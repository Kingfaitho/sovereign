// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAgentPassport {
    function isVerifiedDeveloper(address dev) external view returns (bool);
    function getGrade(uint256 tokenId) external view returns (uint8);
    function isRestricted(uint256 tokenId) external view returns (bool);
    function updateReputation(uint256 tokenId, int256 delta, bool succeeded) external;
}

interface ISovereignTreasury {
    function receiveFees(uint256 amount) external;
}

contract SovereignEscrow is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // =============================================
    // ENUMS
    // =============================================

    enum JobStatus {
        OPEN,
        ACTIVE,
        REVIEW,
        DISPUTED,
        COMPLETED,
        CANCELLED,
        EXPIRED
    }

    enum JobType {
        FIXED,
        MILESTONE
    }

    // =============================================
    // STRUCTS
    // =============================================

    struct Milestone {
        string   description;
        uint256  amount;
        bool     completed;
        bool     approved;
    }

    struct Job {
        address   client;
        uint256   agentTokenId;
        address   agentWallet;
        uint256   amount;
        uint256   stake;
        uint256   deadline;
        JobStatus status;
        JobType   jobType;
        bytes32   specHash;
        uint256   platformFee;
        uint256   createdAt;
        uint256   completedAt;
        string    title;
    }

    // =============================================
    // CONSTANTS
    // =============================================

    uint256 public constant PLATFORM_FEE_BPS = 100;
    uint256 public constant STAKE_BPS        = 1000;
    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant MIN_JOB_AMOUNT   = 1_000_000;
    uint256 public constant MAX_DEADLINE     = 90 days;
    uint256 public constant DISPUTE_WINDOW   = 48 hours;
    int256  public constant REP_SUCCESS      = 10;
    int256  public constant REP_FAILURE      = -5;
    int256  public constant REP_DISPUTE_WIN  = 15;
    int256  public constant REP_DISPUTE_LOSS = -10;

    // =============================================
    // STORAGE
    // =============================================

    IERC20             public immutable usdc;
    IAgentPassport     public immutable passport;
    ISovereignTreasury public immutable treasury;

    uint256 public nextJobId;
    uint256 public totalJobsCompleted;
    uint256 public totalVolumeProcessed;

    mapping(uint256 => Job)          public jobs;
    mapping(uint256 => Milestone[])  public milestones;
    mapping(uint256 => uint256)      public jobsByAgent;
    mapping(address => uint256[])    public clientJobs;
    mapping(uint256 => uint256[])    public agentJobs;

    // =============================================
    // EVENTS
    // =============================================

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount,
        uint256 deadline,
        JobType jobType,
        bytes32 specHash
    );

    event JobAccepted(
        uint256 indexed jobId,
        uint256 indexed agentTokenId,
        address agentWallet,
        uint256 stake
    );

    event MilestoneSubmitted(
        uint256 indexed jobId,
        uint256 milestoneIndex,
        bytes32 deliverableHash
    );

    event MilestoneApproved(
        uint256 indexed jobId,
        uint256 milestoneIndex,
        uint256 amount
    );

    event JobCompleted(
        uint256 indexed jobId,
        uint256 indexed agentTokenId,
        uint256 payout,
        uint256 platformFee
    );

    event JobDisputed(
        uint256 indexed jobId,
        address indexed client,
        uint256 indexed agentTokenId
    );

    event DisputeResolved(
        uint256 indexed jobId,
        bool clientWon,
        address resolver
    );

    event JobCancelled(uint256 indexed jobId, address indexed client);
    event JobExpired(uint256 indexed jobId, uint256 refund);

    // =============================================
    // ERRORS
    // =============================================

    error InvalidAmount();
    error InvalidDeadline();
    error InvalidAddress();
    error JobNotOpen();
    error JobNotActive();
    error JobNotInReview();
    error NotJobClient();
    error NotJobAgent();
    error AgentIsRestricted();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error SelfHire();
    error InsufficientStake();
    error MilestoneOutOfRange();
    error MilestoneAlreadyCompleted();
    error DisputeWindowOpen();

    // =============================================
    // CONSTRUCTOR
    // =============================================

    constructor(
        address _usdc,
        address _passport,
        address _treasury
    ) Ownable(msg.sender) {
        if (_usdc     == address(0)) revert InvalidAddress();
        if (_passport == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        usdc     = IERC20(_usdc);
        passport = IAgentPassport(_passport);
        treasury = ISovereignTreasury(_treasury);
        nextJobId = 1;
    }

    // =============================================
    // CLIENT FUNCTIONS
    // =============================================

    function createJob(
        uint256 amount,
        uint256 deadline,
        JobType jobType,
        bytes32 specHash,
        string calldata title,
        Milestone[] calldata _milestones
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 jobId)
    {
        if (amount < MIN_JOB_AMOUNT) revert InvalidAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (deadline > block.timestamp + MAX_DEADLINE) revert InvalidDeadline();
        if (specHash == bytes32(0)) revert InvalidAmount();

        jobId = nextJobId++;

        uint256 fee = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;

        jobs[jobId] = Job({
            client:       msg.sender,
            agentTokenId: 0,
            agentWallet:  address(0),
            amount:       amount,
            stake:        0,
            deadline:     deadline,
            status:       JobStatus.OPEN,
            jobType:      jobType,
            specHash:     specHash,
            platformFee:  fee,
            createdAt:    block.timestamp,
            completedAt:  0,
            title:        title
        });

        if (jobType == JobType.MILESTONE) {
            require(_milestones.length > 0, "Need milestones");
            uint256 total = 0;
            for (uint256 i = 0; i < _milestones.length; i++) {
                milestones[jobId].push(_milestones[i]);
                total += _milestones[i].amount;
            }
            require(total == amount, "Milestones must equal total");
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        clientJobs[msg.sender].push(jobId);

        emit JobCreated(jobId, msg.sender, amount, deadline, jobType, specHash);
    }

    function cancelJob(uint256 jobId)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.client != msg.sender) revert NotJobClient();
        if (job.status != JobStatus.OPEN) revert JobNotOpen();

        job.status = JobStatus.CANCELLED;
        usdc.safeTransfer(msg.sender, job.amount);

        emit JobCancelled(jobId, msg.sender);
    }

    function approveJob(uint256 jobId)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.client != msg.sender) revert NotJobClient();
        if (job.status != JobStatus.REVIEW) revert JobNotInReview();

        job.status      = JobStatus.COMPLETED;
        job.completedAt = block.timestamp;

        uint256 payout = job.amount - job.platformFee + job.stake;

        totalJobsCompleted++;
        totalVolumeProcessed += job.amount;

        passport.updateReputation(job.agentTokenId, REP_SUCCESS, true);

        usdc.safeTransfer(job.agentWallet, payout);
        usdc.safeTransfer(address(treasury), job.platformFee);

        emit JobCompleted(jobId, job.agentTokenId, payout, job.platformFee);
    }

    function disputeJob(uint256 jobId)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.client != msg.sender) revert NotJobClient();
        if (job.status != JobStatus.REVIEW) revert JobNotInReview();

        job.status = JobStatus.DISPUTED;

        emit JobDisputed(jobId, msg.sender, job.agentTokenId);
    }

    function resolveDispute(uint256 jobId, bool clientWon)
        external
        onlyOwner
        nonReentrant
    {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.DISPUTED) revert JobNotInReview();

        job.status      = JobStatus.COMPLETED;
        job.completedAt = block.timestamp;

        if (clientWon) {
            passport.updateReputation(job.agentTokenId, REP_DISPUTE_LOSS, false);
            usdc.safeTransfer(job.client, job.amount + job.stake);
        } else {
            passport.updateReputation(job.agentTokenId, REP_DISPUTE_WIN, true);
            uint256 payout = job.amount - job.platformFee + job.stake;
            usdc.safeTransfer(job.agentWallet, payout);
            usdc.safeTransfer(address(treasury), job.platformFee);
        }

        totalJobsCompleted++;
        emit DisputeResolved(jobId, clientWon, msg.sender);
    }

    // =============================================
    // AGENT FUNCTIONS
    // =============================================

    function acceptJob(uint256 jobId, uint256 agentTokenId)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.OPEN) revert JobNotOpen();
        if (job.client == msg.sender) revert SelfHire();
        if (block.timestamp >= job.deadline) revert DeadlinePassed();
        if (passport.isRestricted(agentTokenId)) revert AgentIsRestricted();

        uint256 stakeAmount = (job.amount * STAKE_BPS) / BPS_DENOMINATOR;

        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        job.agentTokenId = agentTokenId;
        job.agentWallet  = msg.sender;
        job.stake        = stakeAmount;
        job.status       = JobStatus.ACTIVE;

        agentJobs[agentTokenId].push(jobId);

        emit JobAccepted(jobId, agentTokenId, msg.sender, stakeAmount);
    }

    function submitWork(
        uint256 jobId,
        uint256 milestoneIndex,
        bytes32 deliverableHash
    )
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.agentWallet != msg.sender) revert NotJobAgent();
        if (job.status != JobStatus.ACTIVE) revert JobNotActive();
        if (block.timestamp > job.deadline) revert DeadlinePassed();
        if (deliverableHash == bytes32(0)) revert InvalidAmount();

        if (job.jobType == JobType.MILESTONE) {
            if (milestoneIndex >= milestones[jobId].length)
                revert MilestoneOutOfRange();
            if (milestones[jobId][milestoneIndex].completed)
                revert MilestoneAlreadyCompleted();

            milestones[jobId][milestoneIndex].completed = true;
            emit MilestoneSubmitted(jobId, milestoneIndex, deliverableHash);
        } else {
            job.status = JobStatus.REVIEW;
            emit MilestoneSubmitted(jobId, 0, deliverableHash);
        }
    }

    function approveMilestone(uint256 jobId, uint256 milestoneIndex)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.client != msg.sender) revert NotJobClient();
        if (job.status != JobStatus.ACTIVE) revert JobNotActive();

        Milestone storage m = milestones[jobId][milestoneIndex];
        if (!m.completed) revert MilestoneAlreadyCompleted();
        if (m.approved)   revert MilestoneAlreadyCompleted();

        m.approved = true;
        usdc.safeTransfer(job.agentWallet, m.amount);
        emit MilestoneApproved(jobId, milestoneIndex, m.amount);

        bool allApproved = true;
        for (uint256 i = 0; i < milestones[jobId].length; i++) {
            if (!milestones[jobId][i].approved) {
                allApproved = false;
                break;
            }
        }

        if (allApproved) {
            job.status      = JobStatus.COMPLETED;
            job.completedAt = block.timestamp;
            totalJobsCompleted++;
            totalVolumeProcessed += job.amount;
            passport.updateReputation(job.agentTokenId, REP_SUCCESS, true);
            usdc.safeTransfer(address(treasury), job.platformFee);
            emit JobCompleted(jobId, job.agentTokenId, job.amount, job.platformFee);
        }
    }

    function reclaimExpired(uint256 jobId)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage job = jobs[jobId];
        if (job.client != msg.sender) revert NotJobClient();
        if (job.status != JobStatus.ACTIVE) revert JobNotActive();
        if (block.timestamp <= job.deadline) revert DeadlineNotPassed();

        job.status = JobStatus.EXPIRED;
        passport.updateReputation(job.agentTokenId, REP_FAILURE, false);

        uint256 refund = job.amount + job.stake;
        usdc.safeTransfer(job.client, refund);

        emit JobExpired(jobId, refund);
    }

    // =============================================
    // VIEW FUNCTIONS
    // =============================================

    function getJob(uint256 jobId)
        external view returns (Job memory)
    {
        return jobs[jobId];
    }

    function getMilestones(uint256 jobId)
        external view returns (Milestone[] memory)
    {
        return milestones[jobId];
    }

    function getClientJobs(address client)
        external view returns (uint256[] memory)
    {
        return clientJobs[client];
    }

    function getAgentJobs(uint256 agentTokenId)
        external view returns (uint256[] memory)
    {
        return agentJobs[agentTokenId];
    }

    function calculateStake(uint256 amount)
        external pure returns (uint256)
    {
        return (amount * STAKE_BPS) / BPS_DENOMINATOR;
    }

    function calculateFee(uint256 amount)
        external pure returns (uint256)
    {
        return (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
    }

    // =============================================
    // ADMIN FUNCTIONS
    // =============================================

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}