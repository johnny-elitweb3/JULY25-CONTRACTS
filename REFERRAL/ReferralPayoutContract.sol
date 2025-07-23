// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title IDecentralizedChannelRegistry
 * @dev Interface for the Decentralized Channel Registry contract
 */
interface IDecentralizedChannelRegistry {
    function getUsernameAndReferralStatus(address _user) external view returns (
        string memory username,
        bool isRegistered,
        address referredBy,
        uint256 userReferralCount
    );
    
    function getRegisteredUsers(uint256 _offset, uint256 _limit) external view returns (
        address[] memory users,
        string[] memory usernames,
        uint256 total
    );
    
    function isValidUsernameFormat(string memory _username) external view returns (bool);
}

/**
 * @title ReferralPayoutContract
 * @dev Advanced referral payout system for the Decentralized Channel ecosystem
 * @notice This contract manages XDM token bounties for successful referrals with tier-based rewards
 */
contract ReferralPayoutContract is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // XDM token contract
    IERC20 public immutable xdmToken;
    
    // Registry contract
    IDecentralizedChannelRegistry public immutable registry;
    
    // Payout configuration
    uint256 public baseBounty = 50 * 10**18; // 50 XDM base referrer bounty
    uint256 public newUserBonus = 10 * 10**18; // 10 XDM for new user
    uint256 public minimumBalance = 1000 * 10**18; // Minimum contract balance for payouts
    
    // Tier system for referrers
    struct Tier {
        uint256 minReferrals;
        uint256 bonusMultiplier; // 100 = 1x, 150 = 1.5x, etc.
        string tierName;
    }
    
    Tier[] public tiers;
    
    // Referral tracking structures
    struct ReferralRecord {
        address referrer;
        address newUser;
        string referrerUsername;
        string newUserUsername;
        uint256 referrerPayout;
        uint256 newUserBonus;
        uint256 timestamp;
        bool isPaid;
        uint256 tierAtTime;
    }
    
    struct ReferrerStats {
        uint256 totalEarned;
        uint256 totalReferrals;
        uint256 currentTier;
        uint256 lastReferralTime;
        uint256 streak; // Days with at least one referral
        uint256 lastStreakUpdate;
    }
    
    // Mappings
    mapping(address => ReferralRecord[]) public referralsByReferrer;
    mapping(address => ReferralRecord) public referralRecordByNewUser;
    mapping(address => ReferrerStats) public referrerStats;
    mapping(address => mapping(uint256 => uint256)) public referralsByMonth; // referrer => month => count
    
    // Blacklist for abuse prevention
    mapping(address => bool) public blacklisted;
    
    // Array of all referrals for enumeration
    ReferralRecord[] public allReferrals;
    address[] public activeReferrers;
    mapping(address => bool) public isActiveReferrer;
    
    // Statistics
    uint256 public totalReferrals;
    uint256 public totalPayouts;
    uint256 public totalReferrerPayouts;
    uint256 public totalNewUserBonuses;
    uint256 public highestSinglePayout;
    address public topReferrer;
    
    // Campaign management
    bool public campaignActive = true;
    uint256 public campaignStartTime;
    uint256 public campaignEndTime;
    uint256 public maxReferralsPerUser = 1000;
    uint256 public dailyReferralLimit = 10; // Per referrer
    
    // Bonus campaigns
    uint256 public weekendBonus = 20; // 20% extra on weekends
    bool public weekendBonusActive = true;
    uint256 public streakBonus = 10; // 10% extra per week of streak (max 50%)
    uint256 public maxStreakBonus = 50;
    
    // Events
    event ReferralProcessed(
        address indexed referrer,
        address indexed newUser,
        string referrerUsername,
        string newUserUsername,
        uint256 referrerPayout,
        uint256 newUserBonus,
        uint256 tier,
        uint256 timestamp
    );
    
    event TierAchieved(
        address indexed referrer,
        uint256 newTier,
        string tierName,
        uint256 timestamp
    );
    
    event BountyConfigUpdated(
        uint256 oldBaseBounty,
        uint256 newBaseBounty,
        uint256 oldNewUserBonus,
        uint256 newNewUserBonus
    );
    
    event CampaignStatusUpdated(
        bool isActive,
        uint256 startTime,
        uint256 endTime
    );
    
    event ContractFunded(
        address indexed funder,
        uint256 amount,
        uint256 newBalance
    );
    
    event EmergencyWithdrawal(
        address indexed to,
        uint256 amount
    );
    
    event MinimumBalanceUpdated(
        uint256 oldMinimum,
        uint256 newMinimum
    );
    
    event UserBlacklisted(
        address indexed user,
        uint256 timestamp
    );
    
    event UserWhitelisted(
        address indexed user,
        uint256 timestamp
    );
    
    event TierAdded(
        uint256 minReferrals,
        uint256 bonusMultiplier,
        string tierName
    );
    
    event BonusParametersUpdated(
        uint256 weekendBonus,
        bool weekendBonusActive,
        uint256 streakBonus,
        uint256 maxStreakBonus
    );
    
    modifier onlyRegistry() {
        require(msg.sender == address(registry), "Only registry contract");
        _;
    }
    
    modifier campaignIsActive() {
        require(campaignActive, "Campaign not active");
        require(
            block.timestamp >= campaignStartTime && 
            (campaignEndTime == 0 || block.timestamp <= campaignEndTime),
            "Campaign not in active period"
        );
        _;
    }
    
    modifier notBlacklisted(address _user) {
        require(!blacklisted[_user], "User is blacklisted");
        _;
    }
    
    /**
     * @dev Constructor
     * @param _xdmToken Address of the XDM token contract
     * @param _registry Address of the DecentralizedChannelRegistry contract
     * @param _initialOwner Address of the contract owner
     */
    constructor(
        address _xdmToken,
        address _registry,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_xdmToken != address(0), "Invalid token address");
        require(_registry != address(0), "Invalid registry address");
        
        xdmToken = IERC20(_xdmToken);
        registry = IDecentralizedChannelRegistry(_registry);
        campaignStartTime = block.timestamp;
        
        // Initialize default tiers
        _initializeDefaultTiers();
    }
    
    /**
     * @dev Initialize default tier system
     */
    function _initializeDefaultTiers() private {
        tiers.push(Tier(0, 100, "Bronze"));      // 0+ referrals: 1x multiplier
        tiers.push(Tier(5, 120, "Silver"));      // 5+ referrals: 1.2x multiplier
        tiers.push(Tier(20, 150, "Gold"));       // 20+ referrals: 1.5x multiplier
        tiers.push(Tier(50, 200, "Platinum"));   // 50+ referrals: 2x multiplier
        tiers.push(Tier(100, 300, "Diamond"));   // 100+ referrals: 3x multiplier
    }
    
    /**
     * @dev Process a referral from the registry contract
     * @param _newUser Address of the newly registered user
     * @param _referrer Address of the referrer
     */
    function processReferral(
        address _newUser,
        address _referrer
    ) external onlyRegistry nonReentrant campaignIsActive notBlacklisted(_referrer) notBlacklisted(_newUser) {
        require(_newUser != address(0) && _referrer != address(0), "Invalid address");
        require(_newUser != _referrer, "Cannot refer yourself");
        
        // Check daily limit
        uint256 today = block.timestamp / 1 days;
        require(referralsByMonth[_referrer][today] < dailyReferralLimit, "Daily limit reached");
        
        // Check referral limits
        require(referrerStats[_referrer].totalReferrals < maxReferralsPerUser, "Referral limit reached");
        
        // Check if already processed
        require(!referralRecordByNewUser[_newUser].isPaid, "Already processed");
        
        // Process the referral
        _processReferralInternal(_newUser, _referrer, today);
    }
    
    /**
     * @dev Internal function to process referral (split to avoid stack too deep)
     */
    function _processReferralInternal(
        address _newUser,
        address _referrer,
        uint256 _today
    ) private {
        // Calculate payout
        uint256 referrerPayout = _calculateReferrerPayout(_referrer);
        uint256 totalPayout = referrerPayout + newUserBonus;
        
        // Check balance
        require(
            xdmToken.balanceOf(address(this)) >= totalPayout + minimumBalance,
            "Insufficient balance"
        );
        
        // Verify registration status and get usernames
        (string memory referrerUsername, string memory newUserUsername) = _verifyAndGetUsernames(_referrer, _newUser);
        
        // Update stats and create record
        uint256 currentTier = _updateReferrerData(_referrer, referrerPayout);
        
        // Store the referral
        _storeReferralRecord(
            _referrer,
            _newUser,
            referrerUsername,
            newUserUsername,
            referrerPayout,
            currentTier
        );
        
        // Update tracking
        referralsByMonth[_referrer][_today]++;
        referralsByMonth[_referrer][block.timestamp / 30 days]++;
        
        // Update global stats
        _updateGlobalStats(referrerPayout, totalPayout);
        
        // Process payouts
        xdmToken.safeTransfer(_referrer, referrerPayout);
        xdmToken.safeTransfer(_newUser, newUserBonus);
        
        emit ReferralProcessed(
            _referrer,
            _newUser,
            referrerUsername,
            newUserUsername,
            referrerPayout,
            newUserBonus,
            currentTier,
            block.timestamp
        );
    }
    
    /**
     * @dev Verify users are registered and get their usernames
     */
    function _verifyAndGetUsernames(
        address _referrer,
        address _newUser
    ) private view returns (string memory, string memory) {
        (string memory referrerUsername, bool referrerRegistered,,) = 
            registry.getUsernameAndReferralStatus(_referrer);
        require(referrerRegistered, "Referrer not registered");
        
        (string memory newUserUsername, bool newUserRegistered,,) = 
            registry.getUsernameAndReferralStatus(_newUser);
        require(newUserRegistered, "New user not registered");
        
        return (referrerUsername, newUserUsername);
    }
    
    /**
     * @dev Update referrer data and return current tier
     */
    function _updateReferrerData(
        address _referrer,
        uint256 _payout
    ) private returns (uint256) {
        ReferrerStats storage stats = referrerStats[_referrer];
        stats.totalReferrals++;
        stats.totalEarned += _payout;
        
        // Update streak
        _updateStreak(_referrer);
        
        // Update tier
        uint256 currentTier = _updateTier(_referrer);
        
        // Track as active referrer
        if (!isActiveReferrer[_referrer]) {
            isActiveReferrer[_referrer] = true;
            activeReferrers.push(_referrer);
        }
        
        // Update top referrer if necessary
        if (stats.totalEarned > referrerStats[topReferrer].totalEarned) {
            topReferrer = _referrer;
        }
        
        return currentTier;
    }
    
    /**
     * @dev Store referral record
     */
    function _storeReferralRecord(
        address _referrer,
        address _newUser,
        string memory _referrerUsername,
        string memory _newUserUsername,
        uint256 _referrerPayout,
        uint256 _tier
    ) private {
        ReferralRecord memory record = ReferralRecord({
            referrer: _referrer,
            newUser: _newUser,
            referrerUsername: _referrerUsername,
            newUserUsername: _newUserUsername,
            referrerPayout: _referrerPayout,
            newUserBonus: newUserBonus,
            timestamp: block.timestamp,
            isPaid: true,
            tierAtTime: _tier
        });
        
        referralsByReferrer[_referrer].push(record);
        referralRecordByNewUser[_newUser] = record;
        allReferrals.push(record);
    }
    
    /**
     * @dev Update global statistics
     */
    function _updateGlobalStats(uint256 _referrerPayout, uint256 _totalPayout) private {
        totalReferrals++;
        totalPayouts += _totalPayout;
        totalReferrerPayouts += _referrerPayout;
        totalNewUserBonuses += newUserBonus;
        
        if (_referrerPayout > highestSinglePayout) {
            highestSinglePayout = _referrerPayout;
        }
        
        // Note: topReferrer is updated in _updateReferrerData based on total earnings
    }
    
    /**
     * @dev Calculate referrer payout with bonuses
     * @param _referrer Address of the referrer
     */
    function _calculateReferrerPayout(address _referrer) private view returns (uint256) {
        uint256 payout = baseBounty;
        
        // Apply tier multiplier
        uint256 tier = _getCurrentTier(_referrer);
        if (tier < tiers.length) {
            payout = (payout * tiers[tier].bonusMultiplier) / 100;
        }
        
        // Apply weekend bonus
        if (weekendBonusActive && _isWeekend()) {
            payout = (payout * (100 + weekendBonus)) / 100;
        }
        
        // Apply streak bonus
        uint256 streakWeeks = referrerStats[_referrer].streak / 7;
        uint256 streakBonusAmount = streakWeeks * streakBonus;
        if (streakBonusAmount > maxStreakBonus) {
            streakBonusAmount = maxStreakBonus;
        }
        if (streakBonusAmount > 0) {
            payout = (payout * (100 + streakBonusAmount)) / 100;
        }
        
        return payout;
    }
    
    /**
     * @dev Check if current time is weekend
     */
    function _isWeekend() private view returns (bool) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7;
        return dayOfWeek == 0 || dayOfWeek == 6; // Sunday or Saturday
    }
    
    /**
     * @dev Update referrer streak
     * @param _referrer Address of the referrer
     */
    function _updateStreak(address _referrer) private {
        ReferrerStats storage stats = referrerStats[_referrer];
        uint256 today = block.timestamp / 1 days;
        
        if (stats.lastStreakUpdate == 0) {
            stats.streak = 1;
            stats.lastStreakUpdate = today;
        } else if (today == stats.lastStreakUpdate + 1) {
            stats.streak++;
            stats.lastStreakUpdate = today;
        } else if (today > stats.lastStreakUpdate + 1) {
            stats.streak = 1;
            stats.lastStreakUpdate = today;
        }
        
        stats.lastReferralTime = block.timestamp;
    }
    
    /**
     * @dev Get current tier for a referrer
     * @param _referrer Address of the referrer
     */
    function _getCurrentTier(address _referrer) private view returns (uint256) {
        uint256 referralCount = referrerStats[_referrer].totalReferrals;
        
        for (uint256 i = tiers.length; i > 0; i--) {
            if (referralCount >= tiers[i - 1].minReferrals) {
                return i - 1;
            }
        }
        
        return 0;
    }
    
    /**
     * @dev Update tier for a referrer
     * @param _referrer Address of the referrer
     */
    function _updateTier(address _referrer) private returns (uint256) {
        uint256 newTier = _getCurrentTier(_referrer);
        ReferrerStats storage stats = referrerStats[_referrer];
        
        if (newTier > stats.currentTier) {
            stats.currentTier = newTier;
            emit TierAchieved(_referrer, newTier, tiers[newTier].tierName, block.timestamp);
        }
        
        return newTier;
    }
    
    /**
     * @dev Fund the contract with XDM tokens
     * @param _amount Amount of XDM tokens to deposit
     */
    function fundContract(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        
        xdmToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        emit ContractFunded(msg.sender, _amount, xdmToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Get referral history for a referrer
     * @param _referrer Address of the referrer
     * @param _offset Starting index
     * @param _limit Number of records to return
     */
    function getReferralHistory(
        address _referrer,
        uint256 _offset,
        uint256 _limit
    ) external view returns (
        ReferralRecord[] memory records,
        uint256 totalCount
    ) {
        require(_limit > 0 && _limit <= 100, "Invalid limit");
        
        ReferralRecord[] storage userReferrals = referralsByReferrer[_referrer];
        totalCount = userReferrals.length;
        
        if (_offset >= totalCount) {
            return (new ReferralRecord[](0), totalCount);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalCount) {
            end = totalCount;
        }
        
        uint256 length = end - _offset;
        records = new ReferralRecord[](length);
        
        for (uint256 i = 0; i < length; i++) {
            records[i] = userReferrals[_offset + i];
        }
        
        return (records, totalCount);
    }
    
    /**
     * @dev Get all referrals (paginated)
     * @param _offset Starting index
     * @param _limit Number of records to return
     */
    function getAllReferrals(
        uint256 _offset,
        uint256 _limit
    ) external view returns (
        ReferralRecord[] memory records,
        uint256 totalCount
    ) {
        require(_limit > 0 && _limit <= 100, "Invalid limit");
        
        totalCount = allReferrals.length;
        
        if (_offset >= totalCount) {
            return (new ReferralRecord[](0), totalCount);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalCount) {
            end = totalCount;
        }
        
        uint256 length = end - _offset;
        records = new ReferralRecord[](length);
        
        for (uint256 i = 0; i < length; i++) {
            records[i] = allReferrals[_offset + i];
        }
        
        return (records, totalCount);
    }
    
    /**
     * @dev Get top referrers by earnings
     * @param _limit Number of top referrers to return
     */
    function getTopReferrers(uint256 _limit) external view returns (
        address[] memory referrers,
        string[] memory usernames,
        uint256[] memory earnings,
        uint256[] memory referralCounts,
        uint256[] memory currentTiers
    ) {
        require(_limit > 0 && _limit <= 50, "Invalid limit");
        
        uint256 activeCount = activeReferrers.length;
        uint256 returnCount = activeCount < _limit ? activeCount : _limit;
        
        // Create temporary arrays for sorting
        address[] memory tempReferrers = new address[](activeCount);
        uint256[] memory tempEarnings = new uint256[](activeCount);
        
        // Copy active referrers
        for (uint256 i = 0; i < activeCount; i++) {
            tempReferrers[i] = activeReferrers[i];
            tempEarnings[i] = referrerStats[activeReferrers[i]].totalEarned;
        }
        
        // Sort by earnings (insertion sort for gas efficiency with small arrays)
        for (uint256 i = 1; i < activeCount; i++) {
            address keyAddress = tempReferrers[i];
            uint256 keyEarnings = tempEarnings[i];
            uint256 j = i;
            
            while (j > 0 && tempEarnings[j - 1] < keyEarnings) {
                tempReferrers[j] = tempReferrers[j - 1];
                tempEarnings[j] = tempEarnings[j - 1];
                j--;
            }
            
            tempReferrers[j] = keyAddress;
            tempEarnings[j] = keyEarnings;
        }
        
        // Prepare return arrays
        referrers = new address[](returnCount);
        usernames = new string[](returnCount);
        earnings = new uint256[](returnCount);
        referralCounts = new uint256[](returnCount);
        currentTiers = new uint256[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            address referrer = tempReferrers[i];
            referrers[i] = referrer;
            earnings[i] = tempEarnings[i];
            
            ReferrerStats memory stats = referrerStats[referrer];
            referralCounts[i] = stats.totalReferrals;
            currentTiers[i] = stats.currentTier;
            
            // Get username from registry
            (string memory username,,,) = registry.getUsernameAndReferralStatus(referrer);
            usernames[i] = username;
        }
        
        return (referrers, usernames, earnings, referralCounts, currentTiers);
    }
    
    /**
     * @dev Get detailed referrer statistics
     * @param _referrer Address to query
     */
    function getReferrerStats(address _referrer) external view returns (
        uint256 totalEarned,
        uint256 referralCount,
        uint256 currentTier,
        string memory tierName,
        uint256 currentStreak,
        uint256 lastReferralTime,
        uint256 nextTierReferrals,
        uint256 estimatedNextPayout
    ) {
        ReferrerStats memory stats = referrerStats[_referrer];
        
        totalEarned = stats.totalEarned;
        referralCount = stats.totalReferrals;
        currentTier = stats.currentTier;
        currentStreak = stats.streak;
        lastReferralTime = stats.lastReferralTime;
        
        if (currentTier < tiers.length) {
            tierName = tiers[currentTier].tierName;
        }
        
        // Calculate referrals needed for next tier
        if (currentTier < tiers.length - 1) {
            nextTierReferrals = tiers[currentTier + 1].minReferrals - referralCount;
        }
        
        // Calculate estimated next payout
        estimatedNextPayout = _calculateReferrerPayout(_referrer);
        
        return (
            totalEarned,
            referralCount,
            currentTier,
            tierName,
            currentStreak,
            lastReferralTime,
            nextTierReferrals,
            estimatedNextPayout
        );
    }
    
    /**
     * @dev Get monthly referral statistics
     * @param _referrer Address of the referrer
     * @param _monthsBack Number of months to look back
     */
    function getMonthlyStats(
        address _referrer,
        uint256 _monthsBack
    ) external view returns (
        uint256[] memory months,
        uint256[] memory referralCounts
    ) {
        require(_monthsBack > 0 && _monthsBack <= 12, "Invalid months range");
        
        months = new uint256[](_monthsBack);
        referralCounts = new uint256[](_monthsBack);
        
        uint256 currentMonth = block.timestamp / 30 days;
        
        for (uint256 i = 0; i < _monthsBack; i++) {
            uint256 month = currentMonth - i;
            months[i] = month;
            referralCounts[i] = referralsByMonth[_referrer][month];
        }
        
        return (months, referralCounts);
    }
    
    /**
     * @dev Add a new tier (owner only)
     * @param _minReferrals Minimum referrals for this tier
     * @param _bonusMultiplier Bonus multiplier (100 = 1x)
     * @param _tierName Name of the tier
     */
    function addTier(
        uint256 _minReferrals,
        uint256 _bonusMultiplier,
        string memory _tierName
    ) external onlyOwner {
        require(_bonusMultiplier >= 100, "Multiplier must be >= 100");
        require(bytes(_tierName).length > 0, "Tier name required");
        
        // Ensure tiers are in ascending order
        if (tiers.length > 0) {
            require(
                _minReferrals > tiers[tiers.length - 1].minReferrals,
                "Must be higher than last tier"
            );
        }
        
        tiers.push(Tier(_minReferrals, _bonusMultiplier, _tierName));
        
        emit TierAdded(_minReferrals, _bonusMultiplier, _tierName);
    }
    
    /**
     * @dev Blacklist a user (owner only)
     * @param _user Address to blacklist
     */
    function blacklistUser(address _user) external onlyOwner {
        require(!blacklisted[_user], "Already blacklisted");
        blacklisted[_user] = true;
        emit UserBlacklisted(_user, block.timestamp);
    }
    
    /**
     * @dev Remove user from blacklist (owner only)
     * @param _user Address to whitelist
     */
    function whitelistUser(address _user) external onlyOwner {
        require(blacklisted[_user], "Not blacklisted");
        blacklisted[_user] = false;
        emit UserWhitelisted(_user, block.timestamp);
    }
    
    /**
     * @dev Update bounty configuration (owner only)
     * @param _baseBounty New base bounty for referrers
     * @param _newUserBonus New bonus for new users
     */
    function updateBountyConfig(
        uint256 _baseBounty,
        uint256 _newUserBonus
    ) external onlyOwner {
        require(_baseBounty > 0, "Base bounty must be greater than 0");
        require(_newUserBonus > 0, "New user bonus must be greater than 0");
        
        emit BountyConfigUpdated(
            baseBounty,
            _baseBounty,
            newUserBonus,
            _newUserBonus
        );
        
        baseBounty = _baseBounty;
        newUserBonus = _newUserBonus;
    }
    
    /**
     * @dev Update bonus parameters (owner only)
     * @param _weekendBonus Weekend bonus percentage
     * @param _weekendBonusActive Whether weekend bonus is active
     * @param _streakBonus Streak bonus percentage per week
     * @param _maxStreakBonus Maximum streak bonus percentage
     */
    function updateBonusParameters(
        uint256 _weekendBonus,
        bool _weekendBonusActive,
        uint256 _streakBonus,
        uint256 _maxStreakBonus
    ) external onlyOwner {
        weekendBonus = _weekendBonus;
        weekendBonusActive = _weekendBonusActive;
        streakBonus = _streakBonus;
        maxStreakBonus = _maxStreakBonus;
        
        emit BonusParametersUpdated(
            _weekendBonus,
            _weekendBonusActive,
            _streakBonus,
            _maxStreakBonus
        );
    }
    
    /**
     * @dev Update campaign status (owner only)
     * @param _active Whether campaign is active
     * @param _endTime Campaign end time (0 for no end)
     */
    function updateCampaignStatus(
        bool _active,
        uint256 _endTime
    ) external onlyOwner {
        campaignActive = _active;
        campaignEndTime = _endTime;
        
        emit CampaignStatusUpdated(_active, campaignStartTime, _endTime);
    }
    
    /**
     * @dev Update limits (owner only)
     * @param _maxReferralsPerUser Maximum total referrals per user
     * @param _dailyReferralLimit Maximum referrals per day per user
     */
    function updateLimits(
        uint256 _maxReferralsPerUser,
        uint256 _dailyReferralLimit
    ) external onlyOwner {
        require(_maxReferralsPerUser > 0, "Must be greater than 0");
        require(_dailyReferralLimit > 0, "Must be greater than 0");
        
        maxReferralsPerUser = _maxReferralsPerUser;
        dailyReferralLimit = _dailyReferralLimit;
    }
    
    /**
     * @dev Update minimum balance requirement (owner only)
     * @param _minimumBalance New minimum balance
     */
    function updateMinimumBalance(uint256 _minimumBalance) external onlyOwner {
        uint256 oldMinimum = minimumBalance;
        minimumBalance = _minimumBalance;
        emit MinimumBalanceUpdated(oldMinimum, _minimumBalance);
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
    function getContractStats() external view returns (
        uint256 totalRefs,
        uint256 totalPaid,
        uint256 totalRefPaid,
        uint256 totalBonusPaid,
        uint256 contractBalance,
        uint256 activeReferrerCount,
        address topRef,
        uint256 highestPayout,
        bool isActive,
        uint256 endTime
    ) {
        return (
            totalReferrals,
            totalPayouts,
            totalReferrerPayouts,
            totalNewUserBonuses,
            xdmToken.balanceOf(address(this)),
            activeReferrers.length,
            topReferrer,
            highestSinglePayout,
            campaignActive,
            campaignEndTime
        );
    }
    
    /**
     * @dev Emergency withdrawal (owner only, when paused)
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 _amount) external onlyOwner whenPaused {
        require(_amount <= xdmToken.balanceOf(address(this)), "Insufficient balance");
        
        xdmToken.safeTransfer(owner(), _amount);
        
        emit EmergencyWithdrawal(owner(), _amount);
    }
    
    /**
     * @dev Check if contract has sufficient balance for payouts
     */
    function hasSufficientBalance() external view returns (bool) {
        uint256 maxPossiblePayout = (baseBounty * tiers[tiers.length - 1].bonusMultiplier / 100) * 2; // Max with all bonuses
        uint256 requiredBalance = maxPossiblePayout + newUserBonus + minimumBalance;
        return xdmToken.balanceOf(address(this)) >= requiredBalance;
    }
    
    /**
     * @dev Get tier information
     * @param _tierIndex Index of the tier
     */
    function getTierInfo(uint256 _tierIndex) external view returns (
        uint256 minReferrals,
        uint256 bonusMultiplier,
        string memory tierName
    ) {
        require(_tierIndex < tiers.length, "Invalid tier index");
        Tier memory tier = tiers[_tierIndex];
        return (tier.minReferrals, tier.bonusMultiplier, tier.tierName);
    }
    
    /**
     * @dev Get all tiers
     */
    function getAllTiers() external view returns (Tier[] memory) {
        return tiers;
    }
    
    /**
     * @dev Calculate potential payout for a referrer
     * @param _referrer Address of the referrer
     */
    function calculatePotentialPayout(address _referrer) external view returns (uint256) {
        return _calculateReferrerPayout(_referrer);
    }
}
