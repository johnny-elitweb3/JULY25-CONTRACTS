// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Note: Requires OpenZeppelin Contracts v4.8.0 or higher for safeIncreaseAllowance
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Interfaces for interacting with the donation ecosystem
 */
interface IDonationContract {
    struct ChildInfo {
        address childAddress;
        uint96 percentage;
    }
    
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
    
    // View functions
    function ngoOwner() external view returns (address);
    function contractName() external view returns (string memory);
    function children(uint256) external view returns (address, uint96);
    function getChildrenCount() external view returns (uint256);
    function getChildTitle(uint256 index) external view returns (string memory);
    function acceptedTokens(address) external view returns (bool);
    function donorStats(address) external view returns (DonationStats memory);
    function recurringDonations(address, uint256) external view returns (RecurringDonation memory);
    function yearlyDonations(address, uint256) external view returns (uint256);
    function getAllDonors() external view returns (address[] memory);
    function totalPercentage() external view returns (uint96);
    function receiptNFT() external view returns (address);
    
    // Management functions
    function updateChildren(address[] calldata, uint96[] calldata, string[] calldata) external;
    function addAcceptedToken(address) external;
    function removeAcceptedToken(address) external;
    function pause() external;
    function unpause() external;
    function rescueNative(address payable) external;
    function rescueERC20(address, address) external;
}

interface IDonationFactory {
    function allDonationContracts(uint256) external view returns (address);
    function getDonationContractsCount() external view returns (uint256);
    function getAllDonationContracts() external view returns (address[] memory);
}

interface IDonationReceiptNFT {
    struct ReceiptData {
        address donor;
        address donationContract;
        address token;
        uint256 amount;
        uint256 timestamp;
        string donationURI;
    }
    
    function totalSupply() external view returns (uint256);
    function setBaseURI(string memory) external;
    function getReceiptData(uint256 tokenId) external view returns (ReceiptData memory);
}

interface IREFITreasury {
    function deposit(uint256 amount, string calldata source) external;
    function getPoolAnalytics() external view returns (
        uint256 totalBalance,
        uint256 availableBalance,
        uint256 allocatedBalance,
        uint256 pendingRewards,
        uint256 totalDeposits,
        uint256 totalDistributions,
        uint256 depositorCount,
        uint256 averageDepositSize,
        uint256 lastActivityTime
    );
}

interface IREFIToken is IERC20 {
    // REFI token specific functions if any
}

/**
 * @title NGODashboard
 * @dev Enhanced dashboard for NGOs to manage their donation contracts in the CIFI GIVE ecosystem
 * 
 * Features:
 * - Multi-contract management for NGOs with multiple campaigns
 * - Beneficiary (children) management across contracts
 * - Advanced analytics and reporting
 * - Token management and whitelisting
 * - Emergency controls and security features
 * - Integration with REFI Treasury and staking systems
 * - Donor relationship management
 * - Campaign performance tracking
 * - Automated reporting and notifications
 */
contract NGODashboard is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    
    // ========== Errors ==========
    error NotNGOOwner();
    error NotRegistered();
    error InvalidContract();
    error InvalidParameters();
    error ContractPaused();
    error ZeroAddress();
    error TransferFailed();
    error UnauthorizedAccess();
    error AlreadyRegistered();
    error InvalidPercentage();
    error ArrayLengthMismatch();
    error CategoryLimitExceeded();
    error StringTooLong();
    error InvalidTimeRange();
    
    // ========== Constants ==========
    uint256 public constant MAX_CATEGORIES = 10;
    uint256 public constant MAX_STRING_LENGTH = 256;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant ANALYTICS_UPDATE_COOLDOWN = 1 hours;
    
    // ========== Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    
    // ========== State Variables ==========
    
    // NGO Profile Information (fixed for calldata issue)
    struct NGOProfile {
        string organizationName;
        string description;
        string website;
        string logoURI;
        bool isVerified;
        uint256 establishedDate;
        address primaryContact;
        uint256 categoryCount;
        // Categories stored separately to avoid nested array issues
    }
    
    // Separate mapping for categories
    mapping(address => mapping(uint256 => string)) public ngoCategories;
    
    // Beneficiary Template for easy management
    struct BeneficiaryTemplate {
        string name;
        address walletAddress;
        uint96 defaultPercentage;
        string description;
        bool isActive;
        uint256 createdAt;
        uint256 lastUsed;
        uint256 useCount;
    }
    
    // Enhanced Campaign Analytics
    struct CampaignAnalytics {
        uint256 totalRaised;
        uint256 uniqueDonors;
        uint256 recurringDonors;
        uint256 averageDonation;
        uint256 lastDonationTime;
        uint256 nftsIssued;
        uint256 lastUpdated;
        uint256 monthlyGrowthRate; // Percentage with 2 decimals (10000 = 100%)
        uint256 donorRetentionRate; // Percentage with 2 decimals
    }
    
    // Campaign Goals and Milestones
    struct CampaignGoal {
        uint256 targetAmount;
        uint256 deadline;
        string description;
        bool achieved;
        uint256 achievedAt;
    }
    
    // NGO Performance Metrics
    struct NGOMetrics {
        uint256 totalCampaigns;
        uint256 activeCampaigns;
        uint256 lifetimeRaised;
        uint256 lifetimeDonors;
        uint256 averageCampaignSize;
        uint256 successRate; // Percentage of goals achieved
        uint256 lastActive;
    }
    
    // State mappings
    mapping(address => NGOProfile) public ngoProfiles;
    mapping(address => EnumerableSet.AddressSet) private ngoContracts;
    mapping(address => BeneficiaryTemplate[]) public beneficiaryTemplates;
    mapping(address => CampaignAnalytics) public campaignAnalytics;
    mapping(address => mapping(address => uint256)) private lastAnalyticsUpdate;
    mapping(address => CampaignGoal[]) public campaignGoals;
    mapping(address => NGOMetrics) public ngoMetrics;
    
    // Global registry
    EnumerableSet.AddressSet private registeredNGOs;
    EnumerableSet.AddressSet private verifiedNGOs;
    
    // External contract references
    IDonationFactory public immutable donationFactory;
    IREFITreasury public treasuryContract;
    address public stakingContract;
    address public refiToken;
    
    // Analytics aggregation
    uint256 public totalPlatformRaised;
    uint256 public totalPlatformDonors;
    uint256 public totalPlatformNFTs;
    
    // ========== Events ==========
    event NGORegistered(address indexed ngo, string organizationName);
    event NGOVerified(address indexed ngo, address indexed verifier);
    event NGOProfileUpdated(address indexed ngo);
    event ContractLinked(address indexed ngo, address indexed donationContract);
    event ContractUnlinked(address indexed ngo, address indexed donationContract);
    event BeneficiaryTemplateCreated(address indexed ngo, uint256 templateId, string name);
    event BeneficiaryTemplateUpdated(address indexed ngo, uint256 templateId);
    event BeneficiariesUpdated(address indexed donationContract, uint256 childrenCount);
    event TokensManaged(address indexed donationContract, address token, bool added);
    event EmergencyActionTaken(address indexed donationContract, string action);
    event AnalyticsUpdated(address indexed donationContract, uint256 totalRaised);
    event CampaignGoalSet(address indexed donationContract, uint256 goalId, uint256 targetAmount);
    event CampaignGoalAchieved(address indexed donationContract, uint256 goalId);
    event MetricsUpdated(address indexed ngo, uint256 lifetimeRaised);
    
    // ========== Modifiers ==========
    modifier onlyRegisteredNGO() {
        if (!registeredNGOs.contains(msg.sender)) revert NotRegistered();
        _;
    }
    
    modifier onlyVerifiedNGO(address ngo) {
        if (!verifiedNGOs.contains(ngo)) revert UnauthorizedAccess();
        _;
    }
    
    modifier validString(string memory str) {
        if (bytes(str).length > MAX_STRING_LENGTH) revert StringTooLong();
        _;
    }
    
    // ========== Constructor ==========
    constructor(
        address _donationFactory,
        address _treasuryContract
    ) {
        if (_donationFactory == address(0)) revert ZeroAddress();
        
        donationFactory = IDonationFactory(_donationFactory);
        treasuryContract = IREFITreasury(_treasuryContract);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    // ========== Registration & Profile Management ==========
    
    /**
     * @dev Register as an NGO and create profile (fixed calldata array issue)
     */
    function registerNGO(
        string memory organizationName,
        string memory description,
        string memory website,
        string memory logoURI,
        string[] memory categories
    ) external validString(organizationName) validString(description) {
        if (registeredNGOs.contains(msg.sender)) revert AlreadyRegistered();
        if (bytes(organizationName).length == 0) revert InvalidParameters();
        if (categories.length > MAX_CATEGORIES) revert CategoryLimitExceeded();
        
        // Create profile without categories array
        ngoProfiles[msg.sender] = NGOProfile({
            organizationName: organizationName,
            description: description,
            website: website,
            logoURI: logoURI,
            isVerified: false,
            establishedDate: block.timestamp,
            primaryContact: msg.sender,
            categoryCount: categories.length
        });
        
        // Store categories separately
        for (uint256 i = 0; i < categories.length; i++) {
            if (bytes(categories[i]).length > MAX_STRING_LENGTH) revert StringTooLong();
            ngoCategories[msg.sender][i] = categories[i];
        }
        
        // Initialize metrics
        ngoMetrics[msg.sender] = NGOMetrics({
            totalCampaigns: 0,
            activeCampaigns: 0,
            lifetimeRaised: 0,
            lifetimeDonors: 0,
            averageCampaignSize: 0,
            successRate: 0,
            lastActive: block.timestamp
        });
        
        registeredNGOs.add(msg.sender);
        emit NGORegistered(msg.sender, organizationName);
    }
    
    /**
     * @dev Update NGO profile information
     */
    function updateProfile(
        string memory description,
        string memory website,
        string memory logoURI,
        string[] memory categories
    ) external onlyRegisteredNGO validString(description) {
        if (categories.length > MAX_CATEGORIES) revert CategoryLimitExceeded();
        
        NGOProfile storage profile = ngoProfiles[msg.sender];
        profile.description = description;
        profile.website = website;
        profile.logoURI = logoURI;
        profile.categoryCount = categories.length;
        
        // Update categories
        for (uint256 i = 0; i < categories.length; i++) {
            if (bytes(categories[i]).length > MAX_STRING_LENGTH) revert StringTooLong();
            ngoCategories[msg.sender][i] = categories[i];
        }
        
        // Clear old categories if new list is shorter
        for (uint256 i = categories.length; i < MAX_CATEGORIES; i++) {
            delete ngoCategories[msg.sender][i];
        }
        
        emit NGOProfileUpdated(msg.sender);
    }
    
    /**
     * @dev Link existing donation contracts to NGO profile
     */
    function linkDonationContract(address donationContract) external onlyRegisteredNGO {
        if (donationContract == address(0)) revert ZeroAddress();
        
        // Verify ownership
        try IDonationContract(donationContract).ngoOwner() returns (address owner) {
            if (owner != msg.sender) revert NotNGOOwner();
        } catch {
            revert InvalidContract();
        }
        
        if (ngoContracts[msg.sender].add(donationContract)) {
            // Update metrics
            NGOMetrics storage metrics = ngoMetrics[msg.sender];
            metrics.totalCampaigns++;
            metrics.activeCampaigns++;
            metrics.lastActive = block.timestamp;
            
            emit ContractLinked(msg.sender, donationContract);
            
            // Update analytics
            _updateCampaignAnalytics(donationContract);
        }
    }
    
    /**
     * @dev Unlink a donation contract
     */
    function unlinkDonationContract(address donationContract) external onlyRegisteredNGO {
        if (ngoContracts[msg.sender].remove(donationContract)) {
            NGOMetrics storage metrics = ngoMetrics[msg.sender];
            if (metrics.activeCampaigns > 0) {
                metrics.activeCampaigns--;
            }
            
            emit ContractUnlinked(msg.sender, donationContract);
        }
    }
    
    // ========== Beneficiary Management ==========
    
    /**
     * @dev Create a beneficiary template for reuse across campaigns
     */
    function createBeneficiaryTemplate(
        string memory name,
        address walletAddress,
        uint96 defaultPercentage,
        string memory description
    ) external onlyRegisteredNGO validString(name) validString(description) {
        if (walletAddress == address(0)) revert ZeroAddress();
        if (defaultPercentage == 0 || defaultPercentage > 10000) revert InvalidPercentage();
        
        beneficiaryTemplates[msg.sender].push(BeneficiaryTemplate({
            name: name,
            walletAddress: walletAddress,
            defaultPercentage: defaultPercentage,
            description: description,
            isActive: true,
            createdAt: block.timestamp,
            lastUsed: 0,
            useCount: 0
        }));
        
        uint256 templateId = beneficiaryTemplates[msg.sender].length - 1;
        emit BeneficiaryTemplateCreated(msg.sender, templateId, name);
    }
    
    /**
     * @dev Update an existing beneficiary template
     */
    function updateBeneficiaryTemplate(
        uint256 templateId,
        string memory name,
        address walletAddress,
        uint96 defaultPercentage,
        string memory description,
        bool isActive
    ) external onlyRegisteredNGO validString(name) validString(description) {
        BeneficiaryTemplate[] storage templates = beneficiaryTemplates[msg.sender];
        if (templateId >= templates.length) revert InvalidParameters();
        
        BeneficiaryTemplate storage template = templates[templateId];
        template.name = name;
        template.walletAddress = walletAddress;
        template.defaultPercentage = defaultPercentage;
        template.description = description;
        template.isActive = isActive;
        
        emit BeneficiaryTemplateUpdated(msg.sender, templateId);
    }
    
    /**
     * @dev Update beneficiaries for a donation contract using templates
     */
    function updateBeneficiariesFromTemplates(
        address donationContract,
        uint256[] calldata templateIds,
        uint96[] calldata customPercentages
    ) external nonReentrant onlyRegisteredNGO {
        _verifyContractOwnership(msg.sender, donationContract);
        
        if (templateIds.length == 0 || templateIds.length != customPercentages.length) {
            revert InvalidParameters();
        }
        
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
            
            // Update template usage
            template.lastUsed = block.timestamp;
            template.useCount++;
        }
        
        if (totalPercentage != 10000) revert InvalidPercentage();
        
        IDonationContract(donationContract).updateChildren(addresses, percentages, titles);
        emit BeneficiariesUpdated(donationContract, addresses.length);
    }
    
    // ========== Campaign Goals & Milestones ==========
    
    /**
     * @dev Set a fundraising goal for a campaign
     */
    function setCampaignGoal(
        address donationContract,
        uint256 targetAmount,
        uint256 deadline,
        string memory description
    ) external nonReentrant onlyRegisteredNGO validString(description) {
        _verifyContractOwnership(msg.sender, donationContract);
        
        if (targetAmount == 0) revert InvalidParameters();
        if (deadline <= block.timestamp) revert InvalidParameters();
        
        campaignGoals[donationContract].push(CampaignGoal({
            targetAmount: targetAmount,
            deadline: deadline,
            description: description,
            achieved: false,
            achievedAt: 0
        }));
        
        uint256 goalId = campaignGoals[donationContract].length - 1;
        emit CampaignGoalSet(donationContract, goalId, targetAmount);
    }
    
    /**
     * @dev Check and update goal achievement status
     */
    function checkGoalAchievement(address donationContract, uint256 goalId) external {
        CampaignGoal[] storage goals = campaignGoals[donationContract];
        if (goalId >= goals.length) revert InvalidParameters();
        
        CampaignGoal storage goal = goals[goalId];
        if (goal.achieved) return;
        
        CampaignAnalytics memory analytics = campaignAnalytics[donationContract];
        if (analytics.totalRaised >= goal.targetAmount) {
            goal.achieved = true;
            goal.achievedAt = block.timestamp;
            
            // Update success rate
            _updateNGOSuccessRate(IDonationContract(donationContract).ngoOwner());
            
            emit CampaignGoalAchieved(donationContract, goalId);
        }
    }
    
    // ========== Analytics & Reporting ==========
    
    /**
     * @dev Get comprehensive analytics for all NGO contracts
     */
    function getNGOAnalytics(address ngo) external view returns (
        uint256 totalContractsCount,
        uint256 totalRaisedAllTime,
        uint256 totalUniqueDonors,
        uint256 totalNFTsIssued,
        uint256 averageDonationSize,
        uint256 activeRecurringDonors,
        uint256 monthlyGrowthRate,
        uint256 successRate
    ) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        NGOMetrics memory metrics = ngoMetrics[ngo];
        totalContractsCount = metrics.totalCampaigns;
        totalRaisedAllTime = metrics.lifetimeRaised;
        totalUniqueDonors = metrics.lifetimeDonors;
        averageDonationSize = metrics.lifetimeDonors > 0 ? metrics.lifetimeRaised / metrics.lifetimeDonors : 0;
        successRate = metrics.successRate;
        
        // Aggregate current data from all contracts
        EnumerableSet.AddressSet storage contracts = ngoContracts[ngo];
        for (uint256 i = 0; i < contracts.length(); i++) {
            CampaignAnalytics memory analytics = campaignAnalytics[contracts.at(i)];
            totalNFTsIssued += analytics.nftsIssued;
            activeRecurringDonors += analytics.recurringDonors;
            monthlyGrowthRate += analytics.monthlyGrowthRate;
        }
        
        // Average growth rate
        if (contracts.length() > 0) {
            monthlyGrowthRate = monthlyGrowthRate / contracts.length();
        }
    }
    
    /**
     * @dev Update analytics for a specific campaign
     */
    function updateCampaignAnalytics(address donationContract) external whenNotPaused {
        // Rate limit updates
        if (block.timestamp < lastAnalyticsUpdate[msg.sender][donationContract] + ANALYTICS_UPDATE_COOLDOWN) {
            revert InvalidTimeRange();
        }
        
        _updateCampaignAnalytics(donationContract);
        lastAnalyticsUpdate[msg.sender][donationContract] = block.timestamp;
    }
    
    function _updateCampaignAnalytics(address donationContract) internal {
        try IDonationContract(donationContract).getAllDonors() returns (address[] memory donors) {
            uint256 totalRaised = 0;
            uint256 recurringCount = 0;
            
            // Calculate totals
            for (uint256 i = 0; i < donors.length; i++) {
                IDonationContract.DonationStats memory stats = IDonationContract(donationContract).donorStats(donors[i]);
                totalRaised += stats.totalDonated;
                
                // Check for active recurring donations
                try IDonationContract(donationContract).recurringDonations(donors[i], 0) returns (IDonationContract.RecurringDonation memory rd) {
                    if (rd.active) recurringCount++;
                } catch {}
            }
            
            // Get NFT count
            uint256 nftCount = 0;
            try IDonationReceiptNFT(IDonationContract(donationContract).receiptNFT()).totalSupply() returns (uint256 supply) {
                nftCount = supply;
            } catch {}
            
            // Calculate growth rate
            CampaignAnalytics storage analytics = campaignAnalytics[donationContract];
            uint256 previousTotal = analytics.totalRaised;
            uint256 growthRate = 0;
            
            if (previousTotal > 0 && analytics.lastUpdated > 0) {
                uint256 timeDiff = block.timestamp - analytics.lastUpdated;
                if (timeDiff > 0) {
                    // Calculate monthly growth rate
                    growthRate = ((totalRaised - previousTotal) * 10000 * 30 days) / (previousTotal * timeDiff);
                }
            }
            
            // Update analytics
            analytics.totalRaised = totalRaised;
            analytics.uniqueDonors = donors.length;
            analytics.recurringDonors = recurringCount;
            analytics.averageDonation = donors.length > 0 ? totalRaised / donors.length : 0;
            analytics.lastDonationTime = block.timestamp;
            analytics.nftsIssued = nftCount;
            analytics.lastUpdated = block.timestamp;
            analytics.monthlyGrowthRate = growthRate;
            analytics.donorRetentionRate = donors.length > 0 ? (recurringCount * 10000) / donors.length : 0;
            
            // Update NGO metrics
            address ngoOwner = IDonationContract(donationContract).ngoOwner();
            _updateNGOMetrics(ngoOwner, totalRaised, donors.length);
            
            // Update platform totals
            totalPlatformRaised += totalRaised - previousTotal;
            
            emit AnalyticsUpdated(donationContract, totalRaised);
        } catch {}
    }
    
    function _updateNGOMetrics(address ngo, uint256 campaignTotal, uint256 donorCount) internal {
        NGOMetrics storage metrics = ngoMetrics[ngo];
        
        // Update lifetime totals (avoiding double counting)
        if (campaignTotal > metrics.lifetimeRaised) {
            metrics.lifetimeRaised = campaignTotal;
        }
        
        if (donorCount > metrics.lifetimeDonors) {
            metrics.lifetimeDonors = donorCount;
        }
        
        // Update average campaign size
        if (metrics.activeCampaigns > 0) {
            metrics.averageCampaignSize = metrics.lifetimeRaised / metrics.activeCampaigns;
        }
        
        metrics.lastActive = block.timestamp;
        
        emit MetricsUpdated(ngo, metrics.lifetimeRaised);
    }
    
    function _updateNGOSuccessRate(address ngo) internal {
        NGOMetrics storage metrics = ngoMetrics[ngo];
        
        // Count achieved goals across all campaigns
        uint256 totalGoals = 0;
        uint256 achievedGoals = 0;
        
        EnumerableSet.AddressSet storage contracts = ngoContracts[ngo];
        for (uint256 i = 0; i < contracts.length(); i++) {
            CampaignGoal[] storage goals = campaignGoals[contracts.at(i)];
            for (uint256 j = 0; j < goals.length; j++) {
                totalGoals++;
                if (goals[j].achieved) {
                    achievedGoals++;
                }
            }
        }
        
        metrics.successRate = totalGoals > 0 ? (achievedGoals * 10000) / totalGoals : 0;
    }
    
    // ========== Token Management ==========
    
    /**
     * @dev Batch update accepted tokens across multiple contracts
     */
    function batchUpdateAcceptedTokens(
        address[] calldata donationContracts,
        address[] calldata tokens,
        bool[] calldata addToken
    ) external nonReentrant whenNotPaused onlyRegisteredNGO {
        if (donationContracts.length != tokens.length || tokens.length != addToken.length) {
            revert ArrayLengthMismatch();
        }
        if (donationContracts.length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i = 0; i < donationContracts.length; i++) {
            _verifyContractOwnership(msg.sender, donationContracts[i]);
            
            if (tokens[i] == address(0)) revert ZeroAddress();
            
            if (addToken[i]) {
                IDonationContract(donationContracts[i]).addAcceptedToken(tokens[i]);
            } else {
                IDonationContract(donationContracts[i]).removeAcceptedToken(tokens[i]);
            }
            
            emit TokensManaged(donationContracts[i], tokens[i], addToken[i]);
        }
    }
    
    // ========== Donor Management ==========
    
    /**
     * @dev Get comprehensive donor insights across all NGO contracts
     */
    function getDonorInsights(
        address ngo,
        address donor
    ) external view returns (
        uint256 totalDonated,
        uint256 contractsDonatedTo,
        uint256[] memory yearlyTotals,
        bool hasActiveRecurring,
        uint256 largestSingleDonation,
        uint256 totalDonationCount
    ) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        EnumerableSet.AddressSet storage contracts = ngoContracts[ngo];
        uint256 currentYear = 1970 + (block.timestamp / 365 days);
        yearlyTotals = new uint256[](5); // Last 5 years
        
        for (uint256 i = 0; i < contracts.length(); i++) {
            address contractAddr = contracts.at(i);
            
            try IDonationContract(contractAddr).donorStats(donor) returns (IDonationContract.DonationStats memory stats) {
                if (stats.donationCount > 0) {
                    totalDonated += stats.totalDonated;
                    contractsDonatedTo++;
                    totalDonationCount += stats.donationCount;
                    
                    if (stats.largestDonation > largestSingleDonation) {
                        largestSingleDonation = stats.largestDonation;
                    }
                    
                    // Get yearly donations for the last 5 years
                    for (uint256 year = 0; year < 5; year++) {
                        uint256 checkYear = currentYear - year;
                        try IDonationContract(contractAddr).yearlyDonations(donor, checkYear) returns (uint256 amount) {
                            yearlyTotals[year] += amount;
                        } catch {}
                    }
                    
                    // Check for active recurring
                    if (!hasActiveRecurring) {
                        try IDonationContract(contractAddr).recurringDonations(donor, 0) returns (IDonationContract.RecurringDonation memory rd) {
                            if (rd.active) hasActiveRecurring = true;
                        } catch {}
                    }
                }
            } catch {}
        }
    }
    
    // ========== Integration Functions ==========
    
    /**
     * @dev Contribute to REFI Treasury on behalf of the NGO
     * @notice NGO must have approved this contract to spend REFI tokens
     */
    function contributeToTreasury(
        uint256 amount, 
        string memory source
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRegisteredNGO 
        validString(source) 
    {
        if (amount == 0) revert InvalidParameters();
        if (address(treasuryContract) == address(0)) revert ZeroAddress();
        if (refiToken == address(0)) revert ZeroAddress();
        
        // Transfer tokens from NGO to this contract
        IERC20 token = IERC20(refiToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;
        
        // Use safeIncreaseAllowance instead of safeApprove
        token.safeIncreaseAllowance(address(treasuryContract), actualReceived);
        
        // Deposit to treasury
        treasuryContract.deposit(actualReceived, source);
        
        // Update NGO activity
        ngoMetrics[msg.sender].lastActive = block.timestamp;
    }
    
    // ========== Emergency Functions ==========
    
    /**
     * @dev Emergency pause multiple contracts
     */
    function emergencyPauseContracts(address[] calldata donationContracts) 
        external 
        nonReentrant 
        onlyRegisteredNGO 
    {
        if (donationContracts.length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i = 0; i < donationContracts.length; i++) {
            _verifyContractOwnership(msg.sender, donationContracts[i]);
            IDonationContract(donationContracts[i]).pause();
            emit EmergencyActionTaken(donationContracts[i], "PAUSED");
        }
    }
    
    /**
     * @dev Resume paused contracts
     */
    function resumeContracts(address[] calldata donationContracts) 
        external 
        nonReentrant 
        onlyRegisteredNGO 
    {
        if (donationContracts.length > MAX_BATCH_SIZE) revert InvalidParameters();
        
        for (uint256 i = 0; i < donationContracts.length; i++) {
            _verifyContractOwnership(msg.sender, donationContracts[i]);
            IDonationContract(donationContracts[i]).unpause();
            emit EmergencyActionTaken(donationContracts[i], "RESUMED");
        }
    }
    
    // ========== View Functions ==========
    
    /**
     * @dev Get NGO categories
     */
    function getNGOCategories(address ngo) external view returns (string[] memory) {
        uint256 count = ngoProfiles[ngo].categoryCount;
        string[] memory categories = new string[](count);
        
        for (uint256 i = 0; i < count; i++) {
            categories[i] = ngoCategories[ngo][i];
        }
        
        return categories;
    }
    
    /**
     * @dev Get all contracts owned by an NGO
     */
    function getNGOContracts(address ngo) external view returns (address[] memory) {
        return ngoContracts[ngo].values();
    }
    
    /**
     * @dev Get campaign goals for a contract
     */
    function getCampaignGoals(address donationContract) external view returns (CampaignGoal[] memory) {
        return campaignGoals[donationContract];
    }
    
    /**
     * @dev Check if NGO is verified
     */
    function isVerifiedNGO(address ngo) external view returns (bool) {
        return verifiedNGOs.contains(ngo);
    }
    
    /**
     * @dev Get platform-wide statistics
     */
    function getPlatformStats() external view returns (
        uint256 totalNGOs,
        uint256 verifiedNGOs_,
        uint256 totalRaised,
        uint256 totalDonors,
        uint256 totalNFTs
    ) {
        totalNGOs = registeredNGOs.length();
        verifiedNGOs_ = verifiedNGOs.length();
        totalRaised = totalPlatformRaised;
        totalDonors = totalPlatformDonors;
        totalNFTs = totalPlatformNFTs;
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @dev Verify an NGO (admin only)
     */
    function verifyNGO(address ngo) external onlyRole(VERIFIER_ROLE) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        ngoProfiles[ngo].isVerified = true;
        verifiedNGOs.add(ngo);
        
        emit NGOVerified(ngo, msg.sender);
    }
    
    /**
     * @dev Set treasury contract address
     */
    function setTreasuryContract(address _treasuryContract) external onlyRole(ADMIN_ROLE) {
        if (_treasuryContract == address(0)) revert ZeroAddress();
        treasuryContract = IREFITreasury(_treasuryContract);
    }
    
    /**
     * @dev Set REFI token address
     */
    function setREFIToken(address _refiToken) external onlyRole(ADMIN_ROLE) {
        if (_refiToken == address(0)) revert ZeroAddress();
        refiToken = _refiToken;
    }
    
    /**
     * @dev Set staking contract address
     */
    function setStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        if (_stakingContract == address(0)) revert ZeroAddress();
        stakingContract = _stakingContract;
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // ========== Internal Functions ==========
    
    function _verifyContractOwnership(address ngo, address donationContract) internal view {
        if (!ngoContracts[ngo].contains(donationContract)) revert UnauthorizedAccess();
        
        // Double-check ownership
        try IDonationContract(donationContract).ngoOwner() returns (address owner) {
            if (owner != ngo) revert NotNGOOwner();
        } catch {
            revert InvalidContract();
        }
    }
}
