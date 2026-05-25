// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SovereignEscrow.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockPassport {
    mapping(uint256 => bool) public restricted;

    function isVerifiedDeveloper(address) external pure returns (bool) {
        return true;
    }
    function getGrade(uint256) external pure returns (uint8) {
        return 5;
    }
    function isRestricted(uint256 tokenId) external view returns (bool) {
        return restricted[tokenId];
    }
    function updateReputation(uint256, int256, bool) external {}
    function setRestricted(uint256 tokenId, bool value) external {
        restricted[tokenId] = value;
    }
}

contract MockTreasury {
    uint256 public totalReceived;
    IERC20 public usdc;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }
    function receiveFees(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

contract SovereignEscrowTest is Test {

    SovereignEscrow public escrow;
    MockUSDC        public usdc;
    MockPassport    public passport;
    MockTreasury    public treasury;

    address public owner   = makeAddr("owner");
    address public client  = makeAddr("client");
    address public agent   = makeAddr("agent");
    address public stranger = makeAddr("stranger");

    uint256 public constant AGENT_TOKEN_ID = 1;
    uint256 public constant JOB_AMOUNT     = 100 * 1e6; // 100 USDC
    uint256 public constant STAKE_AMOUNT   = 10  * 1e6; // 10 USDC (10%)
    uint256 public constant PLATFORM_FEE   = 1   * 1e6; // 1 USDC (1%)

    bytes32 public constant SPEC_HASH  = keccak256("job specification v1");
    bytes32 public constant WORK_HASH  = keccak256("deliverable v1");

    function setUp() public {
        usdc     = new MockUSDC();
        passport = new MockPassport();
        treasury = new MockTreasury(address(usdc));

        vm.prank(owner);
        escrow = new SovereignEscrow(
            address(usdc),
            address(passport),
            address(treasury)
        );

        usdc.mint(client, 10_000 * 1e6);
        usdc.mint(agent,  10_000 * 1e6);

        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(agent);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // =============================================
    // HELPERS
    // =============================================

    function _createJob() internal returns (uint256 jobId) {
        SovereignEscrow.Milestone[] memory empty;
        vm.prank(client);
        jobId = escrow.createJob(
            JOB_AMOUNT,
            block.timestamp + 7 days,
            SovereignEscrow.JobType.FIXED,
            SPEC_HASH,
            "Build API endpoint",
            empty
        );
    }

    function _createAndAccept() internal returns (uint256 jobId) {
        jobId = _createJob();
        vm.prank(agent);
        escrow.acceptJob(jobId, AGENT_TOKEN_ID);
    }

    function _createAcceptSubmit() internal returns (uint256 jobId) {
        jobId = _createAndAccept();
        vm.prank(agent);
        escrow.submitWork(jobId, 0, WORK_HASH);
    }

    // =============================================
    // CREATE JOB TESTS
    // =============================================

    function test_createJob_success() public {
        uint256 jobId = _createJob();
        assertEq(jobId, 1);

        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.amount, JOB_AMOUNT);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.OPEN));
    }

    function test_createJob_revertsIfAmountTooLow() public {
        SovereignEscrow.Milestone[] memory empty;
        vm.prank(client);
        vm.expectRevert(SovereignEscrow.InvalidAmount.selector);
        escrow.createJob(
            100,
            block.timestamp + 1 days,
            SovereignEscrow.JobType.FIXED,
            SPEC_HASH,
            "Too cheap",
            empty
        );
    }

    function test_createJob_revertsIfNoSpecHash() public {
        SovereignEscrow.Milestone[] memory empty;
        vm.prank(client);
        vm.expectRevert(SovereignEscrow.InvalidAmount.selector);
        escrow.createJob(
            JOB_AMOUNT,
            block.timestamp + 1 days,
            SovereignEscrow.JobType.FIXED,
            bytes32(0),
            "No spec",
            empty
        );
    }

    // =============================================
    // ACCEPT JOB TESTS
    // =============================================

    function test_acceptJob_success() public {
        uint256 jobId = _createJob();
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        escrow.acceptJob(jobId, AGENT_TOKEN_ID);

        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.ACTIVE));
        assertEq(job.agentWallet, agent);
        assertEq(job.stake, STAKE_AMOUNT);
        assertEq(usdc.balanceOf(agent), agentBefore - STAKE_AMOUNT);
    }

    function test_acceptJob_revertsIfRestricted() public {
        uint256 jobId = _createJob();
        passport.setRestricted(AGENT_TOKEN_ID, true);

        vm.prank(agent);
        vm.expectRevert(SovereignEscrow.AgentIsRestricted.selector);
        escrow.acceptJob(jobId, AGENT_TOKEN_ID);
    }

    function test_acceptJob_revertsIfSelfHire() public {
        uint256 jobId = _createJob();

        vm.prank(client);
        vm.expectRevert(SovereignEscrow.SelfHire.selector);
        escrow.acceptJob(jobId, AGENT_TOKEN_ID);
    }

    // =============================================
    // SUBMIT AND APPROVE TESTS
    // =============================================

    function test_approveJob_success() public {
        uint256 jobId = _createAcceptSubmit();

        uint256 agentBefore    = usdc.balanceOf(agent);
        uint256 clientBefore   = usdc.balanceOf(client);

        vm.prank(client);
        escrow.approveJob(jobId);

        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.COMPLETED));

        uint256 expectedPayout = JOB_AMOUNT - PLATFORM_FEE + STAKE_AMOUNT;
        assertEq(usdc.balanceOf(agent), agentBefore + expectedPayout);
    }

    function test_disputeJob_success() public {
        uint256 jobId = _createAcceptSubmit();

        vm.prank(client);
        escrow.disputeJob(jobId);

        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.DISPUTED));
    }

    // =============================================
    // CANCEL AND EXPIRY TESTS
    // =============================================

    function test_cancelJob_success() public {
        uint256 jobId = _createJob();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        escrow.cancelJob(jobId);

        assertEq(usdc.balanceOf(client), clientBefore + JOB_AMOUNT);
        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.CANCELLED));
    }

    function test_reclaimExpired_success() public {
        uint256 jobId = _createAndAccept();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + 8 days);

        vm.prank(client);
        escrow.reclaimExpired(jobId);

        assertEq(usdc.balanceOf(client), clientBefore + JOB_AMOUNT + STAKE_AMOUNT);
        SovereignEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(uint256(job.status), uint256(SovereignEscrow.JobStatus.EXPIRED));
    }
}