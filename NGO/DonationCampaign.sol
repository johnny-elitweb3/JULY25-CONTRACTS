// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ICIFIRegistry
 * @dev Enhanced interface for interacting with the main registry
 */
interface ICIFIRegistry {
    function trackDonation(address donor, address token, uint256 amount) external;
    function trackPartnerNGOContribution(address token, uint256 amount) external;
    function getPartnerNGO() external view returns (address);
    function campaignRecords(address) external view returns (
        address ngo,
        uint64 deployedAt,
        uint32 beneficiaryCount,
        bool isActive,
        string memory ipfsHash
    );
}

/**
 * @title DonationReceiptNFT
 * @notice Minimal NFT contract for donation receipts
 * @dev Deployed with each campaign for gas efficiency
 */
contract DonationReceiptNFT is ERC721 {
    using Strings for uint256;
    
    // Immutable configuration
    address public immutable campaign;
    string public baseURI;
    
    // Counter for token IDs
    uint256 private _tokenIdCounter;
    
    // Receipt data stored in events for gas efficiency
    event ReceiptIssued(
        uint256 indexed tokenId,
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 timestamp,
        string ipfsHash
    );
    
    modifier onlyCampaign() {
        require(msg.sender == campaign, "Only campaign");
        _;
    }
    
    constructor(
        string memory name,
        string memory symbol,
        string memory _baseURI
    ) ERC721(name, symbol) {
        campaign = msg.sender;
        baseURI = _baseURI;
    }
    
    /**
     * @notice Mint a receipt NFT
     * @param to Recipient address
     * @param token Token donated (address(0) for native)
     * @param amount Amount donated
     * @param ipfsHash IPFS hash of donation metadata
     * @return tokenId The minted token ID
     */
    function mintReceipt(
        address to,
        address token,
        uint256 amount,
        string calldata ipfsHash
    ) external onlyCampaign returns (uint256 tokenId) {
        tokenId = _tokenIdCounter++;
        _safeMint(to, tokenId);
        
        emit ReceiptIssued(tokenId, to, token, amount, block.timestamp, ipfsHash);
    }
    
    /**
     * @notice Get the token URI
     * @param tokenId Token ID
     * @return The token URI
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // ownerOf will revert if token doesn't exist
        ownerOf(tokenId);
        return string(abi.encodePacked(baseURI, tokenId.toString()));
    }
    
    /**
     * @notice Update base URI (only campaign)
     * @param _baseURI New base URI
     */
    function setBaseURI(string calldata _baseURI) external onlyCampaign {
        baseURI = _baseURI;
    }
    
    /**
     * @notice Get total supply
     * @return Total number of tokens minted
     */
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }
}

/**
 * @title DonationCampaign
 * @author CIFI Foundation
 * @notice Enhanced donation processing contract for the CIFI GIVE ecosystem
 * @dev Supports 100% charitable model where platform fees go to partner NGO
 * 
 * Key Design Principles:
 * - Immutable configuration set at deployment
 * - No owner functions - managed entirely by registry
 * - Immediate distribution to beneficiaries AND partner NGO
 * - Event-based analytics for off-chain processing
 * - Optional features based on NGO tier
 * - Platform fees support designated charity (e.g., St. Jude's)
 */
contract DonationCampaign is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ============ Structs ============
    
    /**
     * @dev Immutable beneficiary configuration
     */
    struct Beneficiary {
        address wallet;
        uint96 percentage; // Out of 10000 (100%)
    }
    
    /**
     * @dev Recurring donation configuration
     */
    struct RecurringDonation {
        uint128 amount;
        uint64 interval;
        uint64 nextDue;
        address token;
        bool active;
    }
    
    /**
     * @dev Campaign statistics for transparency
     */
    struct CampaignStats {
        uint128 totalRaised;
        uint128 totalDistributed;
        uint64 uniqueDonors;
        uint64 totalDonations;
        uint128 platformFeesGenerated;
        uint128 largestDonation;
    }
    
    // ============ Constants ============
    uint256 private constant FEE_PRECISION = 10000;
    uint256 private constant MIN_INTERVAL = 1 days;
    uint256 private constant MAX_ACCEPTED_TOKENS = 100;
    
    // ============ Immutable State ============
    address public immutable ngo;
    address public immutable registry;
    address public immutable feeToken;
    address public immutable partnerNGO;
    uint256 public immutable platformFeeRate;
    uint256 public immutable deployedAt;
    string public metadataURI;
    
    // ============ Configuration State ============
    Beneficiary[] public beneficiaries;
    mapping(address => bool) public acceptedTokens;
    DonationReceiptNFT public receiptNFT;
    
    // Feature flags (set by registry based on tier)
    bool public recurringEnabled;
    bool public customNFTEnabled;
    uint32 public maxAcceptedTokens;
    
    // ============ Operational State ============
    bool public paused;
    CampaignStats public stats;
    
    // Donor tracking
    mapping(address => bool) private hasEverDonated;
    mapping(address => uint256) public donorTotalContributions;
    
    // Recurring donations (only if enabled)
    mapping(address => RecurringDonation) public recurringDonations;
    
    // ============ Events ============
    
    // Core donation events
    event DonationReceived(
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 platformFee,
        uint256 netAmount,
        uint256 timestamp
    );
    
    event FundsDistributed(
        address indexed beneficiary,
        address indexed token,
        uint256 amount
    );
    
    event PlatformFeeDonated(
        address indexed partnerNGO,
        address indexed token,
        uint256 amount
    );
    
    // Configuration events
    event TokenAccepted(address indexed token, bool accepted);
    event MetadataUpdated(string oldURI, string newURI);
    event CampaignPausedBy(address indexed by);
    event CampaignUnpausedBy(address indexed by);
    
    // Recurring events
    event RecurringDonationSetup(
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 interval
    );
    
    event RecurringDonationProcessed(
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 nextDue
    );
    
    event RecurringDonationCancelled(
        address indexed donor,
        address indexed token
    );
    
    // Milestone events
    event MilestoneReached(
        string milestone,
        uint256 value,
        uint256 timestamp
    );
    
    // ============ Errors ============
    error Unauthorized();
    error InvalidAmount();
    error InvalidToken();
    error CampaignPaused();
    error CampaignInactive();
    error TokenNotAccepted();
    error TooManyTokens();
    error RecurringNotEnabled();
    error RecurringAlreadyExists();
    error RecurringNotFound();
    error RecurringNotDue();
    error InvalidInterval();
    error TransferFailed();
    error InvalidBeneficiary();
    error InvalidPercentage();
    error InvalidParameters();
    error PartnerNGONotSet();
    
    // ============ Modifiers ============
    
    modifier onlyRegistry() {
        if (msg.sender != registry) revert Unauthorized();
        _;
    }
    
    modifier onlyNGO() {
        if (msg.sender != ngo) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert CampaignPaused();
        _;
    }
    
    modifier onlyActive() {
        (, , , bool isActive,) = ICIFIRegistry(registry).campaignRecords(address(this));
        if (!isActive) revert CampaignInactive();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _ngo,
        address _registry,
        address[] memory _beneficiaries,
        uint256[] memory _percentages,
        string memory _ipfsHash,
        address _feeToken,
        uint256 _platformFeeRate,
        address _partnerNGO
    ) {
        if (_beneficiaries.length != _percentages.length) revert InvalidBeneficiary();
        if (_beneficiaries.length == 0) revert InvalidBeneficiary();
        if (_partnerNGO == address(0)) revert PartnerNGONotSet();
        
        ngo = _ngo;
        registry = _registry;
        feeToken = _feeToken;
        platformFeeRate = _platformFeeRate;
        partnerNGO = _partnerNGO;
        deployedAt = block.timestamp;
        metadataURI = _ipfsHash;
        
        // Validate and store beneficiaries
        uint256 totalPercentage;
        for (uint256 i; i < _beneficiaries.length;) {
            if (_beneficiaries[i] == address(0)) revert InvalidBeneficiary();
            if (_percentages[i] == 0) revert InvalidPercentage();
            
            beneficiaries.push(Beneficiary({
                wallet: _beneficiaries[i],
                percentage: uint96(_percentages[i])
            }));
            
            totalPercentage += _percentages[i];
            unchecked { ++i; }
        }
        
        if (totalPercentage != FEE_PRECISION) revert InvalidPercentage();
        
        // Deploy receipt NFT with campaign-specific metadata
        string memory nftName = string(abi.encodePacked("CIFI Receipt - ", _extractCampaignName(_ipfsHash)));
        receiptNFT = new DonationReceiptNFT(
            nftName,
            "CIFI-R",
            string(abi.encodePacked("ipfs://", _ipfsHash, "/receipts/"))
        );
    }
    
    // ============ Initialization (Called by Registry) ============
    
    /**
     * @notice Initialize campaign features based on NGO tier
     * @param _recurringEnabled Whether recurring donations are enabled
     * @param _customNFTEnabled Whether custom NFT metadata is enabled
     * @param _maxTokens Maximum number of accepted tokens
     */
    function initialize(
        bool _recurringEnabled,
        bool _customNFTEnabled,
        uint32 _maxTokens
    ) external onlyRegistry {
        recurringEnabled = _recurringEnabled;
        customNFTEnabled = _customNFTEnabled;
        maxAcceptedTokens = _maxTokens;
        
        // Accept native token by default
        acceptedTokens[address(0)] = true;
    }
    
    // ============ Donation Functions ============
    
    /**
     * @notice Donate native tokens
     * @param donationData IPFS hash or data for donation metadata
     */
    function donateNative(string calldata donationData) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlyActive 
    {
        if (msg.value == 0) revert InvalidAmount();
        
        _processDonation(msg.sender, address(0), msg.value, donationData);
    }
    
    /**
     * @notice Donate ERC20 tokens
     * @param token Token address
     * @param amount Amount to donate
     * @param donationData IPFS hash or data for donation metadata
     */
    function donateToken(
        address token,
        uint256 amount,
        string calldata donationData
    ) external nonReentrant whenNotPaused onlyActive {
        if (!acceptedTokens[token]) revert TokenNotAccepted();
        if (amount == 0) revert InvalidAmount();
        
        // Transfer tokens from donor
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        
        _processDonation(msg.sender, token, actualAmount, donationData);
    }
    
    /**
     * @notice Batch donation to save gas for multiple small donations
     * @param donors Array of donor addresses
     * @param amounts Array of amounts
     * @param token Token address (must be same for all)
     */
    function processBatchDonations(
        address[] calldata donors,
        uint256[] calldata amounts,
        address token
    ) external onlyRegistry {
        if (donors.length != amounts.length) revert InvalidParameters();
        
        for (uint256 i; i < donors.length;) {
            if (amounts[i] > 0) {
                _processDonation(donors[i], token, amounts[i], "batch");
            }
            unchecked { ++i; }
        }
    }
    
    // ============ Recurring Donation Functions ============
    
    /**
     * @notice Setup a recurring donation
     * @param token Token address (address(0) for native)
     * @param amount Amount per donation
     * @param interval Time between donations (minimum 1 day)
     */
    function setupRecurringDonation(
        address token,
        uint256 amount,
        uint256 interval
    ) external whenNotPaused onlyActive {
        if (!recurringEnabled) revert RecurringNotEnabled();
        if (!acceptedTokens[token]) revert TokenNotAccepted();
        if (amount == 0 || amount > type(uint128).max) revert InvalidAmount();
        if (interval < MIN_INTERVAL) revert InvalidInterval();
        if (recurringDonations[msg.sender].active) revert RecurringAlreadyExists();
        
        recurringDonations[msg.sender] = RecurringDonation({
            amount: uint128(amount),
            interval: uint64(interval),
            nextDue: uint64(block.timestamp + interval),
            token: token,
            active: true
        });
        
        emit RecurringDonationSetup(msg.sender, token, amount, interval);
    }
    
    /**
     * @notice Process a recurring donation
     * @param donationData IPFS hash or data for donation metadata
     */
    function processRecurringDonation(string calldata donationData) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlyActive 
    {
        RecurringDonation storage recurring = recurringDonations[msg.sender];
        if (!recurring.active) revert RecurringNotFound();
        if (block.timestamp < recurring.nextDue) revert RecurringNotDue();
        
        uint256 amount = recurring.amount;
        address token = recurring.token;
        
        // Process the donation
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        }
        
        _processDonation(msg.sender, token, amount, donationData);
        
        // Update next due time
        recurring.nextDue = uint64(block.timestamp + recurring.interval);
        
        emit RecurringDonationProcessed(msg.sender, token, amount, recurring.nextDue);
    }
    
    /**
     * @notice Cancel a recurring donation
     */
    function cancelRecurringDonation() external {
        RecurringDonation storage recurring = recurringDonations[msg.sender];
        if (!recurring.active) revert RecurringNotFound();
        
        address token = recurring.token;
        recurring.active = false;
        delete recurringDonations[msg.sender];
        
        emit RecurringDonationCancelled(msg.sender, token);
    }
    
    // ============ Management Functions ============
    
    /**
     * @notice Update accepted tokens (NGO only)
     * @param token Token address
     * @param accepted Whether to accept the token
     */
    function updateAcceptedToken(address token, bool accepted) external onlyNGO onlyActive {
        if (accepted) {
            uint256 currentCount;
            for (uint256 i; i <= type(uint8).max; i++) {
                if (acceptedTokens[address(uint160(i))]) currentCount++;
                if (currentCount >= maxAcceptedTokens) revert TooManyTokens();
            }
        }
        
        acceptedTokens[token] = accepted;
        emit TokenAccepted(token, accepted);
    }
    
    /**
     * @notice Update campaign metadata (NGO only)
     * @param newURI New metadata URI
     */
    function updateMetadata(string calldata newURI) external onlyNGO {
        string memory oldURI = metadataURI;
        metadataURI = newURI;
        emit MetadataUpdated(oldURI, newURI);
    }
    
    /**
     * @notice Update NFT base URI (NGO only, if custom NFT enabled)
     * @param newBaseURI New base URI for NFTs
     */
    function updateNFTBaseURI(string calldata newBaseURI) external onlyNGO {
        if (!customNFTEnabled) revert Unauthorized();
        receiptNFT.setBaseURI(newBaseURI);
    }
    
    /**
     * @notice Pause campaign (Registry only)
     */
    function pause() external onlyRegistry {
        paused = true;
        emit CampaignPausedBy(msg.sender);
    }
    
    /**
     * @notice Unpause campaign (Registry only)
     */
    function unpause() external onlyRegistry {
        paused = false;
        emit CampaignUnpausedBy(msg.sender);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get comprehensive campaign information
     * @return ngoAddress NGO owner address
     * @return beneficiaryCount Number of beneficiaries
     * @return isActive Whether campaign is active
     * @return campaignStats Complete statistics
     * @return features Enabled features (recurring, customNFT)
     */
    function getCampaignInfo() external view returns (
        address ngoAddress,
        uint256 beneficiaryCount,
        bool isActive,
        CampaignStats memory campaignStats,
        bool[2] memory features
    ) {
        (, , , isActive,) = ICIFIRegistry(registry).campaignRecords(address(this));
        
        return (
            ngo,
            beneficiaries.length,
            isActive,
            stats,
            [recurringEnabled, customNFTEnabled]
        );
    }
    
    /**
     * @notice Get all beneficiaries and their percentages
     * @return addresses Array of beneficiary addresses
     * @return percentages Array of percentages
     */
    function getBeneficiaries() external view returns (
        address[] memory addresses,
        uint256[] memory percentages
    ) {
        uint256 length = beneficiaries.length;
        addresses = new address[](length);
        percentages = new uint256[](length);
        
        for (uint256 i; i < length;) {
            addresses[i] = beneficiaries[i].wallet;
            percentages[i] = beneficiaries[i].percentage;
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Check if a token is accepted
     * @param token Token address
     * @return Whether the token is accepted
     */
    function isTokenAccepted(address token) external view returns (bool) {
        return acceptedTokens[token];
    }
    
    /**
     * @notice Get recurring donation info for a donor
     * @param donor Donor address
     * @return amount Amount per donation
     * @return interval Time between donations
     * @return nextDue Next due timestamp
     * @return token Token address
     * @return active Whether active
     */
    function getRecurringDonation(address donor) external view returns (
        uint256 amount,
        uint256 interval,
        uint256 nextDue,
        address token,
        bool active
    ) {
        RecurringDonation memory recurring = recurringDonations[donor];
        return (
            recurring.amount,
            recurring.interval,
            recurring.nextDue,
            recurring.token,
            recurring.active
        );
    }
    
    /**
     * @notice Get donor's total contributions to this campaign
     * @param donor Donor address
     * @return Total amount donated
     */
    function getDonorContribution(address donor) external view returns (uint256) {
        return donorTotalContributions[donor];
    }
    
    /**
     * @notice Get campaign statistics
     * @return Complete campaign statistics
     */
    function getCampaignStats() external view returns (CampaignStats memory) {
        return stats;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Process a donation and distribute funds
     */
    function _processDonation(
        address donor,
        address token,
        uint256 amount,
        string memory donationData
    ) internal {
        // Update donor tracking
        if (!hasEverDonated[donor]) {
            hasEverDonated[donor] = true;
            stats.uniqueDonors++;
        }
        
        donorTotalContributions[donor] += amount;
        
        // Calculate platform fee
        uint256 platformFee = (amount * platformFeeRate) / FEE_PRECISION;
        uint256 netAmount = amount - platformFee;
        
        // Update statistics
        stats.totalDonations++;
        stats.totalRaised += uint128(amount);
        stats.platformFeesGenerated += uint128(platformFee);
        
        if (amount > stats.largestDonation) {
            stats.largestDonation = uint128(amount);
            emit MilestoneReached("largest_donation", amount, block.timestamp);
        }
        
        // Check for total raised milestones
        _checkMilestones();
        
        // Track donation
        emit DonationReceived(donor, token, amount, platformFee, netAmount, block.timestamp);
        
        // Notify registry for analytics
        try ICIFIRegistry(registry).trackDonation(donor, token, amount) {} catch {}
        
        // Distribute funds to beneficiaries and partner NGO
        _distributeFunds(token, netAmount, platformFee);
        
        // Mint receipt NFT
        if (customNFTEnabled && bytes(donationData).length > 0) {
            receiptNFT.mintReceipt(donor, token, amount, donationData);
        } else {
            receiptNFT.mintReceipt(donor, token, amount, "");
        }
    }
    
    /**
     * @dev Distribute funds to beneficiaries and partner NGO
     */
    function _distributeFunds(
        address token,
        uint256 netAmount,
        uint256 platformFee
    ) internal {
        // Send platform fee to partner NGO (e.g., St. Jude's)
        if (platformFee > 0) {
            _transferFunds(token, partnerNGO, platformFee);
            stats.totalDistributed += uint128(platformFee);
            
            // Track contribution to partner NGO
            try ICIFIRegistry(registry).trackPartnerNGOContribution(token, platformFee) {} catch {}
            
            emit PlatformFeeDonated(partnerNGO, token, platformFee);
        }
        
        // Distribute to beneficiaries
        uint256 distributed;
        uint256 length = beneficiaries.length;
        
        for (uint256 i; i < length - 1;) {
            uint256 share = (netAmount * beneficiaries[i].percentage) / FEE_PRECISION;
            _transferFunds(token, beneficiaries[i].wallet, share);
            distributed += share;
            
            emit FundsDistributed(beneficiaries[i].wallet, token, share);
            
            unchecked { ++i; }
        }
        
        // Send remainder to last beneficiary to handle rounding
        uint256 remainder = netAmount - distributed;
        if (remainder > 0) {
            _transferFunds(token, beneficiaries[length - 1].wallet, remainder);
            emit FundsDistributed(beneficiaries[length - 1].wallet, token, remainder);
        }
        
        stats.totalDistributed += uint128(netAmount);
    }
    
    /**
     * @dev Transfer funds (native or ERC20)
     */
    function _transferFunds(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        if (token == address(0)) {
            // Native token transfer
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 transfer
            IERC20(token).safeTransfer(to, amount);
        }
    }
    
    /**
     * @dev Check and emit milestone events
     */
    function _checkMilestones() internal {
        uint256 totalRaised = stats.totalRaised;
        
        // Check for major milestones
        if (totalRaised >= 1000000 ether && totalRaised - stats.platformFeesGenerated < 1000000 ether) {
            emit MilestoneReached("1M_raised", totalRaised, block.timestamp);
        } else if (totalRaised >= 100000 ether && totalRaised - stats.platformFeesGenerated < 100000 ether) {
            emit MilestoneReached("100K_raised", totalRaised, block.timestamp);
        } else if (totalRaised >= 10000 ether && totalRaised - stats.platformFeesGenerated < 10000 ether) {
            emit MilestoneReached("10K_raised", totalRaised, block.timestamp);
        }
        
        // Check donor milestones
        uint256 uniqueDonors = stats.uniqueDonors;
        if (uniqueDonors == 100 || uniqueDonors == 1000 || uniqueDonors == 10000) {
            emit MilestoneReached("donor_count", uniqueDonors, block.timestamp);
        }
    }
    
    /**
     * @dev Extract campaign name from IPFS hash (first 8 chars)
     */
    function _extractCampaignName(string memory ipfsHash) internal pure returns (string memory) {
        bytes memory hashBytes = bytes(ipfsHash);
        uint256 len = hashBytes.length < 8 ? hashBytes.length : 8;
        bytes memory nameBytes = new bytes(len);
        
        for (uint256 i; i < len;) {
            nameBytes[i] = hashBytes[i];
            unchecked { ++i; }
        }
        
        return string(nameBytes);
    }
}
