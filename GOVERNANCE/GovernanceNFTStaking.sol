// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title IGovernanceNFT
 * @notice Interface for Governance NFT with price tracking
 */
interface IGovernanceNFT is IERC721 {
    function getPurchasePrice(uint256 tokenId) external view returns (uint256 price, address paymentToken);
}

/**
 * @title IGovernanceIntegration
 * @notice Interface for governance contract integration
 */
interface IGovernanceIntegration {
    function notifyStakeUpdate(address user, uint256 tokenId, bool isStaking) external;
    function isProposalActive(address user) external view returns (bool);
    function hasActiveProposals() external view returns (bool);
    function version() external pure returns (string memory);
}

/**
 * @title IRewardCalculator
 * @notice Interface for reward calculation contract
 */
interface IRewardCalculator {
    function createPool(address rewardToken, uint256 yieldPercentage, uint256 stakeDuration, uint256 minStakeDuration) external returns (uint256 poolId);
    function updatePool(uint256 poolId, uint256 yieldPercentage, bool active) external;
    function fundPool(uint256 poolId, uint256 amount) external;
    function calculateAndStoreReward(uint256 tokenId, uint256 poolId, uint256 nftPrice) external returns (uint256 targetReward);
    function calculatePendingRewards(uint256 tokenId) external view returns (uint256);
    function processClaim(uint256 tokenId, address tokenOwner) external returns (uint256 amount);
    function processUnstake(uint256 tokenId, address tokenOwner) external returns (uint256 finalRewards, uint256 unusedRewards);
    function isPoolActive(uint256 poolId) external view returns (bool);
    function getPoolRewardToken(uint256 poolId) external view returns (address);
    function getAvailablePoolRewards(uint256 poolId) external view returns (uint256);
    function version() external pure returns (string memory);
}

/**
 * @title GovernanceNFTStaking
 * @author Enhanced Implementation V2.1.0 - Single Admin Deployment
 * @notice Production-ready NFT staking contract with comprehensive security and compatibility
 * @dev Fully compatible with StandardizedGovernanceNFT v2.0.0
 * @custom:deployment Single admin can deploy and configure, multi-sig optional
 */
contract GovernanceNFTStaking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== Version ==========
    string public constant VERSION = "2.1.0";

    // ========== Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ========== Constants ==========
    address public constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    uint256 public constant MAX_STAKES_PER_USER = 100;
    uint256 public constant VOTE_LOCK_DURATION = 3 days;
    uint256 public constant VOTE_LOCK_DURATION_ACTIVE_GOVERNANCE = 6 days;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant COMMITMENT_BLOCKS = 3; // Block-based delay for MEV protection
    uint256 public constant MAX_BATCH_SIZE = 50; // Max tokens per batch operation
    
    // Circuit breaker constants
    uint256 public constant MAX_DAILY_WITHDRAWALS = 1000 ether;
    uint256 public constant WITHDRAWAL_PERIOD = 1 days;

    // ========== Structs ==========
    struct StakeInfo {
        uint128 poolId;
        uint128 stakedAt;
        address owner;
        uint256 voteLockExpiry;
    }

    struct TimelockAction {
        address target;
        bytes data;
        uint256 executeTime;
        bool executed;
        bool cancelled;
    }

    struct StakeCommitment {
        bytes32 commitment;
        uint256 blockNumber;
    }

    struct WithdrawalTracker {
        uint256 amount;
        uint256 lastResetTime;
    }

    struct ExternalContractInfo {
        address contractAddress;
        string expectedVersion;
        bool isActive;
    }

    // ========== State Variables ==========
    IGovernanceNFT public immutable governanceNFT;
    ExternalContractInfo public governanceContractInfo;
    ExternalContractInfo public rewardCalculatorInfo;
    
    uint256 public timelockActionCounter;
    uint256 public totalStakedNFTs;
    uint256 public multiSigThreshold = 1; // CHANGED: Start with 1 for single admin deployment
    
    mapping(uint256 => StakeInfo) public stakes; // tokenId => stake info
    mapping(address => EnumerableSet.UintSet) private userStakedTokens;
    mapping(uint256 => uint256) public poolStakedCount;
    mapping(uint256 => TimelockAction) public timelockActions;
    mapping(uint256 => uint256) public poolETHBalances; // poolId => ETH balance
    mapping(address => StakeCommitment) public stakeCommitments; // user => commitment
    mapping(uint256 => WithdrawalTracker) public poolWithdrawalTrackers; // poolId => tracker
    mapping(bytes32 => uint256) public multiSigApprovals; // actionHash => approvalCount
    mapping(bytes32 => mapping(address => bool)) public hasApproved; // actionHash => admin => approved
    
    EnumerableSet.AddressSet private rewardTokenWhitelist;
    EnumerableSet.AddressSet private adminAddresses; // For multi-sig

    // ========== Events ==========
    event RewardCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator, string version);
    event GovernanceContractUpdated(address indexed oldContract, address indexed newContract, string version);
    
    event NFTStaked(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed poolId,
        uint256 targetReward
    );
    event NFTUnstaked(address indexed user, uint256 indexed tokenId, uint256 indexed poolId);
    event RewardsClaimed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event BatchRewardsClaimed(address indexed user, uint256 tokenCount, uint256 totalRewards);
    
    event RewardTokenWhitelisted(address indexed token);
    event RewardTokenDelisted(address indexed token);
    
    event TimelockActionScheduled(uint256 indexed actionId, address target, bytes data, uint256 executeTime);
    event TimelockActionExecuted(uint256 indexed actionId);
    event TimelockActionCancelled(uint256 indexed actionId);
    
    event GovernanceNotificationFailed(address indexed user, uint256 indexed tokenId, bool isStaking, string reason);
    event StakeCommitted(address indexed user, bytes32 commitment);
    
    event CircuitBreakerTriggered(uint256 indexed poolId, string reason);
    event MultiSigApproval(bytes32 indexed actionHash, address indexed approver, uint256 approvalCount);
    event MultiSigExecuted(bytes32 indexed actionHash, address indexed executor);

    // ========== Custom Errors ==========
    error InvalidAddress();
    error InvalidPool();
    error MaxStakesReached();
    error NotTokenOwner();
    error AlreadyStaked();
    error NotStaked();
    error NotYourStake();
    error ActiveProposal();
    error TransferFailed();
    error NFTPriceNotFound();
    error NoStakes();
    error TimelockNotReady();
    error ActionNotExists();
    error ActionExecuted();
    error ActionCancelled();
    error OnlyThroughTimelock();
    error AlreadyWhitelisted();
    error NotWhitelisted();
    error CalculatorNotSet();
    error InvalidCommitment();
    error CommitmentTooRecent();
    error NoCommitment();
    error ETHAmountMismatch();
    error InvalidAmount();
    error UnexpectedETH();
    error InsufficientETHBalance();
    error PoolNotExists();
    error InvalidBatchSize();
    error InvalidTokenContract();
    error ContractNotSet();
    error VersionMismatch();
    error WithdrawalLimitExceeded();
    error NotEnoughApprovals();
    error AlreadyApproved();
    error NotAdmin();

    // ========== Constructor ==========
    constructor(address _governanceNFT) {
        if (_governanceNFT == address(0)) revert InvalidAddress();
        
        // We can't use _isContract here because the contract isn't deployed yet
        // So we use inline assembly
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_governanceNFT)
        }
        if (codeSize == 0) revert InvalidAddress();
        
        governanceNFT = IGovernanceNFT(_governanceNFT);
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(POOL_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Add initial admin for multi-sig
        adminAddresses.add(msg.sender);
        
        // Whitelist ETH by default
        rewardTokenWhitelist.add(ETH_ADDRESS);
        emit RewardTokenWhitelisted(ETH_ADDRESS);
    }

    // ========== Version Function (NEW) ==========

    /**
     * @notice Get contract version
     * @return Contract version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ========== Modifiers ==========
    
    /**
     * @dev Ensures external contract is set and active
     */
    modifier onlyWithValidCalculator() {
        if (rewardCalculatorInfo.contractAddress == address(0)) revert CalculatorNotSet();
        if (!rewardCalculatorInfo.isActive) revert ContractNotSet();
        _;
    }

    /**
     * @dev Multi-sig modifier for critical functions
     * @custom:note Works with single admin when threshold is 1
     */
    modifier requiresMultiSig() {
        bytes32 actionHash = keccak256(abi.encode(msg.sender, msg.data, block.number));
        
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert NotAdmin();
        if (hasApproved[actionHash][msg.sender]) revert AlreadyApproved();
        
        hasApproved[actionHash][msg.sender] = true;
        multiSigApprovals[actionHash]++;
        
        emit MultiSigApproval(actionHash, msg.sender, multiSigApprovals[actionHash]);
        
        if (multiSigApprovals[actionHash] < multiSigThreshold) revert NotEnoughApprovals();
        
        emit MultiSigExecuted(actionHash, msg.sender);
        
        // Reset approvals
        delete multiSigApprovals[actionHash];
        address[] memory admins = adminAddresses.values();
        for (uint256 i = 0; i < admins.length; i++) {
            delete hasApproved[actionHash][admins[i]];
        }
        
        _;
    }

    // ========== IStakingSystem Implementation (NEW) ==========

    /**
     * @notice Get user's staking multiplier for voting power calculation
     * @param _user User address
     * @return multiplier Voting power multiplier in basis points (10000 = 1x)
     */
    function getUserMultiplier(address _user) external view returns (uint256 multiplier) {
        uint256 stakedCount = userStakedTokens[_user].length();
        if (stakedCount == 0) return 10000; // 1x multiplier
        
        // Example multiplier tiers:
        // 1-2 NFTs: 1.1x (11000)
        // 3-4 NFTs: 1.25x (12500)
        // 5-9 NFTs: 1.5x (15000)
        // 10-19 NFTs: 1.75x (17500)
        // 20+ NFTs: 2x (20000)
        
        if (stakedCount >= 20) return 20000;
        if (stakedCount >= 10) return 17500;
        if (stakedCount >= 5) return 15000;
        if (stakedCount >= 3) return 12500;
        return 11000;
    }

    // ========== IGovernanceStaking Implementation (NEW) ==========

    /**
     * @notice Get user's voting details (compatible with ProposalManager)
     * @param user User address
     * @return eligibleTokens Array of tokens eligible for voting
     * @return lockedTokens Array of tokens still in lock period
     */
    function getUserVotingDetails(address user) external view returns (
        uint256[] memory eligibleTokens,
        uint256[] memory lockedTokens
    ) {
        return getUserVotingDetailsPaginated(user, 0, MAX_BATCH_SIZE);
    }

    // ========== Configuration ==========

    /**
     * @notice Set the reward calculator contract with version check
     * @param _rewardCalculator Address of the reward calculator
     * @param _expectedVersion Expected version string
     */
    function setRewardCalculator(address _rewardCalculator, string memory _expectedVersion) external requiresMultiSig {
        if (_rewardCalculator == address(0)) revert InvalidAddress();
        if (!_isContract(_rewardCalculator)) revert InvalidAddress();
        
        // Version check
        try IRewardCalculator(_rewardCalculator).version() returns (string memory calculatorVersion) {
            if (keccak256(bytes(calculatorVersion)) != keccak256(bytes(_expectedVersion))) revert VersionMismatch();
        } catch {
            revert VersionMismatch();
        }
        
        address oldCalculator = rewardCalculatorInfo.contractAddress;
        
        rewardCalculatorInfo = ExternalContractInfo({
            contractAddress: _rewardCalculator,
            expectedVersion: _expectedVersion,
            isActive: true
        });
        
        emit RewardCalculatorUpdated(oldCalculator, _rewardCalculator, _expectedVersion);
    }

    /**
     * @notice Set the governance contract address with version check
     * @param _governanceContract Address of the governance contract
     * @param _expectedVersion Expected version string
     */
    function setGovernanceContract(address _governanceContract, string memory _expectedVersion) external requiresMultiSig {
        if (!_isContract(_governanceContract) && _governanceContract != address(0)) revert InvalidAddress();
        
        if (_governanceContract != address(0)) {
            try IGovernanceIntegration(_governanceContract).version() returns (string memory govVersion) {
                if (keccak256(bytes(govVersion)) != keccak256(bytes(_expectedVersion))) revert VersionMismatch();
            } catch {
                revert VersionMismatch();
            }
        }
        
        address oldContract = governanceContractInfo.contractAddress;
        
        governanceContractInfo = ExternalContractInfo({
            contractAddress: _governanceContract,
            expectedVersion: _expectedVersion,
            isActive: _governanceContract != address(0)
        });
        
        emit GovernanceContractUpdated(oldContract, _governanceContract, _expectedVersion);
    }

    /**
     * @notice Emergency circuit breaker for external contracts
     * @param _isCalculator True for calculator, false for governance
     * @param _active New active status
     */
    function setContractActive(bool _isCalculator, bool _active) external onlyRole(EMERGENCY_ROLE) {
        if (_isCalculator) {
            rewardCalculatorInfo.isActive = _active;
        } else {
            governanceContractInfo.isActive = _active;
        }
    }

    // ========== Pool Management ==========

    /**
     * @notice Create a new staking pool
     * @param _rewardToken Token address for rewards
     * @param _yieldPercentage Fixed yield percentage
     * @param _stakeDuration Duration to earn full yield
     * @param _minStakeDuration Minimum stake duration
     */
    function createPool(
        address _rewardToken,
        uint256 _yieldPercentage,
        uint256 _stakeDuration,
        uint256 _minStakeDuration
    ) external onlyRole(POOL_MANAGER_ROLE) onlyWithValidCalculator returns (uint256 poolId) {
        if (!rewardTokenWhitelist.contains(_rewardToken)) revert NotWhitelisted();
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        poolId = calculator.createPool(_rewardToken, _yieldPercentage, _stakeDuration, _minStakeDuration);
        
        // Initialize withdrawal tracker for new pool
        poolWithdrawalTrackers[poolId] = WithdrawalTracker({
            amount: 0,
            lastResetTime: block.timestamp
        });
    }

    /**
     * @notice Update pool parameters
     * @param _poolId Pool to update
     * @param _yieldPercentage New yield percentage
     * @param _active Pool active status
     */
    function updatePool(
        uint256 _poolId,
        uint256 _yieldPercentage,
        bool _active
    ) external onlyRole(POOL_MANAGER_ROLE) onlyWithValidCalculator {
        _validatePoolExists(_poolId);
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        calculator.updatePool(_poolId, _yieldPercentage, _active);
    }

    /**
     * @notice Fund a pool with rewards
     * @param _poolId Pool to fund
     * @param _amount Amount to deposit
     */
    function fundPool(uint256 _poolId, uint256 _amount) external payable nonReentrant onlyWithValidCalculator {
        _validatePoolExists(_poolId);
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        address rewardToken = calculator.getPoolRewardToken(_poolId);
        
        if (rewardToken == ETH_ADDRESS) {
            // Validate ETH amount matches
            if (msg.value != _amount) revert ETHAmountMismatch();
            if (msg.value == 0) revert InvalidAmount();
            // Keep ETH in this contract with proper accounting
            poolETHBalances[_poolId] += _amount;
            // Still notify calculator about the funding
            calculator.fundPool(_poolId, _amount);
        } else {
            if (msg.value > 0) revert UnexpectedETH();
            IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _amount);
            calculator.fundPool(_poolId, _amount);
        }
    }

    // ========== Staking Functions ==========

    /**
     * @notice Commit to stake an NFT (anti-MEV step 1)
     * @param _commitment Hash of stake parameters
     */
    function commitStake(bytes32 _commitment) external {
        stakeCommitments[msg.sender] = StakeCommitment({
            commitment: _commitment,
            blockNumber: block.number
        });
        emit StakeCommitted(msg.sender, _commitment);
    }

    /**
     * @notice Stake an NFT to earn rewards (anti-MEV step 2)
     * @param _tokenId NFT token ID
     * @param _poolId Pool ID to stake in
     * @param _nonce Random nonce used in commitment
     */
    function stake(uint256 _tokenId, uint256 _poolId, uint256 _nonce) external nonReentrant whenNotPaused onlyWithValidCalculator {
        // Verify commitment with block-based delay
        StakeCommitment memory commitment = stakeCommitments[msg.sender];
        if (commitment.commitment == bytes32(0)) revert NoCommitment();
        
        bytes32 expectedCommitment = keccak256(abi.encodePacked(msg.sender, _tokenId, _poolId, _nonce));
        if (commitment.commitment != expectedCommitment) revert InvalidCommitment();
        if (block.number < commitment.blockNumber + COMMITMENT_BLOCKS) revert CommitmentTooRecent();
        
        // Clear commitment
        delete stakeCommitments[msg.sender];
        
        // Continue with existing validations
        if (governanceNFT.ownerOf(_tokenId) != msg.sender) revert NotTokenOwner();
        if (userStakedTokens[msg.sender].length() >= MAX_STAKES_PER_USER) revert MaxStakesReached();
        if (stakes[_tokenId].stakedAt != 0) revert AlreadyStaked();
        
        // Validate pool exists
        _validatePoolExists(_poolId);
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        
        // Check governance proposal status
        if (governanceContractInfo.isActive && governanceContractInfo.contractAddress != address(0)) {
            IGovernanceIntegration govContract = IGovernanceIntegration(governanceContractInfo.contractAddress);
            if (govContract.isProposalActive(msg.sender)) revert ActiveProposal();
        }
        
        // Verify pool is active
        if (!calculator.isPoolActive(_poolId)) revert InvalidPool();
        
        // Get NFT price
        (uint256 nftPrice, ) = governanceNFT.getPurchasePrice(_tokenId);
        if (nftPrice == 0) revert NFTPriceNotFound();
        
        // Calculate and store reward
        uint256 targetReward = calculator.calculateAndStoreReward(_tokenId, _poolId, nftPrice);
        
        // Transfer NFT
        governanceNFT.transferFrom(msg.sender, address(this), _tokenId);
        
        // Dynamic lock based on governance activity
        uint256 lockDuration = VOTE_LOCK_DURATION;
        if (governanceContractInfo.isActive && governanceContractInfo.contractAddress != address(0)) {
            try IGovernanceIntegration(governanceContractInfo.contractAddress).hasActiveProposals() returns (bool hasActive) {
                if (hasActive) {
                    lockDuration = VOTE_LOCK_DURATION_ACTIVE_GOVERNANCE;
                }
            } catch {}
        }
        
        // Store stake info
        stakes[_tokenId] = StakeInfo({
            poolId: uint128(_poolId),
            stakedAt: uint128(block.timestamp),
            owner: msg.sender,
            voteLockExpiry: block.timestamp + lockDuration
        });
        
        // Update tracking
        userStakedTokens[msg.sender].add(_tokenId);
        poolStakedCount[_poolId]++;
        totalStakedNFTs++;
        
        // Safe governance notification
        _notifyGovernance(msg.sender, _tokenId, true);
        
        emit NFTStaked(msg.sender, _tokenId, _poolId, targetReward);
    }

    /**
     * @notice Unstake NFT and claim final rewards
     * @param _tokenId NFT token ID
     */
    function unstake(uint256 _tokenId) external nonReentrant onlyWithValidCalculator {
        if (!userStakedTokens[msg.sender].contains(_tokenId)) revert NotYourStake();
        
        StakeInfo memory stakeInfo = stakes[_tokenId];
        if (stakeInfo.stakedAt == 0) revert NotStaked();
        
        // Check governance proposal status
        if (governanceContractInfo.isActive && governanceContractInfo.contractAddress != address(0)) {
            IGovernanceIntegration govContract = IGovernanceIntegration(governanceContractInfo.contractAddress);
            if (govContract.isProposalActive(msg.sender)) revert ActiveProposal();
        }
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        
        // Process unstake and get rewards (FIXED: Added msg.sender parameter)
        (uint256 finalRewards, ) = calculator.processUnstake(_tokenId, msg.sender);
        
        // Distribute rewards if any
        if (finalRewards > 0) {
            address rewardToken = calculator.getPoolRewardToken(stakeInfo.poolId);
            _distributeRewards(msg.sender, rewardToken, finalRewards, stakeInfo.poolId);
            emit RewardsClaimed(msg.sender, _tokenId, finalRewards);
        }
        
        // Update tracking
        poolStakedCount[stakeInfo.poolId]--;
        userStakedTokens[msg.sender].remove(_tokenId);
        totalStakedNFTs--;
        delete stakes[_tokenId];
        
        // Return NFT
        governanceNFT.transferFrom(address(this), msg.sender, _tokenId);
        
        // Safe governance notification
        _notifyGovernance(msg.sender, _tokenId, false);
        
        emit NFTUnstaked(msg.sender, _tokenId, stakeInfo.poolId);
    }

    /**
     * @notice Claim pending rewards without unstaking
     * @param _tokenId NFT token ID
     */
    function claimRewards(uint256 _tokenId) external nonReentrant onlyWithValidCalculator {
        if (!userStakedTokens[msg.sender].contains(_tokenId)) revert NotYourStake();
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        StakeInfo memory stakeInfo = stakes[_tokenId];
        
        // FIXED: Added msg.sender parameter
        uint256 amount = calculator.processClaim(_tokenId, msg.sender);
        
        if (amount > 0) {
            address rewardToken = calculator.getPoolRewardToken(stakeInfo.poolId);
            _distributeRewards(msg.sender, rewardToken, amount, stakeInfo.poolId);
            emit RewardsClaimed(msg.sender, _tokenId, amount);
        }
    }

    /**
     * @notice Claim rewards for multiple tokens with pagination
     * @param _startIndex Start index in user's token list
     * @param _count Number of tokens to process (max MAX_BATCH_SIZE)
     */
    function claimBatchRewards(uint256 _startIndex, uint256 _count) external nonReentrant onlyWithValidCalculator {
        uint256[] memory allTokenIds = userStakedTokens[msg.sender].values();
        if (allTokenIds.length == 0) revert NoStakes();
        if (_count > MAX_BATCH_SIZE) revert InvalidBatchSize();
        
        uint256 endIndex = _startIndex + _count;
        if (endIndex > allTokenIds.length) {
            endIndex = allTokenIds.length;
        }
        
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        uint256 totalClaimed = 0;
        uint256 tokensProcessed = 0;
        
        for (uint256 i = _startIndex; i < endIndex; i++) {
            uint256 tokenId = allTokenIds[i];
            StakeInfo memory stakeInfo = stakes[tokenId];
            
            // FIXED: Added msg.sender parameter
            uint256 amount = calculator.processClaim(tokenId, msg.sender);
            
            if (amount > 0) {
                address rewardToken = calculator.getPoolRewardToken(stakeInfo.poolId);
                _distributeRewards(msg.sender, rewardToken, amount, stakeInfo.poolId);
                totalClaimed += amount;
                emit RewardsClaimed(msg.sender, tokenId, amount);
            }
            tokensProcessed++;
        }
        
        if (totalClaimed > 0) {
            emit BatchRewardsClaimed(msg.sender, tokensProcessed, totalClaimed);
        }
    }

    // ========== Internal Functions ==========

    /**
     * @notice Check if an address is a contract
     * @param _addr Address to check
     * @return Whether the address is a contract
     */
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /**
     * @notice Distribute rewards to user with proper accounting
     * @param _to Recipient address
     * @param _token Token address
     * @param _amount Amount to transfer
     * @param _poolId Pool ID (for ETH tracking)
     */
    function _distributeRewards(address _to, address _token, uint256 _amount, uint256 _poolId) internal {
        if (_amount == 0) return;
        
        // Check withdrawal limits (circuit breaker)
        _checkWithdrawalLimit(_poolId, _amount);
        
        if (_token == ETH_ADDRESS) {
            // Check ETH balance before deduction
            if (poolETHBalances[_poolId] < _amount) revert InsufficientETHBalance();
            
            // Deduct from pool balance tracking
            poolETHBalances[_poolId] -= _amount;
            
            // Transfer ETH
            (bool success, ) = _to.call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Check and update withdrawal limits
     * @param _poolId Pool ID
     * @param _amount Withdrawal amount
     */
    function _checkWithdrawalLimit(uint256 _poolId, uint256 _amount) internal {
        WithdrawalTracker storage tracker = poolWithdrawalTrackers[_poolId];
        
        // Reset daily limit if needed
        if (block.timestamp >= tracker.lastResetTime + WITHDRAWAL_PERIOD) {
            tracker.amount = 0;
            tracker.lastResetTime = block.timestamp;
        }
        
        // Check limit
        if (tracker.amount + _amount > MAX_DAILY_WITHDRAWALS) {
            emit CircuitBreakerTriggered(_poolId, "Daily withdrawal limit exceeded");
            revert WithdrawalLimitExceeded();
        }
        
        tracker.amount += _amount;
    }

    /**
     * @notice Validate pool exists
     * @param _poolId Pool ID to validate
     */
    function _validatePoolExists(uint256 _poolId) internal view {
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        address rewardToken = calculator.getPoolRewardToken(_poolId);
        if (rewardToken == address(0)) revert PoolNotExists();
    }

    /**
     * @notice Safely notify governance of stake updates
     * @param _user User address
     * @param _tokenId Token ID
     * @param _isStaking Whether staking or unstaking
     */
    function _notifyGovernance(address _user, uint256 _tokenId, bool _isStaking) internal {
        if (!governanceContractInfo.isActive || governanceContractInfo.contractAddress == address(0)) {
            return;
        }
        
        try IGovernanceIntegration(governanceContractInfo.contractAddress).notifyStakeUpdate(_user, _tokenId, _isStaking) {
            // Success - no action needed
        } catch Error(string memory reason) {
            emit GovernanceNotificationFailed(_user, _tokenId, _isStaking, reason);
        } catch {
            emit GovernanceNotificationFailed(_user, _tokenId, _isStaking, "Unknown error");
        }
    }

    // ========== View Functions ==========

    /**
     * @notice Get total staked NFTs
     * @return Total number of staked NFTs
     */
    function getTotalStakedNFTs() external view returns (uint256) {
        return totalStakedNFTs;
    }

    /**
     * @notice Get user's voting power
     * @param _user User address
     * @return votingPower Number of eligible votes
     */
    function getVotingPower(address _user) external view returns (uint256 votingPower) {
        uint256[] memory tokenIds = userStakedTokens[_user].values();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (block.timestamp >= stakes[tokenIds[i]].voteLockExpiry) {
                votingPower++;
            }
        }
    }

    /**
     * @notice Get paginated user voting details
     * @param _user User address
     * @param _startIndex Start index
     * @param _count Number to return (max MAX_BATCH_SIZE)
     */
    function getUserVotingDetailsPaginated(
        address _user,
        uint256 _startIndex,
        uint256 _count
    ) public view returns (
        uint256[] memory eligibleTokens,
        uint256[] memory lockedTokens
    ) {
        if (_count > MAX_BATCH_SIZE) revert InvalidBatchSize();
        
        uint256[] memory allTokens = userStakedTokens[_user].values();
        uint256 endIndex = _startIndex + _count;
        if (endIndex > allTokens.length) {
            endIndex = allTokens.length;
        }
        
        uint256 eligibleCount = 0;
        uint256 lockedCount = 0;
        
        // First pass: count
        for (uint256 i = _startIndex; i < endIndex; i++) {
            if (block.timestamp >= stakes[allTokens[i]].voteLockExpiry) {
                eligibleCount++;
            } else {
                lockedCount++;
            }
        }
        
        // Allocate arrays
        eligibleTokens = new uint256[](eligibleCount);
        lockedTokens = new uint256[](lockedCount);
        
        // Second pass: populate
        uint256 eligibleIndex = 0;
        uint256 lockedIndex = 0;
        
        for (uint256 i = _startIndex; i < endIndex; i++) {
            if (block.timestamp >= stakes[allTokens[i]].voteLockExpiry) {
                eligibleTokens[eligibleIndex++] = allTokens[i];
            } else {
                lockedTokens[lockedIndex++] = allTokens[i];
            }
        }
    }

    /**
     * @notice Get user's staked tokens
     * @param _user User address
     * @return tokenIds Array of staked token IDs
     */
    function getUserStakedTokens(address _user) external view returns (uint256[] memory) {
        return userStakedTokens[_user].values();
    }

    /**
     * @notice Get whitelisted tokens
     * @return tokens Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory) {
        return rewardTokenWhitelist.values();
    }

    /**
     * @notice Get pending rewards for a token
     * @param _tokenId NFT token ID
     * @return pendingRewards Amount pending
     */
    function getPendingRewards(uint256 _tokenId) external view returns (uint256) {
        if (rewardCalculatorInfo.contractAddress == address(0)) return 0;
        IRewardCalculator calculator = IRewardCalculator(rewardCalculatorInfo.contractAddress);
        return calculator.calculatePendingRewards(_tokenId);
    }

    /**
     * @notice Get pool ETH balance
     * @param _poolId Pool ID
     * @return balance ETH balance
     */
    function getPoolETHBalance(uint256 _poolId) external view returns (uint256) {
        return poolETHBalances[_poolId];
    }

    /**
     * @notice Get stake information for a token
     * @param _tokenId NFT token ID
     * @return stakeInfo Stake details
     */
    function getStakeInfo(uint256 _tokenId) external view returns (StakeInfo memory) {
        return stakes[_tokenId];
    }

    /**
     * @notice Get pool staked count
     * @param _poolId Pool ID
     * @return count Number of NFTs staked in pool
     */
    function getPoolStakedCount(uint256 _poolId) external view returns (uint256) {
        return poolStakedCount[_poolId];
    }

    /**
     * @notice Check if a token is ERC20 compliant
     * @param _token Token address to check
     * @return isValid Whether token appears to be valid ERC20
     */
    function isValidERC20(address _token) public view returns (bool isValid) {
        if (_token == ETH_ADDRESS) return true;
        if (!_isContract(_token)) return false;
        
        // Check for basic ERC20 functions
        bytes memory payload = abi.encodeWithSignature("totalSupply()");
        (bool success, ) = _token.staticcall(payload);
        
        return success;
    }

    /**
     * @notice Get multi-sig threshold
     * @return threshold Current multi-sig threshold
     */
    function getMultiSigThreshold() external view returns (uint256) {
        return multiSigThreshold;
    }

    /**
     * @notice Get admin addresses
     * @return admins Array of admin addresses
     */
    function getAdminAddresses() external view returns (address[] memory) {
        return adminAddresses.values();
    }

    // ========== Admin Functions ==========

    /**
     * @notice Add admin for multi-sig
     * @param _admin Admin address to add
     */
    function addAdmin(address _admin) external requiresMultiSig {
        if (_admin == address(0)) revert InvalidAddress();
        _grantRole(ADMIN_ROLE, _admin);
        adminAddresses.add(_admin);
    }

    /**
     * @notice Remove admin from multi-sig
     * @param _admin Admin address to remove
     */
    function removeAdmin(address _admin) external requiresMultiSig {
        _revokeRole(ADMIN_ROLE, _admin);
        adminAddresses.remove(_admin);
    }

    /**
     * @notice Update multi-sig threshold
     * @param _newThreshold New threshold value
     */
    function updateMultiSigThreshold(uint256 _newThreshold) external requiresMultiSig {
        if (_newThreshold == 0 || _newThreshold > adminAddresses.length()) revert InvalidAmount();
        multiSigThreshold = _newThreshold;
    }

    /**
     * @notice Whitelist a reward token
     * @param _token Token to whitelist
     */
    function whitelistRewardToken(address _token) external onlyRole(ADMIN_ROLE) {
        if (!isValidERC20(_token)) revert InvalidTokenContract();
        
        bytes memory data = abi.encodeWithSelector(this.whitelistRewardTokenDirect.selector, _token);
        _scheduleTimelockAction(address(this), data);
    }

    /**
     * @notice Direct token whitelisting (only through timelock)
     * @param _token Token address
     */
    function whitelistRewardTokenDirect(address _token) external {
        if (msg.sender != address(this)) revert OnlyThroughTimelock();
        if (rewardTokenWhitelist.contains(_token)) revert AlreadyWhitelisted();
        
        rewardTokenWhitelist.add(_token);
        emit RewardTokenWhitelisted(_token);
    }

    /**
     * @notice Remove token from whitelist
     * @param _token Token to delist
     */
    function delistRewardToken(address _token) external onlyRole(ADMIN_ROLE) {
        bytes memory data = abi.encodeWithSelector(this.delistRewardTokenDirect.selector, _token);
        _scheduleTimelockAction(address(this), data);
    }

    /**
     * @notice Direct token delisting (only through timelock)
     * @param _token Token address
     */
    function delistRewardTokenDirect(address _token) external {
        if (msg.sender != address(this)) revert OnlyThroughTimelock();
        if (!rewardTokenWhitelist.contains(_token)) revert NotWhitelisted();
        
        rewardTokenWhitelist.remove(_token);
        emit RewardTokenDelisted(_token);
    }

    /**
     * @notice Schedule a timelocked action
     * @param _target Target address
     * @param _data Call data
     * @return actionId Action ID
     */
    function _scheduleTimelockAction(address _target, bytes memory _data) internal returns (uint256 actionId) {
        actionId = ++timelockActionCounter;
        
        timelockActions[actionId] = TimelockAction({
            target: _target,
            data: _data,
            executeTime: block.timestamp + TIMELOCK_DELAY,
            executed: false,
            cancelled: false
        });
        
        emit TimelockActionScheduled(actionId, _target, _data, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Execute a timelocked action
     * @param _actionId Action ID
     */
    function executeTimelockAction(uint256 _actionId) external onlyRole(ADMIN_ROLE) {
        TimelockAction storage action = timelockActions[_actionId];
        
        if (action.executeTime == 0) revert ActionNotExists();
        if (block.timestamp < action.executeTime) revert TimelockNotReady();
        if (action.executed) revert ActionExecuted();
        if (action.cancelled) revert ActionCancelled();
        
        action.executed = true;
        
        (bool success, bytes memory result) = action.target.call(action.data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    let resultSize := mload(result)
                    revert(add(32, result), resultSize)
                }
            } else {
                revert TransferFailed();
            }
        }
        
        emit TimelockActionExecuted(_actionId);
    }

    /**
     * @notice Cancel a timelocked action
     * @param _actionId Action ID
     */
    function cancelTimelockAction(uint256 _actionId) external onlyRole(ADMIN_ROLE) {
        TimelockAction storage action = timelockActions[_actionId];
        
        if (action.executeTime == 0) revert ActionNotExists();
        if (action.executed) revert ActionExecuted();
        if (action.cancelled) revert ActionCancelled();
        
        action.cancelled = true;
        emit TimelockActionCancelled(_actionId);
    }

    // ========== Emergency Functions ==========

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract (requires multi-sig)
     */
    function unpause() external requiresMultiSig {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal override (requires multi-sig)
     * @param _poolId Pool ID
     */
    function resetWithdrawalLimit(uint256 _poolId) external requiresMultiSig {
        poolWithdrawalTrackers[_poolId] = WithdrawalTracker({
            amount: 0,
            lastResetTime: block.timestamp
        });
    }

    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}
