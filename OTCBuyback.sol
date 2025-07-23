// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IVendingMachine {
    function getPriceInUSDC() external view returns (uint256);
}

interface IBuybackVault {
    function depositUSDC(uint256 amount) external;
}

/**
 * @title OTCBuyback V2
 * @author Circularity Finance
 * @notice Improved OTC buyback with automatic USDC detection and recalibration
 * @dev Accepts direct USDC transfers and auto-updates liquidity on each sale
 * 
 * Key Improvements:
 * - Direct USDC transfers supported (no deposit function needed)
 * - Automatic liquidity recalibration on each sale
 * - Real-time liquidity tracking from any source
 * - Enhanced analytics and monitoring
 * - Gas-efficient lazy updates
 */
contract OTCBuybackV2 is ReentrancyGuard, Pausable, Ownable2Step {
    // Constants
    uint256 private constant BASIS_POINTS = 10000; // 100% = 10000 basis points
    uint256 private constant ROLLING_WINDOW = 30 days;
    uint256 private constant MAX_DISCOUNT_BASIS_POINTS = 5000; // 50% max discount
    uint256 private constant MAX_TAX_BASIS_POINTS = 2500; // 25% max tax
    uint256 private constant USDC_DECIMALS = 6;
    uint256 private constant MAX_REASONABLE_PRICE = 1e12; // $1M per token max
    uint256 private constant MAX_HISTORY_ENTRIES = 50; // Limit history for gas efficiency
    
    // State variables
    IERC20 public immutable token;
    IERC20 public immutable USDC;
    uint8 public immutable tokenDecimals;
    
    IVendingMachine public vendingMachine;
    IBuybackVault public buybackVault;
    
    uint256 public discountBasisPoints = 2000; // 20% default
    uint256 public taxThreshold = 10_000 * 1e18; // Normalized to 18 decimals
    uint256 public taxBasisPoints = 1000; // 10% default
    
    // Liquidity tracking with lazy updates
    uint256 public lastKnownUSDCBalance;     // Last recorded USDC balance
    uint256 public totalUSDCReceived;        // Total USDC ever received
    uint256 public totalUSDCPaidOut;         // Total USDC paid to sellers
    uint256 public minimumLiquidity = 1000 * 1e6; // 1000 USDC minimum warning threshold
    
    // Track USDC sources for analytics
    mapping(address => uint256) public liquidityProviders;
    
    // Admin timelock
    uint256 public constant TIMELOCK_DURATION = 2 days;
    mapping(bytes32 => uint256) public timelockOperations;
    
    // User tracking with rolling window
    struct UserSales {
        uint256 amount;
        uint256 timestamp;
    }
    mapping(address => UserSales[]) public userSalesHistory;
    
    // Events
    event LiquidityRecalibrated(uint256 newUSDCDetected, uint256 totalLiquidity, address indexed triggeredBy);
    event USDCDetected(address indexed from, uint256 amount, uint256 newTotal);
    event TokensSold(
        address indexed seller,
        uint256 tokenAmount,
        uint256 usdcPayout,
        bool taxApplied,
        uint256 effectivePrice
    );
    event LowLiquidityWarning(uint256 remainingUSDC, uint256 threshold);
    event MinimumLiquidityUpdated(uint256 oldMinimum, uint256 newMinimum);
    event DiscountUpdated(uint256 oldBasisPoints, uint256 newBasisPoints);
    event TaxSettingsUpdated(uint256 oldThreshold, uint256 newThreshold, uint256 oldRate, uint256 newRate);
    event VaultForwarded(uint256 amount, uint256 blockTimestamp);
    event VendingMachineUpdated(address oldMachine, address newMachine);
    event BuybackVaultUpdated(address oldVault, address newVault);
    event USDCWithdrawn(address indexed to, uint256 amount);
    event TimelockInitiated(bytes32 indexed operation, uint256 executeTime);
    event TimelockExecuted(bytes32 indexed operation);
    event TimelockCancelled(bytes32 indexed operation);
    
    // Errors
    error InvalidAmount();
    error InsufficientLiquidity();
    error InvalidPrice();
    error ExternalCallFailed();
    error TimelockNotReady();
    error InvalidAddress();
    error ValueTooHigh();
    error InsufficientOutput();
    
    constructor(
        address _token,
        address _usdc,
        address _vendingMachine,
        address _vault
    ) Ownable(msg.sender) {
        if (_token == address(0) || _usdc == address(0) || _vendingMachine == address(0) || 
            _vault == address(0)) {
            revert InvalidAddress();
        }
        
        token = IERC20(_token);
        USDC = IERC20(_usdc);
        tokenDecimals = IERC20(_token).decimals();
        vendingMachine = IVendingMachine(_vendingMachine);
        buybackVault = IBuybackVault(_vault);
        
        // Initialize last known balance to current balance
        lastKnownUSDCBalance = USDC.balanceOf(address(this));
    }
    
    /**
     * @dev Recalibrate liquidity by checking current USDC balance
     * @return newUSDCDetected Amount of new USDC detected
     */
    function _recalibrateLiquidity() internal returns (uint256 newUSDCDetected) {
        uint256 currentBalance = USDC.balanceOf(address(this));
        
        // Check if balance increased (new USDC received)
        if (currentBalance > lastKnownUSDCBalance) {
            newUSDCDetected = currentBalance - lastKnownUSDCBalance;
            totalUSDCReceived += newUSDCDetected;
            
            // Note: We can't determine the sender in a standard transfer
            emit USDCDetected(address(0), newUSDCDetected, totalUSDCReceived);
        }
        
        // Update last known balance
        lastKnownUSDCBalance = currentBalance;
        
        return newUSDCDetected;
    }
    
    /**
     * @dev Force liquidity recalibration (can be called by anyone)
     * @notice Useful for updating liquidity without making a sale
     */
    function recalibrateLiquidity() external {
        uint256 newUSDC = _recalibrateLiquidity();
        emit LiquidityRecalibrated(newUSDC, getAvailableLiquidity(), msg.sender);
    }
    
    /**
     * @dev Get current available USDC liquidity
     * @return Current USDC balance
     */
    function getAvailableLiquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    /**
     * @dev Check if current balance differs from last known
     * @return hasNewUSDC Whether new USDC has been received
     * @return amount Amount of new USDC
     */
    function checkForNewUSDC() external view returns (bool hasNewUSDC, uint256 amount) {
        uint256 currentBalance = USDC.balanceOf(address(this));
        if (currentBalance > lastKnownUSDCBalance) {
            return (true, currentBalance - lastKnownUSDCBalance);
        }
        return (false, 0);
    }
    
    /**
     * @dev Update minimum liquidity threshold
     * @param newMinimum New minimum USDC threshold
     */
    function setMinimumLiquidity(uint256 newMinimum) external onlyOwner {
        uint256 oldMinimum = minimumLiquidity;
        minimumLiquidity = newMinimum;
        emit MinimumLiquidityUpdated(oldMinimum, newMinimum);
    }
    
    /**
     * @dev Check if liquidity is low
     * @return Whether liquidity is below threshold
     */
    function isLiquidityLow() public view returns (bool) {
        return getAvailableLiquidity() < minimumLiquidity;
    }
    
    /**
     * @dev Sell tokens back to the protocol for USDC
     * @param amount Amount of tokens to sell (in token's native decimals)
     * @param minPayout Minimum acceptable USDC payout (slippage protection)
     */
    function sellTokens(
        uint256 amount,
        uint256 minPayout
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        // First, recalibrate liquidity to detect any new USDC
        _recalibrateLiquidity();
        
        // Transfer tokens from seller
        if (!token.transferFrom(msg.sender, address(this), amount)) {
            revert ExternalCallFailed();
        }
        
        // Normalize amount to 18 decimals for calculations
        uint256 normalizedAmount = normalizeToDecimals(amount, tokenDecimals, 18);
        
        // Get and validate price
        uint256 salePrice = vendingMachine.getPriceInUSDC();
        if (salePrice == 0 || salePrice > MAX_REASONABLE_PRICE) {
            revert InvalidPrice();
        }
        
        // Calculate discounted price with basis points
        uint256 discountedPrice = (salePrice * (BASIS_POINTS - discountBasisPoints)) / BASIS_POINTS;
        
        // Calculate base payout in USDC (6 decimals)
        uint256 usdcPayout = (normalizedAmount * discountedPrice) / 1e18;
        usdcPayout = usdcPayout / (10 ** (18 - USDC_DECIMALS)); // Convert to USDC decimals
        
        // Check and apply tax if over threshold
        bool taxApplied = false;
        uint256 rollingAmount = getRollingWindowAmount(msg.sender);
        if (rollingAmount + normalizedAmount > taxThreshold) {
            taxApplied = true;
            usdcPayout = (usdcPayout * (BASIS_POINTS - taxBasisPoints)) / BASIS_POINTS;
        }
        
        // Record the sale
        _recordSale(msg.sender, normalizedAmount);
        
        // Slippage protection
        if (usdcPayout < minPayout) revert InsufficientOutput();
        
        // Check liquidity (already recalibrated)
        uint256 availableLiquidity = getAvailableLiquidity();
        if (availableLiquidity < usdcPayout) revert InsufficientLiquidity();
        
        // Update tracking before transfer
        totalUSDCPaidOut += usdcPayout;
        lastKnownUSDCBalance -= usdcPayout;
        
        // Transfer USDC to seller
        if (!USDC.transfer(msg.sender, usdcPayout)) {
            revert ExternalCallFailed();
        }
        
        // Check for low liquidity warning
        if (isLiquidityLow()) {
            emit LowLiquidityWarning(getAvailableLiquidity(), minimumLiquidity);
        }
        
        emit TokensSold(
            msg.sender,
            amount,
            usdcPayout,
            taxApplied,
            discountedPrice
        );
    }
    
    /**
     * @dev Calculate expected USDC payout for a token amount (view function for UI)
     * @param tokenAmount Amount of tokens to sell
     * @param userAddress Address of the seller (to check tax status)
     * @return usdcPayout Expected USDC payout
     * @return willBeTaxed Whether tax will be applied
     * @return sufficientLiquidity Whether contract has enough USDC
     */
    function calculatePayout(
        uint256 tokenAmount,
        address userAddress
    ) external view returns (uint256 usdcPayout, bool willBeTaxed, bool sufficientLiquidity) {
        // Normalize amount
        uint256 normalizedAmount = normalizeToDecimals(tokenAmount, tokenDecimals, 18);
        
        // Get price
        uint256 salePrice = vendingMachine.getPriceInUSDC();
        if (salePrice == 0 || salePrice > MAX_REASONABLE_PRICE) {
            return (0, false, false);
        }
        
        // Calculate discounted price
        uint256 discountedPrice = (salePrice * (BASIS_POINTS - discountBasisPoints)) / BASIS_POINTS;
        
        // Calculate base payout
        usdcPayout = (normalizedAmount * discountedPrice) / 1e18;
        usdcPayout = usdcPayout / (10 ** (18 - USDC_DECIMALS));
        
        // Check if tax applies
        uint256 rollingAmount = getRollingWindowAmount(userAddress);
        if (rollingAmount + normalizedAmount > taxThreshold) {
            willBeTaxed = true;
            usdcPayout = (usdcPayout * (BASIS_POINTS - taxBasisPoints)) / BASIS_POINTS;
        }
        
        // Check liquidity (including undetected USDC)
        sufficientLiquidity = getAvailableLiquidity() >= usdcPayout;
        
        return (usdcPayout, willBeTaxed, sufficientLiquidity);
    }
    
    /**
     * @dev Get detailed liquidity status
     * @return totalReceived Total USDC ever received
     * @return totalPaid Total USDC paid out
     * @return currentLiquidity Current available USDC
     * @return isLow Whether liquidity is below threshold
     * @return utilizationRate Percentage of received USDC that's been used
     * @return hasUndetectedUSDC Whether there's new USDC not yet accounted for
     */
    function getLiquidityStatus() external view returns (
        uint256 totalReceived,
        uint256 totalPaid,
        uint256 currentLiquidity,
        bool isLow,
        uint256 utilizationRate,
        bool hasUndetectedUSDC
    ) {
        totalReceived = totalUSDCReceived;
        totalPaid = totalUSDCPaidOut;
        currentLiquidity = getAvailableLiquidity();
        isLow = isLiquidityLow();
        utilizationRate = totalReceived > 0 ? (totalPaid * 10000) / totalReceived : 0;
        hasUndetectedUSDC = currentLiquidity > lastKnownUSDCBalance;
    }
    
    /**
     * @dev Record a sale in user's history
     */
    function _recordSale(address user, uint256 normalizedAmount) internal {
        userSalesHistory[user].push(UserSales({
            amount: normalizedAmount,
            timestamp: block.timestamp
        }));
        
        // Auto-cleanup old entries if history is getting too long
        if (userSalesHistory[user].length > MAX_HISTORY_ENTRIES) {
            _cleanupOldEntries(user);
        }
    }
    
    /**
     * @dev Get user's rolling 30-day sales amount
     */
    function getRollingWindowAmount(address user) public view returns (uint256) {
        UserSales[] storage sales = userSalesHistory[user];
        uint256 cutoffTime = block.timestamp - ROLLING_WINDOW;
        uint256 total = 0;
        
        // Sum sales within rolling window
        for (uint256 i = 0; i < sales.length; i++) {
            if (sales[i].timestamp >= cutoffTime) {
                total += sales[i].amount;
            }
        }
        
        return total;
    }
    
    /**
     * @dev Normalize token amount to specified decimals
     */
    function normalizeToDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        } else if (fromDecimals > toDecimals) {
            return amount / 10 ** (fromDecimals - toDecimals);
        }
        return amount;
    }
    
    /**
     * @dev Forward USDC to buyback vault
     * @param amount Amount to forward (0 for all excess above minimum)
     */
    function forwardToVault(uint256 amount) external onlyOwner nonReentrant {
        // Recalibrate first to ensure accurate liquidity
        _recalibrateLiquidity();
        
        uint256 availableLiquidity = getAvailableLiquidity();
        
        // If amount is 0, forward all excess above minimum liquidity
        if (amount == 0) {
            if (availableLiquidity <= minimumLiquidity) revert InsufficientLiquidity();
            amount = availableLiquidity - minimumLiquidity;
        } else {
            if (availableLiquidity < amount + minimumLiquidity) revert InsufficientLiquidity();
        }
        
        if (amount == 0) revert InvalidAmount();
        
        // Update tracking
        lastKnownUSDCBalance -= amount;
        
        // Approve vault to spend USDC
        if (!USDC.approve(address(buybackVault), amount)) {
            revert ExternalCallFailed();
        }
        
        // Deposit to vault
        try buybackVault.depositUSDC(amount) {
            emit VaultForwarded(amount, block.timestamp);
        } catch {
            revert ExternalCallFailed();
        }
    }
    
    // Timelocked Admin Functions
    
    /**
     * @dev Initiate discount update (timelocked)
     */
    function initiateDiscountUpdate(uint256 newBasisPoints) external onlyOwner {
        if (newBasisPoints > MAX_DISCOUNT_BASIS_POINTS) revert ValueTooHigh();
        
        bytes32 operation = keccak256(abi.encodePacked("updateDiscount", newBasisPoints));
        timelockOperations[operation] = block.timestamp + TIMELOCK_DURATION;
        
        emit TimelockInitiated(operation, timelockOperations[operation]);
    }
    
    /**
     * @dev Execute discount update after timelock
     */
    function executeDiscountUpdate(uint256 newBasisPoints) external onlyOwner {
        bytes32 operation = keccak256(abi.encodePacked("updateDiscount", newBasisPoints));
        
        if (block.timestamp < timelockOperations[operation]) revert TimelockNotReady();
        if (timelockOperations[operation] == 0) revert TimelockNotReady();
        
        uint256 oldBasisPoints = discountBasisPoints;
        discountBasisPoints = newBasisPoints;
        delete timelockOperations[operation];
        
        emit DiscountUpdated(oldBasisPoints, newBasisPoints);
        emit TimelockExecuted(operation);
    }
    
    /**
     * @dev Update tax settings (timelocked)
     */
    function initiateTaxSettingsUpdate(uint256 newThreshold, uint256 newBasisPoints) external onlyOwner {
        if (newBasisPoints > MAX_TAX_BASIS_POINTS) revert ValueTooHigh();
        
        bytes32 operation = keccak256(abi.encodePacked("updateTax", newThreshold, newBasisPoints));
        timelockOperations[operation] = block.timestamp + TIMELOCK_DURATION;
        
        emit TimelockInitiated(operation, timelockOperations[operation]);
    }
    
    /**
     * @dev Execute tax settings update after timelock
     */
    function executeTaxSettingsUpdate(uint256 newThreshold, uint256 newBasisPoints) external onlyOwner {
        bytes32 operation = keccak256(abi.encodePacked("updateTax", newThreshold, newBasisPoints));
        
        if (block.timestamp < timelockOperations[operation]) revert TimelockNotReady();
        if (timelockOperations[operation] == 0) revert TimelockNotReady();
        
        uint256 oldThreshold = taxThreshold;
        uint256 oldRate = taxBasisPoints;
        
        taxThreshold = newThreshold;
        taxBasisPoints = newBasisPoints;
        delete timelockOperations[operation];
        
        emit TaxSettingsUpdated(oldThreshold, newThreshold, oldRate, newBasisPoints);
        emit TimelockExecuted(operation);
    }
    
    /**
     * @dev Cancel a timelocked operation
     */
    function cancelTimelockOperation(bytes32 operation) external onlyOwner {
        delete timelockOperations[operation];
        emit TimelockCancelled(operation);
    }
    
    // Contract Updates (Immediate for security)
    
    function setVendingMachine(address newMachine) external onlyOwner {
        if (newMachine == address(0)) revert InvalidAddress();
        address oldMachine = address(vendingMachine);
        vendingMachine = IVendingMachine(newMachine);
        emit VendingMachineUpdated(oldMachine, newMachine);
    }
    
    function setBuybackVault(address newVault) external onlyOwner {
        if (newVault == address(0)) revert InvalidAddress();
        address oldVault = address(buybackVault);
        buybackVault = IBuybackVault(newVault);
        emit BuybackVaultUpdated(oldVault, newVault);
    }
    
    // Emergency Functions
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Emergency USDC withdrawal
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawUSDC(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        
        // Recalibrate first
        _recalibrateLiquidity();
        
        if (amount > getAvailableLiquidity()) revert InsufficientLiquidity();
        
        // Update tracking
        lastKnownUSDCBalance -= amount;
        
        if (!USDC.transfer(to, amount)) {
            revert ExternalCallFailed();
        }
        
        emit USDCWithdrawn(to, amount);
    }
    
    // View Functions
    
    function getUserSalesHistory(address user) external view returns (UserSales[] memory) {
        return userSalesHistory[user];
    }
    
    /**
     * @dev Clean up old sales history entries (public function)
     */
    function cleanupSalesHistory(address user) external {
        _cleanupOldEntries(user);
    }
    
    /**
     * @dev Internal function to clean up old sales entries
     */
    function _cleanupOldEntries(address user) internal {
        UserSales[] storage sales = userSalesHistory[user];
        if (sales.length == 0) return;
        
        uint256 cutoffTime = block.timestamp - ROLLING_WINDOW;
        
        // Find first index within window
        uint256 firstValidIndex = sales.length;
        for (uint256 i = 0; i < sales.length; i++) {
            if (sales[i].timestamp >= cutoffTime) {
                firstValidIndex = i;
                break;
            }
        }
        
        // If all sales are old, clear the array
        if (firstValidIndex >= sales.length) {
            delete userSalesHistory[user];
            return;
        }
        
        // If no cleanup needed
        if (firstValidIndex == 0) return;
        
        // Copy valid sales to beginning of array
        uint256 validCount = sales.length - firstValidIndex;
        for (uint256 i = 0; i < validCount; i++) {
            sales[i] = sales[firstValidIndex + i];
        }
        
        // Remove old entries
        uint256 toRemove = firstValidIndex;
        for (uint256 i = 0; i < toRemove; i++) {
            sales.pop();
        }
    }
}
