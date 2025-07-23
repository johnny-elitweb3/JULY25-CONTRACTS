// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ReserveVault
 * @author OIL Protocol
 * @notice Secure multi-token vault for managing OIL and CBG reserves
 * @dev Production-grade contract with comprehensive security features and gas optimizations
 */
contract ReserveVault is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== Constants ====================
    
    uint256 public constant EMERGENCY_DELAY = 3 days;
    uint256 public constant MAX_RESERVE_RATIO = 9500; // 95% max can be reserved
    uint256 public constant RATIO_BASE = 10000;
    
    // ==================== State Variables ====================
    
    // Token addresses
    IERC20 public immutable oilToken;
    IERC20 public immutable cbgToken;
    
    // Access control
    address public tradeDeskContract;
    mapping(address => bool) public authorizedOperators;
    
    // Reserve tracking per token
    mapping(address => uint256) public totalDeposited;
    mapping(address => uint256) public totalReserved;
    mapping(address => uint256) public totalReleased;
    
    // Emergency withdrawal state
    struct EmergencyRequest {
        address token;
        address recipient;
        uint256 amount;
        uint256 requestTime;
        bool executed;
    }
    
    mapping(uint256 => EmergencyRequest) public emergencyRequests;
    uint256 public emergencyRequestCount;
    
    // Security features
    uint256 public lastOperationTime;
    mapping(address => uint256) public lastUserInteraction;
    
    // ==================== Events ====================
    
    event TokensDeposited(
        address indexed token,
        address indexed depositor,
        uint256 amount,
        uint256 newTotal
    );
    
    event TokensReserved(
        address indexed token,
        uint256 amount,
        uint256 newReserved
    );
    
    event TokensReleased(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        string reason
    );
    
    event TradeDeskUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );
    
    event OperatorUpdated(
        address indexed operator,
        bool authorized
    );
    
    event EmergencyWithdrawalRequested(
        uint256 indexed requestId,
        address indexed token,
        address recipient,
        uint256 amount
    );
    
    event EmergencyWithdrawalExecuted(
        uint256 indexed requestId,
        address indexed token,
        address recipient,
        uint256 amount
    );
    
    event EmergencyWithdrawalCancelled(uint256 indexed requestId);
    
    // ==================== Errors ====================
    
    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedCaller();
    error InvalidToken();
    error InsufficientReserves();
    error ReserveRatioExceeded();
    error EmergencyDelayNotMet();
    error InvalidRequestId();
    error RequestAlreadyExecuted();
    error TokenMismatch();
    error TransferFailed();
    error ContractPaused();
    
    // ==================== Modifiers ====================
    
    modifier onlyTradeDesk() {
        if (msg.sender != tradeDeskContract) revert UnauthorizedCaller();
        _;
    }
    
    modifier onlyAuthorized() {
        if (msg.sender != tradeDeskContract && 
            !authorizedOperators[msg.sender] && 
            msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    modifier validToken(address token) {
        if (token != address(oilToken) && token != address(cbgToken)) {
            revert InvalidToken();
        }
        _;
    }
    
    modifier notZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }
    
    modifier updateInteraction() {
        lastOperationTime = block.timestamp;
        lastUserInteraction[msg.sender] = block.timestamp;
        _;
    }
    
    // ==================== Constructor ====================
    
    /**
     * @notice Initialize the ReserveVault with token addresses
     * @param _oilToken Address of the OIL token
     * @param _cbgToken Address of the CBG token
     * @param _initialOwner Address of the initial owner
     */
    constructor(
        address _oilToken,
        address _cbgToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        if (_oilToken == address(0) || _cbgToken == address(0) || _initialOwner == address(0)) {
            revert ZeroAddress();
        }
        
        oilToken = IERC20(_oilToken);
        cbgToken = IERC20(_cbgToken);
        
        lastOperationTime = block.timestamp;
    }
    
    // ==================== Admin Functions ====================
    
    /**
     * @notice Set the TradeDesk contract address
     * @param _tradeDeskContract New TradeDesk contract address
     */
    function setTradeDeskContract(address _tradeDeskContract) 
        external 
        onlyOwner 
        updateInteraction 
    {
        if (_tradeDeskContract == address(0)) revert ZeroAddress();
        
        address oldAddress = tradeDeskContract;
        tradeDeskContract = _tradeDeskContract;
        
        emit TradeDeskUpdated(oldAddress, _tradeDeskContract);
    }
    
    /**
     * @notice Add or remove authorized operators
     * @param operator Address to update authorization for
     * @param authorized Whether the operator should be authorized
     */
    function setOperator(address operator, bool authorized) 
        external 
        onlyOwner 
        updateInteraction 
    {
        if (operator == address(0)) revert ZeroAddress();
        
        authorizedOperators[operator] = authorized;
        emit OperatorUpdated(operator, authorized);
    }
    
    /**
     * @notice Pause vault operations
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause vault operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Request emergency withdrawal (time-locked)
     * @param token Token to withdraw (OIL or CBG)
     * @param recipient Address to receive tokens
     * @param amount Amount to withdraw
     * @return requestId The ID of the emergency request
     */
    function requestEmergencyWithdrawal(
        address token,
        address recipient,
        uint256 amount
    ) 
        external 
        onlyOwner 
        validToken(token)
        notZeroAmount(amount)
        updateInteraction
        returns (uint256 requestId) 
    {
        if (recipient == address(0)) revert ZeroAddress();
        
        requestId = emergencyRequestCount++;
        
        emergencyRequests[requestId] = EmergencyRequest({
            token: token,
            recipient: recipient,
            amount: amount,
            requestTime: block.timestamp,
            executed: false
        });
        
        emit EmergencyWithdrawalRequested(requestId, token, recipient, amount);
    }
    
    /**
     * @notice Execute emergency withdrawal after delay
     * @param requestId The ID of the emergency request to execute
     */
    function executeEmergencyWithdrawal(uint256 requestId) 
        external 
        onlyOwner 
        nonReentrant
        updateInteraction 
    {
        EmergencyRequest storage request = emergencyRequests[requestId];
        
        if (request.requestTime == 0) revert InvalidRequestId();
        if (request.executed) revert RequestAlreadyExecuted();
        if (block.timestamp < request.requestTime + EMERGENCY_DELAY) {
            revert EmergencyDelayNotMet();
        }
        
        request.executed = true;
        
        // Reduce total deposited amount
        totalDeposited[request.token] -= request.amount;
        
        // Transfer tokens
        IERC20(request.token).safeTransfer(request.recipient, request.amount);
        
        emit EmergencyWithdrawalExecuted(
            requestId,
            request.token,
            request.recipient,
            request.amount
        );
    }
    
    /**
     * @notice Cancel emergency withdrawal request
     * @param requestId The ID of the emergency request to cancel
     */
    function cancelEmergencyWithdrawal(uint256 requestId) 
        external 
        onlyOwner
        updateInteraction 
    {
        EmergencyRequest storage request = emergencyRequests[requestId];
        
        if (request.requestTime == 0) revert InvalidRequestId();
        if (request.executed) revert RequestAlreadyExecuted();
        
        delete emergencyRequests[requestId];
        
        emit EmergencyWithdrawalCancelled(requestId);
    }
    
    // ==================== Deposit Functions ====================
    
    /**
     * @notice Deposit tokens into the vault
     * @param token Token to deposit (OIL or CBG)
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) 
        external 
        validToken(token)
        notZeroAmount(amount)
        whenNotPaused
        nonReentrant
        updateInteraction 
    {
        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update accounting
        totalDeposited[token] += amount;
        
        emit TokensDeposited(token, msg.sender, amount, totalDeposited[token]);
    }
    
    /**
     * @notice Batch deposit multiple tokens
     * @param tokens Array of token addresses
     * @param amounts Array of amounts to deposit
     */
    function batchDeposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) 
        external 
        whenNotPaused
        nonReentrant
        updateInteraction 
    {
        if (tokens.length != amounts.length) revert TokenMismatch();
        
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(oilToken) && tokens[i] != address(cbgToken)) {
                revert InvalidToken();
            }
            if (amounts[i] == 0) revert ZeroAmount();
            
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            totalDeposited[tokens[i]] += amounts[i];
            
            emit TokensDeposited(tokens[i], msg.sender, amounts[i], totalDeposited[tokens[i]]);
        }
    }
    
    // ==================== TradeDesk Functions ====================
    
    /**
     * @notice Reserve tokens for an offer (only callable by TradeDesk)
     * @param amount Amount of OIL to reserve
     * @dev Assumes TradeDesk only deals with OIL for offers
     */
    function reserveOil(uint256 amount) 
        external 
        onlyTradeDesk
        notZeroAmount(amount)
        whenNotPaused
        updateInteraction 
    {
        address token = address(oilToken);
        
        // Check if reservation would exceed maximum allowed ratio
        uint256 newReserved = totalReserved[token] + amount;
        uint256 maxReservable = (totalDeposited[token] * MAX_RESERVE_RATIO) / RATIO_BASE;
        
        if (newReserved > maxReservable) {
            revert ReserveRatioExceeded();
        }
        
        // Check if sufficient unreserved balance exists
        uint256 available = getAvailableReserves();
        if (amount > available) {
            revert InsufficientReserves();
        }
        
        totalReserved[token] += amount;
        
        emit TokensReserved(token, amount, totalReserved[token]);
    }
    
    /**
     * @notice Release tokens to a user (only callable by TradeDesk)
     * @param to Recipient address
     * @param amount Amount to release
     * @dev Assumes TradeDesk only releases OIL for redemptions
     */
    function releaseOil(address to, uint256 amount) 
        external 
        onlyTradeDesk
        notZeroAmount(amount)
        whenNotPaused
        nonReentrant
        updateInteraction 
    {
        if (to == address(0)) revert ZeroAddress();
        
        address token = address(oilToken);
        
        // Update accounting
        totalReserved[token] -= amount;
        totalReleased[token] += amount;
        totalDeposited[token] -= amount;
        
        // Transfer tokens
        oilToken.safeTransfer(to, amount);
        
        emit TokensReleased(token, to, amount, "Certificate Redemption");
    }
    
    /**
     * @notice Release specific token to a user (for future multi-token support)
     * @param token Token to release (OIL or CBG)
     * @param to Recipient address
     * @param amount Amount to release
     * @param reason Reason for release
     */
    function releaseToken(
        address token,
        address to,
        uint256 amount,
        string calldata reason
    ) 
        external 
        onlyAuthorized
        validToken(token)
        notZeroAmount(amount)
        whenNotPaused
        nonReentrant
        updateInteraction 
    {
        if (to == address(0)) revert ZeroAddress();
        
        // For reserved tokens, check authorization
        if (msg.sender == tradeDeskContract) {
            // TradeDesk can release from reserved
            if (amount > totalReserved[token]) {
                revert InsufficientReserves();
            }
            totalReserved[token] -= amount;
        } else {
            // Other authorized can only release unreserved
            uint256 available = totalDeposited[token] - totalReserved[token] - totalReleased[token];
            if (amount > available) {
                revert InsufficientReserves();
            }
        }
        
        totalReleased[token] += amount;
        totalDeposited[token] -= amount;
        
        // Transfer tokens
        IERC20(token).safeTransfer(to, amount);
        
        emit TokensReleased(token, to, amount, reason);
    }
    
    // ==================== View Functions ====================
    
    /**
     * @notice Get available OIL reserves (not reserved)
     * @return Available OIL balance
     */
    function getAvailableReserves() public view returns (uint256) {
        address token = address(oilToken);
        return totalDeposited[token] - totalReserved[token] - totalReleased[token];
    }
    
    /**
     * @notice Get available reserves for a specific token
     * @param token Token to check (OIL or CBG)
     * @return Available balance
     */
    function getAvailableReservesForToken(address token) 
        public 
        view 
        validToken(token) 
        returns (uint256) 
    {
        return totalDeposited[token] - totalReserved[token] - totalReleased[token];
    }
    
    /**
     * @notice Get complete reserve statistics for a token
     * @param token Token to check (OIL or CBG)
     * @return deposited Total deposited amount
     * @return reserved Total reserved amount
     * @return released Total released amount
     * @return available Available for reservation
     */
    function getReserveStats(address token) 
        external 
        view 
        validToken(token)
        returns (
            uint256 deposited,
            uint256 reserved,
            uint256 released,
            uint256 available
        ) 
    {
        deposited = totalDeposited[token];
        reserved = totalReserved[token];
        released = totalReleased[token];
        available = deposited - reserved - released;
    }
    
    /**
     * @notice Get vault's actual token balance
     * @param token Token to check (OIL or CBG)
     * @return Actual balance held by vault
     */
    function getVaultBalance(address token) 
        external 
        view 
        validToken(token)
        returns (uint256) 
    {
        return IERC20(token).balanceOf(address(this));
    }
    
    /**
     * @notice Check if reserves are healthy (actual >= expected)
     * @param token Token to check (OIL or CBG)
     * @return healthy Whether reserves match expected amount
     * @return deficit Any deficit amount (0 if healthy)
     */
    function checkReserveHealth(address token) 
        external 
        view 
        validToken(token)
        returns (bool healthy, uint256 deficit) 
    {
        uint256 expectedBalance = totalDeposited[token] - totalReleased[token];
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        
        if (actualBalance >= expectedBalance) {
            return (true, 0);
        } else {
            return (false, expectedBalance - actualBalance);
        }
    }
    
    /**
     * @notice Get emergency request details
     * @param requestId The ID of the emergency request
     * @return Request details
     */
    function getEmergencyRequest(uint256 requestId) 
        external 
        view 
        returns (EmergencyRequest memory) 
    {
        return emergencyRequests[requestId];
    }
    
    /**
     * @notice Get time remaining until emergency withdrawal can be executed
     * @param requestId The ID of the emergency request
     * @return timeRemaining Time remaining in seconds (0 if can be executed)
     */
    function getEmergencyWithdrawalDelay(uint256 requestId) 
        external 
        view 
        returns (uint256 timeRemaining) 
    {
        EmergencyRequest memory request = emergencyRequests[requestId];
        if (request.requestTime == 0 || request.executed) {
            return 0;
        }
        
        uint256 unlockTime = request.requestTime + EMERGENCY_DELAY;
        if (block.timestamp >= unlockTime) {
            return 0;
        }
        
        return unlockTime - block.timestamp;
    }
    
    // ==================== Recovery Functions ====================
    
    /**
     * @notice Recover accidentally sent tokens (not OIL or CBG)
     * @param token Token to recover
     * @param amount Amount to recover
     * @dev Only for tokens that are not OIL or CBG
     */
    function recoverToken(address token, uint256 amount) 
        external 
        onlyOwner
        nonReentrant 
    {
        if (token == address(oilToken) || token == address(cbgToken)) {
            revert InvalidToken();
        }
        
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    /**
     * @notice Sync accounting with actual balance (emergency use only)
     * @param token Token to sync (OIL or CBG)
     * @dev Only increases totalDeposited if actual balance is higher
     */
    function syncReserves(address token) 
        external 
        onlyOwner
        validToken(token)
        updateInteraction 
    {
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 expectedBalance = totalDeposited[token] - totalReleased[token];
        
        if (actualBalance > expectedBalance) {
            uint256 surplus = actualBalance - expectedBalance;
            totalDeposited[token] += surplus;
            
            emit TokensDeposited(token, address(this), surplus, totalDeposited[token]);
        }
    }
}
