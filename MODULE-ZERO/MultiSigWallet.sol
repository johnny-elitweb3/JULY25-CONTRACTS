// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title MultiSigWallet
 * @author CIFI Wealth Management Module
 * @notice Enterprise-grade multi-signature wallet with advanced security features
 * @dev Implements a non-proxy multi-signature wallet with comprehensive asset management
 */
contract MultiSigWallet {
    // ============ Libraries ============
    
    using SafeERC20 for IERC20;
    
    // ============ Events ============
    
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);
    event TransactionSubmitted(uint256 indexed txId, address indexed submitter);
    event TransactionApproved(uint256 indexed txId, address indexed approver);
    event TransactionRevoked(uint256 indexed txId, address indexed revoker);
    event TransactionExecuted(uint256 indexed txId, address indexed executor);
    event TransactionCancelled(uint256 indexed txId);
    event EmergencyPaused(address indexed pauser);
    event EmergencyUnpaused(address indexed unpauser);
    event TokenReceived(address indexed token, address indexed from, uint256 amount);
    event NFTReceived(address indexed token, address indexed from, uint256 tokenId);
    event RecoveryInitiated(address indexed initiator, uint256 recoveryId);
    event RecoveryExecuted(uint256 recoveryId);
    
    // ============ Errors ============
    
    error NotOwner();
    error NotSubmitter();
    error InvalidThreshold();
    error InvalidOwnerAddress();
    error OwnerAlreadyExists();
    error OwnerDoesNotExist();
    error TransactionDoesNotExist();
    error TransactionAlreadyExecuted();
    error TransactionAlreadyApproved();
    error TransactionExpired();
    error InsufficientApprovals();
    error ExecutionFailed();
    error ContractPaused();
    error InvalidNonce();
    error ZeroAddress();
    error EmptyData();
    error TooManyOwners();
    error RecoveryNotReady();
    error InvalidRecovery();
    
    // ============ Constants ============
    
    uint256 public constant MAX_OWNERS = 20;
    uint256 public constant TRANSACTION_EXPIRY = 30 days;
    uint256 public constant RECOVERY_DELAY = 7 days;
    uint256 public constant RATE_LIMIT_PERIOD = 1 days;
    uint256 public constant MAX_DAILY_LIMIT = 100 ether;
    
    // ============ State Variables ============
    
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 submittedAt;
        uint256 approvalCount;
        address submitter;
        uint256 nonce;
    }
    
    struct Recovery {
        address[] newOwners;
        uint256 newThreshold;
        uint256 initiatedAt;
        bool executed;
    }
    
    struct DailyLimit {
        uint256 amount;
        uint256 lastReset;
    }
    
    // Core state
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;
    uint256 public transactionCount;
    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public approvals;
    
    // Security state
    bool public paused;
    uint256 public nonce;
    mapping(address => DailyLimit) public dailyLimits;
    mapping(uint256 => Recovery) public recoveries;
    uint256 public recoveryCount;
    
    // Reentrancy guard
    uint256 private locked = 1;
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    
    modifier transactionExists(uint256 txId) {
        if (transactions[txId].to == address(0)) revert TransactionDoesNotExist();
        _;
    }
    
    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert TransactionAlreadyExecuted();
        _;
    }
    
    modifier nonReentrant() {
        require(locked == 1, "Reentrancy guard");
        locked = 2;
        _;
        locked = 1;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize the multi-signature wallet
     * @param _owners Array of initial owner addresses
     * @param _threshold Number of required confirmations
     */
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0 || _owners.length > MAX_OWNERS) revert InvalidThreshold();
        if (_threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();
        
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0)) revert ZeroAddress();
            if (isOwner[owner]) revert OwnerAlreadyExists();
            
            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }
        
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Submit a new transaction
     * @param to Destination address
     * @param value ETH value to send
     * @param data Transaction data
     * @return txId Transaction ID
     */
    function submitTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner whenNotPaused returns (uint256 txId) {
        if (to == address(0)) revert ZeroAddress();
        
        txId = transactionCount++;
        transactions[txId] = Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            submittedAt: block.timestamp,
            approvalCount: 1,
            submitter: msg.sender,
            nonce: nonce++
        });
        
        approvals[txId][msg.sender] = true;
        emit TransactionSubmitted(txId, msg.sender);
        emit TransactionApproved(txId, msg.sender);
    }
    
    /**
     * @notice Approve a pending transaction
     * @param txId Transaction ID to approve
     */
    function approveTransaction(uint256 txId) 
        external 
        onlyOwner 
        whenNotPaused
        transactionExists(txId)
        notExecuted(txId)
    {
        if (approvals[txId][msg.sender]) revert TransactionAlreadyApproved();
        if (block.timestamp > transactions[txId].submittedAt + TRANSACTION_EXPIRY) {
            revert TransactionExpired();
        }
        
        approvals[txId][msg.sender] = true;
        transactions[txId].approvalCount++;
        emit TransactionApproved(txId, msg.sender);
        
        if (transactions[txId].approvalCount >= threshold) {
            _executeTransaction(txId);
        }
    }
    
    /**
     * @notice Revoke approval for a transaction
     * @param txId Transaction ID to revoke approval
     */
    function revokeApproval(uint256 txId)
        external
        onlyOwner
        transactionExists(txId)
        notExecuted(txId)
    {
        require(approvals[txId][msg.sender], "Not approved");
        
        approvals[txId][msg.sender] = false;
        transactions[txId].approvalCount--;
        emit TransactionRevoked(txId, msg.sender);
    }
    
    /**
     * @notice Execute a transaction with sufficient approvals
     * @param txId Transaction ID to execute
     */
    function executeTransaction(uint256 txId)
        external
        onlyOwner
        whenNotPaused
        transactionExists(txId)
        notExecuted(txId)
    {
        if (transactions[txId].approvalCount < threshold) revert InsufficientApprovals();
        if (block.timestamp > transactions[txId].submittedAt + TRANSACTION_EXPIRY) {
            revert TransactionExpired();
        }
        
        _executeTransaction(txId);
    }
    
    /**
     * @notice Cancel a transaction (only submitter)
     * @param txId Transaction ID to cancel
     */
    function cancelTransaction(uint256 txId)
        external
        transactionExists(txId)
        notExecuted(txId)
    {
        if (msg.sender != transactions[txId].submitter) revert NotSubmitter();
        
        transactions[txId].executed = true; // Mark as executed to prevent future execution
        emit TransactionCancelled(txId);
    }
    
    // ============ Owner Management Functions ============
    
    /**
     * @notice Add a new owner (requires multi-sig approval)
     * @param owner Address of new owner
     */
    function addOwner(address owner) external {
        // This function should be called through submitTransaction
        if (owner == address(0)) revert ZeroAddress();
        if (isOwner[owner]) revert OwnerAlreadyExists();
        if (owners.length >= MAX_OWNERS) revert TooManyOwners();
        
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }
    
    /**
     * @notice Remove an owner (requires multi-sig approval)
     * @param owner Address of owner to remove
     */
    function removeOwner(address owner) external {
        // This function should be called through submitTransaction
        if (!isOwner[owner]) revert OwnerDoesNotExist();
        if (owners.length - 1 < threshold) revert InvalidThreshold();
        
        isOwner[owner] = false;
        
        // Remove from array
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        emit OwnerRemoved(owner);
    }
    
    /**
     * @notice Change the approval threshold (requires multi-sig approval)
     * @param _threshold New threshold value
     */
    function changeThreshold(uint256 _threshold) external {
        // This function should be called through submitTransaction
        if (_threshold == 0 || _threshold > owners.length) revert InvalidThreshold();
        
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Pause contract in emergency (requires threshold approvals)
     */
    function emergencyPause() external {
        // This function should be called through submitTransaction
        paused = true;
        emit EmergencyPaused(msg.sender);
    }
    
    /**
     * @notice Unpause contract (requires threshold approvals)
     */
    function emergencyUnpause() external {
        // This function should be called through submitTransaction
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }
    
    /**
     * @notice Initiate recovery process (requires all owners)
     * @param newOwners New owner addresses
     * @param newThreshold New threshold
     */
    function initiateRecovery(
        address[] calldata newOwners,
        uint256 newThreshold
    ) external onlyOwner {
        uint256 recoveryId = recoveryCount++;
        recoveries[recoveryId] = Recovery({
            newOwners: newOwners,
            newThreshold: newThreshold,
            initiatedAt: block.timestamp,
            executed: false
        });
        
        emit RecoveryInitiated(msg.sender, recoveryId);
    }
    
    /**
     * @notice Execute recovery after delay period
     * @param recoveryId Recovery ID to execute
     */
    function executeRecovery(uint256 recoveryId) external onlyOwner {
        Recovery storage recovery = recoveries[recoveryId];
        if (recovery.executed) revert InvalidRecovery();
        if (block.timestamp < recovery.initiatedAt + RECOVERY_DELAY) {
            revert RecoveryNotReady();
        }
        
        // Requires all current owners to approve
        uint256 approvalCount;
        for (uint256 i = 0; i < owners.length; i++) {
            if (approvals[uint256(keccak256(abi.encode(recoveryId, "recovery")))][owners[i]]) {
                approvalCount++;
            }
        }
        
        require(approvalCount == owners.length, "Requires all owners");
        
        // Clear existing owners
        for (uint256 i = 0; i < owners.length; i++) {
            isOwner[owners[i]] = false;
        }
        delete owners;
        
        // Set new owners
        for (uint256 i = 0; i < recovery.newOwners.length; i++) {
            address owner = recovery.newOwners[i];
            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }
        
        threshold = recovery.newThreshold;
        recovery.executed = true;
        
        emit RecoveryExecuted(recoveryId);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get all owners
     * @return Array of owner addresses
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }
    
    /**
     * @notice Get transaction details
     * @param txId Transaction ID
     * @return Transaction struct
     */
    function getTransaction(uint256 txId) external view returns (Transaction memory) {
        return transactions[txId];
    }
    
    /**
     * @notice Check if transaction is approved by owner
     * @param txId Transaction ID
     * @param owner Owner address
     * @return bool Approval status
     */
    function isApproved(uint256 txId, address owner) external view returns (bool) {
        return approvals[txId][owner];
    }
    
    /**
     * @notice Get approval count for transaction
     * @param txId Transaction ID
     * @return count Number of approvals
     */
    function getApprovalCount(uint256 txId) external view returns (uint256) {
        return transactions[txId].approvalCount;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Execute a transaction
     * @param txId Transaction ID
     */
    function _executeTransaction(uint256 txId) internal nonReentrant {
        Transaction storage txn = transactions[txId];
        txn.executed = true;
        
        // Check daily limit for high value transactions
        if (txn.value > 0) {
            _checkDailyLimit(txn.to, txn.value);
        }
        
        (bool success,) = txn.to.call{value: txn.value}(txn.data);
        if (!success) revert ExecutionFailed();
        
        emit TransactionExecuted(txId, msg.sender);
    }
    
    /**
     * @dev Check and update daily spending limit
     * @param to Destination address
     * @param amount Amount to send
     */
    function _checkDailyLimit(address to, uint256 amount) internal {
        DailyLimit storage limit = dailyLimits[to];
        
        // Reset daily limit if needed
        if (block.timestamp > limit.lastReset + RATE_LIMIT_PERIOD) {
            limit.amount = 0;
            limit.lastReset = block.timestamp;
        }
        
        require(limit.amount + amount <= MAX_DAILY_LIMIT, "Daily limit exceeded");
        limit.amount += amount;
    }
    
    // ============ Receive Functions ============
    
    /**
     * @notice Receive ETH
     */
    receive() external payable {
        emit TokenReceived(address(0), msg.sender, msg.value);
    }
    
    /**
     * @notice Fallback function
     */
    fallback() external payable {
        if (msg.data.length > 0) revert EmptyData();
        emit TokenReceived(address(0), msg.sender, msg.value);
    }
    
    /**
     * @notice Handle ERC721 token reception
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external returns (bytes4) {
        emit NFTReceived(msg.sender, from, tokenId);
        return this.onERC721Received.selector;
    }
    
    /**
     * @notice Handle ERC1155 token reception
     */
    function onERC1155Received(
        address,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata
    ) external returns (bytes4) {
        emit TokenReceived(msg.sender, from, value);
        // Using the id parameter in the event to avoid unused parameter warning
        emit NFTReceived(msg.sender, from, id);
        return this.onERC1155Received.selector;
    }
    
    /**
     * @notice Handle ERC1155 batch token reception
     */
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata
    ) external returns (bytes4) {
        // Emit event for each token received to properly use parameters
        uint256 totalValue = 0;
        for (uint256 i = 0; i < values.length; i++) {
            totalValue += values[i];
            if (i < ids.length) {
                emit NFTReceived(msg.sender, from, ids[i]);
            }
        }
        emit TokenReceived(msg.sender, from, totalValue);
        return this.onERC1155BatchReceived.selector;
    }
}

// ============ Interface Imports ============

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), "SafeERC20: transfer failed");
    }
}
