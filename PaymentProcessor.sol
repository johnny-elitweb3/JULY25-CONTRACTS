// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title PaymentProcessor
 * @author Petroleum Club
 * @notice Handles payment processing and fee distribution for the CBG ecosystem
 * @dev Pull-based distribution system with configurable beneficiaries
 */
contract PaymentProcessor is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // ========== Custom Errors ==========
    error Unauthorized();
    error InvalidConfiguration();
    error InvalidAddress();
    error InvalidPercentage();
    error InvalidIndex();
    error TransferFailed();
    error InsufficientBalance();
    error OracleError();
    error StalePrice();
    error ZeroAmount();
    error TooManyBeneficiaries();
    error DuplicateBeneficiary();
    error BatchSizeExceeded();
    
    // ========== Type Declarations ==========
    struct Beneficiary {
        address payable addr;
        uint256 percentage;      // Basis points (10000 = 100%)
        string label;            // Description (technology/buyback/operations/investments)
        bool isActive;
    }
    
    struct Distribution {
        uint256 technology;
        uint256 buyback;
        uint256 operations;
        uint256 investments;
        uint256 protocolFee;
    }
    
    struct PaymentRecord {
        address buyer;
        address token;
        uint256 amount;
        uint256 usdValue;
        uint256 seriesId;
        uint256 timestamp;
        uint256 protocolFee;
    }
    
    struct WithdrawalBatch {
        address[] tokens;
        uint256[] amounts;
        uint256 totalUsdValue;
    }
    
    // ========== Constants ==========
    uint256 public constant PERCENT_PRECISION = 10000;  // 100.00%
    uint256 public constant MAX_BENEFICIARIES = 10;
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant MIN_PROTOCOL_FEE = 100;     // 1%
    uint256 public constant MAX_PROTOCOL_FEE = 1000;    // 10%
    
    // Default distribution percentages (can be updated)
    uint256 public constant DEFAULT_TECHNOLOGY_PERCENT = 4000;    // 40%
    uint256 public constant DEFAULT_BUYBACK_PERCENT = 3000;       // 30%
    uint256 public constant DEFAULT_OPERATIONS_PERCENT = 2000;    // 20%
    uint256 public constant DEFAULT_INVESTMENTS_PERCENT = 1000;   // 10%
    
    // ========== State Variables ==========
    
    // Beneficiaries
    Beneficiary[] public beneficiaries;
    mapping(string => uint256) public beneficiaryIndex;  // label => array index
    uint256 public totalActivePercentage;
    
    // Protocol Fee
    uint256 public protocolFeePercent = 200;  // 2% default
    address public protocolFeeRecipient;
    
    // Distribution Tracking
    mapping(address => mapping(address => uint256)) public pendingWithdrawals; // beneficiary => token => amount
    mapping(address => uint256) public totalCollected;      // token => total collected
    mapping(address => uint256) public totalDistributed;    // token => total distributed
    mapping(address => uint256) public totalProtocolFees;   // token => total fees
    
    // Payment History
    PaymentRecord[] public paymentHistory;
    mapping(uint256 => PaymentRecord[]) public seriesPayments; // seriesId => payments
    
    // Oracle Configuration
    mapping(address => address) public tokenPriceFeeds;
    mapping(address => uint8) public tokenDecimals;
    
    // Access Control
    address public authorizedCore;
    address public admin;
    address public operator;
    
    // Statistics
    uint256 public totalPaymentsProcessed;
    uint256 public totalUsdVolumeProcessed;
    mapping(address => uint256) public beneficiaryTotalWithdrawn; // beneficiary => USD value withdrawn
    
    // ========== Events ==========
    event PaymentProcessed(
        address indexed buyer,
        address indexed token,
        uint256 amount,
        uint256 usdValue,
        uint256 seriesId,
        uint256 protocolFee
    );
    
    event DistributionCalculated(
        address indexed token,
        uint256 amount,
        uint256 technology,
        uint256 buyback,
        uint256 operations,
        uint256 investments,
        uint256 protocolFee
    );
    
    event FundsWithdrawn(
        address indexed beneficiary,
        address indexed token,
        uint256 amount,
        uint256 usdValue
    );
    
    event BatchWithdrawalCompleted(
        address indexed beneficiary,
        uint256 tokenCount,
        uint256 totalAmount,
        uint256 totalUsdValue
    );
    
    event BeneficiaryUpdated(
        uint256 indexed index,
        address indexed oldAddress,
        address indexed newAddress,
        uint256 percentage,
        string label
    );
    
    event BeneficiaryAdded(
        address indexed beneficiary,
        uint256 percentage,
        string label
    );
    
    event BeneficiaryRemoved(
        uint256 indexed index,
        address indexed beneficiary
    );
    
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event AuthorizedCoreUpdated(address indexed oldCore, address indexed newCore);
    event OracleConfigured(address indexed token, address indexed priceFeed, uint8 decimals);
    
    // ========== Constructor ==========
    /**
     * @notice Initialize the PaymentProcessor with separate beneficiary addresses
     * @param _admin Admin address for contract management
     * @param _protocolFeeRecipient Address to receive protocol fees
     * @param _technologyBeneficiary Address for technology development funds
     * @param _buybackBeneficiary Address for token buyback funds
     * @param _operationsBeneficiary Address for operations funds
     * @param _investmentsBeneficiary Address for investment funds
     */
    constructor(
        address _admin,
        address _protocolFeeRecipient,
        address payable _technologyBeneficiary,
        address payable _buybackBeneficiary,
        address payable _operationsBeneficiary,
        address payable _investmentsBeneficiary
    ) {
        // Validate all addresses
        if (_admin == address(0) || 
            _protocolFeeRecipient == address(0) ||
            _technologyBeneficiary == address(0) ||
            _buybackBeneficiary == address(0) ||
            _operationsBeneficiary == address(0) ||
            _investmentsBeneficiary == address(0)) {
            revert InvalidAddress();
        }
        
        admin = _admin;
        operator = _admin;
        protocolFeeRecipient = _protocolFeeRecipient;
        
        // Initialize beneficiaries with separate addresses
        _addBeneficiary(_technologyBeneficiary, DEFAULT_TECHNOLOGY_PERCENT, "technology");
        _addBeneficiary(_buybackBeneficiary, DEFAULT_BUYBACK_PERCENT, "buyback");
        _addBeneficiary(_operationsBeneficiary, DEFAULT_OPERATIONS_PERCENT, "operations");
        _addBeneficiary(_investmentsBeneficiary, DEFAULT_INVESTMENTS_PERCENT, "investments");
    }
    
    // ========== Modifiers ==========
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorizedCore() {
        if (msg.sender != authorizedCore) revert Unauthorized();
        _;
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @notice Set the authorized core contract
     * @param _authorizedCore New authorized core address
     */
    function setAuthorizedCore(address _authorizedCore) external onlyAdmin {
        if (_authorizedCore == address(0)) revert InvalidAddress();
        address oldCore = authorizedCore;
        authorizedCore = _authorizedCore;
        emit AuthorizedCoreUpdated(oldCore, _authorizedCore);
    }
    
    /**
     * @notice Update operator address
     * @param _operator New operator address
     */
    function setOperator(address _operator) external onlyAdmin {
        if (_operator == address(0)) revert InvalidAddress();
        operator = _operator;
    }
    
    /**
     * @notice Transfer admin role
     * @param _newAdmin New admin address
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        admin = _newAdmin;
    }
    
    /**
     * @notice Update protocol fee percentage
     * @param _newFeePercent New fee percentage in basis points
     */
    function setProtocolFee(uint256 _newFeePercent) external onlyAdmin {
        if (_newFeePercent < MIN_PROTOCOL_FEE || _newFeePercent > MAX_PROTOCOL_FEE) {
            revert InvalidPercentage();
        }
        uint256 oldFee = protocolFeePercent;
        protocolFeePercent = _newFeePercent;
        emit ProtocolFeeUpdated(oldFee, _newFeePercent);
    }
    
    /**
     * @notice Update protocol fee recipient
     * @param _recipient New fee recipient address
     */
    function setProtocolFeeRecipient(address _recipient) external onlyAdmin {
        if (_recipient == address(0)) revert InvalidAddress();
        protocolFeeRecipient = _recipient;
    }
    
    // ========== Beneficiary Management ==========
    
    /**
     * @notice Add a new beneficiary
     * @param _beneficiary Beneficiary address
     * @param _percentage Percentage in basis points
     * @param _label Description label
     */
    function addBeneficiary(
        address payable _beneficiary,
        uint256 _percentage,
        string calldata _label
    ) external onlyAdmin {
        _addBeneficiary(_beneficiary, _percentage, _label);
    }
    
    /**
     * @notice Internal function to add beneficiary
     */
    function _addBeneficiary(
        address payable _beneficiary,
        uint256 _percentage,
        string memory _label
    ) private {
        if (_beneficiary == address(0)) revert InvalidAddress();
        if (_percentage == 0 || _percentage > PERCENT_PRECISION) revert InvalidPercentage();
        if (beneficiaries.length >= MAX_BENEFICIARIES) revert TooManyBeneficiaries();
        
        // Check for duplicate address and label combination
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].addr == _beneficiary && 
                keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes(_label)) &&
                beneficiaries[i].isActive) {
                revert DuplicateBeneficiary();
            }
        }
        
        // Check total percentage doesn't exceed 100%
        if (totalActivePercentage + _percentage > PERCENT_PRECISION) {
            revert InvalidPercentage();
        }
        
        beneficiaries.push(Beneficiary({
            addr: _beneficiary,
            percentage: _percentage,
            label: _label,
            isActive: true
        }));
        
        beneficiaryIndex[_label] = beneficiaries.length - 1;
        totalActivePercentage += _percentage;
        
        emit BeneficiaryAdded(_beneficiary, _percentage, _label);
    }
    
    /**
     * @notice Update an existing beneficiary
     * @param _index Beneficiary index
     * @param _newAddress New beneficiary address
     */
    function updateBeneficiary(
        uint256 _index,
        address payable _newAddress
    ) external onlyAdmin {
        if (_index >= beneficiaries.length) revert InvalidIndex();
        if (_newAddress == address(0)) revert InvalidAddress();
        
        Beneficiary storage beneficiary = beneficiaries[_index];
        if (!beneficiary.isActive) revert InvalidIndex();
        
        address oldAddress = beneficiary.addr;
        beneficiary.addr = _newAddress;
        
        emit BeneficiaryUpdated(_index, oldAddress, _newAddress, beneficiary.percentage, beneficiary.label);
    }
    
    /**
     * @notice Remove a beneficiary
     * @param _index Beneficiary index
     */
    function removeBeneficiary(uint256 _index) external onlyAdmin {
        if (_index >= beneficiaries.length) revert InvalidIndex();
        
        Beneficiary storage beneficiary = beneficiaries[_index];
        if (!beneficiary.isActive) revert InvalidIndex();
        
        beneficiary.isActive = false;
        totalActivePercentage -= beneficiary.percentage;
        
        emit BeneficiaryRemoved(_index, beneficiary.addr);
    }
    
    /**
     * @notice Update beneficiary percentage
     * @param _index Beneficiary index
     * @param _newPercentage New percentage in basis points
     */
    function updateBeneficiaryPercentage(
        uint256 _index,
        uint256 _newPercentage
    ) external onlyAdmin {
        if (_index >= beneficiaries.length) revert InvalidIndex();
        if (_newPercentage == 0 || _newPercentage > PERCENT_PRECISION) revert InvalidPercentage();
        
        Beneficiary storage beneficiary = beneficiaries[_index];
        if (!beneficiary.isActive) revert InvalidIndex();
        
        uint256 newTotal = totalActivePercentage - beneficiary.percentage + _newPercentage;
        if (newTotal > PERCENT_PRECISION) revert InvalidPercentage();
        
        totalActivePercentage = newTotal;
        beneficiary.percentage = _newPercentage;
        
        emit BeneficiaryUpdated(_index, beneficiary.addr, beneficiary.addr, _newPercentage, beneficiary.label);
    }
    
    // ========== Payment Processing ==========
    
    /**
     * @notice Process a payment from the authorized core
     * @param buyer Address of the buyer
     * @param token Payment token address
     * @param amount Token amount
     * @param seriesId Series identifier
     * @return success Whether processing succeeded
     */
    function processPayment(
        address buyer,
        address token,
        uint256 amount,
        uint256 seriesId
    ) external onlyAuthorizedCore nonReentrant whenNotPaused returns (bool success) {
        if (buyer == address(0) || token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        
        // Calculate USD value
        uint256 usdValue = _calculateUsdValue(token, amount);
        
        // Calculate protocol fee
        uint256 protocolFee = (amount * protocolFeePercent) / PERCENT_PRECISION;
        uint256 distributableAmount = amount - protocolFee;
        
        // Update protocol fee tracking
        pendingWithdrawals[protocolFeeRecipient][token] += protocolFee;
        totalProtocolFees[token] += protocolFee;
        
        // Distribute to beneficiaries
        uint256 totalDistributedAmount = 0;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                uint256 beneficiaryAmount = (distributableAmount * beneficiaries[i].percentage) / PERCENT_PRECISION;
                pendingWithdrawals[beneficiaries[i].addr][token] += beneficiaryAmount;
                totalDistributedAmount += beneficiaryAmount;
            }
        }
        
        // Handle rounding dust (add to first active beneficiary)
        if (totalDistributedAmount < distributableAmount) {
            for (uint256 i = 0; i < beneficiaries.length; i++) {
                if (beneficiaries[i].isActive) {
                    pendingWithdrawals[beneficiaries[i].addr][token] += distributableAmount - totalDistributedAmount;
                    break;
                }
            }
        }
        
        // Update tracking
        totalCollected[token] += amount;
        totalPaymentsProcessed++;
        totalUsdVolumeProcessed += usdValue;
        
        // Store payment record
        PaymentRecord memory record = PaymentRecord({
            buyer: buyer,
            token: token,
            amount: amount,
            usdValue: usdValue,
            seriesId: seriesId,
            timestamp: block.timestamp,
            protocolFee: protocolFee
        });
        
        paymentHistory.push(record);
        seriesPayments[seriesId].push(record);
        
        emit PaymentProcessed(buyer, token, amount, usdValue, seriesId, protocolFee);
        
        // Emit distribution event for tracking
        _emitDistributionEvent(token, distributableAmount);
        
        return true;
    }
    
    /**
     * @notice Calculate distribution amounts
     * @param amount Total amount to distribute
     * @return dist Distribution breakdown
     */
    function calculateDistribution(
        uint256 amount
    ) external view returns (Distribution memory dist) {
        uint256 protocolFee = (amount * protocolFeePercent) / PERCENT_PRECISION;
        uint256 distributableAmount = amount - protocolFee;
        
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                uint256 beneficiaryAmount = (distributableAmount * beneficiaries[i].percentage) / PERCENT_PRECISION;
                
                if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("technology"))) {
                    dist.technology = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("buyback"))) {
                    dist.buyback = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("operations"))) {
                    dist.operations = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("investments"))) {
                    dist.investments = beneficiaryAmount;
                }
            }
        }
        
        dist.protocolFee = protocolFee;
    }
    
    // ========== Withdrawal Functions ==========
    
    /**
     * @notice Withdraw pending funds for a specific token
     * @param token Token to withdraw
     */
    function withdrawPendingFunds(address token) external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender][token];
        if (amount == 0) revert InsufficientBalance();
        
        pendingWithdrawals[msg.sender][token] = 0;
        totalDistributed[token] += amount;
        
        // Calculate USD value for tracking
        uint256 usdValue = _calculateUsdValue(token, amount);
        beneficiaryTotalWithdrawn[msg.sender] += usdValue;
        
        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit FundsWithdrawn(msg.sender, token, amount, usdValue);
    }
    
    /**
     * @notice Batch withdraw across multiple tokens
     * @param tokens Array of token addresses to withdraw
     */
    function batchWithdraw(address[] calldata tokens) external nonReentrant {
        uint256 count = tokens.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        uint256 totalUsdValue = 0;
        uint256 successfulWithdrawals = 0;
        
        for (uint256 i = 0; i < count; i++) {
            uint256 amount = pendingWithdrawals[msg.sender][tokens[i]];
            if (amount > 0) {
                pendingWithdrawals[msg.sender][tokens[i]] = 0;
                totalDistributed[tokens[i]] += amount;
                
                // Calculate USD value
                uint256 usdValue = _calculateUsdValue(tokens[i], amount);
                totalUsdValue += usdValue;
                
                // Transfer tokens
                IERC20(tokens[i]).safeTransfer(msg.sender, amount);
                
                emit FundsWithdrawn(msg.sender, tokens[i], amount, usdValue);
                successfulWithdrawals++;
            }
        }
        
        if (successfulWithdrawals > 0) {
            beneficiaryTotalWithdrawn[msg.sender] += totalUsdValue;
            emit BatchWithdrawalCompleted(msg.sender, successfulWithdrawals, 0, totalUsdValue);
        }
    }
    
    /**
     * @notice Get pending balance for a beneficiary
     * @param beneficiary Beneficiary address
     * @param token Token address
     * @return amount Pending amount
     */
    function getPendingBalance(
        address beneficiary,
        address token
    ) external view returns (uint256 amount) {
        return pendingWithdrawals[beneficiary][token];
    }
    
    /**
     * @notice Get all pending balances for a beneficiary
     * @param beneficiary Beneficiary address
     * @param tokens Array of token addresses to check
     * @return amounts Array of pending amounts
     * @return totalUsdValue Total USD value of pending funds
     */
    function getAllPendingBalances(
        address beneficiary,
        address[] calldata tokens
    ) external view returns (uint256[] memory amounts, uint256 totalUsdValue) {
        amounts = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = pendingWithdrawals[beneficiary][tokens[i]];
            if (amounts[i] > 0) {
                totalUsdValue += _calculateUsdValue(tokens[i], amounts[i]);
            }
        }
    }
    
    // ========== Oracle Functions ==========
    
    /**
     * @notice Configure price feed for a token
     * @param token Token address
     * @param priceFeed Chainlink price feed address
     * @param decimals Token decimals
     */
    function configureOracle(
        address token,
        address priceFeed,
        uint8 decimals
    ) external onlyOperator {
        if (token == address(0) || priceFeed == address(0)) revert InvalidAddress();
        if (decimals == 0 || decimals > 18) revert InvalidConfiguration();
        
        tokenPriceFeeds[token] = priceFeed;
        tokenDecimals[token] = decimals;
        
        emit OracleConfigured(token, priceFeed, decimals);
    }
    
    /**
     * @notice Calculate USD value of token amount
     * @param token Token address
     * @param amount Token amount
     * @return usdValue USD value with 18 decimals
     */
    function _calculateUsdValue(
        address token,
        uint256 amount
    ) private view returns (uint256 usdValue) {
        address priceFeed = tokenPriceFeeds[token];
        if (priceFeed == address(0)) {
            // If no price feed configured, return 0
            return 0;
        }
        
        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (price <= 0) revert OracleError();
            if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePrice();
            
            // Convert to 18 decimals
            uint8 tokenDec = tokenDecimals[token];
            uint8 priceDec = 8; // Chainlink USD feeds typically have 8 decimals
            
            // Calculate: amount * price / 10^(tokenDecimals + priceDecimals - 18)
            if (tokenDec + priceDec >= 18) {
                usdValue = (amount * uint256(price)) / (10 ** (tokenDec + priceDec - 18));
            } else {
                usdValue = (amount * uint256(price)) * (10 ** (18 - tokenDec - priceDec));
            }
        } catch {
            revert OracleError();
        }
    }
    
    /**
     * @notice Get current USD price for a token
     * @param token Token address
     * @return price Current price in USD (8 decimals)
     * @return timestamp Last update timestamp
     */
    function getTokenPrice(address token) external view returns (uint256 price, uint256 timestamp) {
        address priceFeed = tokenPriceFeeds[token];
        if (priceFeed == address(0)) {
            return (0, 0);
        }
        
        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80,
            int256 _price,
            uint256,
            uint256 _timestamp,
            uint80
        ) {
            if (_price > 0) {
                return (uint256(_price), _timestamp);
            }
        } catch {
            // Return zero values on oracle error
        }
        
        return (0, 0);
    }
    
    /**
     * @notice Emit distribution event for tracking
     */
    function _emitDistributionEvent(address token, uint256 distributableAmount) private {
        Distribution memory dist;
        
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                uint256 beneficiaryAmount = (distributableAmount * beneficiaries[i].percentage) / PERCENT_PRECISION;
                
                if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("technology"))) {
                    dist.technology = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("buyback"))) {
                    dist.buyback = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("operations"))) {
                    dist.operations = beneficiaryAmount;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("investments"))) {
                    dist.investments = beneficiaryAmount;
                }
            }
        }
        
        dist.protocolFee = (distributableAmount * protocolFeePercent) / (PERCENT_PRECISION - protocolFeePercent);
        
        emit DistributionCalculated(
            token,
            distributableAmount + dist.protocolFee,
            dist.technology,
            dist.buyback,
            dist.operations,
            dist.investments,
            dist.protocolFee
        );
    }
    
    // ========== View Functions ==========
    
    /**
     * @notice Get beneficiary details
     * @param _index Beneficiary index
     * @return beneficiary Beneficiary details
     */
    function getBeneficiary(uint256 _index) external view returns (Beneficiary memory) {
        if (_index >= beneficiaries.length) revert InvalidIndex();
        return beneficiaries[_index];
    }
    
    /**
     * @notice Get all active beneficiaries
     * @return activeBeneficiaries Array of active beneficiaries
     */
    function getActiveBeneficiaries() external view returns (Beneficiary[] memory activeBeneficiaries) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) activeCount++;
        }
        
        activeBeneficiaries = new Beneficiary[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                activeBeneficiaries[index++] = beneficiaries[i];
            }
        }
    }
    
    /**
     * @notice Get beneficiary by label
     * @param label Beneficiary label
     * @return beneficiary Beneficiary details
     */
    function getBeneficiaryByLabel(string calldata label) external view returns (Beneficiary memory beneficiary) {
        uint256 index = beneficiaryIndex[label];
        if (index < beneficiaries.length) {
            beneficiary = beneficiaries[index];
        }
    }
    
    /**
     * @notice Get payment history for a series
     * @param seriesId Series identifier
     * @return payments Array of payment records
     */
    function getSeriesPayments(uint256 seriesId) external view returns (PaymentRecord[] memory) {
        return seriesPayments[seriesId];
    }
    
    /**
     * @notice Get recent payment history
     * @param count Number of recent payments to return
     * @return payments Array of payment records
     */
    function getRecentPayments(uint256 count) external view returns (PaymentRecord[] memory payments) {
        uint256 length = paymentHistory.length;
        if (count > length) count = length;
        
        payments = new PaymentRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            payments[i] = paymentHistory[length - count + i];
        }
    }
    
    /**
     * @notice Get token statistics
     * @param token Token address
     * @return collected Total collected
     * @return distributed Total distributed
     * @return pending Total pending
     * @return fees Total protocol fees
     */
    function getTokenStats(address token) external view returns (
        uint256 collected,
        uint256 distributed,
        uint256 pending,
        uint256 fees
    ) {
        collected = totalCollected[token];
        distributed = totalDistributed[token];
        pending = collected - distributed - totalProtocolFees[token];
        fees = totalProtocolFees[token];
    }
    
    
    function getAllBeneficiaryAddresses() external view returns (
        address technology,
        address buyback,
        address operations,
        address investments
    ) {
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("technology"))) {
                    technology = beneficiaries[i].addr;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("buyback"))) {
                    buyback = beneficiaries[i].addr;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("operations"))) {
                    operations = beneficiaries[i].addr;
                } else if (keccak256(bytes(beneficiaries[i].label)) == keccak256(bytes("investments"))) {
                    investments = beneficiaries[i].addr;
                }
            }
        }
    }
    
    // ========== Emergency Functions ==========
    
    /**
     * @notice Pause all operations
     */
    function pause() external onlyAdmin {
        _pause();
    }
    
    /**
     * @notice Unpause operations
     */
    function unpause() external onlyAdmin {
        _unpause();
    }
    
    /**
     * @notice Emergency token recovery
     * @param token Token to recover
     * @param to Recipient
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        if (to == address(0)) revert InvalidAddress();
        
        // Calculate total pending for this token
        uint256 totalPending = 0;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].isActive) {
                totalPending += pendingWithdrawals[beneficiaries[i].addr][token];
            }
        }
        totalPending += pendingWithdrawals[protocolFeeRecipient][token];
        
        // Only allow recovery of excess funds
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        uint256 excess = contractBalance > totalPending ? contractBalance - totalPending : 0;
        
        if (amount > excess) revert InsufficientBalance();
        
        IERC20(token).safeTransfer(to, amount);
    }
}
