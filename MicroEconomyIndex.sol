// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ITokenomicsMaster {
    function owner() external view returns (address);
    function TOKEN() external view returns (address);
    function getTokenMetrics() external view returns (
        uint256 totalSupply,
        uint256 circulatingSupply,
        uint256 price,
        uint256 marketCap,
        uint256 totalLiquidity,
        uint256 holders,
        uint256 currentEmissionRate,
        uint256 backedSupply,
        uint256 reserveValue
    );
    function getIntegrationReport() external view returns (
        uint256 totalDApps,
        uint256 totalRewardPools,
        uint256 totalLiquidityVenues,
        uint256 totalNFTCollections,
        uint256 totalReserves,
        uint256 reserveBackingRatio
    );
}

interface ITokenomicsMasterFactory {
    function isFactoryDeployment(address deployment) external view returns (bool);
}

/**
 * @title MicroEconomy Index V3
 * @author CIFI Protocol
 * @notice Stack-optimized version of the decentralized tokenomics data marketplace
 * @dev Refactored to avoid stack depth issues while maintaining all functionality
 */
contract MicroEconomyIndex {
    // ============ Type Declarations ============
    
    using SafeMath for uint256;
    
    // ============ Enums ============
    
    enum DataTier {
        PUBLIC,
        BASIC,
        PREMIUM,
        ENTERPRISE
    }
    
    enum BillingCycle {
        DAYS_14,
        DAYS_28,
        DAYS_30
    }
    
    enum ProjectStatus {
        ACTIVE,
        PAUSED,
        DELISTED,
        VERIFIED
    }
    
    enum DataQuality {
        UNVERIFIED,
        BASIC,
        STANDARD,
        PREMIUM
    }
    
    // ============ Core Structs (Simplified) ============
    
    struct ProjectCore {
        address tokenomicsContract;
        address tokenAddress;
        address owner;
        string symbol;
        ProjectStatus status;
        DataQuality dataQuality;
        uint256 registeredAt;
        bool isFactoryDeployed;
    }
    
    struct ProjectMetadata {
        string name;
        string description;
        string logoUrl;
        string websiteUrl;
        uint256 lastUpdate;
        uint256 qualityScore;
        uint256 totalSubscribers;
    }
    
    struct ProjectFinancials {
        uint256 totalRevenueUSD;
        mapping(address => uint256) revenueByToken;
    }
    
    struct PricingConfig {
        BillingCycle billingCycle;
        uint256 gracePeriodDays;
        bool acceptsAllTokens;
        uint256 discountForAnnual;
        mapping(DataTier => uint256) tierPriceUSD;
        mapping(DataTier => address) paymentToken;
        mapping(DataTier => bool) tierEnabled;
    }
    
    struct SubscriptionCore {
        address subscriber;
        address project;
        DataTier tier;
        address paymentToken;
        uint256 pricePerCycle;
        bool isActive;
        bool autoRenew;
        bool isAnnual;
    }
    
    struct SubscriptionTiming {
        uint256 startTime;
        uint256 nextPaymentDue;
        uint256 lastPaymentTime;
    }
    
    struct SubscriptionAccess {
        bytes32 apiKey;
        uint256 requestCount;
        uint256 requestLimit;
    }
    
    struct MetricsBasic {
        uint256 price;
        uint256 marketCap;
        uint256 totalSupply;
        uint256 circulatingSupply;
    }
    
    struct MetricsAdvanced {
        uint256 liquidity;
        uint256 holders;
        uint256 backedSupply;
        uint256 reserveValue;
    }
    
    struct MetricsIntegration {
        uint256 totalDApps;
        uint256 totalRewardPools;
        uint256 txCount24h;
        uint256 uniqueUsers24h;
    }
    
    struct PublicMetrics {
        string name;
        string symbol;
        uint256 price;
        uint256 marketCap;
        uint256 volume24h;
        int256 priceChange24h;
        uint256 lastUpdate;
        uint256 qualityScore;
        bool isVerified;
    }
    
    struct DetailedMetrics {
        PublicMetrics public_;
        MetricsBasic basic;
        MetricsAdvanced advanced;
        MetricsIntegration integration;
    }
    
    struct RegistrationParams {
        address tokenomicsContract;
        string name;
        string symbol;
        string description;
        string logoUrl;
        string websiteUrl;
        address paymentToken;
    }
    
    struct SubscribeParams {
        address tokenomicsContract;
        DataTier tier;
        address paymentToken;
        bool autoRenew;
        bool isAnnual;
    }
    
    struct PaymentInfo {
        uint256 amount;
        uint256 platformFee;
        uint256 projectRevenue;
        uint256 rewardAllocation;
    }
    
    // ============ State Variables ============
    
    // Core configuration
    address public owner;
    address public treasury;
    address public factory;
    bool public paused;
    
    // Platform fees
    uint256 public platformFeePercent = 1000; // 10%
    uint256 public registrationFee = 1000; // $10
    uint256 public verificationFee = 5000; // $50
    uint256 public factoryRegistrationDiscount = 5000; // 50%
    
    // Factory integration
    mapping(address => bool) public trustedFactories;
    
    // Project registry - Split into components
    mapping(address => ProjectCore) public projectCore;
    mapping(address => ProjectMetadata) public projectMetadata;
    mapping(address => ProjectFinancials) internal projectFinancials;
    mapping(address => PricingConfig) internal projectPricing;
    
    mapping(string => address) public projectBySymbol;
    address[] public allProjects;
    uint256 public totalProjects;
    uint256 public activeProjects;
    uint256 public verifiedProjects;
    
    // Subscription management - Split into components
    mapping(bytes32 => SubscriptionCore) public subscriptionCore;
    mapping(bytes32 => SubscriptionTiming) public subscriptionTiming;
    mapping(bytes32 => SubscriptionAccess) public subscriptionAccess;
    
    mapping(address => bytes32[]) public userSubscriptions;
    mapping(address => bytes32[]) public projectSubscriptions;
    mapping(bytes32 => bool) public apiKeyActive;
    mapping(bytes32 => bytes32) public apiKeyToSubscription;
    uint256 public totalActiveSubscriptions;
    
    // Payment tokens
    mapping(address => bool) public acceptedTokens;
    mapping(address => uint256) public tokenPriceUSD;
    address[] public paymentTokenList;
    
    // Historical data
    mapping(address => mapping(uint256 => MetricsBasic)) public historicalBasic;
    mapping(address => mapping(uint256 => MetricsAdvanced)) public historicalAdvanced;
    uint256 public defaultRetentionDays = 365;
    
    // Access control
    mapping(address => bool) public dataProviders;
    mapping(address => bool) public oracles;
    mapping(address => bool) public verifiers;
    
    // Revenue and rewards
    uint256 public totalPlatformRevenue;
    mapping(address => uint256) public projectRewards;
    uint256 public rewardPool;
    uint256 public rewardRate = 100; // 1%
    
    // Rate limiting
    mapping(bytes32 => uint256) public apiRequestCount;
    mapping(bytes32 => uint256) public lastRequestTime;
    uint256 public defaultRateLimit = 1000;
    
    // ============ Events ============
    
    event ProjectRegistered(
        address indexed tokenomicsContract,
        address indexed owner,
        string symbol,
        bool isFactoryDeployed
    );
    
    event ProjectVerified(address indexed project, uint256 qualityScore);
    
    event SubscriptionCreated(
        bytes32 indexed subscriptionId,
        address indexed subscriber,
        address indexed project,
        DataTier tier
    );
    
    event PaymentProcessed(
        bytes32 indexed subscriptionId,
        address token,
        uint256 amount
    );
    
    event DataUpdated(address indexed project, uint256 timestamp);
    
    // ============ Errors ============
    
    error Unauthorized();
    error InvalidAddress();
    error InvalidParameters();
    error ProjectNotFound();
    error ProjectAlreadyExists();
    error SubscriptionNotFound();
    error PaymentFailed();
    error TokenNotAccepted();
    error DataNotAvailable();
    error ContractPaused();
    error RateLimitExceeded();
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyProjectOwner(address project) {
        if (projectCore[project].owner != msg.sender) revert Unauthorized();
        _;
    }
    
    modifier onlyFactoryOrOwner() {
        if (!trustedFactories[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    
    modifier projectExists(address project) {
        if (projectCore[project].tokenomicsContract == address(0)) revert ProjectNotFound();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _treasury, address _factory) {
        owner = msg.sender;
        treasury = _treasury;
        factory = _factory;
        
        if (_factory != address(0)) {
            trustedFactories[_factory] = true;
        }
    }
    
    // ============ Registration Functions (Optimized) ============
    
    /**
     * @notice Register a project with optimized stack usage
     * @param params Registration parameters
     */
    function registerProject(
        RegistrationParams calldata params
    ) external whenNotPaused {
        // Basic validation
        _validateProjectRegistration(params.tokenomicsContract);
        
        // Check symbol uniqueness
        if (projectBySymbol[params.symbol] != address(0)) {
            revert ProjectAlreadyExists();
        }
        
        // Calculate and process fee
        uint256 fee = _calculateRegistrationFee(params.tokenomicsContract);
        if (fee > 0) {
            _processPayment(params.paymentToken, fee, treasury);
        }
        
        // Create project in steps
        _createProjectCore(params.tokenomicsContract, params.symbol);
        _createProjectMetadata(params.tokenomicsContract, params);
        _initializeProjectPricing(params.tokenomicsContract);
        
        // Update registries
        _finalizeProjectRegistration(params.tokenomicsContract, params.symbol);
        
        emit ProjectRegistered(
            params.tokenomicsContract,
            msg.sender,
            params.symbol,
            _checkFactoryDeployment(params.tokenomicsContract)
        );
    }
    
    /**
     * @notice Register from factory with minimal parameters
     */
    function registerProjectFromFactory(
        address tokenomicsContract,
        string calldata name,
        string calldata symbol,
        address projectOwner
    ) external onlyFactoryOrOwner whenNotPaused {
        // Validate
        if (projectCore[tokenomicsContract].tokenomicsContract != address(0)) {
            revert ProjectAlreadyExists();
        }
        if (projectBySymbol[symbol] != address(0)) {
            revert ProjectAlreadyExists();
        }
        
        // Create core
        ProjectCore storage core = projectCore[tokenomicsContract];
        core.tokenomicsContract = tokenomicsContract;
        core.tokenAddress = ITokenomicsMaster(tokenomicsContract).TOKEN();
        core.owner = projectOwner;
        core.symbol = symbol;
        core.status = ProjectStatus.ACTIVE;
        core.dataQuality = DataQuality.BASIC;
        core.registeredAt = block.timestamp;
        core.isFactoryDeployed = true;
        
        // Create metadata
        ProjectMetadata storage meta = projectMetadata[tokenomicsContract];
        meta.name = name;
        meta.lastUpdate = block.timestamp;
        meta.qualityScore = 6000;
        
        // Initialize pricing
        _initializeProjectPricing(tokenomicsContract);
        
        // Finalize
        _finalizeProjectRegistration(tokenomicsContract, symbol);
        
        emit ProjectRegistered(tokenomicsContract, projectOwner, symbol, true);
    }
    
    // ============ Subscription Functions (Optimized) ============
    
    /**
     * @notice Subscribe with optimized stack usage
     * @param params Subscription parameters
     * @return subscriptionId The created subscription ID
     */
    function subscribe(
        SubscribeParams calldata params
    ) external whenNotPaused projectExists(params.tokenomicsContract) returns (bytes32 subscriptionId) {
        // Validate
        _validateSubscriptionTier(params.tokenomicsContract, params.tier);
        _validatePaymentToken(params.tokenomicsContract, params.tier, params.paymentToken);
        
        // Calculate price
        uint256 priceInToken = _calculateSubscriptionPrice(
            params.tokenomicsContract,
            params.tier,
            params.paymentToken,
            params.isAnnual
        );
        
        // Generate IDs
        subscriptionId = _generateSubscriptionId();
        bytes32 apiKey = _generateApiKey(subscriptionId);
        
        // Create subscription components
        _createSubscriptionCore(subscriptionId, params, priceInToken);
        _createSubscriptionTiming(subscriptionId, params);
        _createSubscriptionAccess(subscriptionId, apiKey, params.tier);
        
        // Process payment
        PaymentInfo memory paymentInfo = _calculatePaymentSplit(priceInToken);
        _executePayment(params.paymentToken, paymentInfo);
        _allocateRevenue(params.tokenomicsContract, params.paymentToken, paymentInfo);
        
        // Update registries
        _updateSubscriptionRegistries(subscriptionId, params.tokenomicsContract, apiKey);
        
        // Update stats
        projectMetadata[params.tokenomicsContract].totalSubscribers++;
        totalActiveSubscriptions++;
        
        emit SubscriptionCreated(subscriptionId, msg.sender, params.tokenomicsContract, params.tier);
        
        return subscriptionId;
    }
    
    // ============ Data Access Functions (Optimized) ============
    
    /**
     * @notice Get public metrics efficiently
     */
    function getPublicMetrics(address tokenomicsContract) 
        external 
        view 
        projectExists(tokenomicsContract) 
        returns (PublicMetrics memory metrics) 
    {
        // Get project info
        ProjectMetadata storage meta = projectMetadata[tokenomicsContract];
        
        metrics.name = meta.name;
        metrics.symbol = projectCore[tokenomicsContract].symbol;
        metrics.lastUpdate = meta.lastUpdate;
        metrics.qualityScore = meta.qualityScore;
        metrics.isVerified = (projectCore[tokenomicsContract].status == ProjectStatus.VERIFIED);
        
        // Get price data
        (metrics.price, metrics.marketCap) = _getBasicPriceData(tokenomicsContract);
        
        // Get volume and change
        (metrics.volume24h, metrics.priceChange24h) = _getVolumeAndChange(tokenomicsContract);
    }
    
    /**
     * @notice Get detailed metrics with rate limiting
     */
    function getDetailedMetrics(address tokenomicsContract, bytes32 apiKey) 
        external 
        returns (DetailedMetrics memory metrics) 
    {
        // Rate limit check
        _checkRateLimit(apiKey);
        
        // Validate access
        bytes32 subscriptionId = _validateApiAccess(apiKey, tokenomicsContract);
        DataTier tier = subscriptionCore[subscriptionId].tier;
        
        // Get public data
        metrics.public_ = _buildPublicMetrics(tokenomicsContract);
        
        // Get tier-specific data
        if (tier >= DataTier.BASIC) {
            metrics.basic = _getBasicMetrics(tokenomicsContract);
        }
        
        if (tier >= DataTier.PREMIUM) {
            metrics.advanced = _getAdvancedMetrics(tokenomicsContract);
            metrics.integration = _getIntegrationMetrics(tokenomicsContract);
        }
    }
    
    /**
     * @notice View detailed metrics without rate limiting
     */
    function viewDetailedMetrics(address tokenomicsContract, bytes32 apiKey) 
        external 
        view
        returns (DetailedMetrics memory metrics) 
    {
        // Validate access (view only)
        bytes32 subscriptionId = _validateApiAccessView(apiKey, tokenomicsContract);
        DataTier tier = subscriptionCore[subscriptionId].tier;
        
        // Build response based on tier
        metrics.public_ = _buildPublicMetrics(tokenomicsContract);
        
        if (tier >= DataTier.BASIC) {
            metrics.basic = _getBasicMetrics(tokenomicsContract);
        }
        
        if (tier >= DataTier.PREMIUM) {
            metrics.advanced = _getAdvancedMetrics(tokenomicsContract);
            metrics.integration = _getIntegrationMetrics(tokenomicsContract);
        }
    }
    
    // ============ Internal Helper Functions (Optimized) ============
    
    function _validateProjectRegistration(address tokenomicsContract) internal view {
        if (ITokenomicsMaster(tokenomicsContract).owner() != msg.sender) {
            revert Unauthorized();
        }
        if (projectCore[tokenomicsContract].tokenomicsContract != address(0)) {
            revert ProjectAlreadyExists();
        }
    }
    
    function _calculateRegistrationFee(address tokenomicsContract) internal view returns (uint256 fee) {
        fee = registrationFee;
        if (_checkFactoryDeployment(tokenomicsContract)) {
            fee = fee.mul(10000 - factoryRegistrationDiscount).div(10000);
        }
    }
    
    function _checkFactoryDeployment(address tokenomicsContract) internal view returns (bool) {
        if (factory == address(0)) return false;
        try ITokenomicsMasterFactory(factory).isFactoryDeployment(tokenomicsContract) returns (bool isValid) {
            return isValid;
        } catch {
            return false;
        }
    }
    
    function _createProjectCore(address tokenomicsContract, string calldata symbol) internal {
        ProjectCore storage core = projectCore[tokenomicsContract];
        core.tokenomicsContract = tokenomicsContract;
        core.tokenAddress = ITokenomicsMaster(tokenomicsContract).TOKEN();
        core.owner = msg.sender;
        core.symbol = symbol;
        core.status = ProjectStatus.ACTIVE;
        core.dataQuality = DataQuality.BASIC;
        core.registeredAt = block.timestamp;
        core.isFactoryDeployed = _checkFactoryDeployment(tokenomicsContract);
    }
    
    function _createProjectMetadata(address tokenomicsContract, RegistrationParams calldata params) internal {
        ProjectMetadata storage meta = projectMetadata[tokenomicsContract];
        meta.name = params.name;
        meta.description = params.description;
        meta.logoUrl = params.logoUrl;
        meta.websiteUrl = params.websiteUrl;
        meta.lastUpdate = block.timestamp;
        meta.qualityScore = projectCore[tokenomicsContract].isFactoryDeployed ? 6000 : 5000;
    }
    
    function _initializeProjectPricing(address tokenomicsContract) internal {
        PricingConfig storage pricing = projectPricing[tokenomicsContract];
        pricing.billingCycle = BillingCycle.DAYS_30;
        pricing.gracePeriodDays = 3;
        pricing.acceptsAllTokens = true;
        pricing.discountForAnnual = 2000;
        pricing.tierEnabled[DataTier.PUBLIC] = true;
        pricing.tierEnabled[DataTier.BASIC] = true;
    }
    
    function _finalizeProjectRegistration(address tokenomicsContract, string calldata symbol) internal {
        projectBySymbol[symbol] = tokenomicsContract;
        allProjects.push(tokenomicsContract);
        totalProjects++;
        activeProjects++;
        dataProviders[msg.sender] = true;
    }
    
    function _validateSubscriptionTier(address tokenomicsContract, DataTier tier) internal view {
        if (!projectPricing[tokenomicsContract].tierEnabled[tier]) {
            revert DataNotAvailable();
        }
    }
    
    function _validatePaymentToken(address tokenomicsContract, DataTier tier, address paymentToken) internal view {
        PricingConfig storage pricing = projectPricing[tokenomicsContract];
        if (!pricing.acceptsAllTokens && pricing.paymentToken[tier] != paymentToken) {
            if (!acceptedTokens[paymentToken]) revert TokenNotAccepted();
        }
    }
    
    function _calculateSubscriptionPrice(
        address tokenomicsContract,
        DataTier tier,
        address paymentToken,
        bool isAnnual
    ) internal view returns (uint256) {
        uint256 priceUSD = projectPricing[tokenomicsContract].tierPriceUSD[tier];
        
        if (isAnnual) {
            uint256 annualPrice = priceUSD.mul(12);
            uint256 discount = projectPricing[tokenomicsContract].discountForAnnual;
            priceUSD = annualPrice.sub(annualPrice.mul(discount).div(10000));
        }
        
        return _convertUSDToToken(priceUSD, paymentToken);
    }
    
    function _generateSubscriptionId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, block.timestamp, totalActiveSubscriptions));
    }
    
    function _generateApiKey(bytes32 subscriptionId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(subscriptionId, block.number, block.timestamp));
    }
    
    function _createSubscriptionCore(
        bytes32 subscriptionId,
        SubscribeParams calldata params,
        uint256 priceInToken
    ) internal {
        SubscriptionCore storage core = subscriptionCore[subscriptionId];
        core.subscriber = msg.sender;
        core.project = params.tokenomicsContract;
        core.tier = params.tier;
        core.paymentToken = params.paymentToken;
        core.pricePerCycle = priceInToken;
        core.isActive = true;
        core.autoRenew = params.autoRenew;
        core.isAnnual = params.isAnnual;
    }
    
    function _createSubscriptionTiming(bytes32 subscriptionId, SubscribeParams calldata params) internal {
        uint256 cycleDays = params.isAnnual ? 365 : _getCycleDays(projectPricing[params.tokenomicsContract].billingCycle);
        
        SubscriptionTiming storage timing = subscriptionTiming[subscriptionId];
        timing.startTime = block.timestamp;
        timing.nextPaymentDue = block.timestamp + (cycleDays * 1 days);
        timing.lastPaymentTime = block.timestamp;
    }
    
    function _createSubscriptionAccess(bytes32 subscriptionId, bytes32 apiKey, DataTier tier) internal {
        SubscriptionAccess storage access = subscriptionAccess[subscriptionId];
        access.apiKey = apiKey;
        access.requestLimit = _getRequestLimit(tier);
    }
    
    function _calculatePaymentSplit(uint256 amount) internal view returns (PaymentInfo memory info) {
        info.amount = amount;
        info.platformFee = amount.mul(platformFeePercent).div(10000);
        info.projectRevenue = amount.sub(info.platformFee);
        info.rewardAllocation = info.platformFee.mul(rewardRate).div(10000);
    }
    
    function _executePayment(address token, PaymentInfo memory info) internal {
        bool success = IERC20(token).transferFrom(msg.sender, address(this), info.amount);
        if (!success) revert PaymentFailed();
    }
    
    function _allocateRevenue(address project, address token, PaymentInfo memory info) internal {
        projectFinancials[project].revenueByToken[token] += info.projectRevenue;
        projectFinancials[project].totalRevenueUSD += _convertTokenToUSD(info.amount, token);
        totalPlatformRevenue += _convertTokenToUSD(info.platformFee, token);
        rewardPool += info.rewardAllocation;
    }
    
    function _updateSubscriptionRegistries(bytes32 subscriptionId, address project, bytes32 apiKey) internal {
        userSubscriptions[msg.sender].push(subscriptionId);
        projectSubscriptions[project].push(subscriptionId);
        apiKeyActive[apiKey] = true;
        apiKeyToSubscription[apiKey] = subscriptionId;
    }
    
    function _checkRateLimit(bytes32 apiKey) internal {
        uint256 dayKey = block.timestamp / 1 days;
        
        if (lastRequestTime[apiKey] / 1 days < dayKey) {
            apiRequestCount[apiKey] = 0;
            lastRequestTime[apiKey] = block.timestamp;
        }
        
        SubscriptionAccess storage access = subscriptionAccess[apiKeyToSubscription[apiKey]];
        uint256 limit = access.requestLimit > 0 ? access.requestLimit : defaultRateLimit;
        
        if (apiRequestCount[apiKey] >= limit) revert RateLimitExceeded();
        apiRequestCount[apiKey]++;
    }
    
    function _validateApiAccess(bytes32 apiKey, address project) internal view returns (bytes32 subscriptionId) {
        if (!apiKeyActive[apiKey]) revert Unauthorized();
        
        subscriptionId = apiKeyToSubscription[apiKey];
        SubscriptionCore storage core = subscriptionCore[subscriptionId];
        
        if (!core.isActive) revert Unauthorized();
        if (core.project != project) revert Unauthorized();
        
        SubscriptionTiming storage timing = subscriptionTiming[subscriptionId];
        uint256 gracePeriod = projectPricing[project].gracePeriodDays * 1 days;
        
        if (block.timestamp > timing.nextPaymentDue + gracePeriod) {
            revert Unauthorized();
        }
    }
    
    function _validateApiAccessView(bytes32 apiKey, address project) internal view returns (bytes32 subscriptionId) {
        if (!apiKeyActive[apiKey]) revert Unauthorized();
        
        subscriptionId = apiKeyToSubscription[apiKey];
        SubscriptionCore storage core = subscriptionCore[subscriptionId];
        
        if (!core.isActive || core.project != project) revert Unauthorized();
        
        SubscriptionTiming storage timing = subscriptionTiming[subscriptionId];
        uint256 gracePeriod = projectPricing[project].gracePeriodDays * 1 days;
        
        if (block.timestamp > timing.nextPaymentDue + gracePeriod) {
            revert Unauthorized();
        }
    }
    
    function _buildPublicMetrics(address tokenomicsContract) internal view returns (PublicMetrics memory metrics) {
        ProjectMetadata storage meta = projectMetadata[tokenomicsContract];
        
        metrics.name = meta.name;
        metrics.symbol = projectCore[tokenomicsContract].symbol;
        metrics.lastUpdate = meta.lastUpdate;
        metrics.qualityScore = meta.qualityScore;
        metrics.isVerified = (projectCore[tokenomicsContract].status == ProjectStatus.VERIFIED);
        
        (metrics.price, metrics.marketCap) = _getBasicPriceData(tokenomicsContract);
        (metrics.volume24h, metrics.priceChange24h) = _getVolumeAndChange(tokenomicsContract);
    }
    
    function _getBasicPriceData(address tokenomicsContract) internal view returns (uint256 price, uint256 marketCap) {
        try ITokenomicsMaster(tokenomicsContract).getTokenMetrics() returns (
            uint256, uint256, uint256 _price, uint256 _marketCap,
            uint256, uint256, uint256, uint256, uint256
        ) {
            price = _price;
            marketCap = _marketCap;
        } catch {}
    }
    
    function _getVolumeAndChange(address tokenomicsContract) internal view returns (uint256 volume24h, int256 priceChange24h) {
        uint256 today = block.timestamp / 1 days;
        uint256 yesterday = today - 1;
        
        MetricsBasic storage todayData = historicalBasic[tokenomicsContract][today];
        MetricsBasic storage yesterdayData = historicalBasic[tokenomicsContract][yesterday];
        
        volume24h = todayData.totalSupply; // Placeholder - would track actual volume
        
        if (yesterdayData.price > 0 && todayData.price > 0) {
            int256 priceDiff = int256(todayData.price) - int256(yesterdayData.price);
            priceChange24h = (priceDiff * 10000) / int256(yesterdayData.price);
        }
    }
    
    function _getBasicMetrics(address tokenomicsContract) internal view returns (MetricsBasic memory metrics) {
        try ITokenomicsMaster(tokenomicsContract).getTokenMetrics() returns (
            uint256 totalSupply,
            uint256 circulatingSupply,
            uint256 price,
            uint256 marketCap,
            uint256, uint256, uint256, uint256, uint256
        ) {
            metrics.totalSupply = totalSupply;
            metrics.circulatingSupply = circulatingSupply;
            metrics.price = price;
            metrics.marketCap = marketCap;
        } catch {}
    }
    
    function _getAdvancedMetrics(address tokenomicsContract) internal view returns (MetricsAdvanced memory metrics) {
        try ITokenomicsMaster(tokenomicsContract).getTokenMetrics() returns (
            uint256, uint256, uint256, uint256,
            uint256 liquidity,
            uint256 holders,
            uint256,
            uint256 backedSupply,
            uint256 reserveValue
        ) {
            metrics.liquidity = liquidity;
            metrics.holders = holders;
            metrics.backedSupply = backedSupply;
            metrics.reserveValue = reserveValue;
        } catch {}
    }
    
    function _getIntegrationMetrics(address tokenomicsContract) internal view returns (MetricsIntegration memory metrics) {
        try ITokenomicsMaster(tokenomicsContract).getIntegrationReport() returns (
            uint256 totalDApps,
            uint256 totalRewardPools,
            uint256, uint256, uint256, uint256
        ) {
            metrics.totalDApps = totalDApps;
            metrics.totalRewardPools = totalRewardPools;
        } catch {}
        
        // Get from historical data
        uint256 today = block.timestamp / 1 days;
        MetricsAdvanced storage advanced = historicalAdvanced[tokenomicsContract][today];
        metrics.txCount24h = advanced.holders; // Placeholder
        metrics.uniqueUsers24h = advanced.liquidity; // Placeholder
    }
    
    function _getRequestLimit(DataTier tier) internal view returns (uint256) {
        if (tier == DataTier.BASIC) return defaultRateLimit;
        if (tier == DataTier.PREMIUM) return defaultRateLimit * 5;
        if (tier == DataTier.ENTERPRISE) return defaultRateLimit * 20;
        return defaultRateLimit;
    }
    
    function _getCycleDays(BillingCycle cycle) internal pure returns (uint256) {
        if (cycle == BillingCycle.DAYS_14) return 14;
        if (cycle == BillingCycle.DAYS_28) return 28;
        return 30;
    }
    
    function _processPayment(address token, uint256 amountUSD, address recipient) internal {
        if (!acceptedTokens[token]) revert TokenNotAccepted();
        
        uint256 tokenAmount = _convertUSDToToken(amountUSD, token);
        
        bool success = IERC20(token).transferFrom(msg.sender, recipient, tokenAmount);
        if (!success) revert PaymentFailed();
    }
    
    function _convertUSDToToken(uint256 amountUSD, address token) internal view returns (uint256) {
        uint256 tokenPrice = tokenPriceUSD[token];
        if (tokenPrice == 0) revert TokenNotAccepted();
        
        uint8 decimals = IERC20(token).decimals();
        return amountUSD.mul(10**decimals).div(tokenPrice);
    }
    
    function _convertTokenToUSD(uint256 amount, address token) internal view returns (uint256) {
        uint256 tokenPrice = tokenPriceUSD[token];
        uint8 decimals = IERC20(token).decimals();
        return amount.mul(tokenPrice).div(10**decimals);
    }
    
    // ============ Admin Functions ============
    
    function addPaymentToken(address token, uint256 priceUSD) external onlyOwner {
        acceptedTokens[token] = true;
        tokenPriceUSD[token] = priceUSD;
        paymentTokenList.push(token);
    }
    
    function addTrustedFactory(address _factory) external onlyOwner {
        trustedFactories[_factory] = true;
    }
    
    function setPlatformFee(uint256 feePercent) external onlyOwner {
        if (feePercent > 2000) revert InvalidParameters();
        platformFeePercent = feePercent;
    }
    
    function pause() external onlyOwner {
        paused = true;
    }
    
    function unpause() external onlyOwner {
        paused = false;
    }
    
    // ============ View Functions ============
    
    function getProjectInfo(address tokenomicsContract) 
        external 
        view 
        returns (
            string memory name,
            string memory symbol,
            address projectOwner,
            ProjectStatus status,
            uint256 totalSubscribers,
            bool isFactoryDeployed,
            uint256 qualityScore
        ) 
    {
        ProjectCore storage core = projectCore[tokenomicsContract];
        ProjectMetadata storage meta = projectMetadata[tokenomicsContract];
        
        return (
            meta.name,
            core.symbol,
            core.owner,
            core.status,
            meta.totalSubscribers,
            core.isFactoryDeployed,
            meta.qualityScore
        );
    }
    
    function getTierPricing(address tokenomicsContract, DataTier tier)
        external
        view
        returns (
            bool enabled,
            uint256 priceUSD,
            address paymentToken
        )
    {
        PricingConfig storage pricing = projectPricing[tokenomicsContract];
        return (
            pricing.tierEnabled[tier],
            pricing.tierPriceUSD[tier],
            pricing.paymentToken[tier]
        );
    }
    
    function withdrawRevenue(
        address tokenomicsContract,
        address token
    ) external onlyProjectOwner(tokenomicsContract) {
        uint256 amount = projectFinancials[tokenomicsContract].revenueByToken[token];
        
        if (amount == 0) revert InvalidParameters();
        
        projectFinancials[tokenomicsContract].revenueByToken[token] = 0;
        
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert PaymentFailed();
    }
}

// ============ Library ============

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
}
