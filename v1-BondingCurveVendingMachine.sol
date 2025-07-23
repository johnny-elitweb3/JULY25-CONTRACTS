// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BondingCurveVendingMachine V3
 * @author Circularity Finance
 * @notice Production-ready token vending machine with automatic inventory recalibration
 * @dev Accepts direct token transfers and auto-detects inventory on purchase
 * 
 * Key Features:
 * - Direct token transfers supported (no deposit function needed)
 * - Automatic inventory recalibration on each purchase
 * - Full MEV protection and security features retained
 * - Gas-efficient lazy inventory updates
 * - Compatible with any wallet or dApp
 */

// OpenZeppelin style interfaces
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure
 */
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

/**
 * @title ReentrancyGuard
 * @dev Prevents reentrant calls to functions marked with `nonReentrant`
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * @title Timelock
 * @dev Adds time delays to critical function executions
 */
contract Timelock {
    uint256 public constant MINIMUM_DELAY = 2 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    mapping(bytes32 => uint256) public pendingActions;

    event ActionQueued(bytes32 indexed actionId, uint256 executeTime);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);

    modifier timeLocked(bytes32 actionId) {
        require(pendingActions[actionId] != 0, "Action not queued");
        require(block.timestamp >= pendingActions[actionId], "Timelock not expired");
        require(block.timestamp <= pendingActions[actionId] + 1 days, "Action expired");
        _;
        delete pendingActions[actionId];
        emit ActionExecuted(actionId);
    }

    function _queueAction(bytes32 actionId, uint256 delay) internal {
        require(delay >= MINIMUM_DELAY && delay <= MAXIMUM_DELAY, "Invalid delay");
        require(pendingActions[actionId] == 0, "Action already queued");
        
        uint256 executeTime = block.timestamp + delay;
        pendingActions[actionId] = executeTime;
        emit ActionQueued(actionId, executeTime);
    }

    function _cancelAction(bytes32 actionId) internal {
        require(pendingActions[actionId] != 0, "Action not queued");
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }
}

/**
 * @title BondingCurveVendingMachine V3
 * @notice Main contract with automatic inventory recalibration
 */
contract BondingCurveVendingMachineV3 is ReentrancyGuard, Timelock {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant PERCENTAGE_BASE = 10000; // 100.00%
    uint256 private constant MAX_PURCHASE_HISTORY = 100; // DoS protection
    uint256 private constant ROLLING_WINDOW = 24 hours;
    uint256 private constant COMMIT_DURATION = 2 minutes; // MEV protection
    uint256 private constant LOW_INVENTORY_THRESHOLD = 10; // 10% warning threshold
    
    // Immutable state
    address public immutable owner;
    IERC20 public immutable USDC;
    IERC20 public immutable token;
    uint256 public immutable tokenDecimals;
    
    // Distribution percentages (must sum to 10000)
    uint256 public constant RESERVE_PERCENTAGE = 3000; // 30%
    uint256 public constant OTC_PERCENTAGE = 2000; // 20%
    uint256 public constant OPS_PERCENTAGE = 2000; // 20%
    uint256 public constant DONATION_PERCENTAGE = 1000; // 10%
    uint256 public constant BITRUE_PERCENTAGE = 2000; // 20%
    
    // Configurable state
    address public oversight;
    bool public paused;
    bool public receiveEnabled = true;
    
    // Inventory tracking with lazy updates
    uint256 public lastKnownBalance;        // Last recorded token balance
    uint256 public totalTokensReceived;     // Total tokens ever received
    uint256 public totalTokensSold;         // Total tokens sold
    uint256 public minimumInventory = 1000 * 1e18; // Minimum before warning
    
    // Track deposits by address (for analytics)
    mapping(address => uint256) public depositorContributions;
    
    // NFT contracts
    IERC721 public vipNFT;
    IERC721 public govNFT;
    
    // Fund distribution addresses with failover
    struct Recipient {
        address primary;
        address failover;
        bool useFailover;
    }
    
    Recipient public reserveVault;
    Recipient public otcBuybackContract;
    Recipient public opsWallet;
    Recipient public donationWallet;
    Recipient public bitrueBuybackContract;
    
    // Bonding curve parameters
    uint256 public basePriceXDC;
    uint256 public slopeXDC;
    uint256 public basePriceUSDC;
    uint256 public slopeUSDC;
    
    // Purchase tracking with circular buffer (DoS protection)
    struct PurchaseWindow {
        uint256 amount;
        uint256 timestamp;
    }
    
    struct UserPurchaseData {
        PurchaseWindow[MAX_PURCHASE_HISTORY] purchases;
        uint256 nextIndex;
        uint256 totalEntries;
    }
    
    mapping(address => UserPurchaseData) private userPurchaseData;
    
    // MEV protection - commit/reveal pattern
    struct PurchaseCommit {
        bytes32 commitment;
        uint256 commitBlock;
        uint256 amount;
        bool isNative;
    }
    
    mapping(address => PurchaseCommit) public purchaseCommits;
    
    // Daily caps by role
    uint256 public constant DEFAULT_DAILY_CAP = 50_000 * 1e18;
    uint256 public constant VIP_DAILY_CAP = 100_000 * 1e18;
    uint256 public constant GOV_DAILY_CAP = 200_000 * 1e18;
    
    // Events
    event InventoryRecalibrated(uint256 newTokensDetected, uint256 totalInventory, address indexed triggeredBy);
    event TokensDetected(address indexed from, uint256 amount, uint256 newTotal);
    event TokenPurchased(
        address indexed buyer,
        uint256 amount,
        uint256 pricePerToken,
        address currency,
        uint256 totalCost
    );
    event PurchaseCommitted(address indexed buyer, bytes32 commitment);
    event LowInventoryWarning(uint256 remainingTokens, uint256 threshold);
    event MinimumInventoryUpdated(uint256 oldMinimum, uint256 newMinimum);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OversightTransferred(address indexed oldOversight, address indexed newOversight);
    event ReceiveToggled(bool enabled);
    event ConfigurationQueued(bytes32 indexed actionId, string action);
    event RecipientUpdated(string recipient, address primary, address failover);
    event RecipientFailoverToggled(string recipient, bool useFailover);
    event CurveParametersUpdated(
        uint256 basePriceXDC,
        uint256 slopeXDC,
        uint256 basePriceUSDC,
        uint256 slopeUSDC
    );
    event NFTContractsUpdated(address vipNFT, address govNFT);
    event EmergencyTokenWithdraw(address indexed token, uint256 amount, address indexed to);

    // Custom errors
    error InvalidAddress();
    error Unauthorized();
    error ContractPaused();
    error AmountZero();
    error TransferFailed();
    error ExceedsDailyCap();
    error InsufficientInventory();
    error SlippageExceeded();
    error ReceiveDisabled();
    error InvalidPercentages();
    error InvalidCommitment();
    error CommitmentTooEarly();
    error CommitmentExpired();
    error NoCommitment();

    constructor(
        address _usdc,
        address _token,
        uint256 _basePriceXDC,
        uint256 _slopeXDC,
        uint256 _basePriceUSDC,
        uint256 _slopeUSDC,
        address[10] memory _recipients, // [reserve_primary, reserve_failover, otc_primary, otc_failover, ...]
        address _vipNFT,
        address _govNFT,
        address _oversight
    ) {
        // Validate addresses
        if (_usdc == address(0) || _token == address(0)) revert InvalidAddress();
        if (_oversight == address(0)) revert InvalidAddress();
        
        // Validate all recipient addresses
        for (uint i = 0; i < 10; i++) {
            if (_recipients[i] == address(0)) revert InvalidAddress();
        }
        
        // Validate percentages sum to 100%
        uint256 totalPercentage = RESERVE_PERCENTAGE + OTC_PERCENTAGE + OPS_PERCENTAGE + 
                                 DONATION_PERCENTAGE + BITRUE_PERCENTAGE;
        if (totalPercentage != PERCENTAGE_BASE) revert InvalidPercentages();
        
        owner = msg.sender;
        oversight = _oversight;
        USDC = IERC20(_usdc);
        token = IERC20(_token);
        
        // Query token decimals dynamically
        tokenDecimals = 10 ** uint256(IERC20(_token).decimals());
        
        // Initialize last known balance to current balance
        lastKnownBalance = token.balanceOf(address(this));
        
        basePriceXDC = _basePriceXDC;
        slopeXDC = _slopeXDC;
        basePriceUSDC = _basePriceUSDC;
        slopeUSDC = _slopeUSDC;
        
        // Initialize recipients with failover addresses
        reserveVault = Recipient(_recipients[0], _recipients[1], false);
        otcBuybackContract = Recipient(_recipients[2], _recipients[3], false);
        opsWallet = Recipient(_recipients[4], _recipients[5], false);
        donationWallet = Recipient(_recipients[6], _recipients[7], false);
        bitrueBuybackContract = Recipient(_recipients[8], _recipients[9], false);
        
        if (_vipNFT != address(0)) vipNFT = IERC721(_vipNFT);
        if (_govNFT != address(0)) govNFT = IERC721(_govNFT);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrOversight() {
        if (msg.sender != owner && msg.sender != oversight) revert Unauthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert InvalidAddress();
        _;
    }

    /**
     * @notice Recalibrate inventory by checking current token balance
     * @dev This is called automatically before each purchase
     * @return newTokensDetected Amount of new tokens detected
     */
    function _recalibrateInventory() internal returns (uint256 newTokensDetected) {
        uint256 currentBalance = token.balanceOf(address(this));
        
        // Check if balance increased (new tokens received)
        if (currentBalance > lastKnownBalance) {
            newTokensDetected = currentBalance - lastKnownBalance;
            totalTokensReceived += newTokensDetected;
            
            // Note: We can't determine the sender in a standard transfer
            // but we can still track the contribution
            emit TokensDetected(address(0), newTokensDetected, totalTokensReceived);
        }
        
        // Update last known balance
        lastKnownBalance = currentBalance;
        
        return newTokensDetected;
    }
    
    /**
     * @notice Force inventory recalibration (can be called by anyone)
     * @dev Useful for updating inventory without making a purchase
     */
    function recalibrateInventory() external {
        uint256 newTokens = _recalibrateInventory();
        emit InventoryRecalibrated(newTokens, getAvailableInventory(), msg.sender);
    }
    
    /**
     * @notice Get current available inventory
     * @return Current token balance
     */
    function getAvailableInventory() public view returns (uint256) {
        return token.balanceOf(address(this));
    }
    
    /**
     * @notice Check if current balance differs from last known
     * @return hasNewTokens Whether new tokens have been received
     * @return amount Amount of new tokens
     */
    function checkForNewTokens() external view returns (bool hasNewTokens, uint256 amount) {
        uint256 currentBalance = token.balanceOf(address(this));
        if (currentBalance > lastKnownBalance) {
            return (true, currentBalance - lastKnownBalance);
        }
        return (false, 0);
    }
    
    /**
     * @notice Update minimum inventory threshold
     * @param newMinimum New minimum token threshold
     */
    function setMinimumInventory(uint256 newMinimum) external onlyOwner {
        uint256 oldMinimum = minimumInventory;
        minimumInventory = newMinimum;
        emit MinimumInventoryUpdated(oldMinimum, newMinimum);
    }
    
    /**
     * @notice Check if inventory is low
     * @return Whether inventory is below threshold
     */
    function isInventoryLow() public view returns (bool) {
        uint256 available = getAvailableInventory();
        uint256 threshold = totalTokensReceived > 0 ? 
            (totalTokensReceived * LOW_INVENTORY_THRESHOLD) / 100 : minimumInventory;
        return available < threshold || available < minimumInventory;
    }

    /**
     * @notice Commit to a purchase (MEV protection step 1)
     * @param commitment Hash of (address, amount, nonce)
     * @param amount Amount to be spent
     * @param isNative Whether paying with native token
     */
    function commitPurchase(
        bytes32 commitment,
        uint256 amount,
        bool isNative
    ) external notPaused {
        if (amount == 0) revert AmountZero();
        
        purchaseCommits[msg.sender] = PurchaseCommit({
            commitment: commitment,
            commitBlock: block.number,
            amount: amount,
            isNative: isNative
        });
        
        emit PurchaseCommitted(msg.sender, commitment);
    }

    /**
     * @notice Reveal and execute purchase (MEV protection step 2)
     * @param nonce Random nonce used in commitment
     * @param minTokensOut Minimum tokens expected
     */
    function revealPurchase(
        uint256 nonce,
        uint256 minTokensOut
    ) external payable notPaused nonReentrant {
        // First, recalibrate inventory
        _recalibrateInventory();
        
        PurchaseCommit memory commit = purchaseCommits[msg.sender];
        if (commit.commitment == bytes32(0)) revert NoCommitment();
        
        // Verify commitment timing
        if (block.number < commit.commitBlock + COMMIT_DURATION / 12) revert CommitmentTooEarly();
        if (block.number > commit.commitBlock + 1000) revert CommitmentExpired(); // ~4 hours
        
        // Verify commitment matches
        bytes32 expectedCommitment = keccak256(abi.encodePacked(msg.sender, commit.amount, nonce));
        if (commit.commitment != expectedCommitment) revert InvalidCommitment();
        
        // Clear commitment
        delete purchaseCommits[msg.sender];
        
        // Process purchase
        if (commit.isNative) {
            if (msg.value != commit.amount) revert AmountZero();
            _processPurchase(msg.sender, commit.amount, true, minTokensOut);
        } else {
            USDC.safeTransferFrom(msg.sender, address(this), commit.amount);
            _processPurchase(msg.sender, commit.amount, false, minTokensOut);
        }
    }

    /**
     * @notice Direct purchase without commit/reveal (accepts higher MEV risk)
     */
    function buyDirectXDC(uint256 minTokensOut) external payable notPaused nonReentrant {
        if (msg.value == 0) revert AmountZero();
        
        // Recalibrate inventory before purchase
        _recalibrateInventory();
        
        _processPurchase(msg.sender, msg.value, true, minTokensOut);
    }

    /**
     * @notice Direct USDC purchase without commit/reveal
     */
    function buyDirectUSDC(uint256 amount, uint256 minTokensOut) external notPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        
        // Recalibrate inventory before purchase
        _recalibrateInventory();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        _processPurchase(msg.sender, amount, false, minTokensOut);
    }

    /**
     * @notice Process token purchase with all validations
     */
    function _processPurchase(
        address buyer,
        uint256 paymentAmount,
        bool isNative,
        uint256 minTokensOut
    ) internal {
        // Calculate tokens with precision
        uint256 currentPrice = isNative ? getPriceInXDC() : getPriceInUSDC();
        uint256 tokensToTransfer = _calculateTokensWithPrecision(paymentAmount, currentPrice);
        
        // Slippage protection
        if (tokensToTransfer < minTokensOut) revert SlippageExceeded();
        
        // Check inventory (already recalibrated)
        uint256 available = getAvailableInventory();
        if (tokensToTransfer > available) revert InsufficientInventory();
        
        // Check rolling window cap
        uint256 rollingAmount = _getRollingWindowAmount(buyer) + tokensToTransfer;
        uint256 dailyCap = getDailyCap(buyer);
        if (rollingAmount > dailyCap) revert ExceedsDailyCap();
        
        // Update purchase history (circular buffer)
        _updatePurchaseHistory(buyer, tokensToTransfer);
        
        // Update state before external calls
        totalTokensSold += tokensToTransfer;
        lastKnownBalance -= tokensToTransfer; // Update tracking after transfer
        
        // Transfer tokens to buyer
        token.safeTransfer(buyer, tokensToTransfer);
        
        // Check for low inventory warning
        if (isInventoryLow()) {
            emit LowInventoryWarning(getAvailableInventory(), minimumInventory);
        }
        
        // Distribute funds
        _distributeFunds(paymentAmount, isNative);
        
        emit TokenPurchased(buyer, tokensToTransfer, currentPrice, isNative ? address(0) : address(USDC), paymentAmount);
    }

    /**
     * @notice Calculate tokens with high precision
     */
    function _calculateTokensWithPrecision(uint256 paymentAmount, uint256 price) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 scaledPayment = paymentAmount * PRECISION;
        uint256 scaledTokens = (scaledPayment * tokenDecimals) / price;
        return scaledTokens / PRECISION;
    }

    /**
     * @notice Get purchase amount in rolling 24-hour window
     */
    function _getRollingWindowAmount(address user) internal view returns (uint256) {
        UserPurchaseData storage data = userPurchaseData[user];
        uint256 windowStart = block.timestamp - ROLLING_WINDOW;
        uint256 total = 0;
        
        uint256 count = data.totalEntries < MAX_PURCHASE_HISTORY ? data.totalEntries : MAX_PURCHASE_HISTORY;
        
        for (uint256 i = 0; i < count; i++) {
            PurchaseWindow memory purchase = data.purchases[i];
            if (purchase.timestamp >= windowStart) {
                total += purchase.amount;
            }
        }
        
        return total;
    }

    /**
     * @notice Update purchase history using circular buffer
     */
    function _updatePurchaseHistory(address user, uint256 amount) internal {
        UserPurchaseData storage data = userPurchaseData[user];
        
        // Add new purchase at nextIndex
        data.purchases[data.nextIndex] = PurchaseWindow({
            amount: amount,
            timestamp: block.timestamp
        });
        
        // Update circular buffer indices
        data.nextIndex = (data.nextIndex + 1) % MAX_PURCHASE_HISTORY;
        if (data.totalEntries < MAX_PURCHASE_HISTORY) {
            data.totalEntries++;
        }
    }

    /**
     * @notice Distribute funds with failover mechanism
     */
    function _distributeFunds(uint256 amount, bool isNative) internal {
        uint256 reserve = (amount * RESERVE_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 otc = (amount * OTC_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 ops = (amount * OPS_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 donation = (amount * DONATION_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 bitrue = amount - reserve - otc - ops - donation;
        
        if (isNative) {
            _safeTransferETHWithFailover(reserveVault, reserve);
            _safeTransferETHWithFailover(otcBuybackContract, otc);
            _safeTransferETHWithFailover(opsWallet, ops);
            _safeTransferETHWithFailover(donationWallet, donation);
            _safeTransferETHWithFailover(bitrueBuybackContract, bitrue);
        } else {
            _safeTransferTokenWithFailover(reserveVault, reserve);
            _safeTransferTokenWithFailover(otcBuybackContract, otc);
            _safeTransferTokenWithFailover(opsWallet, ops);
            _safeTransferTokenWithFailover(donationWallet, donation);
            _safeTransferTokenWithFailover(bitrueBuybackContract, bitrue);
        }
    }

    /**
     * @notice Safe ETH transfer with failover
     */
    function _safeTransferETHWithFailover(Recipient storage recipient, uint256 amount) internal {
        address target = recipient.useFailover ? recipient.failover : recipient.primary;
        (bool success, ) = target.call{value: amount}("");
        
        // Try failover if primary fails and not already using failover
        if (!success && !recipient.useFailover && recipient.failover != address(0)) {
            (success, ) = recipient.failover.call{value: amount}("");
        }
        
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Safe token transfer with failover
     */
    function _safeTransferTokenWithFailover(Recipient storage recipient, uint256 amount) internal {
        address target = recipient.useFailover ? recipient.failover : recipient.primary;
        
        // Try primary address first
        (bool success, ) = address(USDC).call(
            abi.encodeWithSelector(IERC20.transfer.selector, target, amount)
        );
        
        // Check if the transfer succeeded by decoding the return value
        if (success) {
            assembly {
                switch returndatasize()
                case 0 {
                    // Some tokens don't return a value, assume success
                    success := 1
                }
                default {
                    // Tokens that do return a value
                    let returndata := mload(0x40)
                    returndatacopy(returndata, 0, 0x20)
                    success := mload(returndata)
                }
            }
        }
        
        // Try failover if primary fails and not already using failover
        if (!success && !recipient.useFailover && recipient.failover != address(0)) {
            (success, ) = address(USDC).call(
                abi.encodeWithSelector(IERC20.transfer.selector, recipient.failover, amount)
            );
            
            // Check return value again
            if (success) {
                assembly {
                    switch returndatasize()
                    case 0 {
                        success := 1
                    }
                    default {
                        let returndata := mload(0x40)
                        returndatacopy(returndata, 0, 0x20)
                        success := mload(returndata)
                    }
                }
            }
        }
        
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Toggle failover for a recipient
     */
    function toggleRecipientFailover(string memory recipientName) external onlyOwner {
        Recipient storage recipient;
        
        if (keccak256(bytes(recipientName)) == keccak256("reserve")) {
            recipient = reserveVault;
        } else if (keccak256(bytes(recipientName)) == keccak256("otc")) {
            recipient = otcBuybackContract;
        } else if (keccak256(bytes(recipientName)) == keccak256("ops")) {
            recipient = opsWallet;
        } else if (keccak256(bytes(recipientName)) == keccak256("donation")) {
            recipient = donationWallet;
        } else if (keccak256(bytes(recipientName)) == keccak256("bitrue")) {
            recipient = bitrueBuybackContract;
        } else {
            revert Unauthorized();
        }
        
        recipient.useFailover = !recipient.useFailover;
        emit RecipientFailoverToggled(recipientName, recipient.useFailover);
    }

    /**
     * @notice Pause all purchase operations
     */
    function pause() external onlyOwnerOrOversight {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause purchase operations
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Toggle receive function
     */
    function toggleReceive() external onlyOwner {
        receiveEnabled = !receiveEnabled;
        emit ReceiveToggled(receiveEnabled);
    }

    /**
     * @notice Transfer oversight role
     */
    function transferOversight(address newOversight) 
        external 
        onlyOwner 
        validAddress(newOversight) 
    {
        emit OversightTransferred(oversight, newOversight);
        oversight = newOversight;
    }

    /**
     * @notice Receive ETH and process purchase
     */
    receive() external payable {
        if (!receiveEnabled) revert ReceiveDisabled();
        if (msg.value == 0) revert AmountZero();
        
        // Recalibrate inventory before purchase
        _recalibrateInventory();
        
        _processPurchase(msg.sender, msg.value, true, 0);
    }

    /**
     * @notice Get daily purchase cap based on NFT holdings
     */
    function getDailyCap(address user) public view returns (uint256) {
        if (address(govNFT) != address(0) && govNFT.balanceOf(user) > 0) {
            return GOV_DAILY_CAP;
        }
        if (address(vipNFT) != address(0) && vipNFT.balanceOf(user) > 0) {
            return VIP_DAILY_CAP;
        }
        return DEFAULT_DAILY_CAP;
    }

    /**
     * @notice Get current price in XDC
     */
    function getPriceInXDC() public view returns (uint256) {
        return basePriceXDC + (slopeXDC * totalTokensSold / tokenDecimals);
    }

    /**
     * @notice Get current price in USDC
     */
    function getPriceInUSDC() public view returns (uint256) {
        return basePriceUSDC + (slopeUSDC * totalTokensSold / tokenDecimals);
    }

    /**
     * @notice Estimate tokens for given payment
     */
    function estimateTokensForPayment(uint256 amount, bool isNative) 
        public 
        view 
        returns (uint256) 
    {
        uint256 price = isNative ? getPriceInXDC() : getPriceInUSDC();
        return _calculateTokensWithPrecision(amount, price);
    }

    /**
     * @notice Get user's current rolling window purchase amount
     */
    function getUserRollingPurchases(address user) public view returns (uint256) {
        return _getRollingWindowAmount(user);
    }

    /**
     * @notice Get detailed inventory status
     */
    function getInventoryStatus() external view returns (
        uint256 totalReceived,
        uint256 totalSold,
        uint256 availableInventory,
        bool isLow,
        uint256 percentageRemaining,
        bool hasUndetectedTokens
    ) {
        totalReceived = totalTokensReceived;
        totalSold = totalTokensSold;
        availableInventory = getAvailableInventory();
        isLow = isInventoryLow();
        percentageRemaining = totalReceived > 0 ? (availableInventory * 100) / totalReceived : 0;
        hasUndetectedTokens = availableInventory > lastKnownBalance;
    }

    /**
     * @notice Queue recipient update with timelock
     */
    function queueUpdateRecipient(
        string memory recipientName,
        address newPrimary,
        address newFailover
    ) external onlyOwner {
        if (newPrimary == address(0) || newFailover == address(0)) revert InvalidAddress();
        
        bytes32 actionId = keccak256(abi.encodePacked(
            "updateRecipient",
            recipientName,
            newPrimary,
            newFailover,
            block.timestamp
        ));
        
        _queueAction(actionId, MINIMUM_DELAY);
        emit ConfigurationQueued(actionId, string(abi.encodePacked("updateRecipient-", recipientName)));
    }

    /**
     * @notice Execute recipient update after timelock
     */
    function executeUpdateRecipient(
        string memory recipientName,
        address newPrimary,
        address newFailover,
        uint256 queueTimestamp
    ) external onlyOwner timeLocked(
        keccak256(abi.encodePacked(
            "updateRecipient",
            recipientName,
            newPrimary,
            newFailover,
            queueTimestamp
        ))
    ) {
        Recipient storage recipient;
        if (keccak256(bytes(recipientName)) == keccak256("reserve")) {
            recipient = reserveVault;
        } else if (keccak256(bytes(recipientName)) == keccak256("otc")) {
            recipient = otcBuybackContract;
        } else if (keccak256(bytes(recipientName)) == keccak256("ops")) {
            recipient = opsWallet;
        } else if (keccak256(bytes(recipientName)) == keccak256("donation")) {
            recipient = donationWallet;
        } else if (keccak256(bytes(recipientName)) == keccak256("bitrue")) {
            recipient = bitrueBuybackContract;
        } else {
            revert Unauthorized();
        }
        
        recipient.primary = newPrimary;
        recipient.failover = newFailover;
        recipient.useFailover = false;
        
        emit RecipientUpdated(recipientName, newPrimary, newFailover);
    }

    /**
     * @notice Queue bonding curve update with timelock
     */
    function queueUpdateCurve(
        uint256 _baseXDC,
        uint256 _slopeXDC,
        uint256 _baseUSDC,
        uint256 _slopeUSDC
    ) external onlyOwner {
        bytes32 actionId = keccak256(abi.encodePacked(
            "updateCurve",
            _baseXDC,
            _slopeXDC,
            _baseUSDC,
            _slopeUSDC,
            block.timestamp
        ));
        
        _queueAction(actionId, MINIMUM_DELAY);
        emit ConfigurationQueued(actionId, "updateCurve");
    }

    /**
     * @notice Execute bonding curve update after timelock
     */
    function executeUpdateCurve(
        uint256 _baseXDC,
        uint256 _slopeXDC,
        uint256 _baseUSDC,
        uint256 _slopeUSDC,
        uint256 queueTimestamp
    ) external onlyOwner timeLocked(
        keccak256(abi.encodePacked(
            "updateCurve",
            _baseXDC,
            _slopeXDC,
            _baseUSDC,
            _slopeUSDC,
            queueTimestamp
        ))
    ) {
        basePriceXDC = _baseXDC;
        slopeXDC = _slopeXDC;
        basePriceUSDC = _baseUSDC;
        slopeUSDC = _slopeUSDC;
        
        emit CurveParametersUpdated(_baseXDC, _slopeXDC, _baseUSDC, _slopeUSDC);
    }

    /**
     * @notice Update NFT contracts
     */
    function updateNFTContracts(address _vipNFT, address _govNFT) external onlyOwner {
        vipNFT = _vipNFT != address(0) ? IERC721(_vipNFT) : IERC721(address(0));
        govNFT = _govNFT != address(0) ? IERC721(_govNFT) : IERC721(address(0));
        
        emit NFTContractsUpdated(_vipNFT, _govNFT);
    }

    /**
     * @notice Cancel a queued action
     */
    function cancelAction(bytes32 actionId) external onlyOwner {
        _cancelAction(actionId);
    }

    /**
     * @notice Emergency function to withdraw unsold tokens
     * @param amount Amount to withdraw (0 for all)
     */
    function emergencyWithdrawTokens(uint256 amount) external onlyOwner {
        // First recalibrate to ensure accurate accounting
        _recalibrateInventory();
        
        uint256 withdrawAmount = amount == 0 ? getAvailableInventory() : amount;
        if (withdrawAmount > getAvailableInventory()) revert InsufficientInventory();
        
        // Update tracking
        lastKnownBalance -= withdrawAmount;
        
        token.safeTransfer(owner, withdrawAmount);
        emit EmergencyTokenWithdraw(address(token), withdrawAmount, owner);
    }

    /**
     * @notice Emergency function to recover accidentally sent tokens
     */
    function emergencyTokenRecovery(address tokenAddress, uint256 amount) 
        external 
        onlyOwner 
    {
        if (tokenAddress == address(USDC) || tokenAddress == address(token)) revert Unauthorized();
        IERC20(tokenAddress).safeTransfer(owner, amount);
        emit EmergencyTokenWithdraw(tokenAddress, amount, owner);
    }

    /**
     * @notice Get user's purchase history count
     */
    function getUserPurchaseCount(address user) external view returns (uint256) {
        return userPurchaseData[user].totalEntries;
    }

    /**
     * @notice Check if address is using failover
     */
    function isUsingFailover(string memory recipientName) external view returns (bool) {
        if (keccak256(bytes(recipientName)) == keccak256("reserve")) {
            return reserveVault.useFailover;
        } else if (keccak256(bytes(recipientName)) == keccak256("otc")) {
            return otcBuybackContract.useFailover;
        } else if (keccak256(bytes(recipientName)) == keccak256("ops")) {
            return opsWallet.useFailover;
        } else if (keccak256(bytes(recipientName)) == keccak256("donation")) {
            return donationWallet.useFailover;
        } else if (keccak256(bytes(recipientName)) == keccak256("bitrue")) {
            return bitrueBuybackContract.useFailover;
        }
        return false;
    }

    /**
     * @notice Get the execute time for a queued action
     */
    function getActionExecuteTime(bytes32 actionId) external view returns (uint256) {
        return pendingActions[actionId];
    }

    /**
     * @notice Calculate actionId for recipient update
     */
    function calculateRecipientUpdateActionId(
        string memory recipientName,
        address newPrimary,
        address newFailover,
        uint256 timestamp
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "updateRecipient",
            recipientName,
            newPrimary,
            newFailover,
            timestamp
        ));
    }

    /**
     * @notice Calculate actionId for curve update
     */
    function calculateCurveUpdateActionId(
        uint256 _baseXDC,
        uint256 _slopeXDC,
        uint256 _baseUSDC,
        uint256 _slopeUSDC,
        uint256 timestamp
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "updateCurve",
            _baseXDC,
            _slopeXDC,
            _baseUSDC,
            _slopeUSDC,
            timestamp
        ));
    }
}
