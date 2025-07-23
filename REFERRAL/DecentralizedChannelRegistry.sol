// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title DecentralizedChannelRegistry
 * @dev A registry for managing tradeable user profiles (@names), wallets, and communication privileges
 * @notice This contract enables users to register unique usernames, trade them, and stake tokens for enhanced features
 * @notice UPDATED: Now includes full compatibility with messaging, payment, and IPFS contracts
 */
contract DecentralizedChannelRegistry is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Token used for payments and staking
    IERC20 public immutable xdmToken;
    
    // Registration and staking costs
    uint256 public registrationFee = 100 * 10**18; // 100 XDM tokens
    uint256 public constant STAKE_REQUIREMENT = 1000 * 10**18; // 1,000 XDM tokens
    uint256 public constant MIN_USERNAME_LENGTH = 3;
    uint256 public constant MAX_USERNAME_LENGTH = 32;
    
    // Rewards pool address for collecting fees
    address public rewardsPool;
    
    // Referral contract address
    address public referralContract;
    
    // Marketplace fee (percentage of sale price, 250 = 2.5%)
    uint256 public marketplaceFee = 250; // 2.5%
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE = 1000; // 10% maximum
    
    // === NEW: Authorization and logging ===
    mapping(address => bool) public authorizedContracts;
    uint256 private nextMessageId = 1;
    uint256 public totalMessages;
    uint256 public totalPayments;
    uint256 public totalRichMessages;
    
    // User profile structure
    struct UserProfile {
        string username; // @ name
        address primaryWallet;
        string email;
        string phoneNumber;
        uint256 registeredAt;
        uint256 stakedAmount;
        bool isRegistered;
        bool hasPayloadPrivileges; // true if staked >= 1,000 XDM
        address referredBy; // Address of referrer
        uint256 totalReferrals; // Number of users referred
        mapping(uint256 => address) additionalWallets; // chainId => wallet address
        uint256[] supportedChainIds;
    }
    
    // Marketplace listing structure
    struct Listing {
        address seller;
        uint256 price;
        bool isActive;
        uint256 listedAt;
    }
    
    // Mappings for efficient lookups
    mapping(address => UserProfile) public profiles;
    mapping(string => address) public usernameToAddress;
    mapping(address => string) public addressToUsername;
    mapping(string => Listing) public marketplace; // username => listing info
    
    // Username validation pattern storage
    mapping(bytes1 => bool) private validUsernameChars;
    
    // Array to track all registered users
    address[] public registeredUsers;
    mapping(address => uint256) public userIndex; // For efficient array management
    
    // Statistics
    uint256 public totalRegisteredUsers;
    uint256 public totalStakedUsers;
    uint256 public totalStakedAmount;
    uint256 public totalVolumeTraded;
    uint256 public totalTradeCount;
    uint256 public totalReferrals;
    
    // Events
    event UserRegistered(
        address indexed wallet,
        string username,
        string email,
        string phoneNumber,
        uint256 timestamp
    );
    
    event UserRegisteredWithReferral(
        address indexed wallet,
        string username,
        address indexed referrer,
        string referrerUsername,
        uint256 timestamp
    );
    
    event UsernameTransferred(
        string indexed username,
        address indexed from,
        address indexed to,
        uint256 price
    );
    
    event UsernameListed(
        string indexed username,
        address indexed seller,
        uint256 price,
        uint256 timestamp
    );
    
    event ListingCancelled(
        string indexed username,
        address indexed seller
    );
    
    event WalletAdded(
        address indexed primaryWallet,
        uint256 chainId,
        address newWallet
    );
    
    event WalletRemoved(
        address indexed primaryWallet,
        uint256 chainId
    );
    
    event TokensStaked(
        address indexed user,
        uint256 amount,
        uint256 totalStaked
    );
    
    event TokensUnstaked(
        address indexed user,
        uint256 amount,
        uint256 remainingStaked
    );
    
    event RewardsPoolUpdated(
        address indexed oldPool,
        address indexed newPool
    );
    
    event ReferralContractUpdated(
        address indexed oldContract,
        address indexed newContract
    );
    
    event MarketplaceFeeUpdated(
        uint256 oldFee,
        uint256 newFee
    );
    
    event RegistrationFeeUpdated(
        uint256 oldFee,
        uint256 newFee
    );
    
    event ContactInfoUpdated(
        address indexed user,
        string newEmail,
        string newPhone
    );
    
    // === NEW: Events for logging ===
    event MessageLogged(
        uint256 indexed messageId,
        address indexed sender,
        address indexed recipient,
        bool isRichContent,
        uint256 timestamp
    );
    
    event PaymentLogged(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );
    
    event ContractAuthorized(
        address indexed contractAddress,
        bool authorized
    );
    
    modifier onlyRegistered() {
        require(profiles[msg.sender].isRegistered, "User not registered");
        _;
    }
    
    modifier onlyUsernameOwner(string memory _username) {
        require(usernameToAddress[_username] == msg.sender, "Not username owner");
        _;
    }
    
    modifier usernameAvailable(string memory _username) {
        require(bytes(_username).length >= MIN_USERNAME_LENGTH, "Username too short");
        require(bytes(_username).length <= MAX_USERNAME_LENGTH, "Username too long");
        require(usernameToAddress[_username] == address(0), "Username already taken");
        require(_isValidUsername(_username), "Invalid username format");
        _;
    }
    
    modifier onlyReferralContract() {
        require(msg.sender == referralContract, "Only referral contract");
        _;
    }
    
    // === NEW: Modifier for authorized contracts ===
    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    /**
     * @dev Constructor initializes the contract with necessary addresses
     * @param _xdmToken Address of the XDM token contract
     * @param _rewardsPool Address where fees will be collected
     * @param _initialOwner Address of the contract owner
     */
    constructor(
        address _xdmToken, 
        address _rewardsPool,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_xdmToken != address(0), "Invalid token address");
        require(_rewardsPool != address(0), "Invalid rewards pool address");
        
        xdmToken = IERC20(_xdmToken);
        rewardsPool = _rewardsPool;
        
        // Initialize valid username characters (a-z, A-Z, 0-9, _, -)
        for (uint8 i = 48; i <= 57; i++) validUsernameChars[bytes1(i)] = true; // 0-9
        for (uint8 i = 65; i <= 90; i++) validUsernameChars[bytes1(i)] = true; // A-Z
        for (uint8 i = 97; i <= 122; i++) validUsernameChars[bytes1(i)] = true; // a-z
        validUsernameChars[bytes1(uint8(95))] = true; // _
        validUsernameChars[bytes1(uint8(45))] = true; // -
    }
    
    /**
     * @dev Validates username format
     * @param _username Username to validate
     * @return bool indicating if username is valid
     */
    function _isValidUsername(string memory _username) private view returns (bool) {
        bytes memory usernameBytes = bytes(_username);
        
        // Check first character is alphanumeric
        bytes1 firstChar = usernameBytes[0];
        if (!((firstChar >= 0x30 && firstChar <= 0x39) || // 0-9
              (firstChar >= 0x41 && firstChar <= 0x5A) || // A-Z
              (firstChar >= 0x61 && firstChar <= 0x7A))) { // a-z
            return false;
        }
        
        // Check all characters are valid
        for (uint i = 0; i < usernameBytes.length; i++) {
            if (!validUsernameChars[usernameBytes[i]]) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @dev Register a new user profile
     * @param _username The desired @ name
     * @param _email Contact email
     * @param _phoneNumber Contact phone number
     */
    function registerUser(
        string memory _username,
        string memory _email,
        string memory _phoneNumber
    ) external nonReentrant whenNotPaused usernameAvailable(_username) {
        _registerUserInternal(_username, _email, _phoneNumber, address(0));
    }
    
    /**
     * @dev Register a new user profile with referral
     * @param _username The desired @ name
     * @param _email Contact email
     * @param _phoneNumber Contact phone number
     * @param _referrer Address of the referrer
     */
    function registerUserWithReferral(
        string memory _username,
        string memory _email,
        string memory _phoneNumber,
        address _referrer
    ) external nonReentrant whenNotPaused usernameAvailable(_username) {
        require(_referrer != address(0), "Invalid referrer address");
        require(_referrer != msg.sender, "Cannot refer yourself");
        require(profiles[_referrer].isRegistered, "Referrer not registered");
        
        _registerUserInternal(_username, _email, _phoneNumber, _referrer);
        
        // Update referrer's stats
        profiles[_referrer].totalReferrals++;
        totalReferrals++;
        
        // Emit special event for referral registration
        emit UserRegisteredWithReferral(
            msg.sender,
            _username,
            _referrer,
            profiles[_referrer].username,
            block.timestamp
        );
        
        // Notify referral contract if set
        if (referralContract != address(0)) {
            try IReferralPayout(referralContract).processReferral(msg.sender, _referrer) {} catch {}
        }
    }
    
    /**
     * @dev Internal function to register user
     */
    function _registerUserInternal(
        string memory _username,
        string memory _email,
        string memory _phoneNumber,
        address _referrer
    ) private {
        require(!profiles[msg.sender].isRegistered, "Already registered");
        require(bytes(_email).length > 0 && bytes(_email).length <= 100, "Invalid email length");
        require(bytes(_phoneNumber).length > 0 && bytes(_phoneNumber).length <= 20, "Invalid phone length");
        
        // Transfer registration fee to rewards pool using SafeERC20
        xdmToken.safeTransferFrom(msg.sender, rewardsPool, registrationFee);
        
        // Create profile
        UserProfile storage profile = profiles[msg.sender];
        profile.username = _username;
        profile.primaryWallet = msg.sender;
        profile.email = _email;
        profile.phoneNumber = _phoneNumber;
        profile.registeredAt = block.timestamp;
        profile.isRegistered = true;
        profile.stakedAmount = 0;
        profile.hasPayloadPrivileges = false;
        profile.referredBy = _referrer;
        profile.totalReferrals = 0;
        
        // Update mappings
        usernameToAddress[_username] = msg.sender;
        addressToUsername[msg.sender] = _username;
        
        // Add to registered users array
        userIndex[msg.sender] = registeredUsers.length;
        registeredUsers.push(msg.sender);
        
        totalRegisteredUsers++;
        
        emit UserRegistered(
            msg.sender,
            _username,
            _email,
            _phoneNumber,
            block.timestamp
        );
    }
    
    /**
     * @dev List a username for sale
     * @param _username Username to list
     * @param _price Sale price in XDM tokens
     */
    function listUsername(
        string memory _username,
        uint256 _price
    ) external onlyRegistered onlyUsernameOwner(_username) whenNotPaused {
        require(_price > 0, "Price must be greater than 0");
        require(!marketplace[_username].isActive, "Already listed");
        
        marketplace[_username] = Listing({
            seller: msg.sender,
            price: _price,
            isActive: true,
            listedAt: block.timestamp
        });
        
        emit UsernameListed(_username, msg.sender, _price, block.timestamp);
    }
    
    /**
     * @dev Cancel a username listing
     * @param _username Username to delist
     */
    function cancelListing(
        string memory _username
    ) external onlyUsernameOwner(_username) {
        require(marketplace[_username].isActive, "Not listed");
        
        delete marketplace[_username];
        
        emit ListingCancelled(_username, msg.sender);
    }
    
    /**
     * @dev Buy a listed username
     * @param _username Username to purchase
     * @param _newEmail New owner's email
     * @param _newPhone New owner's phone number
     */
    function buyUsername(
        string memory _username,
        string memory _newEmail,
        string memory _newPhone
    ) external nonReentrant whenNotPaused {
        Listing memory listing = marketplace[_username];
        require(listing.isActive, "Username not for sale");
        require(listing.seller != msg.sender, "Cannot buy own username");
        require(bytes(_newEmail).length > 0 && bytes(_newEmail).length <= 100, "Invalid email length");
        require(bytes(_newPhone).length > 0 && bytes(_newPhone).length <= 20, "Invalid phone length");
        
        address seller = listing.seller;
        uint256 price = listing.price;
        
        // Calculate fees
        uint256 fee = (price * marketplaceFee) / FEE_DENOMINATOR;
        uint256 sellerAmount = price - fee;
        
        // Transfer payment using SafeERC20
        xdmToken.safeTransferFrom(msg.sender, seller, sellerAmount);
        
        // Transfer fee to rewards pool
        if (fee > 0) {
            xdmToken.safeTransferFrom(msg.sender, rewardsPool, fee);
        }
        
        // Handle seller's staked tokens
        _handleStakedTokensTransfer(seller);
        
        // Clear seller's profile
        _clearUserProfile(seller);
        
        // Set up buyer's profile
        _setupBuyerProfile(msg.sender, _username, _newEmail, _newPhone);
        
        // Remove listing
        delete marketplace[_username];
        
        // Update statistics
        totalVolumeTraded += price;
        totalTradeCount++;
        
        emit UsernameTransferred(_username, seller, msg.sender, price);
    }
    
    /**
     * @dev Transfer username directly (no payment)
     * @param _username Username to transfer
     * @param _to Recipient address
     * @param _newEmail Recipient's email
     * @param _newPhone Recipient's phone number
     */
    function transferUsername(
        string memory _username,
        address _to,
        string memory _newEmail,
        string memory _newPhone
    ) external onlyRegistered onlyUsernameOwner(_username) nonReentrant whenNotPaused {
        require(_to != address(0), "Invalid recipient");
        require(_to != msg.sender, "Cannot transfer to self");
        require(bytes(_newEmail).length > 0 && bytes(_newEmail).length <= 100, "Invalid email length");
        require(bytes(_newPhone).length > 0 && bytes(_newPhone).length <= 20, "Invalid phone length");
        require(!marketplace[_username].isActive, "Cancel listing first");
        
        // Handle sender's staked tokens
        _handleStakedTokensTransfer(msg.sender);
        
        // Clear sender's profile
        _clearUserProfile(msg.sender);
        
        // Set up recipient's profile
        _setupBuyerProfile(_to, _username, _newEmail, _newPhone);
        
        emit UsernameTransferred(_username, msg.sender, _to, 0);
    }
    
    /**
     * @dev Internal function to handle staked tokens during transfer
     * @param _user Address of the user whose tokens to handle
     */
    function _handleStakedTokensTransfer(address _user) private {
        UserProfile storage profile = profiles[_user];
        uint256 stakedAmount = profile.stakedAmount;
        
        if (stakedAmount > 0) {
            profile.stakedAmount = 0;
            totalStakedAmount -= stakedAmount;
            
            if (profile.hasPayloadPrivileges) {
                profile.hasPayloadPrivileges = false;
                totalStakedUsers--;
            }
            
            xdmToken.safeTransfer(_user, stakedAmount);
        }
    }
    
    /**
     * @dev Internal function to clear a user's profile
     * @param _user Address of the user to clear
     */
    function _clearUserProfile(address _user) private {
        UserProfile storage profile = profiles[_user];
        
        // Remove from registered users array
        uint256 index = userIndex[_user];
        uint256 lastIndex = registeredUsers.length - 1;
        
        if (index != lastIndex) {
            address lastUser = registeredUsers[lastIndex];
            registeredUsers[index] = lastUser;
            userIndex[lastUser] = index;
        }
        
        registeredUsers.pop();
        delete userIndex[_user];
        
        delete addressToUsername[_user];
        profile.isRegistered = false;
        profile.username = "";
        profile.hasPayloadPrivileges = false;
        profile.email = "";
        profile.phoneNumber = "";
        profile.referredBy = address(0);
        profile.totalReferrals = 0;
        
        // Clear additional wallets
        for (uint i = 0; i < profile.supportedChainIds.length; i++) {
            delete profile.additionalWallets[profile.supportedChainIds[i]];
        }
        delete profile.supportedChainIds;
    }
    
    /**
     * @dev Internal function to set up buyer's profile
     * @param _buyer Address of the buyer
     * @param _username Username being acquired
     * @param _email Email address
     * @param _phone Phone number
     */
    function _setupBuyerProfile(
        address _buyer,
        string memory _username,
        string memory _email,
        string memory _phone
    ) private {
        UserProfile storage buyerProfile = profiles[_buyer];
        
        bool wasRegistered = buyerProfile.isRegistered;
        
        // If buyer already has a username, clear it
        if (bytes(buyerProfile.username).length > 0) {
            delete usernameToAddress[buyerProfile.username];
        }
        
        // Transfer username to buyer
        buyerProfile.username = _username;
        buyerProfile.primaryWallet = _buyer;
        buyerProfile.email = _email;
        buyerProfile.phoneNumber = _phone;
        buyerProfile.registeredAt = block.timestamp;
        buyerProfile.isRegistered = true;
        
        // Update mappings
        usernameToAddress[_username] = _buyer;
        addressToUsername[_buyer] = _username;
        
        // Add to registered users array if not already registered
        if (!wasRegistered) {
            userIndex[_buyer] = registeredUsers.length;
            registeredUsers.push(_buyer);
            totalRegisteredUsers++;
        }
    }
    
    /**
     * @dev Stake XDM tokens to enable payload messaging
     * @param _amount Amount of XDM tokens to stake
     */
    function stakeTokens(uint256 _amount) external onlyRegistered nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from user using SafeERC20
        xdmToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        UserProfile storage profile = profiles[msg.sender];
        profile.stakedAmount += _amount;
        totalStakedAmount += _amount;
        
        // Check if user now meets staking requirement
        if (!profile.hasPayloadPrivileges && profile.stakedAmount >= STAKE_REQUIREMENT) {
            profile.hasPayloadPrivileges = true;
            totalStakedUsers++;
        }
        
        emit TokensStaked(msg.sender, _amount, profile.stakedAmount);
    }
    
    /**
     * @dev Unstake XDM tokens
     * @param _amount Amount of XDM tokens to unstake
     */
    function unstakeTokens(uint256 _amount) external onlyRegistered nonReentrant {
        UserProfile storage profile = profiles[msg.sender];
        require(profile.stakedAmount >= _amount, "Insufficient staked balance");
        
        profile.stakedAmount -= _amount;
        totalStakedAmount -= _amount;
        
        // Check if user no longer meets staking requirement
        if (profile.hasPayloadPrivileges && profile.stakedAmount < STAKE_REQUIREMENT) {
            profile.hasPayloadPrivileges = false;
            totalStakedUsers--;
        }
        
        // Transfer tokens back to user using SafeERC20
        xdmToken.safeTransfer(msg.sender, _amount);
        
        emit TokensUnstaked(msg.sender, _amount, profile.stakedAmount);
    }
    
    /**
     * @dev Add an additional wallet for a different chain
     * @param _chainId The chain ID for the wallet
     * @param _wallet The wallet address on that chain
     */
    function addWallet(uint256 _chainId, address _wallet) external onlyRegistered whenNotPaused {
        require(_wallet != address(0), "Invalid wallet address");
        require(_chainId > 0, "Invalid chain ID");
        require(_chainId != block.chainid, "Use primary wallet for current chain");
        
        UserProfile storage profile = profiles[msg.sender];
        
        // Check if this chain already has a wallet
        if (profile.additionalWallets[_chainId] == address(0)) {
            profile.supportedChainIds.push(_chainId);
        }
        
        profile.additionalWallets[_chainId] = _wallet;
        
        emit WalletAdded(msg.sender, _chainId, _wallet);
    }
    
    /**
     * @dev Remove a wallet for a specific chain
     * @param _chainId The chain ID to remove
     */
    function removeWallet(uint256 _chainId) external onlyRegistered {
        UserProfile storage profile = profiles[msg.sender];
        require(profile.additionalWallets[_chainId] != address(0), "Wallet not found");
        
        delete profile.additionalWallets[_chainId];
        
        // Remove from supportedChainIds array
        for (uint i = 0; i < profile.supportedChainIds.length; i++) {
            if (profile.supportedChainIds[i] == _chainId) {
                profile.supportedChainIds[i] = profile.supportedChainIds[profile.supportedChainIds.length - 1];
                profile.supportedChainIds.pop();
                break;
            }
        }
        
        emit WalletRemoved(msg.sender, _chainId);
    }
    
    /**
     * @dev Update contact information
     * @param _email New email address
     * @param _phoneNumber New phone number
     */
    function updateContactInfo(
        string memory _email,
        string memory _phoneNumber
    ) external onlyRegistered whenNotPaused {
        require(bytes(_email).length > 0 && bytes(_email).length <= 100, "Invalid email length");
        require(bytes(_phoneNumber).length > 0 && bytes(_phoneNumber).length <= 20, "Invalid phone length");
        
        UserProfile storage profile = profiles[msg.sender];
        profile.email = _email;
        profile.phoneNumber = _phoneNumber;
        
        emit ContactInfoUpdated(msg.sender, _email, _phoneNumber);
    }
    
    // === NEW: Compatibility Functions ===
    
    /**
     * @dev Authorize a contract to log messages and payments
     * @param _contract Contract address to authorize
     * @param _authorized Authorization status
     */
    function authorizeContract(address _contract, bool _authorized) external onlyOwner {
        require(_contract != address(0), "Invalid contract address");
        authorizedContracts[_contract] = _authorized;
        emit ContractAuthorized(_contract, _authorized);
    }
    
    /**
     * @dev Log a message sent between users (called by messaging contract)
     * @param _sender Sender address
     * @param _recipient Recipient username
     * @param _isRichContent Whether message contains rich content
     */
    function logMessage(
        address _sender,
        string memory _recipient,
        string memory /* _ipfsHash */,
        bool _isRichContent
    ) external onlyAuthorized returns (uint256) {
        require(profiles[_sender].isRegistered, "Sender not registered");
        address recipientAddr = usernameToAddress[_recipient];
        require(recipientAddr != address(0), "Recipient not found");
        
        if (_isRichContent) {
            require(profiles[_sender].hasPayloadPrivileges, "Payload privileges required");
            totalRichMessages++;
        }
        
        uint256 messageId = nextMessageId++;
        totalMessages++;
        
        emit MessageLogged(messageId, _sender, recipientAddr, _isRichContent, block.timestamp);
        
        return messageId;
    }
    
    /**
     * @dev Log a payment between users (called by payment contract)
     * @param _from Sender address
     * @param _to Recipient username
     * @param _amount Payment amount
     */
    function logPayment(
        address _from,
        string memory _to,
        uint256 _amount
    ) external onlyAuthorized {
        require(profiles[_from].isRegistered, "Sender not registered");
        address recipientAddr = usernameToAddress[_to];
        require(recipientAddr != address(0), "Recipient not found");
        
        totalPayments++;
        
        emit PaymentLogged(_from, recipientAddr, _amount, block.timestamp);
    }
    
    /**
     * @dev Alias for canSendPayloads to maintain compatibility
     * @param _user Address to check
     */
    function canSendRichContent(address _user) external view returns (bool) {
        return profiles[_user].hasPayloadPrivileges;
    }
    
    /**
     * @dev Get user tier (0=not registered, 1=basic, 2=premium)
     * @param _user Address to check
     */
    function getUserTier(address _user) external view returns (uint8) {
        UserProfile storage profile = profiles[_user];
        if (!profile.isRegistered) return 0;
        if (profile.hasPayloadPrivileges) return 2;
        return 1;
    }
    
    // === END NEW: Compatibility Functions ===
    
    /**
     * @dev Get marketplace listing details
     * @param _username Username to query
     */
    function getListing(string memory _username) external view returns (
        address seller,
        uint256 price,
        bool isActive,
        uint256 listedAt
    ) {
        Listing memory listing = marketplace[_username];
        return (listing.seller, listing.price, listing.isActive, listing.listedAt);
    }
    
    /**
     * @dev Get user profile information
     * @param _user Address of the user
     */
    function getUserProfile(address _user) external view returns (
        string memory username,
        address primaryWallet,
        string memory email,
        string memory phoneNumber,
        uint256 registeredAt,
        uint256 stakedAmount,
        bool hasPayloadAccess,
        address referredBy,
        uint256 userReferralCount,
        uint256[] memory supportedChainIds
    ) {
        UserProfile storage profile = profiles[_user];
        require(profile.isRegistered, "User not found");
        
        return (
            profile.username,
            profile.primaryWallet,
            profile.email,
            profile.phoneNumber,
            profile.registeredAt,
            profile.stakedAmount,
            profile.hasPayloadPrivileges,
            profile.referredBy,
            profile.totalReferrals,
            profile.supportedChainIds
        );
    }
    
    /**
     * @dev Get user profile by username
     * @param _username The @ name to lookup
     */
    function getUserByUsername(string memory _username) external view returns (address) {
        address userAddress = usernameToAddress[_username];
        require(userAddress != address(0), "Username not found");
        return userAddress;
    }
    
    /**
     * @dev Get wallet address for a specific chain
     * @param _user User address
     * @param _chainId Chain ID to query
     */
    function getWalletForChain(address _user, uint256 _chainId) external view returns (address) {
        require(profiles[_user].isRegistered, "User not found");
        
        if (_chainId == block.chainid) {
            return profiles[_user].primaryWallet;
        }
        
        address wallet = profiles[_user].additionalWallets[_chainId];
        return wallet != address(0) ? wallet : address(0);
    }
    
    /**
     * @dev Get all wallets for a user
     * @param _user User address
     */
    function getAllWallets(address _user) external view returns (
        uint256[] memory chainIds,
        address[] memory wallets
    ) {
        UserProfile storage profile = profiles[_user];
        require(profile.isRegistered, "User not found");
        
        uint256 totalWallets = profile.supportedChainIds.length + 1; // +1 for primary
        chainIds = new uint256[](totalWallets);
        wallets = new address[](totalWallets);
        
        // Add primary wallet
        chainIds[0] = block.chainid;
        wallets[0] = profile.primaryWallet;
        
        // Add additional wallets
        for (uint i = 0; i < profile.supportedChainIds.length; i++) {
            uint256 chainId = profile.supportedChainIds[i];
            chainIds[i + 1] = chainId;
            wallets[i + 1] = profile.additionalWallets[chainId];
        }
        
        return (chainIds, wallets);
    }
    
    /**
     * @dev Get all registered users (paginated)
     * @param _offset Starting index
     * @param _limit Number of users to return
     */
    function getRegisteredUsers(uint256 _offset, uint256 _limit) external view returns (
        address[] memory users,
        string[] memory usernames,
        uint256 total
    ) {
        require(_limit > 0 && _limit <= 100, "Invalid limit");
        
        uint256 totalUsers = registeredUsers.length;
        if (_offset >= totalUsers) {
            return (new address[](0), new string[](0), totalUsers);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalUsers) {
            end = totalUsers;
        }
        
        uint256 length = end - _offset;
        users = new address[](length);
        usernames = new string[](length);
        
        for (uint256 i = 0; i < length; i++) {
            address user = registeredUsers[_offset + i];
            users[i] = user;
            usernames[i] = profiles[user].username;
        }
        
        return (users, usernames, totalUsers);
    }
    
    /**
     * @dev Get username and referral status for an address
     * @param _user Address to query
     */
    function getUsernameAndReferralStatus(address _user) external view returns (
        string memory username,
        bool isRegistered,
        address referredBy,
        uint256 userReferralCount
    ) {
        UserProfile storage profile = profiles[_user];
        return (
            profile.username,
            profile.isRegistered,
            profile.referredBy,
            profile.totalReferrals
        );
    }
    
    /**
     * @dev Check if user can send payments
     * @param _user Address to check
     */
    function canSendPayments(address _user) external view returns (bool) {
        return profiles[_user].isRegistered;
    }
    
    /**
     * @dev Check if user can send payload messages
     * @param _user Address to check
     */
    function canSendPayloads(address _user) external view returns (bool) {
        return profiles[_user].hasPayloadPrivileges;
    }
    
    /**
     * @dev Check if a username is valid format
     * @param _username Username to check
     */
    function isValidUsernameFormat(string memory _username) external view returns (bool) {
        if (bytes(_username).length < MIN_USERNAME_LENGTH || 
            bytes(_username).length > MAX_USERNAME_LENGTH) {
            return false;
        }
        return _isValidUsername(_username);
    }
    
    /**
     * @dev Set referral contract address (owner only)
     * @param _referralContract New referral contract address
     */
    function setReferralContract(address _referralContract) external onlyOwner {
        address oldContract = referralContract;
        referralContract = _referralContract;
        emit ReferralContractUpdated(oldContract, _referralContract);
    }
    
    /**
     * @dev Update rewards pool address (owner only)
     * @param _newRewardsPool New rewards pool address
     */
    function updateRewardsPool(address _newRewardsPool) external onlyOwner {
        require(_newRewardsPool != address(0), "Invalid address");
        address oldPool = rewardsPool;
        rewardsPool = _newRewardsPool;
        emit RewardsPoolUpdated(oldPool, _newRewardsPool);
    }
    
    /**
     * @dev Update marketplace fee (owner only)
     * @param _newFee New fee percentage (e.g., 250 = 2.5%)
     */
    function updateMarketplaceFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= MAX_FEE, "Fee too high");
        uint256 oldFee = marketplaceFee;
        marketplaceFee = _newFee;
        emit MarketplaceFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Update registration fee (owner only)
     * @param _newFee New registration fee in XDM tokens (with decimals)
     */
    function updateRegistrationFee(uint256 _newFee) external onlyOwner {
        require(_newFee > 0, "Fee must be greater than 0");
        uint256 oldFee = registrationFee;
        registrationFee = _newFee;
        emit RegistrationFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Pause the contract (owner only)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract (owner only)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Get contract statistics
     */
    function getStats() external view returns (
        uint256 registered,
        uint256 staked,
        uint256 totalStaked,
        uint256 volumeTraded,
        uint256 tradeCount,
        uint256 referrals,
        uint256 contractBalance,
        uint256 messagesLogged,
        uint256 paymentsLogged,
        uint256 richMessagesLogged
    ) {
        return (
            totalRegisteredUsers,
            totalStakedUsers,
            totalStakedAmount,
            totalVolumeTraded,
            totalTradeCount,
            totalReferrals,
            xdmToken.balanceOf(address(this)),
            totalMessages,
            totalPayments,
            totalRichMessages
        );
    }
    
    /**
     * @dev Emergency withdrawal function (owner only, when paused)
     * @param _token Token to withdraw (address(0) for ETH)
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner whenPaused {
        if (_token == address(0)) {
            require(address(this).balance >= _amount, "Insufficient ETH balance");
            payable(owner()).transfer(_amount);
        } else {
            IERC20(_token).safeTransfer(owner(), _amount);
        }
    }
}

/**
 * @title IReferralPayout
 * @dev Interface for the referral payout contract
 */
interface IReferralPayout {
    function processReferral(address newUser, address referrer) external;
}
