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
 * @title CBGTradeDesk
 * @author Petroleum Club
 * @notice Core contract for Crypto Black Gold (CBG) NFT system with integrated series management and multi-asset redemption
 * @dev Combines NFT, factory, and burn management functionality into a single optimized contract
 */
contract CBGTradeDesk is ERC721Enumerable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== Custom Errors ==========
    error Unauthorized();
    error InvalidConfiguration();
    error SeriesNotActive();
    error InsufficientSupply();
    error PaymentTokenNotAccepted();
    error InvalidAmount();
    error BelowMinimumPurchase();
    error AboveMaximumPurchase();
    error TransferFailed();
    error TokenNotOwned();
    error TokenNotMature();
    error TokenAlreadyBurned();
    error InvalidRedemptionAsset();
    error SlippageExceeded();
    error OracleError();
    error StalePrice();
    error InvalidAddress();
    error InvalidSeriesId();
    error InvalidTokenId();
    error BatchSizeExceeded();
    error ArrayLengthMismatch();
    error SeriesAlreadyExists();

    // ========== Type Declarations ==========
    enum RedemptionAsset { OIL, CBG, USDC }
    
    struct CBGMetadata {
        uint256 seriesId;
        uint256 barrelsPurchased;
        uint256 bonusBarrels;
        uint256 totalBarrels;
        uint256 usdValuePaid;
        uint256 purchaseTimestamp;
        uint256 maturityTimestamp;
        address paymentToken;
        uint256 tokenAmountPaid;
        address originalPurchaser;
    }
    
    struct SeriesConfig {
        string name;
        uint256 maxSupply;
        uint256 currentSupply;
        uint256 barrelPrice;        // Price per barrel in USD (18 decimals)
        uint256 yieldBonusPercent;  // Percentage bonus (basis points)
        uint256 lockupPeriod;       // Seconds until maturity
        address preferredPaymentToken;
        bool isActive;
        uint256 createdAt;
        uint256 totalUSDCollected;
        uint256 totalBarrelsReserved;
    }
    
    struct PaymentToken {
        bool accepted;
        address priceFeed;
        uint256 minPurchase;    // Minimum USD value (18 decimals)
        uint256 maxPurchase;    // Maximum USD value (18 decimals)
        uint8 decimals;
        uint256 lastPrice;
        uint256 lastPriceUpdate;
    }
    
    struct RedemptionQuote {
        uint256 baseAmount;
        uint256 bonusAmount;
        uint256 totalAmount;
        uint256 conversionRate;
        bool isAvailable;
        string unavailableReason;
    }
    
    struct PurchaseParams {
        uint256 tokenAmount;
        uint256 protocolFee;
        uint256 netUsdAmount;
        uint256 barrelsPurchased;
        uint256 bonusBarrels;
        uint256 totalBarrels;
    }

    // ========== Constants ==========
    uint256 public constant PERCENT_PRECISION = 10000;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant PROTOCOL_FEE_PERCENT = 200; // 2%
    uint256 public constant GOVERNANCE_BONUS_OIL = 300;   // 3%
    uint256 public constant GOVERNANCE_BONUS_CBG = 200;   // 2%
    uint256 public constant GOVERNANCE_BONUS_USDC = 100;  // 1%
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ========== State Variables ==========
    
    // Token Management
    uint256 private _tokenIdCounter = 1;
    uint256 private _seriesIdCounter = 1;
    mapping(uint256 => CBGMetadata) public nftMetadata;
    mapping(uint256 => bool) public isTokenBurned;
    mapping(address => EnumerableSet.UintSet) private _userBurnedTokens;
    
    // Series Management
    mapping(uint256 => SeriesConfig) public seriesConfigs;
    EnumerableSet.UintSet private _activeSeriesIds;
    
    // Payment Management
    mapping(address => PaymentToken) public paymentTokens;
    EnumerableSet.AddressSet private _acceptedTokens;
    
    // External Contracts
    IUnifiedReserveVault public immutable reserveVault;
    IPaymentProcessor public immutable paymentProcessor;
    IERC20 public immutable governanceToken;
    
    // Access Control
    mapping(bytes32 => EnumerableSet.AddressSet) private _roleMembers;
    
    // Oracle Configuration
    mapping(RedemptionAsset => address) public redemptionOracles;
    mapping(RedemptionAsset => uint256) public redemptionRates; // For fixed rates
    mapping(RedemptionAsset => bool) public useOracleForRedemption;
    
    // Statistics
    uint256 public totalSeriesCreated;
    uint256 public totalTokensMinted;
    uint256 public totalTokensBurned;
    uint256 public totalUSDCollected;
    uint256 public totalProtocolFeesCollected;
    mapping(RedemptionAsset => uint256) public totalRedeemedByAsset;

    // ========== Events ==========
    event SeriesCreated(
        uint256 indexed seriesId,
        string name,
        uint256 maxSupply,
        uint256 barrelPrice,
        uint256 yieldBonusPercent,
        uint256 lockupPeriod
    );
    
    event TokenPurchased(
        uint256 indexed tokenId,
        uint256 indexed seriesId,
        address indexed buyer,
        uint256 totalBarrels,
        uint256 usdValue,
        address paymentToken,
        uint256 tokenAmount
    );
    
    event TokenBurned(
        uint256 indexed tokenId,
        address indexed owner,
        RedemptionAsset indexed asset,
        uint256 amountReceived,
        uint256 conversionRate,
        bool governanceBonus
    );
    
    event BatchPurchaseCompleted(
        address indexed buyer,
        uint256 indexed seriesId,
        uint256 tokenCount,
        uint256 totalUSDSpent
    );
    
    event BatchBurnCompleted(
        address indexed burner,
        RedemptionAsset indexed asset,
        uint256 tokenCount,
        uint256 totalReceived
    );
    
    event PaymentTokenConfigured(
        address indexed token,
        bool accepted,
        address priceFeed,
        uint256 minPurchase,
        uint256 maxPurchase
    );
    
    event SeriesUpdated(
        uint256 indexed seriesId,
        bool isActive
    );
    
    event RedemptionAssetConfigured(
        RedemptionAsset indexed asset,
        address oracle,
        uint256 fixedRate,
        bool useOracle
    );
    
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    // ========== Constructor ==========
    constructor(
        string memory _name,
        string memory _symbol,
        address _reserveVault,
        address _paymentProcessor,
        address _governanceToken,
        address _admin
    ) ERC721(_name, _symbol) {
        if (_reserveVault == address(0) || 
            _paymentProcessor == address(0) || 
            _governanceToken == address(0) ||
            _admin == address(0)) revert InvalidAddress();
            
        reserveVault = IUnifiedReserveVault(_reserveVault);
        paymentProcessor = IPaymentProcessor(_paymentProcessor);
        governanceToken = IERC20(_governanceToken);
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        // Initialize default redemption configurations
        redemptionRates[RedemptionAsset.OIL] = 1e18; // 1:1 ratio
        useOracleForRedemption[RedemptionAsset.CBG] = true;
        useOracleForRedemption[RedemptionAsset.USDC] = true;
    }

    // ========== Access Control ==========
    
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }
    
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roleMembers[role].contains(account);
    }
    
    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        if (_roleMembers[role].add(account)) {
            emit RoleGranted(role, account);
        }
    }
    
    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        if (_roleMembers[role].remove(account)) {
            emit RoleRevoked(role, account);
        }
    }
    
    function _grantRole(bytes32 role, address account) private {
        if (_roleMembers[role].add(account)) {
            emit RoleGranted(role, account);
        }
    }

    // ========== Series Management ==========
    
    /**
     * @notice Create a new CBG series with specified parameters
     * @param name Series name
     * @param maxSupply Maximum NFTs that can be minted in this series
     * @param barrelPrice Price per barrel in USD (18 decimals)
     * @param yieldBonusPercent Yield bonus percentage in basis points
     * @param lockupPeriod Time until NFTs mature (in seconds)
     * @param preferredPaymentToken Default payment token for this series
     * @return seriesId The ID of the newly created series
     */
    function createSeries(
        string calldata name,
        uint256 maxSupply,
        uint256 barrelPrice,
        uint256 yieldBonusPercent,
        uint256 lockupPeriod,
        address preferredPaymentToken
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 seriesId) {
        if (maxSupply == 0 || barrelPrice == 0) revert InvalidConfiguration();
        if (yieldBonusPercent > PERCENT_PRECISION) revert InvalidConfiguration();
        if (lockupPeriod < 1 days || lockupPeriod > 1095 days) revert InvalidConfiguration();
        if (!paymentTokens[preferredPaymentToken].accepted) revert PaymentTokenNotAccepted();
        
        seriesId = _seriesIdCounter++;
        
        seriesConfigs[seriesId] = SeriesConfig({
            name: name,
            maxSupply: maxSupply,
            currentSupply: 0,
            barrelPrice: barrelPrice,
            yieldBonusPercent: yieldBonusPercent,
            lockupPeriod: lockupPeriod,
            preferredPaymentToken: preferredPaymentToken,
            isActive: true,
            createdAt: block.timestamp,
            totalUSDCollected: 0,
            totalBarrelsReserved: 0
        });
        
        _activeSeriesIds.add(seriesId);
        totalSeriesCreated++;
        
        // Initialize reserves for this series
        uint256 estimatedBarrels = maxSupply + (maxSupply * yieldBonusPercent / PERCENT_PRECISION);
        uint256 estimatedOIL = estimatedBarrels * 1e18;
        uint256 estimatedCBG = estimatedOIL / 2; // Conservative estimate
        uint256 estimatedUSDC = (estimatedBarrels * barrelPrice) / 1e12; // Convert to USDC decimals
        
        reserveVault.initializeSeries(
            seriesId,
            [estimatedOIL, estimatedCBG, estimatedUSDC]
        );
        
        emit SeriesCreated(
            seriesId,
            name,
            maxSupply,
            barrelPrice,
            yieldBonusPercent,
            lockupPeriod
        );
    }
    
    /**
     * @notice Update series active status
     * @param seriesId Series to update
     * @param isActive New active status
     */
    function updateSeriesStatus(uint256 seriesId, bool isActive) external onlyRole(OPERATOR_ROLE) {
        if (seriesId == 0 || seriesId >= _seriesIdCounter) revert InvalidSeriesId();
        
        seriesConfigs[seriesId].isActive = isActive;
        
        if (isActive) {
            _activeSeriesIds.add(seriesId);
        } else {
            _activeSeriesIds.remove(seriesId);
        }
        
        emit SeriesUpdated(seriesId, isActive);
    }

    // ========== Purchase Functions ==========
    
    /**
     * @notice Purchase a CBG NFT from a specific series
     * @param seriesId Series to purchase from
     * @param usdAmount USD value to spend (18 decimals)
     * @param paymentToken Token to use for payment
     * @param maxTokenAmount Maximum tokens to spend (slippage protection)
     * @return tokenId The minted NFT token ID
     */
    function purchaseCBG(
        uint256 seriesId,
        uint256 usdAmount,
        address paymentToken,
        uint256 maxTokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        tokenId = _purchaseCBGInternal(seriesId, usdAmount, paymentToken, maxTokenAmount);
    }
    
    /**
     * @notice Batch purchase multiple CBG NFTs
     * @param seriesId Series to purchase from
     * @param usdAmounts Array of USD amounts for each NFT
     * @param paymentToken Token to use for payment
     * @param maxTotalTokenAmount Maximum total tokens to spend
     * @return tokenIds Array of minted token IDs
     */
    function batchPurchaseCBG(
        uint256 seriesId,
        uint256[] calldata usdAmounts,
        address paymentToken,
        uint256 maxTotalTokenAmount
    ) external nonReentrant whenNotPaused returns (uint256[] memory tokenIds) {
        uint256 count = usdAmounts.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        tokenIds = new uint256[](count);
        uint256 totalUSD = 0;
        uint256 totalTokenAmount = 0;
        
        // Calculate total cost first
        for (uint256 i = 0; i < count; i++) {
            totalUSD += usdAmounts[i];
            totalTokenAmount += _calculateTokenAmount(paymentToken, usdAmounts[i]);
        }
        
        if (totalTokenAmount > maxTotalTokenAmount) revert SlippageExceeded();
        
        // Process all purchases using internal function
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = _purchaseCBGInternal(seriesId, usdAmounts[i], paymentToken, type(uint256).max);
        }
        
        emit BatchPurchaseCompleted(msg.sender, seriesId, count, totalUSD);
    }
    
    /**
     * @notice Internal function for purchasing CBG NFTs (to avoid stack too deep)
     */
    function _purchaseCBGInternal(
        uint256 seriesId,
        uint256 usdAmount,
        address paymentToken,
        uint256 maxTokenAmount
    ) private returns (uint256 tokenId) {
        // Validate series
        SeriesConfig storage series = seriesConfigs[seriesId];
        if (!series.isActive) revert SeriesNotActive();
        if (series.currentSupply >= series.maxSupply) revert InsufficientSupply();
        
        // Validate payment
        PaymentToken memory paymentConfig = paymentTokens[paymentToken];
        if (!paymentConfig.accepted) revert PaymentTokenNotAccepted();
        if (usdAmount < paymentConfig.minPurchase) revert BelowMinimumPurchase();
        if (usdAmount > paymentConfig.maxPurchase) revert AboveMaximumPurchase();
        
        PurchaseParams memory params;
        
        // Calculate token amount needed
        params.tokenAmount = _calculateTokenAmount(paymentToken, usdAmount);
        if (params.tokenAmount > maxTokenAmount) revert SlippageExceeded();
        
        // Calculate barrels and fees
        params.protocolFee = (usdAmount * PROTOCOL_FEE_PERCENT) / PERCENT_PRECISION;
        params.netUsdAmount = usdAmount - params.protocolFee;
        params.barrelsPurchased = (params.netUsdAmount * 1e18) / series.barrelPrice;
        params.bonusBarrels = (params.barrelsPurchased * series.yieldBonusPercent) / PERCENT_PRECISION;
        params.totalBarrels = params.barrelsPurchased + params.bonusBarrels;
        
        // Process payment
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), params.tokenAmount);
        IERC20(paymentToken).approve(address(paymentProcessor), params.tokenAmount);
        paymentProcessor.processPayment(msg.sender, paymentToken, params.tokenAmount, seriesId);
        
        // Mint NFT
        tokenId = _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);
        
        // Store metadata
        nftMetadata[tokenId] = CBGMetadata({
            seriesId: seriesId,
            barrelsPurchased: params.barrelsPurchased,
            bonusBarrels: params.bonusBarrels,
            totalBarrels: params.totalBarrels,
            usdValuePaid: params.netUsdAmount,
            purchaseTimestamp: block.timestamp,
            maturityTimestamp: block.timestamp + series.lockupPeriod,
            paymentToken: paymentToken,
            tokenAmountPaid: params.tokenAmount,
            originalPurchaser: msg.sender
        });
        
        // Update statistics
        series.currentSupply++;
        series.totalUSDCollected += params.netUsdAmount;
        series.totalBarrelsReserved += params.totalBarrels;
        totalTokensMinted++;
        totalUSDCollected += usdAmount;
        totalProtocolFeesCollected += params.protocolFee;
        
        emit TokenPurchased(
            tokenId,
            seriesId,
            msg.sender,
            params.totalBarrels,
            params.netUsdAmount,
            paymentToken,
            params.tokenAmount
        );
    }

    // ========== Redemption Functions ==========
    
    /**
     * @notice Burn a mature CBG NFT and receive chosen redemption asset
     * @param tokenId Token to burn
     * @param asset Asset to receive (OIL, CBG, or USDC)
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @return amountReceived Amount of tokens received
     */
    function burnForAsset(
        uint256 tokenId,
        RedemptionAsset asset,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountReceived) {
        // Validate ownership and status
        if (ownerOf(tokenId) != msg.sender) revert TokenNotOwned();
        if (isTokenBurned[tokenId]) revert TokenAlreadyBurned();
        
        CBGMetadata memory metadata = nftMetadata[tokenId];
        if (block.timestamp < metadata.maturityTimestamp) revert TokenNotMature();
        
        // Calculate redemption amount
        RedemptionQuote memory quote = _calculateRedemptionQuote(metadata, asset, msg.sender);
        if (!quote.isAvailable) revert InvalidRedemptionAsset();
        
        amountReceived = quote.totalAmount;
        if (amountReceived < minAmountOut) revert SlippageExceeded();
        
        // Mark as burned (don't actually burn the token)
        isTokenBurned[tokenId] = true;
        _userBurnedTokens[msg.sender].add(tokenId);
        totalTokensBurned++;
        totalRedeemedByAsset[asset] += amountReceived;
        
        // Release tokens from vault
        reserveVault.releaseTokens(
            msg.sender,
            tokenId,
            metadata.seriesId,
            amountReceived,
            uint8(asset)
        );
        
        emit TokenBurned(
            tokenId,
            msg.sender,
            asset,
            amountReceived,
            quote.conversionRate,
            quote.bonusAmount > 0
        );
    }
    
    /**
     * @notice Batch burn multiple NFTs for the same redemption asset
     * @param tokenIds Array of token IDs to burn
     * @param asset Asset to receive
     * @param minTotalAmountOut Minimum total amount to receive
     * @return totalReceived Total amount received
     */
    function batchBurnForAsset(
        uint256[] calldata tokenIds,
        RedemptionAsset asset,
        uint256 minTotalAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 totalReceived) {
        uint256 count = tokenIds.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        for (uint256 i = 0; i < count; i++) {
            totalReceived += _burnForAssetInternal(tokenIds[i], asset, 0);
        }
        
        if (totalReceived < minTotalAmountOut) revert SlippageExceeded();
        
        emit BatchBurnCompleted(msg.sender, asset, count, totalReceived);
    }
    
    /**
     * @notice Internal function for burning assets (to avoid stack too deep)
     */
    function _burnForAssetInternal(
        uint256 tokenId,
        RedemptionAsset asset,
        uint256 minAmountOut
    ) private returns (uint256 amountReceived) {
        // Validate ownership and status
        if (ownerOf(tokenId) != msg.sender) revert TokenNotOwned();
        if (isTokenBurned[tokenId]) revert TokenAlreadyBurned();
        
        CBGMetadata memory metadata = nftMetadata[tokenId];
        if (block.timestamp < metadata.maturityTimestamp) revert TokenNotMature();
        
        // Calculate redemption amount
        RedemptionQuote memory quote = _calculateRedemptionQuote(metadata, asset, msg.sender);
        if (!quote.isAvailable) revert InvalidRedemptionAsset();
        
        amountReceived = quote.totalAmount;
        if (amountReceived < minAmountOut) revert SlippageExceeded();
        
        // Mark as burned (don't actually burn the token)
        isTokenBurned[tokenId] = true;
        _userBurnedTokens[msg.sender].add(tokenId);
        totalTokensBurned++;
        totalRedeemedByAsset[asset] += amountReceived;
        
        // Release tokens from vault
        reserveVault.releaseTokens(
            msg.sender,
            tokenId,
            metadata.seriesId,
            amountReceived,
            uint8(asset)
        );
        
        emit TokenBurned(
            tokenId,
            msg.sender,
            asset,
            amountReceived,
            quote.conversionRate,
            quote.bonusAmount > 0
        );
    }

    // ========== Configuration Functions ==========
    
    /**
     * @notice Configure a payment token
     * @param token Token address
     * @param accepted Whether token is accepted
     * @param priceFeed Chainlink price feed address
     * @param minPurchase Minimum purchase in USD (18 decimals)
     * @param maxPurchase Maximum purchase in USD (18 decimals)
     * @param decimals Token decimals
     */
    function configurePaymentToken(
        address token,
        bool accepted,
        address priceFeed,
        uint256 minPurchase,
        uint256 maxPurchase,
        uint8 decimals
    ) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        if (accepted && priceFeed == address(0)) revert InvalidAddress();
        if (maxPurchase < minPurchase) revert InvalidConfiguration();
        
        paymentTokens[token] = PaymentToken({
            accepted: accepted,
            priceFeed: priceFeed,
            minPurchase: minPurchase,
            maxPurchase: maxPurchase,
            decimals: decimals,
            lastPrice: 0,
            lastPriceUpdate: 0
        });
        
        if (accepted) {
            _acceptedTokens.add(token);
        } else {
            _acceptedTokens.remove(token);
        }
        
        emit PaymentTokenConfigured(token, accepted, priceFeed, minPurchase, maxPurchase);
    }
    
    /**
     * @notice Configure redemption asset oracle or fixed rate
     * @param asset Redemption asset to configure
     * @param oracle Oracle address (0 for fixed rate)
     * @param fixedRate Fixed conversion rate (ignored if using oracle)
     * @param useOracle Whether to use oracle pricing
     */
    function configureRedemptionAsset(
        RedemptionAsset asset,
        address oracle,
        uint256 fixedRate,
        bool useOracle
    ) external onlyRole(OPERATOR_ROLE) {
        if (useOracle && oracle == address(0)) revert InvalidAddress();
        if (!useOracle && fixedRate == 0) revert InvalidConfiguration();
        
        redemptionOracles[asset] = oracle;
        redemptionRates[asset] = fixedRate;
        useOracleForRedemption[asset] = useOracle;
        
        emit RedemptionAssetConfigured(asset, oracle, fixedRate, useOracle);
    }

    // ========== View Functions ==========
    
    /**
     * @notice Get redemption quote for a token
     * @param tokenId Token to get quote for
     * @param asset Redemption asset
     * @return quote Detailed redemption quote
     */
    function getRedemptionQuote(
        uint256 tokenId,
        RedemptionAsset asset
    ) external view returns (RedemptionQuote memory quote) {
        if (tokenId == 0 || tokenId >= _tokenIdCounter) revert InvalidTokenId();
        CBGMetadata memory metadata = nftMetadata[tokenId];
        return _calculateRedemptionQuote(metadata, asset, ownerOf(tokenId));
    }
    
    /**
     * @notice Get all active series IDs
     * @return Array of active series IDs
     */
    function getActiveSeries() external view returns (uint256[] memory) {
        return _activeSeriesIds.values();
    }
    
    /**
     * @notice Get all accepted payment tokens
     * @return Array of accepted token addresses
     */
    function getAcceptedPaymentTokens() external view returns (address[] memory) {
        return _acceptedTokens.values();
    }
    
    /**
     * @notice Get user's burned token IDs
     * @param user User address
     * @return Array of burned token IDs
     */
    function getUserBurnedTokens(address user) external view returns (uint256[] memory) {
        return _userBurnedTokens[user].values();
    }
    
    /**
     * @notice Get tokens owned by user in a specific series
     * @param user User address
     * @param seriesId Series ID
     * @return tokenIds Array of token IDs
     */
    function getUserTokensBySeries(
        address user,
        uint256 seriesId
    ) external view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(user);
        uint256[] memory tempIds = new uint256[](balance);
        uint256 count = 0;
        
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(user, i);
            if (nftMetadata[tokenId].seriesId == seriesId && !isTokenBurned[tokenId]) {
                tempIds[count++] = tokenId;
            }
        }
        
        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = tempIds[i];
        }
    }
    
    /**
     * @notice Check if token is mature
     * @param tokenId Token to check
     * @return isMature Whether token has reached maturity
     */
    function isTokenMature(uint256 tokenId) external view returns (bool) {
        if (tokenId == 0 || tokenId >= _tokenIdCounter) return false;
        return block.timestamp >= nftMetadata[tokenId].maturityTimestamp;
    }
    
    /**
     * @notice Get comprehensive series information
     * @param seriesId Series ID
     * @return config Series configuration
     * @return remainingSupply Remaining supply
     * @return percentageSold Percentage sold
     */
    function getSeriesInfo(uint256 seriesId) external view returns (
        SeriesConfig memory config,
        uint256 remainingSupply,
        uint256 percentageSold
    ) {
        config = seriesConfigs[seriesId];
        remainingSupply = config.maxSupply - config.currentSupply;
        percentageSold = config.maxSupply > 0 
            ? (config.currentSupply * PERCENT_PRECISION) / config.maxSupply 
            : 0;
    }

    // ========== Internal Functions ==========
    
    /**
     * @notice Calculate token amount needed for USD value
     * @param token Payment token address
     * @param usdAmount USD amount (18 decimals)
     * @return tokenAmount Amount of tokens needed
     */
    function _calculateTokenAmount(
        address token,
        uint256 usdAmount
    ) private view returns (uint256 tokenAmount) {
        PaymentToken memory config = paymentTokens[token];
        
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(config.priceFeed).latestRoundData();
        
        if (price <= 0) revert OracleError();
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePrice();
        
        // Price feeds typically have 8 decimals, convert to token amount
        tokenAmount = (usdAmount * 10**config.decimals) / (uint256(price) * 10**10);
    }
    
    /**
     * @notice Calculate redemption quote for given metadata and asset
     * @param metadata Token metadata
     * @param asset Redemption asset
     * @param owner Token owner
     * @return quote Redemption quote details
     */
    function _calculateRedemptionQuote(
        CBGMetadata memory metadata,
        RedemptionAsset asset,
        address owner
    ) private view returns (RedemptionQuote memory quote) {
        // Check if token is mature
        if (block.timestamp < metadata.maturityTimestamp) {
            uint256 timeLeft = metadata.maturityTimestamp - block.timestamp;
            quote.unavailableReason = string(abi.encodePacked("Matures in ", _toString(timeLeft / 86400), " days"));
            return quote;
        }
        
        // Get conversion rate
        uint256 conversionRate;
        if (useOracleForRedemption[asset]) {
            address oracle = redemptionOracles[asset];
            if (oracle == address(0)) {
                quote.unavailableReason = "Oracle not configured";
                return quote;
            }
            
            try AggregatorV3Interface(oracle).latestRoundData() returns (
                uint80,
                int256 price,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (price <= 0 || block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
                    quote.unavailableReason = "Oracle price unavailable";
                    return quote;
                }
                conversionRate = uint256(price);
            } catch {
                quote.unavailableReason = "Oracle error";
                return quote;
            }
        } else {
            conversionRate = redemptionRates[asset];
            if (conversionRate == 0) {
                quote.unavailableReason = "Rate not configured";
                return quote;
            }
        }
        
        // Calculate base amount based on asset type
        if (asset == RedemptionAsset.OIL) {
            quote.baseAmount = metadata.totalBarrels * 1e18;
        } else if (asset == RedemptionAsset.CBG) {
            quote.baseAmount = (metadata.totalBarrels * conversionRate) / 1e18;
        } else if (asset == RedemptionAsset.USDC) {
            // Convert barrels to USDC based on oil price
            quote.baseAmount = (metadata.totalBarrels * conversionRate) / 1e2; // Adjust for USDC 6 decimals
        }
        
        // Apply governance bonus if applicable
        uint256 governanceBalance = governanceToken.balanceOf(owner);
        if (governanceBalance > 0) {
            uint256 bonusPercent;
            if (asset == RedemptionAsset.OIL) bonusPercent = GOVERNANCE_BONUS_OIL;
            else if (asset == RedemptionAsset.CBG) bonusPercent = GOVERNANCE_BONUS_CBG;
            else bonusPercent = GOVERNANCE_BONUS_USDC;
            
            quote.bonusAmount = (quote.baseAmount * bonusPercent) / PERCENT_PRECISION;
        }
        
        quote.totalAmount = quote.baseAmount + quote.bonusAmount;
        quote.conversionRate = conversionRate;
        quote.isAvailable = true;
    }
    
    /**
     * @notice Convert uint to string
     * @param value Value to convert
     * @return String representation
     */
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
    
    // Note: Burned tokens retain their burned status even if transferred
    // This matches the original design where tokens are marked as burned but not actually destroyed

    // ========== Admin Functions ==========
    
    /**
     * @notice Pause all contract operations
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency token recovery (only for mistakenly sent tokens)
     * @param token Token to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
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
