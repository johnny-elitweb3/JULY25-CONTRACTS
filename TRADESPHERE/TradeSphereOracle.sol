// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title TradeSphereOracle
 * @notice A decentralized oracle management system for requesting and managing price feeds
 * @dev Implements role-based access control, pausability, and reentrancy protection
 */
contract TradeSphereOracle is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    // ============ Constants ============
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    uint256 public constant MIN_FREQUENCY = 5 minutes;
    uint256 public constant MAX_FREQUENCY = 1440 minutes; // 24 hours
    uint256 public constant GRACE_PERIOD = 7 days;
    uint256 public constant MAX_ASSET_NAME_LENGTH = 50;
    uint256 public constant MAX_CHAIN_NAME_LENGTH = 30;

    // ============ State Variables ============
    IERC20 public immutable cifiToken;
    Counters.Counter private _feedIdCounter;
    
    // Pricing tiers (frequency in minutes => price in CIFI)
    mapping(uint256 => uint256) public pricingTiers;
    
    // Feed management
    mapping(uint256 => Feed) public feeds;
    mapping(address => uint256[]) public userFeeds;
    mapping(string => mapping(string => uint256[])) public assetChainFeeds;
    
    // Revenue and metrics
    uint256 public totalRevenue;
    uint256 public totalRefunds;
    mapping(FeedStatus => uint256) public feedStatusCount;
    
    // Configuration
    uint256 public refundPercentage = 90; // 90% refund on rejection
    bool public dynamicPricingEnabled;
    
    // ============ Enums ============
    enum FeedStatus {
        Requested,
        UnderReview,
        Approved,
        Live,
        Paused,
        Expired,
        Rejected,
        Archived
    }
    
    enum RefundReason {
        Rejected,
        Cancelled,
        TechnicalIssue
    }

    // ============ Structs ============
    struct Feed {
        uint256 id;
        address requester;
        string assetName;
        string targetChain;
        uint32 frequencyMinutes;
        uint32 lastUpdateTime;
        uint128 pricePaid;
        FeedStatus status;
        uint64 createdAt;
        uint64 expiresAt;
        string rejectionReason;
        address dataProvider;
    }
    
    struct FeedRequest {
        string assetName;
        string targetChain;
        uint256 frequencyMinutes;
    }

    // ============ Events ============
    event FeedRequested(
        uint256 indexed feedId,
        address indexed requester,
        string assetName,
        string targetChain,
        uint256 frequencyMinutes,
        uint256 pricePaid
    );
    
    event FeedStatusUpdated(
        uint256 indexed feedId,
        FeedStatus previousStatus,
        FeedStatus newStatus,
        string reason
    );
    
    event FeedRefunded(
        uint256 indexed feedId,
        address indexed requester,
        uint256 amount,
        RefundReason reason
    );
    
    event PricingTierUpdated(uint256 frequencyMinutes, uint256 price);
    event FeedRenewed(uint256 indexed feedId, uint64 newExpiryDate, uint256 pricePaid);
    event DataProviderAssigned(uint256 indexed feedId, address indexed provider);
    
    // ============ Errors ============
    error InvalidAddress();
    error InvalidFrequency();
    error InvalidFeedId();
    error InvalidStatusTransition();
    error InsufficientPayment();
    error FeedExpired();
    error Unauthorized();
    error InvalidInput();
    error TransferFailed();

    // ============ Constructor ============
    constructor(address _cifiToken, address _admin) {
        if (_cifiToken == address(0) || _admin == address(0)) revert InvalidAddress();
        
        cifiToken = IERC20(_cifiToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        
        // Initialize default pricing tiers
        _initializeDefaultPricing();
    }

    // ============ External Functions ============

    /**
     * @notice Submit a new feed request
     * @param request The feed request details
     * @return feedId The ID of the newly created feed
     */
    function requestFeed(FeedRequest calldata request) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 feedId) 
    {
        _validateFeedRequest(request);
        
        uint256 price = calculatePrice(request.frequencyMinutes);
        
        // Transfer payment
        cifiToken.safeTransferFrom(msg.sender, address(this), price);
        
        // Create feed
        _feedIdCounter.increment();
        feedId = _feedIdCounter.current();
        
        feeds[feedId] = Feed({
            id: feedId,
            requester: msg.sender,
            assetName: request.assetName,
            targetChain: request.targetChain,
            frequencyMinutes: uint32(request.frequencyMinutes),
            lastUpdateTime: 0,
            pricePaid: uint128(price),
            status: FeedStatus.Requested,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 365 days),
            rejectionReason: "",
            dataProvider: address(0)
        });
        
        // Update mappings
        userFeeds[msg.sender].push(feedId);
        assetChainFeeds[request.assetName][request.targetChain].push(feedId);
        feedStatusCount[FeedStatus.Requested]++;
        totalRevenue += price;
        
        emit FeedRequested(
            feedId,
            msg.sender,
            request.assetName,
            request.targetChain,
            request.frequencyMinutes,
            price
        );
    }

    /**
     * @notice Submit multiple feed requests in a single transaction
     * @param requests Array of feed requests
     * @return feedIds Array of created feed IDs
     */
    function requestFeedsBatch(FeedRequest[] calldata requests)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory feedIds)
    {
        uint256 length = requests.length;
        if (length == 0 || length > 10) revert InvalidInput();
        
        feedIds = new uint256[](length);
        uint256 totalPrice;
        
        // Calculate total price
        for (uint256 i = 0; i < length; i++) {
            totalPrice += calculatePrice(requests[i].frequencyMinutes);
        }
        
        // Transfer total payment
        cifiToken.safeTransferFrom(msg.sender, address(this), totalPrice);
        
        // Create feeds
        for (uint256 i = 0; i < length; i++) {
            feedIds[i] = _createFeed(requests[i], calculatePrice(requests[i].frequencyMinutes));
        }
    }

    /**
     * @notice Update feed status with enhanced validation
     * @param feedId The feed ID to update
     * @param newStatus The new status
     * @param reason Optional reason for status change
     */
    function updateFeedStatus(
        uint256 feedId,
        FeedStatus newStatus,
        string calldata reason
    ) external onlyRole(OPERATOR_ROLE) {
        Feed storage feed = _getFeed(feedId);
        FeedStatus previousStatus = feed.status;
        
        if (!_isValidStatusTransition(previousStatus, newStatus)) {
            revert InvalidStatusTransition();
        }
        
        // Update status counts
        feedStatusCount[previousStatus]--;
        feedStatusCount[newStatus]++;
        
        feed.status = newStatus;
        
        // Handle rejection
        if (newStatus == FeedStatus.Rejected) {
            feed.rejectionReason = reason;
            _processRefund(feedId, RefundReason.Rejected);
        }
        
        emit FeedStatusUpdated(feedId, previousStatus, newStatus, reason);
    }

    /**
     * @notice Renew an existing feed
     * @param feedId The feed ID to renew
     */
    function renewFeed(uint256 feedId) external nonReentrant whenNotPaused {
        Feed storage feed = _getFeed(feedId);
        
        if (feed.requester != msg.sender) revert Unauthorized();
        if (feed.status != FeedStatus.Live && feed.status != FeedStatus.Expired) {
            revert InvalidStatusTransition();
        }
        
        uint256 price = calculatePrice(feed.frequencyMinutes);
        cifiToken.safeTransferFrom(msg.sender, address(this), price);
        
        feed.expiresAt = uint64(block.timestamp + 365 days);
        if (feed.status == FeedStatus.Expired) {
            feedStatusCount[FeedStatus.Expired]--;
            feedStatusCount[FeedStatus.Live]++;
            feed.status = FeedStatus.Live;
        }
        
        totalRevenue += price;
        
        emit FeedRenewed(feedId, feed.expiresAt, price);
    }

    /**
     * @notice Assign a data provider to a feed
     * @param feedId The feed ID
     * @param provider The data provider address
     */
    function assignDataProvider(uint256 feedId, address provider) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        if (provider == address(0)) revert InvalidAddress();
        Feed storage feed = _getFeed(feedId);
        feed.dataProvider = provider;
        emit DataProviderAssigned(feedId, provider);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update pricing for a specific frequency tier
     * @param frequencyMinutes The frequency in minutes
     * @param price The price in CIFI tokens (with decimals)
     */
    function updatePricingTier(uint256 frequencyMinutes, uint256 price) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (frequencyMinutes < MIN_FREQUENCY || frequencyMinutes > MAX_FREQUENCY) {
            revert InvalidFrequency();
        }
        pricingTiers[frequencyMinutes] = price;
        emit PricingTierUpdated(frequencyMinutes, price);
    }

    /**
     * @notice Withdraw CIFI tokens to treasury
     * @param to The recipient address
     * @param amount The amount to withdraw
     */
    function withdrawToTreasury(address to, uint256 amount) 
        external 
        onlyRole(TREASURY_ROLE) 
        nonReentrant 
    {
        if (to == address(0)) revert InvalidAddress();
        cifiToken.safeTransfer(to, amount);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get detailed feed information
     * @param feedId The feed ID
     * @return feed The feed struct
     */
    function getFeed(uint256 feedId) external view returns (Feed memory) {
        return feeds[feedId];
    }

    /**
     * @notice Get all feeds for a specific user
     * @param user The user address
     * @return Array of feed IDs
     */
    function getUserFeeds(address user) external view returns (uint256[] memory) {
        return userFeeds[user];
    }

    /**
     * @notice Get feeds by asset and chain with pagination
     * @param assetName The asset name
     * @param targetChain The target chain
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return feedIds Array of feed IDs
     */
    function getFeedsByAssetChain(
        string calldata assetName,
        string calldata targetChain,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory feedIds) {
        uint256[] storage allFeeds = assetChainFeeds[assetName][targetChain];
        uint256 totalFeeds = allFeeds.length;
        
        if (offset >= totalFeeds) {
            return new uint256[](0);
        }
        
        uint256 end = offset + limit;
        if (end > totalFeeds) {
            end = totalFeeds;
        }
        
        feedIds = new uint256[](end - offset);
        for (uint256 i = 0; i < feedIds.length; i++) {
            feedIds[i] = allFeeds[offset + i];
        }
    }

    /**
     * @notice Calculate the price for a given frequency
     * @param frequencyMinutes The update frequency in minutes
     * @return The price in CIFI tokens
     */
    function calculatePrice(uint256 frequencyMinutes) public view returns (uint256) {
        uint256 basePrice = pricingTiers[frequencyMinutes];
        if (basePrice > 0) return basePrice;
        
        // Linear interpolation for non-standard frequencies
        uint256 lowerBound;
        uint256 upperBound = type(uint256).max;
        
        // Find bounds
        for (uint256 freq = MIN_FREQUENCY; freq <= MAX_FREQUENCY; freq += 5) {
            if (pricingTiers[freq] > 0) {
                if (freq < frequencyMinutes && freq > lowerBound) {
                    lowerBound = freq;
                } else if (freq > frequencyMinutes && freq < upperBound) {
                    upperBound = freq;
                }
            }
        }
        
        // Calculate interpolated price
        if (lowerBound > 0 && upperBound < type(uint256).max) {
            uint256 priceLower = pricingTiers[lowerBound];
            uint256 priceUpper = pricingTiers[upperBound];
            
            return priceLower + 
                   ((priceUpper - priceLower) * (frequencyMinutes - lowerBound)) / 
                   (upperBound - lowerBound);
        }
        
        // Default price if no bounds found
        return 500 * 10**18;
    }


    function getStatistics() external view returns (
        uint256 totalFeeds,
        uint256 activeFeeds,
        uint256 revenue,
        uint256 refunds,
        uint256 averageFrequency
    ) {
        totalFeeds = _feedIdCounter.current();
        activeFeeds = feedStatusCount[FeedStatus.Live];
        revenue = totalRevenue;
        refunds = totalRefunds;
        
        // Calculate average frequency
        if (totalFeeds > 0) {
            uint256 sumFrequency;
            for (uint256 i = 1; i <= totalFeeds; i++) {
                sumFrequency += feeds[i].frequencyMinutes;
            }
            averageFrequency = sumFrequency / totalFeeds;
        }
    }

    // ============ Internal Functions ============

    function _getFeed(uint256 feedId) internal view returns (Feed storage) {
        if (feedId == 0 || feedId > _feedIdCounter.current()) revert InvalidFeedId();
        return feeds[feedId];
    }

    function _validateFeedRequest(FeedRequest calldata request) internal pure {
        if (bytes(request.assetName).length == 0 || 
            bytes(request.assetName).length > MAX_ASSET_NAME_LENGTH) {
            revert InvalidInput();
        }
        if (bytes(request.targetChain).length == 0 || 
            bytes(request.targetChain).length > MAX_CHAIN_NAME_LENGTH) {
            revert InvalidInput();
        }
        if (request.frequencyMinutes < MIN_FREQUENCY || 
            request.frequencyMinutes > MAX_FREQUENCY) {
            revert InvalidFrequency();
        }
    }

    function _isValidStatusTransition(
        FeedStatus from,
        FeedStatus to
    ) internal pure returns (bool) {
        // Define valid transitions
        if (from == FeedStatus.Requested) {
            return to == FeedStatus.UnderReview || 
                   to == FeedStatus.Rejected || 
                   to == FeedStatus.Approved;
        }
        if (from == FeedStatus.UnderReview) {
            return to == FeedStatus.Approved || 
                   to == FeedStatus.Rejected;
        }
        if (from == FeedStatus.Approved) {
            return to == FeedStatus.Live || 
                   to == FeedStatus.Rejected;
        }
        if (from == FeedStatus.Live) {
            return to == FeedStatus.Paused || 
                   to == FeedStatus.Expired || 
                   to == FeedStatus.Archived;
        }
        if (from == FeedStatus.Paused) {
            return to == FeedStatus.Live || 
                   to == FeedStatus.Archived;
        }
        if (from == FeedStatus.Expired) {
            return to == FeedStatus.Live || // After renewal
                   to == FeedStatus.Archived;
        }
        return false;
    }

    function _processRefund(uint256 feedId, RefundReason reason) internal {
        Feed storage feed = feeds[feedId];
        uint256 refundAmount = (feed.pricePaid * refundPercentage) / 100;
        
        if (refundAmount > 0) {
            totalRefunds += refundAmount;
            cifiToken.safeTransfer(feed.requester, refundAmount);
            emit FeedRefunded(feedId, feed.requester, refundAmount, reason);
        }
    }

    function _createFeed(
        FeedRequest calldata request,
        uint256 price
    ) internal returns (uint256 feedId) {
        _validateFeedRequest(request);
        
        _feedIdCounter.increment();
        feedId = _feedIdCounter.current();
        
        feeds[feedId] = Feed({
            id: feedId,
            requester: msg.sender,
            assetName: request.assetName,
            targetChain: request.targetChain,
            frequencyMinutes: uint32(request.frequencyMinutes),
            lastUpdateTime: 0,
            pricePaid: uint128(price),
            status: FeedStatus.Requested,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 365 days),
            rejectionReason: "",
            dataProvider: address(0)
        });
        
        userFeeds[msg.sender].push(feedId);
        assetChainFeeds[request.assetName][request.targetChain].push(feedId);
        feedStatusCount[FeedStatus.Requested]++;
        totalRevenue += price;
        
        emit FeedRequested(
            feedId,
            msg.sender,
            request.assetName,
            request.targetChain,
            request.frequencyMinutes,
            price
        );
    }

    function _initializeDefaultPricing() internal {
        // High-frequency feeds (more expensive)
        pricingTiers[5] = 2000 * 10**18;    // 5 minutes
        pricingTiers[15] = 1500 * 10**18;   // 15 minutes
        pricingTiers[30] = 1000 * 10**18;   // 30 minutes
        
        // Medium-frequency feeds
        pricingTiers[60] = 750 * 10**18;    // 1 hour
        pricingTiers[120] = 600 * 10**18;   // 2 hours
        pricingTiers[240] = 500 * 10**18;   // 4 hours
        
        // Low-frequency feeds (cheaper)
        pricingTiers[480] = 400 * 10**18;   // 8 hours
        pricingTiers[720] = 350 * 10**18;   // 12 hours
        pricingTiers[1440] = 300 * 10**18;  // 24 hours
    }

    // ============ Maintenance Functions ============

    /**
     * @notice Check and update expired feeds
     * @param feedIds Array of feed IDs to check
     */
    function checkExpiredFeeds(uint256[] calldata feedIds) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            Feed storage feed = feeds[feedIds[i]];
            if (feed.status == FeedStatus.Live && 
                block.timestamp > feed.expiresAt + GRACE_PERIOD) {
                feedStatusCount[FeedStatus.Live]--;
                feedStatusCount[FeedStatus.Expired]++;
                feed.status = FeedStatus.Expired;
                emit FeedStatusUpdated(feedIds[i], FeedStatus.Live, FeedStatus.Expired, "Auto-expired");
            }
        }
    }
}
