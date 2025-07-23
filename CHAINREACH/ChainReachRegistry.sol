// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// Interfaces
interface IChainReachToken {
    function recordFeePaid(address payer, uint256 amount) external;
}

interface IProofOfDonationToken {
    function initialize(
        address ngo,
        string memory name,
        string memory symbol,
        string memory ngoName,
        string memory metadataURI
    ) external;
}

interface IDonationCampaign {
    function initialize(
        address[] memory beneficiaries,
        uint256[] memory percentages,
        string memory ipfsHash,
        address podToken,
        bool recurringEnabled,
        uint32 maxTokens
    ) external;
}

/**
 * @title ChainReachRegistry
 * @author ChainReach Foundation
 * @notice Central registry for NGO registration and campaign management in the ChainReach ecosystem
 * @dev Handles NGO applications, POD token deployment, and donation campaign creation
 * 
 * Key Features:
 * - NGO registration with 100 CRT fee and approval workflow
 * - Automated POD token deployment for approved NGOs
 * - Campaign deployment with beneficiary management
 * - Fee distribution (1% platform, 1% giving chain treasury)
 * - Template system for beneficiary configurations
 * - Comprehensive analytics and event tracking
 */
contract ChainReachRegistry is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Clones for address;
    
    // ============ Constants ============
    
    uint256 private constant REGISTRATION_FEE = 100 * 10**18; // 100 CRT
    uint256 private constant FEE_PRECISION = 10000;
    uint256 private constant PLATFORM_FEE_RATE = 100; // 1%
    uint256 private constant GIVING_CHAIN_FEE_RATE = 100; // 1%
    uint256 private constant MAX_BENEFICIARIES = 20;
    uint256 private constant APPLICATION_EXPIRY = 30 days;
    uint256 private constant MAX_BATCH_SIZE = 50;
    
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    // ============ Structs ============
    
    struct NGOApplication {
        address applicant;
        uint64 submittedAt;
        uint8 status; // 0: pending, 1: approved, 2: rejected
        string metadataURI; // IPFS hash with all NGO details
        string organizationName;
    }
    
    struct NGORecord {
        address account;
        uint64 registeredAt;
        uint64 lastActivityAt;
        address podToken;
        uint32 campaignCount;
        uint32 lifetimeCampaigns;
        uint128 totalRaised;
        bool isActive;
        string metadataURI;
        string organizationName;
    }
    
    struct CampaignRecord {
        address ngo;
        address podToken;
        uint64 deployedAt;
        uint32 beneficiaryCount;
        bool isActive;
        uint128 totalRaised;
        string metadataURI;
    }
    
    struct BeneficiaryTemplate {
        string name;
        address wallet;
        uint96 percentage; // Out of 10000
        bool isActive;
    }
    
    struct PlatformStats {
        uint256 totalNGOs;
        uint256 activeNGOs;
        uint256 totalCampaigns;
        uint256 activeCampaigns;
        uint256 totalDonationsProcessed;
        uint256 platformFeesCollected;
        uint256 givingChainFeesCollected;
    }
    
    // ============ State Variables ============
    
    // Core addresses
    address public immutable crtToken;
    address public platformTreasury;
    address public givingChainTreasury;
    
    // Implementation contracts for cloning
    address public podTokenImplementation;
    address public campaignImplementation;
    
    // Application tracking
    uint256 public nextApplicationId = 1;
    mapping(uint256 => NGOApplication) public applications;
    mapping(address => uint256) public activeApplicationId;
    EnumerableSet.AddressSet private pendingApplications;
    
    // NGO registry
    mapping(address => NGORecord) public ngoRecords;
    EnumerableSet.AddressSet private registeredNGOs;
    EnumerableSet.AddressSet private activeNGOs;
    
    // Campaign registry
    mapping(address => CampaignRecord) public campaignRecords;
    mapping(address => EnumerableSet.AddressSet) private ngoCampaigns;
    EnumerableSet.AddressSet private allCampaigns;
    
    // Template management
    mapping(address => BeneficiaryTemplate[]) public beneficiaryTemplates;
    mapping(address => uint256) public templateCount;
    
    // Platform statistics
    PlatformStats public platformStats;
    
    // ============ Events ============
    
    // Application events
    event ApplicationSubmitted(
        uint256 indexed applicationId, 
        address indexed applicant, 
        string organizationName
    );
    event ApplicationProcessed(
        uint256 indexed applicationId, 
        address indexed applicant, 
        bool approved, 
        address approver
    );
    
    // NGO events
    event NGORegistered(
        address indexed ngo, 
        address indexed podToken, 
        string organizationName
    );
    event NGOStatusChanged(
        address indexed ngo, 
        bool isActive
    );
    event PODTokenDeployed(
        address indexed ngo, 
        address indexed podToken, 
        string name, 
        string symbol
    );
    
    // Campaign events
    event CampaignDeployed(
        address indexed campaign, 
        address indexed ngo, 
        address indexed podToken,
        uint256 beneficiaryCount
    );
    event CampaignStatusChanged(
        address indexed campaign, 
        bool isActive
    );
    
    // Fee events
    event PlatformFeeCollected(
        address indexed from, 
        uint256 amount
    );
    event GivingChainFeeCollected(
        address indexed from, 
        uint256 amount
    );
    
    // Template events
    event TemplateCreated(
        address indexed ngo, 
        uint256 indexed templateId, 
        string name
    );
    event TemplateUpdated(
        address indexed ngo, 
        uint256 indexed templateId
    );
    
    // ============ Errors ============
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidParameters();
    error AlreadyRegistered();
    error NotRegistered();
    error ApplicationPending();
    error ApplicationNotFound();
    error ApplicationExpired();
    error InsufficientFee();
    error Unauthorized();
    error CampaignLimitExceeded();
    error TemplateNotFound();
    error TooManyBeneficiaries();
    error InvalidPercentage();
    error ArrayLengthMismatch();
    error TransferFailed();
    error ImplementationNotSet();
    
    // ============ Modifiers ============
    
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    
    modifier onlyRegisteredNGO() {
        if (!registeredNGOs.contains(msg.sender)) revert NotRegistered();
        if (!ngoRecords[msg.sender].isActive) revert Unauthorized();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _crtToken,
        address _platformTreasury,
        address _givingChainTreasury
    ) 
        validAddress(_crtToken)
        validAddress(_platformTreasury)
        validAddress(_givingChainTreasury)
    {
        crtToken = _crtToken;
        platformTreasury = _platformTreasury;
        givingChainTreasury = _givingChainTreasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(APPROVER_ROLE, msg.sender);
    }
    
    // ============ Implementation Setup ============
    
    /**
     * @notice Set implementation contracts for cloning
     * @param _podTokenImpl POD token implementation address
     * @param _campaignImpl Campaign implementation address
     */
    function setImplementations(
        address _podTokenImpl,
        address _campaignImpl
    ) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        validAddress(_podTokenImpl)
        validAddress(_campaignImpl)
    {
        podTokenImplementation = _podTokenImpl;
        campaignImplementation = _campaignImpl;
    }
    
    // ============ NGO Registration ============
    
    /**
     * @notice Submit an NGO registration application
     * @param organizationName Name of the organization
     * @param metadataURI IPFS hash containing organization details
     */
    function submitApplication(
        string calldata organizationName,
        string calldata metadataURI
    ) external whenNotPaused nonReentrant {
        if (bytes(organizationName).length == 0) revert InvalidParameters();
        if (bytes(metadataURI).length == 0) revert InvalidParameters();
        if (registeredNGOs.contains(msg.sender)) revert AlreadyRegistered();
        if (activeApplicationId[msg.sender] != 0) revert ApplicationPending();
        
        // Collect registration fee
        IERC20(crtToken).safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);
        IChainReachToken(crtToken).recordFeePaid(msg.sender, REGISTRATION_FEE);
        
        // Create application
        uint256 applicationId = nextApplicationId++;
        applications[applicationId] = NGOApplication({
            applicant: msg.sender,
            submittedAt: uint64(block.timestamp),
            status: 0, // pending
            metadataURI: metadataURI,
            organizationName: organizationName
        });
        
        activeApplicationId[msg.sender] = applicationId;
        pendingApplications.add(msg.sender);
        
        emit ApplicationSubmitted(applicationId, msg.sender, organizationName);
    }
    
    /**
     * @notice Process an NGO application
     * @param applicationId Application to process
     * @param approved Whether to approve or reject
     */
    function processApplication(
        uint256 applicationId,
        bool approved
    ) external onlyRole(APPROVER_ROLE) {
        NGOApplication storage app = applications[applicationId];
        if (app.applicant == address(0)) revert ApplicationNotFound();
        if (app.status != 0) revert InvalidParameters();
        if (block.timestamp > app.submittedAt + APPLICATION_EXPIRY) {
            revert ApplicationExpired();
        }
        
        app.status = approved ? 1 : 2;
        pendingApplications.remove(app.applicant);
        
        if (approved) {
            _registerNGO(app.applicant, app.organizationName, app.metadataURI);
            
            // Transfer fees to treasuries
            uint256 platformFee = REGISTRATION_FEE / 2;
            uint256 givingChainFee = REGISTRATION_FEE - platformFee;
            
            IERC20(crtToken).safeTransfer(platformTreasury, platformFee);
            IERC20(crtToken).safeTransfer(givingChainTreasury, givingChainFee);
            
            platformStats.platformFeesCollected += platformFee;
            platformStats.givingChainFeesCollected += givingChainFee;
            
            emit PlatformFeeCollected(app.applicant, platformFee);
            emit GivingChainFeeCollected(app.applicant, givingChainFee);
        } else {
            // Refund 90% of fee on rejection (10% processing fee)
            uint256 refund = (REGISTRATION_FEE * 9000) / FEE_PRECISION;
            IERC20(crtToken).safeTransfer(app.applicant, refund);
            
            uint256 processingFee = REGISTRATION_FEE - refund;
            IERC20(crtToken).safeTransfer(platformTreasury, processingFee);
            platformStats.platformFeesCollected += processingFee;
        }
        
        delete activeApplicationId[app.applicant];
        emit ApplicationProcessed(applicationId, app.applicant, approved, msg.sender);
    }
    
    /**
     * @notice Register an NGO and deploy their POD token
     */
    function _registerNGO(
        address account,
        string memory organizationName,
        string memory metadataURI
    ) internal {
        if (podTokenImplementation == address(0)) revert ImplementationNotSet();
        
        // Deploy POD token using clone
        address podToken = podTokenImplementation.clone();
        
        // Initialize POD token
        string memory tokenName = string(abi.encodePacked(organizationName, " Impact Token"));
        string memory tokenSymbol = _generateTokenSymbol(organizationName);
        
        IProofOfDonationToken(podToken).initialize(
            account,
            tokenName,
            tokenSymbol,
            organizationName,
            metadataURI
        );
        
        // Create NGO record
        ngoRecords[account] = NGORecord({
            account: account,
            registeredAt: uint64(block.timestamp),
            lastActivityAt: uint64(block.timestamp),
            podToken: podToken,
            campaignCount: 0,
            lifetimeCampaigns: 0,
            totalRaised: 0,
            isActive: true,
            metadataURI: metadataURI,
            organizationName: organizationName
        });
        
        registeredNGOs.add(account);
        activeNGOs.add(account);
        platformStats.totalNGOs++;
        platformStats.activeNGOs++;
        
        emit NGORegistered(account, podToken, organizationName);
        emit PODTokenDeployed(account, podToken, tokenName, tokenSymbol);
    }
    
    // ============ Campaign Deployment ============
    
    /**
     * @notice Deploy a new donation campaign
     * @param beneficiaries Array of beneficiary addresses
     * @param percentages Array of distribution percentages
     * @param campaignMetadataURI IPFS hash for campaign details
     * @param acceptedTokens Initial tokens to accept
     * @param recurringEnabled Whether to enable recurring donations
     * @return campaign Deployed campaign address
     */
    function deployCampaign(
        address[] calldata beneficiaries,
        uint256[] calldata percentages,
        string calldata campaignMetadataURI,
        address[] calldata acceptedTokens,
        bool recurringEnabled
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRegisteredNGO 
        returns (address campaign) 
    {
        if (campaignImplementation == address(0)) revert ImplementationNotSet();
        if (beneficiaries.length != percentages.length) revert ArrayLengthMismatch();
        if (beneficiaries.length == 0 || beneficiaries.length > MAX_BENEFICIARIES) {
            revert TooManyBeneficiaries();
        }
        
        // Validate percentages sum to 100%
        uint256 totalPercentage;
        for (uint256 i; i < percentages.length;) {
            if (beneficiaries[i] == address(0)) revert InvalidAddress();
            if (percentages[i] == 0) revert InvalidPercentage();
            totalPercentage += percentages[i];
            unchecked { ++i; }
        }
        if (totalPercentage != FEE_PRECISION) revert InvalidPercentage();
        
        NGORecord storage ngo = ngoRecords[msg.sender];
        
        // Deploy campaign using clone
        campaign = campaignImplementation.clone();
        
        // Initialize campaign
        IDonationCampaign(campaign).initialize(
            beneficiaries,
            percentages,
            campaignMetadataURI,
            ngo.podToken,
            recurringEnabled,
            uint32(acceptedTokens.length)
        );
        
        // Register campaign
        campaignRecords[campaign] = CampaignRecord({
            ngo: msg.sender,
            podToken: ngo.podToken,
            deployedAt: uint64(block.timestamp),
            beneficiaryCount: uint32(beneficiaries.length),
            isActive: true,
            totalRaised: 0,
            metadataURI: campaignMetadataURI
        });
        
        ngoCampaigns[msg.sender].add(campaign);
        allCampaigns.add(campaign);
        
        // Update statistics
        ngo.campaignCount++;
        ngo.lifetimeCampaigns++;
        ngo.lastActivityAt = uint64(block.timestamp);
        platformStats.totalCampaigns++;
        platformStats.activeCampaigns++;
        
        emit CampaignDeployed(campaign, msg.sender, ngo.podToken, beneficiaries.length);
    }
    
    // ============ Template Management ============
    
    /**
     * @notice Create a beneficiary template for reuse
     * @param name Template name
     * @param wallet Beneficiary address
     * @param percentage Distribution percentage
     * @return templateId Created template ID
     */
    function createTemplate(
        string calldata name,
        address wallet,
        uint96 percentage
    ) 
        external 
        onlyRegisteredNGO 
        validAddress(wallet)
        returns (uint256 templateId) 
    {
        if (bytes(name).length == 0) revert InvalidParameters();
        if (percentage == 0 || percentage > FEE_PRECISION) revert InvalidPercentage();
        
        templateId = beneficiaryTemplates[msg.sender].length;
        beneficiaryTemplates[msg.sender].push(BeneficiaryTemplate({
            name: name,
            wallet: wallet,
            percentage: percentage,
            isActive: true
        }));
        
        templateCount[msg.sender]++;
        emit TemplateCreated(msg.sender, templateId, name);
    }
    
    /**
     * @notice Apply templates to get beneficiary configuration
     * @param templateIds Array of template IDs
     * @return wallets Beneficiary addresses
     * @return percentages Distribution percentages
     */
    function applyTemplates(
        uint256[] calldata templateIds
    ) 
        external 
        view 
        onlyRegisteredNGO 
        returns (address[] memory wallets, uint256[] memory percentages) 
    {
        uint256 length = templateIds.length;
        wallets = new address[](length);
        percentages = new uint256[](length);
        
        for (uint256 i; i < length;) {
            if (templateIds[i] >= beneficiaryTemplates[msg.sender].length) {
                revert TemplateNotFound();
            }
            
            BeneficiaryTemplate memory template = beneficiaryTemplates[msg.sender][templateIds[i]];
            if (!template.isActive) revert InvalidParameters();
            
            wallets[i] = template.wallet;
            percentages[i] = template.percentage;
            unchecked { ++i; }
        }
    }
    
    // ============ Campaign Management ============
    
    /**
     * @notice Update campaign status
     * @param campaign Campaign address
     * @param isActive New status
     */
    function updateCampaignStatus(
        address campaign,
        bool isActive
    ) external onlyRegisteredNGO {
        CampaignRecord storage record = campaignRecords[campaign];
        if (record.ngo != msg.sender) revert Unauthorized();
        
        if (record.isActive != isActive) {
            record.isActive = isActive;
            
            if (isActive) {
                ngoRecords[msg.sender].campaignCount++;
                platformStats.activeCampaigns++;
            } else {
                ngoRecords[msg.sender].campaignCount--;
                platformStats.activeCampaigns--;
            }
            
            emit CampaignStatusChanged(campaign, isActive);
        }
    }
    
    /**
     * @notice Track donation for analytics (called by campaigns)
     * @param donor Donor address
     * @param amount Donation amount
     */
    function trackDonation(
        address donor,
        uint256 amount
    ) external {
        CampaignRecord storage record = campaignRecords[msg.sender];
        if (record.ngo == address(0)) revert Unauthorized();
        
        record.totalRaised += uint128(amount);
        ngoRecords[record.ngo].totalRaised += uint128(amount);
        ngoRecords[record.ngo].lastActivityAt = uint64(block.timestamp);
        platformStats.totalDonationsProcessed++;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get NGO information
     * @param ngo NGO address
     * @return record NGO record
     * @return campaigns Array of campaign addresses
     */
    function getNGOInfo(address ngo) 
        external 
        view 
        returns (NGORecord memory record, address[] memory campaigns) 
    {
        record = ngoRecords[ngo];
        campaigns = ngoCampaigns[ngo].values();
    }
    
    /**
     * @notice Get pending applications
     * @return Array of applicant addresses
     */
    function getPendingApplications() external view returns (address[] memory) {
        return pendingApplications.values();
    }
    
    /**
     * @notice Get all registered NGOs
     * @param offset Start index
     * @param limit Number to return
     * @return ngos Array of NGO addresses
     */
    function getRegisteredNGOs(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory ngos) {
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
     * @notice Get platform statistics
     * @return Platform-wide statistics
     */
    function getPlatformStats() external view returns (PlatformStats memory) {
        return platformStats;
    }
    
    /**
     * @notice Get templates for an NGO
     * @param ngo NGO address
     * @return Array of templates
     */
    function getTemplates(address ngo) 
        external 
        view 
        returns (BeneficiaryTemplate[] memory) 
    {
        return beneficiaryTemplates[ngo];
    }
    
    /**
     * @notice Check if address is registered NGO
     * @param account Address to check
     * @return isRegistered Whether registered
     * @return isActive Whether active
     */
    function isRegisteredNGO(address account) 
        external 
        view 
        returns (bool isRegistered, bool isActive) 
    {
        isRegistered = registeredNGOs.contains(account);
        isActive = isRegistered && ngoRecords[account].isActive;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update treasury addresses
     * @param _platformTreasury New platform treasury
     * @param _givingChainTreasury New giving chain treasury
     */
    function updateTreasuries(
        address _platformTreasury,
        address _givingChainTreasury
    ) 
        external 
        onlyRole(TREASURY_ROLE) 
        validAddress(_platformTreasury)
        validAddress(_givingChainTreasury)
    {
        platformTreasury = _platformTreasury;
        givingChainTreasury = _givingChainTreasury;
    }
    
    /**
     * @notice Pause the registry
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the registry
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Update NGO status (admin action)
     * @param ngo NGO address
     * @param isActive New status
     */
    function updateNGOStatus(
        address ngo,
        bool isActive
    ) external onlyRole(OPERATOR_ROLE) {
        if (!registeredNGOs.contains(ngo)) revert NotRegistered();
        
        NGORecord storage record = ngoRecords[ngo];
        if (record.isActive != isActive) {
            record.isActive = isActive;
            
            if (isActive) {
                activeNGOs.add(ngo);
                platformStats.activeNGOs++;
            } else {
                activeNGOs.remove(ngo);
                platformStats.activeNGOs--;
            }
            
            emit NGOStatusChanged(ngo, isActive);
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Generate token symbol from organization name
     * @param orgName Organization name
     * @return symbol Generated symbol (3-6 characters)
     */
    function _generateTokenSymbol(
        string memory orgName
    ) internal pure returns (string memory symbol) {
        bytes memory nameBytes = bytes(orgName);
        bytes memory symbolBytes = new bytes(6);
        uint256 symbolLength;
        
        // Extract uppercase letters and numbers
        for (uint256 i; i < nameBytes.length && symbolLength < 6; i++) {
            bytes1 char = nameBytes[i];
            if ((char >= 0x41 && char <= 0x5A) || // A-Z
                (char >= 0x30 && char <= 0x39)) { // 0-9
                symbolBytes[symbolLength++] = char;
            } else if (char >= 0x61 && char <= 0x7A) { // a-z
                // Convert to uppercase
                symbolBytes[symbolLength++] = bytes1(uint8(char) - 32);
            }
        }
        
        // Ensure minimum length of 3
        if (symbolLength < 3) {
            symbolBytes[0] = 0x50; // P
            symbolBytes[1] = 0x4F; // O
            symbolBytes[2] = 0x44; // D
            symbolLength = 3;
        }
        
        // Create final symbol
        symbol = string(new bytes(symbolLength));
        bytes memory finalSymbol = bytes(symbol);
        for (uint256 i; i < symbolLength; i++) {
            finalSymbol[i] = symbolBytes[i];
        }
    }
}
