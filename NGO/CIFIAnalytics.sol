// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title ICIFIRegistry
 * @dev Interface for the main registry contract
 */
interface ICIFIRegistry {
    struct NGORecord {
        address account;
        uint64 registeredAt;
        uint32 tier;
        uint64 tierExpiresAt;
        uint32 campaignCount;
        uint32 lifetimeCampaigns;
        uint8 status;
        bool isVerified;
        uint128 totalRaised;
        string ipfsHash;
    }
    
    struct CampaignRecord {
        address ngo;
        uint64 deployedAt;
        uint32 beneficiaryCount;
        bool isActive;
        string ipfsHash;
    }
    
    function ngoRecords(address) external view returns (NGORecord memory);
    function campaignRecords(address) external view returns (CampaignRecord memory);
    function getNGOCampaigns(address ngo) external view returns (address[] memory);
    function isRegisteredNGO(address) external view returns (bool);
    function isVerifiedNGO(address) external view returns (bool);
    function platformFeeRate() external view returns (uint256);
}

/**
 * @title IDonationCampaign
 * @dev Interface for donation campaign contracts
 */
interface IDonationCampaign {
    function ngo() external view returns (address);
    function totalDonations() external view returns (uint256);
    function getBeneficiaries() external view returns (address[] memory, uint256[] memory);
    function isTokenAccepted(address token) external view returns (bool);
    function getRecurringDonation(address donor) external view returns (
        uint256 amount,
        uint256 interval,
        uint256 nextDue,
        address token,
        bool active
    );
    function getCampaignInfo() external view returns (
        address ngoAddress,
        uint256 beneficiaryCount,
        bool isActive,
        uint256 totalRaised,
        bool[2] memory features
    );
}

/**
 * @title IREFITreasury
 * @dev Interface for REFI treasury integration
 */
interface IREFITreasury {
    function deposit(uint256 amount, string calldata source) external;
}

/**
 * @title CIFIAnalytics
 * @author CIFI Foundation
 * @notice Comprehensive analytics and management dashboard for the CIFI GIVE ecosystem
 * @dev Provides advanced analytics, NGO tools, and donor insights with gas optimization
 * 
 * Key Features:
 * - Real-time analytics aggregation across all campaigns
 * - Beneficiary template management system
 * - Campaign goal tracking and milestones
 * - Donor relationship management
 * - Cross-campaign insights and reporting
 * - Integration with external systems (REFI, etc.)
 * - Gas-optimized batch operations
 */
contract CIFIAnalytics is AccessControl, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    
    // ============ Constants ============
    uint256 private constant FEE_PRECISION = 10000;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant CACHE_DURATION = 1 hours;
    uint256 private constant MAX_TEMPLATES = 100;
    uint256 private constant MAX_GOALS = 20;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ANALYST_ROLE = keccak256("ANALYST_ROLE");
    
    // ============ Structs ============
    
    /**
     * @dev Beneficiary template for reuse across campaigns
     */
    struct BeneficiaryTemplate {
        string name;
        address wallet;
        uint96 percentage;
        string description;
        uint64 createdAt;
        uint64 lastUsed;
        uint32 useCount;
        bool isActive;
    }
    
    /**
     * @dev Campaign goal tracking
     */
    struct CampaignGoal {
        uint128 targetAmount;
        uint64 deadline;
        uint64 achievedAt;
        bool achieved;
        string description;
    }
    
    /**
     * @dev Aggregated campaign metrics
     */
    struct CampaignMetrics {
        uint128 totalRaised;
        uint64 lastDonation;
        uint32 uniqueDonors;
        uint32 totalDonations;
        uint32 recurringDonors;
        uint16 donorRetentionRate; // Basis points (10000 = 100%)
        uint16 monthlyGrowthRate;   // Basis points
        bool metricsStale;
    }
    
    /**
     * @dev NGO performance dashboard
     */
    struct NGODashboard {
        uint128 lifetimeRaised;
        uint64 lastActivityAt;
        uint32 totalCampaigns;
        uint32 activeCampaigns;
        uint32 lifetimeDonors;
        uint32 goalsAchieved;
        uint16 successRate;      // Basis points
        uint16 avgGrowthRate;    // Basis points
    }
    
    /**
     * @dev Donor profile across campaigns
     */
    struct DonorProfile {
        uint128 totalDonated;
        uint64 firstDonation;
        uint64 lastDonation;
        uint32 donationCount;
        uint32 campaignsSupported;
        uint16 loyaltyScore;     // 0-10000 based on frequency and amount
        bool hasActiveRecurring;
    }
    
    /**
     * @dev Platform-wide insights
     */
    struct PlatformInsights {
        uint256 totalVolume;
        uint256 totalDonors;
        uint256 totalCampaigns;
        uint256 avgDonationSize;
        uint256 topCampaignVolume;
        address topCampaign;
        uint256 lastUpdated;
    }
    
    // ============ State Variables ============
    
    // Core references
    ICIFIRegistry public immutable registry;
    IREFITreasury public refiTreasury;
    
    // Template management
    mapping(address => BeneficiaryTemplate[]) public beneficiaryTemplates;
    mapping(address => uint256) public templateCount;
    
    // Goal tracking
    mapping(address => CampaignGoal[]) public campaignGoals;
    mapping(address => EnumerableSet.UintSet) private activeGoals;
    
    // Analytics caching
    mapping(address => CampaignMetrics) public campaignMetrics;
    mapping(address => NGODashboard) public ngoDashboards;
    mapping(address => DonorProfile) public donorProfiles;
    mapping(address => uint256) private lastMetricUpdate;
    
    // Donor tracking
    mapping(address => EnumerableSet.AddressSet) private campaignDonors;
    mapping(address => EnumerableSet.AddressSet) private donorCampaigns;
    mapping(address => mapping(address => uint256)) public donorCampaignAmount;
    
    // Platform insights
    PlatformInsights public platformInsights;
    EnumerableSet.AddressSet private allDonors;
    
    // Data verification
    bytes32 public dataRoot;
    mapping(bytes32 => bool) private processedReports;
    
    // ============ Events ============
    
    // Template events
    event TemplateCreated(address indexed ngo, uint256 indexed templateId, string name);
    event TemplateUpdated(address indexed ngo, uint256 indexed templateId);
    event TemplateApplied(address indexed ngo, address indexed campaign, uint256[] templateIds);
    
    // Goal events
    event GoalCreated(address indexed campaign, uint256 indexed goalId, uint128 target, uint64 deadline);
    event GoalAchieved(address indexed campaign, uint256 indexed goalId, uint128 raised);
    event GoalUpdated(address indexed campaign, uint256 indexed goalId);
    
    // Analytics events
    event MetricsUpdated(address indexed entity, string metricType, uint256 timestamp);
    event DonorProfileUpdated(address indexed donor, uint128 totalDonated, uint32 campaigns);
    event InsightsGenerated(uint256 totalVolume, uint256 totalDonors, uint256 timestamp);
    
    // Integration events
    event DataSubmitted(address indexed submitter, bytes32 dataHash, uint256 timestamp);
    event REFIContribution(address indexed ngo, uint256 amount, string source);
    
    // ============ Errors ============
    error NotRegisteredNGO();
    error Unauthorized();
    error InvalidParameters();
    error TemplateNotFound();
    error TemplateLimitExceeded();
    error GoalNotFound();
    error GoalLimitExceeded();
    error DataNotFresh();
    error InvalidProof();
    error AlreadyProcessed();
    error TransferFailed();
    error ArrayLengthMismatch();
    error InvalidAddress();
    error InvalidAmount();
    error CampaignNotFound();
    
    // ============ Modifiers ============
    
    modifier onlyRegisteredNGO() {
        if (!registry.isRegisteredNGO(msg.sender)) revert NotRegisteredNGO();
        _;
    }
    
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _registry) validAddress(_registry) {
        registry = ICIFIRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    // ============ Template Management ============
    
    /**
     * @notice Create a beneficiary template
     * @param name Template name
     * @param wallet Beneficiary address
     * @param percentage Distribution percentage (out of 10000)
     * @param description Template description
     * @return templateId Created template ID
     */
    function createTemplate(
        string calldata name,
        address wallet,
        uint96 percentage,
        string calldata description
    ) external onlyRegisteredNGO validAddress(wallet) returns (uint256 templateId) {
        if (percentage == 0 || percentage > FEE_PRECISION) revert InvalidAmount();
        if (templateCount[msg.sender] >= MAX_TEMPLATES) revert TemplateLimitExceeded();
        
        templateId = beneficiaryTemplates[msg.sender].length;
        
        beneficiaryTemplates[msg.sender].push(BeneficiaryTemplate({
            name: name,
            wallet: wallet,
            percentage: percentage,
            description: description,
            createdAt: uint64(block.timestamp),
            lastUsed: 0,
            useCount: 0,
            isActive: true
        }));
        
        templateCount[msg.sender]++;
        emit TemplateCreated(msg.sender, templateId, name);
    }
    
    /**
     * @notice Update a beneficiary template
     * @param templateId Template to update
     * @param name New name
     * @param wallet New wallet address
     * @param percentage New percentage
     * @param description New description
     * @param isActive Active status
     */
    function updateTemplate(
        uint256 templateId,
        string calldata name,
        address wallet,
        uint96 percentage,
        string calldata description,
        bool isActive
    ) external onlyRegisteredNGO validAddress(wallet) {
        if (templateId >= beneficiaryTemplates[msg.sender].length) revert TemplateNotFound();
        if (percentage == 0 || percentage > FEE_PRECISION) revert InvalidAmount();
        
        BeneficiaryTemplate storage template = beneficiaryTemplates[msg.sender][templateId];
        template.name = name;
        template.wallet = wallet;
        template.percentage = percentage;
        template.description = description;
        template.isActive = isActive;
        
        emit TemplateUpdated(msg.sender, templateId);
    }
    
    /**
     * @notice Apply templates to create beneficiary configuration
     * @param templateIds Array of template IDs to apply
     * @param customPercentages Optional custom percentages (0 to use template default)
     * @return wallets Array of beneficiary addresses
     * @return percentages Array of percentages
     */
    function applyTemplates(
        uint256[] calldata templateIds,
        uint96[] calldata customPercentages
    ) external view onlyRegisteredNGO returns (
        address[] memory wallets,
        uint256[] memory percentages
    ) {
        if (templateIds.length != customPercentages.length) revert ArrayLengthMismatch();
        
        wallets = new address[](templateIds.length);
        percentages = new uint256[](templateIds.length);
        
        uint256 totalPercentage;
        
        for (uint256 i; i < templateIds.length;) {
            if (templateIds[i] >= beneficiaryTemplates[msg.sender].length) revert TemplateNotFound();
            
            BeneficiaryTemplate memory template = beneficiaryTemplates[msg.sender][templateIds[i]];
            if (!template.isActive) revert InvalidParameters();
            
            wallets[i] = template.wallet;
            percentages[i] = customPercentages[i] > 0 ? customPercentages[i] : template.percentage;
            totalPercentage += percentages[i];
            
            unchecked { ++i; }
        }
        
        if (totalPercentage != FEE_PRECISION) revert InvalidAmount();
    }
    
    /**
     * @notice Record template usage
     * @param ngo NGO address
     * @param campaign Campaign address
     * @param templateIds Used template IDs
     */
    function recordTemplateUsage(
        address ngo,
        address campaign,
        uint256[] calldata templateIds
    ) external onlyRole(OPERATOR_ROLE) {
        for (uint256 i; i < templateIds.length;) {
            if (templateIds[i] < beneficiaryTemplates[ngo].length) {
                BeneficiaryTemplate storage template = beneficiaryTemplates[ngo][templateIds[i]];
                template.lastUsed = uint64(block.timestamp);
                template.useCount++;
            }
            unchecked { ++i; }
        }
        
        emit TemplateApplied(ngo, campaign, templateIds);
    }
    
    // ============ Goal Management ============
    
    /**
     * @notice Create a campaign goal
     * @param campaign Campaign address
     * @param targetAmount Target amount to raise
     * @param deadline Deadline timestamp
     * @param description Goal description
     * @return goalId Created goal ID
     */
    function createCampaignGoal(
        address campaign,
        uint128 targetAmount,
        uint64 deadline,
        string calldata description
    ) external onlyRegisteredNGO returns (uint256 goalId) {
        ICIFIRegistry.CampaignRecord memory record = registry.campaignRecords(campaign);
        if (record.ngo != msg.sender) revert Unauthorized();
        if (targetAmount == 0 || deadline <= block.timestamp) revert InvalidParameters();
        if (campaignGoals[campaign].length >= MAX_GOALS) revert GoalLimitExceeded();
        
        goalId = campaignGoals[campaign].length;
        
        campaignGoals[campaign].push(CampaignGoal({
            targetAmount: targetAmount,
            deadline: deadline,
            achievedAt: 0,
            achieved: false,
            description: description
        }));
        
        activeGoals[campaign].add(goalId);
        emit GoalCreated(campaign, goalId, targetAmount, deadline);
    }
    
    /**
     * @notice Update goal status based on campaign progress
     * @param campaign Campaign address
     * @param goalId Goal ID to check
     */
    function updateGoalStatus(address campaign, uint256 goalId) public {
        if (goalId >= campaignGoals[campaign].length) revert GoalNotFound();
        
        CampaignGoal storage goal = campaignGoals[campaign][goalId];
        if (goal.achieved) return;
        
        // Get current campaign metrics
        CampaignMetrics memory metrics = _getCampaignMetrics(campaign);
        
        if (metrics.totalRaised >= goal.targetAmount) {
            goal.achieved = true;
            goal.achievedAt = uint64(block.timestamp);
            activeGoals[campaign].remove(goalId);
            
            // Update NGO success metrics
            _updateNGOSuccessMetrics(IDonationCampaign(campaign).ngo());
            
            emit GoalAchieved(campaign, goalId, metrics.totalRaised);
        }
    }
    
    /**
     * @notice Batch update multiple goals
     * @param campaigns Array of campaign addresses
     * @param goalIds Array of goal IDs
     */
    function batchUpdateGoals(
        address[] calldata campaigns,
        uint256[] calldata goalIds
    ) external {
        if (campaigns.length != goalIds.length) revert ArrayLengthMismatch();
        if (campaigns.length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i; i < campaigns.length;) {
            updateGoalStatus(campaigns[i], goalIds[i]);
            unchecked { ++i; }
        }
    }
    
    // ============ Analytics Functions ============
    
    /**
     * @notice Update campaign metrics
     * @param campaign Campaign address
     * @param forceUpdate Force update even if cache is fresh
     */
    function updateCampaignMetrics(address campaign, bool forceUpdate) public {
        if (!forceUpdate && block.timestamp < lastMetricUpdate[campaign] + CACHE_DURATION) {
            revert DataNotFresh();
        }
        
        CampaignMetrics storage metrics = campaignMetrics[campaign];
        
        // Note: In production, this would aggregate from indexed events
        // For now, we'll use the campaign's reported total
        (, , , uint256 totalRaised, ) = IDonationCampaign(campaign).getCampaignInfo();
        
        metrics.totalRaised = uint128(totalRaised);
        metrics.lastDonation = uint64(block.timestamp);
        metrics.metricsStale = false;
        
        // Update donor metrics
        uint256 donorCount = campaignDonors[campaign].length();
        metrics.uniqueDonors = uint32(donorCount);
        
        // Calculate retention and growth rates
        if (donorCount > 0) {
            uint256 recurringCount = _countRecurringDonors(campaign);
            metrics.recurringDonors = uint32(recurringCount);
            metrics.donorRetentionRate = uint16((recurringCount * 10000) / donorCount);
        }
        
        lastMetricUpdate[campaign] = block.timestamp;
        emit MetricsUpdated(campaign, "campaign_metrics", block.timestamp);
    }
    
    /**
     * @notice Generate NGO dashboard
     * @param ngo NGO address
     * @return dashboard Complete NGO metrics
     */
    function generateNGODashboard(address ngo) external returns (NGODashboard memory dashboard) {
        if (!registry.isRegisteredNGO(ngo)) revert NotRegisteredNGO();
        
        dashboard = ngoDashboards[ngo];
        address[] memory campaigns = registry.getNGOCampaigns(ngo);
        
        uint256 totalRaised;
        uint256 totalDonors;
        uint256 activeCampaigns;
        uint256 totalGrowth;
        
        for (uint256 i; i < campaigns.length;) {
            CampaignMetrics memory metrics = _getCampaignMetrics(campaigns[i]);
            
            totalRaised += metrics.totalRaised;
            totalDonors += metrics.uniqueDonors;
            totalGrowth += metrics.monthlyGrowthRate;
            
            (, , bool isActive, , ) = IDonationCampaign(campaigns[i]).getCampaignInfo();
            if (isActive) activeCampaigns++;
            
            unchecked { ++i; }
        }
        
        dashboard.lifetimeRaised = uint128(totalRaised);
        dashboard.lifetimeDonors = uint32(totalDonors);
        dashboard.totalCampaigns = uint32(campaigns.length);
        dashboard.activeCampaigns = uint32(activeCampaigns);
        dashboard.lastActivityAt = uint64(block.timestamp);
        
        if (campaigns.length > 0) {
            dashboard.avgGrowthRate = uint16(totalGrowth / campaigns.length);
        }
        
        // Calculate success rate
        uint256 totalGoals;
        uint256 achievedGoals;
        
        for (uint256 i; i < campaigns.length;) {
            CampaignGoal[] memory goals = campaignGoals[campaigns[i]];
            for (uint256 j; j < goals.length;) {
                totalGoals++;
                if (goals[j].achieved) achievedGoals++;
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        
        if (totalGoals > 0) {
            dashboard.successRate = uint16((achievedGoals * 10000) / totalGoals);
            dashboard.goalsAchieved = uint32(achievedGoals);
        }
        
        ngoDashboards[ngo] = dashboard;
        emit MetricsUpdated(ngo, "ngo_dashboard", block.timestamp);
    }
    
    /**
     * @notice Track donor activity across campaigns
     * @param donor Donor address
     * @param campaign Campaign donated to
     * @param amount Amount donated
     */
    function trackDonorActivity(
        address donor,
        address campaign,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) {
        // Update donor profile
        DonorProfile storage profile = donorProfiles[donor];
        
        if (profile.firstDonation == 0) {
            profile.firstDonation = uint64(block.timestamp);
            allDonors.add(donor);
        }
        
        profile.totalDonated += uint128(amount);
        profile.lastDonation = uint64(block.timestamp);
        profile.donationCount++;
        
        // Track campaign relationship
        if (donorCampaigns[donor].add(campaign)) {
            profile.campaignsSupported++;
        }
        
        campaignDonors[campaign].add(donor);
        donorCampaignAmount[donor][campaign] += amount;
        
        // Calculate loyalty score (0-10000)
        uint256 recency = block.timestamp - profile.lastDonation;
        uint256 frequency = profile.donationCount;
        uint256 monetary = profile.totalDonated;
        
        // Simple RFM scoring
        uint16 recencyScore = recency < 30 days ? 3333 : (recency < 90 days ? 2000 : 1000);
        uint16 frequencyScore = frequency > 10 ? 3333 : uint16((frequency * 333));
        uint16 monetaryScore = monetary > 10000 ether ? 3334 : uint16((monetary * 3334) / 10000 ether);
        
        profile.loyaltyScore = recencyScore + frequencyScore + monetaryScore;
        
        // Check for active recurring
        try IDonationCampaign(campaign).getRecurringDonation(donor) returns (
            uint256, uint256, uint256, address, bool active
        ) {
            profile.hasActiveRecurring = active;
        } catch {}
        
        emit DonorProfileUpdated(donor, profile.totalDonated, profile.campaignsSupported);
    }
    
    /**
     * @notice Generate platform-wide insights
     */
    function generatePlatformInsights() external onlyRole(ANALYST_ROLE) {
        uint256 totalVolume;
        uint256 totalCampaigns;
        uint256 totalDonationCount;
        uint256 topVolume;
        address topCampaign;
        
        // Note: In production, this would be optimized with off-chain indexing
        // For demonstration, we'll iterate through known donors
        address[] memory donors = allDonors.values();
        
        for (uint256 i; i < donors.length && i < 1000;) { // Limit iteration
            DonorProfile memory profile = donorProfiles[donors[i]];
            totalVolume += profile.totalDonated;
            totalDonationCount += profile.donationCount;
            unchecked { ++i; }
        }
        
        platformInsights = PlatformInsights({
            totalVolume: totalVolume,
            totalDonors: allDonors.length(),
            totalCampaigns: totalCampaigns,
            avgDonationSize: totalDonationCount > 0 ? totalVolume / totalDonationCount : 0,
            topCampaignVolume: topVolume,
            topCampaign: topCampaign,
            lastUpdated: block.timestamp
        });
        
        emit InsightsGenerated(totalVolume, allDonors.length(), block.timestamp);
    }
    
    // ============ Data Verification ============
    
    /**
     * @notice Submit verified data with merkle proof
     * @param dataHash Hash of the data
     * @param proof Merkle proof
     */
    function submitVerifiedData(
        bytes32 dataHash,
        bytes32[] calldata proof
    ) external onlyRole(OPERATOR_ROLE) {
        if (processedReports[dataHash]) revert AlreadyProcessed();
        
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, dataHash));
        if (!MerkleProof.verify(proof, dataRoot, leaf)) revert InvalidProof();
        
        processedReports[dataHash] = true;
        emit DataSubmitted(msg.sender, dataHash, block.timestamp);
    }
    
    /**
     * @notice Update data root for verification
     * @param newRoot New merkle root
     */
    function updateDataRoot(bytes32 newRoot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        dataRoot = newRoot;
    }
    
    // ============ External Integrations ============
    
    /**
     * @notice Set REFI treasury contract
     * @param _refiTreasury Treasury address
     */
    function setREFITreasury(address _refiTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) validAddress(_refiTreasury) {
        refiTreasury = IREFITreasury(_refiTreasury);
    }
    
    /**
     * @notice Contribute to REFI treasury on behalf of NGO
     * @param amount Amount to contribute
     * @param source Source description
     */
    function contributeToREFI(
        uint256 amount,
        string calldata source
    ) external nonReentrant onlyRegisteredNGO {
        if (address(refiTreasury) == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        // Note: Assumes NGO has approved this contract for REFI token
        // Implementation would include token transfer and treasury deposit
        
        emit REFIContribution(msg.sender, amount, source);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get all templates for an NGO
     * @param ngo NGO address
     * @return templates Array of templates
     */
    function getNGOTemplates(address ngo) external view returns (BeneficiaryTemplate[] memory) {
        return beneficiaryTemplates[ngo];
    }
    
    /**
     * @notice Get active templates only
     * @param ngo NGO address
     * @return activeTemplates Array of active templates
     */
    function getActiveTemplates(address ngo) external view returns (BeneficiaryTemplate[] memory activeTemplates) {
        BeneficiaryTemplate[] memory allTemplates = beneficiaryTemplates[ngo];
        uint256 activeCount;
        
        // Count active templates
        for (uint256 i; i < allTemplates.length;) {
            if (allTemplates[i].isActive) activeCount++;
            unchecked { ++i; }
        }
        
        // Build active array
        activeTemplates = new BeneficiaryTemplate[](activeCount);
        uint256 index;
        
        for (uint256 i; i < allTemplates.length;) {
            if (allTemplates[i].isActive) {
                activeTemplates[index++] = allTemplates[i];
            }
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get campaign goals
     * @param campaign Campaign address
     * @return goals Array of goals
     */
    function getCampaignGoals(address campaign) external view returns (CampaignGoal[] memory) {
        return campaignGoals[campaign];
    }
    
    /**
     * @notice Get active goals for a campaign
     * @param campaign Campaign address
     * @return goalIds Array of active goal IDs
     */
    function getActiveGoals(address campaign) external view returns (uint256[] memory) {
        return activeGoals[campaign].values();
    }
    
    /**
     * @notice Get comprehensive donor insights
     * @param donor Donor address
     * @return profile Donor profile
     * @return supportedCampaigns Array of supported campaigns
     */
    function getDonorInsights(address donor) external view returns (
        DonorProfile memory profile,
        address[] memory supportedCampaigns
    ) {
        profile = donorProfiles[donor];
        supportedCampaigns = donorCampaigns[donor].values();
    }
    
    /**
     * @notice Get top donors for a campaign
     * @param campaign Campaign address
     * @param limit Maximum number to return
     * @return donors Array of donor addresses
     * @return amounts Array of donation amounts
     */
    function getTopDonors(
        address campaign,
        uint256 limit
    ) external view returns (
        address[] memory donors,
        uint256[] memory amounts
    ) {
        address[] memory allCampaignDonors = campaignDonors[campaign].values();
        uint256 count = allCampaignDonors.length < limit ? allCampaignDonors.length : limit;
        
        donors = new address[](count);
        amounts = new uint256[](count);
        
        // Note: In production, this would be maintained as a sorted list
        for (uint256 i; i < count;) {
            donors[i] = allCampaignDonors[i];
            amounts[i] = donorCampaignAmount[donors[i]][campaign];
            unchecked { ++i; }
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Get campaign metrics with cache check
     */
    function _getCampaignMetrics(address campaign) internal view returns (CampaignMetrics memory) {
        CampaignMetrics memory metrics = campaignMetrics[campaign];
        
        // If metrics are stale or don't exist, return basic info
        if (metrics.totalRaised == 0 || metrics.metricsStale) {
            (, , , uint256 totalRaised, ) = IDonationCampaign(campaign).getCampaignInfo();
            metrics.totalRaised = uint128(totalRaised);
        }
        
        return metrics;
    }
    
    /**
     * @dev Count recurring donors for a campaign
     */
    function _countRecurringDonors(address campaign) internal view returns (uint256 count) {
        address[] memory donors = campaignDonors[campaign].values();
        
        for (uint256 i; i < donors.length && i < 100;) { // Limit to prevent gas issues
            try IDonationCampaign(campaign).getRecurringDonation(donors[i]) returns (
                uint256, uint256, uint256, address, bool active
            ) {
                if (active) count++;
            } catch {}
            unchecked { ++i; }
        }
    }
    
    /**
     * @dev Update NGO success metrics after goal achievement
     */
    function _updateNGOSuccessMetrics(address ngo) internal {
        NGODashboard storage dashboard = ngoDashboards[ngo];
        dashboard.goalsAchieved++;
        
        // Recalculate success rate
        address[] memory campaigns = registry.getNGOCampaigns(ngo);
        uint256 totalGoals;
        
        for (uint256 i; i < campaigns.length;) {
            totalGoals += campaignGoals[campaigns[i]].length;
            unchecked { ++i; }
        }
        
        if (totalGoals > 0) {
            dashboard.successRate = uint16((dashboard.goalsAchieved * 10000) / totalGoals);
        }
    }
}
