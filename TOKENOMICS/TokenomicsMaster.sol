// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title TokenomicsMaster
 * @author Advanced DeFi Systems
 * @notice Comprehensive tokenomics tracking and management system with proof of reserve support
 * @dev Enterprise-grade contract for complete token ecosystem oversight including reserve backing verification
 */
contract TokenomicsMaster {
    // ============ Type Declarations ============
    
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    
    // ============ Enums ============
    
    enum WalletType {
        UNCLASSIFIED,
        AI_AGENT,
        TEAM,
        TREASURY,
        MULTI_SIG,
        CEX,
        DEX_LP,
        WHALE,
        INSTITUTIONAL,
        RETAIL,
        PROOF_OF_RESERVE
    }
    
    enum IntegrationType {
        DAPP,
        REWARD_POOL,
        STAKING,
        GAMING,
        DEFI,
        BRIDGE,
        LENDING
    }
    
    enum NFTCategory {
        GOVERNANCE,
        COMMERCIAL,
        COMMODITY,
        UTILITY
    }
    
    enum DataFeedType {
        PRICE,
        VOLUME,
        SUPPLY,
        CUSTOM
    }
    
    // ============ Structs ============
    
    struct DAppIntegration {
        string name;
        address contractAddress;
        IntegrationType integrationType;
        uint256 authorizationDate;
        uint256 totalTokensLocked;
        uint256 activeUsers;
        uint256 transactionVolume;
        bool isActive;
        mapping(bytes32 => bytes) metadata;
    }
    
    struct RewardPool {
        address poolAddress;
        string name;
        uint256 totalDeposited;
        uint256 remainingRewards;
        uint256 distributionRate;
        uint256 participantCount;
        uint256 createdAt;
        uint256 expiresAt;
        bool isActive;
    }
    
    struct WalletInfo {
        WalletType walletType;
        string label;
        uint256 classifiedAt;
        uint256 lastActivity;
        uint256 totalTransactions;
        mapping(bytes32 => bytes) metadata;
    }
    
    struct LiquidityInfo {
        address venue;
        string name;
        bool isDEX;
        uint256 tokenAmount;
        uint256 pairedAssetAmount;
        address pairedAsset;
        uint256 lpTokenSupply;
        uint256 lastUpdated;
    }
    
    struct HolderData {
        address holder;
        uint256 balance;
        uint256 percentage; // Basis points (10000 = 100%)
        WalletType classification;
        uint256 lastUpdate;
    }
    
    struct DataFeed {
        string name;
        address oracle;
        DataFeedType feedType;
        uint256 lastUpdate;
        bytes lastValue;
        uint256 updateFrequency;
        bool isActive;
    }
    
    struct NFTCollection {
        address collectionAddress;
        string name;
        NFTCategory category;
        uint256 totalSupply;
        uint256 holderCount;
        uint256 governanceWeight;
        uint256 totalRevenue;
        bool isActive;
        mapping(bytes32 => bytes) metadata;
    }
    
    struct SupplyMetrics {
        uint256 totalSupply;
        uint256 circulatingSupply;
        uint256 lockedSupply;
        uint256 burnedSupply;
        uint256 vestingSupply;
        uint256 treasurySupply;
        uint256 lastUpdated;
    }
    
    struct EmissionSchedule {
        uint256 currentRate;
        uint256 nextHalvingBlock;
        uint256 halvingPercentage;
        uint256[] milestones;
        uint256[] rates;
        bool isActive;
    }
    
    struct TreasuryInfo {
        address treasuryAddress;
        string name;
        uint256 tokenBalance;
        uint256 totalValueUSD;
        uint256 lastActivity;
        mapping(address => uint256) otherAssets;
    }
    
    struct ProofOfReserve {
        address reserveAddress;
        string name;
        string assetType; // "USD", "GOLD", "BTC", etc.
        uint256 backedTokenSupply; // Amount of tokens this reserve backs
        uint256 reserveValue; // Value in reserve currency
        uint256 lastAuditTimestamp;
        string lastAuditReport; // IPFS hash or URL
        address[] auditors; // Authorized auditors
        bool isActive;
        mapping(bytes32 => bytes) metadata;
    }
    
    // ============ State Variables ============
    
    // Core Configuration
    address public immutable TOKEN;
    address public owner;
    bool public paused;
    
    // Access Control
    mapping(address => bool) public admins;
    mapping(address => bool) public operators;
    mapping(address => bool) public observers;
    
    // Integration Tracking
    mapping(address => DAppIntegration) public dappIntegrations;
    EnumerableSet.AddressSet private activeDApps;
    
    mapping(address => RewardPool) public rewardPools;
    EnumerableSet.AddressSet private activeRewardPools;
    
    // Wallet Classification
    mapping(address => WalletInfo) public walletClassifications;
    mapping(WalletType => EnumerableSet.AddressSet) private walletsByType;
    
    // Liquidity Tracking
    mapping(address => LiquidityInfo) public liquidityVenues;
    EnumerableSet.AddressSet private dexVenues;
    EnumerableSet.AddressSet private cexVenues;
    
    // Holder Analytics
    HolderData[25] public topHolders;
    uint256 public lastHolderUpdate;
    uint256 public totalHolders;
    
    // Data Feeds
    mapping(bytes32 => DataFeed) public dataFeeds;
    bytes32[] public activeFeedIds;
    
    // NFT Collections
    mapping(address => NFTCollection) public nftCollections;
    mapping(NFTCategory => EnumerableSet.AddressSet) private collectionsByCategory;
    
    // Supply and Emissions
    SupplyMetrics public supplyMetrics;
    EmissionSchedule public emissionSchedule;
    
    // Treasury and Governance
    mapping(address => TreasuryInfo) public treasuries;
    EnumerableSet.AddressSet private treasuryAddresses;
    
    mapping(address => bool) public multiSigWallets;
    EnumerableSet.AddressSet private activeMultiSigs;
    
    // Proof of Reserve
    mapping(address => ProofOfReserve) public proofOfReserves;
    EnumerableSet.AddressSet private activeReserves;
    uint256 public totalBackedSupply;
    uint256 public totalReserveValueUSD;
    
    // Analytics Cache
    uint256 public cachedTotalLiquidity;
    uint256 public cachedPrice;
    uint256 public cachedMarketCap;
    uint256 public lastAnalyticsUpdate;
    
    // Events
    event DAppRegistered(address indexed dapp, string name, IntegrationType integrationType);
    event RewardPoolAdded(address indexed pool, string name, uint256 totalRewards);
    event WalletClassified(address indexed wallet, WalletType walletType, string label);
    event LiquidityVenueAdded(address indexed venue, bool isDEX, string name);
    event DataFeedUpdated(bytes32 indexed feedId, uint256 value);
    event NFTCollectionAdded(address indexed collection, NFTCategory category, string name);
    event SupplyMetricsUpdated(uint256 totalSupply, uint256 circulatingSupply);
    event TreasuryRegistered(address indexed treasury, string name);
    event TopHoldersUpdated(uint256 timestamp);
    event EmergencyPause(address indexed by);
    event ProofOfReserveAdded(address indexed reserve, string assetType, uint256 backedSupply);
    event ProofOfReserveUpdated(address indexed reserve, uint256 newValue, uint256 backedSupply);
    event ProofOfReserveAudited(address indexed reserve, uint256 timestamp, string auditReport);
    event AuditorAdded(address indexed reserve, address indexed auditor);
    event AuditorRemoved(address indexed reserve, address indexed auditor);
    
    // Errors
    error Unauthorized();
    error InvalidAddress();
    error InvalidParameters();
    error AlreadyRegistered();
    error NotFound();
    error ContractPaused();
    error UpdateTooSoon();
    error ArrayLengthMismatch();
    error ValueOutOfRange();
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyAdmin() {
        if (!admins[msg.sender] && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!operators[msg.sender] && !admins[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _token) validAddress(_token) {
        TOKEN = _token;
        owner = msg.sender;
        admins[msg.sender] = true;
        
        // Initialize supply metrics
        supplyMetrics.lastUpdated = block.timestamp;
        lastAnalyticsUpdate = block.timestamp;
    }
    
    // ============ Integration Management Functions ============
    
    /**
     * @notice Register a new DAPP integration
     * @param dappAddress Address of the DAPP contract
     * @param name Name of the DAPP
     * @param integrationType Type of integration
     */
    function registerDApp(
        address dappAddress,
        string calldata name,
        IntegrationType integrationType
    ) external onlyOperator validAddress(dappAddress) {
        if (dappIntegrations[dappAddress].authorizationDate != 0) {
            revert AlreadyRegistered();
        }
        
        DAppIntegration storage dapp = dappIntegrations[dappAddress];
        dapp.name = name;
        dapp.contractAddress = dappAddress;
        dapp.integrationType = integrationType;
        dapp.authorizationDate = block.timestamp;
        dapp.isActive = true;
        
        activeDApps.add(dappAddress);
        
        emit DAppRegistered(dappAddress, name, integrationType);
    }
    
    /**
     * @notice Add a new reward pool
     * @param poolAddress Address of the reward pool
     * @param name Name of the pool
     * @param totalRewards Total rewards allocated
     * @param distributionRate Distribution rate per block/second
     * @param expiresAt Expiration timestamp
     */
    function addRewardPool(
        address poolAddress,
        string calldata name,
        uint256 totalRewards,
        uint256 distributionRate,
        uint256 expiresAt
    ) external onlyOperator validAddress(poolAddress) {
        if (rewardPools[poolAddress].createdAt != 0) {
            revert AlreadyRegistered();
        }
        
        RewardPool storage pool = rewardPools[poolAddress];
        pool.poolAddress = poolAddress;
        pool.name = name;
        pool.totalDeposited = totalRewards;
        pool.remainingRewards = totalRewards;
        pool.distributionRate = distributionRate;
        pool.createdAt = block.timestamp;
        pool.expiresAt = expiresAt;
        pool.isActive = true;
        
        activeRewardPools.add(poolAddress);
        
        emit RewardPoolAdded(poolAddress, name, totalRewards);
    }
    
    /**
     * @notice Update DAPP metrics
     * @param dappAddress Address of the DAPP
     * @param tokensLocked Current tokens locked
     * @param activeUsers Number of active users
     * @param volume Transaction volume
     */
    function updateDAppMetrics(
        address dappAddress,
        uint256 tokensLocked,
        uint256 activeUsers,
        uint256 volume
    ) external onlyOperator {
        DAppIntegration storage dapp = dappIntegrations[dappAddress];
        if (dapp.authorizationDate == 0) revert NotFound();
        
        dapp.totalTokensLocked = tokensLocked;
        dapp.activeUsers = activeUsers;
        dapp.transactionVolume = volume;
    }
    
    // ============ Wallet Classification Functions ============
    
    /**
     * @notice Classify a wallet address
     * @param wallet Address to classify
     * @param walletType Type of wallet
     * @param label Description label
     */
    function classifyWallet(
        address wallet,
        WalletType walletType,
        string calldata label
    ) external onlyOperator validAddress(wallet) {
        _classifyWallet(wallet, walletType, label);
    }
    
    /**
     * @notice Batch classify wallets
     * @param wallets Array of wallet addresses
     * @param walletTypes Array of wallet types
     * @param labels Array of labels
     */
    function batchClassifyWallets(
        address[] calldata wallets,
        WalletType[] calldata walletTypes,
        string[] calldata labels
    ) external onlyOperator {
        uint256 length = wallets.length;
        if (length != walletTypes.length || length != labels.length) {
            revert ArrayLengthMismatch();
        }
        
        for (uint256 i = 0; i < length; i++) {
            _classifyWallet(wallets[i], walletTypes[i], labels[i]);
        }
    }
    
    /**
     * @notice Check if an address is a registered proof of reserve
     * @param addr Address to check
     * @return isReserve Whether the address is an active proof of reserve
     * @return assetType Type of asset backing (empty string if not a reserve)
     */
    function isProofOfReserve(address addr) external view returns (bool isReserve, string memory assetType) {
        ProofOfReserve storage reserve = proofOfReserves[addr];
        isReserve = reserve.isActive && reserve.reserveAddress != address(0);
        assetType = reserve.assetType;
    }
    
    /**
     * @notice Get reserves by asset type
     * @param assetType Type of backing asset to filter by
     * @return reserves Array of reserve addresses backing this asset type
     * @return totalBacked Total tokens backed by this asset type
     * @return totalValue Total value held in this asset type
     */
    function getReservesByAssetType(string calldata assetType) external view returns (
        address[] memory reserves,
        uint256 totalBacked,
        uint256 totalValue
    ) {
        uint256 count = activeReserves.length();
        address[] memory tempReserves = new address[](count);
        uint256 matchCount = 0;
        
        for (uint256 i = 0; i < count; i++) {
            address reserveAddr = activeReserves.at(i);
            ProofOfReserve storage reserve = proofOfReserves[reserveAddr];
            
            if (keccak256(bytes(reserve.assetType)) == keccak256(bytes(assetType))) {
                tempReserves[matchCount] = reserveAddr;
                totalBacked += reserve.backedTokenSupply;
                totalValue += reserve.reserveValue;
                matchCount++;
            }
        }
        
        // Create properly sized array
        reserves = new address[](matchCount);
        for (uint256 i = 0; i < matchCount; i++) {
            reserves[i] = tempReserves[i];
        }
    }
    
    // ============ Liquidity Tracking Functions ============
    
    /**
     * @notice Register a liquidity venue
     * @param venue Address of the liquidity venue
     * @param name Name of the venue
     * @param isDEX Whether it's a DEX (true) or CEX (false)
     */
    function registerLiquidityVenue(
        address venue,
        string calldata name,
        bool isDEX
    ) external onlyOperator validAddress(venue) {
        LiquidityInfo storage info = liquidityVenues[venue];
        info.venue = venue;
        info.name = name;
        info.isDEX = isDEX;
        info.lastUpdated = block.timestamp;
        
        if (isDEX) {
            dexVenues.add(venue);
        } else {
            cexVenues.add(venue);
        }
        
        emit LiquidityVenueAdded(venue, isDEX, name);
    }
    
    /**
     * @notice Update liquidity metrics for a venue
     * @param venue Address of the venue
     * @param tokenAmount Amount of tokens
     * @param pairedAssetAmount Amount of paired asset
     * @param pairedAsset Address of paired asset
     */
    function updateLiquidityMetrics(
        address venue,
        uint256 tokenAmount,
        uint256 pairedAssetAmount,
        address pairedAsset
    ) external onlyOperator {
        LiquidityInfo storage info = liquidityVenues[venue];
        if (info.venue == address(0)) revert NotFound();
        
        info.tokenAmount = tokenAmount;
        info.pairedAssetAmount = pairedAssetAmount;
        info.pairedAsset = pairedAsset;
        info.lastUpdated = block.timestamp;
        
        _updateTotalLiquidity();
    }
    
    // ============ Holder Analytics Functions ============
    
    /**
     * @notice Update top holders list
     * @param holders Array of holder addresses
     * @param balances Array of holder balances
     */
    function updateTopHolders(
        address[] calldata holders,
        uint256[] calldata balances
    ) external onlyOperator {
        uint256 length = holders.length;
        if (length > 25 || length != balances.length) {
            revert InvalidParameters();
        }
        
        uint256 totalSupply = supplyMetrics.totalSupply;
        if (totalSupply == 0) revert InvalidParameters();
        
        for (uint256 i = 0; i < length; i++) {
            topHolders[i] = HolderData({
                holder: holders[i],
                balance: balances[i],
                percentage: balances[i].mul(10000).div(totalSupply),
                classification: walletClassifications[holders[i]].walletType,
                lastUpdate: block.timestamp
            });
        }
        
        // Clear remaining slots if less than 25 holders
        for (uint256 i = length; i < 25; i++) {
            delete topHolders[i];
        }
        
        lastHolderUpdate = block.timestamp;
        emit TopHoldersUpdated(block.timestamp);
    }
    
    /**
     * @notice Update total holder count
     * @param count Total number of token holders
     */
    function updateHolderCount(uint256 count) external onlyOperator {
        totalHolders = count;
    }
    
    // ============ Data Feed Functions ============
    
    /**
     * @notice Register a new data feed
     * @param feedId Unique identifier for the feed
     * @param name Name of the feed
     * @param oracle Oracle address
     * @param feedType Type of data feed
     * @param updateFrequency How often the feed updates
     */
    function registerDataFeed(
        bytes32 feedId,
        string calldata name,
        address oracle,
        DataFeedType feedType,
        uint256 updateFrequency
    ) external onlyAdmin validAddress(oracle) {
        DataFeed storage feed = dataFeeds[feedId];
        feed.name = name;
        feed.oracle = oracle;
        feed.feedType = feedType;
        feed.updateFrequency = updateFrequency;
        feed.isActive = true;
        
        activeFeedIds.push(feedId);
    }
    
    /**
     * @notice Update data feed value
     * @param feedId Feed identifier
     * @param value New value
     */
    function updateDataFeed(bytes32 feedId, bytes calldata value) external onlyOperator {
        DataFeed storage feed = dataFeeds[feedId];
        if (!feed.isActive) revert NotFound();
        
        feed.lastValue = value;
        feed.lastUpdate = block.timestamp;
        
        // Update cached values based on feed type
        if (feed.feedType == DataFeedType.PRICE) {
            cachedPrice = abi.decode(value, (uint256));
            _updateMarketCap();
        }
        
        emit DataFeedUpdated(feedId, abi.decode(value, (uint256)));
    }
    
    // ============ NFT Collection Management ============
    
    /**
     * @notice Register an NFT collection
     * @param collection Address of the NFT collection
     * @param name Name of the collection
     * @param category Category of NFT
     * @param totalSupply Total supply of NFTs
     * @param governanceWeight Governance weight per NFT (if applicable)
     */
    function registerNFTCollection(
        address collection,
        string calldata name,
        NFTCategory category,
        uint256 totalSupply,
        uint256 governanceWeight
    ) external onlyOperator validAddress(collection) {
        if (nftCollections[collection].collectionAddress != address(0)) {
            revert AlreadyRegistered();
        }
        
        NFTCollection storage nft = nftCollections[collection];
        nft.collectionAddress = collection;
        nft.name = name;
        nft.category = category;
        nft.totalSupply = totalSupply;
        nft.governanceWeight = governanceWeight;
        nft.isActive = true;
        
        collectionsByCategory[category].add(collection);
        
        emit NFTCollectionAdded(collection, category, name);
    }
    
    /**
     * @notice Update NFT collection metrics
     * @param collection Address of the collection
     * @param holderCount Number of unique holders
     * @param totalRevenue Total revenue generated (if commercial)
     */
    function updateNFTMetrics(
        address collection,
        uint256 holderCount,
        uint256 totalRevenue
    ) external onlyOperator {
        NFTCollection storage nft = nftCollections[collection];
        if (nft.collectionAddress == address(0)) revert NotFound();
        
        nft.holderCount = holderCount;
        nft.totalRevenue = totalRevenue;
    }
    
    // ============ Supply and Emission Management ============
    
    /**
     * @notice Update supply metrics
     * @param metrics New supply metrics
     */
    function updateSupplyMetrics(SupplyMetrics calldata metrics) external onlyOperator {
        supplyMetrics = metrics;
        supplyMetrics.lastUpdated = block.timestamp;
        
        emit SupplyMetricsUpdated(metrics.totalSupply, metrics.circulatingSupply);
        
        _updateMarketCap();
    }
    
    /**
     * @notice Set emission schedule
     * @param currentRate Current emission rate
     * @param nextHalving Block number for next halving
     * @param halvingPercentage Percentage reduction at halving
     * @param milestones Array of milestone blocks
     * @param rates Array of emission rates
     */
    function setEmissionSchedule(
        uint256 currentRate,
        uint256 nextHalving,
        uint256 halvingPercentage,
        uint256[] calldata milestones,
        uint256[] calldata rates
    ) external onlyAdmin {
        if (milestones.length != rates.length) revert ArrayLengthMismatch();
        if (halvingPercentage > 100) revert ValueOutOfRange();
        
        emissionSchedule.currentRate = currentRate;
        emissionSchedule.nextHalvingBlock = nextHalving;
        emissionSchedule.halvingPercentage = halvingPercentage;
        emissionSchedule.milestones = milestones;
        emissionSchedule.rates = rates;
        emissionSchedule.isActive = true;
    }
    
    // ============ Treasury and Governance Functions ============
    
    /**
     * @notice Register a treasury address
     * @param treasury Address of the treasury
     * @param name Name of the treasury
     */
    function registerTreasury(
        address treasury,
        string calldata name
    ) external onlyOperator validAddress(treasury) {
        TreasuryInfo storage info = treasuries[treasury];
        info.treasuryAddress = treasury;
        info.name = name;
        
        treasuryAddresses.add(treasury);
        
        // Also classify as treasury wallet
        _classifyWallet(treasury, WalletType.TREASURY, name);
        
        emit TreasuryRegistered(treasury, name);
    }
    
    /**
     * @notice Register a multi-sig wallet
     * @param multiSig Address of the multi-sig
     * @param label Description of the multi-sig
     */
    function registerMultiSig(
        address multiSig,
        string calldata label
    ) external onlyOperator validAddress(multiSig) {
        multiSigWallets[multiSig] = true;
        activeMultiSigs.add(multiSig);
        
        // Also classify as multi-sig wallet
        _classifyWallet(multiSig, WalletType.MULTI_SIG, label);
    }
    
    /**
     * @notice Update treasury metrics
     * @param treasury Address of the treasury
     * @param tokenBalance Current token balance
     * @param totalValueUSD Total USD value
     */
    function updateTreasuryMetrics(
        address treasury,
        uint256 tokenBalance,
        uint256 totalValueUSD
    ) external onlyOperator {
        TreasuryInfo storage info = treasuries[treasury];
        if (info.treasuryAddress == address(0)) revert NotFound();
        
        info.tokenBalance = tokenBalance;
        info.totalValueUSD = totalValueUSD;
        info.lastActivity = block.timestamp;
    }
    
    // ============ Proof of Reserve Functions ============
    
    /**
     * @notice Register a proof of reserve address
     * @dev Proof of reserves demonstrate backing for tokens (e.g., stablecoins backed by USD,
     *      tokenized commodities backed by physical assets, or any token with collateral)
     * @param reserveAddress Address holding the reserves
     * @param name Name of the reserve
     * @param assetType Type of asset backing (USD, GOLD, BTC, etc.)
     * @param backedTokenSupply Amount of tokens this reserve backs
     * @param initialValue Initial reserve value
     */
    function registerProofOfReserve(
        address reserveAddress,
        string calldata name,
        string calldata assetType,
        uint256 backedTokenSupply,
        uint256 initialValue
    ) external onlyOperator validAddress(reserveAddress) {
        if (proofOfReserves[reserveAddress].reserveAddress != address(0)) {
            revert AlreadyRegistered();
        }
        
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        reserve.reserveAddress = reserveAddress;
        reserve.name = name;
        reserve.assetType = assetType;
        reserve.backedTokenSupply = backedTokenSupply;
        reserve.reserveValue = initialValue;
        reserve.isActive = true;
        
        activeReserves.add(reserveAddress);
        totalBackedSupply += backedTokenSupply;
        totalReserveValueUSD += initialValue;
        
        // Also classify as proof of reserve wallet
        _classifyWallet(reserveAddress, WalletType.PROOF_OF_RESERVE, name);
        
        emit ProofOfReserveAdded(reserveAddress, assetType, backedTokenSupply);
    }
    
    /**
     * @notice Update proof of reserve metrics
     * @param reserveAddress Address of the reserve
     * @param newReserveValue Updated reserve value
     * @param newBackedSupply Updated backed token supply
     */
    function updateProofOfReserve(
        address reserveAddress,
        uint256 newReserveValue,
        uint256 newBackedSupply
    ) external onlyOperator {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        // Update total backed supply
        totalBackedSupply = totalBackedSupply - reserve.backedTokenSupply + newBackedSupply;
        
        // Update total reserve value
        totalReserveValueUSD = totalReserveValueUSD - reserve.reserveValue + newReserveValue;
        
        reserve.reserveValue = newReserveValue;
        reserve.backedTokenSupply = newBackedSupply;
        
        emit ProofOfReserveUpdated(reserveAddress, newReserveValue, newBackedSupply);
    }
    
    /**
     * @notice Submit audit report for proof of reserve
     * @param reserveAddress Address of the reserve
     * @param auditReport IPFS hash or URL of audit report
     */
    function submitAuditReport(
        address reserveAddress,
        string calldata auditReport
    ) external {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        // Check if sender is authorized auditor
        bool isAuditor = false;
        for (uint256 i = 0; i < reserve.auditors.length; i++) {
            if (reserve.auditors[i] == msg.sender) {
                isAuditor = true;
                break;
            }
        }
        if (!isAuditor && !operators[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        
        reserve.lastAuditTimestamp = block.timestamp;
        reserve.lastAuditReport = auditReport;
        
        emit ProofOfReserveAudited(reserveAddress, block.timestamp, auditReport);
    }
    
    /**
     * @notice Add an authorized auditor for a reserve
     * @param reserveAddress Address of the reserve
     * @param auditor Address of the auditor
     */
    function addAuditor(
        address reserveAddress,
        address auditor
    ) external onlyAdmin validAddress(auditor) {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        reserve.auditors.push(auditor);
        
        emit AuditorAdded(reserveAddress, auditor);
    }
    
    /**
     * @notice Remove an auditor from a reserve
     * @param reserveAddress Address of the reserve
     * @param auditor Address of the auditor to remove
     */
    function removeAuditor(
        address reserveAddress,
        address auditor
    ) external onlyAdmin {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        uint256 length = reserve.auditors.length;
        for (uint256 i = 0; i < length; i++) {
            if (reserve.auditors[i] == auditor) {
                reserve.auditors[i] = reserve.auditors[length - 1];
                reserve.auditors.pop();
                emit AuditorRemoved(reserveAddress, auditor);
                break;
            }
        }
    }
    
    /**
     * @notice Update total reserve value in USD
     * @param newTotalValue New total value across all reserves
     */
    function updateTotalReserveValue(uint256 newTotalValue) external onlyOperator {
        totalReserveValueUSD = newTotalValue;
    }
    
    /**
     * @notice Set metadata for a proof of reserve
     * @param reserveAddress Reserve address
     * @param key Metadata key
     * @param value Metadata value
     */
    function setReserveMetadata(
        address reserveAddress,
        bytes32 key,
        bytes calldata value
    ) external onlyOperator {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        reserve.metadata[key] = value;
    }
    
    /**
     * @notice Deactivate a proof of reserve
     * @param reserveAddress Address of the reserve to deactivate
     */
    function deactivateProofOfReserve(address reserveAddress) external onlyAdmin {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        if (reserve.reserveAddress == address(0)) revert NotFound();
        
        reserve.isActive = false;
        activeReserves.remove(reserveAddress);
        totalBackedSupply -= reserve.backedTokenSupply;
        totalReserveValueUSD -= reserve.reserveValue;
        
        // Update wallet classification
        _classifyWallet(reserveAddress, WalletType.UNCLASSIFIED, "Deactivated Reserve");
    }
    
    /**
     * @notice Batch register proof of reserves
     * @param reserves Array of reserve addresses
     * @param names Array of reserve names
     * @param assetTypes Array of asset types
     * @param backedSupplies Array of backed token supplies
     * @param initialValues Array of initial reserve values
     */
    function batchRegisterProofOfReserves(
        address[] calldata reserves,
        string[] calldata names,
        string[] calldata assetTypes,
        uint256[] calldata backedSupplies,
        uint256[] calldata initialValues
    ) external onlyOperator {
        uint256 length = reserves.length;
        if (length != names.length || 
            length != assetTypes.length || 
            length != backedSupplies.length || 
            length != initialValues.length) {
            revert ArrayLengthMismatch();
        }
        
        for (uint256 i = 0; i < length; i++) {
            if (reserves[i] == address(0)) continue;
            if (proofOfReserves[reserves[i]].reserveAddress != address(0)) continue;
            
            ProofOfReserve storage reserve = proofOfReserves[reserves[i]];
            reserve.reserveAddress = reserves[i];
            reserve.name = names[i];
            reserve.assetType = assetTypes[i];
            reserve.backedTokenSupply = backedSupplies[i];
            reserve.reserveValue = initialValues[i];
            reserve.isActive = true;
            
            activeReserves.add(reserves[i]);
            totalBackedSupply += backedSupplies[i];
            totalReserveValueUSD += initialValues[i];
            
            _classifyWallet(reserves[i], WalletType.PROOF_OF_RESERVE, names[i]);
            
            emit ProofOfReserveAdded(reserves[i], assetTypes[i], backedSupplies[i]);
        }
    }
    
    // ============ Query Functions ============
    
    /**
     * @notice Get complete token metrics
     * @return totalSupply Total supply of tokens
     * @return circulatingSupply Circulating supply of tokens
     * @return price Current token price
     * @return marketCap Current market capitalization
     * @return totalLiquidity Total liquidity across all venues
     * @return holders Total number of token holders
     * @return currentEmissionRate Current emission rate
     * @return backedSupply Total supply backed by reserves
     * @return reserveValue Total value in reserves (USD)
     */
    function getTokenMetrics() external view returns (
        uint256 totalSupply,
        uint256 circulatingSupply,
        uint256 price,
        uint256 marketCap,
        uint256 totalLiquidity,
        uint256 holders,
        uint256 currentEmissionRate,
        uint256 backedSupply,
        uint256 reserveValue
    ) {
        return (
            supplyMetrics.totalSupply,
            supplyMetrics.circulatingSupply,
            cachedPrice,
            cachedMarketCap,
            cachedTotalLiquidity,
            totalHolders,
            emissionSchedule.currentRate,
            totalBackedSupply,
            totalReserveValueUSD
        );
    }
    
    /**
     * @notice Get top holders with details
     * @param count Number of holders to return (max 25)
     * @return holders Array of holder data
     */
    function getTopHolders(uint256 count) external view returns (HolderData[] memory holders) {
        if (count > 25) count = 25;
        holders = new HolderData[](count);
        
        for (uint256 i = 0; i < count; i++) {
            if (topHolders[i].holder == address(0)) break;
            holders[i] = topHolders[i];
        }
    }
    
    /**
     * @notice Get all active DAPP integrations
     * @return dapps Array of DAPP addresses
     */
    function getActiveDApps() external view returns (address[] memory) {
        return activeDApps.values();
    }
    
    /**
     * @notice Get all liquidity venues
     * @return dexList Array of DEX addresses
     * @return cexList Array of CEX addresses
     */
    function getLiquidityVenues() external view returns (
        address[] memory dexList,
        address[] memory cexList
    ) {
        dexList = dexVenues.values();
        cexList = cexVenues.values();
    }
    
    /**
     * @notice Get NFT collections by category
     * @param category NFT category to query
     * @return collections Array of collection addresses
     */
    function getNFTCollectionsByCategory(NFTCategory category) 
        external 
        view 
        returns (address[] memory) 
    {
        return collectionsByCategory[category].values();
    }
    
    /**
     * @notice Get wallets by type
     * @param walletType Type of wallet to query
     * @return wallets Array of wallet addresses
     */
    function getWalletsByType(WalletType walletType) 
        external 
        view 
        returns (address[] memory) 
    {
        return walletsByType[walletType].values();
    }
    
    /**
     * @notice Get all treasury addresses
     * @return Array of treasury addresses
     */
    function getTreasuryAddresses() external view returns (address[] memory) {
        return treasuryAddresses.values();
    }
    
    /**
     * @notice Get all active reward pools
     * @return Array of reward pool addresses
     */
    function getActiveRewardPools() external view returns (address[] memory) {
        return activeRewardPools.values();
    }
    
    /**
     * @notice Get all proof of reserve addresses
     * @return Array of proof of reserve addresses
     */
    function getProofOfReserves() external view returns (address[] memory) {
        return activeReserves.values();
    }
    
    /**
     * @notice Get detailed proof of reserve information
     * @param reserveAddress Address of the reserve
     * @return name Reserve name
     * @return assetType Type of backing asset
     * @return backedSupply Token supply backed by this reserve
     * @return reserveValue Current reserve value
     * @return lastAudit Timestamp of last audit
     * @return auditReport Last audit report reference
     */
    function getReserveDetails(address reserveAddress) external view returns (
        string memory name,
        string memory assetType,
        uint256 backedSupply,
        uint256 reserveValue,
        uint256 lastAudit,
        string memory auditReport
    ) {
        ProofOfReserve storage reserve = proofOfReserves[reserveAddress];
        return (
            reserve.name,
            reserve.assetType,
            reserve.backedTokenSupply,
            reserve.reserveValue,
            reserve.lastAuditTimestamp,
            reserve.lastAuditReport
        );
    }
    
    /**
     * @notice Get reserve backing ratio
     * @return backingRatio Percentage of token supply backed by reserves (basis points)
     */
    function getReserveBackingRatio() external view returns (uint256 backingRatio) {
        if (supplyMetrics.totalSupply == 0) return 0;
        backingRatio = totalBackedSupply.mul(10000).div(supplyMetrics.totalSupply);
    }
    
    /**
     * @notice Get auditors for a specific reserve
     * @param reserveAddress Address of the reserve
     * @return Array of auditor addresses
     */
    function getReserveAuditors(address reserveAddress) external view returns (address[] memory) {
        return proofOfReserves[reserveAddress].auditors;
    }
    
    /**
     * @notice Get comprehensive reserve statistics
     * @return totalReserves Number of active reserves
     * @return totalBackedTokens Total tokens backed by reserves
     * @return totalReserveVal Total USD value in reserves
     * @return backingRatio Overall backing ratio (basis points)
     * @return lastAuditTime Timestamp of most recent audit across all reserves
     */
    function getReserveStatistics() external view returns (
        uint256 totalReserves,
        uint256 totalBackedTokens,
        uint256 totalReserveVal,
        uint256 backingRatio,
        uint256 lastAuditTime
    ) {
        totalReserves = activeReserves.length();
        totalBackedTokens = totalBackedSupply;
        totalReserveVal = totalReserveValueUSD;
        
        if (supplyMetrics.totalSupply > 0) {
            backingRatio = totalBackedSupply.mul(10000).div(supplyMetrics.totalSupply);
        }
        
        // Find most recent audit
        for (uint256 i = 0; i < totalReserves; i++) {
            address reserveAddr = activeReserves.at(i);
            uint256 auditTime = proofOfReserves[reserveAddr].lastAuditTimestamp;
            if (auditTime > lastAuditTime) {
                lastAuditTime = auditTime;
            }
        }
    }
    
    /**
     * @notice Get comprehensive integration report
     * @return totalDApps Total number of integrated DAPPs
     * @return totalRewardPools Total number of reward pools
     * @return totalLiquidityVenues Total liquidity venues
     * @return totalNFTCollections Total NFT collections
     * @return totalReserves Total proof of reserve addresses
     * @return reserveBackingRatio Reserve backing ratio in basis points
     */
    function getIntegrationReport() external view returns (
        uint256 totalDApps,
        uint256 totalRewardPools,
        uint256 totalLiquidityVenues,
        uint256 totalNFTCollections,
        uint256 totalReserves,
        uint256 reserveBackingRatio
    ) {
        totalDApps = activeDApps.length();
        totalRewardPools = activeRewardPools.length();
        totalLiquidityVenues = dexVenues.length() + cexVenues.length();
        
        uint256 nftCount;
        for (uint256 i = 0; i <= uint256(NFTCategory.UTILITY); i++) {
            nftCount += collectionsByCategory[NFTCategory(i)].length();
        }
        totalNFTCollections = nftCount;
        totalReserves = activeReserves.length();
        
        if (supplyMetrics.totalSupply > 0) {
            reserveBackingRatio = totalBackedSupply.mul(10000).div(supplyMetrics.totalSupply);
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Internal function to classify a wallet
     * @param wallet Address to classify
     * @param walletType Type of wallet
     * @param label Description label
     */
    function _classifyWallet(
        address wallet,
        WalletType walletType,
        string memory label
    ) internal {
        if (wallet == address(0)) revert InvalidAddress();
        
        WalletInfo storage info = walletClassifications[wallet];
        
        // Remove from previous category if exists
        if (info.walletType != WalletType.UNCLASSIFIED) {
            walletsByType[info.walletType].remove(wallet);
        }
        
        info.walletType = walletType;
        info.label = label;
        info.classifiedAt = block.timestamp;
        
        walletsByType[walletType].add(wallet);
        
        emit WalletClassified(wallet, walletType, label);
    }
    
    /**
     * @dev Update total liquidity across all venues
     */
    function _updateTotalLiquidity() internal {
        uint256 total = 0;
        
        // Sum DEX liquidity
        uint256 dexLength = dexVenues.length();
        for (uint256 i = 0; i < dexLength; i++) {
            address venue = dexVenues.at(i);
            total += liquidityVenues[venue].tokenAmount;
        }
        
        // Sum CEX liquidity (estimated)
        uint256 cexLength = cexVenues.length();
        for (uint256 i = 0; i < cexLength; i++) {
            address venue = cexVenues.at(i);
            total += liquidityVenues[venue].tokenAmount;
        }
        
        cachedTotalLiquidity = total;
        lastAnalyticsUpdate = block.timestamp;
    }
    
    /**
     * @dev Update market cap calculation
     */
    function _updateMarketCap() internal {
        if (cachedPrice > 0 && supplyMetrics.circulatingSupply > 0) {
            cachedMarketCap = cachedPrice.mul(supplyMetrics.circulatingSupply).div(1e18);
        }
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Add an admin
     * @param admin Address to grant admin role
     */
    function addAdmin(address admin) external onlyOwner validAddress(admin) {
        admins[admin] = true;
    }
    
    /**
     * @notice Remove an admin
     * @param admin Address to revoke admin role
     */
    function removeAdmin(address admin) external onlyOwner {
        admins[admin] = false;
    }
    
    /**
     * @notice Add an operator
     * @param operator Address to grant operator role
     */
    function addOperator(address operator) external onlyAdmin validAddress(operator) {
        operators[operator] = true;
    }
    
    /**
     * @notice Remove an operator
     * @param operator Address to revoke operator role
     */
    function removeOperator(address operator) external onlyAdmin {
        operators[operator] = false;
    }
    
    /**
     * @notice Add an observer
     * @param observer Address to grant observer role
     */
    function addObserver(address observer) external onlyAdmin validAddress(observer) {
        observers[observer] = true;
    }
    
    /**
     * @notice Emergency pause
     */
    function emergencyPause() external onlyOwner {
        paused = true;
        emit EmergencyPause(msg.sender);
    }
    
    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        paused = false;
    }
    
    /**
     * @notice Transfer ownership
     * @param newOwner Address of new owner
     */
    function transferOwnership(address newOwner) external onlyOwner validAddress(newOwner) {
        owner = newOwner;
        admins[newOwner] = true;
    }
    
    /**
     * @notice Set metadata for a DAPP
     * @param dapp DAPP address
     * @param key Metadata key
     * @param value Metadata value
     */
    function setDAppMetadata(
        address dapp,
        bytes32 key,
        bytes calldata value
    ) external onlyOperator {
        DAppIntegration storage integration = dappIntegrations[dapp];
        if (integration.authorizationDate == 0) revert NotFound();
        
        integration.metadata[key] = value;
    }
    
    /**
     * @notice Set metadata for a wallet
     * @param wallet Wallet address
     * @param key Metadata key
     * @param value Metadata value
     */
    function setWalletMetadata(
        address wallet,
        bytes32 key,
        bytes calldata value
    ) external onlyOperator {
        WalletInfo storage info = walletClassifications[wallet];
        if (info.classifiedAt == 0) revert NotFound();
        
        info.metadata[key] = value;
    }
    
    /**
     * @notice Set metadata for an NFT collection
     * @param collection Collection address
     * @param key Metadata key
     * @param value Metadata value
     */
    function setNFTMetadata(
        address collection,
        bytes32 key,
        bytes calldata value
    ) external onlyOperator {
        NFTCollection storage nft = nftCollections[collection];
        if (nft.collectionAddress == address(0)) revert NotFound();
        
        nft.metadata[key] = value;
    }
}

// ============ Library Imports ============

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
}

library EnumerableSet {
    struct Set {
        bytes32[] _values;
        mapping(bytes32 => uint256) _indexes;
    }
    
    struct AddressSet {
        Set _inner;
    }
    
    struct UintSet {
        Set _inner;
    }
    
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }
    
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }
    
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }
    
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }
    
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }
    
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;
        
        assembly {
            result := store
        }
        
        return result;
    }
    
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            set._indexes[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }
    
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        uint256 valueIndex = set._indexes[value];
        
        if (valueIndex != 0) {
            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;
            
            if (lastIndex != toDeleteIndex) {
                bytes32 lastValue = set._values[lastIndex];
                set._values[toDeleteIndex] = lastValue;
                set._indexes[lastValue] = valueIndex;
            }
            
            set._values.pop();
            delete set._indexes[value];
            
            return true;
        } else {
            return false;
        }
    }
    
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._indexes[value] != 0;
    }
    
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }
    
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }
    
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }
}
