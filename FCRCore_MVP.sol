// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title FCRCore_MVP
 * @author Petroleum Club
 * @notice Minimal viable FCR system with fixed USDC pricing for purchases and oracle-based redemptions
 * @dev Optimized for minimal oracle usage during issuance phase
 */
contract FCRCore_MVP is ERC721Enumerable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // ========== Custom Errors ==========
    error Unauthorized();
    error InvalidConfiguration();
    error SeriesNotActive();
    error InsufficientSupply();
    error InvalidAmount();
    error TransferFailed();
    error TokenNotOwned();
    error TokenNotMature();
    error TokenAlreadyBurned();
    error SlippageExceeded();
    error OracleError();
    error StalePrice();
    error InvalidAddress();
    error InvalidSeriesId();
    error InvalidTokenId();
    error BurnedTokenTransfer();
    error PaymentBelowMinimum();
    error PaymentAboveMaximum();

    // ========== Type Declarations ==========
    enum RedemptionAsset { OIL, CBG, USDC }
    
    struct FCRMetadata {
        uint256 seriesId;
        uint256 barrelsPurchased;
        uint256 bonusBarrels;
        uint256 totalBarrels;
        uint256 usdcPaid;           // Amount of USDC paid
        uint256 purchaseTimestamp;
        uint256 maturityTimestamp;
        address originalPurchaser;
    }
    
    struct SeriesConfig {
        string name;
        uint256 maxSupply;
        uint256 currentSupply;
        uint256 pricePerBarrelUSDC;  // Fixed price in USDC (6 decimals)
        uint256 yieldBonusPercent;   // Basis points
        uint256 lockupPeriod;        // Seconds
        bool isActive;
        uint256 createdAt;
        uint256 totalUSDCCollected;
        uint256 totalBarrelsReserved;
    }
    
    struct RedemptionConfig {
        bool useOracle;
        address oracle;              // Chainlink oracle address
        uint256 fixedRate;          // Fixed conversion rate (18 decimals)
        uint256 lastOraclePrice;    // Cached oracle price
        uint256 lastOracleUpdate;   // Timestamp of last update
        uint256 governanceBonus;    // Basis points
    }

    // ========== Constants ==========
    uint256 public constant PERCENT_PRECISION = 10000;
    uint256 public constant PROTOCOL_FEE_PERCENT = 200; // 2%
    uint256 public constant MIN_PURCHASE_USDC = 100e6;  // $100 minimum
    uint256 public constant MAX_PURCHASE_USDC = 1000000e6; // $1M maximum
    uint256 public constant ORACLE_STALENESS_THRESHOLD = 3600; // 1 hour
    
    // Governance bonuses
    uint256 public constant GOVERNANCE_BONUS_OIL = 500;   // 5%
    uint256 public constant GOVERNANCE_BONUS_CBG = 400;   // 4%
    uint256 public constant GOVERNANCE_BONUS_USDC = 200;  // 2%
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ========== State Variables ==========
    
    // Token Management
    uint256 private _tokenIdCounter = 1;
    uint256 private _seriesIdCounter = 1;
    mapping(uint256 => FCRMetadata) public nftMetadata;
    mapping(uint256 => bool) public isTokenBurned;
    
    // Series Management
    mapping(uint256 => SeriesConfig) public seriesConfigs;
    EnumerableSet.UintSet private _activeSeriesIds;
    
    // Redemption Configuration (only used during burns)
    mapping(RedemptionAsset => RedemptionConfig) public redemptionConfigs;
    
    // External Contracts
    IERC20 public immutable usdcToken;
    IUnifiedReserveVault public immutable reserveVault;
    IPaymentProcessor public immutable paymentProcessor;
    IERC20 public immutable governanceToken;
    
    // Access Control
    mapping(address => bool) public isAdmin;
    mapping(address => bool) public isOperator;
    
    // Statistics
    uint256 public totalTokensMinted;
    uint256 public totalTokensBurned;
    uint256 public totalUSDCCollected;
    uint256 public totalProtocolFeesCollected;
    mapping(RedemptionAsset => uint256) public totalRedeemedByAsset;

    // ========== Events ==========
    event SeriesCreated(
        uint256 indexed seriesId,
        string name,
        uint256 maxSupply,
        uint256 pricePerBarrelUSDC,
        uint256 yieldBonusPercent,
        uint256 lockupPeriod
    );
    
    event TokenPurchased(
        uint256 indexed tokenId,
        uint256 indexed seriesId,
        address indexed buyer,
        uint256 totalBarrels,
        uint256 usdcPaid
    );
    
    event TokenBurned(
        uint256 indexed tokenId,
        address indexed owner,
        RedemptionAsset indexed asset,
        uint256 amountReceived,
        uint256 conversionRate
    );
    
    event RedemptionConfigUpdated(
        RedemptionAsset indexed asset,
        bool useOracle,
        address oracle,
        uint256 fixedRate
    );
    
    event SeriesStatusUpdated(uint256 indexed seriesId, bool isActive);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    // ========== Constructor ==========
    constructor(
        string memory _name,
        string memory _symbol,
        address _usdcToken,
        address _reserveVault,
        address _paymentProcessor,
        address _governanceToken,
        address _admin
    ) ERC721(_name, _symbol) {
        if (_usdcToken == address(0) || 
            _reserveVault == address(0) || 
            _paymentProcessor == address(0) || 
            _governanceToken == address(0) ||
            _admin == address(0)) revert InvalidAddress();
            
        usdcToken = IERC20(_usdcToken);
        reserveVault = IUnifiedReserveVault(_reserveVault);
        paymentProcessor = IPaymentProcessor(_paymentProcessor);
        governanceToken = IERC20(_governanceToken);
        
        isAdmin[_admin] = true;
        isOperator[_admin] = true;
        
        // Initialize redemption configs with defaults
        redemptionConfigs[RedemptionAsset.OIL] = RedemptionConfig({
            useOracle: false,
            oracle: address(0),
            fixedRate: 1e18, // 1:1 ratio
            lastOraclePrice: 0,
            lastOracleUpdate: 0,
            governanceBonus: GOVERNANCE_BONUS_OIL
        });
        
        redemptionConfigs[RedemptionAsset.CBG] = RedemptionConfig({
            useOracle: false,
            oracle: address(0),
            fixedRate: 0, // Must be set before use
            lastOraclePrice: 0,
            lastOracleUpdate: 0,
            governanceBonus: GOVERNANCE_BONUS_CBG
        });
        
        redemptionConfigs[RedemptionAsset.USDC] = RedemptionConfig({
            useOracle: true, // Will need oil price oracle
            oracle: address(0), // Must be set before USDC redemptions
            fixedRate: 0,
            lastOraclePrice: 0,
            lastOracleUpdate: 0,
            governanceBonus: GOVERNANCE_BONUS_USDC
        });
        
        emit RoleGranted(ADMIN_ROLE, _admin);
        emit RoleGranted(OPERATOR_ROLE, _admin);
    }

    // ========== Modifiers ==========
    
    modifier onlyAdmin() {
        if (!isAdmin[msg.sender]) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert Unauthorized();
        _;
    }

    // ========== Series Management ==========
    
    /**
     * @notice Create a new series with fixed USDC pricing
     * @param name Series name
     * @param maxSupply Maximum NFTs in this series
     * @param pricePerBarrelUSDC Price per barrel in USDC (6 decimals)
     * @param yieldBonusPercent Yield bonus in basis points
     * @param lockupPeriod Time until maturity in seconds
     * @return seriesId The created series ID
     */
    function createSeries(
        string calldata name,
        uint256 maxSupply,
        uint256 pricePerBarrelUSDC,
        uint256 yieldBonusPercent,
        uint256 lockupPeriod
    ) external onlyOperator returns (uint256 seriesId) {
        if (maxSupply == 0 || pricePerBarrelUSDC == 0) revert InvalidConfiguration();
        if (yieldBonusPercent > PERCENT_PRECISION) revert InvalidConfiguration();
        if (lockupPeriod < 1 days || lockupPeriod > 1095 days) revert InvalidConfiguration();
        
        seriesId = _seriesIdCounter++;
        
        seriesConfigs[seriesId] = SeriesConfig({
            name: name,
            maxSupply: maxSupply,
            currentSupply: 0,
            pricePerBarrelUSDC: pricePerBarrelUSDC,
            yieldBonusPercent: yieldBonusPercent,
            lockupPeriod: lockupPeriod,
            isActive: true,
            createdAt: block.timestamp,
            totalUSDCCollected: 0,
            totalBarrelsReserved: 0
        });
        
        _activeSeriesIds.add(seriesId);
        
        // Initialize reserves (estimated amounts)
        uint256 estimatedBarrels = maxSupply + (maxSupply * yieldBonusPercent / PERCENT_PRECISION);
        uint256 estimatedOIL = estimatedBarrels * 1e18;
        uint256 estimatedCBG = estimatedOIL / 2; // Conservative estimate
        uint256 estimatedUSDC = estimatedBarrels * pricePerBarrelUSDC;
        
        reserveVault.initializeSeries(
            seriesId,
            [estimatedOIL, estimatedCBG, estimatedUSDC]
        );
        
        emit SeriesCreated(
            seriesId,
            name,
            maxSupply,
            pricePerBarrelUSDC,
            yieldBonusPercent,
            lockupPeriod
        );
    }
    
    /**
     * @notice Update series active status
     * @param seriesId Series to update
     * @param isActive New status
     */
    function updateSeriesStatus(uint256 seriesId, bool isActive) external onlyOperator {
        if (seriesId == 0 || seriesId >= _seriesIdCounter) revert InvalidSeriesId();
        
        seriesConfigs[seriesId].isActive = isActive;
        
        if (isActive) {
            _activeSeriesIds.add(seriesId);
        } else {
            _activeSeriesIds.remove(seriesId);
        }
        
        emit SeriesStatusUpdated(seriesId, isActive);
    }

    // ========== Purchase Functions (No Oracles Needed) ==========
    
    /**
     * @notice Purchase FCR NFT with USDC at fixed price
     * @param seriesId Series to purchase from
     * @param barrelsToPurchase Number of barrels to purchase
     * @return tokenId The minted NFT ID
     */
    function purchaseFCR(
        uint256 seriesId,
        uint256 barrelsToPurchase
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        // Validate series
        SeriesConfig storage series = seriesConfigs[seriesId];
        if (!series.isActive) revert SeriesNotActive();
        if (series.currentSupply >= series.maxSupply) revert InsufficientSupply();
        if (barrelsTopurchase == 0) revert InvalidAmount();
        
        // Calculate costs (no oracle needed!)
        uint256 totalCostUSDC = barrelsTopurchase * series.pricePerBarrelUSDC;
        uint256 protocolFee = (totalCostUSDC * PROTOCOL_FEE_PERCENT) / PERCENT_PRECISION;
        uint256 netCostUSDC = totalCostUSDC - protocolFee;
        
        // Validate purchase limits
        if (totalCostUSDC < MIN_PURCHASE_USDC) revert PaymentBelowMinimum();
        if (totalCostUSDC > MAX_PURCHASE_USDC) revert PaymentAboveMaximum();
        
        // Calculate barrels with bonus
        uint256 bonusBarrels = (barrelsTourchase * series.yieldBonusPercent) / PERCENT_PRECISION;
        uint256 totalBarrels = barrelsTourchase + bonusBarrels;
        
        // Process USDC payment
        usdcToken.safeTransferFrom(msg.sender, address(this), totalCostUSDC);
        usdcToken.safeApprove(address(paymentProcessor), totalCostUSDC);
        paymentProcessor.processPayment(msg.sender, address(usdcToken), totalCostUSDC, seriesId);
        
        // Mint NFT
        tokenId = _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);
        
        // Store metadata
        nftMetadata[tokenId] = FCRMetadata({
            seriesId: seriesId,
            barrelsPurchased: barrelsTourchase,
            bonusBarrels: bonusBarrels,
            totalBarrels: totalBarrels,
            usdcPaid: netCostUSDC,
            purchaseTimestamp: block.timestamp,
            maturityTimestamp: block.timestamp + series.lockupPeriod,
            originalPurchaser: msg.sender
        });
        
        // Update statistics
        series.currentSupply++;
        series.totalUSDCCollected += netCostUSDC;
        series.totalBarrelsReserved += totalBarrels;
        totalTokensMinted++;
        totalUSDCCollected += totalCostUSDC;
        totalProtocolFeesCollected += protocolFee;
        
        emit TokenPurchased(tokenId, seriesId, msg.sender, totalBarrels, netCostUSDC);
    }

    // ========== Redemption Functions (Oracles Used Here) ==========
    
    /**
     * @notice Burn NFT and redeem for chosen asset
     * @param tokenId Token to burn
     * @param asset Asset to receive
     * @param minAmountOut Minimum amount to receive
     * @return amountReceived Amount received
     */
    function burnForAsset(
        uint256 tokenId,
        RedemptionAsset asset,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountReceived) {
        // Validate ownership and status
        if (ownerOf(tokenId) != msg.sender) revert TokenNotOwned();
        if (isTokenBurned[tokenId]) revert TokenAlreadyBurned();
        
        FCRMetadata memory metadata = nftMetadata[tokenId];
        if (block.timestamp < metadata.maturityTimestamp) revert TokenNotMature();
        
        // Get redemption amount (this is where oracles are used)
        (uint256 amount, uint256 rate) = _calculateRedemptionAmount(metadata, asset, msg.sender);
        if (amount < minAmountOut) revert SlippageExceeded();
        
        // Mark as burned
        isTokenBurned[tokenId] = true;
        totalTokensBurned++;
        totalRedeemedByAsset[asset] += amount;
        amountReceived = amount;
        
        // Release from vault
        reserveVault.releaseTokens(
            msg.sender,
            tokenId,
            metadata.seriesId,
            amount,
            uint8(asset)
        );
        
        emit TokenBurned(tokenId, msg.sender, asset, amount, rate);
    }
    
    /**
     * @notice Calculate redemption amount using oracles when necessary
     * @param metadata Token metadata
     * @param asset Redemption asset
     * @param owner Token owner
     * @return amount Amount to receive
     * @return rate Conversion rate used
     */
    function _calculateRedemptionAmount(
        FCRMetadata memory metadata,
        RedemptionAsset asset,
        address owner
    ) private view returns (uint256 amount, uint256 rate) {
        RedemptionConfig memory config = redemptionConfigs[asset];
        
        // Get conversion rate
        if (config.useOracle) {
            // Only USDC redemptions typically need oracle (for oil price)
            if (config.oracle == address(0)) revert OracleError();
            
            try AggregatorV3Interface(config.oracle).latestRoundData() returns (
                uint80,
                int256 price,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (price <= 0) revert OracleError();
                if (block.timestamp - updatedAt > ORACLE_STALENESS_THRESHOLD) revert StalePrice();
                rate = uint256(price);
            } catch {
                revert OracleError();
            }
        } else {
            // Use fixed rate for OIL and CBG
            rate = config.fixedRate;
            if (rate == 0) revert InvalidConfiguration();
        }
        
        // Calculate base amount
        if (asset == RedemptionAsset.OIL) {
            // Simple 1:1 conversion
            amount = metadata.totalBarrels * 1e18;
        } else if (asset == RedemptionAsset.CBG) {
            // Apply CBG conversion rate
            amount = (metadata.totalBarrels * rate) / 1e18;
        } else if (asset == RedemptionAsset.USDC) {
            // Convert barrels to USDC using oil price oracle
            // Oracle returns price in USD with 8 decimals, convert to USDC (6 decimals)
            amount = (metadata.totalBarrels * rate) / 1e20; // Adjust for decimals
        }
        
        // Apply governance bonus if holder has tokens
        if (governanceToken.balanceOf(owner) > 0) {
            uint256 bonus = (amount * config.governanceBonus) / PERCENT_PRECISION;
            amount += bonus;
        }
    }

    // ========== Configuration Functions ==========
    
    /**
     * @notice Configure redemption asset (oracle or fixed rate)
     * @param asset Asset to configure
     * @param useOracle Whether to use oracle pricing
     * @param oracle Oracle address (if using oracle)
     * @param fixedRate Fixed rate (if not using oracle)
     */
    function configureRedemptionAsset(
        RedemptionAsset asset,
        bool useOracle,
        address oracle,
        uint256 fixedRate
    ) external onlyAdmin {
        if (useOracle && oracle == address(0)) revert InvalidAddress();
        if (!useOracle && fixedRate == 0) revert InvalidConfiguration();
        
        redemptionConfigs[asset] = RedemptionConfig({
            useOracle: useOracle,
            oracle: oracle,
            fixedRate: fixedRate,
            lastOraclePrice: 0,
            lastOracleUpdate: 0,
            governanceBonus: redemptionConfigs[asset].governanceBonus
        });
        
        emit RedemptionConfigUpdated(asset, useOracle, oracle, fixedRate);
    }
    
    /**
     * @notice Grant role to an address
     * @param role Role to grant
     * @param account Address to grant role to
     */
    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (role == ADMIN_ROLE) {
            isAdmin[account] = true;
        } else if (role == OPERATOR_ROLE) {
            isOperator[account] = true;
        }
        emit RoleGranted(role, account);
    }
    
    /**
     * @notice Revoke role from an address
     * @param role Role to revoke
     * @param account Address to revoke role from
     */
    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (role == ADMIN_ROLE) {
            isAdmin[account] = false;
        } else if (role == OPERATOR_ROLE) {
            isOperator[account] = false;
        }
        emit RoleRevoked(role, account);
    }

    // ========== View Functions ==========
    
    /**
     * @notice Get redemption quote for a token
     * @param tokenId Token ID
     * @param asset Redemption asset
     * @return amount Amount to receive
     * @return rate Conversion rate
     * @return isReady Whether token is ready for redemption
     */
    function getRedemptionQuote(
        uint256 tokenId,
        RedemptionAsset asset
    ) external view returns (uint256 amount, uint256 rate, bool isReady) {
        if (tokenId == 0 || tokenId >= _tokenIdCounter) revert InvalidTokenId();
        if (isTokenBurned[tokenId]) return (0, 0, false);
        
        FCRMetadata memory metadata = nftMetadata[tokenId];
        isReady = block.timestamp >= metadata.maturityTimestamp;
        
        if (isReady) {
            (amount, rate) = _calculateRedemptionAmount(metadata, asset, ownerOf(tokenId));
        }
    }
    
    /**
     * @notice Calculate USDC cost for barrel purchase (no oracle needed)
     * @param seriesId Series ID
     * @param barrelsTourchase Number of barrels
     * @return totalCost Total USDC cost
     * @return protocolFee Protocol fee amount
     * @return netCost Net cost after fee
     */
    function calculatePurchaseCost(
        uint256 seriesId,
        uint256 barrelsTourchase
    ) external view returns (uint256 totalCost, uint256 protocolFee, uint256 netCost) {
        SeriesConfig memory series = seriesConfigs[seriesId];
        totalCost = barrelsTourchase * series.pricePerBarrelUSDC;
        protocolFee = (totalCost * PROTOCOL_FEE_PERCENT) / PERCENT_PRECISION;
        netCost = totalCost - protocolFee;
    }
    
    /**
     * @notice Get all active series
     * @return Array of active series IDs
     */
    function getActiveSeries() external view returns (uint256[] memory) {
        return _activeSeriesIds.values();
    }
    
    /**
     * @notice Check if token is mature
     * @param tokenId Token ID
     * @return Whether token is mature
     */
    function isTokenMature(uint256 tokenId) external view returns (bool) {
        if (tokenId == 0 || tokenId >= _tokenIdCounter) return false;
        return block.timestamp >= nftMetadata[tokenId].maturityTimestamp;
    }
    
    /**
     * @notice Get series information
     * @param seriesId Series ID
     * @return config Series configuration
     * @return remainingSupply Remaining supply
     */
    function getSeriesInfo(uint256 seriesId) external view returns (
        SeriesConfig memory config,
        uint256 remainingSupply
    ) {
        config = seriesConfigs[seriesId];
        remainingSupply = config.maxSupply - config.currentSupply;
    }

    // ========== Internal Functions ==========
    
    /**
     * @notice Override transfer to prevent burned token transfers
     */
    function _transfer(address from, address to, uint256 tokenId) internal override {
        if (isTokenBurned[tokenId]) revert BurnedTokenTransfer();
        super._transfer(from, to, tokenId);
    }

    // ========== Admin Functions ==========
    
    /**
     * @notice Pause contract
     */
    function pause() external onlyAdmin {
        _pause();
    }
    
    /**
     * @notice Unpause contract
     */
    function unpause() external onlyAdmin {
        _unpause();
    }
}

// ========== Interfaces ==========

interface IUnifiedReserveVault {
    function initializeSeries(uint256 seriesId, uint256[3] memory estimatedAmounts) external;
    function releaseTokens(address recipient, uint256 tokenId, uint256 seriesId, uint256 amount, uint8 assetType) external;
}

interface IPaymentProcessor {
    function processPayment(address buyer, address token, uint256 amount, uint256 seriesId) external returns (bool);
}
