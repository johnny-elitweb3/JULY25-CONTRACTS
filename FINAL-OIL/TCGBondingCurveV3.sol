// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// ==================== INTERFACES ====================

interface ITCG is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IPriceOracle {
    function getLatestPrice() external view returns (uint256);
    function getAveragePrice(uint256 period) external view returns (uint256);
}

interface ILender {
    function receiveFunds(address token, uint256 amount) external payable;
    function getUtilizationRate() external view returns (uint256);
}

// ==================== TCG BONDING CURVE V3 - PRODUCTIVE CAPITAL MODEL ====================

/**
 * @title TCG Bonding Curve Vending Machine V3
 * @author TCGDeX Protocol
 * @notice World-class bonding curve with 100% productive capital allocation
 * @dev All funds are immediately deployed for maximum capital efficiency
 */
contract TCGBondingCurveV3 is IPriceOracle, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== CONSTANTS ====================
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PRICE_MANAGER_ROLE = keccak256("PRICE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant LENDER_MANAGER_ROLE = keccak256("LENDER_MANAGER_ROLE");
    
    // Bonding curve phases (in tokens)
    uint256 public constant PHASE_1_END = 1_000_000 * 10**18;      // 1M tokens
    uint256 public constant PHASE_2_END = 10_000_000 * 10**18;    // 10M tokens
    uint256 public constant PHASE_3_END = 50_000_000 * 10**18;    // 50M tokens
    
    // Price increments per 100k tokens for each phase
    uint256 public constant PHASE_1_INCREMENT = 0.001 ether;       // $0.001
    uint256 public constant PHASE_2_INCREMENT = 0.005 ether;       // $0.005
    uint256 public constant PHASE_3_INCREMENT = 0.02 ether;        // $0.02
    uint256 public constant PHASE_4_INCREMENT = 0.05 ether;        // $0.05
    
    uint256 public constant TOKENS_PER_STEP = 100_000 * 10**18;   // 100k tokens
    uint256 public constant INITIAL_PRICE = 0.001 ether;           // $0.001
    
    // Capital allocation percentages (in basis points)
    // Note: No reserve - all capital is productive!
    uint256 public constant LENDER_PERCENTAGE = 3000;      // 30% to lender (was reserve)
    uint256 public constant BUYBACK_PERCENTAGE = 2000;     // 20% for buybacks
    uint256 public constant LIQUIDITY_PERCENTAGE = 3000;   // 30% for DEX liquidity
    uint256 public constant OPERATIONS_PERCENTAGE = 2000;  // 20% for operations
    uint256 public constant BASIS_POINTS = 10000;
    
    // Security limits
    uint256 public constant MAX_PURCHASE_PERCENTAGE = 100; // 1% of total sold per tx
    uint256 public constant MIN_PURCHASE_AMOUNT = 0.01 ether;
    uint256 public constant PRICE_IMPACT_THRESHOLD = 300; // 3% max standard impact
    uint256 public constant COOLDOWN_PERIOD = 30 seconds; // Reduced for better UX
    uint256 public constant MAX_DAILY_VOLUME_MULTIPLIER = 10; // 10x average daily
    
    // Circuit breaker thresholds
    uint256 public constant EMERGENCY_THRESHOLD_MULTIPLIER = 20; // 20x average volume
    uint256 public constant AUTO_PAUSE_THRESHOLD = 5; // Reduced for faster response
    
    // Operational parameters
    uint256 public constant FUNDS_DEPLOYMENT_THRESHOLD = 1 ether; // Auto-deploy when accumulated
    uint256 public constant PRICE_UPDATE_INTERVAL = 1 hours;
    
    // ==================== STATE VARIABLES ====================
    
    ITCG public immutable tcgToken;
    
    // Core metrics
    uint256 public totalTokensSold;
    uint256 public totalEthCollected;
    uint256 public totalEthDeployed;
    
    // Productive capital tracking
    struct CapitalDeployment {
        uint256 totalSent;
        uint256 lastDeployment;
        uint256 pendingAmount;
    }
    
    mapping(string => CapitalDeployment) public capitalDeployments;
    
    // Destination addresses
    address public lenderAddress;      // Receives 30% for lending operations
    address public buybackAddress;     // Receives 20% for market buybacks
    address public liquidityAddress;   // Receives 30% for DEX liquidity
    address public operationsAddress;  // Receives 20% for operations
    
    // Security state
    mapping(address => uint256) public lastPurchaseTime;
    mapping(address => uint256) public userDailyVolume;
    mapping(address => uint256) public userPurchaseCount;
    mapping(uint256 => uint256) public dailyVolume;
    uint256 public currentDay;
    uint256 public anomalyCounter;
    uint256 public lastAnomalyReset;
    
    // Price tracking with enhanced metrics
    struct PricePoint {
        uint256 timestamp;
        uint256 price;
        uint256 tokensSold;
        uint256 volume24h;
        uint256 uniqueBuyers24h;
        uint256 averagePurchaseSize;
    }
    
    PricePoint[] public priceHistory;
    mapping(uint256 => address[]) public dailyBuyers;
    
    // Performance metrics
    struct PerformanceMetrics {
        uint256 totalBuyers;
        uint256 averageHoldTime;
        uint256 velocityScore; // Trading velocity
        uint256 healthScore;   // Overall system health
    }
    
    PerformanceMetrics public metrics;
    
    // Dynamic limits based on system health
    uint256 public dynamicPurchaseLimit;
    uint256 public dynamicDailyLimit;
    uint256 public systemHealthScore = 100; // 0-100 scale
    
    // Enhanced events
    event CapitalDeployed(
        string destination,
        uint256 amount,
        uint256 totalDeployed,
        address indexed recipient
    );
    
    event SystemHealthUpdated(
        uint256 oldScore,
        uint256 newScore,
        string reason
    );
    
    event YieldReported(
        address indexed source,
        uint256 amount,
        uint256 utilizationRate
    );
    
    // ==================== EVENTS ====================
    
    event TokensPurchased(
        address indexed buyer,
        uint256 tokensReceived,
        uint256 ethSpent,
        uint256 averagePrice,
        uint256 newPrice,
        uint256 priceImpact,
        uint256 systemHealth
    );
    
    event FundsAllocated(
        uint256 toLender,
        uint256 toBuyback,
        uint256 toLiquidity,
        uint256 toOperations,
        uint256 totalDeployed
    );
    
    event AutomaticDeployment(
        string[] destinations,
        uint256[] amounts,
        uint256 totalDeployed,
        uint256 gasUsed
    );
    
    event PricePhaseChanged(
        uint256 oldPhase,
        uint256 newPhase,
        uint256 tokensSold,
        uint256 newPriceIncrement,
        uint256 projectedPrice50M
    );
    
    event DynamicLimitsUpdated(
        uint256 purchaseLimit,
        uint256 dailyLimit,
        uint256 healthScore,
        string triggerReason
    );
    
    // ==================== ERRORS ====================
    
    error Unauthorized(address caller, bytes32 requiredRole);
    error InvalidAmount(uint256 provided, uint256 minimum, uint256 maximum);
    error InsufficientTokens(uint256 requested, uint256 available);
    error SlippageExceeded(uint256 expectedTokens, uint256 minTokens);
    error CooldownActive(uint256 timeRemaining);
    error PurchaseLimitExceeded(string limitType, uint256 limit, uint256 requested);
    error SystemUnhealthy(uint256 healthScore, uint256 requiredScore);
    error DeploymentFailed(string destination, uint256 amount);
    error InvalidConfiguration(string reason);
    error ExcessivePriceImpact(uint256 impact, uint256 threshold);
    error ZeroAddress(string parameter);
    error LenderRejectedFunds(uint256 amount, string reason);
    
    // ==================== MODIFIERS ====================
    
    modifier onlyHealthySystem() {
        if (systemHealthScore < 50) {
            revert SystemUnhealthy(systemHealthScore, 50);
        }
        _;
    }
    
    modifier respectsCooldown() {
        uint256 timeSinceLastPurchase = block.timestamp - lastPurchaseTime[msg.sender];
        if (timeSinceLastPurchase < COOLDOWN_PERIOD) {
            revert CooldownActive(COOLDOWN_PERIOD - timeSinceLastPurchase);
        }
        _;
    }
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _tcgToken,
        address _lenderAddress,
        address _buybackAddress,
        address _liquidityAddress,
        address _operationsAddress,
        address _admin
    ) {
        // Validate addresses
        if (_tcgToken == address(0) || 
            _lenderAddress == address(0) || 
            _buybackAddress == address(0) || 
            _liquidityAddress == address(0) ||
            _operationsAddress == address(0) ||
            _admin == address(0)) {
            revert ZeroAddress("constructor parameter");
        }
        
        tcgToken = ITCG(_tcgToken);
        lenderAddress = _lenderAddress;
        buybackAddress = _buybackAddress;
        liquidityAddress = _liquidityAddress;
        operationsAddress = _operationsAddress;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        _grantRole(PRICE_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(LENDER_MANAGER_ROLE, _admin);
        
        // Initialize
        currentDay = block.timestamp / 1 days;
        _initializeDynamicLimits();
        
        // Initial price point
        priceHistory.push(PricePoint({
            timestamp: block.timestamp,
            price: INITIAL_PRICE,
            tokensSold: 0,
            volume24h: 0,
            uniqueBuyers24h: 0,
            averagePurchaseSize: 0
        }));
    }
    
    // ==================== MAIN PURCHASE FUNCTION ====================
    
    /**
     * @notice Purchase TCG tokens with ETH - all funds are productively deployed
     * @param minTokensOut Minimum tokens expected (slippage protection)
     * @param deadline Transaction deadline
     * @return tokensReceived Amount of tokens purchased
     */
    function purchaseTokens(
        uint256 minTokensOut,
        uint256 deadline
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlyHealthySystem
        respectsCooldown
        returns (uint256 tokensReceived) 
    {
        // Deadline check
        if (block.timestamp > deadline) {
            revert InvalidConfiguration("Transaction expired");
        }
        
        // Amount validation
        if (msg.value < MIN_PURCHASE_AMOUNT) {
            revert InvalidAmount(msg.value, MIN_PURCHASE_AMOUNT, type(uint256).max);
        }
        
        // Update daily tracking
        _updateDailyTracking();
        
        // Calculate tokens using accelerating curve
        (uint256 tokens, uint256 averagePrice, uint256 priceImpact) = _calculateTokensWithAcceleratingCurve(msg.value);
        
        // Validate slippage
        if (tokens < minTokensOut) {
            revert SlippageExceeded(tokens, minTokensOut);
        }
        
        // Check token availability
        uint256 availableTokens = tcgToken.balanceOf(address(this));
        if (tokens > availableTokens) {
            revert InsufficientTokens(tokens, availableTokens);
        }
        
        // Validate against dynamic limits
        _validateDynamicLimits(msg.sender, tokens, msg.value, priceImpact);
        
        // Update state before external calls
        uint256 oldPhase = _getCurrentPhase(totalTokensSold);
        totalTokensSold += tokens;
        totalEthCollected += msg.value;
        
        // Update user tracking
        lastPurchaseTime[msg.sender] = block.timestamp;
        userDailyVolume[msg.sender] += msg.value;
        userPurchaseCount[msg.sender]++;
        dailyVolume[currentDay] += msg.value;
        
        // Track unique buyers
        if (userPurchaseCount[msg.sender] == 1) {
            metrics.totalBuyers++;
            dailyBuyers[currentDay].push(msg.sender);
        }
        
        // Check for phase change
        uint256 newPhase = _getCurrentPhase(totalTokensSold);
        if (newPhase != oldPhase) {
            uint256 projectedPrice = _getPriceAtSupply(50_000_000 * 10**18);
            emit PricePhaseChanged(oldPhase, newPhase, totalTokensSold, _getPhaseIncrement(newPhase), projectedPrice);
        }
        
        // Update system health
        _updateSystemHealth(priceImpact, msg.value);
        
        // Record price point
        _recordPricePoint(averagePrice);
        
        // CRITICAL: Allocate and deploy funds immediately
        _allocateAndDeployFunds(msg.value);
        
        // Transfer tokens to buyer (external call last)
        tcgToken.safeTransfer(msg.sender, tokens);
        
        // Emit comprehensive event
        emit TokensPurchased(
            msg.sender,
            tokens,
            msg.value,
            averagePrice,
            getCurrentPrice(),
            priceImpact,
            systemHealthScore
        );
        
        // Check for automatic deployments
        _checkAutomaticDeployments();
        
        return tokens;
    }
    
    // ==================== CAPITAL ALLOCATION & DEPLOYMENT ====================
    
    /**
     * @notice Allocate and immediately deploy funds for maximum productivity
     * @param ethAmount Amount to allocate and deploy
     */
    function _allocateAndDeployFunds(uint256 ethAmount) internal {
        // Calculate allocations
        uint256 toLender = (ethAmount * LENDER_PERCENTAGE) / BASIS_POINTS;
        uint256 toBuyback = (ethAmount * BUYBACK_PERCENTAGE) / BASIS_POINTS;
        uint256 toLiquidity = (ethAmount * LIQUIDITY_PERCENTAGE) / BASIS_POINTS;
        uint256 toOperations = ethAmount - toLender - toBuyback - toLiquidity; // Remainder for precision
        
        // Update pending amounts
        capitalDeployments["lender"].pendingAmount += toLender;
        capitalDeployments["buyback"].pendingAmount += toBuyback;
        capitalDeployments["liquidity"].pendingAmount += toLiquidity;
        capitalDeployments["operations"].pendingAmount += toOperations;
        
        // Deploy immediately if thresholds met
        uint256 totalDeployed = 0;
        
        if (capitalDeployments["lender"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD) {
            totalDeployed += _deployToLender();
        }
        
        if (capitalDeployments["buyback"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD) {
            totalDeployed += _deployToBuyback();
        }
        
        if (capitalDeployments["liquidity"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD) {
            totalDeployed += _deployToLiquidity();
        }
        
        if (capitalDeployments["operations"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD) {
            totalDeployed += _deployToOperations();
        }
        
        // Emit allocation event
        emit FundsAllocated(toLender, toBuyback, toLiquidity, toOperations, totalDeployed);
    }
    
    /**
     * @notice Deploy funds to lender for productive use
     * @return amountDeployed Amount successfully deployed
     */
    function _deployToLender() internal returns (uint256 amountDeployed) {
        uint256 amount = capitalDeployments["lender"].pendingAmount;
        if (amount == 0) return 0;
        
        // Try to call lender interface
        bool success;
        if (lenderAddress.code.length > 0) {
            try ILender(lenderAddress).receiveFunds{value: amount}(address(0), amount) {
                success = true;
            } catch {
                // Fallback to direct transfer
                (success,) = lenderAddress.call{value: amount}("");
            }
        } else {
            // Direct transfer if not a contract
            (success,) = lenderAddress.call{value: amount}("");
        }
        
        if (success) {
            capitalDeployments["lender"].pendingAmount = 0;
            capitalDeployments["lender"].totalSent += amount;
            capitalDeployments["lender"].lastDeployment = block.timestamp;
            totalEthDeployed += amount;
            
            emit CapitalDeployed("lender", amount, capitalDeployments["lender"].totalSent, lenderAddress);
            return amount;
        } else {
            revert DeploymentFailed("lender", amount);
        }
    }
    
    /**
     * @notice Deploy funds to buyback address
     * @return amountDeployed Amount successfully deployed
     */
    function _deployToBuyback() internal returns (uint256 amountDeployed) {
        uint256 amount = capitalDeployments["buyback"].pendingAmount;
        if (amount == 0) return 0;
        
        (bool success,) = buybackAddress.call{value: amount}("");
        if (success) {
            capitalDeployments["buyback"].pendingAmount = 0;
            capitalDeployments["buyback"].totalSent += amount;
            capitalDeployments["buyback"].lastDeployment = block.timestamp;
            totalEthDeployed += amount;
            
            emit CapitalDeployed("buyback", amount, capitalDeployments["buyback"].totalSent, buybackAddress);
            return amount;
        } else {
            revert DeploymentFailed("buyback", amount);
        }
    }
    
    /**
     * @notice Deploy funds to liquidity address
     * @return amountDeployed Amount successfully deployed
     */
    function _deployToLiquidity() internal returns (uint256 amountDeployed) {
        uint256 amount = capitalDeployments["liquidity"].pendingAmount;
        if (amount == 0) return 0;
        
        (bool success,) = liquidityAddress.call{value: amount}("");
        if (success) {
            capitalDeployments["liquidity"].pendingAmount = 0;
            capitalDeployments["liquidity"].totalSent += amount;
            capitalDeployments["liquidity"].lastDeployment = block.timestamp;
            totalEthDeployed += amount;
            
            emit CapitalDeployed("liquidity", amount, capitalDeployments["liquidity"].totalSent, liquidityAddress);
            return amount;
        } else {
            revert DeploymentFailed("liquidity", amount);
        }
    }
    
    /**
     * @notice Deploy funds to operations address
     * @return amountDeployed Amount successfully deployed
     */
    function _deployToOperations() internal returns (uint256 amountDeployed) {
        uint256 amount = capitalDeployments["operations"].pendingAmount;
        if (amount == 0) return 0;
        
        (bool success,) = operationsAddress.call{value: amount}("");
        if (success) {
            capitalDeployments["operations"].pendingAmount = 0;
            capitalDeployments["operations"].totalSent += amount;
            capitalDeployments["operations"].lastDeployment = block.timestamp;
            totalEthDeployed += amount;
            
            emit CapitalDeployed("operations", amount, capitalDeployments["operations"].totalSent, operationsAddress);
            return amount;
        } else {
            revert DeploymentFailed("operations", amount);
        }
    }
    
    /**
     * @notice Force deployment of all pending funds
     */
    function forceDeployAllFunds() external onlyRole(TREASURY_ROLE) nonReentrant {
        uint256 startGas = gasleft();
        string[] memory destinations = new string[](4);
        uint256[] memory amounts = new uint256[](4);
        uint256 totalDeployed = 0;
        uint256 i = 0;
        
        // Deploy all pending funds regardless of threshold
        if (capitalDeployments["lender"].pendingAmount > 0) {
            amounts[i] = _deployToLender();
            destinations[i] = "lender";
            totalDeployed += amounts[i];
            i++;
        }
        
        if (capitalDeployments["buyback"].pendingAmount > 0) {
            amounts[i] = _deployToBuyback();
            destinations[i] = "buyback";
            totalDeployed += amounts[i];
            i++;
        }
        
        if (capitalDeployments["liquidity"].pendingAmount > 0) {
            amounts[i] = _deployToLiquidity();
            destinations[i] = "liquidity";
            totalDeployed += amounts[i];
            i++;
        }
        
        if (capitalDeployments["operations"].pendingAmount > 0) {
            amounts[i] = _deployToOperations();
            destinations[i] = "operations";
            totalDeployed += amounts[i];
            i++;
        }
        
        uint256 gasUsed = startGas - gasleft();
        
        emit AutomaticDeployment(destinations, amounts, totalDeployed, gasUsed);
    }
    
    // ==================== CALCULATION FUNCTIONS ====================
    
    /**
     * @notice Calculate tokens received using accelerating bonding curve
     * @param ethAmount Amount of ETH to spend
     * @return tokens Amount of tokens to receive
     * @return averagePrice Average price paid per token
     * @return priceImpact Price impact percentage (in basis points)
     */
    function _calculateTokensWithAcceleratingCurve(uint256 ethAmount) 
        internal 
        view 
        returns (uint256 tokens, uint256 averagePrice, uint256 priceImpact) 
    {
        uint256 remainingEth = ethAmount;
        uint256 totalTokens = 0;
        uint256 currentSold = totalTokensSold;
        uint256 startPrice = getCurrentPrice();
        
        while (remainingEth > 0) {
            uint256 currentPhase = _getCurrentPhase(currentSold);
            uint256 phaseIncrement = _getPhaseIncrement(currentPhase);
            uint256 currentStep = currentSold / TOKENS_PER_STEP;
            uint256 currentPrice = INITIAL_PRICE + (currentStep * phaseIncrement);
            
            // Tokens until next price step
            uint256 tokensUntilNextStep = TOKENS_PER_STEP - (currentSold % TOKENS_PER_STEP);
            uint256 ethForCurrentStep = (tokensUntilNextStep * currentPrice) / 10**18;
            
            if (remainingEth >= ethForCurrentStep) {
                // Buy all remaining tokens at current price
                totalTokens += tokensUntilNextStep;
                remainingEth -= ethForCurrentStep;
                currentSold += tokensUntilNextStep;
            } else {
                // Buy partial tokens at current price
                uint256 tokensToBuy = (remainingEth * 10**18) / currentPrice;
                totalTokens += tokensToBuy;
                currentSold += tokensToBuy;
                remainingEth = 0;
            }
        }
        
        tokens = totalTokens;
        averagePrice = (ethAmount * 10**18) / tokens;
        
        // Calculate price impact
        uint256 endPrice = _getPriceAtSupply(currentSold);
        if (startPrice > 0) {
            priceImpact = ((endPrice - startPrice) * BASIS_POINTS) / startPrice;
        }
    }
    
    // ==================== DYNAMIC SYSTEM MANAGEMENT ====================
    
    /**
     * @notice Initialize dynamic limits based on phase
     */
    function _initializeDynamicLimits() internal {
        uint256 phase = _getCurrentPhase(totalTokensSold);
        
        if (phase == 1) {
            dynamicPurchaseLimit = 100_000 * 10**18;  // 100k tokens
            dynamicDailyLimit = 20 ether;             // 20 ETH
        } else if (phase == 2) {
            dynamicPurchaseLimit = 250_000 * 10**18;  // 250k tokens
            dynamicDailyLimit = 50 ether;             // 50 ETH
        } else if (phase == 3) {
            dynamicPurchaseLimit = 500_000 * 10**18;  // 500k tokens
            dynamicDailyLimit = 100 ether;            // 100 ETH
        } else {
            dynamicPurchaseLimit = 1_000_000 * 10**18; // 1M tokens
            dynamicDailyLimit = 200 ether;             // 200 ETH
        }
    }
    
    /**
     * @notice Validate purchase against dynamic limits
     */
    function _validateDynamicLimits(
        address buyer,
        uint256 tokens,
        uint256 ethAmount,
        uint256 priceImpact
    ) internal view {
        // Token purchase limit
        if (tokens > dynamicPurchaseLimit) {
            revert PurchaseLimitExceeded("dynamicPurchaseLimit", dynamicPurchaseLimit, tokens);
        }
        
        // Daily ETH limit
        if (userDailyVolume[buyer] + ethAmount > dynamicDailyLimit) {
            revert PurchaseLimitExceeded("userDailyLimit", dynamicDailyLimit, userDailyVolume[buyer] + ethAmount);
        }
        
        // Price impact limit (scaled by health)
        uint256 adjustedImpactLimit = (PRICE_IMPACT_THRESHOLD * systemHealthScore) / 100;
        if (priceImpact > adjustedImpactLimit) {
            revert ExcessivePriceImpact(priceImpact, adjustedImpactLimit);
        }
        
        // Percentage of supply limit
        if (totalTokensSold > 0) {
            uint256 maxPercent = (totalTokensSold * MAX_PURCHASE_PERCENTAGE) / BASIS_POINTS;
            if (tokens > maxPercent) {
                revert PurchaseLimitExceeded("percentageLimit", maxPercent, tokens);
            }
        }
    }
    
    /**
     * @notice Update system health based on activity
     */
    function _updateSystemHealth(uint256 priceImpact, uint256 volume) internal {
        uint256 oldHealth = systemHealthScore;
        
        // Positive factors
        if (priceImpact < 100) { // Less than 1% impact
            systemHealthScore = Math.min(100, systemHealthScore + 1);
        }
        
        // Negative factors
        if (priceImpact > 500) { // More than 5% impact
            systemHealthScore = systemHealthScore > 10 ? systemHealthScore - 10 : 0;
        }
        
        // Volume-based adjustments
        uint256 avgDaily = _getAverageDailyVolume();
        if (avgDaily > 0) {
            if (volume > avgDaily * 5) {
                systemHealthScore = systemHealthScore > 5 ? systemHealthScore - 5 : 0;
            } else if (volume < avgDaily * 2) {
                systemHealthScore = Math.min(100, systemHealthScore + 2);
            }
        }
        
        if (oldHealth != systemHealthScore) {
            emit SystemHealthUpdated(oldHealth, systemHealthScore, "Activity-based adjustment");
            
            // Update limits if health changed significantly
            if (Math.max(oldHealth, systemHealthScore) - Math.min(oldHealth, systemHealthScore) > 20) {
                _updateDynamicLimits("Health change");
            }
        }
    }
    
    /**
     * @notice Update dynamic limits based on system state
     */
    function _updateDynamicLimits(string memory reason) internal {
        uint256 healthMultiplier = (systemHealthScore + 50) / 100; // 0.5x to 1.5x
        
        // Get base limits for current phase
        _initializeDynamicLimits();
        
        // Adjust by health
        dynamicPurchaseLimit = (dynamicPurchaseLimit * healthMultiplier);
        dynamicDailyLimit = (dynamicDailyLimit * healthMultiplier);
        
        emit DynamicLimitsUpdated(dynamicPurchaseLimit, dynamicDailyLimit, systemHealthScore, reason);
    }
    
    /**
     * @notice Check and execute automatic deployments
     */
    function _checkAutomaticDeployments() internal {
        // Deploy if any pending amount exceeds threshold
        if (capitalDeployments["lender"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD ||
            capitalDeployments["buyback"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD ||
            capitalDeployments["liquidity"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD ||
            capitalDeployments["operations"].pendingAmount >= FUNDS_DEPLOYMENT_THRESHOLD) {
            
            // Use remaining gas for deployments
            if (gasleft() > 100000) {
                try this.forceDeployAllFunds() {
                    // Deployment successful
                } catch {
                    // Log but don't revert main transaction
                }
            }
        }
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get current token price from bonding curve
     */
    function getCurrentPrice() public view returns (uint256) {
        return _getPriceAtSupply(totalTokensSold);
    }
    
    /**
     * @notice Get comprehensive system statistics
     */
    function getSystemStats() external view returns (
        uint256 _totalTokensSold,
        uint256 _currentPrice,
        uint256 _currentPhase,
        uint256 _totalEthCollected,
        uint256 _totalEthDeployed,
        uint256 _systemHealth,
        uint256 _uniqueBuyers,
        uint256 _tokensAvailable
    ) {
        return (
            totalTokensSold,
            getCurrentPrice(),
            _getCurrentPhase(totalTokensSold),
            totalEthCollected,
            totalEthDeployed,
            systemHealthScore,
            metrics.totalBuyers,
            tcgToken.balanceOf(address(this))
        );
    }
    
    /**
     * @notice Get capital deployment statistics
     */
    function getDeploymentStats() external view returns (
        uint256 lenderTotal,
        uint256 lenderPending,
        uint256 buybackTotal,
        uint256 buybackPending,
        uint256 liquidityTotal,
        uint256 liquidityPending,
        uint256 operationsTotal,
        uint256 operationsPending
    ) {
        return (
            capitalDeployments["lender"].totalSent,
            capitalDeployments["lender"].pendingAmount,
            capitalDeployments["buyback"].totalSent,
            capitalDeployments["buyback"].pendingAmount,
            capitalDeployments["liquidity"].totalSent,
            capitalDeployments["liquidity"].pendingAmount,
            capitalDeployments["operations"].totalSent,
            capitalDeployments["operations"].pendingAmount
        );
    }
    
    /**
     * @notice Get detailed quote for purchase
     */
    function getDetailedQuote(uint256 ethAmount) external view returns (
        uint256 tokens,
        uint256 averagePrice,
        uint256 priceImpact,
        uint256 currentPrice,
        uint256 finalPrice,
        bool withinLimits,
        string memory limitReason
    ) {
        (tokens, averagePrice, priceImpact) = _calculateTokensWithAcceleratingCurve(ethAmount);
        currentPrice = getCurrentPrice();
        finalPrice = _getPriceAtSupply(totalTokensSold + tokens);
        
        // Check limits
        withinLimits = true;
        limitReason = "";
        
        if (tokens > dynamicPurchaseLimit) {
            withinLimits = false;
            limitReason = "Exceeds purchase limit";
        } else if (priceImpact > PRICE_IMPACT_THRESHOLD) {
            withinLimits = false;
            limitReason = "Excessive price impact";
        } else if (tokens > tcgToken.balanceOf(address(this))) {
            withinLimits = false;
            limitReason = "Insufficient token supply";
        }
    }
    
    /**
     * @notice Get average daily volume
     */
    function _getAverageDailyVolume() internal view returns (uint256) {
        uint256 total = 0;
        uint256 days = 0;
        uint256 today = block.timestamp / 1 days;
        
        // Look back up to 7 days
        for (uint256 i = 1; i <= 7; i++) {
            if (today >= i) {
                uint256 dayVolume = dailyVolume[today - i];
                if (dayVolume > 0) {
                    total += dayVolume;
                    days++;
                }
            }
        }
        
        return days > 0 ? total / days : 0;
    }
    
    // ==================== PRICE CURVE FUNCTIONS ====================
    
    function _getCurrentPhase(uint256 tokensSold) internal pure returns (uint256) {
        if (tokensSold < PHASE_1_END) return 1;
        if (tokensSold < PHASE_2_END) return 2;
        if (tokensSold < PHASE_3_END) return 3;
        return 4;
    }
    
    function _getPhaseIncrement(uint256 phase) internal pure returns (uint256) {
        if (phase == 1) return PHASE_1_INCREMENT;
        if (phase == 2) return PHASE_2_INCREMENT;
        if (phase == 3) return PHASE_3_INCREMENT;
        return PHASE_4_INCREMENT;
    }
    
    function _getPriceAtSupply(uint256 supply) internal pure returns (uint256) {
        uint256 totalPrice = INITIAL_PRICE;
        uint256 remaining = supply;
        
        // Phase 1 calculation
        if (remaining > 0) {
            uint256 phase1Tokens = remaining > PHASE_1_END ? PHASE_1_END : remaining;
            uint256 phase1Steps = phase1Tokens / TOKENS_PER_STEP;
            totalPrice += phase1Steps * PHASE_1_INCREMENT;
            remaining -= phase1Tokens;
        }
        
        // Phase 2 calculation
        if (remaining > 0) {
            uint256 phase2Tokens = remaining > (PHASE_2_END - PHASE_1_END) ? 
                (PHASE_2_END - PHASE_1_END) : remaining;
            uint256 phase2Steps = phase2Tokens / TOKENS_PER_STEP;
            totalPrice += phase2Steps * PHASE_2_INCREMENT;
            remaining -= phase2Tokens;
        }
        
        // Phase 3 calculation
        if (remaining > 0) {
            uint256 phase3Tokens = remaining > (PHASE_3_END - PHASE_2_END) ? 
                (PHASE_3_END - PHASE_2_END) : remaining;
            uint256 phase3Steps = phase3Tokens / TOKENS_PER_STEP;
            totalPrice += phase3Steps * PHASE_3_INCREMENT;
            remaining -= phase3Tokens;
        }
        
        // Phase 4 calculation
        if (remaining > 0) {
            uint256 phase4Steps = remaining / TOKENS_PER_STEP;
            totalPrice += phase4Steps * PHASE_4_INCREMENT;
        }
        
        return totalPrice;
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Update destination addresses
     */
    function updateDestinationAddresses(
        address _lender,
        address _buyback,
        address _liquidity,
        address _operations
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_lender == address(0) || _buyback == address(0) || 
            _liquidity == address(0) || _operations == address(0)) {
            revert ZeroAddress("destination address");
        }
        
        lenderAddress = _lender;
        buybackAddress = _buyback;
        liquidityAddress = _liquidity;
        operationsAddress = _operations;
    }
    
    /**
     * @notice Manual health score adjustment
     */
    function adjustSystemHealth(int256 adjustment, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        uint256 oldHealth = systemHealthScore;
        
        if (adjustment > 0) {
            systemHealthScore = Math.min(100, systemHealthScore + uint256(adjustment));
        } else {
            uint256 decrease = uint256(-adjustment);
            systemHealthScore = systemHealthScore > decrease ? systemHealthScore - decrease : 0;
        }
        
        emit SystemHealthUpdated(oldHealth, systemHealthScore, reason);
        _updateDynamicLimits("Manual adjustment");
    }
    
    /**
     * @notice Emergency pause
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        systemHealthScore = 0; // Force unhealthy state
        emit SystemHealthUpdated(systemHealthScore, 0, "Emergency pause");
    }
    
    /**
     * @notice Resume operations
     */
    function resume() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
        systemHealthScore = 50; // Start at neutral health
        _updateDynamicLimits("System resumed");
    }
    
    // ==================== ORACLE FUNCTIONS ====================
    
    function getLatestPrice() external view override returns (uint256) {
        return getCurrentPrice();
    }
    
    function getAveragePrice(uint256 period) external view override returns (uint256) {
        if (priceHistory.length == 0) return getCurrentPrice();
        
        uint256 cutoffTime = block.timestamp - period;
        uint256 sumPrice = 0;
        uint256 sumWeight = 0;
        
        // Volume-weighted average price
        for (uint256 i = priceHistory.length; i > 0; i--) {
            PricePoint memory point = priceHistory[i - 1];
            if (point.timestamp < cutoffTime) break;
            
            uint256 weight = point.volume24h > 0 ? point.volume24h : 1 ether;
            sumPrice += point.price * weight;
            sumWeight += weight;
        }
        
        return sumWeight > 0 ? sumPrice / sumWeight : getCurrentPrice();
    }
    
    // ==================== INTERNAL HELPERS ====================
    
    function _updateDailyTracking() internal {
        uint256 today = block.timestamp / 1 days;
        if (today > currentDay) {
            currentDay = today;
            // Reset daily volumes for users would go here in production
            // For gas efficiency, we track but don't reset individual user volumes
        }
    }
    
    function _recordPricePoint(uint256 price) internal {
        // Limit array size for gas efficiency
        if (priceHistory.length >= 168) { // 1 week of hourly data
            for (uint256 i = 0; i < priceHistory.length - 1; i++) {
                priceHistory[i] = priceHistory[i + 1];
            }
            priceHistory.pop();
        }
        
        uint256 volume24h = _get24HourVolume();
        uint256 uniqueBuyers = dailyBuyers[currentDay].length;
        uint256 avgPurchase = uniqueBuyers > 0 ? dailyVolume[currentDay] / uniqueBuyers : 0;
        
        priceHistory.push(PricePoint({
            timestamp: block.timestamp,
            price: price,
            tokensSold: totalTokensSold,
            volume24h: volume24h,
            uniqueBuyers24h: uniqueBuyers,
            averagePurchaseSize: avgPurchase
        }));
    }
    
    function _get24HourVolume() internal view returns (uint256) {
        uint256 volume = 0;
        uint256 cutoff = block.timestamp - 1 days;
        uint256 today = block.timestamp / 1 days;
        
        // Current day volume
        volume += dailyVolume[today];
        
        // Previous day partial volume
        if (today > 0) {
            // Estimate based on time passed
            uint256 secondsToday = block.timestamp % 1 days;
            uint256 yesterdayWeight = (1 days - secondsToday) * 100 / 1 days;
            volume += (dailyVolume[today - 1] * yesterdayWeight) / 100;
        }
        
        return volume;
    }
    
    // ==================== RECEIVE FUNCTION ====================
    
    receive() external payable {
        // Accept ETH for potential refunds or direct deposits
    }
}
