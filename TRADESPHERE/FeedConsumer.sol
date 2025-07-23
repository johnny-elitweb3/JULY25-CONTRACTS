// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./TradeSphereOracle.sol";

/**
 * @title FeedConsumer
 * @notice Advanced price feed consumer with multi-oracle support, data validation, and historical tracking
 * @dev Implements comprehensive access control, circuit breakers, and data integrity features
 */
contract FeedConsumer is AccessControl, ReentrancyGuard, Pausable {
    using SafeMath for uint256;

    // ============ Constants ============
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    uint256 public constant MAX_PRICE_DEVIATION = 5000; // 50% in basis points
    uint256 public constant STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant HISTORY_SIZE = 100;
    uint256 public constant EMERGENCY_THRESHOLD = 3; // Consecutive failed updates
    
    // ============ State Variables ============
    TradeSphereOracle public immutable tradeSphereOracle;
    uint256 public immutable feedId;
    
    // Feed metadata
    string public assetName;
    string public sourceChain;
    uint8 public decimals;
    bool public isPublic;
    
    // Treasury management
    address public treasury;
    
    // Price data
    PriceData public latestPrice;
    mapping(uint256 => PriceData) public priceHistory;
    uint256 public historyIndex;
    
    // Oracle management
    mapping(address => OracleInfo) public oracles;
    address[] public activeOracles;
    uint256 public requiredConfirmations;
    mapping(uint256 => PendingPrice) public pendingPrices;
    uint256 public pendingPriceNonce;
    
    // Circuit breaker and monitoring
    uint256 public consecutiveFailures;
    bool public emergencyMode;
    uint256 public lastSuccessfulUpdate;
    
    // Access control
    mapping(address => uint256) public subscriberExpiry;
    uint256 public subscriptionPrice;
    uint256 public subscriptionDuration;
    
    // Statistics
    Statistics public stats;
    
    // ============ Structs ============
    struct PriceData {
        uint256 value;
        uint256 timestamp;
        uint256 confidence; // 0-10000 basis points
        address oracle;
        bytes32 proofHash;
    }
    
    struct OracleInfo {
        bool isActive;
        uint256 reputation; // 0-10000 basis points
        uint256 totalUpdates;
        uint256 failedUpdates;
        uint256 lastUpdate;
        string endpoint;
    }
    
    struct PendingPrice {
        uint256 value;
        uint256 timestamp;
        uint256 confirmations;
        uint256 confidence;
        bytes32 proofHash;
        mapping(address => bool) confirmedBy;
        bool executed;
    }
    
    struct Statistics {
        uint256 totalUpdates;
        uint256 averageGasUsed;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 totalVolume;
    }
    
    struct FeedConfig {
        string assetName;
        string sourceChain;
        uint8 decimals;
        bool isPublic;
        uint256 requiredConfirmations;
        uint256 subscriptionPrice;
        uint256 subscriptionDuration;
    }
    
    // ============ Events ============
    event PriceUpdated(
        uint256 indexed newValue,
        uint256 indexed timestamp,
        address indexed oracle,
        uint256 confidence
    );
    
    event PriceConfirmed(
        uint256 indexed nonce,
        uint256 value,
        uint256 confirmations
    );
    
    event PendingPriceSubmitted(
        uint256 indexed nonce,
        uint256 value,
        uint256 confidence,
        bytes32 proofHash,
        address indexed oracle
    );
    
    event OracleAdded(address indexed oracle, string endpoint);
    event OracleRemoved(address indexed oracle, string reason);
    event OracleReputationUpdated(address indexed oracle, uint256 newReputation);
    
    event EmergencyModeActivated(string reason);
    event EmergencyModeDeactivated();
    
    event SubscriptionPurchased(address indexed subscriber, uint256 expiryTime);
    event ConfigurationUpdated(string parameter, uint256 oldValue, uint256 newValue);
    
    event AnomalyDetected(
        uint256 reportedPrice,
        uint256 expectedRange,
        address oracle
    );
    
    // ============ Errors ============
    error InvalidConfiguration();
    error UnauthorizedAccess();
    error StalePrice();
    error PriceDeviation();
    error InsufficientConfirmations();
    error OracleNotActive();
    error SubscriptionExpired();
    error EmergencyModeActive();
    error InvalidPrice();
    error DuplicateOracle();

    // ============ Constructor ============
    constructor(
        address _tradeSphereOracle,
        uint256 _feedId,
        FeedConfig memory _config,
        address _admin
    ) {
        if (_tradeSphereOracle == address(0) || _admin == address(0)) {
            revert InvalidConfiguration();
        }
        
        tradeSphereOracle = TradeSphereOracle(_tradeSphereOracle);
        feedId = _feedId;
        
        // Validate feed exists and is active
        TradeSphereOracle.Feed memory feed = tradeSphereOracle.getFeed(_feedId);
        if (feed.status != TradeSphereOracle.FeedStatus.Live) {
            revert InvalidConfiguration();
        }
        
        // Initialize feed configuration
        assetName = _config.assetName;
        sourceChain = _config.sourceChain;
        decimals = _config.decimals;
        isPublic = _config.isPublic;
        requiredConfirmations = _config.requiredConfirmations > 0 ? _config.requiredConfirmations : 1;
        subscriptionPrice = _config.subscriptionPrice;
        subscriptionDuration = _config.subscriptionDuration > 0 ? _config.subscriptionDuration : 30 days;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        // Set treasury
        treasury = _admin;
        
        // Initialize statistics
        stats.minPrice = type(uint256).max;
    }

    // ============ Oracle Management ============

    /**
     * @notice Add a new oracle to the feed
     * @param oracle The oracle address
     * @param endpoint The oracle's data endpoint
     */
    function addOracle(address oracle, string calldata endpoint) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        if (oracle == address(0)) revert InvalidConfiguration();
        if (oracles[oracle].isActive) revert DuplicateOracle();
        
        oracles[oracle] = OracleInfo({
            isActive: true,
            reputation: 10000, // Start with perfect reputation
            totalUpdates: 0,
            failedUpdates: 0,
            lastUpdate: 0,
            endpoint: endpoint
        });
        
        activeOracles.push(oracle);
        _grantRole(ORACLE_ROLE, oracle);
        
        emit OracleAdded(oracle, endpoint);
    }

    /**
     * @notice Remove an oracle from the feed
     * @param oracle The oracle address
     * @param reason The removal reason
     */
    function removeOracle(address oracle, string calldata reason) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        if (!oracles[oracle].isActive) revert OracleNotActive();
        
        oracles[oracle].isActive = false;
        _revokeRole(ORACLE_ROLE, oracle);
        
        // Remove from active oracles array
        for (uint256 i = 0; i < activeOracles.length; i++) {
            if (activeOracles[i] == oracle) {
                activeOracles[i] = activeOracles[activeOracles.length - 1];
                activeOracles.pop();
                break;
            }
        }
        
        emit OracleRemoved(oracle, reason);
    }

    // ============ Price Updates ============

    /**
     * @notice Submit a new price update
     * @param value The price value
     * @param confidence The confidence level (0-10000)
     * @param proofHash Optional proof hash for data integrity
     */
    function updatePrice(
        uint256 value,
        uint256 confidence,
        bytes32 proofHash
    ) external whenNotPaused onlyRole(ORACLE_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (!oracles[msg.sender].isActive) revert OracleNotActive();
        if (value == 0) revert InvalidPrice();
        if (confidence > 10000) revert InvalidConfiguration();
        
        // Check for anomalies
        if (latestPrice.value > 0) {
            uint256 deviation = _calculateDeviation(value, latestPrice.value);
            if (deviation > MAX_PRICE_DEVIATION) {
                emit AnomalyDetected(value, MAX_PRICE_DEVIATION, msg.sender);
                
                // Multi-oracle confirmation required for large deviations
                if (requiredConfirmations == 1) {
                    _updateOracleReputation(msg.sender, false);
                    revert PriceDeviation();
                }
                
                _submitPendingPrice(value, confidence, proofHash);
                return;
            }
        }
        
        // Direct update for normal prices or single oracle setup
        if (requiredConfirmations == 1) {
            _executePriceUpdate(value, confidence, proofHash, msg.sender);
        } else {
            _submitPendingPrice(value, confidence, proofHash);
        }
    }

    /**
     * @notice Confirm a pending price update with additional proof
     * @param nonce The pending price nonce
     * @param additionalProof Additional proof hash for verification
     */
    function confirmPriceWithProof(uint256 nonce, bytes32 additionalProof) 
        public 
        whenNotPaused 
        onlyRole(ORACLE_ROLE) 
    {
        PendingPrice storage pending = pendingPrices[nonce];
        if (pending.executed) revert InvalidPrice();
        if (pending.confirmedBy[msg.sender]) revert InvalidPrice();
        if (!oracles[msg.sender].isActive) revert OracleNotActive();
        
        pending.confirmedBy[msg.sender] = true;
        pending.confirmations++;
        
        // Combine proof hashes for enhanced verification
        if (additionalProof != bytes32(0)) {
            pending.proofHash = keccak256(abi.encodePacked(pending.proofHash, additionalProof));
        }
        
        emit PriceConfirmed(nonce, pending.value, pending.confirmations);
        
        if (pending.confirmations >= requiredConfirmations) {
            pending.executed = true;
            // Calculate weighted confidence based on confirmations
            uint256 weightedConfidence = pending.confidence.mul(pending.confirmations).div(activeOracles.length);
            _executePriceUpdate(
                pending.value,
                weightedConfidence > 10000 ? 10000 : weightedConfidence,
                pending.proofHash,
                msg.sender
            );
        }
    }
    
    /**
     * @notice Confirm a pending price update
     * @param nonce The pending price nonce
     */
    function confirmPrice(uint256 nonce) external {
        confirmPriceWithProof(nonce, bytes32(0));
    }

    // ============ Data Access ============

    /**
     * @notice Get the latest price data
     * @return price The latest price data structure
     */
    function getLatestPrice() external view returns (PriceData memory) {
        _checkAccess();
        if (block.timestamp > latestPrice.timestamp + STALENESS_THRESHOLD) {
            revert StalePrice();
        }
        return latestPrice;
    }

    /**
     * @notice Get historical price data
     * @param count Number of historical entries to retrieve
     * @return prices Array of historical prices
     */
    function getPriceHistory(uint256 count) 
        external 
        view 
        returns (PriceData[] memory prices) 
    {
        _checkAccess();
        
        uint256 available = stats.totalUpdates < HISTORY_SIZE ? stats.totalUpdates : HISTORY_SIZE;
        uint256 toReturn = count < available ? count : available;
        
        prices = new PriceData[](toReturn);
        
        uint256 currentIdx = historyIndex;
        for (uint256 i = 0; i < toReturn; i++) {
            uint256 idx = (currentIdx + HISTORY_SIZE - i) % HISTORY_SIZE;
            prices[i] = priceHistory[idx];
        }
    }

    /**
     * @notice Calculate time-weighted average price (TWAP)
     * @param duration The duration in seconds
     * @return twap The time-weighted average price
     */
    function getTWAP(uint256 duration) external view returns (uint256 twap) {
        _checkAccess();
        
        uint256 cutoffTime = block.timestamp - duration;
        uint256 weightedSum;
        uint256 totalWeight;
        
        for (uint256 i = 0; i < HISTORY_SIZE; i++) {
            uint256 idx = (historyIndex + HISTORY_SIZE - i) % HISTORY_SIZE;
            PriceData memory price = priceHistory[idx];
            
            if (price.timestamp == 0 || price.timestamp < cutoffTime) break;
            
            uint256 weight = price.timestamp - cutoffTime;
            weightedSum += price.value.mul(weight);
            totalWeight += weight;
        }
        
        if (totalWeight > 0) {
            twap = weightedSum.div(totalWeight);
        }
    }

    /**
     * @notice Get feed statistics
     * @return feedStats The complete statistics structure
     */
    function getStatistics() external view returns (Statistics memory) {
        _checkAccess();
        return stats;
    }

    // ============ Subscription Management ============

    /**
     * @notice Purchase or extend subscription
     */
    function purchaseSubscription() external payable nonReentrant {
        if (msg.value < subscriptionPrice) revert InsufficientConfirmations();
        
        uint256 currentExpiry = subscriberExpiry[msg.sender];
        uint256 startTime = currentExpiry > block.timestamp ? currentExpiry : block.timestamp;
        
        subscriberExpiry[msg.sender] = startTime + subscriptionDuration;
        
        emit SubscriptionPurchased(msg.sender, subscriberExpiry[msg.sender]);
        
        // Transfer funds to treasury
        if (treasury != address(0)) {
            (bool success, ) = payable(treasury).call{value: msg.value}("");
            require(success, "Transfer failed");
        }
    }

    /**
     * @notice Get pending price details
     * @param nonce The pending price nonce
     * @return value The price value
     * @return confidence The confidence level
     * @return proofHash The proof hash
     * @return confirmations Number of confirmations
     * @return executed Whether the price has been executed
     */
    function getPendingPrice(uint256 nonce) 
        external 
        view 
        returns (
            uint256 value,
            uint256 confidence,
            bytes32 proofHash,
            uint256 confirmations,
            bool executed
        ) 
    {
        PendingPrice storage pending = pendingPrices[nonce];
        return (
            pending.value,
            pending.confidence,
            pending.proofHash,
            pending.confirmations,
            pending.executed
        );
    }
    
    /**
     * @notice Check if an oracle has confirmed a pending price
     * @param nonce The pending price nonce
     * @param oracle The oracle address
     * @return confirmed Whether the oracle has confirmed
     */
    function hasOracleConfirmed(uint256 nonce, address oracle) 
        external 
        view 
        returns (bool) 
    {
        return pendingPrices[nonce].confirmedBy[oracle];
    }
    
    // ============ Admin Functions ============

    /**
     * @notice Update feed configuration
     * @param parameter The parameter to update
     * @param value The new value
     */
    function updateConfiguration(string calldata parameter, uint256 value) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 oldValue;
        
        if (keccak256(bytes(parameter)) == keccak256("requiredConfirmations")) {
            oldValue = requiredConfirmations;
            requiredConfirmations = value;
        } else if (keccak256(bytes(parameter)) == keccak256("subscriptionPrice")) {
            oldValue = subscriptionPrice;
            subscriptionPrice = value;
        } else if (keccak256(bytes(parameter)) == keccak256("subscriptionDuration")) {
            oldValue = subscriptionDuration;
            subscriptionDuration = value;
        } else {
            revert InvalidConfiguration();
        }
        
        emit ConfigurationUpdated(parameter, oldValue, value);
    }

    /**
     * @notice Update treasury address
     * @param _treasury The new treasury address
     */
    function updateTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidConfiguration();
        treasury = _treasury;
    }
    
    /**
     * @notice Toggle public access
     */
    function setPublicAccess(bool _isPublic) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isPublic = _isPublic;
    }

    /**
     * @notice Activate emergency mode
     * @param reason The activation reason
     */
    function activateEmergencyMode(string calldata reason) 
        external 
        onlyRole(OPERATOR_ROLE) 
    {
        emergencyMode = true;
        _pause();
        emit EmergencyModeActivated(reason);
    }

    /**
     * @notice Deactivate emergency mode
     */
    function deactivateEmergencyMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = false;
        consecutiveFailures = 0;
        _unpause();
        emit EmergencyModeDeactivated();
    }

    /**
     * @notice Emergency price update (admin only)
     * @param value The emergency price value
     */
    function emergencyPriceUpdate(uint256 value) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (!emergencyMode) revert UnauthorizedAccess();
        
        _executePriceUpdate(
            value,
            5000, // 50% confidence for emergency updates
            keccak256("EMERGENCY"),
            msg.sender
        );
    }

    // ============ Internal Functions ============

    function _executePriceUpdate(
        uint256 value,
        uint256 confidence,
        bytes32 proofHash,
        address oracle
    ) internal {
        // Update latest price
        latestPrice = PriceData({
            value: value,
            timestamp: block.timestamp,
            confidence: confidence,
            oracle: oracle,
            proofHash: proofHash
        });
        
        // Add to history
        historyIndex = (historyIndex + 1) % HISTORY_SIZE;
        priceHistory[historyIndex] = latestPrice;
        
        // Update statistics
        stats.totalUpdates++;
        if (value < stats.minPrice) stats.minPrice = value;
        if (value > stats.maxPrice) stats.maxPrice = value;
        stats.totalVolume += value;
        
        // Update oracle stats
        oracles[oracle].totalUpdates++;
        oracles[oracle].lastUpdate = block.timestamp;
        _updateOracleReputation(oracle, true);
        
        // Reset failure counter
        consecutiveFailures = 0;
        lastSuccessfulUpdate = block.timestamp;
        
        emit PriceUpdated(value, block.timestamp, oracle, confidence);
    }

    function _submitPendingPrice(
        uint256 value,
        uint256 confidence,
        bytes32 proofHash
    ) internal {
        pendingPriceNonce++;
        
        PendingPrice storage pending = pendingPrices[pendingPriceNonce];
        pending.value = value;
        pending.timestamp = block.timestamp;
        pending.confirmations = 1;
        pending.confidence = confidence;
        pending.proofHash = proofHash;
        pending.confirmedBy[msg.sender] = true;
        
        emit PendingPriceSubmitted(pendingPriceNonce, value, confidence, proofHash, msg.sender);
        emit PriceConfirmed(pendingPriceNonce, value, 1);
    }

    function _updateOracleReputation(address oracle, bool success) internal {
        OracleInfo storage info = oracles[oracle];
        
        if (success) {
            // Increase reputation (max 10000)
            if (info.reputation < 9900) {
                info.reputation += 100;
            } else {
                info.reputation = 10000;
            }
        } else {
            // Decrease reputation
            info.failedUpdates++;
            if (info.reputation > 1000) {
                info.reputation -= 1000;
            } else {
                info.reputation = 0;
            }
            
            // Increment consecutive failures
            consecutiveFailures++;
            if (consecutiveFailures >= EMERGENCY_THRESHOLD && !emergencyMode) {
                emergencyMode = true;
                _pause();
                emit EmergencyModeActivated("Consecutive failures threshold reached");
            }
        }
        
        emit OracleReputationUpdated(oracle, info.reputation);
    }

    function _calculateDeviation(uint256 newValue, uint256 oldValue) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        return diff.mul(10000).div(oldValue);
    }

    function _checkAccess() internal view {
        if (!isPublic) {
            if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                if (subscriberExpiry[msg.sender] < block.timestamp) {
                    revert SubscriptionExpired();
                }
            }
        }
    }

    // ============ Oracle Coordination ============

    /**
     * @notice Get active oracle information
     * @return activeOracleList Array of active oracle addresses
     * @return infos Array of oracle information
     */
    function getActiveOracles() 
        external 
        view 
        returns (address[] memory activeOracleList, OracleInfo[] memory infos) 
    {
        uint256 count = activeOracles.length;
        activeOracleList = new address[](count);
        infos = new OracleInfo[](count);
        
        for (uint256 i = 0; i < count; i++) {
            activeOracleList[i] = activeOracles[i];
            infos[i] = oracles[activeOracles[i]];
        }
        
        return (activeOracleList, infos);
    }

    /**
     * @notice Check if feed needs update
     * @return needsUpdate Whether the feed is stale
     * @return staleness Time since last update
     */
    function checkUpdateNeeded() 
        external 
        view 
        returns (bool needsUpdate, uint256 staleness) 
    {
        staleness = block.timestamp - latestPrice.timestamp;
        
        // Get feed frequency from oracle contract
        TradeSphereOracle.Feed memory feed = tradeSphereOracle.getFeed(feedId);
        uint256 expectedFrequency = uint256(feed.frequencyMinutes) * 60;
        
        needsUpdate = staleness > expectedFrequency;
    }

    /**
     * @notice Sync configuration with TradeSphereOracle
     */
    function syncWithOracle() external onlyRole(OPERATOR_ROLE) {
        TradeSphereOracle.Feed memory feed = tradeSphereOracle.getFeed(feedId);
        
        if (feed.status != TradeSphereOracle.FeedStatus.Live) {
            emergencyMode = true;
            _pause();
            emit EmergencyModeActivated("Feed no longer live in oracle");
        }
        
        // Update metadata if changed
        if (keccak256(bytes(feed.assetName)) != keccak256(bytes(assetName))) {
            assetName = feed.assetName;
        }
        if (keccak256(bytes(feed.targetChain)) != keccak256(bytes(sourceChain))) {
            sourceChain = feed.targetChain;
        }
    }

    // ============ Receive Function ============
    receive() external payable {
        // Accept payments for subscriptions
    }
}
