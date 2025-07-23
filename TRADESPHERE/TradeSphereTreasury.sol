// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./TradeSphereOracle.sol";
import "./FeedConsumer.sol";

/**
 * @title TradeSphere Treasury
 * @notice Central treasury management for the TradeSphere ecosystem
 * @dev Handles revenue collection, distribution, staking, and financial operations
 */
contract TradeSphereTreasury is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ============ Constants ============
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_ALLOCATION_POINTS = 10000;
    uint256 public constant MIN_STAKE_AMOUNT = 100 * 10**18; // 100 CIFI
    uint256 public constant LOCK_PERIOD = 7 days;
    uint256 public constant COMPOUND_PERIOD = 1 days;
    uint256 public constant MAX_BENEFICIARIES = 10;
    
    // ============ State Variables ============
    IERC20 public immutable cifiToken;
    TradeSphereOracle public tradeSphereOracle;
    
    // Revenue tracking
    mapping(address => RevenueSource) public revenueSources;
    address[] public registeredSources;
    uint256 public totalRevenue;
    uint256 public totalDistributed;
    
    // Allocation management
    mapping(address => Allocation) public allocations;
    address[] public beneficiaries;
    uint256 public totalAllocationPoints;
    
    // Staking system
    mapping(address => StakeInfo) public stakes;
    uint256 public totalStaked;
    uint256 public rewardRate; // Rewards per second per token
    uint256 public lastRewardUpdate;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    // Fee structure
    FeeStructure public fees;
    
    // Financial metrics
    FinancialMetrics public metrics;
    mapping(uint256 => EpochData) public epochData;
    uint256 public currentEpoch;
    uint256 public epochDuration = 30 days;
    uint256 public lastEpochTimestamp;
    
    // Emergency fund
    uint256 public emergencyFundBalance;
    uint256 public emergencyFundTarget;
    
    // Budget management
    mapping(string => Budget) public budgets;
    string[] public budgetCategories;
    
    // Withdrawal management
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    uint256 public withdrawalDelay = 48 hours;
    
    // ============ Structs ============
    struct RevenueSource {
        bool isActive;
        string sourceName;
        uint256 totalCollected;
        uint256 lastCollection;
        address contractAddress;
    }
    
    struct Allocation {
        address beneficiary;
        uint256 allocationPoints;
        string purpose;
        bool isActive;
        uint256 totalReceived;
        uint256 lastClaim;
        bool autoDistribute;
    }
    
    struct StakeInfo {
        uint256 amount;
        uint256 lockEndTime;
        uint256 lastStakeTime;
        uint256 tier; // 0: Bronze, 1: Silver, 2: Gold, 3: Platinum
        uint256 multiplier; // Basis points
    }
    
    struct FeeStructure {
        uint256 stakingRewardsFee;    // BP allocated to staking rewards
        uint256 emergencyFundFee;     // BP allocated to emergency fund
        uint256 operationalFee;       // BP for operational expenses
        uint256 developmentFee;       // BP for development
        uint256 marketingFee;         // BP for marketing
    }
    
    struct FinancialMetrics {
        uint256 totalRevenueAllTime;
        uint256 totalDistributedAllTime;
        uint256 averageDailyRevenue;
        uint256 currentBalance;
        uint256 projectedMonthlyRevenue;
    }
    
    struct EpochData {
        uint256 revenue;
        uint256 distributed;
        uint256 staked;
        uint256 activeUsers;
        uint256 timestamp;
    }
    
    struct Budget {
        uint256 allocated;
        uint256 spent;
        uint256 period; // In seconds
        uint256 lastReset;
        bool isActive;
    }
    
    struct WithdrawalRequest {
        uint256 amount;
        uint256 requestTime;
        bool executed;
        string reason;
    }
    
    struct TreasuryConfig {
        uint256 stakingRewardsFee;
        uint256 emergencyFundFee;
        uint256 operationalFee;
        uint256 developmentFee;
        uint256 marketingFee;
        uint256 emergencyFundTarget;
        uint256 epochDuration;
    }
    
    // ============ Events ============
    event RevenueCollected(
        address indexed source,
        uint256 amount,
        uint256 timestamp
    );
    
    event RevenueDistributed(
        address indexed beneficiary,
        uint256 amount,
        string purpose
    );
    
    event AllocationUpdated(
        address indexed beneficiary,
        uint256 oldPoints,
        uint256 newPoints
    );
    
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 lockEndTime,
        uint256 tier
    );
    
    event Unstaked(
        address indexed user,
        uint256 amount
    );
    
    event RewardPaid(
        address indexed user,
        uint256 reward
    );
    
    event EmergencyWithdrawal(
        address indexed to,
        uint256 amount,
        string reason
    );
    
    event BudgetUpdated(
        string category,
        uint256 allocated,
        uint256 period
    );
    
    event WithdrawalRequested(
        address indexed requester,
        uint256 amount,
        string reason
    );
    
    event WithdrawalExecuted(
        address indexed requester,
        uint256 amount
    );
    
    event EpochCompleted(
        uint256 indexed epoch,
        uint256 revenue,
        uint256 distributed
    );
    
    event MetricsUpdated(
        uint256 totalRevenue,
        uint256 totalDistributed,
        uint256 currentBalance
    );
    
    // ============ Errors ============
    error InvalidConfiguration();
    error UnauthorizedAccess();
    error InsufficientBalance();
    error AllocationExceedsLimit();
    error StakeLocked();
    error WithdrawalPending();
    error BudgetExceeded();
    error InvalidAmount();
    error SourceNotRegistered();
    error MaxBeneficiariesReached();

    // ============ Constructor ============
    constructor(
        address _cifiToken,
        address _admin,
        TreasuryConfig memory _config
    ) {
        if (_cifiToken == address(0) || _admin == address(0)) {
            revert InvalidConfiguration();
        }
        
        cifiToken = IERC20(_cifiToken);
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(TREASURER_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        // Initialize fee structure
        fees = FeeStructure({
            stakingRewardsFee: _config.stakingRewardsFee,
            emergencyFundFee: _config.emergencyFundFee,
            operationalFee: _config.operationalFee,
            developmentFee: _config.developmentFee,
            marketingFee: _config.marketingFee
        });
        
        // Validate fee structure
        uint256 totalFees = fees.stakingRewardsFee + 
                           fees.emergencyFundFee + 
                           fees.operationalFee + 
                           fees.developmentFee + 
                           fees.marketingFee;
        
        if (totalFees > BASIS_POINTS) revert InvalidConfiguration();
        
        emergencyFundTarget = _config.emergencyFundTarget;
        epochDuration = _config.epochDuration;
        lastEpochTimestamp = block.timestamp;
        
        // Initialize default budgets
        _initializeDefaultBudgets();
    }

    // ============ Revenue Management ============

    /**
     * @notice Register a new revenue source
     * @param source The source contract address
     * @param sourceName The name of the revenue source
     */
    function registerRevenueSource(
        address source,
        string calldata sourceName
    ) external onlyRole(TREASURER_ROLE) {
        if (source == address(0)) revert InvalidConfiguration();
        if (revenueSources[source].isActive) revert InvalidConfiguration();
        
        revenueSources[source] = RevenueSource({
            isActive: true,
            sourceName: sourceName,
            totalCollected: 0,
            lastCollection: block.timestamp,
            contractAddress: source
        });
        
        registeredSources.push(source);
    }

    /**
     * @notice Collect revenue from TradeSphereOracle
     */
    function collectFromOracle() external nonReentrant {
        if (address(tradeSphereOracle) == address(0)) revert InvalidConfiguration();
        
        uint256 balance = cifiToken.balanceOf(address(tradeSphereOracle));
        if (balance == 0) revert InsufficientBalance();
        
        // Request withdrawal from oracle
        tradeSphereOracle.withdrawToTreasury(address(this), balance);
        
        _processRevenue(address(tradeSphereOracle), balance);
    }

    /**
     * @notice Collect revenue from a FeedConsumer
     * @param feedConsumer The FeedConsumer contract address
     */
    function collectFromFeedConsumer(address feedConsumer) external nonReentrant {
        if (!revenueSources[feedConsumer].isActive) revert SourceNotRegistered();
        
        uint256 balance = feedConsumer.balance;
        if (balance == 0) revert InsufficientBalance();
        
        // FeedConsumer should have a withdrawal function
        (bool success, ) = feedConsumer.call(
            abi.encodeWithSignature("withdrawToTreasury()")
        );
        require(success, "Collection failed");
        
        _processRevenue(feedConsumer, balance);
    }

    /**
     * @notice Process incoming revenue
     * @param source The revenue source
     * @param amount The amount collected
     */
    function _processRevenue(address source, uint256 amount) internal {
        revenueSources[source].totalCollected += amount;
        revenueSources[source].lastCollection = block.timestamp;
        
        totalRevenue += amount;
        metrics.totalRevenueAllTime += amount;
        metrics.currentBalance = cifiToken.balanceOf(address(this));
        
        // Update epoch data
        epochData[currentEpoch].revenue += amount;
        
        // Distribute according to fee structure
        _distributeRevenue(amount);
        
        emit RevenueCollected(source, amount, block.timestamp);
        emit MetricsUpdated(
            metrics.totalRevenueAllTime,
            metrics.totalDistributedAllTime,
            metrics.currentBalance
        );
    }

    /**
     * @notice Distribute revenue according to fee structure
     * @param amount The amount to distribute
     */
    function _distributeRevenue(uint256 amount) internal {
        // Emergency fund allocation
        if (emergencyFundBalance < emergencyFundTarget) {
            uint256 emergencyAllocation = amount.mul(fees.emergencyFundFee).div(BASIS_POINTS);
            emergencyFundBalance += emergencyAllocation;
        }
        
        // Staking rewards allocation
        uint256 stakingAllocation = amount.mul(fees.stakingRewardsFee).div(BASIS_POINTS);
        if (totalStaked > 0) {
            _updateRewardRate(stakingAllocation);
        }
        
        // Auto-distribute to beneficiaries
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];
            Allocation storage alloc = allocations[beneficiary];
            
            if (alloc.isActive && alloc.autoDistribute) {
                uint256 share = amount.mul(alloc.allocationPoints).div(totalAllocationPoints);
                if (share > 0) {
                    cifiToken.safeTransfer(beneficiary, share);
                    alloc.totalReceived += share;
                    alloc.lastClaim = block.timestamp;
                    totalDistributed += share;
                    
                    emit RevenueDistributed(beneficiary, share, alloc.purpose);
                }
            }
        }
    }

    // ============ Allocation Management ============

    /**
     * @notice Add or update an allocation
     * @param beneficiary The beneficiary address
     * @param allocationPoints The allocation points (out of 10000)
     * @param purpose The allocation purpose
     * @param autoDistribute Whether to auto-distribute
     */
    function setAllocation(
        address beneficiary,
        uint256 allocationPoints,
        string calldata purpose,
        bool autoDistribute
    ) external onlyRole(TREASURER_ROLE) {
        if (beneficiary == address(0)) revert InvalidConfiguration();
        if (allocationPoints > MAX_ALLOCATION_POINTS) revert AllocationExceedsLimit();
        
        Allocation storage alloc = allocations[beneficiary];
        uint256 oldPoints = alloc.allocationPoints;
        
        // Add to beneficiaries if new
        if (!alloc.isActive && allocationPoints > 0) {
            if (beneficiaries.length >= MAX_BENEFICIARIES) revert MaxBeneficiariesReached();
            beneficiaries.push(beneficiary);
        }
        
        // Update allocation
        alloc.beneficiary = beneficiary;
        alloc.allocationPoints = allocationPoints;
        alloc.purpose = purpose;
        alloc.isActive = allocationPoints > 0;
        alloc.autoDistribute = autoDistribute;
        
        // Update total points
        totalAllocationPoints = totalAllocationPoints.sub(oldPoints).add(allocationPoints);
        
        emit AllocationUpdated(beneficiary, oldPoints, allocationPoints);
    }

    /**
     * @notice Manual distribution to beneficiaries
     * @param beneficiary The beneficiary address
     * @param amount The amount to distribute
     */
    function distribute(
        address beneficiary,
        uint256 amount
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        if (!allocations[beneficiary].isActive) revert UnauthorizedAccess();
        if (amount > cifiToken.balanceOf(address(this))) revert InsufficientBalance();
        
        Allocation storage alloc = allocations[beneficiary];
        
        cifiToken.safeTransfer(beneficiary, amount);
        alloc.totalReceived += amount;
        alloc.lastClaim = block.timestamp;
        totalDistributed += amount;
        metrics.totalDistributedAllTime += amount;
        
        emit RevenueDistributed(beneficiary, amount, alloc.purpose);
    }

    // ============ Staking System ============

    /**
     * @notice Stake CIFI tokens
     * @param amount The amount to stake
     * @param lockDuration The lock duration in seconds
     */
    function stake(uint256 amount, uint256 lockDuration) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (amount < MIN_STAKE_AMOUNT) revert InvalidAmount();
        
        _updateReward(msg.sender);
        
        // Transfer tokens
        cifiToken.safeTransferFrom(msg.sender, address(this), amount);
        
        StakeInfo storage stakeInfo = stakes[msg.sender];
        stakeInfo.amount += amount;
        stakeInfo.lockEndTime = block.timestamp + lockDuration;
        stakeInfo.lastStakeTime = block.timestamp;
        
        // Determine tier and multiplier based on amount and duration
        (uint256 tier, uint256 multiplier) = _calculateStakingTier(
            stakeInfo.amount,
            lockDuration
        );
        stakeInfo.tier = tier;
        stakeInfo.multiplier = multiplier;
        
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, stakeInfo.lockEndTime, tier);
    }

    /**
     * @notice Unstake CIFI tokens
     * @param amount The amount to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage stakeInfo = stakes[msg.sender];
        
        if (amount > stakeInfo.amount) revert InvalidAmount();
        if (block.timestamp < stakeInfo.lockEndTime) revert StakeLocked();
        
        _updateReward(msg.sender);
        
        stakeInfo.amount -= amount;
        totalStaked -= amount;
        
        // Update tier if necessary
        if (stakeInfo.amount > 0) {
            uint256 remainingLock = stakeInfo.lockEndTime > block.timestamp ? 
                stakeInfo.lockEndTime - block.timestamp : 0;
            (uint256 tier, uint256 multiplier) = _calculateStakingTier(
                stakeInfo.amount,
                remainingLock
            );
            stakeInfo.tier = tier;
            stakeInfo.multiplier = multiplier;
        }
        
        cifiToken.safeTransfer(msg.sender, amount);
        
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim staking rewards
     */
    function claimRewards() external nonReentrant {
        _updateReward(msg.sender);
        
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            cifiToken.safeTransfer(msg.sender, reward);
            
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Calculate staking tier and multiplier
     * @param amount The staked amount
     * @param lockDuration The lock duration
     * @return tier The staking tier
     * @return multiplier The reward multiplier
     */
    function _calculateStakingTier(
        uint256 amount,
        uint256 lockDuration
    ) internal pure returns (uint256 tier, uint256 multiplier) {
        // Tier calculation based on amount and duration
        if (amount >= 10000 * 10**18 && lockDuration >= 365 days) {
            tier = 3; // Platinum
            multiplier = 20000; // 2x multiplier
        } else if (amount >= 5000 * 10**18 && lockDuration >= 180 days) {
            tier = 2; // Gold
            multiplier = 15000; // 1.5x multiplier
        } else if (amount >= 1000 * 10**18 && lockDuration >= 90 days) {
            tier = 1; // Silver
            multiplier = 12500; // 1.25x multiplier
        } else {
            tier = 0; // Bronze
            multiplier = 10000; // 1x multiplier
        }
    }

    /**
     * @notice Update reward calculations
     * @param account The account to update
     */
    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastRewardUpdate = block.timestamp;
        
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /**
     * @notice Update the reward rate
     * @param rewardAmount The new rewards to add
     */
    function _updateRewardRate(uint256 rewardAmount) internal {
        _updateReward(address(0));
        
        if (block.timestamp >= lastRewardUpdate) {
            rewardRate = rewardAmount.div(COMPOUND_PERIOD);
        }
        lastRewardUpdate = block.timestamp;
    }

    /**
     * @notice Calculate reward per token
     * @return The reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        
        return rewardPerTokenStored.add(
            block.timestamp
                .sub(lastRewardUpdate)
                .mul(rewardRate)
                .mul(1e18)
                .div(totalStaked)
        );
    }

    /**
     * @notice Calculate earned rewards
     * @param account The account to check
     * @return The earned rewards
     */
    function earned(address account) public view returns (uint256) {
        StakeInfo memory stakeInfo = stakes[account];
        
        return stakeInfo.amount
            .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
            .div(1e18)
            .mul(stakeInfo.multiplier)
            .div(BASIS_POINTS)
            .add(rewards[account]);
    }

    // ============ Budget Management ============

    /**
     * @notice Set a budget for a category
     * @param category The budget category
     * @param allocated The allocated amount
     * @param period The budget period in seconds
     */
    function setBudget(
        string calldata category,
        uint256 allocated,
        uint256 period
    ) external onlyRole(TREASURER_ROLE) {
        Budget storage budget = budgets[category];
        
        if (!budget.isActive) {
            budgetCategories.push(category);
        }
        
        budget.allocated = allocated;
        budget.period = period;
        budget.isActive = true;
        budget.lastReset = block.timestamp;
        
        emit BudgetUpdated(category, allocated, period);
    }

    /**
     * @notice Spend from a budget
     * @param category The budget category
     * @param amount The amount to spend
     * @param recipient The recipient address
     */
    function spendFromBudget(
        string calldata category,
        uint256 amount,
        address recipient
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        Budget storage budget = budgets[category];
        
        if (!budget.isActive) revert InvalidConfiguration();
        
        // Reset budget if period has passed
        if (block.timestamp >= budget.lastReset + budget.period) {
            budget.spent = 0;
            budget.lastReset = block.timestamp;
        }
        
        if (budget.spent + amount > budget.allocated) revert BudgetExceeded();
        
        budget.spent += amount;
        cifiToken.safeTransfer(recipient, amount);
        
        totalDistributed += amount;
        metrics.totalDistributedAllTime += amount;
    }

    // ============ Withdrawal Management ============

    /**
     * @notice Request a withdrawal
     * @param amount The amount to withdraw
     * @param reason The withdrawal reason
     */
    function requestWithdrawal(
        uint256 amount,
        string calldata reason
    ) external onlyRole(TREASURER_ROLE) {
        if (withdrawalRequests[msg.sender].requestTime > 0 && 
            !withdrawalRequests[msg.sender].executed) {
            revert WithdrawalPending();
        }
        
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amount,
            requestTime: block.timestamp,
            executed: false,
            reason: reason
        });
        
        emit WithdrawalRequested(msg.sender, amount, reason);
    }

    /**
     * @notice Execute a pending withdrawal
     */
    function executeWithdrawal() external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        
        if (request.requestTime == 0) revert InvalidConfiguration();
        if (request.executed) revert InvalidConfiguration();
        if (block.timestamp < request.requestTime + withdrawalDelay) {
            revert WithdrawalPending();
        }
        
        request.executed = true;
        cifiToken.safeTransfer(msg.sender, request.amount);
        
        emit WithdrawalExecuted(msg.sender, request.amount);
    }

    // ============ Emergency Functions ============

    /**
     * @notice Emergency withdrawal from treasury
     * @param to The recipient address
     * @param amount The amount to withdraw
     * @param reason The emergency reason
     */
    function emergencyWithdraw(
        address to,
        uint256 amount,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidConfiguration();
        if (amount > emergencyFundBalance) revert InsufficientBalance();
        
        emergencyFundBalance -= amount;
        cifiToken.safeTransfer(to, amount);
        
        emit EmergencyWithdrawal(to, amount, reason);
    }

    /**
     * @notice Pause all operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get complete treasury statistics
     * @return stats The financial metrics
     * @return epochInfo Current epoch data
     * @return balance Current treasury balance
     */
    function getTreasuryStats() external view returns (
        FinancialMetrics memory stats,
        EpochData memory epochInfo,
        uint256 balance
    ) {
        stats = metrics;
        epochInfo = epochData[currentEpoch];
        balance = cifiToken.balanceOf(address(this));
    }

    /**
     * @notice Get revenue source details
     * @param source The source address
     * @return info The revenue source information
     */
    function getRevenueSource(address source) 
        external 
        view 
        returns (RevenueSource memory) 
    {
        return revenueSources[source];
    }

    /**
     * @notice Get all beneficiaries
     * @return beneficiaryList The list of beneficiaries
     * @return allocationList Their allocations
     */
    function getAllBeneficiaries() 
        external 
        view 
        returns (
            address[] memory beneficiaryList,
            Allocation[] memory allocationList
        ) 
    {
        beneficiaryList = beneficiaries;
        allocationList = new Allocation[](beneficiaries.length);
        
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            allocationList[i] = allocations[beneficiaries[i]];
        }
    }

    /**
     * @notice Get staking information for a user
     * @param user The user address
     * @return stakeInfo The stake information
     * @return pendingRewards The pending rewards
     */
    function getStakingInfo(address user) 
        external 
        view 
        returns (StakeInfo memory stakeInfo, uint256 pendingRewards) 
    {
        stakeInfo = stakes[user];
        pendingRewards = earned(user);
    }

    /**
     * @notice Check if epoch needs update
     * @return needsUpdate Whether epoch should be updated
     * @return timeSinceLastEpoch Time since last epoch
     */
    function checkEpochUpdate() 
        external 
        view 
        returns (bool needsUpdate, uint256 timeSinceLastEpoch) 
    {
        timeSinceLastEpoch = block.timestamp - lastEpochTimestamp;
        needsUpdate = timeSinceLastEpoch >= epochDuration;
    }

    // ============ Epoch Management ============

    /**
     * @notice Complete current epoch and start new one
     */
    function completeEpoch() external onlyRole(OPERATOR_ROLE) {
        if (block.timestamp < lastEpochTimestamp + epochDuration) {
            revert InvalidConfiguration();
        }
        
        // Finalize current epoch
        EpochData storage epoch = epochData[currentEpoch];
        epoch.distributed = totalDistributed;
        epoch.staked = totalStaked;
        epoch.activeUsers = beneficiaries.length;
        epoch.timestamp = block.timestamp;
        
        emit EpochCompleted(currentEpoch, epoch.revenue, epoch.distributed);
        
        // Start new epoch
        currentEpoch++;
        lastEpochTimestamp = block.timestamp;
        
        // Update metrics
        _updateMetrics();
    }

    /**
     * @notice Update financial metrics
     */
    function _updateMetrics() internal {
        metrics.currentBalance = cifiToken.balanceOf(address(this));
        
        // Calculate average daily revenue (30-day rolling average)
        uint256 daysCount = 30;
        uint256 totalRecentRevenue;
        uint256 startEpoch = currentEpoch > daysCount ? currentEpoch - daysCount : 0;
        
        for (uint256 i = startEpoch; i < currentEpoch; i++) {
            totalRecentRevenue += epochData[i].revenue;
        }
        
        metrics.averageDailyRevenue = totalRecentRevenue / daysCount;
        metrics.projectedMonthlyRevenue = metrics.averageDailyRevenue * 30;
    }

    // ============ Configuration Functions ============

    /**
     * @notice Update oracle contract address
     * @param _oracle The new oracle address
     */
    function setOracleContract(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oracle == address(0)) revert InvalidConfiguration();
        tradeSphereOracle = TradeSphereOracle(_oracle);
    }

    /**
     * @notice Update fee structure
     * @param _fees The new fee structure
     */
    function updateFeeStructure(FeeStructure calldata _fees) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 totalFees = _fees.stakingRewardsFee +
                           _fees.emergencyFundFee +
                           _fees.operationalFee +
                           _fees.developmentFee +
                           _fees.marketingFee;
        
        if (totalFees > BASIS_POINTS) revert InvalidConfiguration();
        
        fees = _fees;
    }

    /**
     * @notice Update withdrawal delay
     * @param _delay The new delay in seconds
     */
    function setWithdrawalDelay(uint256 _delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalDelay = _delay;
    }

    // ============ Internal Functions ============

    /**
     * @notice Initialize default budget categories
     */
    function _initializeDefaultBudgets() internal {
        // Operations budget
        budgets["Operations"] = Budget({
            allocated: 10000 * 10**18,
            spent: 0,
            period: 30 days,
            lastReset: block.timestamp,
            isActive: true
        });
        budgetCategories.push("Operations");
        
        // Development budget
        budgets["Development"] = Budget({
            allocated: 15000 * 10**18,
            spent: 0,
            period: 30 days,
            lastReset: block.timestamp,
            isActive: true
        });
        budgetCategories.push("Development");
        
        // Marketing budget
        budgets["Marketing"] = Budget({
            allocated: 5000 * 10**18,
            spent: 0,
            period: 30 days,
            lastReset: block.timestamp,
            isActive: true
        });
        budgetCategories.push("Marketing");
        
        // Partnerships budget
        budgets["Partnerships"] = Budget({
            allocated: 8000 * 10**18,
            spent: 0,
            period: 30 days,
            lastReset: block.timestamp,
            isActive: true
        });
        budgetCategories.push("Partnerships");
    }

    // ============ Receive Function ============
    receive() external payable {
        // Accept ETH payments
    }
}
