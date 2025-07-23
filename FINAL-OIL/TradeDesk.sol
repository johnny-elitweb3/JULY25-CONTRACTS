// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TradeDesk
 * @author OIL Protocol
 * @notice Main contract for creating and managing OIL token offers with maturity bonuses
 * @dev Production-grade contract with comprehensive security features
 */
contract TradeDesk is ReentrancyGuard, Pausable, Ownable(msg.sender) {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== State Variables ====================
    
    IERC20Metadata public immutable oilToken;
    IOilCertificate public immutable certificateContract;
    IReserveVault public immutable reserveVault;
    
    uint256 private _offerIdCounter;
    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000
    uint256 public constant MIN_MATURITY_PERIOD = 1 days;
    uint256 public constant MAX_MATURITY_PERIOD = 1825 days; // 5 years
    uint256 public constant MAX_BONUS_PERCENTAGE = 10000; // 100% max bonus
    uint256 public constant BARREL_DECIMALS = 18; // OIL token decimals
    
    // Offer data
    mapping(uint256 => Offer) public offers;
    mapping(address => bool) public allowedPaymentTokens;
    mapping(address => uint256) public userTotalPurchases;
    
    // Emergency withdrawal delay
    uint256 public constant EMERGENCY_WITHDRAWAL_DELAY = 3 days;
    uint256 public emergencyWithdrawalRequestTime;
    address public emergencyWithdrawalRecipient;
    uint256 public emergencyWithdrawalAmount;
    
    // ==================== Structs ====================
    
    struct Offer {
        uint256 pricePerBarrelUSD;     // Price in payment token decimals (e.g., 6 for USDC)
        uint256 bonusPercentage;       // Bonus percentage (2000 = 20%)
        uint256 launchDate;            // When purchases can begin
        uint256 purchaseDeadline;      // When purchases end
        uint256 maturityPeriod;        // Time from purchase to maturity (seconds)
        uint256 maxSupply;             // Maximum barrels available
        uint256 soldAmount;            // Barrels sold so far
        uint256 reservedAmount;        // Total OIL reserved (including bonus)
        bool isActive;                 // Can be deactivated by admin
        address paymentToken;          // USDC, USDT, etc.
        string metadataURI;           // IPFS URI for offer details
    }
    
    // ==================== Events ====================
    
    event OfferCreated(
        uint256 indexed offerId,
        uint256 pricePerBarrelUSD,
        uint256 bonusPercentage,
        uint256 launchDate,
        uint256 purchaseDeadline,
        uint256 maturityPeriod,
        uint256 maxSupply,
        address paymentToken
    );
    
    event OfferPurchased(
        uint256 indexed offerId,
        address indexed purchaser,
        uint256 indexed certificateId,
        uint256 barrelsPurchased,
        uint256 bonusBarrels,
        uint256 paymentAmount,
        uint256 maturityDate
    );
    
    event CertificateRedeemed(
        uint256 indexed certificateId,
        address indexed redeemer,
        uint256 oilAmount,
        uint256 offerId
    );
    
    event OfferDeactivated(uint256 indexed offerId);
    event OfferMetadataUpdated(uint256 indexed offerId, string newURI);
    event PaymentTokenUpdated(address indexed token, bool allowed);
    event EmergencyWithdrawalRequested(address recipient, uint256 amount);
    event EmergencyWithdrawalExecuted(address recipient, uint256 amount);
    event EmergencyWithdrawalCancelled();
    
    // ==================== Errors ====================
    
    error InvalidPrice();
    error InvalidBonus();
    error InvalidDates();
    error InvalidMaturityPeriod();
    error InvalidSupply();
    error InvalidPaymentToken();
    error OfferNotActive();
    error OfferNotStarted();
    error OfferExpired();
    error InsufficientSupply();
    error InsufficientReserves();
    error InvalidPurchaseAmount();
    error PaymentFailed();
    error NotCertificateOwner();
    error CertificateNotMatured();
    error CertificateAlreadyRedeemed();
    error InvalidCertificate();
    error EmergencyWithdrawalNotReady();
    error NoEmergencyWithdrawalPending();
    error ZeroAddress();
    error InvalidBarrelAmount();
    
    // ==================== Constructor ====================
    
    /**
     * @notice Initialize the TradeDesk contract
     * @param _oilToken Address of the OIL token
     * @param _certificateContract Address of the OilCertificate NFT contract
     * @param _reserveVault Address of the ReserveVault contract
     * @param _initialPaymentTokens Array of initially allowed payment tokens
     */
    constructor(
        address _oilToken,
        address _certificateContract,
        address _reserveVault,
        address[] memory _initialPaymentTokens
    ) {
        if (_oilToken == address(0) || _certificateContract == address(0) || _reserveVault == address(0)) {
            revert ZeroAddress();
        }
        
        oilToken = IERC20Metadata(_oilToken);
        certificateContract = IOilCertificate(_certificateContract);
        reserveVault = IReserveVault(_reserveVault);
        
        // Set initial payment tokens
        for (uint256 i = 0; i < _initialPaymentTokens.length; i++) {
            if (_initialPaymentTokens[i] == address(0)) revert ZeroAddress();
            allowedPaymentTokens[_initialPaymentTokens[i]] = true;
            emit PaymentTokenUpdated(_initialPaymentTokens[i], true);
        }
    }
    
    // ==================== Admin Functions ====================
    
    /**
     * @notice Create a new offer
     * @param pricePerBarrelUSD Price per barrel in payment token units
     * @param bonusPercentage Bonus percentage at maturity (2000 = 20%)
     * @param launchDate Unix timestamp when purchases begin
     * @param purchaseDeadline Unix timestamp when purchases end
     * @param maturityPeriod Seconds from purchase to maturity
     * @param maxSupply Maximum barrels available for purchase
     * @param paymentToken Address of payment token (USDC, USDT, etc.)
     * @param metadataURI IPFS URI for additional offer metadata
     */
    function createOffer(
        uint256 pricePerBarrelUSD,
        uint256 bonusPercentage,
        uint256 launchDate,
        uint256 purchaseDeadline,
        uint256 maturityPeriod,
        uint256 maxSupply,
        address paymentToken,
        string calldata metadataURI
    ) external onlyOwner whenNotPaused {
        // Validate inputs
        if (pricePerBarrelUSD == 0) revert InvalidPrice();
        if (bonusPercentage > MAX_BONUS_PERCENTAGE) revert InvalidBonus();
        if (launchDate >= purchaseDeadline || launchDate < block.timestamp) revert InvalidDates();
        if (maturityPeriod < MIN_MATURITY_PERIOD || maturityPeriod > MAX_MATURITY_PERIOD) {
            revert InvalidMaturityPeriod();
        }
        if (maxSupply == 0) revert InvalidSupply();
        if (!allowedPaymentTokens[paymentToken]) revert InvalidPaymentToken();
        
        // Calculate total reserves needed (including bonus)
        uint256 totalReservesNeeded = maxSupply + (maxSupply * bonusPercentage / PERCENTAGE_BASE);
        
        // Check available reserves
        if (reserveVault.getAvailableReserves() < totalReservesNeeded) {
            revert InsufficientReserves();
        }
        
        // Reserve the OIL tokens
        reserveVault.reserveOil(totalReservesNeeded);
        
        // Create offer
        uint256 offerId = _offerIdCounter++;
        offers[offerId] = Offer({
            pricePerBarrelUSD: pricePerBarrelUSD,
            bonusPercentage: bonusPercentage,
            launchDate: launchDate,
            purchaseDeadline: purchaseDeadline,
            maturityPeriod: maturityPeriod,
            maxSupply: maxSupply,
            soldAmount: 0,
            reservedAmount: totalReservesNeeded,
            isActive: true,
            paymentToken: paymentToken,
            metadataURI: metadataURI
        });
        
        emit OfferCreated(
            offerId,
            pricePerBarrelUSD,
            bonusPercentage,
            launchDate,
            purchaseDeadline,
            maturityPeriod,
            maxSupply,
            paymentToken
        );
    }
    
    /**
     * @notice Deactivate an offer (emergency use)
     * @param offerId The offer to deactivate
     */
    function deactivateOffer(uint256 offerId) external onlyOwner {
        offers[offerId].isActive = false;
        emit OfferDeactivated(offerId);
    }
    
    /**
     * @notice Update offer metadata URI
     * @param offerId The offer to update
     * @param newURI New IPFS metadata URI
     */
    function updateOfferMetadata(uint256 offerId, string calldata newURI) external onlyOwner {
        offers[offerId].metadataURI = newURI;
        emit OfferMetadataUpdated(offerId, newURI);
    }
    
    /**
     * @notice Add or remove allowed payment tokens
     * @param token Token address
     * @param allowed Whether to allow this token
     */
    function setPaymentToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = allowed;
        emit PaymentTokenUpdated(token, allowed);
    }
    
    /**
     * @notice Pause all contract operations
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Request emergency withdrawal (time-locked)
     * @param recipient Address to receive OIL tokens
     * @param amount Amount of OIL to withdraw
     */
    function requestEmergencyWithdrawal(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        emergencyWithdrawalRequestTime = block.timestamp;
        emergencyWithdrawalRecipient = recipient;
        emergencyWithdrawalAmount = amount;
        emit EmergencyWithdrawalRequested(recipient, amount);
    }
    
    /**
     * @notice Execute emergency withdrawal after timelock
     */
    function executeEmergencyWithdrawal() external onlyOwner {
        if (emergencyWithdrawalRequestTime == 0) revert NoEmergencyWithdrawalPending();
        if (block.timestamp < emergencyWithdrawalRequestTime + EMERGENCY_WITHDRAWAL_DELAY) {
            revert EmergencyWithdrawalNotReady();
        }
        
        address recipient = emergencyWithdrawalRecipient;
        uint256 amount = emergencyWithdrawalAmount;
        
        // Reset state
        emergencyWithdrawalRequestTime = 0;
        emergencyWithdrawalRecipient = address(0);
        emergencyWithdrawalAmount = 0;
        
        // Execute withdrawal
        reserveVault.releaseOil(recipient, amount);
        emit EmergencyWithdrawalExecuted(recipient, amount);
    }
    
    /**
     * @notice Cancel pending emergency withdrawal
     */
    function cancelEmergencyWithdrawal() external onlyOwner {
        emergencyWithdrawalRequestTime = 0;
        emergencyWithdrawalRecipient = address(0);
        emergencyWithdrawalAmount = 0;
        emit EmergencyWithdrawalCancelled();
    }
    
    // ==================== User Functions ====================
    
    /**
     * @notice Purchase barrels from an offer
     * @param offerId The offer to purchase from
     * @param barrelAmount Number of barrels to purchase
     * @param maxPaymentAmount Maximum payment amount (slippage protection)
     */
    function purchaseOffer(
        uint256 offerId,
        uint256 barrelAmount,
        uint256 maxPaymentAmount
    ) external nonReentrant whenNotPaused {
        if (barrelAmount == 0) revert InvalidBarrelAmount();
        
        Offer storage offer = offers[offerId];
        
        // Validate offer
        if (!offer.isActive) revert OfferNotActive();
        if (block.timestamp < offer.launchDate) revert OfferNotStarted();
        if (block.timestamp > offer.purchaseDeadline) revert OfferExpired();
        if (offer.soldAmount + barrelAmount > offer.maxSupply) revert InsufficientSupply();
        
        // Calculate payment
        uint256 paymentAmount = (barrelAmount * offer.pricePerBarrelUSD * 10**BARREL_DECIMALS) / 10**BARREL_DECIMALS;
        
        // Adjust for payment token decimals
        uint256 paymentDecimals = IERC20Metadata(offer.paymentToken).decimals();
        if (paymentDecimals < 18) {
            paymentAmount = paymentAmount / 10**(18 - paymentDecimals);
        }
        
        // Slippage protection
        if (paymentAmount > maxPaymentAmount) revert InvalidPurchaseAmount();
        
        // Calculate bonus
        uint256 bonusBarrels = (barrelAmount * offer.bonusPercentage) / PERCENTAGE_BASE;
        uint256 maturityDate = block.timestamp + offer.maturityPeriod;
        
        // Update offer state
        offer.soldAmount += barrelAmount;
        
        // Transfer payment from user
        IERC20(offer.paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
        
        // Mint certificate NFT
        uint256 certificateId = certificateContract.mintCertificate(
            msg.sender,
            offerId,
            barrelAmount,
            bonusBarrels,
            maturityDate
        );
        
        // Update user stats
        userTotalPurchases[msg.sender] += barrelAmount;
        
        emit OfferPurchased(
            offerId,
            msg.sender,
            certificateId,
            barrelAmount,
            bonusBarrels,
            paymentAmount,
            maturityDate
        );
    }
    
    /**
     * @notice Redeem a matured certificate for OIL tokens
     * @param certificateId The NFT certificate to redeem
     */
    function redeemCertificate(uint256 certificateId) external nonReentrant whenNotPaused {
        // Verify ownership
        if (certificateContract.ownerOf(certificateId) != msg.sender) {
            revert NotCertificateOwner();
        }
        
        // Get certificate data
        (
            uint256 offerId,
            uint256 barrelsPurchased,
            uint256 bonusBarrels,
            ,
            uint256 maturityDate,
            bool isRedeemed
        ) = certificateContract.getCertificateData(certificateId);
        
        // Validate redemption
        if (isRedeemed) revert CertificateAlreadyRedeemed();
        if (block.timestamp < maturityDate) revert CertificateNotMatured();
        
        // Calculate total OIL to transfer
        uint256 totalOil = barrelsPurchased + bonusBarrels;
        
        // Burn the certificate
        certificateContract.burnCertificate(certificateId);
        
        // Transfer OIL tokens from vault
        reserveVault.releaseOil(msg.sender, totalOil);
        
        emit CertificateRedeemed(certificateId, msg.sender, totalOil, offerId);
    }
    
    // ==================== View Functions ====================
    
    /**
     * @notice Get detailed offer information
     * @param offerId The offer to query
     */
    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }
    
    /**
     * @notice Calculate purchase cost for a given amount of barrels
     * @param offerId The offer to calculate for
     * @param barrelAmount Number of barrels
     * @return paymentAmount Amount in payment token
     * @return bonusBarrels Bonus barrels at maturity
     */
    function calculatePurchase(uint256 offerId, uint256 barrelAmount) 
        external 
        view 
        returns (uint256 paymentAmount, uint256 bonusBarrels) 
    {
        Offer memory offer = offers[offerId];
        
        paymentAmount = (barrelAmount * offer.pricePerBarrelUSD * 10**BARREL_DECIMALS) / 10**BARREL_DECIMALS;
        
        // Adjust for payment token decimals
        uint256 paymentDecimals = IERC20Metadata(offer.paymentToken).decimals();
        if (paymentDecimals < 18) {
            paymentAmount = paymentAmount / 10**(18 - paymentDecimals);
        }
        
        bonusBarrels = (barrelAmount * offer.bonusPercentage) / PERCENTAGE_BASE;
    }
    
    /**
     * @notice Check if an offer is currently purchasable
     * @param offerId The offer to check
     */
    function isOfferPurchasable(uint256 offerId) external view returns (bool) {
        Offer memory offer = offers[offerId];
        return offer.isActive && 
               block.timestamp >= offer.launchDate && 
               block.timestamp <= offer.purchaseDeadline &&
               offer.soldAmount < offer.maxSupply;
    }
    
    /**
     * @notice Get remaining supply for an offer
     * @param offerId The offer to check
     */
    function getRemainingSupply(uint256 offerId) external view returns (uint256) {
        Offer memory offer = offers[offerId];
        return offer.maxSupply - offer.soldAmount;
    }
    
    /**
     * @notice Recover accidentally sent tokens (not OIL or payment tokens)
     * @param token Token to recover
     * @param amount Amount to recover
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == address(oilToken)) revert InvalidPaymentToken();
        IERC20(token).safeTransfer(owner(), amount);
    }
}

// ==================== Interfaces ====================

interface IOilCertificate {
    function mintCertificate(
        address to,
        uint256 offerId,
        uint256 barrels,
        uint256 bonus,
        uint256 maturityDate
    ) external returns (uint256);
    
    function burnCertificate(uint256 tokenId) external;
    
    function getCertificateData(uint256 tokenId) external view returns (
        uint256 offerId,
        uint256 barrelsPurchased,
        uint256 bonusBarrels,
        uint256 purchaseDate,
        uint256 maturityDate,
        bool isRedeemed
    );
    
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IReserveVault {
    function reserveOil(uint256 amount) external;
    function releaseOil(address to, uint256 amount) external;
    function getAvailableReserves() external view returns (uint256);
}
