// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title IGovernanceStaking
 * @notice Interface for interacting with the staking contract
 */
interface IGovernanceStaking {
    function getVotingPower(address user) external view returns (uint256);
    function getUserVotingDetails(address user) external view returns (
        uint256[] memory eligibleTokens,
        uint256[] memory lockedTokens
    );
    function getTotalStakedNFTs() external view returns (uint256);
    function getUserStakedTokens(address user) external view returns (uint256[] memory);
    function version() external pure returns (string memory);
}

/**
 * @title IDAppRegistry
 * @notice Interface for interacting with the DApp registry
 */
interface IDAppRegistry {
    struct DApp {
        string name;
        string description;
        address contractAddress;
        address registrar;
        uint128 registeredAt;
        uint128 lastActivityAt;
        bool active;
        uint256 totalProposals;
        uint256 successfulProposals;
        uint256 failedProposals;
    }
    
    struct DAppConfig {
        uint256 minProposalThreshold;
        uint256 defaultQuorum;
        uint256 defaultVotingDuration;
        bool customSettingsEnabled;
    }
    
    function getDApp(uint256 dappId) external view returns (DApp memory);
    function getDAppConfig(uint256 dappId) external view returns (DAppConfig memory);
    function isDAppActive(uint256 dappId) external view returns (bool);
    function isFunctionWhitelisted(uint256 dappId, bytes4 functionSelector) external view returns (bool);
    function updateActivity(uint256 dappId) external;
    function incrementProposalCount(uint256 dappId) external returns (uint256);
    function updateProposalStats(uint256 dappId, bool success) external;
    function updateActiveProposals(uint256 dappId, bool increment) external;
    function executeOnDApp(uint256 dappId, uint256 proposalId, bytes calldata actionData) external returns (bool);
}

/**
 * @title ProposalManager
 * @author Enhanced Implementation v2.0.0 with Full Compatibility
 * @notice Manages proposals and voting for the governance system
 * @dev Compatible with GovernanceNFTStaking v2.1.0 and StandardizedGovernanceNFT v2.0.0
 */
contract ProposalManager is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ========== Version ==========
    string public constant VERSION = "2.0.0";

    // ========== Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ========== Constants ==========
    uint256 public constant MIN_VOTING_DURATION = 1 days;
    uint256 public constant MAX_VOTING_DURATION = 30 days;
    uint256 public constant MIN_QUORUM_PERCENTAGE = 1;
    uint256 public constant MAX_QUORUM_PERCENTAGE = 100;
    uint256 public constant EXECUTION_DELAY = 1 days;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint256 public constant MAX_ACTIVE_PROPOSALS_PER_DAPP = 5;
    uint256 public constant MAX_ACTION_DATA_SIZE = 10000;
    uint256 public constant PROPOSAL_CREATION_COOLDOWN = 1 hours;
    uint256 public constant MAX_SNAPSHOT_VOTERS = 1000; // Gas optimization limit
    uint256 public constant MAX_BATCH_SNAPSHOT = 50; // Max users per snapshot batch

    // ========== Enums ==========
    enum ProposalState {
        Pending,
        Active,
        Succeeded,
        Failed,
        Executed,
        Cancelled,
        Expired
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    // ========== Structs ==========
    struct Vote {
        uint256 votingPower;
        VoteType voteType;
        uint128 timestamp;
    }

    struct ProposalCore {
        uint256 dappId;
        address proposer;
        bytes4 functionSelector;
        uint128 startTime;
        uint128 endTime;
        uint128 executionTime;
        uint256 quorumRequired;
        ProposalState state;
        uint256 snapshotBlock; // Block number for snapshot
    }

    struct ProposalVotes {
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 snapshotTotalVotingPower;
    }

    struct VotingPowerSnapshot {
        bool hasSnapshot;
        uint256 votingPower;
    }

    struct StakingContractInfo {
        address contractAddress;
        string expectedVersion;
        bool isActive;
    }

    // ========== State Variables ==========
    StakingContractInfo public stakingContractInfo;
    IDAppRegistry public immutable dappRegistry;
    
    uint256 public proposalCounter;
    
    // Split proposal storage to avoid stack issues
    mapping(uint256 => ProposalCore) public proposalCores;
    mapping(uint256 => ProposalVotes) public proposalVotes;
    mapping(uint256 => string) public proposalTitles;
    mapping(uint256 => string) public proposalDescriptions;
    mapping(uint256 => bytes) public proposalActionData;
    mapping(uint256 => uint256) public proposalNumbers; // proposalId => proposal number in DApp
    
    // Voting power snapshots: proposalId => user => snapshot
    mapping(uint256 => mapping(address => VotingPowerSnapshot)) public votingPowerSnapshots;
    mapping(uint256 => EnumerableSet.AddressSet) private snapshotVoters;
    
    mapping(uint256 => mapping(address => Vote)) public userVotes;
    mapping(uint256 => EnumerableSet.AddressSet) private proposalVoters;
    mapping(address => EnumerableSet.UintSet) private userActiveProposals;
    mapping(uint256 => EnumerableSet.UintSet) private dappActiveProposals;
    mapping(address => uint256) public lastProposalTimestamp;

    // ========== Events ==========
    event StakingContractUpdated(address indexed oldContract, address indexed newContract, string version);
    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed dappId,
        address indexed proposer,
        string title,
        uint256 endTime,
        uint256 quorum,
        uint256 snapshotBlock
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteType voteType,
        uint256 votingPower,
        string reason
    );
    event ProposalStateChanged(uint256 indexed proposalId, ProposalState oldState, ProposalState newState);
    event ProposalExecuted(uint256 indexed proposalId, bool success, bytes returnData);
    event ProposalCancelled(uint256 indexed proposalId, string reason);
    event VotingPowerSnapshotted(uint256 indexed proposalId, address indexed voter, uint256 votingPower);
    event BatchSnapshotCompleted(uint256 indexed proposalId, uint256 userCount);

    // ========== Custom Errors ==========
    error InvalidAddress();
    error InvalidDApp();
    error ProposalNotFound();
    error InvalidProposalState();
    error InvalidVotingDuration();
    error InvalidQuorum();
    error InsufficientVotingPower();
    error ProposalNotActive();
    error AlreadyVoted();
    error VotingEnded();
    error VotingNotEnded();
    error ExecutionDelayNotMet();
    error ExecutionWindowExpired();
    error FunctionNotWhitelisted();
    error InvalidActionData();
    error TooManyActiveProposals();
    error ProposalCooldown();
    error NotProposer();
    error NotAuthorized();
    error ExecutionFailed();
    error NoVotingPowerSnapshot();
    error SnapshotLimitReached();
    error StakingContractNotSet();
    error VersionMismatch();
    error ContractNotActive();
    error InvalidBatchSize();

    // ========== Constructor ==========
    constructor(address _stakingContract, address _dappRegistry, string memory _expectedStakingVersion) {
        if (_stakingContract == address(0) || _dappRegistry == address(0)) revert InvalidAddress();
        
        // Verify staking contract version
        try IGovernanceStaking(_stakingContract).version() returns (string memory stakingVersion) {
            if (keccak256(bytes(stakingVersion)) != keccak256(bytes(_expectedStakingVersion))) {
                revert VersionMismatch();
            }
        } catch {
            revert VersionMismatch();
        }
        
        stakingContractInfo = StakingContractInfo({
            contractAddress: _stakingContract,
            expectedVersion: _expectedStakingVersion,
            isActive: true
        });
        
        dappRegistry = IDAppRegistry(_dappRegistry);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    // ========== Version Function ==========

    /**
     * @notice Get contract version
     * @return Contract version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ========== Modifiers ==========
    
    modifier validProposal(uint256 _proposalId) {
        if (_proposalId == 0 || _proposalId > proposalCounter) revert ProposalNotFound();
        _;
    }

    modifier onlyWithActiveStaking() {
        if (!stakingContractInfo.isActive) revert ContractNotActive();
        if (stakingContractInfo.contractAddress == address(0)) revert StakingContractNotSet();
        _;
    }

    // ========== Configuration ==========

    /**
     * @notice Update the staking contract with version verification
     * @param _stakingContract New staking contract address
     * @param _expectedVersion Expected version of the staking contract
     */
    function setStakingContract(address _stakingContract, string memory _expectedVersion) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (_stakingContract == address(0)) revert InvalidAddress();
        
        // Verify version
        try IGovernanceStaking(_stakingContract).version() returns (string memory stakingVersion) {
            if (keccak256(bytes(stakingVersion)) != keccak256(bytes(_expectedVersion))) {
                revert VersionMismatch();
            }
        } catch {
            revert VersionMismatch();
        }
        
        address oldContract = stakingContractInfo.contractAddress;
        
        stakingContractInfo = StakingContractInfo({
            contractAddress: _stakingContract,
            expectedVersion: _expectedVersion,
            isActive: true
        });
        
        emit StakingContractUpdated(oldContract, _stakingContract, _expectedVersion);
    }

    /**
     * @notice Emergency circuit breaker for staking contract
     * @param _active New active status
     */
    function setStakingContractActive(bool _active) external onlyRole(EMERGENCY_ROLE) {
        stakingContractInfo.isActive = _active;
    }

    // ========== Internal Functions ==========
    
    /**
     * @notice Get staking contract instance
     * @return Staking contract interface
     */
    function _getStakingContract() internal view returns (IGovernanceStaking) {
        return IGovernanceStaking(stakingContractInfo.contractAddress);
    }

    /**
     * @notice Get total voting power from staking contract
     * @return Total staked NFTs (voting power)
     */
    function _getTotalVotingPowerFromStaking() internal view returns (uint256) {
        return _getStakingContract().getTotalStakedNFTs();
    }

    /**
     * @notice Take a voting power snapshot for a user
     * @param _proposalId Proposal ID
     * @param _user User address
     */
    function _takeVotingPowerSnapshot(uint256 _proposalId, address _user) internal {
        if (votingPowerSnapshots[_proposalId][_user].hasSnapshot) return;
        
        uint256 votingPower = _getStakingContract().getVotingPower(_user);
        votingPowerSnapshots[_proposalId][_user] = VotingPowerSnapshot({
            hasSnapshot: true,
            votingPower: votingPower
        });
        
        snapshotVoters[_proposalId].add(_user);
        emit VotingPowerSnapshotted(_proposalId, _user, votingPower);
    }

    /**
     * @notice Get user's snapshotted voting power for a proposal
     * @param _proposalId Proposal ID
     * @param _user User address
     * @return Snapshotted voting power
     */
    function _getSnapshotVotingPower(uint256 _proposalId, address _user) internal view returns (uint256) {
        VotingPowerSnapshot memory snapshot = votingPowerSnapshots[_proposalId][_user];
        if (!snapshot.hasSnapshot) revert NoVotingPowerSnapshot();
        return snapshot.votingPower;
    }

    // ========== Proposal Creation ==========

    /**
     * @notice Create a governance proposal
     * @param _dappId Target DApp ID
     * @param _title Proposal title
     * @param _description Proposal description
     * @param _actionData Encoded function call data
     * @param _votingDuration Custom voting duration (0 for default)
     * @param _quorumRequired Custom quorum (0 for default)
     * @return proposalId The created proposal ID
     */
    function createProposal(
        uint256 _dappId,
        string memory _title,
        string memory _description,
        bytes memory _actionData,
        uint256 _votingDuration,
        uint256 _quorumRequired
    ) external nonReentrant whenNotPaused onlyWithActiveStaking returns (uint256 proposalId) {
        // Validate DApp
        if (!dappRegistry.isDAppActive(_dappId)) revert InvalidDApp();
        
        // Validate action data
        if (_actionData.length < 4 || _actionData.length > MAX_ACTION_DATA_SIZE) {
            revert InvalidActionData();
        }
        
        // Extract and validate function selector
        bytes4 functionSelector = bytes4(_actionData);
        if (!dappRegistry.isFunctionWhitelisted(_dappId, functionSelector)) {
            revert FunctionNotWhitelisted();
        }
        
        // Check voting power
        uint256 votingPower = _getStakingContract().getVotingPower(msg.sender);
        IDAppRegistry.DAppConfig memory config = dappRegistry.getDAppConfig(_dappId);
        
        if (votingPower < config.minProposalThreshold) {
            revert InsufficientVotingPower();
        }
        
        // Check cooldown
        if (block.timestamp < lastProposalTimestamp[msg.sender] + PROPOSAL_CREATION_COOLDOWN) {
            revert ProposalCooldown();
        }
        
        // Check active proposals limit
        if (dappActiveProposals[_dappId].length() >= MAX_ACTIVE_PROPOSALS_PER_DAPP) {
            revert TooManyActiveProposals();
        }
        
        // Set voting parameters
        if (_votingDuration == 0) {
            _votingDuration = config.defaultVotingDuration;
        } else if (_votingDuration < MIN_VOTING_DURATION || _votingDuration > MAX_VOTING_DURATION) {
            revert InvalidVotingDuration();
        }
        
        if (_quorumRequired == 0) {
            _quorumRequired = config.defaultQuorum;
        } else if (_quorumRequired < MIN_QUORUM_PERCENTAGE || _quorumRequired > MAX_QUORUM_PERCENTAGE * 100) {
            revert InvalidQuorum();
        }
        
        // Create proposal
        proposalId = ++proposalCounter;
        uint256 proposalNumber = dappRegistry.incrementProposalCount(_dappId);
        
        // Store core data with snapshot block
        proposalCores[proposalId] = ProposalCore({
            dappId: _dappId,
            proposer: msg.sender,
            functionSelector: functionSelector,
            startTime: uint128(block.timestamp),
            endTime: uint128(block.timestamp + _votingDuration),
            executionTime: uint128(block.timestamp + _votingDuration + EXECUTION_DELAY),
            quorumRequired: _quorumRequired,
            state: ProposalState.Active,
            snapshotBlock: block.number
        });
        
        // Store votes data with actual total voting power snapshot
        proposalVotes[proposalId] = ProposalVotes({
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            snapshotTotalVotingPower: _getTotalVotingPowerFromStaking()
        });
        
        // Store strings and bytes separately
        proposalTitles[proposalId] = _title;
        proposalDescriptions[proposalId] = _description;
        proposalActionData[proposalId] = _actionData;
        proposalNumbers[proposalId] = proposalNumber;
        
        // Take voting power snapshot for proposer
        _takeVotingPowerSnapshot(proposalId, msg.sender);
        
        // Update tracking
        lastProposalTimestamp[msg.sender] = block.timestamp;
        userActiveProposals[msg.sender].add(proposalId);
        dappActiveProposals[_dappId].add(proposalId);
        
        // Update DApp activity
        dappRegistry.updateActivity(_dappId);
        dappRegistry.updateActiveProposals(_dappId, true);
        
        emit ProposalCreated(proposalId, _dappId, msg.sender, _title, block.timestamp + _votingDuration, _quorumRequired, block.number);
    }

    // ========== Voting ==========

    /**
     * @notice Cast a vote on a proposal
     * @param _proposalId Proposal ID
     * @param _voteType Vote type
     * @param _reason Optional reason
     */
    function castVote(
        uint256 _proposalId,
        VoteType _voteType,
        string memory _reason
    ) external nonReentrant validProposal(_proposalId) onlyWithActiveStaking {
        ProposalCore storage core = proposalCores[_proposalId];
        
        if (core.state != ProposalState.Active) revert ProposalNotActive();
        if (block.timestamp >= core.endTime) revert VotingEnded();
        if (userVotes[_proposalId][msg.sender].votingPower > 0) revert AlreadyVoted();
        
        // Check if snapshot exists for user, if not take one
        if (!votingPowerSnapshots[_proposalId][msg.sender].hasSnapshot) {
            // Prevent too many snapshots to avoid gas issues
            if (snapshotVoters[_proposalId].length() >= MAX_SNAPSHOT_VOTERS) {
                revert SnapshotLimitReached();
            }
            _takeVotingPowerSnapshot(_proposalId, msg.sender);
        }
        
        // Use snapshotted voting power
        uint256 votingPower = _getSnapshotVotingPower(_proposalId, msg.sender);
        if (votingPower == 0) revert InsufficientVotingPower();
        
        // Record vote
        userVotes[_proposalId][msg.sender] = Vote({
            votingPower: votingPower,
            voteType: _voteType,
            timestamp: uint128(block.timestamp)
        });
        
        proposalVoters[_proposalId].add(msg.sender);
        
        // Update vote tallies
        ProposalVotes storage votes = proposalVotes[_proposalId];
        if (_voteType == VoteType.For) {
            votes.forVotes += votingPower;
        } else if (_voteType == VoteType.Against) {
            votes.againstVotes += votingPower;
        } else {
            votes.abstainVotes += votingPower;
        }
        
        emit VoteCast(_proposalId, msg.sender, _voteType, votingPower, _reason);
    }

    /**
     * @notice Pre-snapshot voting power for multiple users
     * @param _proposalId Proposal ID
     * @param _users Array of user addresses to snapshot
     * @dev Allows taking snapshots in batches to avoid gas limit issues
     */
    function snapshotVotingPowerBatch(uint256 _proposalId, address[] calldata _users) 
        external 
        validProposal(_proposalId) 
        onlyWithActiveStaking 
    {
        ProposalCore storage core = proposalCores[_proposalId];
        if (core.state != ProposalState.Active) revert ProposalNotActive();
        
        if (_users.length == 0 || _users.length > MAX_BATCH_SNAPSHOT) {
            revert InvalidBatchSize();
        }
        
        uint256 currentSnapshots = snapshotVoters[_proposalId].length();
        if (currentSnapshots + _users.length > MAX_SNAPSHOT_VOTERS) {
            revert SnapshotLimitReached();
        }
        
        for (uint256 i = 0; i < _users.length; i++) {
            _takeVotingPowerSnapshot(_proposalId, _users[i]);
        }
        
        emit BatchSnapshotCompleted(_proposalId, _users.length);
    }

    // ========== State Management ==========

    /**
     * @notice Update proposal state based on current conditions
     * @param _proposalId Proposal ID
     */
    function updateProposalState(uint256 _proposalId) public validProposal(_proposalId) {
        ProposalCore storage core = proposalCores[_proposalId];
        ProposalState oldState = core.state;
        ProposalState newState = _calculateProposalState(_proposalId);
        
        if (oldState != newState) {
            core.state = newState;
            
            // Handle state transition
            if (oldState == ProposalState.Active) {
                _handleActiveStateTransition(_proposalId, newState);
            }
            
            emit ProposalStateChanged(_proposalId, oldState, newState);
        }
    }

    function _calculateProposalState(uint256 _proposalId) internal view returns (ProposalState) {
        ProposalCore storage core = proposalCores[_proposalId];
        ProposalState currentState = core.state;
        
        if (currentState == ProposalState.Active && block.timestamp >= core.endTime) {
            ProposalVotes storage votes = proposalVotes[_proposalId];
            uint256 totalVotes = votes.forVotes + votes.againstVotes + votes.abstainVotes;
            uint256 requiredQuorum = (votes.snapshotTotalVotingPower * core.quorumRequired) / 10000;
            
            if (totalVotes >= requiredQuorum && votes.forVotes > votes.againstVotes) {
                return ProposalState.Succeeded;
            } else {
                return ProposalState.Failed;
            }
        } else if (currentState == ProposalState.Succeeded) {
            if (block.timestamp > core.executionTime + EXECUTION_WINDOW) {
                return ProposalState.Expired;
            }
        }
        
        return currentState;
    }

    function _handleActiveStateTransition(uint256 _proposalId, ProposalState _newState) internal {
        ProposalCore storage core = proposalCores[_proposalId];
        
        // Update DApp stats
        dappRegistry.updateProposalStats(core.dappId, _newState == ProposalState.Succeeded);
        
        // Clean up tracking
        userActiveProposals[core.proposer].remove(_proposalId);
        dappActiveProposals[core.dappId].remove(_proposalId);
        dappRegistry.updateActiveProposals(core.dappId, false);
    }

    // ========== Execution ==========

    /**
     * @notice Execute a successful proposal
     * @param _proposalId Proposal ID
     */
    function executeProposal(uint256 _proposalId) external nonReentrant validProposal(_proposalId) {
        updateProposalState(_proposalId);
        
        ProposalCore storage core = proposalCores[_proposalId];
        
        if (core.state != ProposalState.Succeeded) revert InvalidProposalState();
        if (block.timestamp < core.executionTime) revert ExecutionDelayNotMet();
        if (block.timestamp > core.executionTime + EXECUTION_WINDOW) revert ExecutionWindowExpired();
        
        // Mark as executed before external call
        core.state = ProposalState.Executed;
        
        // Execute via registry
        bytes memory actionData = proposalActionData[_proposalId];
        uint256 proposalNumber = proposalNumbers[_proposalId];
        
        try dappRegistry.executeOnDApp(core.dappId, proposalNumber, actionData) returns (bool success) {
            if (!success) revert ExecutionFailed();
            emit ProposalExecuted(_proposalId, true, "");
        } catch Error(string memory reason) {
            core.state = ProposalState.Succeeded;
            emit ProposalExecuted(_proposalId, false, bytes(reason));
            revert ExecutionFailed();
        } catch (bytes memory lowLevelData) {
            core.state = ProposalState.Succeeded;
            emit ProposalExecuted(_proposalId, false, lowLevelData);
            revert ExecutionFailed();
        }
        
        dappRegistry.updateActivity(core.dappId);
    }

    /**
     * @notice Cancel a proposal
     * @param _proposalId Proposal ID
     * @param _reason Cancellation reason
     */
    function cancelProposal(uint256 _proposalId, string memory _reason) external validProposal(_proposalId) {
        ProposalCore storage core = proposalCores[_proposalId];
        
        if (!hasRole(EMERGENCY_ROLE, msg.sender) && core.proposer != msg.sender) {
            revert NotAuthorized();
        }
        
        if (core.state != ProposalState.Active && core.state != ProposalState.Succeeded) {
            revert InvalidProposalState();
        }
        
        ProposalState oldState = core.state;
        core.state = ProposalState.Cancelled;
        
        if (oldState == ProposalState.Active) {
            userActiveProposals[core.proposer].remove(_proposalId);
            dappActiveProposals[core.dappId].remove(_proposalId);
            dappRegistry.updateActiveProposals(core.dappId, false);
        }
        
        emit ProposalStateChanged(_proposalId, oldState, ProposalState.Cancelled);
        emit ProposalCancelled(_proposalId, _reason);
    }

    // ========== View Functions ==========

    /**
     * @notice Get proposal details
     * @param _proposalId Proposal ID
     * @return Core proposal data
     * @return Voting data
     * @return title Proposal title
     * @return description Proposal description
     */
    function getProposal(uint256 _proposalId) external view validProposal(_proposalId) returns (
        ProposalCore memory,
        ProposalVotes memory,
        string memory title,
        string memory description
    ) {
        return (
            proposalCores[_proposalId],
            proposalVotes[_proposalId],
            proposalTitles[_proposalId],
            proposalDescriptions[_proposalId]
        );
    }

    /**
     * @notice Get proposal action data
     * @param _proposalId Proposal ID
     * @return Action data bytes
     */
    function getProposalActionData(uint256 _proposalId) external view validProposal(_proposalId) returns (bytes memory) {
        return proposalActionData[_proposalId];
    }

    /**
     * @notice Get user's vote
     * @param _proposalId Proposal ID
     * @param _user User address
     * @return vote Vote details
     */
    function getUserVote(uint256 _proposalId, address _user) external view returns (Vote memory) {
        return userVotes[_proposalId][_user];
    }

    /**
     * @notice Get user's snapshotted voting power
     * @param _proposalId Proposal ID
     * @param _user User address
     * @return votingPower Snapshotted voting power
     * @return hasSnapshot Whether snapshot exists
     */
    function getUserSnapshotVotingPower(uint256 _proposalId, address _user) external view returns (uint256 votingPower, bool hasSnapshot) {
        VotingPowerSnapshot memory snapshot = votingPowerSnapshots[_proposalId][_user];
        return (snapshot.votingPower, snapshot.hasSnapshot);
    }

    /**
     * @notice Get proposal voters
     * @param _proposalId Proposal ID
     * @return voters Array of voter addresses
     */
    function getProposalVoters(uint256 _proposalId) external view returns (address[] memory) {
        return proposalVoters[_proposalId].values();
    }

    /**
     * @notice Get users with voting power snapshots
     * @param _proposalId Proposal ID
     * @return users Array of user addresses with snapshots
     */
    function getSnapshotVoters(uint256 _proposalId) external view returns (address[] memory) {
        return snapshotVoters[_proposalId].values();
    }

    /**
     * @notice Get user's active proposals
     * @param _user User address
     * @return proposalIds Active proposal IDs
     */
    function getUserActiveProposals(address _user) external view returns (uint256[] memory) {
        return userActiveProposals[_user].values();
    }

    /**
     * @notice Get DApp's active proposals
     * @param _dappId DApp ID
     * @return proposalIds Active proposal IDs
     */
    function getDAppActiveProposals(uint256 _dappId) external view returns (uint256[] memory) {
        return dappActiveProposals[_dappId].values();
    }

    /**
     * @notice Check if user has active proposals
     * @param _user User address
     * @return hasActive Whether user has active proposals
     */
    function isProposalActive(address _user) external view returns (bool) {
        return userActiveProposals[_user].length() > 0;
    }

    /**
     * @notice Check if there are any active proposals
     * @return hasActive Whether there are any active proposals
     */
    function hasActiveProposals() external view returns (bool) {
        for (uint256 i = 1; i <= proposalCounter; i++) {
            if (proposalCores[i].state == ProposalState.Active) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get current total voting power
     * @return Current total staked NFTs (voting power)
     */
    function getCurrentTotalVotingPower() external view onlyWithActiveStaking returns (uint256) {
        return _getTotalVotingPowerFromStaking();
    }

    /**
     * @notice Get staking contract info
     * @return contractAddress Address of the staking contract
     * @return expectedVersion Expected version string
     * @return isActive Whether the contract is active
     */
    function getStakingContractInfo() external view returns (
        address contractAddress,
        string memory expectedVersion,
        bool isActive
    ) {
        return (
            stakingContractInfo.contractAddress,
            stakingContractInfo.expectedVersion,
            stakingContractInfo.isActive
        );
    }

    /**
     * @notice Get all proposals paginated
     * @param _startIndex Start index
     * @param _count Number to return
     * @return proposalIds Array of proposal IDs
     * @return states Array of proposal states
     */
    function getProposalsPaginated(uint256 _startIndex, uint256 _count) 
        external 
        view 
        returns (
            uint256[] memory proposalIds,
            ProposalState[] memory states
        ) 
    {
        if (_count > 100) _count = 100; // Max 100 per call
        
        uint256 endIndex = _startIndex + _count;
        if (endIndex > proposalCounter) {
            endIndex = proposalCounter;
        }
        
        uint256 actualCount = endIndex > _startIndex ? endIndex - _startIndex : 0;
        proposalIds = new uint256[](actualCount);
        states = new ProposalState[](actualCount);
        
        for (uint256 i = 0; i < actualCount; i++) {
            uint256 proposalId = _startIndex + i + 1;
            proposalIds[i] = proposalId;
            states[i] = proposalCores[proposalId].state;
        }
    }

    /**
     * @notice Get voting results for a proposal
     * @param _proposalId Proposal ID
     * @return forVotes Number of for votes
     * @return againstVotes Number of against votes
     * @return abstainVotes Number of abstain votes
     * @return totalVotes Total votes cast
     * @return quorumReached Whether quorum was reached
     * @return proposalPassed Whether proposal passed
     */
    function getVotingResults(uint256 _proposalId) 
        external 
        view 
        validProposal(_proposalId) 
        returns (
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            uint256 totalVotes,
            bool quorumReached,
            bool proposalPassed
        ) 
    {
        ProposalVotes storage votes = proposalVotes[_proposalId];
        ProposalCore storage core = proposalCores[_proposalId];
        
        forVotes = votes.forVotes;
        againstVotes = votes.againstVotes;
        abstainVotes = votes.abstainVotes;
        totalVotes = forVotes + againstVotes + abstainVotes;
        
        uint256 requiredQuorum = (votes.snapshotTotalVotingPower * core.quorumRequired) / 10000;
        quorumReached = totalVotes >= requiredQuorum;
        proposalPassed = quorumReached && forVotes > againstVotes;
    }

    // ========== Admin Functions ==========

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Grant executor role
     * @param _account Address to grant role to
     */
    function grantExecutorRole(address _account) external onlyRole(ADMIN_ROLE) {
        _grantRole(EXECUTOR_ROLE, _account);
    }

    /**
     * @notice Revoke executor role
     * @param _account Address to revoke role from
     */
    function revokeExecutorRole(address _account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(EXECUTOR_ROLE, _account);
    }

    // ========== IGovernanceIntegration Implementation ==========

    /**
     * @notice Notify governance of stake updates (compatibility)
     * @dev This function exists for interface compatibility but no action is needed
     */
    function notifyStakeUpdate(address /* _user */, uint256 /* _tokenId */, bool /* _isStaking */) external {
        // Compatibility function - no action needed
        // The staking contract calls this, but ProposalManager doesn't need to track individual stakes
    }
}
