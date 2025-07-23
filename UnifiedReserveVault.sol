// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title UnifiedReserveVault
 * @author Petroleum Club
 * @notice Multi-asset reserve management for the CBG ecosystem
 * @dev Manages OIL, CBG, and USDC reserves with series-based allocation tracking
 */
contract UnifiedReserveVault is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // ========== Custom Errors ==========
    error Unauthorized();
    error InvalidConfiguration();
    error InsufficientReserves();
    error TokenAlreadyProcessed();
    error InvalidAssetType();
    error InvalidAmount();
    error TransferFailed();
    error OracleError();
    error StalePrice();
    error SeriesNotInitialized();
    error InvalidAddress();
    error AssetNotActive();
    error BelowMinimumRedemption();
    error BatchSizeExceeded();
    
    // ========== Type Declarations ==========
    enum AssetType { OIL, CBG, USDC }
    
    struct AssetConfig {
        address tokenAddress;
        address priceOracle;
        uint256 conversionRate;  // For fixed rates (18 decimals)
        bool useOracle;
        uint8 decimals;
        uint256 minRedemption;
        bool isActive;
    }
    
    struct ReleaseRequest {
        address recipient;
        uint256 tokenId;
        uint256 seriesId;
        uint256 amount;
        AssetType assetType;
    }
    
    struct ReserveStatus {
        uint256 totalReserves;
        uint256 totalAllocated;
        uint256 totalReleased;
        uint256 availableReserves;
        uint256 unallocatedReserves;
    }
    
    struct SeriesAllocation {
        uint256 allocated;
        uint256 released;
        uint256 available;
        bool initialized;
    }
    
    // ========== Constants ==========
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant ALLOCATION_BUFFER_PERCENT = 110; // 10% buffer
    uint256 public constant PERCENT_PRECISION = 100;
    
    // ========== State Variables ==========
    
    // Asset Management
    mapping(AssetType => AssetConfig) public assetConfigs;
    mapping(AssetType => uint256) public totalReserves;
    mapping(AssetType => uint256) public totalAllocated;
    mapping(AssetType => uint256) public totalReleased;
    
    // Series Tracking
    mapping(uint256 => mapping(AssetType => uint256)) public seriesAllocated;
    mapping(uint256 => mapping(AssetType => uint256)) public seriesReleased;
    mapping(uint256 => bool) public seriesInitialized;
    
    // Burn Processing
    mapping(uint256 => bool) public tokenProcessed;
    mapping(uint256 => address) public tokenRecipient;
    mapping(uint256 => uint256) public tokenReleasedAmount;
    mapping(uint256 => AssetType) public tokenReleasedAsset;
    
    // Access Control
    address public authorizedCore;
    address public admin;
    address public operator;
    
    // Statistics
    uint256 public totalTokensProcessed;
    uint256 public totalSeriesInitialized;
    mapping(AssetType => uint256) public totalTokensReleasedByAsset;
    
    // ========== Events ==========
    event AssetConfigured(
        AssetType indexed assetType,
        address indexed tokenAddress,
        address priceOracle,
        uint256 conversionRate,
        bool useOracle
    );
    
    event ReserveLoaded(
        AssetType indexed assetType,
        uint256 amount,
        uint256 newTotal
    );
    
    event SeriesInitialized(
        uint256 indexed seriesId,
        uint256 oilAmount,
        uint256 cbgAmount,
        uint256 usdcAmount
    );
    
    event AllocationAdjusted(
        uint256 indexed seriesId,
        AssetType indexed assetType,
        uint256 oldAmount,
        uint256 newAmount
    );
    
    event TokensReleased(
        uint256 indexed tokenId,
        uint256 indexed seriesId,
        address indexed recipient,
        AssetType assetType,
        uint256 amount
    );
    
    event BatchReleaseCompleted(
        uint256 tokensProcessed,
        uint256 totalOilReleased,
        uint256 totalCbgReleased,
        uint256 totalUsdcReleased
    );
    
    event AuthorizedCoreUpdated(address indexed oldCore, address indexed newCore);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    
    // ========== Constructor ==========
    constructor(address _admin, address _operator) {
        if (_admin == address(0) || _operator == address(0)) revert InvalidAddress();
        
        admin = _admin;
        operator = _operator;
        
        // Initialize default asset configurations
        // These will need to be properly configured after deployment
        assetConfigs[AssetType.OIL] = AssetConfig({
            tokenAddress: address(0),
            priceOracle: address(0),
            conversionRate: 1e18, // 1:1 default
            useOracle: false,
            decimals: 18,
            minRedemption: 1e17, // 0.1 OIL minimum
            isActive: false
        });
        
        assetConfigs[AssetType.CBG] = AssetConfig({
            tokenAddress: address(0),
            priceOracle: address(0),
            conversionRate: 0,
            useOracle: true,
            decimals: 18,
            minRedemption: 1e17, // 0.1 CBG minimum
            isActive: false
        });
        
        assetConfigs[AssetType.USDC] = AssetConfig({
            tokenAddress: address(0),
            priceOracle: address(0),
            conversionRate: 0,
            useOracle: true,
            decimals: 6,
            minRedemption: 1e6, // 1 USDC minimum
            isActive: false
        });
    }
    
    // ========== Modifiers ==========
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorizedCore() {
        if (msg.sender != authorizedCore) revert Unauthorized();
        _;
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @notice Update the authorized core contract address
     * @param _authorizedCore New authorized core address
     */
    function setAuthorizedCore(address _authorizedCore) external onlyAdmin {
        if (_authorizedCore == address(0)) revert InvalidAddress();
        address oldCore = authorizedCore;
        authorizedCore = _authorizedCore;
        emit AuthorizedCoreUpdated(oldCore, _authorizedCore);
    }
    
    /**
     * @notice Update the operator address
     * @param _operator New operator address
     */
    function setOperator(address _operator) external onlyAdmin {
        if (_operator == address(0)) revert InvalidAddress();
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }
    
    /**
     * @notice Transfer admin role
     * @param _newAdmin New admin address
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminUpdated(oldAdmin, _newAdmin);
    }
    
    // ========== Asset Management ==========
    
    /**
     * @notice Configure an asset type
     * @param assetType Type of asset to configure
     * @param config Asset configuration
     */
    function configureAsset(
        AssetType assetType,
        AssetConfig calldata config
    ) external onlyOperator {
        if (config.tokenAddress == address(0)) revert InvalidAddress();
        if (config.useOracle && config.priceOracle == address(0)) revert InvalidAddress();
        if (!config.useOracle && config.conversionRate == 0) revert InvalidConfiguration();
        if (config.decimals == 0 || config.decimals > 18) revert InvalidConfiguration();
        
        assetConfigs[assetType] = config;
        
        emit AssetConfigured(
            assetType,
            config.tokenAddress,
            config.priceOracle,
            config.conversionRate,
            config.useOracle
        );
    }
    
    /**
     * @notice Load reserves for an asset type
     * @param assetType Type of asset to load
     * @param amount Amount to load
     */
    function loadReserve(
        AssetType assetType,
        uint256 amount
    ) external onlyOperator nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        AssetConfig memory config = assetConfigs[assetType];
        if (!config.isActive) revert AssetNotActive();
        
        // Transfer tokens to vault
        IERC20(config.tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update reserves
        totalReserves[assetType] += amount;
        
        emit ReserveLoaded(assetType, amount, totalReserves[assetType]);
    }
    
    /**
     * @notice Withdraw excess reserves
     * @param assetType Type of asset to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawExcessReserves(
        AssetType assetType,
        uint256 amount,
        address recipient
    ) external onlyAdmin nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        
        uint256 available = totalReserves[assetType] - totalAllocated[assetType];
        if (amount > available) revert InsufficientReserves();
        
        AssetConfig memory config = assetConfigs[assetType];
        totalReserves[assetType] -= amount;
        
        IERC20(config.tokenAddress).safeTransfer(recipient, amount);
    }
    
    // ========== Series Management ==========
    
    /**
     * @notice Initialize a new series with estimated reserve requirements
     * @param seriesId Series identifier
     * @param estimatedAmounts Array of estimated amounts [OIL, CBG, USDC]
     */
    function initializeSeries(
        uint256 seriesId,
        uint256[3] calldata estimatedAmounts
    ) external onlyAuthorizedCore {
        if (seriesInitialized[seriesId]) revert SeriesNotInitialized();
        
        // Apply buffer to estimates
        uint256 oilAllocation = (estimatedAmounts[0] * ALLOCATION_BUFFER_PERCENT) / PERCENT_PRECISION;
        uint256 cbgAllocation = (estimatedAmounts[1] * ALLOCATION_BUFFER_PERCENT) / PERCENT_PRECISION;
        uint256 usdcAllocation = (estimatedAmounts[2] * ALLOCATION_BUFFER_PERCENT) / PERCENT_PRECISION;
        
        // Verify sufficient reserves
        if (totalReserves[AssetType.OIL] - totalAllocated[AssetType.OIL] < oilAllocation) {
            revert InsufficientReserves();
        }
        if (totalReserves[AssetType.CBG] - totalAllocated[AssetType.CBG] < cbgAllocation) {
            revert InsufficientReserves();
        }
        if (totalReserves[AssetType.USDC] - totalAllocated[AssetType.USDC] < usdcAllocation) {
            revert InsufficientReserves();
        }
        
        // Allocate reserves
        seriesAllocated[seriesId][AssetType.OIL] = oilAllocation;
        seriesAllocated[seriesId][AssetType.CBG] = cbgAllocation;
        seriesAllocated[seriesId][AssetType.USDC] = usdcAllocation;
        
        totalAllocated[AssetType.OIL] += oilAllocation;
        totalAllocated[AssetType.CBG] += cbgAllocation;
        totalAllocated[AssetType.USDC] += usdcAllocation;
        
        seriesInitialized[seriesId] = true;
        totalSeriesInitialized++;
        
        emit SeriesInitialized(seriesId, oilAllocation, cbgAllocation, usdcAllocation);
    }
    
    /**
     * @notice Adjust series allocation for a specific asset
     * @param seriesId Series identifier
     * @param assetType Asset to adjust
     * @param newAmount New allocation amount
     */
    function adjustSeriesAllocation(
        uint256 seriesId,
        AssetType assetType,
        uint256 newAmount
    ) external onlyOperator {
        if (!seriesInitialized[seriesId]) revert SeriesNotInitialized();
        
        uint256 currentAllocation = seriesAllocated[seriesId][assetType];
        uint256 releasedAmount = seriesReleased[seriesId][assetType];
        
        // Can't reduce below already released amount
        if (newAmount < releasedAmount) revert InvalidAmount();
        
        if (newAmount > currentAllocation) {
            // Increasing allocation
            uint256 increase = newAmount - currentAllocation;
            uint256 available = totalReserves[assetType] - totalAllocated[assetType];
            if (increase > available) revert InsufficientReserves();
            
            totalAllocated[assetType] += increase;
        } else if (newAmount < currentAllocation) {
            // Decreasing allocation
            uint256 decrease = currentAllocation - newAmount;
            totalAllocated[assetType] -= decrease;
        }
        
        uint256 oldAmount = seriesAllocated[seriesId][assetType];
        seriesAllocated[seriesId][assetType] = newAmount;
        
        emit AllocationAdjusted(seriesId, assetType, oldAmount, newAmount);
    }
    
    // ========== Token Release ==========
    
    /**
     * @notice Release tokens for a burned NFT
     * @param recipient Address to receive tokens
     * @param tokenId NFT token ID
     * @param seriesId Series ID
     * @param amount Amount to release
     * @param assetType Asset type to release
     */
    function releaseTokens(
        address recipient,
        uint256 tokenId,
        uint256 seriesId,
        uint256 amount,
        uint8 assetType
    ) external onlyAuthorizedCore nonReentrant whenNotPaused {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (tokenProcessed[tokenId]) revert TokenAlreadyProcessed();
        if (assetType > uint8(AssetType.USDC)) revert InvalidAssetType();
        
        AssetType asset = AssetType(assetType);
        AssetConfig memory config = assetConfigs[asset];
        
        if (!config.isActive) revert AssetNotActive();
        if (amount < config.minRedemption) revert BelowMinimumRedemption();
        if (!seriesInitialized[seriesId]) revert SeriesNotInitialized();
        
        // Check series has sufficient allocated reserves
        uint256 seriesAvailable = seriesAllocated[seriesId][asset] - seriesReleased[seriesId][asset];
        if (amount > seriesAvailable) revert InsufficientReserves();
        
        // Update accounting
        tokenProcessed[tokenId] = true;
        tokenRecipient[tokenId] = recipient;
        tokenReleasedAmount[tokenId] = amount;
        tokenReleasedAsset[tokenId] = asset;
        
        seriesReleased[seriesId][asset] += amount;
        totalReleased[asset] += amount;
        totalTokensProcessed++;
        totalTokensReleasedByAsset[asset]++;
        
        // Transfer tokens
        IERC20(config.tokenAddress).safeTransfer(recipient, amount);
        
        emit TokensReleased(tokenId, seriesId, recipient, asset, amount);
    }
    
    /**
     * @notice Batch release tokens for multiple burns
     * @param requests Array of release requests
     */
    function batchRelease(
        ReleaseRequest[] calldata requests
    ) external onlyAuthorizedCore nonReentrant whenNotPaused {
        uint256 count = requests.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        uint256[3] memory totalsByAsset;
        
        for (uint256 i = 0; i < count; i++) {
            ReleaseRequest calldata req = requests[i];
            
            if (req.recipient == address(0)) revert InvalidAddress();
            if (req.amount == 0) revert InvalidAmount();
            if (tokenProcessed[req.tokenId]) revert TokenAlreadyProcessed();
            if (uint8(req.assetType) > uint8(AssetType.USDC)) revert InvalidAssetType();
            
            AssetConfig memory config = assetConfigs[req.assetType];
            
            if (!config.isActive) revert AssetNotActive();
            if (req.amount < config.minRedemption) revert BelowMinimumRedemption();
            if (!seriesInitialized[req.seriesId]) revert SeriesNotInitialized();
            
            // Check series has sufficient allocated reserves
            uint256 seriesAvailable = seriesAllocated[req.seriesId][req.assetType] - 
                                     seriesReleased[req.seriesId][req.assetType];
            if (req.amount > seriesAvailable) revert InsufficientReserves();
            
            // Update accounting
            tokenProcessed[req.tokenId] = true;
            tokenRecipient[req.tokenId] = req.recipient;
            tokenReleasedAmount[req.tokenId] = req.amount;
            tokenReleasedAsset[req.tokenId] = req.assetType;
            
            seriesReleased[req.seriesId][req.assetType] += req.amount;
            totalReleased[req.assetType] += req.amount;
            totalTokensProcessed++;
            totalTokensReleasedByAsset[req.assetType]++;
            
            totalsByAsset[uint8(req.assetType)] += req.amount;
            
            // Transfer tokens
            IERC20(config.tokenAddress).safeTransfer(req.recipient, req.amount);
            
            emit TokensReleased(req.tokenId, req.seriesId, req.recipient, req.assetType, req.amount);
        }
        
        emit BatchReleaseCompleted(
            count,
            totalsByAsset[0],
            totalsByAsset[1],
            totalsByAsset[2]
        );
    }
    
    // ========== View Functions ==========
    
    /**
     * @notice Get reserve status for an asset type
     * @param assetType Asset to query
     * @return status Reserve status details
     */
    function getAssetReserveStatus(
        AssetType assetType
    ) external view returns (ReserveStatus memory status) {
        status.totalReserves = totalReserves[assetType];
        status.totalAllocated = totalAllocated[assetType];
        status.totalReleased = totalReleased[assetType];
        status.availableReserves = status.totalReserves - status.totalReleased;
        status.unallocatedReserves = status.totalReserves - status.totalAllocated;
    }
    
    /**
     * @notice Get series allocation for a specific asset
     * @param seriesId Series to query
     * @param assetType Asset to query
     * @return allocation Series allocation details
     */
    function getSeriesAllocation(
        uint256 seriesId,
        AssetType assetType
    ) external view returns (SeriesAllocation memory allocation) {
        allocation.allocated = seriesAllocated[seriesId][assetType];
        allocation.released = seriesReleased[seriesId][assetType];
        allocation.available = allocation.allocated - allocation.released;
        allocation.initialized = seriesInitialized[seriesId];
    }
    
    /**
     * @notice Get all series allocations
     * @param seriesId Series to query
     * @return oil OIL allocation details
     * @return cbg CBG allocation details
     * @return usdc USDC allocation details
     */
    function getAllSeriesAllocations(uint256 seriesId) external view returns (
        SeriesAllocation memory oil,
        SeriesAllocation memory cbg,
        SeriesAllocation memory usdc
    ) {
        oil = SeriesAllocation({
            allocated: seriesAllocated[seriesId][AssetType.OIL],
            released: seriesReleased[seriesId][AssetType.OIL],
            available: seriesAllocated[seriesId][AssetType.OIL] - seriesReleased[seriesId][AssetType.OIL],
            initialized: seriesInitialized[seriesId]
        });
        
        cbg = SeriesAllocation({
            allocated: seriesAllocated[seriesId][AssetType.CBG],
            released: seriesReleased[seriesId][AssetType.CBG],
            available: seriesAllocated[seriesId][AssetType.CBG] - seriesReleased[seriesId][AssetType.CBG],
            initialized: seriesInitialized[seriesId]
        });
        
        usdc = SeriesAllocation({
            allocated: seriesAllocated[seriesId][AssetType.USDC],
            released: seriesReleased[seriesId][AssetType.USDC],
            available: seriesAllocated[seriesId][AssetType.USDC] - seriesReleased[seriesId][AssetType.USDC],
            initialized: seriesInitialized[seriesId]
        });
    }
    
    /**
     * @notice Get token release details
     * @param tokenId Token to query
     * @return processed Whether token has been processed
     * @return recipient Address that received tokens
     * @return amount Amount released
     * @return assetType Asset type released
     */
    function getTokenReleaseDetails(uint256 tokenId) external view returns (
        bool processed,
        address recipient,
        uint256 amount,
        AssetType assetType
    ) {
        processed = tokenProcessed[tokenId];
        recipient = tokenRecipient[tokenId];
        amount = tokenReleasedAmount[tokenId];
        assetType = tokenReleasedAsset[tokenId];
    }
    
    /**
     * @notice Check if reserves are sufficient for a release
     * @param seriesId Series ID
     * @param assetType Asset type
     * @param amount Amount to check
     * @return sufficient Whether reserves are sufficient
     * @return available Available amount in series
     */
    function checkReserveSufficiency(
        uint256 seriesId,
        AssetType assetType,
        uint256 amount
    ) external view returns (bool sufficient, uint256 available) {
        if (!seriesInitialized[seriesId]) {
            return (false, 0);
        }
        
        available = seriesAllocated[seriesId][assetType] - seriesReleased[seriesId][assetType];
        sufficient = amount <= available && assetConfigs[assetType].isActive;
    }
    
    /**
     * @notice Get current conversion rate for an asset
     * @param assetType Asset to query
     * @return rate Current conversion rate
     * @return isLive Whether rate is from live oracle
     */
    function getConversionRate(AssetType assetType) external view returns (uint256 rate, bool isLive) {
        AssetConfig memory config = assetConfigs[assetType];
        
        if (!config.useOracle) {
            return (config.conversionRate, false);
        }
        
        if (config.priceOracle == address(0)) {
            return (0, false);
        }
        
        try AggregatorV3Interface(config.priceOracle).latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (price > 0 && block.timestamp - updatedAt <= PRICE_STALENESS_THRESHOLD) {
                return (uint256(price), true);
            }
        } catch {
            // Oracle call failed
        }
        
        return (0, false);
    }
    
    // ========== Emergency Functions ==========
    
    /**
     * @notice Pause all operations
     */
    function pause() external onlyAdmin {
        _pause();
    }
    
    /**
     * @notice Unpause operations
     */
    function unpause() external onlyAdmin {
        _unpause();
    }
    
    /**
     * @notice Emergency token recovery
     * @param token Token to recover
     * @param to Recipient
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        if (to == address(0)) revert InvalidAddress();
        
        // Prevent recovery of active reserve tokens
        for (uint8 i = 0; i <= uint8(AssetType.USDC); i++) {
            AssetConfig memory config = assetConfigs[AssetType(i)];
            if (config.tokenAddress == token && config.isActive) {
                revert Unauthorized();
            }
        }
        
        IERC20(token).safeTransfer(to, amount);
    }
}
