// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
* @title SovereignTreasury
* @notice The financial heart of the Sovereign protocol.
*    Receives platform fees, pays founder allocation,
*    funds genesis allocations for new agents,
*    and holds ecosystem reserves.
*/
contract SovereignTreasury is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //=============================================
    // PHASE THRESHOLDS - milestone based not time
    //=============================================

    uint256 public constant PHASE_TWO_THRESHOLD = 1_000;
    uint256 public constant PHASE_THREE_THRESHOLD = 10_000;

    //=============================================
    // FOUNDER ALLOCATION BPS
    //=============================================

    uint256 public constant PHASE_ONE_BPS = 1_000; // 10%
    uint256 public constant PHASE_TWO_BPS = 600; // 6%
    uint256 public constant PHASE_THREE_BPS = 350; // 3.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    //=============================================
    // GENESIS ALLOCATION - given to every new agent
    //=============================================

    uint256 public genesisAllocation;

    //=============================================
    // STORAGE
    //=============================================

    IERC20 public immutable usdc;
    address public founder;
    address public passportContract;

    uint256 public totalActiveAgents;
    uint256 public totalFeesReceived;
    uint256 public totalFounderPaid;
    uint256 public totalGenesisAllocated;
    uint256 public totalgenesisAllocation;

    mapping(address => uint256) public agentGenesisClaimed;

    //=============================================
    // EVENTS
    //=============================================

    event FeeReceived(address indexed from, uint256 amount);
    event FounderPaid(address indexed founder, uint256 amount, uint256 phase);
    event GenesisClaimed(address indexed agent, uint256 amount);
    event AgentCountUpdated(uint256 newCount);
    event GenesisAllocationUpdated(uint256 newAmount);
    event PassportContractUpdated(address newContract);

    //=============================================
    // ERRORS
    //=============================================

    error ZeroAmount();
    error InvalidAddress();
    error AlreayClaimedGenesis();
    error NotPassportContract();
    error InsufficientTreasuryBalance();

    //=============================================
    // CONSTRUCTOR
    //=============================================

    constructor(
        address _usdc,
        address _founder,
        uint256 _genesisAllocation
    ) Ownable(msg.sender) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_founder == address(0)) revert InvalidAddress();

        usdc = IERC20(_usdc);
        founder = _founder;
        genesisAllocation = _genesisAllocation;
    }

    //=============================================
    // CORE FUNCTIONS
    //=============================================

    function receiveFees(uint256 amount)
    external
    nonReentrant
    whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalFeesReceived += amount;

        uint256 founderCut = _calculateFounderCut(amount);

        if (founderCut > 0) {
            totalFounderPaid += founderCut;
            usdc.safeTransfer(founder, founderCut);
            emit FounderPaid(founder, founderCut, currentPhase());
        }

        emit FeeReceived(msg.sender, amount);
    }

    function claimGenesis(address agent)
    external 
    nonReentrant
    whenNotPaused
    {
        if (msg.sender != passportContract) revert NotPassportContract();
        if (agentGenesisClaimed[agent] > 0) revert AlreayClaimedGenesis();
        if (genesisAllocation == 0) revert ZeroAmount();

        uint256 balance = usdc.balanceOf(address(this));
        if (balance < genesisAllocation) revert InsufficientTreasuryBalance();

        agentGenesisClaimed[agent] = genesisAllocation;
        totalGenesisAllocated += genesisAllocation;

        usdc.safeTransfer(agent, genesisAllocation);
        emit GenesisClaimed(agent, genesisAllocation);
    }

     //=============================================
    // VIEW FUNCTIONS
    //=============================================

    function currentPhase() public view returns (uint256) {
        if (totalActiveAgents >= PHASE_THREE_THRESHOLD) return 3;
        if (totalActiveAgents >= PHASE_TWO_THRESHOLD) return 2;
        return 1;
    }

    function currentFounderBps() public view returns (uint256) {
        uint256 phase = currentPhase();
        if (phase == 3) return PHASE_THREE_BPS;
        if (phase == 2) return PHASE_TWO_BPS;
        return PHASE_ONE_BPS;
    }

    function treasuryBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

     //=============================================
    // INTERNAL FUNCTIONS
    //=============================================

    function _calculateFounderCut(uint256 amount)
    internal
    view
    returns (uint256)
    {
        return (amount * currentFounderBps()) / BPS_DENOMINATOR;
    }

     //=============================================
    // ADMIN FUNCTIONS
    //=============================================

    function updateAgentCount(uint256 newCount)
    external
    {
        if(msg.sender != passportContract) revert NotPassportContract();
        totalActiveAgents = newCount;
        emit AgentCountUpdated(newCount);
    }

    function setPassportContract(address _passport)
    external
    onlyOwner
    {
        if (_passport == address(0)) revert InvalidAddress();
        passportContract = _passport;
        emit PassportContractUpdated(_passport);
    }

    function setGenesisAllocation(uint256 amount)
    external
    onlyOwner
    {
        genesisAllocation = amount;
        emit GenesisAllocationUpdated(amount);
    }

    function setFounder(address newFounder) external onlyOwner {
        if(newFounder == address(0)) revert InvalidAddress();
        founder = newFounder;
    }

    function pause() external onlyOwner {_pause();}
    function unpause() external onlyOwner {_unpause();}
}
