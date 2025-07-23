// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @dev Forward declaration of DonationCampaign contract
 */
contract DonationCampaign {
    constructor(
        address _ngo,
        address _registry,
        address[] memory _beneficiaries,
        uint256[] memory _percentages,
        string memory _ipfsHash,
        address _feeToken,
        uint256 _platformFeeRate,
        address _partnerNGO
    ) {}
}

interface IDonationCampaign {
    function initialize(
        bool recurringEnabled,
        bool customNFTEnabled,
        uint32 maxTokens
    ) external;
}

/**
 * @title CIFIRegistry
 * @author CIFI Foundation
 * @notice Central registry and control plane for the CIFI GIVE donation ecosystem
 * @dev Enhanced version with partner NGO support for 100% charitable model
 * 
 * Key Features:
 * - NGO registration and verification workflow
 * - Multi-tier subscription model with fee management
 * - Campaign deployment and lifecycle management
 * - Partner NGO system where platform fees support charity
 * - Event-driven analytics for off-chain processing
 * - Integration with REFI ecosystem
 * - Professional access control and emergency procedures
 */
contract CIFIRegistry is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ============ Custom Errors ============
    error InvalidAddress();
    error InvalidAmount();
    error InvalidParameters();
    error InvalidTier();
    error InvalidStatus();
    error InvalidSignature();
    error AlreadyRegistered();
    error NotRegistered();
    error ApplicationPending();
    error ApplicationNotFound();
    error InsufficientPayment();
    error TierExpired();
    error CampaignLimitExceeded();
    error Unauthorized();
    error DeadlineExpired();
    error ArrayLengthMismatch();
    error StringTooLong();
    error TransferFailed();
    error ContractPaused();
    error InvalidMerkleProof();
    error PartnerNGONotSet();
    error CannotSetSelfAsPartner();

    // ============ Constants ============
    uint256 private constant MAX_STRING_LENGTH = 256;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant TIER_DURATION = 365 days;
    uint256 private constant APPLICATION_EXPIRY = 30 days;
    uint256 private constant FEE_PRECISION = 10000; // 100% = 10000
    uint256 private constant MAX_TIERS = 5;
    
    // Role definitions
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PARTNER_MANAGER_ROLE = keccak256("PARTNER_MANAGER_ROLE");

    // ============ Structs ============
    
    /**
     * @dev Packed struct for gas efficiency - fits in 3 storage slots
     */
    struct NGORecord {
        address account;           // Slot 1: 20 bytes
        uint64 registeredAt;      // Slot 1: 8 bytes  
        uint32 tier;              // Slot 1: 4 bytes
        uint64 tierExpiresAt;     // Slot 2: 8 bytes
        uint32 campaignCount;     // Slot 2: 4 bytes
        uint32 lifetimeCampaigns; // Slot 2: 4 bytes
        uint8 status;             // Slot 2: 1 byte (0=none, 1=active, 2=suspended, 3=blacklisted)
        bool isVerified;          // Slot 2: 1 byte
        uint128 totalRaised;      // Slot 2: 16 bytes
        string ipfsHash;          // Slot 3: 32 bytes (all metadata stored on IPFS)
    }

    /**
     * @dev Tier configuration with features and limits
     */
    struct TierConfig {
        uint128 deploymentFee;    // Deployment fee in fee token
        uint128 annualFee;        // Annual subscription fee
        uint32 maxCampaigns;      // Maximum active campaigns
        uint32 maxBeneficiaries;  // Maximum beneficiaries per campaign
        uint32 maxTokens;         // Maximum accepted tokens per campaign
        bool recurringEnabled;    // Whether recurring donations are enabled
        bool customNFTEnabled;    // Whether custom NFT receipts are enabled
        string name;              // Tier name for display
    }

    /**
     * @dev Pending application data
     */
    struct Application {
        address applicant;        // Who applied
        uint64 submittedAt;       // When they applied
        uint32 requestedTier;     // What tier they want
        uint8 status;             // 0=pending, 1=approved, 2=rejected
        string ipfsHash;          // Application data on IPFS
    }

    /**
     * @dev Campaign registration data
     */
    struct CampaignRecord {
        address ngo;              // NGO owner
        uint64 deployedAt;        // Deployment timestamp
        uint32 beneficiaryCount;  // Number of beneficiaries
        bool isActive;            // Whether campaign is active
        string ipfsHash;          // Campaign metadata on IPFS
    }

    /**
     * @dev Platform-wide statistics for dashboard
     */
    struct PlatformStats {
        uint256 totalNGOs;
        uint256 verifiedNGOs;
        uint256 totalCampaigns;
        uint256 activeCampaigns;
        uint256 totalDonations;
        uint256 platformFeesCollected;
        uint256 partnerNGOContributions;
    }

    // ============ State Variables ============
    
    // Platform configuration
    address public feeToken;
    address public treasury;
    address public refiToken;
    address public refiTreasury;
    address public partnerNGO;  // Partner NGO that receives platform fees (e.g., St. Jude's)
    
    // Fee configuration
    uint256 public platformFeeRate = 100; // 1% = 100
    uint256 public referralFeeRate = 50;  // 0.5% = 50
    
    // NGO registry
    mapping(address => NGORecord) public ngoRecords;
    mapping(uint256 => Application) public applications;
    mapping(address => uint256) public activeApplicationId;
    
    // Campaign registry
    mapping(address => CampaignRecord) public campaignRecords;
    mapping(address => EnumerableSet.AddressSet) private ngoCampaigns;
    
    // Tier configuration
    mapping(uint256 => TierConfig) public tierConfigs;
    
    // Platform statistics
    PlatformStats public platformStats;
    
    // Counters and tracking
    uint256 public nextApplicationId = 1;
    EnumerableSet.AddressSet private registeredNGOs;
    EnumerableSet.AddressSet private verifiedNGOs;
    EnumerableSet.AddressSet private allCampaigns;
    EnumerableSet.UintSet private pendingApplications;
    
    // Referral system
    mapping(address => address) public referredBy;
    mapping(address => uint256) public referralRewards;
    
    // Merkle root for batch operations
    bytes32 public merkleRoot;

    // Partner NGO tracking
    mapping(address => uint256) public partnerNGOContributions; // Track contributions by token

    // ============ Events ============
    
    // Application events
    event ApplicationSubmitted(uint256 indexed applicationId, address indexed applicant, uint32 tier);
    event ApplicationProcessed(uint256 indexed applicationId, address indexed applicant, bool approved, address processor);
    
    // NGO events  
    event NGORegistered(address indexed ngo, uint32 tier, string ipfsHash);
    event NGOVerified(address indexed ngo, address indexed verifier);
    event NGOStatusChanged(address indexed ngo, uint8 oldStatus, uint8 newStatus);
    event NGOTierRenewed(address indexed ngo, uint32 tier, uint64 expiresAt);
    
    // Campaign events
    event CampaignDeployed(address indexed campaign, address indexed ngo, string ipfsHash);
    event CampaignStatusChanged(address indexed campaign, bool isActive);
    
    // Platform events
    event TierConfigured(uint32 indexed tier, string name, uint128 deploymentFee, uint128 annualFee);
    event PlatformFeeUpdated(uint256 oldRate, uint256 newRate);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event PartnerNGOUpdated(address indexed oldPartner, address indexed newPartner);
    
    // Analytics events
    event DonationTracked(address indexed campaign, address indexed donor, address token, uint256 amount, uint256 timestamp);
    event MetricUpdated(address indexed entity, string metricType, uint256 value, uint256 timestamp);
    event PartnerNGOContribution(address indexed partnerNGO, address indexed token, uint256 amount, address indexed fromCampaign);

    // ============ Modifiers ============
    
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    
    modifier validString(string memory str) {
        if (bytes(str).length == 0 || bytes(str).length > MAX_STRING_LENGTH) revert StringTooLong();
        _;
    }
    
    modifier onlyRegisteredNGO() {
        if (!registeredNGOs.contains(msg.sender)) revert NotRegistered();
        if (ngoRecords[msg.sender].status != 1) revert InvalidStatus();
        _;
    }
    
    modifier onlyActiveTier() {
        NGORecord storage ngo = ngoRecords[msg.sender];
        if (block.timestamp > ngo.tierExpiresAt) revert TierExpired();
        _;
    }

    // ============ Constructor ============
    
    constructor(
        address _feeToken,
        address _treasury,
        address _partnerNGO
    ) validAddress(_feeToken) validAddress(_treasury) {
        feeToken = _feeToken;
        treasury = _treasury;
        
        // Set partner NGO if provided (can be zero initially)
        if (_partnerNGO != address(0)) {
            partnerNGO = _partnerNGO;
        }
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PARTNER_MANAGER_ROLE, msg.sender);
        _initializeTiers();
    }

    // ============ Partner NGO Management ============
    
    /**
     * @notice Set the partner NGO that receives platform fees
     * @param _partnerNGO Address of the partner NGO (e.g., St. Jude's)
     * @dev This creates a 100% charitable model where even platform fees go to charity
     */
    function setPartnerNGO(address _partnerNGO) external onlyRole(PARTNER_MANAGER_ROLE) validAddress(_partnerNGO) {
        // Ensure the partner NGO is registered and active
        if (!registeredNGOs.contains(_partnerNGO)) revert NotRegistered();
        if (ngoRecords[_partnerNGO].status != 1) revert InvalidStatus();
        
        address oldPartner = partnerNGO;
        partnerNGO = _partnerNGO;
        
        emit PartnerNGOUpdated(oldPartner, _partnerNGO);
    }
    
    /**
     * @notice Get the current partner NGO address
     * @return The address of the partner NGO that receives platform fees
     */
    function getPartnerNGO() external view returns (address) {
        return partnerNGO;
    }
    
    /**
     * @notice Track contribution to partner NGO (called by campaigns)
     * @param token Token address (address(0) for native)
     * @param amount Amount contributed
     */
    function trackPartnerNGOContribution(address token, uint256 amount) external {
        // Only campaigns can call this
        if (campaignRecords[msg.sender].ngo == address(0)) revert Unauthorized();
        
        partnerNGOContributions[token] += amount;
        platformStats.partnerNGOContributions += amount;
        
        emit PartnerNGOContribution(partnerNGO, token, amount, msg.sender);
        emit MetricUpdated(partnerNGO, "platform_fee_received", amount, block.timestamp);
    }

    // ============ Application Functions ============
    
    /**
     * @notice Submit an application to become a registered NGO
     * @param tier Requested tier level (1-5)
     * @param ipfsHash IPFS hash containing application details
     * @param referrer Optional referrer address for rewards
     */
    function submitApplication(
        uint32 tier,
        string calldata ipfsHash,
        address referrer
    ) external whenNotPaused validString(ipfsHash) {
        if (tier == 0 || tier > MAX_TIERS) revert InvalidTier();
        if (registeredNGOs.contains(msg.sender)) revert AlreadyRegistered();
        if (activeApplicationId[msg.sender] != 0) revert ApplicationPending();
        
        uint256 applicationId = nextApplicationId++;
        
        applications[applicationId] = Application({
            applicant: msg.sender,
            submittedAt: uint64(block.timestamp),
            requestedTier: tier,
            status: 0,
            ipfsHash: ipfsHash
        });
        
        activeApplicationId[msg.sender] = applicationId;
        pendingApplications.add(applicationId);
        
        if (referrer != address(0) && referrer != msg.sender) {
            referredBy[msg.sender] = referrer;
        }
        
        emit ApplicationSubmitted(applicationId, msg.sender, tier);
    }
    
    /**
     * @notice Process a pending application
     * @param applicationId Application to process
     * @param approved Whether to approve or reject
     * @param ipfsHash Updated IPFS hash with review notes
     */
    function processApplication(
        uint256 applicationId,
        bool approved,
        string calldata ipfsHash
    ) external onlyRole(VERIFIER_ROLE) validString(ipfsHash) {
        _processApplication(applicationId, approved, ipfsHash);
    }
    
    /**
     * @notice Batch process multiple applications
     * @param applicationIds Array of application IDs
     * @param approvals Array of approval decisions
     * @param ipfsHashes Array of IPFS hashes with review notes
     */
    function batchProcessApplications(
        uint256[] calldata applicationIds,
        bool[] calldata approvals,
        string[] calldata ipfsHashes
    ) external onlyRole(VERIFIER_ROLE) {
        uint256 length = applicationIds.length;
        if (length != approvals.length || length != ipfsHashes.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i; i < length;) {
            if (bytes(ipfsHashes[i]).length == 0 || bytes(ipfsHashes[i]).length > MAX_STRING_LENGTH) {
                revert StringTooLong();
            }
            _processApplication(applicationIds[i], approvals[i], ipfsHashes[i]);
            unchecked { ++i; }
        }
    }

    // ============ NGO Management Functions ============
    
    /**
     * @notice Renew NGO tier subscription
     * @param tier Tier to renew (can be different from current)
     */
    function renewTier(uint32 tier) external nonReentrant onlyRegisteredNGO {
        if (tier == 0 || tier > MAX_TIERS) revert InvalidTier();
        
        NGORecord storage ngo = ngoRecords[msg.sender];
        TierConfig memory config = tierConfigs[tier];
        
        // Collect annual fee
        if (config.annualFee > 0) {
            IERC20(feeToken).safeTransferFrom(msg.sender, treasury, config.annualFee);
            platformStats.platformFeesCollected += config.annualFee;
            
            // Process referral rewards
            _processReferralReward(msg.sender, config.annualFee);
        }
        
        // Update tier
        ngo.tier = tier;
        ngo.tierExpiresAt = uint64(block.timestamp + TIER_DURATION);
        
        emit NGOTierRenewed(msg.sender, tier, ngo.tierExpiresAt);
    }
    
    /**
     * @notice Update NGO metadata
     * @param ipfsHash New IPFS hash containing updated metadata
     */
    function updateNGOMetadata(string calldata ipfsHash) external onlyRegisteredNGO validString(ipfsHash) {
        ngoRecords[msg.sender].ipfsHash = ipfsHash;
        emit MetricUpdated(msg.sender, "metadata_updated", 1, block.timestamp);
    }
    
    /**
     * @notice Verify an NGO (admin function)
     * @param ngo Address to verify
     */
    function verifyNGO(address ngo) external onlyRole(VERIFIER_ROLE) {
        NGORecord storage record = ngoRecords[ngo];
        if (record.account == address(0)) revert NotRegistered();
        if (record.isVerified) revert InvalidStatus();
        
        record.isVerified = true;
        verifiedNGOs.add(ngo);
        platformStats.verifiedNGOs++;
        
        emit NGOVerified(ngo, msg.sender);
    }
    
    /**
     * @notice Update NGO status (admin function)
     * @param ngo NGO address
     * @param newStatus New status (1=active, 2=suspended, 3=blacklisted)
     */
    function updateNGOStatus(address ngo, uint8 newStatus) external onlyRole(OPERATOR_ROLE) {
        NGORecord storage record = ngoRecords[ngo];
        if (record.account == address(0)) revert NotRegistered();
        if (newStatus == 0 || newStatus > 3) revert InvalidStatus();
        
        uint8 oldStatus = record.status;
        record.status = newStatus;
        
        emit NGOStatusChanged(ngo, oldStatus, newStatus);
    }

    // ============ Campaign Deployment Functions ============
    
    /**
     * @notice Deploy a new donation campaign
     * @param beneficiaries Array of beneficiary addresses
     * @param percentages Array of distribution percentages (must sum to 10000)
     * @param ipfsHash IPFS hash containing campaign metadata
     * @return campaign Address of deployed campaign
     */
    function deployCampaign(
        address[] calldata beneficiaries,
        uint256[] calldata percentages,
        string calldata ipfsHash
    ) external nonReentrant whenNotPaused onlyRegisteredNGO onlyActiveTier validString(ipfsHash) returns (address campaign) {
        // Ensure partner NGO is set for 100% charitable model
        if (partnerNGO == address(0)) revert PartnerNGONotSet();
        
        NGORecord storage ngo = ngoRecords[msg.sender];
        TierConfig memory config = tierConfigs[ngo.tier];
        
        // Validate limits
        if (ngo.campaignCount >= config.maxCampaigns) revert CampaignLimitExceeded();
        if (beneficiaries.length != percentages.length) revert ArrayLengthMismatch();
        if (beneficiaries.length > config.maxBeneficiaries) revert InvalidParameters();
        
        // Validate percentages sum to 100%
        uint256 totalPercentage;
        for (uint256 i; i < percentages.length;) {
            totalPercentage += percentages[i];
            unchecked { ++i; }
        }
        if (totalPercentage != FEE_PRECISION) revert InvalidParameters();
        
        // Collect deployment fee
        if (config.deploymentFee > 0) {
            IERC20(feeToken).safeTransferFrom(msg.sender, treasury, config.deploymentFee);
            platformStats.platformFeesCollected += config.deploymentFee;
            _processReferralReward(msg.sender, config.deploymentFee);
        }
        
        // Deploy campaign
        campaign = _deployCampaign(msg.sender, beneficiaries, percentages, ipfsHash);
        
        // Register campaign
        campaignRecords[campaign] = CampaignRecord({
            ngo: msg.sender,
            deployedAt: uint64(block.timestamp),
            beneficiaryCount: uint32(beneficiaries.length),
            isActive: true,
            ipfsHash: ipfsHash
        });
        
        ngoCampaigns[msg.sender].add(campaign);
        allCampaigns.add(campaign);
        
        // Update statistics
        ngo.campaignCount++;
        ngo.lifetimeCampaigns++;
        platformStats.totalCampaigns++;
        platformStats.activeCampaigns++;
        
        emit CampaignDeployed(campaign, msg.sender, ipfsHash);
    }
    
    /**
     * @notice Update campaign status
     * @param campaign Campaign address
     * @param isActive New active status
     */
    function updateCampaignStatus(address campaign, bool isActive) external onlyRegisteredNGO {
        CampaignRecord storage record = campaignRecords[campaign];
        if (record.ngo != msg.sender) revert Unauthorized();
        
        if (record.isActive && !isActive) {
            platformStats.activeCampaigns--;
            ngoRecords[msg.sender].campaignCount--;
        } else if (!record.isActive && isActive) {
            platformStats.activeCampaigns++;
            ngoRecords[msg.sender].campaignCount++;
        }
        
        record.isActive = isActive;
        emit CampaignStatusChanged(campaign, isActive);
    }

    // ============ Analytics Functions ============
    
    /**
     * @notice Track a donation for analytics (called by campaigns)
     * @param donor Donor address
     * @param token Token address (address(0) for native)
     * @param amount Donation amount
     */
    function trackDonation(address donor, address token, uint256 amount) external {
        CampaignRecord memory record = campaignRecords[msg.sender];
        if (record.ngo == address(0)) revert Unauthorized();
        
        platformStats.totalDonations++;
        ngoRecords[record.ngo].totalRaised += uint128(amount);
        
        emit DonationTracked(msg.sender, donor, token, amount, block.timestamp);
        emit MetricUpdated(record.ngo, "donation_received", amount, block.timestamp);
    }
    
    /**
     * @notice Submit metrics via merkle proof (for off-chain aggregation)
     * @param ngo NGO address
     * @param metricType Type of metric
     * @param value Metric value
     * @param proof Merkle proof
     */
    function submitMetricWithProof(
        address ngo,
        string calldata metricType,
        uint256 value,
        bytes32[] calldata proof
    ) external {
        bytes32 leaf = keccak256(abi.encodePacked(ngo, metricType, value, msg.sender));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidMerkleProof();
        
        emit MetricUpdated(ngo, metricType, value, block.timestamp);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get comprehensive NGO information
     * @param ngo NGO address
     * @return record NGO record
     * @return campaigns Array of campaign addresses
     * @return isVerified Verification status
     */
    function getNGOInfo(address ngo) external view returns (
        NGORecord memory record,
        address[] memory campaigns,
        bool isVerified
    ) {
        record = ngoRecords[ngo];
        campaigns = ngoCampaigns[ngo].values();
        isVerified = verifiedNGOs.contains(ngo);
    }
    
    /**
     * @notice Get all campaigns for an NGO
     * @param ngo NGO address
     * @return Array of campaign addresses
     */
    function getNGOCampaigns(address ngo) external view returns (address[] memory) {
        return ngoCampaigns[ngo].values();
    }
    
    /**
     * @notice Get platform statistics including partner NGO contributions
     * @return Enhanced platform statistics struct
     */
    function getPlatformStatistics() external view returns (PlatformStats memory) {
        return platformStats;
    }
    
    /**
     * @notice Check if address is registered NGO
     * @param account Address to check
     * @return bool Whether registered
     */
    function isRegisteredNGO(address account) external view returns (bool) {
        return registeredNGOs.contains(account);
    }
    
    /**
     * @notice Check if address is verified NGO
     * @param account Address to check
     * @return bool Whether verified
     */
    function isVerifiedNGO(address account) external view returns (bool) {
        return verifiedNGOs.contains(account);
    }
    
    /**
     * @notice Get all registered NGOs
     * @param offset Start index
     * @param limit Number to return
     * @return ngos Array of NGO addresses
     */
    function getRegisteredNGOs(uint256 offset, uint256 limit) external view returns (address[] memory ngos) {
        uint256 total = registeredNGOs.length();
        if (offset >= total) return new address[](0);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 length = end - offset;
        
        ngos = new address[](length);
        for (uint256 i; i < length;) {
            ngos[i] = registeredNGOs.at(offset + i);
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get pending applications
     * @return Array of application IDs
     */
    function getPendingApplications() external view returns (uint256[] memory) {
        return pendingApplications.values();
    }
    
    /**
     * @notice Get partner NGO contributions by token
     * @param token Token address to query
     * @return Total contributions in that token
     */
    function getPartnerNGOContributionsByToken(address token) external view returns (uint256) {
        return partnerNGOContributions[token];
    }
    
    /**
     * @notice Compute the address where a campaign would be deployed
     * @param ngo NGO address
     * @param beneficiaries Array of beneficiary addresses
     * @param percentages Array of distribution percentages
     * @param ipfsHash IPFS hash containing campaign metadata
     * @param timestamp Timestamp to use in salt calculation
     * @return The address where the campaign would be deployed
     */
    function computeCampaignAddress(
        address ngo,
        address[] calldata beneficiaries,
        uint256[] calldata percentages,
        string calldata ipfsHash,
        uint256 timestamp
    ) external view returns (address) {
        bytes32 salt = keccak256(
            abi.encodePacked(
                ngo,
                keccak256(abi.encode(beneficiaries)),
                keccak256(abi.encode(percentages)),
                ipfsHash,
                timestamp
            )
        );
        
        bytes memory constructorArgs = abi.encode(
            ngo,
            address(this),
            beneficiaries,
            percentages,
            ipfsHash,
            feeToken,
            platformFeeRate,
            partnerNGO
        );
        
        bytes memory bytecode = abi.encodePacked(
            type(DonationCampaign).creationCode,
            constructorArgs
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Configure a tier
     * @param tier Tier number (1-5)
     * @param config Tier configuration
     */
    function configureTier(uint32 tier, TierConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier == 0 || tier > MAX_TIERS) revert InvalidTier();
        
        tierConfigs[tier] = config;
        emit TierConfigured(tier, config.name, config.deploymentFee, config.annualFee);
    }
    
    /**
     * @notice Update platform fee rate
     * @param newRate New fee rate (10000 = 100%)
     */
    function updatePlatformFeeRate(uint256 newRate) external onlyRole(TREASURY_ROLE) {
        if (newRate > 1000) revert InvalidAmount(); // Max 10%
        
        uint256 oldRate = platformFeeRate;
        platformFeeRate = newRate;
        emit PlatformFeeUpdated(oldRate, newRate);
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) validAddress(newTreasury) {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Update merkle root for batch operations
     * @param newRoot New merkle root
     */
    function updateMerkleRoot(bytes32 newRoot) external onlyRole(OPERATOR_ROLE) {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = newRoot;
        emit MerkleRootUpdated(oldRoot, newRoot);
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Withdraw accumulated referral rewards
     */
    function withdrawReferralRewards() external nonReentrant {
        uint256 rewards = referralRewards[msg.sender];
        if (rewards == 0) revert InvalidAmount();
        
        referralRewards[msg.sender] = 0;
        IERC20(feeToken).safeTransfer(msg.sender, rewards);
    }

    // ============ Internal Functions ============
    
    /**
     * @dev Internal function to process applications
     */
    function _processApplication(
        uint256 applicationId,
        bool approved,
        string calldata ipfsHash
    ) internal {
        Application storage app = applications[applicationId];
        if (app.status != 0) revert InvalidStatus();
        if (app.submittedAt + APPLICATION_EXPIRY < block.timestamp) revert DeadlineExpired();
        
        app.status = approved ? 1 : 2;
        pendingApplications.remove(applicationId);
        
        if (approved) {
            _registerNGO(app.applicant, app.requestedTier, ipfsHash);
        }
        
        delete activeApplicationId[app.applicant];
        
        emit ApplicationProcessed(applicationId, app.applicant, approved, msg.sender);
    }
    
    /**
     * @dev Register a new NGO
     */
    function _registerNGO(address account, uint32 tier, string memory ipfsHash) internal {
        ngoRecords[account] = NGORecord({
            account: account,
            registeredAt: uint64(block.timestamp),
            tier: tier,
            tierExpiresAt: uint64(block.timestamp + TIER_DURATION),
            campaignCount: 0,
            lifetimeCampaigns: 0,
            status: 1, // Active
            isVerified: false,
            totalRaised: 0,
            ipfsHash: ipfsHash
        });
        
        registeredNGOs.add(account);
        platformStats.totalNGOs++;
        
        emit NGORegistered(account, tier, ipfsHash);
    }
    
    /**
     * @dev Deploy a campaign contract using CREATE2 for deterministic addresses
     */
    function _deployCampaign(
        address ngo,
        address[] calldata beneficiaries,
        uint256[] calldata percentages,
        string calldata ipfsHash
    ) internal returns (address campaign) {
        // Create salt including all parameters for true determinism
        bytes32 salt = keccak256(
            abi.encodePacked(
                ngo,
                keccak256(abi.encode(beneficiaries)),
                keccak256(abi.encode(percentages)),
                ipfsHash,
                block.timestamp
            )
        );
        
        // Deploy using CREATE2 with partner NGO parameter
        {
            // Scope to avoid stack too deep
            bytes memory bytecode = abi.encodePacked(
                type(DonationCampaign).creationCode,
                abi.encode(
                    ngo,                      // NGO owner
                    address(this),           // Registry address
                    beneficiaries,           // Beneficiary addresses
                    percentages,             // Distribution percentages
                    ipfsHash,                // Campaign metadata
                    feeToken,                // Platform fee token
                    platformFeeRate,         // Platform fee rate
                    partnerNGO               // Partner NGO for platform fees
                )
            );
            
            assembly {
                campaign := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
                if iszero(extcodesize(campaign)) {
                    revert(0, 0)
                }
            }
        }
        
        // Initialize campaign with tier settings
        {
            // Separate scope to avoid stack too deep
            TierConfig memory tierConfig = tierConfigs[ngoRecords[ngo].tier];
            IDonationCampaign(campaign).initialize(
                tierConfig.recurringEnabled,
                tierConfig.customNFTEnabled,
                tierConfig.maxTokens
            );
        }
    }
    
    /**
     * @dev Process referral rewards
     */
    function _processReferralReward(address user, uint256 feeAmount) internal {
        address referrer = referredBy[user];
        if (referrer != address(0)) {
            uint256 reward = (feeAmount * referralFeeRate) / FEE_PRECISION;
            referralRewards[referrer] += reward;
        }
    }
    
    /**
     * @dev Initialize default tier configurations
     */
    function _initializeTiers() internal {
        tierConfigs[1] = TierConfig({
            deploymentFee: 50 ether,
            annualFee: 100 ether,
            maxCampaigns: 1,
            maxBeneficiaries: 3,
            maxTokens: 5,
            recurringEnabled: false,
            customNFTEnabled: false,
            name: "Starter"
        });
        
        tierConfigs[2] = TierConfig({
            deploymentFee: 100 ether,
            annualFee: 500 ether,
            maxCampaigns: 3,
            maxBeneficiaries: 5,
            maxTokens: 10,
            recurringEnabled: true,
            customNFTEnabled: false,
            name: "Growth"
        });
        
        tierConfigs[3] = TierConfig({
            deploymentFee: 250 ether,
            annualFee: 1000 ether,
            maxCampaigns: 10,
            maxBeneficiaries: 10,
            maxTokens: 20,
            recurringEnabled: true,
            customNFTEnabled: true,
            name: "Professional"
        });
        
        tierConfigs[4] = TierConfig({
            deploymentFee: 500 ether,
            annualFee: 2500 ether,
            maxCampaigns: 25,
            maxBeneficiaries: 15,
            maxTokens: 50,
            recurringEnabled: true,
            customNFTEnabled: true,
            name: "Enterprise"
        });
        
        tierConfigs[5] = TierConfig({
            deploymentFee: 1000 ether,
            annualFee: 5000 ether,
            maxCampaigns: 100,
            maxBeneficiaries: 20,
            maxTokens: 100,
            recurringEnabled: true,
            customNFTEnabled: true,
            name: "Unlimited"
        });
    }
}
