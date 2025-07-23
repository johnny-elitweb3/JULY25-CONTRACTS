// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IDecentralizedChannelRegistry
 * @dev Interface for interacting with the registry
 */
interface IDecentralizedChannelRegistry {
    function getUsernameAndReferralStatus(address _user)
        external
        view
        returns (
            string memory username,
            bool isRegistered,
            address referredBy,
            uint256 userReferralCount
        );

    function getUserByUsername(string memory _username)
        external
        view
        returns (address);

    function canSendPayments(address _user) external view returns (bool);

    function getUserTier(address _user) external view returns (uint8);

    function logPayment(
        address _from,
        string memory _to,
        uint256 _amount
    ) external;
}

/**
 * @title IReferralPayoutContract
 * @dev Interface for the referral payout system
 */
interface IReferralPayoutContract {
    function processReferral(address _newUser, address _referrer) external;
}

/**
 * @title IIntegratedApplication
 * @dev Interface that integrated applications must implement
 */
interface IIntegratedApplication {
    function onPurchaseWithReferral(
        address buyer,
        uint256 purchaseAmount,
        string memory referrerUsername,
        bytes calldata data
    ) external returns (bool);
}

/**
 * @title UniversalApplicationAdapter
 * @dev Universal adapter for connecting any application to the @name registry and referral system
 * @notice This contract enables any dApp to integrate referral tracking and rewards
 */
contract UniversalApplicationAdapter is
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant APPLICATION_ROLE = keccak256("APPLICATION_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Core contracts
    IDecentralizedChannelRegistry public immutable registry;
    IReferralPayoutContract public referralPayout;
    IERC20 public immutable xdmToken;

    // Application registration structure
    struct Application {
        string name;
        address contractAddress;
        uint256 commissionRate; // Percentage in basis points (10000 = 100%)
        uint256 minPurchaseAmount;
        bool isActive;
        bool autoProcessReferrals;
        uint256 totalPurchases;
        uint256 totalVolume;
        uint256 registeredAt;
    }

    // Purchase event structure
    struct PurchaseEvent {
        address application;
        address buyer;
        string buyerUsername;
        address referrer;
        string referrerUsername;
        uint256 purchaseAmount;
        uint256 commissionPaid;
        uint256 timestamp;
        string productId;
        PurchaseType purchaseType;
    }

    // Purchase types for different applications
    enum PurchaseType {
        NFT_SALE,
        TOKEN_SWAP,
        SERVICE_PAYMENT,
        SUBSCRIPTION,
        COMMODITY_TRADE,
        CUSTOM
    }

    // Commission distribution structure
    struct CommissionConfig {
        uint256 referrerShare; // Share going to referrer (basis points)
        uint256 platformShare; // Share going to platform
        uint256 burnShare; // Share to burn (deflationary)
        address platformWallet; // Where platform fees go
    }

    // Mappings
    mapping(address => Application) public applications;
    mapping(address => bool) public isRegisteredApp;
    mapping(bytes32 => PurchaseEvent) public purchaseEvents;
    mapping(address => CommissionConfig) public commissionConfigs;

    // Tracking
    mapping(address => mapping(address => uint256)) public referralPurchases; // referrer => buyer => count
    mapping(address => mapping(string => uint256)) public appReferralVolume; // app => referrerUsername => volume
    mapping(address => uint256) public userTotalEarnings; // Total earnings per user across all apps
    mapping(address => uint256) public appTotalCommissions; // Total commissions per app

    // Arrays for enumeration
    address[] public registeredApplications;
    bytes32[] public allPurchaseEvents;

    // Configuration
    uint256 public defaultCommissionRate = 250; // 2.5% default
    uint256 public minCommissionRate = 50; // 0.5% minimum
    uint256 public maxCommissionRate = 2000; // 20% maximum
    address public defaultPlatformWallet;
    address public burnAddress = address(0xdead);

    // Statistics
    uint256 public totalApplications;
    uint256 public totalPurchaseEvents;
    uint256 public totalVolumeProcessed;
    uint256 public totalCommissionsPaid;
    uint256 public totalReferralRewards;

    // Events
    event ApplicationRegistered(
        address indexed application,
        string name,
        uint256 commissionRate,
        uint256 timestamp
    );

    event ApplicationUpdated(
        address indexed application,
        uint256 newCommissionRate,
        bool isActive
    );

    event PurchaseProcessed(
        bytes32 indexed eventId,
        address indexed application,
        address indexed buyer,
        address referrer,
        uint256 purchaseAmount,
        uint256 commissionPaid,
        PurchaseType purchaseType,
        string productId,
        uint256 timestamp
    );

    event ReferralCommissionPaid(
        address indexed referrer,
        address indexed buyer,
        address indexed application,
        uint256 amount,
        uint256 timestamp
    );

    event CommissionConfigUpdated(
        address indexed application,
        uint256 referrerShare,
        uint256 platformShare,
        uint256 burnShare
    );

    event PlatformWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );

    event ReferralPayoutContractUpdated(
        address indexed oldContract,
        address indexed newContract
    );

    modifier onlyRegisteredApp() {
        require(isRegisteredApp[msg.sender], "Not a registered application");
        require(applications[msg.sender].isActive, "Application not active");
        _;
    }

    modifier validCommissionRate(uint256 _rate) {
        require(
            _rate >= minCommissionRate && _rate <= maxCommissionRate,
            "Invalid commission rate"
        );
        _;
    }

    /**
     * @dev Constructor
     * @param _registry Address of the DecentralizedChannelRegistry
     * @param _referralPayout Address of the ReferralPayoutContract
     * @param _xdmToken Address of the XDM token
     * @param _defaultPlatformWallet Default wallet for platform fees
     */
    constructor(
        address _registry,
        address _referralPayout,
        address _xdmToken,
        address _defaultPlatformWallet
    ) {
        require(_registry != address(0), "Invalid registry");
        require(_xdmToken != address(0), "Invalid token");
        require(
            _defaultPlatformWallet != address(0),
            "Invalid platform wallet"
        );

        registry = IDecentralizedChannelRegistry(_registry);
        referralPayout = IReferralPayoutContract(_referralPayout);
        xdmToken = IERC20(_xdmToken);
        defaultPlatformWallet = _defaultPlatformWallet;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @dev Register a new application
     * @param _name Application name
     * @param _contractAddress Application contract address
     * @param _commissionRate Commission rate in basis points
     * @param _minPurchaseAmount Minimum purchase amount for referrals
     * @param _autoProcessReferrals Whether to auto-process referral payouts
     */
    function registerApplication(
        string memory _name,
        address _contractAddress,
        uint256 _commissionRate,
        uint256 _minPurchaseAmount,
        bool _autoProcessReferrals
    ) external validCommissionRate(_commissionRate) {
        require(_contractAddress != address(0), "Invalid contract address");
        require(!isRegisteredApp[_contractAddress], "Already registered");
        require(bytes(_name).length > 0, "Name required");

        applications[_contractAddress] = Application({
            name: _name,
            contractAddress: _contractAddress,
            commissionRate: _commissionRate,
            minPurchaseAmount: _minPurchaseAmount,
            isActive: true,
            autoProcessReferrals: _autoProcessReferrals,
            totalPurchases: 0,
            totalVolume: 0,
            registeredAt: block.timestamp
        });

        isRegisteredApp[_contractAddress] = true;
        registeredApplications.push(_contractAddress);
        totalApplications++;

        // Set default commission config
        commissionConfigs[_contractAddress] = CommissionConfig({
            referrerShare: 7000, // 70% to referrer
            platformShare: 2000, // 20% to platform
            burnShare: 1000, // 10% burn
            platformWallet: defaultPlatformWallet
        });

        // Grant APPLICATION_ROLE
        _grantRole(APPLICATION_ROLE, _contractAddress);

        emit ApplicationRegistered(
            _contractAddress,
            _name,
            _commissionRate,
            block.timestamp
        );
    }

    /**
     * @dev Process a purchase with referral
     * @param _buyer Buyer address
     * @param _referrerUsername Referrer's @name
     * @param _purchaseAmount Purchase amount in XDM
     * @param _purchaseType Type of purchase
     * @param _productId Product identifier
     * @param _customData Custom data for the application
     */
    function processPurchaseWithReferral(
        address _buyer,
        string memory _referrerUsername,
        uint256 _purchaseAmount,
        PurchaseType _purchaseType,
        string memory _productId,
        bytes memory _customData
    )
        external
        onlyRegisteredApp
        nonReentrant
        whenNotPaused
        returns (bytes32 eventId)
    {
        Application storage app = applications[msg.sender];
        require(
            _purchaseAmount >= app.minPurchaseAmount,
            "Below minimum amount"
        );

        // Verify buyer is registered
        (string memory buyerUsername, bool buyerRegistered, , ) = registry
            .getUsernameAndReferralStatus(_buyer);
        require(buyerRegistered, "Buyer not registered");

        // Get referrer address
        address referrer = registry.getUserByUsername(_referrerUsername);
        require(referrer != address(0), "Referrer not found");
        require(referrer != _buyer, "Cannot refer yourself");

        // Calculate commission
        uint256 commission = (_purchaseAmount * app.commissionRate) / 10000;

        // Create purchase event
        eventId = keccak256(
            abi.encodePacked(
                msg.sender,
                _buyer,
                referrer,
                _purchaseAmount,
                block.timestamp,
                block.number
            )
        );

        purchaseEvents[eventId] = PurchaseEvent({
            application: msg.sender,
            buyer: _buyer,
            buyerUsername: buyerUsername,
            referrer: referrer,
            referrerUsername: _referrerUsername,
            purchaseAmount: _purchaseAmount,
            commissionPaid: commission,
            timestamp: block.timestamp,
            productId: _productId,
            purchaseType: _purchaseType
        });

        allPurchaseEvents.push(eventId);

        // Update statistics
        _updateStatistics(
            msg.sender,
            _buyer,
            referrer,
            _referrerUsername,
            _purchaseAmount,
            commission
        );

        // Process commission payment
        if (commission > 0) {
            _processCommission(msg.sender, referrer, commission);
        }

        // Auto-process referral if enabled and first purchase
        if (
            app.autoProcessReferrals && referralPurchases[referrer][_buyer] == 1
        ) {
            _triggerReferralPayout(_buyer, referrer);
        }

        // Notify the application
        try
            IIntegratedApplication(msg.sender).onPurchaseWithReferral(
                _buyer,
                _purchaseAmount,
                _referrerUsername,
                _customData
            )
        returns (bool success) {
            require(success, "Application callback failed");
        } catch {}

        emit PurchaseProcessed(
            eventId,
            msg.sender,
            _buyer,
            referrer,
            _purchaseAmount,
            commission,
            _purchaseType,
            _productId,
            block.timestamp
        );

        return eventId;
    }

    /**
     * @dev Process a purchase without referral (direct purchase)
     * @param _buyer Buyer address
     * @param _purchaseAmount Purchase amount
     * @param _purchaseType Type of purchase
     * @param _productId Product identifier
     */
    function processDirectPurchase(
        address _buyer,
        uint256 _purchaseAmount,
        PurchaseType _purchaseType,
        string memory _productId
    )
        external
        onlyRegisteredApp
        nonReentrant
        whenNotPaused
        returns (bytes32 eventId)
    {
        Application storage app = applications[msg.sender];

        // Create event ID
        eventId = keccak256(
            abi.encodePacked(
                msg.sender,
                _buyer,
                _purchaseAmount,
                block.timestamp,
                block.number,
                "DIRECT"
            )
        );

        // Update app statistics
        app.totalPurchases++;
        app.totalVolume += _purchaseAmount;
        totalVolumeProcessed += _purchaseAmount;

        emit PurchaseProcessed(
            eventId,
            msg.sender,
            _buyer,
            address(0),
            _purchaseAmount,
            0,
            _purchaseType,
            _productId,
            block.timestamp
        );

        return eventId;
    }

    /**
     * @dev Update statistics
     */
    function _updateStatistics(
        address _app,
        address _buyer,
        address _referrer,
        string memory _referrerUsername,
        uint256 _purchaseAmount,
        uint256 _commission
    ) private {
        Application storage app = applications[_app];

        app.totalPurchases++;
        app.totalVolume += _purchaseAmount;
        appTotalCommissions[_app] += _commission;

        referralPurchases[_referrer][_buyer]++;
        appReferralVolume[_app][_referrerUsername] += _purchaseAmount;
        userTotalEarnings[_referrer] += _commission;

        totalPurchaseEvents++;
        totalVolumeProcessed += _purchaseAmount;
        totalCommissionsPaid += _commission;
    }

    /**
     * @dev Process commission payment
     */
    function _processCommission(
        address _app,
        address _referrer,
        uint256 _commission
    ) private {
        CommissionConfig memory config = commissionConfigs[_app];

        // Calculate distributions
        uint256 referrerAmount = (_commission * config.referrerShare) / 10000;
        uint256 platformAmount = (_commission * config.platformShare) / 10000;
        uint256 burnAmount = (_commission * config.burnShare) / 10000;

        // Ensure we don't exceed commission due to rounding
        if (referrerAmount + platformAmount + burnAmount > _commission) {
            burnAmount = _commission - referrerAmount - platformAmount;
        }

        // Transfer commissions
        if (referrerAmount > 0) {
            xdmToken.safeTransferFrom(msg.sender, _referrer, referrerAmount);
            totalReferralRewards += referrerAmount;

            emit ReferralCommissionPaid(
                _referrer,
                msg.sender,
                _app,
                referrerAmount,
                block.timestamp
            );
        }

        if (platformAmount > 0) {
            xdmToken.safeTransferFrom(
                msg.sender,
                config.platformWallet,
                platformAmount
            );
        }

        if (burnAmount > 0) {
            xdmToken.safeTransferFrom(msg.sender, burnAddress, burnAmount);
        }
    }

    /**
     * @dev Trigger referral payout in the main referral contract
     */
    function _triggerReferralPayout(address _newUser, address _referrer)
        private
    {
        if (address(referralPayout) != address(0)) {
            try referralPayout.processReferral(_newUser, _referrer) {
                // Success
            } catch {
                // Failed but don't revert the purchase
            }
        }
    }

    /**
     * @dev Manual trigger for referral payout (operator only)
     */
    function manualTriggerReferralPayout(address _newUser, address _referrer)
        external
        onlyRole(OPERATOR_ROLE)
    {
        _triggerReferralPayout(_newUser, _referrer);
    }

    /**
     * @dev Update application settings
     */
    function updateApplication(
        address _app,
        uint256 _commissionRate,
        uint256 _minPurchaseAmount,
        bool _isActive,
        bool _autoProcessReferrals
    ) external onlyRole(ADMIN_ROLE) validCommissionRate(_commissionRate) {
        require(isRegisteredApp[_app], "Application not found");

        Application storage app = applications[_app];
        app.commissionRate = _commissionRate;
        app.minPurchaseAmount = _minPurchaseAmount;
        app.isActive = _isActive;
        app.autoProcessReferrals = _autoProcessReferrals;

        emit ApplicationUpdated(_app, _commissionRate, _isActive);
    }

    /**
     * @dev Update commission configuration for an application
     */
    function updateCommissionConfig(
        address _app,
        uint256 _referrerShare,
        uint256 _platformShare,
        uint256 _burnShare,
        address _platformWallet
    ) external onlyRole(ADMIN_ROLE) {
        require(isRegisteredApp[_app], "Application not found");
        require(
            _referrerShare + _platformShare + _burnShare == 10000,
            "Shares must sum to 100%"
        );
        require(_platformWallet != address(0), "Invalid platform wallet");

        commissionConfigs[_app] = CommissionConfig({
            referrerShare: _referrerShare,
            platformShare: _platformShare,
            burnShare: _burnShare,
            platformWallet: _platformWallet
        });

        emit CommissionConfigUpdated(
            _app,
            _referrerShare,
            _platformShare,
            _burnShare
        );
    }

    /**
     * @dev Get purchase history for a referrer
     */
    function getReferrerPurchaseHistory(
        address _referrer,
        uint256 _offset,
        uint256 _limit
    )
        external
        view
        returns (
            bytes32[] memory eventIds,
            PurchaseEvent[] memory events,
            uint256 totalCount
        )
    {
        require(_limit > 0 && _limit <= 100, "Invalid limit");

        // Count relevant events
        uint256 count = 0;
        for (uint256 i = 0; i < allPurchaseEvents.length; i++) {
            if (purchaseEvents[allPurchaseEvents[i]].referrer == _referrer) {
                count++;
            }
        }

        totalCount = count;

        // Collect events
        uint256 collected = 0;
        uint256 skipped = 0;
        eventIds = new bytes32[](_limit);
        events = new PurchaseEvent[](_limit);

        for (
            uint256 i = 0;
            i < allPurchaseEvents.length && collected < _limit;
            i++
        ) {
            bytes32 eventId = allPurchaseEvents[i];
            if (purchaseEvents[eventId].referrer == _referrer) {
                if (skipped >= _offset) {
                    eventIds[collected] = eventId;
                    events[collected] = purchaseEvents[eventId];
                    collected++;
                } else {
                    skipped++;
                }
            }
        }

        // Resize arrays
        assembly {
            mstore(eventIds, collected)
            mstore(events, collected)
        }

        return (eventIds, events, totalCount);
    }

    /**
     * @dev Get application statistics
     */
    function getApplicationStats(address _app)
        external
        view
        returns (
            string memory name,
            uint256 totalPurchases,
            uint256 totalVolume,
            uint256 totalCommissions,
            uint256 commissionRate,
            bool isActive,
            uint256 registeredAt
        )
    {
        require(isRegisteredApp[_app], "Application not found");

        Application memory app = applications[_app];
        return (
            app.name,
            app.totalPurchases,
            app.totalVolume,
            appTotalCommissions[_app],
            app.commissionRate,
            app.isActive,
            app.registeredAt
        );
    }

    /**
     * @dev Get referrer earnings across all applications
     */
    function getReferrerEarnings(address _referrer)
        external
        view
        returns (
            uint256 totalEarnings,
            uint256 purchaseCount,
            address[] memory topApps,
            uint256[] memory appEarnings
        )
    {
        totalEarnings = userTotalEarnings[_referrer];

        // Count total purchases
        for (uint256 i = 0; i < allPurchaseEvents.length; i++) {
            if (purchaseEvents[allPurchaseEvents[i]].referrer == _referrer) {
                purchaseCount++;
            }
        }

        // Find top earning apps (simplified - returns first 5)
        uint256 appCount = registeredApplications.length < 5
            ? registeredApplications.length
            : 5;
        topApps = new address[](appCount);
        appEarnings = new uint256[](appCount);

        for (uint256 i = 0; i < appCount; i++) {
            topApps[i] = registeredApplications[i];

            // Calculate earnings from this app
            for (uint256 j = 0; j < allPurchaseEvents.length; j++) {
                PurchaseEvent memory evt = purchaseEvents[allPurchaseEvents[j]];
                if (
                    evt.referrer == _referrer &&
                    evt.application == registeredApplications[i]
                ) {
                    appEarnings[i] += evt.commissionPaid;
                }
            }
        }

        return (totalEarnings, purchaseCount, topApps, appEarnings);
    }

    /**
     * @dev Get global statistics
     */
    function getGlobalStats()
        external
        view
        returns (
            uint256 totalApps, // Changed from 'applications' to 'totalApps'
            uint256 purchases,
            uint256 volume,
            uint256 commissions,
            uint256 referralRewards,
            uint256 avgCommissionRate
        )
    {
        totalApps = totalApplications; // Changed variable name
        purchases = totalPurchaseEvents;
        volume = totalVolumeProcessed;
        commissions = totalCommissionsPaid;
        referralRewards = totalReferralRewards;

        // Calculate average commission rate
        if (totalApplications > 0) {
            uint256 totalRate;
            for (uint256 i = 0; i < registeredApplications.length; i++) {
                totalRate += applications[registeredApplications[i]]
                    .commissionRate;
            }
            avgCommissionRate = totalRate / totalApplications;
        }

        return (
            totalApps,
            purchases,
            volume,
            commissions,
            referralRewards,
            avgCommissionRate
        );
    }

    /**
     * @dev Update referral payout contract
     */
    function updateReferralPayoutContract(address _newContract)
        external
        onlyRole(ADMIN_ROLE)
    {
        address oldContract = address(referralPayout);
        referralPayout = IReferralPayoutContract(_newContract);
        emit ReferralPayoutContractUpdated(oldContract, _newContract);
    }

    /**
     * @dev Update default platform wallet
     */
    function updateDefaultPlatformWallet(address _newWallet)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(_newWallet != address(0), "Invalid wallet");
        address oldWallet = defaultPlatformWallet;
        defaultPlatformWallet = _newWallet;
        emit PlatformWalletUpdated(oldWallet, _newWallet);
    }

    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Check if address is a registered application
     */
    function isApplication(address _app) external view returns (bool) {
        return isRegisteredApp[_app] && applications[_app].isActive;
    }

    /**
     * @dev Get all registered applications
     */
    function getAllApplications()
        external
        view
        returns (
            address[] memory apps,
            string[] memory names,
            bool[] memory activeStatus
        )
    {
        uint256 count = registeredApplications.length;
        apps = new address[](count);
        names = new string[](count);
        activeStatus = new bool[](count);

        for (uint256 i = 0; i < count; i++) {
            address app = registeredApplications[i];
            apps[i] = app;
            names[i] = applications[app].name;
            activeStatus[i] = applications[app].isActive;
        }

        return (apps, names, activeStatus);
    }
}
