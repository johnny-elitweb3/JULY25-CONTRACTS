// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title RewardCalculator
 * @author Enhanced Implementation v2
 * @notice Handles precise reward calculations and pool management for NFT staking
 * @dev Optimized for gas efficiency and security
 */
contract RewardCalculator is Ownable, ReentrancyGuard {
    using Math for uint256;

    // ========== Constants ==========
    uint256 public constant PRECISION = 1e18; // 18 decimal precision
    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000
    uint256 public constant MAX_YIELD_PERCENTAGE = 5000; // Max 50%
    uint256 public constant MIN_STAKE_DURATION = 1 days;
    uint256 public constant MAX_STAKE_DURATION = 365 days;
    uint256 public constant DUST_THRESHOLD = 1000; // Minimum claimable amount

    // ========== Structs ==========
    struct Pool {
        uint256 yieldPercentage; // In PERCENTAGE_BASE units
        uint256 stakeDuration; // Duration to earn full yield
        uint256 minStakeDuration; // Minimum time before unstaking
        uint256 totalRewards; // Total rewards deposited
        uint256 totalClaimed; // Total rewards claimed
        uint256 reservedRewards; // Rewards allocated to active stakes
        uint256 totalStaked; // Total NFTs staked in pool
        uint256 totalUnstaked; // Total NFTs unstaked from pool
        address rewardToken;
        bool active;
        uint128 createdAt;
        uint128 lastUpdateAt;
    }

    struct StakeReward {
        uint256 targetReward; // Pre-calculated total reward
        uint256 rewardsClaimed; // Amount already claimed
        uint256 lastClaimTime; // Last claim timestamp
        uint256 stakedAt; // Stake timestamp
        uint256 poolId; // Associated pool
        uint256 nftPrice; // Original NFT price for tracking
    }

    struct PoolStats {
        uint256 totalValueStaked; // Total value of NFTs staked
        uint256 averageStakeDuration; // Average stake duration
        uint256 utilizationRate; // Pool utilization percentage
    }

    // ========== State Variables ==========
    address public stakingContract;
    
    mapping(uint256 => Pool) public pools;
    mapping(uint256 => StakeReward) public stakeRewards; // tokenId => reward info
    mapping(uint256 => PoolStats) public poolStats; // poolId => statistics
    mapping(address => uint256) public userTotalClaimed; // user => total claimed across all pools
    mapping(uint256 => mapping(address => uint256)) public userPoolClaimed; // poolId => user => claimed amount
    
    uint256 public poolCounter;
    uint256 public totalRewardsDistributed;

    // ========== Events ==========
    event PoolCreated(
        uint256 indexed poolId, 
        address indexed rewardToken,
        uint256 yieldPercentage, 
        uint256 stakeDuration,
        uint256 minStakeDuration
    );
    event PoolUpdated(uint256 indexed poolId, uint256 yieldPercentage, bool active);
    event RewardCalculated(uint256 indexed tokenId, uint256 indexed poolId, uint256 targetReward, uint256 nftPrice);
    event RewardsClaimed(uint256 indexed tokenId, address indexed user, uint256 amount);
    event PoolFunded(uint256 indexed poolId, uint256 amount, uint256 newTotal);
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);
    event UnusedRewardsReleased(uint256 indexed poolId, uint256 amount);
    event EmergencyWithdraw(uint256 indexed poolId, uint256 amount);

    // ========== Custom Errors ==========
    error OnlyStakingContract();
    error InvalidPool();
    error InvalidAddress();
    error InvalidYieldPercentage();
    error InvalidDuration();
    error PoolNotActive();
    error InsufficientPoolRewards();
    error NotStaked();
    error MinDurationNotMet();
    error NothingToClaim();
    error AmountBelowDustThreshold();

    // ========== Modifiers ==========
    modifier onlyStakingContract() {
        if (msg.sender != stakingContract) revert OnlyStakingContract();
        _;
    }

    modifier validPool(uint256 _poolId) {
        if (_poolId >= poolCounter) revert InvalidPool();
        _;
    }

    // ========== Constructor ==========
    constructor() Ownable(msg.sender) {}

    // ========== Configuration ==========

    /**
     * @notice Set the staking contract address
     * @param _stakingContract Address of the staking contract
     */
    function setStakingContract(address _stakingContract) external onlyOwner {
        if (_stakingContract == address(0)) revert InvalidAddress();
        address oldContract = stakingContract;
        stakingContract = _stakingContract;
        emit StakingContractUpdated(oldContract, _stakingContract);
    }

    // ========== Pool Management ==========

    /**
     * @notice Create a new reward pool
     * @param _rewardToken Token used for rewards
     * @param _yieldPercentage Fixed yield percentage
     * @param _stakeDuration Duration to earn full yield
     * @param _minStakeDuration Minimum stake duration
     * @return poolId The created pool ID
     */
    function createPool(
        address _rewardToken,
        uint256 _yieldPercentage,
        uint256 _stakeDuration,
        uint256 _minStakeDuration
    ) external onlyStakingContract returns (uint256 poolId) {
        if (_yieldPercentage == 0 || _yieldPercentage > MAX_YIELD_PERCENTAGE) revert InvalidYieldPercentage();
        if (_stakeDuration < MIN_STAKE_DURATION || _stakeDuration > MAX_STAKE_DURATION) revert InvalidDuration();
        if (_minStakeDuration < MIN_STAKE_DURATION || _minStakeDuration > _stakeDuration) revert InvalidDuration();
        
        poolId = poolCounter++;
        
        pools[poolId] = Pool({
            yieldPercentage: _yieldPercentage,
            stakeDuration: _stakeDuration,
            minStakeDuration: _minStakeDuration,
            totalRewards: 0,
            totalClaimed: 0,
            reservedRewards: 0,
            totalStaked: 0,
            totalUnstaked: 0,
            rewardToken: _rewardToken,
            active: true,
            createdAt: uint128(block.timestamp),
            lastUpdateAt: uint128(block.timestamp)
        });
        
        emit PoolCreated(poolId, _rewardToken, _yieldPercentage, _stakeDuration, _minStakeDuration);
    }

    /**
     * @notice Update pool parameters
     * @param _poolId Pool ID to update
     * @param _yieldPercentage New yield percentage
     * @param _active Pool active status
     */
    function updatePool(
        uint256 _poolId,
        uint256 _yieldPercentage,
        bool _active
    ) external onlyStakingContract validPool(_poolId) {
        if (_yieldPercentage > MAX_YIELD_PERCENTAGE) revert InvalidYieldPercentage();
        
        Pool storage pool = pools[_poolId];
        pool.yieldPercentage = _yieldPercentage;
        pool.active = _active;
        pool.lastUpdateAt = uint128(block.timestamp);
        
        emit PoolUpdated(_poolId, _yieldPercentage, _active);
    }

    /**
     * @notice Fund a pool with rewards
     * @param _poolId Pool to fund
     * @param _amount Amount to add
     */
    function fundPool(uint256 _poolId, uint256 _amount) external onlyStakingContract validPool(_poolId) {
        pools[_poolId].totalRewards += _amount;
        emit PoolFunded(_poolId, _amount, pools[_poolId].totalRewards);
    }

    // ========== Reward Calculation ==========

    /**
     * @notice Calculate and store target reward for a new stake
     * @param _tokenId NFT token ID
     * @param _poolId Pool ID
     * @param _nftPrice NFT purchase price
     * @return targetReward Calculated target reward
     */
    function calculateAndStoreReward(
        uint256 _tokenId,
        uint256 _poolId,
        uint256 _nftPrice
    ) external onlyStakingContract validPool(_poolId) returns (uint256 targetReward) {
        Pool storage pool = pools[_poolId];
        if (!pool.active) revert PoolNotActive();
        
        // High precision calculation
        targetReward = (_nftPrice * pool.yieldPercentage * PRECISION) / (PERCENTAGE_BASE * PRECISION);
        
        // Check available rewards
        uint256 availableRewards = pool.totalRewards - pool.totalClaimed - pool.reservedRewards;
        if (availableRewards < targetReward) revert InsufficientPoolRewards();
        
        // Store reward info
        stakeRewards[_tokenId] = StakeReward({
            targetReward: targetReward,
            rewardsClaimed: 0,
            lastClaimTime: block.timestamp,
            stakedAt: block.timestamp,
            poolId: _poolId,
            nftPrice: _nftPrice
        });
        
        // Update pool state
        pool.reservedRewards += targetReward;
        pool.totalStaked++;
        pool.lastUpdateAt = uint128(block.timestamp);
        
        // Update pool statistics
        poolStats[_poolId].totalValueStaked += _nftPrice;
        _updateUtilizationRate(_poolId);
        
        emit RewardCalculated(_tokenId, _poolId, targetReward, _nftPrice);
    }

    /**
     * @notice Calculate pending rewards for a stake
     * @param _tokenId NFT token ID
     * @return pendingRewards Amount of pending rewards
     */
    function calculatePendingRewards(uint256 _tokenId) external view returns (uint256 pendingRewards) {
        return _calculatePendingRewardsInternal(_tokenId);
    }

    /**
     * @notice Internal function to calculate pending rewards
     * @param _tokenId NFT token ID
     * @return pendingRewards Amount of pending rewards
     */
    function _calculatePendingRewardsInternal(uint256 _tokenId) internal view returns (uint256 pendingRewards) {
        StakeReward storage reward = stakeRewards[_tokenId];
        if (reward.stakedAt == 0) return 0;
        
        Pool storage pool = pools[reward.poolId];
        
        // Calculate time staked
        uint256 timeStaked = block.timestamp - reward.stakedAt;
        
        // Calculate total earned rewards
        uint256 totalEarned;
        if (timeStaked >= pool.stakeDuration) {
            totalEarned = reward.targetReward;
        } else {
            // High precision proportional calculation
            totalEarned = (reward.targetReward * timeStaked * PRECISION) / (pool.stakeDuration * PRECISION);
        }
        
        // Calculate pending (unclaimed)
        pendingRewards = totalEarned > reward.rewardsClaimed ? 
                        totalEarned - reward.rewardsClaimed : 0;
        
        // Cap at available pool rewards
        uint256 availableInPool = pool.totalRewards - pool.totalClaimed;
        if (pendingRewards > availableInPool) {
            pendingRewards = availableInPool;
        }
    }

    /**
     * @notice Process reward claim
     * @param _tokenId NFT token ID
     * @param _tokenOwner Owner of the token (passed by staking contract)
     * @return amount Amount to claim
     */
    function processClaim(uint256 _tokenId, address _tokenOwner) external onlyStakingContract nonReentrant returns (uint256 amount) {
        StakeReward storage reward = stakeRewards[_tokenId];
        if (reward.stakedAt == 0) revert NotStaked();
        
        // Use internal calculation function
        amount = _calculatePendingRewardsInternal(_tokenId);
        
        if (amount == 0) revert NothingToClaim();
        if (amount < DUST_THRESHOLD) revert AmountBelowDustThreshold();
        
        Pool storage pool = pools[reward.poolId];
        
        // Update state
        reward.rewardsClaimed += amount;
        reward.lastClaimTime = block.timestamp;
        pool.totalClaimed += amount;
        pool.lastUpdateAt = uint128(block.timestamp);
        
        // Update global and user statistics
        totalRewardsDistributed += amount;
        userTotalClaimed[_tokenOwner] += amount;
        userPoolClaimed[reward.poolId][_tokenOwner] += amount;
        
        emit RewardsClaimed(_tokenId, _tokenOwner, amount);
    }

    /**
     * @notice Process unstaking and return final rewards
     * @param _tokenId NFT token ID
     * @param _tokenOwner Owner of the token (passed by staking contract)
     * @return finalRewards Final rewards to claim
     * @return unusedRewards Unused reserved rewards to release
     */
    function processUnstake(uint256 _tokenId, address _tokenOwner) external onlyStakingContract nonReentrant returns (
        uint256 finalRewards,
        uint256 unusedRewards
    ) {
        StakeReward storage reward = stakeRewards[_tokenId];
        if (reward.stakedAt == 0) revert NotStaked();
        
        Pool storage pool = pools[reward.poolId];
        
        // Check minimum stake duration
        if (block.timestamp < reward.stakedAt + pool.minStakeDuration) {
            revert MinDurationNotMet();
        }
        
        // Calculate final rewards using internal function
        finalRewards = _calculatePendingRewardsInternal(_tokenId);
        uint256 totalClaimedForStake = reward.rewardsClaimed + finalRewards;
        
        // Calculate unused rewards
        unusedRewards = reward.targetReward > totalClaimedForStake ? 
                       reward.targetReward - totalClaimedForStake : 0;
        
        // Update pool state
        if (finalRewards > 0) {
            pool.totalClaimed += finalRewards;
            totalRewardsDistributed += finalRewards;
            
            userTotalClaimed[_tokenOwner] += finalRewards;
            userPoolClaimed[reward.poolId][_tokenOwner] += finalRewards;
        }
        
        if (unusedRewards > 0) {
            pool.reservedRewards -= unusedRewards;
            emit UnusedRewardsReleased(reward.poolId, unusedRewards);
        }
        
        // Update pool statistics
        pool.totalUnstaked++;
        pool.lastUpdateAt = uint128(block.timestamp);
        poolStats[reward.poolId].totalValueStaked -= reward.nftPrice;
        
        // Update average stake duration
        uint256 stakeDuration = block.timestamp - reward.stakedAt;
        _updateAverageStakeDuration(reward.poolId, stakeDuration);
        _updateUtilizationRate(reward.poolId);
        
        // Clear stake reward info
        delete stakeRewards[_tokenId];
    }

    // ========== Internal Helper Functions ==========

    /**
     * @notice Update pool utilization rate
     * @param _poolId Pool ID
     */
    function _updateUtilizationRate(uint256 _poolId) internal {
        Pool storage pool = pools[_poolId];
        if (pool.totalRewards > 0) {
            poolStats[_poolId].utilizationRate = 
                (pool.reservedRewards * PERCENTAGE_BASE) / pool.totalRewards;
        }
    }

    /**
     * @notice Update average stake duration for pool
     * @param _poolId Pool ID
     * @param _newDuration New stake duration to include
     */
    function _updateAverageStakeDuration(uint256 _poolId, uint256 _newDuration) internal {
        Pool storage pool = pools[_poolId];
        uint256 totalStakes = pool.totalStaked + pool.totalUnstaked;
        
        if (totalStakes > 0) {
            uint256 currentAvg = poolStats[_poolId].averageStakeDuration;
            poolStats[_poolId].averageStakeDuration = 
                (currentAvg * (totalStakes - 1) + _newDuration) / totalStakes;
        }
    }

    // ========== View Functions ==========

    /**
     * @notice Get pool information
     * @param _poolId Pool ID
     * @return pool Pool data
     */
    function getPool(uint256 _poolId) external view validPool(_poolId) returns (Pool memory) {
        return pools[_poolId];
    }

    /**
     * @notice Get stake reward information
     * @param _tokenId NFT token ID
     * @return reward Stake reward data
     */
    function getStakeReward(uint256 _tokenId) external view returns (StakeReward memory) {
        return stakeRewards[_tokenId];
    }

    /**
     * @notice Get available rewards in a pool
     * @param _poolId Pool ID
     * @return available Available rewards for new stakes
     */
    function getAvailablePoolRewards(uint256 _poolId) external view validPool(_poolId) returns (uint256) {
        Pool storage pool = pools[_poolId];
        return pool.totalRewards - pool.totalClaimed - pool.reservedRewards;
    }

    /**
     * @notice Get pool statistics
     * @param _poolId Pool ID
     * @return stats Pool statistics
     */
    function getPoolStats(uint256 _poolId) external view validPool(_poolId) returns (PoolStats memory) {
        return poolStats[_poolId];
    }

    /**
     * @notice Get user's total claimed rewards
     * @param _user User address
     * @return total Total claimed across all pools
     */
    function getUserTotalClaimed(address _user) external view returns (uint256) {
        return userTotalClaimed[_user];
    }

    /**
     * @notice Get user's claimed rewards from specific pool
     * @param _poolId Pool ID
     * @param _user User address
     * @return amount Amount claimed from pool
     */
    function getUserPoolClaimed(uint256 _poolId, address _user) external view validPool(_poolId) returns (uint256) {
        return userPoolClaimed[_poolId][_user];
    }

    /**
     * @notice Check if pool is active
     * @param _poolId Pool ID
     * @return active Pool active status
     */
    function isPoolActive(uint256 _poolId) external view validPool(_poolId) returns (bool) {
        return pools[_poolId].active;
    }

    /**
     * @notice Get pool reward token
     * @param _poolId Pool ID
     * @return token Reward token address
     */
    function getPoolRewardToken(uint256 _poolId) external view validPool(_poolId) returns (address) {
        return pools[_poolId].rewardToken;
    }

    /**
     * @notice Calculate reward for given parameters without storing
     * @param _poolId Pool ID
     * @param _nftPrice NFT price
     * @return reward Calculated reward amount
     */
    function previewReward(uint256 _poolId, uint256 _nftPrice) external view validPool(_poolId) returns (uint256) {
        Pool storage pool = pools[_poolId];
        return (_nftPrice * pool.yieldPercentage * PRECISION) / (PERCENTAGE_BASE * PRECISION);
    }

    /**
     * @notice Get all pool IDs
     * @return poolIds Array of all pool IDs
     */
    function getAllPoolIds() external view returns (uint256[] memory) {
        uint256[] memory poolIds = new uint256[](poolCounter);
        for (uint256 i = 0; i < poolCounter; i++) {
            poolIds[i] = i;
        }
        return poolIds;
    }

    /**
     * @notice Get active pool IDs
     * @return activePoolIds Array of active pool IDs
     */
    function getActivePoolIds() external view returns (uint256[] memory) {
        uint256 activeCount = 0;
        
        // Count active pools
        for (uint256 i = 0; i < poolCounter; i++) {
            if (pools[i].active) activeCount++;
        }
        
        // Populate array
        uint256[] memory activePoolIds = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < poolCounter; i++) {
            if (pools[i].active) {
                activePoolIds[index++] = i;
            }
        }
        
        return activePoolIds;
    }

    // ========== Emergency Functions ==========

    /**
     * @notice Emergency withdraw for stuck funds (owner only)
     * @param _poolId Pool ID
     * @param _amount Amount to withdraw
     * @param _recipient Recipient address
     */
    function emergencyWithdraw(
        uint256 _poolId, 
        uint256 _amount, 
        address _recipient
    ) external onlyOwner validPool(_poolId) {
        if (_recipient == address(0)) revert InvalidAddress();
        
        Pool storage pool = pools[_poolId];
        uint256 safeAmount = pool.totalRewards - pool.totalClaimed - pool.reservedRewards;
        
        if (_amount > safeAmount) revert InsufficientPoolRewards();
        
        pool.totalRewards -= _amount;
        emit EmergencyWithdraw(_poolId, _amount);
        
        // Transfer would be handled by staking contract
    }
}
