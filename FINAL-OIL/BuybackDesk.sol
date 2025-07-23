// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title BuybackDesk
 * @author OIL Protocol
 * @notice Enables early redemption of OIL certificates at original purchase price
 * @dev World-class implementation with comprehensive security and flexibility
 */
contract BuybackDesk is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== Roles ====================
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    // ==================== Constants ====================
    
    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000
    uint256 public constant MAX_FEE = 1000; // 10% max fee
    uint256 public constant MIN_BUYBACK_DELAY = 1 days; // Minimum time after purchase
    uint256 public constant EMERGENCY_WITHDRAWAL_DELAY = 3 days;
    
    // ==================== State Variables ====================
    
    // Core contracts
    ITradeDesk public immutable tradeDesk;
    IOilCertificate public immutable certificateContract;
    IReserveVault public immutable reserveVault;
    
    // Buyback configuration
    uint256 public buybackFee = 300; // 3% default fee
    uint256 public minHoldingPeriod = 7 days; // Must hold for 7 days before selling
    bool public buybackEnabled = true;
    
    // Treasury management
    mapping(address => uint256) public treasuryBalances; // Stablecoin balances
    mapping(address => bool) public allowedPaymentTokens;
    
    // Buyback tracking
    mapping(uint256 => BuybackRecord) public buybackRecords;
    mapping(address => uint256[]) public userBuybackHistory;
    uint256 public totalBuybacks;
    uint256 public totalBuybackVolume; // Total USDC value bought back
    
    // Certificate pricing cache
    mapping(uint256 => CertificatePricing) public certificatePricing;
    
    // Fee distribution
    address public feeRecipient;
    mapping(address => uint256) public accumulatedFees;
    
    // Emergency withdrawal
    uint256 public emergencyWithdrawalRequestTime;
    address public emergencyWithdrawalToken;
    uint256 public emergencyWithdrawalAmount;
    
    // ==================== Structs ====================
    
    struct BuybackRecord {
        uint256 certificateId;
        address seller;
        uint256 buybackPrice;
        uint256 feeAmount;
        address paymentToken;
        uint256 timestamp;
        uint256 originalBarrels;
        uint256 originalBonus;
    }
    
    struct CertificatePricing {
        uint256 originalPaymentAmount;
        address originalPaymentToken;
        uint256 purchaseTimestamp;
        bool isRecorded;
    }
    
    struct BuybackQuote {
        uint256 buybackAmount;
        uint256 feeAmount;
        uint256 netAmount;
        address paymentToken;
        bool isEligible;
        string ineligibilityReason;
    }
    
    // ==================== Events ====================
    
    event BuybackExecuted(
        uint256 indexed certificateId,
        address indexed seller,
        uint256 buybackPrice,
        uint256 feeAmount,
        address paymentToken
    );
    
    event BuybackConfigUpdated(
        uint256 newFee,
        uint256 newMinHoldingPeriod,
        bool buybackEnabled
    );
    
    event TreasuryDeposit(
        address indexed token,
        address indexed depositor,
        uint256 amount
    );
    
    event TreasuryWithdrawal(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    
    event PaymentTokenUpdated(address indexed token, bool allowed);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesCollected(address indexed token, uint256 amount);
    event CertificatePricingRecorded(uint256 indexed certificateId, uint256 amount, address token);
    event EmergencyWithdrawalRequested(address token, uint256 amount);
    event EmergencyWithdrawalExecuted(address token, uint256 amount);
    event EmergencyWithdrawalCancelled();
    
    // ==================== Errors ====================
    
    error ZeroAddress();
    error ZeroAmount();
    error BuybackDisabled();
    error InvalidCertificate();
    error NotCertificateOwner();
    error CertificateMatured();
    error MinHoldingPeriodNotMet();
    error InsufficientTreasury();
    error InvalidPaymentToken();
    error PricingNotRecorded();
    error InvalidFee();
    error InvalidHoldingPeriod();
    error TransferFailed();
    error EmergencyDelayNotMet();
    error NoEmergencyWithdrawalPending();
    error CertificateAlreadyRedeemed();
    
    // ==================== Constructor ====================
    
    /**
     * @notice Initialize the BuybackDesk contract
     * @param _tradeDesk Address of TradeDesk contract
     * @param _certificateContract Address of OilCertificate contract
     * @param _reserveVault Address of ReserveVault contract
     * @param _admin Address of the admin
     * @param _feeRecipient Address to receive fees
     * @param _initialPaymentTokens Array of initially allowed payment tokens
     */
    constructor(
        address _tradeDesk,
        address _certificateContract,
        address _reserveVault,
        address _admin,
        address _feeRecipient,
        address[] memory _initialPaymentTokens
    ) {
        if (_tradeDesk == address(0) || 
            _certificateContract == address(0) || 
            _reserveVault == address(0) ||
            _admin == address(0) ||
            _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        
        tradeDesk = ITradeDesk(_tradeDesk);
        certificateContract = IOilCertificate(_certificateContract);
        reserveVault = IReserveVault(_reserveVault);
        feeRecipient = _feeRecipient;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        // Set initial payment tokens
        for (uint256 i = 0; i < _initialPaymentTokens.length; i++) {
            if (_initialPaymentTokens[i] != address(0)) {
                allowedPaymentTokens[_initialPaymentTokens[i]] = true;
                emit PaymentTokenUpdated(_initialPaymentTokens[i], true);
            }
        }
    }
    
    // ==================== Admin Functions ====================
    
    /**
     * @notice Update buyback configuration
     * @param _buybackFee New fee percentage (300 = 3%)
     * @param _minHoldingPeriod Minimum days before buyback allowed
     * @param _enabled Whether buybacks are enabled
     */
    function updateBuybackConfig(
        uint256 _buybackFee,
        uint256 _minHoldingPeriod,
        bool _enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_buybackFee > MAX_FEE) revert InvalidFee();
        if (_minHoldingPeriod < MIN_BUYBACK_DELAY) revert InvalidHoldingPeriod();
        
        buybackFee = _buybackFee;
        minHoldingPeriod = _minHoldingPeriod;
        buybackEnabled = _enabled;
        
        emit BuybackConfigUpdated(_buybackFee, _minHoldingPeriod, _enabled);
    }
    
    /**
     * @notice Update fee recipient
     * @param _newRecipient New fee recipient address
     */
    function updateFeeRecipient(address _newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newRecipient == address(0)) revert ZeroAddress();
        
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        
        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }
    
    /**
     * @notice Add or remove allowed payment tokens
     * @param token Token address
     * @param allowed Whether to allow this token
     */
    function setPaymentToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = allowed;
        emit PaymentTokenUpdated(token, allowed);
    }
    
    /**
     * @notice Pause buyback operations
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause buyback operations
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    // ==================== Treasury Functions ====================
    
    /**
     * @notice Deposit stablecoins to treasury for buybacks
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToTreasury(address token, uint256 amount) 
        external 
        nonReentrant
        whenNotPaused
    {
        if (!allowedPaymentTokens[token]) revert InvalidPaymentToken();
        if (amount == 0) revert ZeroAmount();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        treasuryBalances[token] += amount;
        
        emit TreasuryDeposit(token, msg.sender, amount);
    }
    
    /**
     * @notice Withdraw from treasury (admin only)
     * @param token Token to withdraw
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFromTreasury(
        address token,
        address recipient,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (treasuryBalances[token] < amount) revert InsufficientTreasury();
        
        treasuryBalances[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
        
        emit TreasuryWithdrawal(token, recipient, amount);
    }
    
    /**
     * @notice Request emergency withdrawal (time-locked)
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function requestEmergencyWithdrawal(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyWithdrawalRequestTime = block.timestamp;
        emergencyWithdrawalToken = token;
        emergencyWithdrawalAmount = amount;
        
        emit EmergencyWithdrawalRequested(token, amount);
    }
    
    /**
     * @notice Execute emergency withdrawal after delay
     */
    function executeEmergencyWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (emergencyWithdrawalRequestTime == 0) revert NoEmergencyWithdrawalPending();
        if (block.timestamp < emergencyWithdrawalRequestTime + EMERGENCY_WITHDRAWAL_DELAY) {
            revert EmergencyDelayNotMet();
        }
        
        address token = emergencyWithdrawalToken;
        uint256 amount = emergencyWithdrawalAmount;
        
        // Reset state
        emergencyWithdrawalRequestTime = 0;
        emergencyWithdrawalToken = address(0);
        emergencyWithdrawalAmount = 0;
        
        // Execute withdrawal
        if (treasuryBalances[token] >= amount) {
            treasuryBalances[token] -= amount;
        }
        
        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawalExecuted(token, amount);
    }
    
    /**
     * @notice Cancel emergency withdrawal
     */
    function cancelEmergencyWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyWithdrawalRequestTime = 0;
        emergencyWithdrawalToken = address(0);
        emergencyWithdrawalAmount = 0;
        
        emit EmergencyWithdrawalCancelled();
    }
    
    // ==================== Pricing Functions ====================
    
    /**
     * @notice Record certificate pricing (called by TradeDesk on purchase)
     * @param certificateId Certificate ID
     * @param paymentAmount Original payment amount
     * @param paymentToken Original payment token
     */
    function recordCertificatePricing(
        uint256 certificateId,
        uint256 paymentAmount,
        address paymentToken
    ) external {
        // Only TradeDesk can record pricing
        if (msg.sender != address(tradeDesk)) revert ZeroAddress();
        
        certificatePricing[certificateId] = CertificatePricing({
            originalPaymentAmount: paymentAmount,
            originalPaymentToken: paymentToken,
            purchaseTimestamp: block.timestamp,
            isRecorded: true
        });
        
        emit CertificatePricingRecorded(certificateId, paymentAmount, paymentToken);
    }
    
    // ==================== Buyback Functions ====================
    
    /**
     * @notice Execute buyback of certificate
     * @param certificateId Certificate to sell back
     * @param minAmount Minimum amount to accept (slippage protection)
     */
    function executeBuyback(
        uint256 certificateId,
        uint256 minAmount
    ) external nonReentrant whenNotPaused {
        if (!buybackEnabled) revert BuybackDisabled();
        
        // Verify ownership
        if (certificateContract.ownerOf(certificateId) != msg.sender) {
            revert NotCertificateOwner();
        }
        
        // Get certificate data (using underscore for unused variables)
        (
            ,  // offerId (unused)
            uint256 barrelsPurchased,
            uint256 bonusBarrels,
            ,
            uint256 maturityDate,
            bool isRedeemed
        ) = certificateContract.getCertificateData(certificateId);
        
        if (isRedeemed) revert CertificateAlreadyRedeemed();
        
        // Check if already matured
        if (block.timestamp >= maturityDate) revert CertificateMatured();
        
        // Get pricing info
        CertificatePricing memory pricing = certificatePricing[certificateId];
        if (!pricing.isRecorded) revert PricingNotRecorded();
        
        // Check holding period
        if (block.timestamp < pricing.purchaseTimestamp + minHoldingPeriod) {
            revert MinHoldingPeriodNotMet();
        }
        
        // Calculate buyback amount
        uint256 feeAmount = (pricing.originalPaymentAmount * buybackFee) / PERCENTAGE_BASE;
        uint256 netAmount = pricing.originalPaymentAmount - feeAmount;
        
        // Slippage protection
        if (netAmount < minAmount) revert InsufficientTreasury();
        
        // Check treasury balance
        if (treasuryBalances[pricing.originalPaymentToken] < pricing.originalPaymentAmount) {
            revert InsufficientTreasury();
        }
        
        // Update treasury
        treasuryBalances[pricing.originalPaymentToken] -= netAmount;
        accumulatedFees[pricing.originalPaymentToken] += feeAmount;
        
        // Record buyback
        buybackRecords[totalBuybacks] = BuybackRecord({
            certificateId: certificateId,
            seller: msg.sender,
            buybackPrice: pricing.originalPaymentAmount,
            feeAmount: feeAmount,
            paymentToken: pricing.originalPaymentToken,
            timestamp: block.timestamp,
            originalBarrels: barrelsPurchased,
            originalBonus: bonusBarrels
        });
        
        userBuybackHistory[msg.sender].push(totalBuybacks);
        totalBuybacks++;
        totalBuybackVolume += pricing.originalPaymentAmount;
        
        // Transfer certificate to this contract
        certificateContract.safeTransferFrom(msg.sender, address(this), certificateId);
        
        // Burn the certificate
        certificateContract.burnCertificate(certificateId);
        
        // Unreserve the OIL in the vault
        // This ensures the OIL (including bonus) becomes available again
        uint256 totalOilAmount = barrelsPurchased + bonusBarrels;
        reserveVault.unreserveOil(totalOilAmount);
        
        // Pay the seller
        IERC20(pricing.originalPaymentToken).safeTransfer(msg.sender, netAmount);
        
        emit BuybackExecuted(
            certificateId,
            msg.sender,
            pricing.originalPaymentAmount,
            feeAmount,
            pricing.originalPaymentToken
        );
    }
    
    /**
     * @notice Get buyback quote for a certificate
     * @param certificateId Certificate to quote
     * @return quote Buyback quote details
     */
    function getBuybackQuote(uint256 certificateId) 
        external 
        view 
        returns (BuybackQuote memory quote) 
    {
        // Check if buyback is enabled
        if (!buybackEnabled) {
            return BuybackQuote({
                buybackAmount: 0,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: address(0),
                isEligible: false,
                ineligibilityReason: "Buybacks disabled"
            });
        }
        
        // Check ownership
        address owner;
        try certificateContract.ownerOf(certificateId) returns (address _owner) {
            owner = _owner;
        } catch {
            return BuybackQuote({
                buybackAmount: 0,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: address(0),
                isEligible: false,
                ineligibilityReason: "Invalid certificate"
            });
        }
        
        // Get certificate data
        (,,,, uint256 maturityDate, bool isRedeemed) = certificateContract.getCertificateData(certificateId);
        
        if (isRedeemed) {
            return BuybackQuote({
                buybackAmount: 0,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: address(0),
                isEligible: false,
                ineligibilityReason: "Certificate already redeemed"
            });
        }
        
        // Check if matured
        if (block.timestamp >= maturityDate) {
            return BuybackQuote({
                buybackAmount: 0,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: address(0),
                isEligible: false,
                ineligibilityReason: "Certificate matured"
            });
        }
        
        // Get pricing
        CertificatePricing memory pricing = certificatePricing[certificateId];
        if (!pricing.isRecorded) {
            return BuybackQuote({
                buybackAmount: 0,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: address(0),
                isEligible: false,
                ineligibilityReason: "Pricing not recorded"
            });
        }
        
        // Check holding period
        if (block.timestamp < pricing.purchaseTimestamp + minHoldingPeriod) {
            uint256 timeRemaining = (pricing.purchaseTimestamp + minHoldingPeriod) - block.timestamp;
            return BuybackQuote({
                buybackAmount: pricing.originalPaymentAmount,
                feeAmount: 0,
                netAmount: 0,
                paymentToken: pricing.originalPaymentToken,
                isEligible: false,
                ineligibilityReason: string(abi.encodePacked(
                    "Holding period not met. Time remaining: ",
                    _toString(timeRemaining / 1 days),
                    " days"
                ))
            });
        }
        
        // Calculate amounts
        uint256 feeAmount = (pricing.originalPaymentAmount * buybackFee) / PERCENTAGE_BASE;
        uint256 netAmount = pricing.originalPaymentAmount - feeAmount;
        
        // Check treasury balance
        if (treasuryBalances[pricing.originalPaymentToken] < pricing.originalPaymentAmount) {
            return BuybackQuote({
                buybackAmount: pricing.originalPaymentAmount,
                feeAmount: feeAmount,
                netAmount: netAmount,
                paymentToken: pricing.originalPaymentToken,
                isEligible: false,
                ineligibilityReason: "Insufficient treasury"
            });
        }
        
        return BuybackQuote({
            buybackAmount: pricing.originalPaymentAmount,
            feeAmount: feeAmount,
            netAmount: netAmount,
            paymentToken: pricing.originalPaymentToken,
            isEligible: true,
            ineligibilityReason: ""
        });
    }
    
    // ==================== Fee Management ====================
    
    /**
     * @notice Collect accumulated fees
     * @param token Token to collect fees for
     */
    function collectFees(address token) external nonReentrant {
        uint256 amount = accumulatedFees[token];
        if (amount == 0) revert ZeroAmount();
        
        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);
        
        emit FeesCollected(token, amount);
    }
    
    // ==================== View Functions ====================
    
    /**
     * @notice Get user's buyback history
     * @param user User address
     * @return recordIds Array of buyback record IDs
     */
    function getUserBuybackHistory(address user) external view returns (uint256[] memory) {
        return userBuybackHistory[user];
    }
    
    /**
     * @notice Get detailed buyback records for a user
     * @param user User address
     * @return records Array of buyback records
     */
    function getUserBuybackRecords(address user) 
        external 
        view 
        returns (BuybackRecord[] memory records) 
    {
        uint256[] memory recordIds = userBuybackHistory[user];
        records = new BuybackRecord[](recordIds.length);
        
        for (uint256 i = 0; i < recordIds.length; i++) {
            records[i] = buybackRecords[recordIds[i]];
        }
    }
    
    /**
     * @notice Get treasury balance for a token
     * @param token Token to check
     * @return balance Treasury balance
     */
    function getTreasuryBalance(address token) external view returns (uint256) {
        return treasuryBalances[token];
    }
    
    /**
     * @notice Get accumulated fees for a token
     * @param token Token to check
     * @return fees Accumulated fees
     */
    function getAccumulatedFees(address token) external view returns (uint256) {
        return accumulatedFees[token];
    }
    
    /**
     * @notice Check if certificate is eligible for buyback
     * @param certificateId Certificate to check
     * @return eligible Whether eligible for buyback
     * @return reason Reason if not eligible
     */
    function isCertificateEligible(uint256 certificateId) 
        external 
        view 
        returns (bool eligible, string memory reason) 
    {
        BuybackQuote memory quote = this.getBuybackQuote(certificateId);
        return (quote.isEligible, quote.ineligibilityReason);
    }
    
    /**
     * @notice Get time until certificate can be bought back
     * @param certificateId Certificate to check
     * @return timeRemaining Seconds until eligible (0 if already eligible)
     */
    function getTimeUntilBuybackEligible(uint256 certificateId) 
        external 
        view 
        returns (uint256 timeRemaining) 
    {
        CertificatePricing memory pricing = certificatePricing[certificateId];
        if (!pricing.isRecorded) return 0;
        
        uint256 eligibleTime = pricing.purchaseTimestamp + minHoldingPeriod;
        if (block.timestamp >= eligibleTime) return 0;
        
        return eligibleTime - block.timestamp;
    }
    
    /**
     * @notice Get complete buyback statistics
     * @return totalCount Total number of buybacks
     * @return totalVolume Total USD value bought back
     * @return enabledStatus Whether buybacks are currently enabled
     */
    function getBuybackStats() 
        external 
        view 
        returns (
            uint256 totalCount,
            uint256 totalVolume,
            bool enabledStatus
        ) 
    {
        return (totalBuybacks, totalBuybackVolume, buybackEnabled);
    }
    
    // ==================== Internal Functions ====================
    
    /**
     * @notice Convert uint to string
     * @param value Value to convert
     * @return String representation
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    /**
     * @notice Handle receipt of NFT
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
    /**
     * @notice Recover accidentally sent tokens (not payment tokens)
     * @param token Token to recover
     * @param amount Amount to recover
     */
    function recoverToken(address token, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (allowedPaymentTokens[token]) revert InvalidPaymentToken();
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}

// ==================== Interfaces ====================

interface ITradeDesk {
    function getOffer(uint256 offerId) external view returns (
        uint256 pricePerBarrelUSD,
        uint256 bonusPercentage,
        uint256 launchDate,
        uint256 purchaseDeadline,
        uint256 maturityPeriod,
        uint256 maxSupply,
        uint256 soldAmount,
        uint256 reservedAmount,
        bool isActive,
        address paymentToken,
        string memory metadataURI
    );
}

interface IOilCertificate {
    function ownerOf(uint256 tokenId) external view returns (address);
    
    function getCertificateData(uint256 tokenId) external view returns (
        uint256 offerId,
        uint256 barrelsPurchased,
        uint256 bonusBarrels,
        uint256 purchaseDate,
        uint256 maturityDate,
        bool isRedeemed
    );
    
    function burnCertificate(uint256 tokenId) external;
    
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IReserveVault {
    function unreserveOil(uint256 amount) external;
}
