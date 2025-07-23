// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Import the EnhancedDonationContract from previous implementation
import "./EnhancedDonationContract.sol";

/**
 * @title CIFI GIVE - Enterprise Philanthropy Platform
 * @notice Unified contract combining NGO registry, dashboard, and management functions
 * @dev Single entry point for the entire donation ecosystem
 * 
 * Features:
 * - NGO application and verification system
 * - Automated donation contract deployment
 * - Comprehensive analytics and reporting
 * - Multi-campaign management
 * - Beneficiary templates and management
 * - Donor relationship tracking
 * - Integration with REFI ecosystem
 * - Enterprise-grade security and controls
 */
contract CIFI_GIVE is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // ========== Custom Errors ==========
    error NotRegistered();
    error AlreadyRegistered();
    error InvalidParameters();
    error UnauthorizedAccess();
    error ApplicationPending();
    error NoSlotAvailable();
    error InvalidStatus();
    error ContractNotFound();
    error TierLimitExceeded();
    error PaymentRequired();
    error TransferFailed();
    error Blacklisted();
    error SystemPaused();
    error TimelockActive();
    error InvalidContract();
    
    // ========== Constants ==========
    uint256 public constant VERSION = 1;
    uint256 public constant MAX_TIERS = 5;
    uint256 public constant MAX_CATEGORIES = 10;
    uint256 public constant MAX_STRING_LENGTH = 256;
    uint256 public constant ANALYTICS_UPDATE_COOLDOWN = 1 hours;
    uint256 public constant TIMELOCK_PERIOD = 3 days;
    uint256 public constant MAX_BATCH_SIZE = 50;
    
    // ========== Access Control Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    // ========== Enums ==========
    enum ApplicationStatus {
        None,
        Pending,
        UnderReview,
        Approved,
        Rejected,
        Withdrawn
    }
    
    enum NGOStatus {
        Inactive,
        Active,
        Suspended,
        Blacklisted
    }
    
    // ========== Core Data Structures ==========
    
    struct NGOProfile {
        string organizationName;
        string description;
        string website;
        string logoURI;
        string ipfsMetadata;
        address primaryContact;
        uint256 establishedDate;
        uint256 registrationDate;
        uint256 tier;
        NGOStatus status;
        bool isVerified;
        uint256 categoryCount;
    }
    
    struct Application {
        address applicant;
        string organizationName;
        string description;
        string website;
        string ipfsMetadata;
        uint256 requestedTier;
        uint256 applicationTime;
        ApplicationStatus status;
        string reviewNotes;
        address reviewer;
    }
    
    struct TierConfig {
        string tierName;
        uint256 deploymentFee;
        uint256 annualFee;
        uint256 maxCampaigns;
        uint256 maxBeneficiaries;
        uint256 maxAcceptedTokens;
        bool recurringEnabled;
        bool customNFTEnabled;
        bool analyticsEnabled;
        bool treasuryEnabled;
    }
    
    struct CampaignMetrics {
        uint256 totalRaised;
        uint256 uniqueDonors;
        uint256 recurringDonors;
        uint256 averageDonation;
        uint256 lastDonationTime;
        uint256 nftsIssued;
        uint256 monthlyGrowthRate;
        uint256 donorRetentionRate;
        uint256 lastUpdated;
    }
    
    struct BeneficiaryTemplate {
        string name;
        address walletAddress;
        uint96 defaultPercentage;
        string description;
        bool isActive;
        uint256 createdAt;
        uint256 useCount;
    }
    
    struct CampaignGoal {
        uint256 targetAmount;
        uint256 deadline;
        string description;
        bool achieved;
        uint256 achievedAt;
    }
    
    struct PlatformStats {
        uint256 totalNGOs;
        uint256 verifiedNGOs;
        uint256 totalCampaigns;
        uint256 totalRaised;
        uint256 totalDonors;
        uint256 totalNFTsIssued;
        uint256 totalFeesCollected;
    }
    
    // ========== State Variables ==========
    
    // Platform Configuration
    address public platformTreasury;
    address public feeToken;
    address public refiToken;
    address public refiTreasury;
    address public stakingContract;
    
    // NGO Management
    mapping(address => NGOProfile) public ngoProfiles;
    mapping(address => mapping(uint256 => string)) public ngoCategories;
    mapping(address => EnumerableSet.AddressSet) private ngoCampaigns;
    mapping(address => BeneficiaryTemplate[]) public beneficiaryTemplates;
    
    // Application System
    uint256 public nextApplicationId = 1;
    mapping(uint256 => Application) public applications;
    mapping(address => uint256) public activeApplicationId;
    mapping(address => uint256[]) public applicationHistory;
    
    // Campaign Management
    mapping(address => CampaignMetrics) public campaignMetrics;
    mapping(address => CampaignGoal[]) public campaignGoals;
    mapping(address => address) public campaignToNGO;
    mapping(address => bool) public isRegisteredCampaign;
    
    // Platform Registry
    EnumerableSet.AddressSet private registeredNGOs;
    EnumerableSet.AddressSet private verifiedNGOs;
    EnumerableSet.AddressSet private allCampaigns;
    
    // Tier System
    mapping(uint256 => TierConfig) public tierConfigs;
    mapping(address => uint256) public ngoTierExpiry;
    
    // Security & Compliance
    mapping(address => bool) public blacklistedAddresses;
    mapping(address => uint256) private lastAnalyticsUpdate;
    
    // Platform Statistics
    PlatformStats public platformStats;
    
    // System Controls
    bool public applicationsPaused;
    bool public deploymentsPaused;
    uint256 public lastFeeUpdate;
    
    // ========== Events ==========
    
    // Application Events
    event ApplicationSubmitted(uint256 indexed applicationId, address indexed applicant, string organizationName);
    event ApplicationReviewed(uint256 indexed applicationId, ApplicationStatus newStatus, address reviewer);
    event ApplicationWithdrawn(uint256 indexed applicationId, address applicant);
    
    // NGO Events
    event NGORegistered(address indexed ngo, string organizationName, uint256 tier);
    event NGOVerified(address indexed ngo, address verifier);
    event NGOStatusChanged(address indexed ngo, NGOStatus oldStatus, NGOStatus newStatus);
    event NGOTierChanged(address indexed ngo, uint256 oldTier, uint256 newTier);
    event NGOProfileUpdated(address indexed ngo);
    
    // Campaign Events
    event CampaignDeployed(address indexed ngo, address indexed campaign, string campaignName);
    event CampaignMetricsUpdated(address indexed campaign, uint256 totalRaised);
    event CampaignGoalSet(address indexed campaign, uint256 goalId, uint256 targetAmount);
    event CampaignGoalAchieved(address indexed campaign, uint256 goalId);
    
    // Template Events
    event BeneficiaryTemplateCreated(address indexed ngo, uint256 templateId, string name);
    event BeneficiaryTemplateUpdated(address indexed ngo, uint256 templateId);
    event TemplateAppliedToCampaign(address indexed campaign, uint256[] templateIds);
    
    // Platform Events
    event PlatformConfigUpdated(string configType, address newAddress);
    event TierConfigured(uint256 indexed tier, string tierName, uint256 deploymentFee);
    event FeesCollected(address indexed from, uint256 amount, string feeType);
    event EmergencyAction(string action, address indexed initiator);
    
    // ========== Constructor ==========
    
    constructor(
        address _feeToken,
        address _platformTreasury,
        address _refiToken,
        address _refiTreasury
    ) {
        if (_feeToken == address(0) || _platformTreasury == address(0)) revert InvalidParameters();
        
        feeToken = _feeToken;
        platformTreasury = _platformTreasury;
        refiToken = _refiToken;
        refiTreasury = _refiTreasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        _initializeDefaultTiers();
    }
    
    // ========== NGO Registration & Application ==========
    
    /**
     * @notice Submit application to register as an NGO
     * @dev Includes automatic duplicate check and validation
     */
    function submitApplication(
        string memory organizationName,
        string memory description,
        string memory website,
        string memory ipfsMetadata,
        string[] memory categories,
        uint256 requestedTier
    ) external nonReentrant whenNotPaused {
        if (applicationsPaused) revert SystemPaused();
        if (blacklistedAddresses[msg.sender]) revert Blacklisted();
        if (activeApplicationId[msg.sender] != 0) revert ApplicationPending();
        if (bytes(organizationName).length == 0 || bytes(organizationName).length > MAX_STRING_LENGTH) {
            revert InvalidParameters();
        }
        if (categories.length == 0 || categories.length > MAX_CATEGORIES) revert InvalidParameters();
        if (requestedTier == 0 || requestedTier > MAX_TIERS) revert InvalidParameters();
        
        uint256 applicationId = nextApplicationId++;
        
        applications[applicationId] = Application({
            applicant: msg.sender,
            organizationName: organizationName,
            description: description,
            website: website,
            ipfsMetadata: ipfsMetadata,
            requestedTier: requestedTier,
            applicationTime: block.timestamp,
            status: ApplicationStatus.Pending,
            reviewNotes: "",
            reviewer: address(0)
        });
        
        activeApplicationId[msg.sender] = applicationId;
        applicationHistory[msg.sender].push(applicationId);
        
        emit ApplicationSubmitted(applicationId, msg.sender, organizationName);
    }
    
    /**
     * @notice Review and approve an NGO application
     * @dev Creates NGO profile and grants access
     */
    function approveApplication(
        uint256 applicationId,
        string memory reviewNotes,
        uint256 approvedTier,
        bool autoVerify
    ) external onlyRole(REVIEWER_ROLE) nonReentrant {
        Application storage app = applications[applicationId];
        if (app.status != ApplicationStatus.Pending && app.status != ApplicationStatus.UnderReview) {
            revert InvalidStatus();
        }
        
        address applicant = app.applicant;
        if (registeredNGOs.contains(applicant)) revert AlreadyRegistered();
        
        // Update application
        app.status = ApplicationStatus.Approved;
        app.reviewNotes = reviewNotes;
        app.reviewer = msg.sender;
        
        // Create NGO profile
        ngoProfiles[applicant] = NGOProfile({
            organizationName: app.organizationName,
            description: app.description,
            website: app.website,
            logoURI: "",
            ipfsMetadata: app.ipfsMetadata,
            primaryContact: applicant,
            establishedDate: block.timestamp,
            registrationDate: block.timestamp,
            tier: approvedTier,
            status: NGOStatus.Active,
            isVerified: autoVerify,
            categoryCount: 0
        });
        
        // Register NGO
        registeredNGOs.add(applicant);
        if (autoVerify) {
            verifiedNGOs.add(applicant);
        }
        
        // Set tier expiry (1 year from approval)
        ngoTierExpiry[applicant] = block.timestamp + 365 days;
        
        // Clear active application
        activeApplicationId[applicant] = 0;
        
        // Update platform stats
        platformStats.totalNGOs++;
        if (autoVerify) {
            platformStats.verifiedNGOs++;
        }
        
        emit ApplicationReviewed(applicationId, ApplicationStatus.Approved, msg.sender);
        emit NGORegistered(applicant, app.organizationName, approvedTier);
        
        if (autoVerify) {
            emit NGOVerified(applicant, msg.sender);
        }
    }
    
    /**
     * @notice Reject an application
     */
    function rejectApplication(
        uint256 applicationId,
        string memory reviewNotes
    ) external onlyRole(REVIEWER_ROLE) {
        Application storage app = applications[applicationId];
        if (app.status != ApplicationStatus.Pending && app.status != ApplicationStatus.UnderReview) {
            revert InvalidStatus();
        }
        
        app.status = ApplicationStatus.Rejected;
        app.reviewNotes = reviewNotes;
        app.reviewer = msg.sender;
        
        activeApplicationId[app.applicant] = 0;
        
        emit ApplicationReviewed(applicationId, ApplicationStatus.Rejected, msg.sender);
    }
    
    // ========== Campaign Deployment ==========
    
    /**
     * @notice Deploy a new donation campaign contract
     * @dev Enforces tier limits and collects deployment fee
     */
    function deployCampaign(
        address[] memory beneficiaries,
        uint96[] memory percentages,
        string memory campaignName,
        address[] memory acceptedTokens,
        string memory nftName,
        string memory nftSymbol,
        string memory nftBaseURI,
        string[] memory beneficiaryTitles
    ) external nonReentrant whenNotPaused returns (address) {
        if (deploymentsPaused) revert SystemPaused();
        if (!registeredNGOs.contains(msg.sender)) revert NotRegistered();
        
        NGOProfile storage profile = ngoProfiles[msg.sender];
        if (profile.status != NGOStatus.Active) revert UnauthorizedAccess();
        
        // Check tier limits
        TierConfig memory tierConfig = tierConfigs[profile.tier];
        uint256 currentCampaigns = ngoCampaigns[msg.sender].length();
        if (currentCampaigns >= tierConfig.maxCampaigns) revert TierLimitExceeded();
        if (beneficiaries.length > tierConfig.maxBeneficiaries) revert TierLimitExceeded();
        if (acceptedTokens.length > tierConfig.maxAcceptedTokens) revert TierLimitExceeded();
        
        // Collect deployment fee
        if (tierConfig.deploymentFee > 0) {
            IERC20(feeToken).safeTransferFrom(msg.sender, platformTreasury, tierConfig.deploymentFee);
            platformStats.totalFeesCollected += tierConfig.deploymentFee;
            emit FeesCollected(msg.sender, tierConfig.deploymentFee, "DEPLOYMENT");
        }
        
        // Deploy campaign contract
        EnhancedDonationContract campaign = new EnhancedDonationContract(
            msg.sender,
            address(this),
            beneficiaries,
            percentages,
            campaignName,
            acceptedTokens,
            nftName,
            nftSymbol,
            nftBaseURI,
            beneficiaryTitles
        );
        
        address campaignAddress = address(campaign);
        
        // Register campaign
        ngoCampaigns[msg.sender].add(campaignAddress);
        allCampaigns.add(campaignAddress);
        campaignToNGO[campaignAddress] = msg.sender;
        isRegisteredCampaign[campaignAddress] = true;
        
        // Initialize metrics
        campaignMetrics[campaignAddress] = CampaignMetrics({
            totalRaised: 0,
            uniqueDonors: 0,
            recurringDonors: 0,
            averageDonation: 0,
            lastDonationTime: 0,
            nftsIssued: 0,
            monthlyGrowthRate: 0,
            donorRetentionRate: 0,
            lastUpdated: block.timestamp
        });
        
        // Update platform stats
        platformStats.totalCampaigns++;
        
        emit CampaignDeployed(msg.sender, campaignAddress, campaignName);
        
        return campaignAddress;
    }
    
    // ========== Dashboard Functions ==========
    
    /**
     * @notice Get comprehensive NGO dashboard data
     */
    function getNGODashboard(address ngo) external view returns (
        NGOProfile memory profile,
        uint256 totalCampaigns,
        uint256 totalRaised,
        uint256 totalDonors,
        uint256 totalNFTs,
        uint256 activeRecurringDonors,
        uint256 averageGrowthRate,
        uint256 tierDaysRemaining
    ) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        profile = ngoProfiles[ngo];
        totalCampaigns = ngoCampaigns[ngo].length();
        
        // Aggregate metrics from all campaigns
        address[] memory campaigns = ngoCampaigns[ngo].values();
        for (uint256 i = 0; i < campaigns.length; i++) {
            CampaignMetrics memory metrics = campaignMetrics[campaigns[i]];
            totalRaised += metrics.totalRaised;
            totalDonors += metrics.uniqueDonors;
            totalNFTs += metrics.nftsIssued;
            activeRecurringDonors += metrics.recurringDonors;
            averageGrowthRate += metrics.monthlyGrowthRate;
        }
        
        // Calculate averages
        if (totalCampaigns > 0) {
            averageGrowthRate = averageGrowthRate / totalCampaigns;
        }
        
        // Calculate tier days remaining
        if (ngoTierExpiry[ngo] > block.timestamp) {
            tierDaysRemaining = (ngoTierExpiry[ngo] - block.timestamp) / 1 days;
        }
    }
    
    /**
     * @notice Update campaign analytics
     * @dev Can be called by campaign owner or system
     */
    function updateCampaignAnalytics(address campaign) external nonReentrant {
        if (!isRegisteredCampaign[campaign]) revert ContractNotFound();
        
        // Rate limit updates
        if (block.timestamp < lastAnalyticsUpdate[campaign] + ANALYTICS_UPDATE_COOLDOWN) {
            revert InvalidParameters();
        }
        
        _updateCampaignMetrics(campaign);
        lastAnalyticsUpdate[campaign] = block.timestamp;
    }
    
    /**
     * @notice Create a beneficiary template for reuse
     */
    function createBeneficiaryTemplate(
        string memory name,
        address walletAddress,
        uint96 defaultPercentage,
        string memory description
    ) external {
        if (!registeredNGOs.contains(msg.sender)) revert NotRegistered();
        if (walletAddress == address(0)) revert InvalidParameters();
        if (defaultPercentage == 0 || defaultPercentage > 10000) revert InvalidParameters();
        
        beneficiaryTemplates[msg.sender].push(BeneficiaryTemplate({
            name: name,
            walletAddress: walletAddress,
            defaultPercentage: defaultPercentage,
            description: description,
            isActive: true,
            createdAt: block.timestamp,
            useCount: 0
        }));
        
        uint256 templateId = beneficiaryTemplates[msg.sender].length - 1;
        emit BeneficiaryTemplateCreated(msg.sender, templateId, name);
    }
    
    /**
     * @notice Apply beneficiary templates to a campaign
     */
    function applyTemplatesToCampaign(
        address campaign,
        uint256[] calldata templateIds,
        uint96[] calldata customPercentages
    ) external nonReentrant {
        if (campaignToNGO[campaign] != msg.sender) revert UnauthorizedAccess();
        if (templateIds.length != customPercentages.length) revert InvalidParameters();
        
        BeneficiaryTemplate[] storage templates = beneficiaryTemplates[msg.sender];
        
        address[] memory addresses = new address[](templateIds.length);
        uint96[] memory percentages = new uint96[](templateIds.length);
        string[] memory titles = new string[](templateIds.length);
        
        uint96 totalPercentage = 0;
        
        for (uint256 i = 0; i < templateIds.length; i++) {
            if (templateIds[i] >= templates.length) revert InvalidParameters();
            
            BeneficiaryTemplate storage template = templates[templateIds[i]];
            if (!template.isActive) revert InvalidParameters();
            
            addresses[i] = template.walletAddress;
            percentages[i] = customPercentages[i] > 0 ? customPercentages[i] : template.defaultPercentage;
            titles[i] = template.name;
            
            totalPercentage += percentages[i];
            template.useCount++;
        }
        
        if (totalPercentage != 10000) revert InvalidParameters();
        
        IDonationContract(campaign).updateChildren(addresses, percentages, titles);
        emit TemplateAppliedToCampaign(campaign, templateIds);
    }
    
    // ========== Campaign Goals ==========
    
    /**
     * @notice Set a fundraising goal for a campaign
     */
    function setCampaignGoal(
        address campaign,
        uint256 targetAmount,
        uint256 deadline,
        string memory description
    ) external {
        if (campaignToNGO[campaign] != msg.sender) revert UnauthorizedAccess();
        
        campaignGoals[campaign].push(CampaignGoal({
            targetAmount: targetAmount,
            deadline: deadline,
            description: description,
            achieved: false,
            achievedAt: 0
        }));
        
        uint256 goalId = campaignGoals[campaign].length - 1;
        emit CampaignGoalSet(campaign, goalId, targetAmount);
    }
    
    // ========== View Functions ==========
    
    /**
     * @notice Get all campaigns for an NGO
     */
    function getNGOCampaigns(address ngo) external view returns (address[] memory) {
        return ngoCampaigns[ngo].values();
    }
    
    /**
     * @notice Get NGO categories
     */
    function getNGOCategories(address ngo) external view returns (string[] memory categories) {
        uint256 count = ngoProfiles[ngo].categoryCount;
        categories = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            categories[i] = ngoCategories[ngo][i];
        }
    }
    
    /**
     * @notice Check if an address is a verified NGO
     */
    function isVerifiedNGO(address ngo) external view returns (bool) {
        return verifiedNGOs.contains(ngo);
    }
    
    /**
     * @notice Get platform-wide statistics
     */
    function getPlatformStatistics() external view returns (PlatformStats memory) {
        return platformStats;
    }
    
    /**
     * @notice Get campaign goals and their status
     */
    function getCampaignGoals(address campaign) external view returns (CampaignGoal[] memory) {
        return campaignGoals[campaign];
    }
    
    /**
     * @notice Get beneficiary templates for an NGO
     */
    function getBeneficiaryTemplates(address ngo) external view returns (BeneficiaryTemplate[] memory) {
        return beneficiaryTemplates[ngo];
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @notice Configure tier settings
     */
    function configureTier(
        uint256 tier,
        string memory tierName,
        uint256 deploymentFee,
        uint256 annualFee,
        uint256 maxCampaigns,
        uint256 maxBeneficiaries,
        uint256 maxAcceptedTokens,
        bool recurringEnabled,
        bool analyticsEnabled
    ) external onlyRole(ADMIN_ROLE) {
        if (tier == 0 || tier > MAX_TIERS) revert InvalidParameters();
        
        tierConfigs[tier] = TierConfig({
            tierName: tierName,
            deploymentFee: deploymentFee,
            annualFee: annualFee,
            maxCampaigns: maxCampaigns,
            maxBeneficiaries: maxBeneficiaries,
            maxAcceptedTokens: maxAcceptedTokens,
            recurringEnabled: recurringEnabled,
            customNFTEnabled: tier >= 3,
            analyticsEnabled: analyticsEnabled,
            treasuryEnabled: tier >= 2
        });
        
        emit TierConfigured(tier, tierName, deploymentFee);
    }
    
    /**
     * @notice Update platform configuration
     */
    function updatePlatformConfig(
        address _feeToken,
        address _platformTreasury,
        address _refiTreasury
    ) external onlyRole(ADMIN_ROLE) {
        if (block.timestamp < lastFeeUpdate + TIMELOCK_PERIOD) revert TimelockActive();
        
        if (_feeToken != address(0)) {
            feeToken = _feeToken;
            emit PlatformConfigUpdated("FEE_TOKEN", _feeToken);
        }
        
        if (_platformTreasury != address(0)) {
            platformTreasury = _platformTreasury;
            emit PlatformConfigUpdated("PLATFORM_TREASURY", _platformTreasury);
        }
        
        if (_refiTreasury != address(0)) {
            refiTreasury = _refiTreasury;
            emit PlatformConfigUpdated("REFI_TREASURY", _refiTreasury);
        }
        
        lastFeeUpdate = block.timestamp;
    }
    
    /**
     * @notice Verify an NGO
     */
    function verifyNGO(address ngo) external onlyRole(REVIEWER_ROLE) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        ngoProfiles[ngo].isVerified = true;
        verifiedNGOs.add(ngo);
        platformStats.verifiedNGOs++;
        
        emit NGOVerified(ngo, msg.sender);
    }
    
    /**
     * @notice Update NGO status
     */
    function updateNGOStatus(address ngo, NGOStatus newStatus) external onlyRole(ADMIN_ROLE) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        NGOStatus oldStatus = ngoProfiles[ngo].status;
        ngoProfiles[ngo].status = newStatus;
        
        if (newStatus == NGOStatus.Blacklisted) {
            blacklistedAddresses[ngo] = true;
        }
        
        emit NGOStatusChanged(ngo, oldStatus, newStatus);
    }
    
    /**
     * @notice Emergency pause functions
     */
    function pauseApplications() external onlyRole(OPERATOR_ROLE) {
        applicationsPaused = true;
        emit EmergencyAction("APPLICATIONS_PAUSED", msg.sender);
    }
    
    function resumeApplications() external onlyRole(OPERATOR_ROLE) {
        applicationsPaused = false;
        emit EmergencyAction("APPLICATIONS_RESUMED", msg.sender);
    }
    
    function pauseDeployments() external onlyRole(OPERATOR_ROLE) {
        deploymentsPaused = true;
        emit EmergencyAction("DEPLOYMENTS_PAUSED", msg.sender);
    }
    
    function resumeDeployments() external onlyRole(OPERATOR_ROLE) {
        deploymentsPaused = false;
        emit EmergencyAction("DEPLOYMENTS_RESUMED", msg.sender);
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit EmergencyAction("PLATFORM_PAUSED", msg.sender);
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit EmergencyAction("PLATFORM_UNPAUSED", msg.sender);
    }
    
    // ========== Internal Functions ==========
    
    function _updateCampaignMetrics(address campaign) internal {
        try IDonationContract(campaign).getAllDonors() returns (address[] memory donors) {
            CampaignMetrics storage metrics = campaignMetrics[campaign];
            uint256 previousTotal = metrics.totalRaised;
            uint256 totalRaised = 0;
            uint256 recurringCount = 0;
            
            // Calculate totals from donor stats
            for (uint256 i = 0; i < donors.length; i++) {
                IDonationContract.DonationStats memory stats = IDonationContract(campaign).donorStats(donors[i]);
                totalRaised += stats.totalDonated;
                
                // Check for active recurring donations
                try IDonationContract(campaign).recurringDonations(donors[i], 0) returns (
                    IDonationContract.RecurringDonation memory rd
                ) {
                    if (rd.active) recurringCount++;
                } catch {}
            }
            
            // Get NFT count
            uint256 nftCount = 0;
            try IDonationReceiptNFT(IDonationContract(campaign).receiptNFT()).totalSupply() returns (uint256 supply) {
                nftCount = supply;
            } catch {}
            
            // Calculate growth rate
            uint256 growthRate = 0;
            if (previousTotal > 0 && metrics.lastUpdated > 0) {
                uint256 timeDiff = block.timestamp - metrics.lastUpdated;
                if (timeDiff > 0) {
                    growthRate = ((totalRaised - previousTotal) * 10000 * 30 days) / (previousTotal * timeDiff);
                }
            }
            
            // Update metrics
            metrics.totalRaised = totalRaised;
            metrics.uniqueDonors = donors.length;
            metrics.recurringDonors = recurringCount;
            metrics.averageDonation = donors.length > 0 ? totalRaised / donors.length : 0;
            metrics.nftsIssued = nftCount;
            metrics.monthlyGrowthRate = growthRate;
            metrics.donorRetentionRate = donors.length > 0 ? (recurringCount * 10000) / donors.length : 0;
            metrics.lastUpdated = block.timestamp;
            
            // Update platform stats
            if (totalRaised > previousTotal) {
                platformStats.totalRaised += totalRaised - previousTotal;
            }
            
            // Check campaign goals
            _checkCampaignGoals(campaign, totalRaised);
            
            emit CampaignMetricsUpdated(campaign, totalRaised);
        } catch {}
    }
    
    function _checkCampaignGoals(address campaign, uint256 totalRaised) internal {
        CampaignGoal[] storage goals = campaignGoals[campaign];
        
        for (uint256 i = 0; i < goals.length; i++) {
            if (!goals[i].achieved && totalRaised >= goals[i].targetAmount) {
                goals[i].achieved = true;
                goals[i].achievedAt = block.timestamp;
                emit CampaignGoalAchieved(campaign, i);
            }
        }
    }
    
    function _initializeDefaultTiers() internal {
        tierConfigs[1] = TierConfig({
            tierName: "Starter",
            deploymentFee: 50 * 10**18,
            annualFee: 100 * 10**18,
            maxCampaigns: 1,
            maxBeneficiaries: 3,
            maxAcceptedTokens: 3,
            recurringEnabled: false,
            customNFTEnabled: false,
            analyticsEnabled: true,
            treasuryEnabled: false
        });
        
        tierConfigs[2] = TierConfig({
            tierName: "Growth",
            deploymentFee: 100 * 10**18,
            annualFee: 500 * 10**18,
            maxCampaigns: 3,
            maxBeneficiaries: 5,
            maxAcceptedTokens: 10,
            recurringEnabled: true,
            customNFTEnabled: false,
            analyticsEnabled: true,
            treasuryEnabled: true
        });
        
        tierConfigs[3] = TierConfig({
            tierName: "Professional",
            deploymentFee: 250 * 10**18,
            annualFee: 1000 * 10**18,
            maxCampaigns: 10,
            maxBeneficiaries: 10,
            maxAcceptedTokens: 20,
            recurringEnabled: true,
            customNFTEnabled: true,
            analyticsEnabled: true,
            treasuryEnabled: true
        });
        
        tierConfigs[4] = TierConfig({
            tierName: "Enterprise",
            deploymentFee: 500 * 10**18,
            annualFee: 2500 * 10**18,
            maxCampaigns: 25,
            maxBeneficiaries: 15,
            maxAcceptedTokens: 50,
            recurringEnabled: true,
            customNFTEnabled: true,
            analyticsEnabled: true,
            treasuryEnabled: true
        });
        
        tierConfigs[5] = TierConfig({
            tierName: "Unlimited",
            deploymentFee: 1000 * 10**18,
            annualFee: 5000 * 10**18,
            maxCampaigns: 100,
            maxBeneficiaries: 20,
            maxAcceptedTokens: 100,
            recurringEnabled: true,
            customNFTEnabled: true,
            analyticsEnabled: true,
            treasuryEnabled: true
        });
    }
}

// ========== Interfaces ==========

interface IDonationContract {
    struct DonationStats {
        uint256 totalDonated;
        uint256 largestDonation;
        uint256 donationCount;
    }
    
    struct RecurringDonation {
        uint256 amount;
        uint256 interval;
        uint256 lastDonationTime;
        uint256 nextDonationTime;
        address token;
        bool active;
        uint256 maxDonations;
        uint256 donationCount;
    }
    
    function getAllDonors() external view returns (address[] memory);
    function donorStats(address) external view returns (DonationStats memory);
    function recurringDonations(address, uint256) external view returns (RecurringDonation memory);
    function receiptNFT() external view returns (address);
    function updateChildren(address[] calldata, uint96[] calldata, string[] calldata) external;
}

interface IDonationReceiptNFT {
    function totalSupply() external view returns (uint256);
}
