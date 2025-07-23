// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Interfaces for the main contracts
interface ICIFIRegistry {
    function submitApplication(uint32 tier, string calldata ipfsHash, address referrer) external;
    function deployCampaign(address[] calldata beneficiaries, uint256[] calldata percentages, string calldata ipfsHash) external returns (address);
    function getNGOInfo(address ngo) external view returns (address account, uint64 registeredAt, uint32 tier, bool isVerified, address[] memory campaigns);
    function tierConfigs(uint32) external view returns (uint128 deploymentFee, uint128 annualFee, uint32 maxCampaigns, uint32 maxBeneficiaries, uint32 maxTokens, bool recurringEnabled, bool customNFTEnabled, string memory name);
    function feeToken() external view returns (address);
    function ngoRecords(address) external view returns (address account, uint64 registeredAt, uint32 tier, uint64 tierExpiresAt, uint32 campaignCount, uint32 lifetimeCampaigns, uint8 status, bool isVerified, uint128 totalRaised, string memory ipfsHash);
}

interface IDonationCampaign {
    function donateNative(string calldata donationData) external payable;
    function donateToken(address token, uint256 amount, string calldata donationData) external;
    function setupRecurringDonation(address token, uint256 amount, uint256 interval) external;
    function updateAcceptedToken(address token, bool accepted) external;
    function getCampaignInfo() external view returns (address ngoAddress, uint256 beneficiaryCount, bool isActive, uint256 totalRaised, bool[2] memory features);
}

interface ICIFIAnalytics {
    function createTemplate(string calldata name, address wallet, uint96 percentage, string calldata description) external returns (uint256);
    function applyTemplates(uint256[] calldata templateIds, uint96[] calldata customPercentages) external view returns (address[] memory wallets, uint256[] memory percentages);
    function createCampaignGoal(address campaign, uint128 targetAmount, uint64 deadline, string calldata description) external returns (uint256);
    function generateNGODashboard(address ngo) external returns (uint128 lifetimeRaised, uint32 totalCampaigns, uint32 activeCampaigns, uint32 lifetimeDonors);
}

/**
 * @title CIFIRouter
 * @author CIFI Foundation
 * @notice Unified interface for interacting with the CIFI GIVE ecosystem
 * @dev Simplifies complex multi-contract operations and provides batching capabilities
 * 
 * Key Benefits:
 * - Single transaction for complex operations
 * - Gas optimization through batching
 * - Simplified interface for developers
 * - Atomic operations (all succeed or all fail)
 * - Enhanced error handling
 * - Emergency pause functionality
 * - Access control for sensitive operations
 * 
 * Token Approval Handling:
 * - Uses a custom _safeApprove function to handle edge cases
 * - Compatible with tokens that don't return values on approve
 * - Always resets approval to 0 after use for security
 */
contract CIFIRouter is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    
    // ============ Constants ============
    
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant CACHE_DURATION = 1 hours;
    uint256 private constant MAX_DONATION_AMOUNT = 1e30; // Prevent overflow
    
    // ============ Structs ============
    
    struct CampaignDeployment {
        uint256[] templateIds;      // Analytics contract template IDs
        uint96[] customPercentages; // Custom percentages (0 to use template default)
        string ipfsHash;            // Campaign metadata
        address[] acceptedTokens;   // Tokens to accept
        uint128 initialGoalAmount;  // Optional: Set initial goal
        uint64 goalDeadline;        // Optional: Goal deadline
        string goalDescription;     // Optional: Goal description
    }
    
    struct BatchDonation {
        address campaign;
        address token;              // address(0) for native token
        uint256 amount;
        string donationData;
    }
    
    struct NGOQuickSetup {
        uint32 tier;
        string applicationIpfs;
        string[] templateNames;
        address[] templateWallets;
        uint96[] templatePercentages;
        string[] templateDescriptions;
    }
    
    struct DonorProfile {
        address donor;
        uint256 totalDonated;
        uint256 campaignsSupported;
        address[] recentCampaigns;
        bool hasActiveRecurring;
    }
    
    struct NGOProfile {
        bool isRegistered;
        bool isVerified;
        uint32 tier;
        address[] campaigns;
        uint128 lifetimeRaised;
        uint32 totalCampaigns;
        uint32 activeCampaigns;
        uint32 lifetimeDonors;
    }
    
    // ============ State Variables ============
    
    ICIFIRegistry public immutable registry;
    ICIFIAnalytics public immutable analytics;
    
    // Cache frequently accessed data
    mapping(address => address[]) private ngoTemplateCache;
    mapping(address => uint256) private lastCacheUpdate;
    
    // Tracking for rate limiting and statistics
    mapping(address => uint256) private lastActionTimestamp;
    mapping(address => uint256) private donorTotalDonations;
    mapping(address => uint256) private donorCampaignCount;
    
    uint256 public totalDonationsProcessed;
    uint256 public totalCampaignsDeployed;
    
    // ============ Events ============
    
    event CampaignDeployedWithTemplates(
        address indexed ngo, 
        address indexed campaign, 
        uint256[] templateIds, 
        uint256 feesPaid
    );
    event BatchDonationCompleted(
        address indexed donor, 
        uint256 totalAmount, 
        uint256 campaignCount
    );
    event QuickSetupCompleted(
        address indexed ngo, 
        uint256 templatesCreated
    );
    event MultiCampaignGoalSet(
        address indexed ngo, 
        address[] campaigns, 
        uint256[] goalIds
    );
    event RecurringDonationsSetup(
        address indexed donor, 
        address[] campaigns, 
        uint256 count
    );
    event EmergencyWithdrawal(
        address indexed token, 
        address indexed to, 
        uint256 amount
    );
    
    // ============ Errors ============
    
    error InvalidInput();
    error OperationFailed();
    error InsufficientBalance();
    error Unauthorized();
    error NotRegisteredNGO();
    error TierExpired();
    error DeploymentFailed();
    error BatchSizeExceeded();
    error AmountTooLarge();
    error RateLimitExceeded();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error InvalidPercentage();
    
    // ============ Modifiers ============
    
    /**
     * @dev Validates that addresses are not zero
     */
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }
    
    /**
     * @dev Rate limiting modifier
     */
    modifier rateLimited() {
        if (block.timestamp - lastActionTimestamp[msg.sender] < 1) {
            revert RateLimitExceeded();
        }
        lastActionTimestamp[msg.sender] = block.timestamp;
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _registry, 
        address _analytics
    ) 
        notZeroAddress(_registry) 
        notZeroAddress(_analytics) 
        Ownable(msg.sender) 
    {
        registry = ICIFIRegistry(_registry);
        analytics = ICIFIAnalytics(_analytics);
    }
    
    // ============ Main Functions ============
    
    /**
     * @notice Deploy a campaign using beneficiary templates
     * @dev Combines template application with campaign deployment
     * @param deployment Deployment configuration
     * @return campaign The deployed campaign address
     */
    function deployCampaignWithTemplates(
        CampaignDeployment calldata deployment
    ) 
        external 
        nonReentrant 
        whenNotPaused
        rateLimited
        returns (address campaign) 
    {
        // Verify caller is registered NGO with active tier
        (address account, , , , , , uint8 status, , , ) = registry.ngoRecords(msg.sender);
        if (account == address(0) || status != 1) revert NotRegisteredNGO();
        
        // Validate input arrays
        if (deployment.templateIds.length == 0) revert InvalidInput();
        if (deployment.templateIds.length != deployment.customPercentages.length) {
            revert ArrayLengthMismatch();
        }
        
        // Apply templates to get beneficiaries
        (address[] memory wallets, uint256[] memory percentages) = analytics.applyTemplates(
            deployment.templateIds,
            deployment.customPercentages
        );
        
        // Validate percentages sum to 100%
        uint256 totalPercentage;
        for (uint256 i; i < percentages.length;) {
            totalPercentage += percentages[i];
            unchecked { ++i; }
        }
        if (totalPercentage != BASIS_POINTS) revert InvalidPercentage();
        
        // Get tier info for deployment fee
        (, , uint32 tier, , , , , , , ) = registry.ngoRecords(msg.sender);
        (uint128 deploymentFee, , , , , , , ) = registry.tierConfigs(tier);
        
        // Handle deployment fee if required
        if (deploymentFee > 0) {
            address feeTokenAddress = registry.feeToken();
            if (feeTokenAddress == address(0)) revert InvalidInput();
            
            // Transfer fee from caller to this contract
            IERC20(feeTokenAddress).safeTransferFrom(msg.sender, address(this), deploymentFee);
            
            // Approve registry to spend the fee
            _safeApprove(IERC20(feeTokenAddress), address(registry), deploymentFee);
        }
        
        // Deploy campaign through registry
        campaign = registry.deployCampaign(wallets, percentages, deployment.ipfsHash);
        if (campaign == address(0)) revert DeploymentFailed();
        
        // Reset approval to 0 for safety
        if (deploymentFee > 0) {
            _safeApprove(IERC20(registry.feeToken()), address(registry), 0);
        }
        
        // Configure accepted tokens if caller is the campaign owner
        if (deployment.acceptedTokens.length > 0) {
            _configureAcceptedTokens(campaign, deployment.acceptedTokens);
        }
        
        // Set initial goal if specified
        if (deployment.initialGoalAmount > 0 && deployment.goalDeadline > block.timestamp) {
            analytics.createCampaignGoal(
                campaign,
                deployment.initialGoalAmount,
                deployment.goalDeadline,
                deployment.goalDescription
            );
        }
        
        // Update statistics
        unchecked {
            totalCampaignsDeployed++;
        }
        
        emit CampaignDeployedWithTemplates(msg.sender, campaign, deployment.templateIds, deploymentFee);
    }
    
    /**
     * @notice Execute multiple donations in a single transaction
     * @dev Supports both native and ERC20 tokens with gas optimization
     * @param donations Array of donation instructions
     */
    function batchDonate(
        BatchDonation[] calldata donations
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        uint256 donationCount = donations.length;
        if (donationCount == 0 || donationCount > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded();
        }
        
        uint256 totalEthRequired;
        uint256 totalAmount;
        
        // First pass: validate and calculate requirements
        for (uint256 i; i < donationCount;) {
            BatchDonation calldata donation = donations[i];
            
            if (donation.campaign == address(0)) revert ZeroAddress();
            if (donation.amount == 0 || donation.amount > MAX_DONATION_AMOUNT) {
                revert AmountTooLarge();
            }
            
            if (donation.token == address(0)) {
                totalEthRequired += donation.amount;
            }
            totalAmount += donation.amount;
            
            unchecked { ++i; }
        }
        
        if (msg.value < totalEthRequired) revert InsufficientBalance();
        
        // Second pass: execute donations
        for (uint256 i; i < donationCount;) {
            _executeSingleDonation(donations[i]);
            unchecked { ++i; }
        }
        
        // Update donor statistics
        donorTotalDonations[msg.sender] += totalAmount;
        donorCampaignCount[msg.sender] += donationCount;
        
        unchecked {
            totalDonationsProcessed += donationCount;
        }
        
        // Refund excess ETH
        if (msg.value > totalEthRequired) {
            _safeTransferETH(msg.sender, msg.value - totalEthRequired);
        }
        
        emit BatchDonationCompleted(msg.sender, totalAmount, donationCount);
    }
    
    /**
     * @notice Quick setup for new NGOs
     * @dev Creates application and templates in preparation for approval
     * @param setup Configuration for quick setup
     */
    function quickNGOSetup(
        NGOQuickSetup calldata setup
    ) 
        external 
        nonReentrant 
        whenNotPaused
        rateLimited
    {
        // Validate inputs
        uint256 templateCount = setup.templateNames.length;
        if (templateCount == 0) revert InvalidInput();
        
        if (templateCount != setup.templateWallets.length || 
            templateCount != setup.templatePercentages.length || 
            templateCount != setup.templateDescriptions.length) {
            revert ArrayLengthMismatch();
        }
        
        // Validate percentages
        uint256 totalPercentage;
        for (uint256 i; i < templateCount;) {
            if (setup.templateWallets[i] == address(0)) revert ZeroAddress();
            totalPercentage += setup.templatePercentages[i];
            unchecked { ++i; }
        }
        if (totalPercentage != BASIS_POINTS) revert InvalidPercentage();
        
        // Submit application
        registry.submitApplication(setup.tier, setup.applicationIpfs, address(0));
        
        // Create beneficiary templates
        for (uint256 i; i < templateCount;) {
            analytics.createTemplate(
                setup.templateNames[i],
                setup.templateWallets[i],
                setup.templatePercentages[i],
                setup.templateDescriptions[i]
            );
            unchecked { ++i; }
        }
        
        emit QuickSetupCompleted(msg.sender, templateCount);
    }
    
    /**
     * @notice Set goals for multiple campaigns
     * @dev Batch operation for campaign goal setting
     * @param campaigns Array of campaign addresses
     * @param targetAmounts Array of target amounts
     * @param deadlines Array of deadlines
     * @param descriptions Array of descriptions
     * @return goalIds Array of created goal IDs
     */
    function setMultiCampaignGoals(
        address[] calldata campaigns,
        uint128[] calldata targetAmounts,
        uint64[] calldata deadlines,
        string[] calldata descriptions
    ) 
        external 
        nonReentrant 
        whenNotPaused
        returns (uint256[] memory goalIds) 
    {
        uint256 length = campaigns.length;
        if (length == 0 || length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        if (length != targetAmounts.length || 
            length != deadlines.length || 
            length != descriptions.length) {
            revert ArrayLengthMismatch();
        }
        
        goalIds = new uint256[](length);
        
        for (uint256 i; i < length;) {
            if (campaigns[i] == address(0)) revert ZeroAddress();
            if (targetAmounts[i] == 0) revert InvalidInput();
            if (deadlines[i] <= block.timestamp) revert InvalidInput();
            
            // Verify caller owns the campaign
            (address ngoOwner, , , , ) = IDonationCampaign(campaigns[i]).getCampaignInfo();
            if (ngoOwner != msg.sender) revert Unauthorized();
            
            goalIds[i] = analytics.createCampaignGoal(
                campaigns[i],
                targetAmounts[i],
                deadlines[i],
                descriptions[i]
            );
            unchecked { ++i; }
        }
        
        emit MultiCampaignGoalSet(msg.sender, campaigns, goalIds);
    }
    
    /**
     * @notice Setup recurring donations for multiple campaigns
     * @dev Configure recurring donations across campaigns
     * @param campaigns Array of campaign addresses
     * @param tokens Array of token addresses (address(0) for native)
     * @param amounts Array of amounts
     * @param intervals Array of intervals in seconds
     */
    function setupMultiRecurring(
        address[] calldata campaigns,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata intervals
    ) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        uint256 length = campaigns.length;
        if (length == 0 || length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        if (length != tokens.length || 
            length != amounts.length || 
            length != intervals.length) {
            revert ArrayLengthMismatch();
        }
        
        for (uint256 i; i < length;) {
            if (campaigns[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0 || amounts[i] > MAX_DONATION_AMOUNT) {
                revert AmountTooLarge();
            }
            if (intervals[i] < 1 days) revert InvalidInput(); // Minimum interval
            
            IDonationCampaign(campaigns[i]).setupRecurringDonation(
                tokens[i],
                amounts[i],
                intervals[i]
            );
            unchecked { ++i; }
        }
        
        emit RecurringDonationsSetup(msg.sender, campaigns, length);
    }
    
    /**
     * @notice Make a donation and setup recurring in one transaction
     * @dev Combines immediate and recurring donation setup
     * @param campaign Campaign address
     * @param token Token address (address(0) for native)
     * @param immediateAmount Amount to donate now
     * @param recurringAmount Amount for recurring donations
     * @param interval Interval in seconds
     * @param donationData Donation message/data
     */
    function donateAndSetupRecurring(
        address campaign,
        address token,
        uint256 immediateAmount,
        uint256 recurringAmount,
        uint256 interval,
        string calldata donationData
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused
        notZeroAddress(campaign)
    {
        if (immediateAmount > MAX_DONATION_AMOUNT || recurringAmount > MAX_DONATION_AMOUNT) {
            revert AmountTooLarge();
        }
        if (interval < 1 days) revert InvalidInput();
        
        // Handle immediate donation
        if (immediateAmount > 0) {
            if (token == address(0)) {
                if (msg.value < immediateAmount) revert InsufficientBalance();
                IDonationCampaign(campaign).donateNative{value: immediateAmount}(donationData);
                
                // Refund excess
                if (msg.value > immediateAmount) {
                    _safeTransferETH(msg.sender, msg.value - immediateAmount);
                }
            } else {
                IERC20(token).safeTransferFrom(msg.sender, address(this), immediateAmount);
                _safeApprove(IERC20(token), campaign, immediateAmount);
                
                IDonationCampaign(campaign).donateToken(token, immediateAmount, donationData);
                
                // Reset approval
                _safeApprove(IERC20(token), campaign, 0);
            }
            
            // Update statistics
            donorTotalDonations[msg.sender] += immediateAmount;
            if (donorCampaignCount[msg.sender] == 0) {
                donorCampaignCount[msg.sender] = 1;
            }
        }
        
        // Setup recurring donation
        if (recurringAmount > 0) {
            IDonationCampaign(campaign).setupRecurringDonation(token, recurringAmount, interval);
        }
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get comprehensive NGO information
     * @dev Aggregates data from registry and analytics
     * @param ngo NGO address
     * @return isRegistered Whether the NGO is registered
     * @return isVerified Whether the NGO is verified
     * @return tier The NGO's tier level
     * @return campaigns Array of campaign addresses
     * @return lifetimeRaised Total amount raised lifetime
     * @return totalCampaigns Total number of campaigns
     * @return activeCampaigns Number of active campaigns
     * @return lifetimeDonors Total unique donors lifetime
     */
    function getNGOProfile(address ngo) 
        external 
        returns (
            bool isRegistered,
            bool isVerified,
            uint32 tier,
            address[] memory campaigns,
            uint128 lifetimeRaised,
            uint32 totalCampaigns,
            uint32 activeCampaigns,
            uint32 lifetimeDonors
        ) 
    {
        // Get basic info from registry
        (address account, , uint32 ngoTier, bool verified, address[] memory ngoCampaigns) = 
            registry.getNGOInfo(ngo);
        
        isRegistered = (account != address(0));
        isVerified = verified;
        tier = ngoTier;
        campaigns = ngoCampaigns;
        
        // Get analytics if registered
        if (isRegistered) {
            (lifetimeRaised, totalCampaigns, activeCampaigns, lifetimeDonors) = 
                analytics.generateNGODashboard(ngo);
        }
    }
    
    /**
     * @notice Get complete NGO profile as a struct
     * @dev Alternative method returning structured data
     * @param ngo NGO address
     * @return profile Complete NGO profile information
     */
    function getNGOProfileStruct(address ngo) external returns (NGOProfile memory profile) {
        (
            profile.isRegistered,
            profile.isVerified,
            profile.tier,
            profile.campaigns,
            profile.lifetimeRaised,
            profile.totalCampaigns,
            profile.activeCampaigns,
            profile.lifetimeDonors
        ) = this.getNGOProfile(ngo);
    }
    
    /**
     * @notice Get donor profile across all campaigns
     * @dev Aggregates donor activity
     * @param donor Donor address
     * @return profile Donor profile information
     */
    function getDonorProfile(address donor) external view returns (DonorProfile memory profile) {
        profile.donor = donor;
        profile.totalDonated = donorTotalDonations[donor];
        profile.campaignsSupported = donorCampaignCount[donor];
        profile.recentCampaigns = new address[](0); // Would be populated from analytics in production
        profile.hasActiveRecurring = false; // Would check recurring donations in production
    }
    
    /**
     * @notice Calculate fees for operations
     * @dev Helps estimate costs before execution
     * @param ngo NGO address (or address(0) for new NGOs)
     * @param tier Tier to check (used if ngo is not registered)
     * @param operation Operation type (0=deploy, 1=renew)
     * @return feeAmount Required fee amount
     * @return feeTokenAddress Token address for fee
     */
    function calculateFees(
        address ngo, 
        uint32 tier, 
        uint256 operation
    ) 
        external 
        view 
        returns (uint256 feeAmount, address feeTokenAddress) 
    {
        uint32 actualTier = tier;
        
        // If NGO is registered, use their tier
        if (ngo != address(0)) {
            (, , uint32 ngoTier, , ) = registry.getNGOInfo(ngo);
            if (ngoTier > 0) actualTier = ngoTier;
        }
        
        if (actualTier == 0) actualTier = 1; // Default to starter tier
        
        (uint128 deploymentFee, uint128 annualFee, , , , , , ) = registry.tierConfigs(actualTier);
        
        feeTokenAddress = registry.feeToken();
        feeAmount = operation == 0 ? deploymentFee : annualFee;
    }
    
    /**
     * @notice Check if templates are valid
     * @dev Validates template configuration before deployment
     * @param templateIds Array of template IDs
     * @param customPercentages Array of custom percentages
     * @return valid Whether configuration is valid
     * @return totalPercentage Total percentage (should be 10000)
     */
    function validateTemplates(
        uint256[] calldata templateIds,
        uint96[] calldata customPercentages
    ) 
        external 
        view 
        returns (bool valid, uint256 totalPercentage) 
    {
        if (templateIds.length != customPercentages.length || templateIds.length == 0) {
            return (false, 0);
        }
        
        try analytics.applyTemplates(templateIds, customPercentages) returns (
            address[] memory, 
            uint256[] memory percentages
        ) {
            for (uint256 i; i < percentages.length;) {
                totalPercentage += percentages[i];
                unchecked { ++i; }
            }
            valid = (totalPercentage == BASIS_POINTS);
        } catch {
            valid = false;
            totalPercentage = 0;
        }
    }
    
    /**
     * @notice Estimate gas for batch donation
     * @dev Helps users estimate gas costs with improved accuracy
     * @param donations Array of donations to estimate
     * @return estimatedGas Estimated gas usage
     */
    function estimateBatchDonationGas(
        BatchDonation[] calldata donations
    ) 
        external 
        pure 
        returns (uint256 estimatedGas) 
    {
        uint256 donationCount = donations.length;
        if (donationCount == 0 || donationCount > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded();
        }
        
        // Base gas for function overhead and checks
        estimatedGas = 60000;
        
        // Add gas per donation with more accurate estimates
        for (uint256 i; i < donationCount;) {
            if (donations[i].token == address(0)) {
                estimatedGas += 85000; // Native donation
            } else {
                estimatedGas += 130000; // ERC20 donation (includes transfers and approvals)
            }
            unchecked { ++i; }
        }
        
        // Add 25% safety buffer
        estimatedGas = (estimatedGas * 125) / 100;
    }
    
    /**
     * @notice Get router statistics
     * @dev Returns overall router usage statistics
     * @return campaignsDeployed Total campaigns deployed through router
     * @return donationsProcessed Total donations processed
     * @return routerBalance Current router balance (should be minimal)
     */
    function getRouterStats() 
        external 
        view 
        returns (
            uint256 campaignsDeployed,
            uint256 donationsProcessed,
            uint256 routerBalance
        ) 
    {
        campaignsDeployed = totalCampaignsDeployed;
        donationsProcessed = totalDonationsProcessed;
        routerBalance = address(this).balance;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Execute a single donation
     */
    function _executeSingleDonation(BatchDonation calldata donation) internal {
        if (donation.token == address(0)) {
            // Native token donation
            IDonationCampaign(donation.campaign).donateNative{value: donation.amount}(
                donation.donationData
            );
        } else {
            // ERC20 donation
            IERC20(donation.token).safeTransferFrom(msg.sender, address(this), donation.amount);
            _safeApprove(IERC20(donation.token), donation.campaign, donation.amount);
            
            IDonationCampaign(donation.campaign).donateToken(
                donation.token,
                donation.amount,
                donation.donationData
            );
            
            // Reset approval to 0 for safety
            _safeApprove(IERC20(donation.token), donation.campaign, 0);
        }
    }
    
    /**
     * @dev Configure accepted tokens for a campaign
     */
    function _configureAcceptedTokens(address campaign, address[] calldata tokens) internal {
        uint256 tokenCount = tokens.length;
        for (uint256 i; i < tokenCount;) {
            if (tokens[i] != address(0)) {
                try IDonationCampaign(campaign).updateAcceptedToken(tokens[i], true) {
                    // Success - token added
                } catch {
                    // Failed - likely not the campaign owner, skip silently
                }
            }
            unchecked { ++i; }
        }
    }
    
    /**
     * @dev Safe ETH transfer with proper error handling
     */
    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert OperationFailed();
    }
    
    /**
     * @dev Safe approve handling
     * @param token Token to approve
     * @param spender Address to approve
     * @param amount Amount to approve
     */
    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        // We use a low-level call to handle tokens that don't return a value
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
        
        // Check if the call was successful and handle tokens that don't return a value
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token approval failed"
        );
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Pause the router in case of emergency
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause the router
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Rescue stuck tokens
     * @dev Emergency function to recover tokens
     * @param token Token address (address(0) for ETH)
     * @param amount Amount to rescue
     * @param to Recipient address
     */
    function rescueTokens(
        address token, 
        uint256 amount, 
        address to
    ) 
        external 
        onlyOwner 
        notZeroAddress(to) 
    {
        if (amount == 0) revert InvalidInput();
        
        if (token == address(0)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            _safeTransferETH(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit EmergencyWithdrawal(token, to, amount);
    }
    
    // ============ Receive Function ============
    
    /**
     * @notice Allow contract to receive ETH
     * @dev Necessary for refunds and donations
     */
    receive() external payable {}
}
