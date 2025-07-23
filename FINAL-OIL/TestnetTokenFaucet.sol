// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ITestnetFaucet
 * @notice Interface for testnet faucet implementations
 * @dev Standard interface to ensure compatibility across different faucet implementations
 */
interface ITestnetFaucet {
    function requestTokens() external returns (uint256 amount);
    function requestTokensFor(address recipient) external returns (uint256 amount);
    function canClaim(address user) external view returns (bool);
    function timeUntilNextClaim(address user) external view returns (uint256);
    function getUserInfo(address user) external view returns (
        uint256 totalClaimed,
        uint256 claimCount,
        uint256 lastClaimTime,
        bool canClaimNow
    );
}

/**
 * @title TestnetTokenFaucet
 * @notice Advanced faucet contract for testnet token distribution
 * @dev Designed to be a centerpiece for testnet ecosystems with extensive features:
 *      - Configurable claim amounts and cooldowns
 *      - Role-based access control
 *      - Emergency pause functionality
 *      - Comprehensive statistics tracking
 *      - Batch operations support
 *      - Integration-friendly design
 * 
 * @custom:security-contact security@your-project.com
 */
contract TestnetTokenFaucet is 
    ITestnetFaucet, 
    AccessControl, 
    Pausable, 
    ReentrancyGuard
{
    // ========== ROLES ==========
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");

    // ========== STATE VARIABLES ==========
    IERC20 public immutable token;
    
    // Configurable parameters
    uint256 public claimAmount;
    uint256 public cooldownPeriod;
    uint256 public maxClaimAmount;
    uint256 public minFaucetBalance;
    
    // User tracking
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public totalClaimed;
    mapping(address => uint256) public claimCount;
    
    // Global statistics
    uint256 public totalDistributed;
    uint256 public totalClaimCount;
    uint256 public uniqueUsers;
    
    // Batch claim limits
    uint256 public constant MAX_BATCH_SIZE = 100;
    
    // ========== EVENTS ==========
    event TokensClaimed(
        address indexed user, 
        address indexed recipient, 
        uint256 amount, 
        uint256 timestamp
    );
    event ConfigurationUpdated(
        uint256 claimAmount, 
        uint256 cooldownPeriod, 
        uint256 maxClaimAmount,
        uint256 minFaucetBalance
    );
    event TokensDeposited(address indexed from, uint256 amount);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event BatchClaim(address indexed initiator, uint256 recipientCount, uint256 totalAmount);
    
    // ========== ERRORS ==========
    error InvalidAddress();
    error InvalidAmount();
    error CooldownActive(uint256 timeRemaining);
    error InsufficientFaucetBalance(uint256 available, uint256 required);
    error BatchSizeTooLarge(uint256 size, uint256 maxSize);
    error ClaimAmountExceedsMax(uint256 requested, uint256 maximum);
    error ArrayLengthMismatch();
    
    /**
     * @notice Initializes the faucet with configurable parameters
     * @param _token Address of the ERC20 token to distribute
     * @param _admin Address that will have DEFAULT_ADMIN_ROLE
     * @param _claimAmount Initial amount users can claim
     * @param _cooldownPeriod Initial cooldown period in seconds
     */
    constructor(
        address _token,
        address _admin,
        uint256 _claimAmount,
        uint256 _cooldownPeriod
    ) {
        if (_token == address(0) || _admin == address(0)) revert InvalidAddress();
        if (_claimAmount == 0) revert InvalidAmount();
        
        token = IERC20(_token);
        claimAmount = _claimAmount;
        cooldownPeriod = _cooldownPeriod;
        maxClaimAmount = _claimAmount * 10; // Default: 10x single claim
        minFaucetBalance = _claimAmount * 100; // Default: 100 claims worth
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(CONFIGURATOR_ROLE, _admin);
    }
    
    // ========== EXTERNAL FUNCTIONS ==========
    
    /**
     * @notice Request tokens from the faucet
     * @return amount The amount of tokens claimed
     */
    function requestTokens() external whenNotPaused nonReentrant returns (uint256 amount) {
        return _claimTokens(msg.sender, msg.sender, claimAmount);
    }
    
    /**
     * @notice Request tokens for another address (useful for onboarding)
     * @param recipient Address to receive the tokens
     * @return amount The amount of tokens claimed
     */
    function requestTokensFor(address recipient) 
        external 
        whenNotPaused 
        nonReentrant 
        onlyRole(OPERATOR_ROLE) 
        returns (uint256 amount) 
    {
        if (recipient == address(0)) revert InvalidAddress();
        return _claimTokens(msg.sender, recipient, claimAmount);
    }
    
    /**
     * @notice Request a custom amount of tokens (for special cases)
     * @param amount The amount of tokens to claim
     * @return The actual amount claimed
     */
    function requestCustomAmount(uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256) 
    {
        if (amount > maxClaimAmount) revert ClaimAmountExceedsMax(amount, maxClaimAmount);
        return _claimTokens(msg.sender, msg.sender, amount);
    }
    
    /**
     * @notice Batch claim for multiple recipients
     * @param recipients Array of addresses to receive tokens
     * @param amounts Array of amounts for each recipient
     */
    function batchClaim(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant onlyRole(OPERATOR_ROLE) {
        uint256 length = recipients.length;
        if (length != amounts.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeTooLarge(length, MAX_BATCH_SIZE);
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            if (recipients[i] == address(0)) revert InvalidAddress();
            totalAmount += amounts[i];
        }
        
        if (token.balanceOf(address(this)) < totalAmount) {
            revert InsufficientFaucetBalance(token.balanceOf(address(this)), totalAmount);
        }
        
        for (uint256 i = 0; i < length; i++) {
            _claimTokensWithoutCooldown(recipients[i], amounts[i]);
        }
        
        emit BatchClaim(msg.sender, length, totalAmount);
    }
    
    /**
     * @notice Deposit tokens into the faucet
     * @param amount Amount of tokens to deposit
     */
    function depositTokens(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        
        bool success = token.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        
        emit TokensDeposited(msg.sender, amount);
    }
    
    /**
     * @notice Withdraw tokens from the faucet
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawTokens(address to, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        bool success = token.transfer(to, amount);
        require(success, "Transfer failed");
        
        emit TokensWithdrawn(to, amount);
    }
    
    /**
     * @notice Update faucet configuration
     * @param _claimAmount New claim amount
     * @param _cooldownPeriod New cooldown period
     * @param _maxClaimAmount New maximum claim amount
     * @param _minFaucetBalance New minimum faucet balance warning threshold
     */
    function updateConfiguration(
        uint256 _claimAmount,
        uint256 _cooldownPeriod,
        uint256 _maxClaimAmount,
        uint256 _minFaucetBalance
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (_claimAmount == 0 || _maxClaimAmount < _claimAmount) revert InvalidAmount();
        
        claimAmount = _claimAmount;
        cooldownPeriod = _cooldownPeriod;
        maxClaimAmount = _maxClaimAmount;
        minFaucetBalance = _minFaucetBalance;
        
        emit ConfigurationUpdated(_claimAmount, _cooldownPeriod, _maxClaimAmount, _minFaucetBalance);
    }
    
    /**
     * @notice Pause the faucet
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the faucet
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Check if a user can claim tokens
     * @param user Address to check
     * @return Whether the user can claim
     */
    function canClaim(address user) public view returns (bool) {
        return block.timestamp >= lastClaimTime[user] + cooldownPeriod;
    }
    
    /**
     * @notice Get time until next claim
     * @param user Address to check
     * @return Seconds until next claim (0 if can claim now)
     */
    function timeUntilNextClaim(address user) public view returns (uint256) {
        if (canClaim(user)) return 0;
        return (lastClaimTime[user] + cooldownPeriod) - block.timestamp;
    }
    
    /**
     * @notice Get comprehensive user information
     * @param user Address to query
     * @return totalClaimed Total tokens claimed by user
     * @return claimCount Number of claims made
     * @return lastClaimTime Timestamp of last claim
     * @return canClaimNow Whether user can claim now
     */
    function getUserInfo(address user) external view returns (
        uint256,
        uint256,
        uint256,
        bool
    ) {
        return (
            totalClaimed[user],
            claimCount[user],
            lastClaimTime[user],
            canClaim(user)
        );
    }
    
    
    function getFaucetStats() external view returns (
        uint256 tokenBalance,
        uint256 _totalDistributed,
        uint256 _totalClaimCount,
        uint256 _uniqueUsers,
        bool isLowBalance
    ) {
        tokenBalance = token.balanceOf(address(this));
        return (
            tokenBalance,
            totalDistributed,
            totalClaimCount,
            uniqueUsers,
            tokenBalance < minFaucetBalance
        );
    }
    
    /**
     * @notice Get token metadata
     * @return name Token name
     * @return symbol Token symbol
     * @return decimals Token decimals
     */
    function getTokenInfo() external view returns (
        string memory name,
        string memory symbol,
        uint8 decimals
    ) {
        IERC20Metadata tokenMetadata = IERC20Metadata(address(token));
        return (
            tokenMetadata.name(),
            tokenMetadata.symbol(),
            tokenMetadata.decimals()
        );
    }
    
    /**
     * @notice Check if contract supports an interface
     * @param interfaceId Interface identifier
     * @return Whether interface is supported
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl) 
        returns (bool) 
    {
        return 
            interfaceId == type(ITestnetFaucet).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Internal function to process token claims
     */
    function _claimTokens(
        address claimer,
        address recipient,
        uint256 amount
    ) internal returns (uint256) {
        if (!canClaim(claimer)) {
            revert CooldownActive(timeUntilNextClaim(claimer));
        }
        
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientFaucetBalance(balance, amount);
        }
        
        // Update claimer's cooldown
        lastClaimTime[claimer] = block.timestamp;
        
        // Update statistics
        if (claimCount[recipient] == 0) {
            uniqueUsers++;
        }
        
        totalClaimed[recipient] += amount;
        claimCount[recipient]++;
        totalDistributed += amount;
        totalClaimCount++;
        
        // Transfer tokens
        bool success = token.transfer(recipient, amount);
        require(success, "Transfer failed");
        
        emit TokensClaimed(claimer, recipient, amount, block.timestamp);
        
        return amount;
    }
    
    /**
     * @notice Internal function for batch claims without cooldown check
     */
    function _claimTokensWithoutCooldown(address recipient, uint256 amount) internal {
        if (claimCount[recipient] == 0) {
            uniqueUsers++;
        }
        
        totalClaimed[recipient] += amount;
        claimCount[recipient]++;
        totalDistributed += amount;
        totalClaimCount++;
        
        bool success = token.transfer(recipient, amount);
        require(success, "Transfer failed");
        
        emit TokensClaimed(msg.sender, recipient, amount, block.timestamp);
    }
}
