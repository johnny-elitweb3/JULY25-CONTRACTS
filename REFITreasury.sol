// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title REFITreasury
 * @dev Treasury contract for managing REFI token rewards pool
 * 
 * Features:
 * - P2P deposits directly to the contract
 * - Real-time pool analytics
 * - Integration with NFT staking contract
 * - Deposit tracking and history
 * - Emergency withdrawal mechanisms
 * - Automated reward distribution management
 * - Enhanced security and gas optimizations
 */
contract REFITreasury is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========== Errors ==========
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error UnauthorizedCaller();
    error TransferFailed();
    error InvalidAllocation();
    error AllocationExceedsBalance();
    error StakingContractOnly();
    error InvalidTimestamp();
    error ArrayLengthMismatch();
    error SourceTooLong();
    error InvalidParameters();

    // ========== Constants ==========
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_ALLOCATION_PERCENTAGE = 10000; // 100%
    uint256 public constant MAX_SOURCE_LENGTH = 32;
    uint256 public constant MAX_BATCH_SIZE = 100;
    
    // ========== State Variables ==========
    IERC20 public immutable refiToken;
    address public stakingContract;
    
    // Treasury tracking
    uint256 public totalDeposited;
    uint256 public totalDistributed;
    uint256 public lastRecalibrationTime;
    
    // Allocation tracking for staking rewards
    uint256 public allocatedForRewards;
    uint256 public pendingRewards;
    
    // Deposit tracking
    struct DepositInfo {
        address depositor;
        uint256 amount;
        uint256 timestamp;
        string source; // "P2P", "DAPP", "PROTOCOL", etc.
    }
    
    DepositInfo[] public deposits;
    mapping(address => uint256) public depositorTotalContributions;
    mapping(address => uint256[]) private depositorHistory;
    
    // Unique depositors tracking
    address[] private uniqueDepositors;
    mapping(address => bool) private isDepositor;
    
    // Analytics
    struct PoolAnalytics {
        uint256 totalBalance;
        uint256 availableBalance;
        uint256 allocatedBalance;
        uint256 pendingRewards;
        uint256 totalDeposits;
        uint256 totalDistributions;
        uint256 depositorCount;
        uint256 averageDepositSize;
        uint256 lastActivityTime;
    }
    
    // Reward distribution tracking
    struct RewardDistribution {
        address recipient;
        uint256 amount;
        uint256 timestamp;
        uint256 vaultId;
    }
    
    RewardDistribution[] public rewardHistory;
    mapping(address => uint256) public totalRewardsPerUser;
    
    // Rate limiting for distributions
    mapping(address => uint256) private lastDistributionTime;
    uint256 public distributionCooldown = 1 hours;
    
    // ========== Events ==========
    event Deposited(address indexed depositor, uint256 amount, string source, uint256 newBalance);
    event RewardsAllocated(uint256 amount, uint256 totalAllocated);
    event RewardsDistributed(address indexed recipient, uint256 amount, uint256 vaultId);
    event PoolRecalibrated(uint256 totalBalance, uint256 allocated, uint256 available);
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event RewardAllocationUpdated(uint256 oldAllocation, uint256 newAllocation);
    event DirectDepositDetected(uint256 amount, uint256 timestamp);
    event DistributionCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    
    // ========== Modifiers ==========
    modifier onlyStakingContract() {
        if (msg.sender != stakingContract) revert StakingContractOnly();
        _;
    }
    
    modifier notZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }
    
    modifier validSource(string calldata source) {
        if (bytes(source).length > MAX_SOURCE_LENGTH) revert SourceTooLong();
        _;
    }
    
    // ========== Constructor ==========
    constructor(
        address _refiToken,
        address _stakingContract
    ) 
        notZeroAddress(_refiToken)
        notZeroAddress(_stakingContract)
        Ownable(msg.sender)
    {
        refiToken = IERC20(_refiToken);
        stakingContract = _stakingContract;
        lastRecalibrationTime = block.timestamp;
        
        emit StakingContractUpdated(address(0), _stakingContract);
    }
    
    // ========== Deposit Functions ==========
    
    /**
     * @dev Allows anyone to deposit REFI tokens to the reward pool
     * @param amount Amount of REFI tokens to deposit
     * @param source Source identifier (P2P, DAPP, etc.)
     */
    function deposit(uint256 amount, string calldata source) 
        external 
        nonReentrant 
        whenNotPaused 
        validSource(source)
    {
        if (amount == 0) revert ZeroAmount();
        
        // Transfer tokens from depositor
        uint256 balanceBefore = refiToken.balanceOf(address(this));
        refiToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualDeposited = refiToken.balanceOf(address(this)) - balanceBefore;
        
        // Track unique depositors
        if (!isDepositor[msg.sender]) {
            isDepositor[msg.sender] = true;
            uniqueDepositors.push(msg.sender);
        }
        
        // Record deposit
        deposits.push(DepositInfo({
            depositor: msg.sender,
            amount: actualDeposited,
            timestamp: block.timestamp,
            source: source
        }));
        
        // Update tracking
        totalDeposited += actualDeposited;
        depositorTotalContributions[msg.sender] += actualDeposited;
        depositorHistory[msg.sender].push(deposits.length - 1);
        
        // Recalibrate pool
        _recalibratePool();
        
        emit Deposited(msg.sender, actualDeposited, source, refiToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Batch deposit with different sources
     */
    function batchDeposit(
        uint256[] calldata amounts,
        string[] calldata sources
    ) external nonReentrant whenNotPaused {
        uint256 length = amounts.length;
        if (length != sources.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i = 0; i < length; i++) {
            if (amounts[i] > 0 && bytes(sources[i]).length <= MAX_SOURCE_LENGTH) {
                this.deposit(amounts[i], sources[i]);
            }
        }
    }
    
    // ========== Reward Management ==========
    
    /**
     * @dev Allocates tokens for staking rewards
     * @param amount Amount to allocate for rewards
     */
    function allocateRewards(uint256 amount) external onlyOwner whenNotPaused {
        uint256 available = getAvailableBalance();
        if (amount > available) revert AllocationExceedsBalance();
        
        allocatedForRewards += amount;
        emit RewardsAllocated(amount, allocatedForRewards);
        
        _recalibratePool();
    }
    
    /**
     * @dev Reduces reward allocation
     * @param amount Amount to deallocate from rewards
     */
    function deallocateRewards(uint256 amount) external onlyOwner whenNotPaused {
        if (amount > allocatedForRewards) revert InsufficientBalance();
        
        allocatedForRewards -= amount;
        emit RewardAllocationUpdated(allocatedForRewards + amount, allocatedForRewards);
        
        _recalibratePool();
    }
    
    /**
     * @dev Distributes rewards to a staker (called by staking contract)
     * @param recipient Address to receive rewards
     * @param amount Amount of rewards to distribute
     * @param vaultId Vault ID from staking contract
     */
    function distributeRewards(
        address recipient,
        uint256 amount,
        uint256 vaultId
    ) external onlyStakingContract nonReentrant whenNotPaused returns (bool) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        // Check if we have enough allocated rewards
        if (amount > allocatedForRewards) revert InsufficientBalance();
        
        // Update allocations
        allocatedForRewards -= amount;
        totalDistributed += amount;
        
        // Record distribution
        rewardHistory.push(RewardDistribution({
            recipient: recipient,
            amount: amount,
            timestamp: block.timestamp,
            vaultId: vaultId
        }));
        
        totalRewardsPerUser[recipient] += amount;
        lastDistributionTime[recipient] = block.timestamp;
        
        // Transfer rewards
        refiToken.safeTransfer(recipient, amount);
        
        emit RewardsDistributed(recipient, amount, vaultId);
        
        // Recalibrate after distribution
        _recalibratePool();
        
        return true;
    }
    
    /**
     * @dev Batch distribute rewards (gas efficient for multiple distributions)
     */
    function batchDistributeRewards(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256[] calldata vaultIds
    ) external onlyStakingContract nonReentrant whenNotPaused returns (bool) {
        uint256 length = recipients.length;
        if (length != amounts.length || length != vaultIds.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            totalAmount += amounts[i];
        }
        
        if (totalAmount > allocatedForRewards) revert InsufficientBalance();
        
        for (uint256 i = 0; i < length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) continue;
            
            allocatedForRewards -= amounts[i];
            totalDistributed += amounts[i];
            
            rewardHistory.push(RewardDistribution({
                recipient: recipients[i],
                amount: amounts[i],
                timestamp: block.timestamp,
                vaultId: vaultIds[i]
            }));
            
            totalRewardsPerUser[recipients[i]] += amounts[i];
            lastDistributionTime[recipients[i]] = block.timestamp;
            
            refiToken.safeTransfer(recipients[i], amounts[i]);
            
            emit RewardsDistributed(recipients[i], amounts[i], vaultIds[i]);
        }
        
        _recalibratePool();
        return true;
    }
    
    // ========== Pool Management ==========
    
    /**
     * @dev Recalibrates the reward pool based on current balance
     * Called automatically on deposits and distributions
     */
    function _recalibratePool() private {
        uint256 currentBalance = refiToken.balanceOf(address(this));
        uint256 available = currentBalance > allocatedForRewards ? 
            currentBalance - allocatedForRewards : 0;
        
        lastRecalibrationTime = block.timestamp;
        
        emit PoolRecalibrated(currentBalance, allocatedForRewards, available);
    }
    
    /**
     * @dev Manual recalibration (can be called by anyone)
     */
    function recalibratePool() external whenNotPaused {
        _recalibratePool();
    }
    
    /**
     * @dev Check and handle any tokens sent directly to contract
     */
    function checkDirectDeposits() external nonReentrant whenNotPaused {
        uint256 currentBalance = refiToken.balanceOf(address(this));
        uint256 expectedBalance = totalDeposited - totalDistributed;
        
        if (currentBalance > expectedBalance) {
            uint256 directDeposit = currentBalance - expectedBalance;
            
            // Record as direct deposit
            deposits.push(DepositInfo({
                depositor: address(0), // Unknown depositor
                amount: directDeposit,
                timestamp: block.timestamp,
                source: "DIRECT_TRANSFER"
            }));
            
            totalDeposited += directDeposit;
            
            emit Deposited(address(0), directDeposit, "DIRECT_TRANSFER", currentBalance);
            emit DirectDepositDetected(directDeposit, block.timestamp);
            
            _recalibratePool();
        }
    }
    
    // ========== View Functions ==========
    
    /**
     * @dev Returns comprehensive pool analytics
     */
    function getPoolAnalytics() external view returns (PoolAnalytics memory) {
        uint256 balance = refiToken.balanceOf(address(this));
        uint256 depositorCount = uniqueDepositors.length;
        
        return PoolAnalytics({
            totalBalance: balance,
            availableBalance: getAvailableBalance(),
            allocatedBalance: allocatedForRewards,
            pendingRewards: pendingRewards,
            totalDeposits: totalDeposited,
            totalDistributions: totalDistributed,
            depositorCount: depositorCount,
            averageDepositSize: depositorCount > 0 ? totalDeposited / depositorCount : 0,
            lastActivityTime: lastRecalibrationTime
        });
    }
    
    /**
     * @dev Returns available balance for allocation
     */
    function getAvailableBalance() public view returns (uint256) {
        uint256 balance = refiToken.balanceOf(address(this));
        return balance > allocatedForRewards ? balance - allocatedForRewards : 0;
    }
    
    /**
     * @dev Get unique depositor count
     */
    function getUniqueDepositorCount() external view returns (uint256) {
        return uniqueDepositors.length;
    }
    
    /**
     * @dev Get unique depositors with pagination
     */
    function getUniqueDepositors(uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory) 
    {
        uint256 total = uniqueDepositors.length;
        if (offset >= total) return new address[](0);
        
        uint256 end = Math.min(offset + limit, total);
        uint256 length = end - offset;
        
        address[] memory depositors = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            depositors[i] = uniqueDepositors[offset + i];
        }
        
        return depositors;
    }
    
    /**
     * @dev Get deposit history for a specific depositor
     */
    function getDepositorHistory(address depositor) external view returns (DepositInfo[] memory) {
        uint256[] memory indices = depositorHistory[depositor];
        DepositInfo[] memory history = new DepositInfo[](indices.length);
        
        for (uint256 i = 0; i < indices.length; i++) {
            history[i] = deposits[indices[i]];
        }
        
        return history;
    }
    
    /**
     * @dev Get recent deposits with pagination
     */
    function getRecentDeposits(uint256 offset, uint256 limit) 
        external 
        view 
        returns (DepositInfo[] memory) 
    {
        uint256 total = deposits.length;
        if (offset >= total) return new DepositInfo[](0);
        
        uint256 end = Math.min(offset + limit, total);
        uint256 length = end - offset;
        
        DepositInfo[] memory recent = new DepositInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            recent[i] = deposits[total - offset - i - 1]; // Return in reverse order (newest first)
        }
        
        return recent;
    }
    
    /**
     * @dev Get reward distribution history
     */
    function getRewardHistory(uint256 offset, uint256 limit) 
        external 
        view 
        returns (RewardDistribution[] memory) 
    {
        uint256 total = rewardHistory.length;
        if (offset >= total) return new RewardDistribution[](0);
        
        uint256 end = Math.min(offset + limit, total);
        uint256 length = end - offset;
        
        RewardDistribution[] memory history = new RewardDistribution[](length);
        for (uint256 i = 0; i < length; i++) {
            history[i] = rewardHistory[total - offset - i - 1];
        }
        
        return history;
    }
    
    /**
     * @dev Get user's last distribution time
     */
    function getLastDistributionTime(address user) external view returns (uint256) {
        return lastDistributionTime[user];
    }
    
    /**
     * @dev Check if address has ever deposited
     */
    function hasDeposited(address depositor) external view returns (bool) {
        return isDepositor[depositor];
    }
    
    /**
     * @dev Get total number of deposits
     */
    function getTotalDeposits() external view returns (uint256) {
        return deposits.length;
    }
    
    /**
     * @dev Get total number of distributions
     */
    function getTotalDistributions() external view returns (uint256) {
        return rewardHistory.length;
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @dev Update staking contract address
     */
    function updateStakingContract(address newStakingContract) 
        external 
        onlyOwner 
        notZeroAddress(newStakingContract) 
    {
        address oldContract = stakingContract;
        stakingContract = newStakingContract;
        emit StakingContractUpdated(oldContract, newStakingContract);
    }
    
    /**
     * @dev Update distribution cooldown
     */
    function updateDistributionCooldown(uint256 newCooldown) external onlyOwner {
        uint256 oldCooldown = distributionCooldown;
        distributionCooldown = newCooldown;
        emit DistributionCooldownUpdated(oldCooldown, newCooldown);
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Emergency withdrawal (only when paused)
     */
    function emergencyWithdraw(address to, uint256 amount) 
        external 
        onlyOwner 
        whenPaused 
        notZeroAddress(to) 
    {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = refiToken.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        
        refiToken.safeTransfer(to, amount);
        
        // Reset allocations if needed
        if (allocatedForRewards > refiToken.balanceOf(address(this))) {
            allocatedForRewards = refiToken.balanceOf(address(this));
        }
        
        emit EmergencyWithdrawal(to, amount);
        _recalibratePool();
    }
    
    /**
     * @dev Rescue any accidentally sent tokens (not REFI)
     */
    function rescueTokens(address token, address to, uint256 amount) 
        external 
        onlyOwner 
        notZeroAddress(to) 
        notZeroAddress(token)
    {
        if (token == address(refiToken)) revert UnauthorizedCaller();
        IERC20(token).safeTransfer(to, amount);
    }
    
    /**
     * @dev Complete two-step ownership transfer
     */
    function acceptOwnership() public override {
        super.acceptOwnership();
    }
    
    /**
     * @dev Renounce ownership (disabled for safety)
     */
    function renounceOwnership() public view override onlyOwner {
        revert UnauthorizedCaller();
    }
}
