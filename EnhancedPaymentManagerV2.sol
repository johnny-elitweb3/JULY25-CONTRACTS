// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title IEnhancedGovernanceNFT
 * @notice Interface for the governance NFT contract
 */
interface IEnhancedGovernanceNFT {
    function isProposalApproved(uint256 proposalId) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title EnhancedPaymentManagerV2
 * @dev Advanced payment processing with security improvements and pull-over-push distribution
 * @notice Handles both ETH and ERC20 payments with secure distribution mechanisms
 */
contract EnhancedPaymentManagerV2 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== Constants ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant TECHNOLOGY_SHARE = 1000;    // 10%
    uint256 public constant BUYBACK_SHARE = 1000;       // 10%
    uint256 public constant OPERATIONS_SHARE = 3000;    // 30%
    uint256 public constant INVESTMENTS_SHARE = 5000;   // 50%
    uint256 public constant TOTAL_SHARES = 10000;       // 100%
    
    uint256 public constant MAX_PRICE_AGE = 3600;       // 1 hour
    uint256 public constant MAX_TRANSACTION_USD = 1000000e8; // $1M USD limit
    uint256 public constant RATE_LIMIT_WINDOW = 300;    // 5 minutes
    uint256 public constant MAX_TRANSACTIONS_PER_WINDOW = 10;
    uint256 public constant DUST_THRESHOLD = 100;       // Minimum wei/token units
    uint256 public constant TIMELOCK_DURATION = 24 hours;
    
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    // ========== State Variables ==========
    IEnhancedGovernanceNFT public governanceNFT;
    AggregatorV3Interface public ethUsdPriceFeed;
    
    // Beneficiary addresses
    address payable public technologyAddress;
    address payable public buybackAddress;
    address payable public operationsAddress;
    address payable public investmentsAddress;
    
    // Token management with efficient enumeration
    struct TokenConfig {
        bool accepted;
        address priceFeed;
        uint8 decimals;
        uint256 minAmount;
        bool exists;
    }
    
    mapping(address => TokenConfig) public tokenConfigs;
    EnumerableSet.AddressSet private acceptedTokensSet;
    
    // Pull-over-push distribution system
    mapping(address => mapping(address => uint256)) public pendingWithdrawals; // beneficiary => token => amount
    mapping(address => uint256) public dustAccumulator; // token => accumulated dust
    
    // Rate limiting
    mapping(address => uint256) public userTransactionCount;
    mapping(address => uint256) public userWindowStart;
    
    // Statistics and tracking
    mapping(address => uint256) public totalCollected;
    mapping(address => uint256) public totalDistributed;
    mapping(address => uint256) public totalWithdrawn; // Per beneficiary
    uint256 public totalUSDValue;
    
    // Governance proposals
    struct TokenProposal {
        address token;
        address priceFeed;
        uint8 decimals;
        uint256 minAmount;
        bool executed;
    }
    mapping(uint256 => TokenProposal) public tokenProposals;
    
    // Timelock mechanism
    struct TimelockOperation {
        bytes32 operationHash;
        uint256 executeAfter;
        bool executed;
        string operationType;
    }
    mapping(bytes32 => TimelockOperation) public timelockOperations;
    
    // ========== Events ==========
    event PaymentProcessed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usdValue,
        uint256 timestamp,
        bytes32 indexed transactionId
    );
    
    event DistributionQueued(
        address indexed token,
        uint256 amount,
        uint256 toTechnology,
        uint256 toBuyback,
        uint256 toOperations,
        uint256 toInvestments,
        uint256 dustCollected
    );
    
    event WithdrawalCompleted(
        address indexed beneficiary,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    
    event TokenConfigured(
        address indexed token,
        bool accepted,
        address priceFeed,
        uint256 minAmount
    );
    
    event BeneficiaryUpdated(
        string beneficiaryType,
        address indexed oldAddress,
        address indexed newAddress
    );
    
    event RateLimitExceeded(
        address indexed user,
        uint256 transactionCount,
        uint256 windowStart
    );
    
    event CircuitBreakerTriggered(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usdValue
    );
    
    event DustCollected(
        address indexed token,
        uint256 amount,
        address indexed beneficiary
    );
    
    event TimelockOperationScheduled(
        bytes32 indexed operationHash,
        string operationType,
        uint256 executeAfter
    );
    
    event TimelockOperationExecuted(
        bytes32 indexed operationHash,
        string operationType
    );
    
    event EmergencyAction(
        address indexed admin,
        string actionType,
        address indexed target,
        uint256 amount
    );

    // ========== Modifiers ==========
    
    modifier onlyAfterTimelock(bytes32 operationHash) {
        TimelockOperation memory op = timelockOperations[operationHash];
        require(op.executeAfter != 0, "Operation not scheduled");
        require(block.timestamp >= op.executeAfter, "Timelock not expired");
        require(!op.executed, "Operation already executed");
        _;
        timelockOperations[operationHash].executed = true;
    }
    
    modifier rateLimited() {
        _checkRateLimit(msg.sender);
        _;
    }
    
    modifier circuitBreaker(address token, uint256 amount) {
        uint256 usdValue = _getUSDValue(token, amount);
        require(usdValue <= MAX_TRANSACTION_USD, "Transaction exceeds limit");
        _;
    }

    // ========== Constructor ==========
    
    constructor(
        address _governanceNFT,
        address payable _technology,
        address payable _buyback,
        address payable _operations,
        address payable _investments,
        address _ethUsdPriceFeed
    ) {
        require(_governanceNFT != address(0), "Invalid governance address");
        require(_technology != address(0), "Invalid technology address");
        require(_buyback != address(0), "Invalid buyback address");
        require(_operations != address(0), "Invalid operations address");
        require(_investments != address(0), "Invalid investments address");
        require(_ethUsdPriceFeed != address(0), "Invalid ETH price feed");
        
        _validateUniqueAddresses(_technology, _buyback, _operations, _investments);
        _validateNonContractAddresses(_technology, _buyback, _operations, _investments);
        
        governanceNFT = IEnhancedGovernanceNFT(_governanceNFT);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        
        technologyAddress = _technology;
        buybackAddress = _buyback;
        operationsAddress = _operations;
        investmentsAddress = _investments;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _governanceNFT);
        
        // Configure ETH with proper price feed
        _configureTokenInternal(ETH_ADDRESS, true, _ethUsdPriceFeed, 18, 0.001 ether);
    }

    // ========== Payment Processing ==========
    
    function processETHPayment() 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        rateLimited
        circuitBreaker(ETH_ADDRESS, msg.value)
        returns (bool success) 
    {
        require(tokenConfigs[ETH_ADDRESS].accepted, "ETH not accepted");
        require(msg.value >= tokenConfigs[ETH_ADDRESS].minAmount, "Amount below minimum");
        
        bytes32 transactionId = keccak256(abi.encodePacked(
            msg.sender, 
            ETH_ADDRESS, 
            msg.value, 
            block.timestamp, 
            block.number
        ));
        
        totalCollected[ETH_ADDRESS] += msg.value;
        uint256 usdValue = getETHPriceInUSD(msg.value);
        totalUSDValue += usdValue;
        
        emit PaymentProcessed(
            msg.sender, 
            ETH_ADDRESS, 
            msg.value, 
            usdValue, 
            block.timestamp, 
            transactionId
        );
        
        _queueDistribution(ETH_ADDRESS, msg.value);
        return true;
    }
    
    function processTokenPayment(
        address user,
        address token,
        uint256 amount
    ) 
        external 
        onlyRole(FACTORY_ROLE) 
        nonReentrant 
        whenNotPaused
        circuitBreaker(token, amount)
        returns (bool success) 
    {
        require(tokenConfigs[token].accepted, "Token not accepted");
        require(amount >= tokenConfigs[token].minAmount, "Amount below minimum");
        
        _checkRateLimit(user);
        
        IERC20 paymentToken = IERC20(token);
        require(paymentToken.balanceOf(user) >= amount, "Insufficient balance");
        require(paymentToken.allowance(user, address(this)) >= amount, "Insufficient allowance");
        
        paymentToken.safeTransferFrom(user, address(this), amount);
        
        bytes32 transactionId = keccak256(abi.encodePacked(
            user, 
            token, 
            amount, 
            block.timestamp, 
            block.number
        ));
        
        totalCollected[token] += amount;
        uint256 usdValue = getTokenUSDValue(token, amount);
        totalUSDValue += usdValue;
        
        emit PaymentProcessed(
            user, 
            token, 
            amount, 
            usdValue, 
            block.timestamp, 
            transactionId
        );
        
        _queueDistribution(token, amount);
        return true;
    }

    // ========== Secure Distribution System ==========
    
    function _queueDistribution(address token, uint256 amount) private {
        if (amount == 0) return;
        
        uint256 technologyAmount = (amount * TECHNOLOGY_SHARE) / TOTAL_SHARES;
        uint256 buybackAmount = (amount * BUYBACK_SHARE) / TOTAL_SHARES;
        uint256 operationsAmount = (amount * OPERATIONS_SHARE) / TOTAL_SHARES;
        uint256 investmentsAmount = (amount * INVESTMENTS_SHARE) / TOTAL_SHARES;
        
        uint256 totalAllocated = technologyAmount + buybackAmount + operationsAmount + investmentsAmount;
        uint256 dust = amount - totalAllocated;
        
        // Queue withdrawals for beneficiaries
        if (technologyAmount > 0) {
            pendingWithdrawals[technologyAddress][token] += technologyAmount;
        }
        if (buybackAmount > 0) {
            pendingWithdrawals[buybackAddress][token] += buybackAmount;
        }
        if (operationsAmount > 0) {
            pendingWithdrawals[operationsAddress][token] += operationsAmount;
        }
        if (investmentsAmount > 0) {
            pendingWithdrawals[investmentsAddress][token] += investmentsAmount;
        }
        
        // Handle dust
        if (dust > 0) {
            dustAccumulator[token] += dust;
            
            // Auto-distribute dust if threshold reached
            if (dustAccumulator[token] >= DUST_THRESHOLD) {
                pendingWithdrawals[investmentsAddress][token] += dustAccumulator[token];
                emit DustCollected(token, dustAccumulator[token], investmentsAddress);
                dustAccumulator[token] = 0;
            }
        }
        
        totalDistributed[token] += amount;
        
        emit DistributionQueued(
            token,
            amount,
            technologyAmount,
            buybackAmount,
            operationsAmount,
            investmentsAmount,
            dust
        );
    }
    
    /**
     * @notice Allows beneficiaries to withdraw their pending funds
     * @param token Token address to withdraw (use ETH_ADDRESS for ETH)
     */
    function withdrawPendingFunds(address token) external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender][token];
        require(amount > 0, "No pending withdrawal");
        
        pendingWithdrawals[msg.sender][token] = 0;
        totalWithdrawn[msg.sender] += amount;
        
        bool success = _safeTransfer(token, payable(msg.sender), amount);
        
        if (!success) {
            // Revert the state change if transfer failed
            pendingWithdrawals[msg.sender][token] = amount;
            totalWithdrawn[msg.sender] -= amount;
            revert("Transfer failed");
        }
        
        emit WithdrawalCompleted(msg.sender, token, amount, block.timestamp);
    }
    
    /**
     * @notice Batch withdraw multiple tokens for a beneficiary
     * @param tokens Array of token addresses to withdraw
     */
    function batchWithdrawPendingFunds(address[] calldata tokens) external nonReentrant {
        require(tokens.length <= 10, "Too many tokens"); // Gas limit protection
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = pendingWithdrawals[msg.sender][token];
            
            if (amount > 0) {
                pendingWithdrawals[msg.sender][token] = 0;
                totalWithdrawn[msg.sender] += amount;
                
                bool success = _safeTransfer(token, payable(msg.sender), amount);
                
                if (success) {
                    emit WithdrawalCompleted(msg.sender, token, amount, block.timestamp);
                } else {
                    // Revert the state change if transfer failed
                    pendingWithdrawals[msg.sender][token] = amount;
                    totalWithdrawn[msg.sender] -= amount;
                }
            }
        }
    }
    
    function _safeTransfer(address token, address payable to, uint256 amount) private returns (bool) {
        if (token == ETH_ADDRESS) {
            (bool success, ) = to.call{value: amount, gas: 10000}("");
            return success;
        } else {
            try IERC20(token).transfer(to, amount) returns (bool success) {
                return success;
            } catch {
                return false;
            }
        }
    }

    // ========== Enhanced Oracle Functions ==========
    
    function getTokenUSDValue(address token, uint256 amount) public view returns (uint256) {
        TokenConfig memory config = tokenConfigs[token];
        require(config.accepted, "Token not accepted");
        require(config.priceFeed != address(0), "No price feed configured");
        
        AggregatorV3Interface priceFeed = AggregatorV3Interface(config.priceFeed);
        
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        // Enhanced oracle validation
        require(updatedAt > 0, "Invalid price data");
        require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "Price data too stale");
        require(price > 0, "Invalid price");
        require(answeredInRound >= roundId, "Stale round data");
        require(startedAt > 0, "Round not complete");
        
        uint256 tokenDecimals = 10 ** config.decimals;
        uint256 usdValue = (amount * uint256(price)) / tokenDecimals;
        
        return usdValue;
    }
    
    function getETHPriceInUSD(uint256 amount) public view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethUsdPriceFeed.latestRoundData();
        
        require(updatedAt > 0, "Invalid ETH price data");
        require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "ETH price data too stale");
        require(price > 0, "Invalid ETH price");
        require(answeredInRound >= roundId, "Stale ETH round data");
        require(startedAt > 0, "ETH round not complete");
        
        // ETH price feeds typically return price with 8 decimals
        // Convert ETH amount (in wei) to USD value (with 8 decimals)
        uint256 usdValue = (amount * uint256(price)) / 1e18;
        
        return usdValue;
    }
    
    function _getUSDValue(address token, uint256 amount) private view returns (uint256) {
        if (token == ETH_ADDRESS) {
            return getETHPriceInUSD(amount);
        } else {
            return getTokenUSDValue(token, amount);
        }
    }

    // ========== Rate Limiting ==========
    
    function _checkRateLimit(address user) private {
        uint256 currentWindow = block.timestamp / RATE_LIMIT_WINDOW;
        uint256 userWindow = userWindowStart[user] / RATE_LIMIT_WINDOW;
        
        if (currentWindow > userWindow) {
            // New window, reset counter
            userTransactionCount[user] = 1;
            userWindowStart[user] = block.timestamp;
        } else {
            // Same window, increment counter
            userTransactionCount[user]++;
            require(
                userTransactionCount[user] <= MAX_TRANSACTIONS_PER_WINDOW,
                "Rate limit exceeded"
            );
            
            if (userTransactionCount[user] == MAX_TRANSACTIONS_PER_WINDOW) {
                emit RateLimitExceeded(user, userTransactionCount[user], userWindowStart[user]);
            }
        }
    }

    // ========== Enhanced Admin Functions with Timelock ==========
    
    function scheduleUpdateBeneficiary(
        string memory beneficiaryType,
        address payable newAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(newAddress != address(0), "Invalid address");
        _validateNonContractAddress(newAddress);
        
        bytes32 operationHash = keccak256(abi.encodePacked(
            "updateBeneficiary",
            beneficiaryType,
            newAddress,
            block.timestamp
        ));
        
        timelockOperations[operationHash] = TimelockOperation({
            operationHash: operationHash,
            executeAfter: block.timestamp + TIMELOCK_DURATION,
            executed: false,
            operationType: string(abi.encodePacked("updateBeneficiary:", beneficiaryType))
        });
        
        emit TimelockOperationScheduled(
            operationHash,
            string(abi.encodePacked("updateBeneficiary:", beneficiaryType)),
            block.timestamp + TIMELOCK_DURATION
        );
    }
    
    function executeUpdateBeneficiary(
        string memory beneficiaryType,
        address payable newAddress,
        uint256 timestamp
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 operationHash = keccak256(abi.encodePacked(
            "updateBeneficiary",
            beneficiaryType,
            newAddress,
            timestamp
        ));
        
        _executeWithTimelock(operationHash);
        
        bytes32 typeHash = keccak256(bytes(beneficiaryType));
        address oldAddress;
        
        if (typeHash == keccak256("technology")) {
            oldAddress = technologyAddress;
            technologyAddress = newAddress;
        } else if (typeHash == keccak256("buyback")) {
            oldAddress = buybackAddress;
            buybackAddress = newAddress;
        } else if (typeHash == keccak256("operations")) {
            oldAddress = operationsAddress;
            operationsAddress = newAddress;
        } else if (typeHash == keccak256("investments")) {
            oldAddress = investmentsAddress;
            investmentsAddress = newAddress;
        } else {
            revert("Invalid beneficiary type");
        }
        
        emit BeneficiaryUpdated(beneficiaryType, oldAddress, newAddress);
        emit TimelockOperationExecuted(operationHash, string(abi.encodePacked("updateBeneficiary:", beneficiaryType)));
    }
    
    function _executeWithTimelock(bytes32 operationHash) private onlyAfterTimelock(operationHash) {
        // Modifier handles the logic
    }

    // ========== Token Management ==========
    
    function configureToken(
        address token,
        bool accepted,
        address priceFeed,
        uint8 decimals,
        uint256 minAmount
    ) external onlyRole(ADMIN_ROLE) {
        _configureTokenInternal(token, accepted, priceFeed, decimals, minAmount);
    }
    
    function _configureTokenInternal(
        address token,
        bool accepted,
        address priceFeed,
        uint8 decimals,
        uint256 minAmount
    ) private {
        require(token != address(0), "Invalid token address");
        
        if (accepted) {
            require(priceFeed != address(0), "Price feed required");
            require(decimals > 0 && decimals <= 18, "Invalid decimals");
            
            if (!tokenConfigs[token].exists) {
                acceptedTokensSet.add(token);
                tokenConfigs[token].exists = true;
            }
            
            tokenConfigs[token] = TokenConfig({
                accepted: true,
                priceFeed: priceFeed,
                decimals: decimals,
                minAmount: minAmount,
                exists: true
            });
        } else {
            tokenConfigs[token].accepted = false;
            acceptedTokensSet.remove(token);
        }
        
        emit TokenConfigured(token, accepted, priceFeed, minAmount);
    }

    // ========== Enhanced Emergency Functions ==========
    
    function emergencyWithdrawToken(
        address token,
        address payable to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        
        if (token == ETH_ADDRESS) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20 tokenContract = IERC20(token);
            require(tokenContract.balanceOf(address(this)) >= amount, "Insufficient token balance");
            tokenContract.safeTransfer(to, amount);
        }
        
        emit EmergencyAction(msg.sender, "emergencyWithdraw", token, amount);
    }
    
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyAction(msg.sender, "pause", address(0), 0);
    }
    
    function emergencyUnpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit EmergencyAction(msg.sender, "unpause", address(0), 0);
    }

    // ========== Enhanced View Functions ==========
    
    function getAcceptedTokens() external view returns (address[] memory) {
        return acceptedTokensSet.values();
    }
    
    function getTokenCount() external view returns (uint256) {
        return acceptedTokensSet.length();
    }
    
    function getTokenAt(uint256 index) external view returns (address) {
        return acceptedTokensSet.at(index);
    }
    
    function getPendingWithdrawal(address beneficiary, address token) external view returns (uint256) {
        return pendingWithdrawals[beneficiary][token];
    }
    
    function getBeneficiaryPendingWithdrawals(address beneficiary) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        address[] memory allTokens = acceptedTokensSet.values();
        uint256 count = 0;
        
        // Count non-zero withdrawals
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (pendingWithdrawals[beneficiary][allTokens[i]] > 0) {
                count++;
            }
        }
        
        tokens = new address[](count);
        amounts = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allTokens.length; i++) {
            uint256 amount = pendingWithdrawals[beneficiary][allTokens[i]];
            if (amount > 0) {
                tokens[index] = allTokens[i];
                amounts[index] = amount;
                index++;
            }
        }
    }
    
    function getContractStats() external view returns (
        uint256 totalTokens,
        uint256 totalUSD,
        uint256 totalPendingDistributions,
        uint256 totalDustAccumulated
    ) {
        totalTokens = acceptedTokensSet.length();
        totalUSD = totalUSDValue;
        
        address[] memory tokens = acceptedTokensSet.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            totalPendingDistributions += totalCollected[token] - totalDistributed[token];
            totalDustAccumulated += dustAccumulator[token];
        }
    }
    
    function getUserRateLimit(address user) external view returns (
        uint256 transactionCount,
        uint256 windowStart,
        uint256 remainingTransactions
    ) {
        uint256 currentWindow = block.timestamp / RATE_LIMIT_WINDOW;
        uint256 userWindow = userWindowStart[user] / RATE_LIMIT_WINDOW;
        
        if (currentWindow > userWindow) {
            transactionCount = 0;
            windowStart = block.timestamp;
            remainingTransactions = MAX_TRANSACTIONS_PER_WINDOW;
        } else {
            transactionCount = userTransactionCount[user];
            windowStart = userWindowStart[user];
            remainingTransactions = MAX_TRANSACTIONS_PER_WINDOW > transactionCount 
                ? MAX_TRANSACTIONS_PER_WINDOW - transactionCount 
                : 0;
        }
    }

    // ========== Address Validation Helpers ==========
    
    function _validateUniqueAddresses(
        address addr1, 
        address addr2, 
        address addr3, 
        address addr4
    ) private pure {
        require(
            addr1 != addr2 && addr1 != addr3 && addr1 != addr4 &&
            addr2 != addr3 && addr2 != addr4 &&
            addr3 != addr4,
            "Duplicate beneficiary addresses"
        );
    }
    
    function _validateNonContractAddresses(
        address addr1, 
        address addr2, 
        address addr3, 
        address addr4
    ) private view {
        _validateNonContractAddress(addr1);
        _validateNonContractAddress(addr2);
        _validateNonContractAddress(addr3);
        _validateNonContractAddress(addr4);
    }
    
    function _validateNonContractAddress(address addr) private view {
        require(addr.code.length == 0, "Beneficiary cannot be a contract");
    }

    // ========== Governance Integration ==========
    
    function executeTokenProposal(uint256 proposalId) external nonReentrant {
        require(governanceNFT.isProposalApproved(proposalId), "Proposal not approved");
        
        TokenProposal storage proposal = tokenProposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(proposal.token != address(0), "Invalid proposal");
        
        proposal.executed = true;
        
        _configureTokenInternal(
            proposal.token,
            true,
            proposal.priceFeed,
            proposal.decimals,
            proposal.minAmount
        );
        
        emit TokenProposalExecuted(proposalId, proposal.token, proposal.priceFeed);
    }
    
    function storeTokenProposal(
        uint256 proposalId,
        address token,
        address priceFeed,
        uint8 decimals,
        uint256 minAmount
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token address");
        require(priceFeed != address(0), "Invalid price feed");
        require(decimals > 0 && decimals <= 18, "Invalid decimals");
        
        tokenProposals[proposalId] = TokenProposal({
            token: token,
            priceFeed: priceFeed,
            decimals: decimals,
            minAmount: minAmount,
            executed: false
        });
    }

    // ========== Events for Governance ==========
    
    event TokenProposalExecuted(
        uint256 indexed proposalId,
        address indexed token,
        address priceFeed
    );

    // ========== Fallback ==========
    
    receive() external payable {
        if (msg.value > 0 && !paused()) {
            require(tokenConfigs[ETH_ADDRESS].accepted, "ETH not accepted");
            require(msg.value >= tokenConfigs[ETH_ADDRESS].minAmount, "Amount below minimum");
            
            // Basic rate limiting for direct sends
            _checkRateLimit(msg.sender);
            
            // Circuit breaker check
            uint256 usdValue = getETHPriceInUSD(msg.value);
            require(usdValue <= MAX_TRANSACTION_USD, "Transaction exceeds limit");
            
            totalCollected[ETH_ADDRESS] += msg.value;
            totalUSDValue += usdValue;
            
            bytes32 transactionId = keccak256(abi.encodePacked(
                msg.sender, 
                ETH_ADDRESS, 
                msg.value, 
                block.timestamp, 
                block.number
            ));
            
            emit PaymentProcessed(
                msg.sender, 
                ETH_ADDRESS, 
                msg.value, 
                usdValue, 
                block.timestamp, 
                transactionId
            );
            
            _queueDistribution(ETH_ADDRESS, msg.value);
        }
    }
}
