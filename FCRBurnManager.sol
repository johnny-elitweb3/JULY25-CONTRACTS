// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// ========== Interfaces ==========

/**
 * @title IFCRNFTCollection Interface
 * @notice Interface for FCR NFT collections
 */
interface IFCRNFTCollection {
    struct FCRMetadata {
        uint256 barrelsPurchased;
        uint256 bonusBarrels;
        uint256 totalBarrels;
        uint256 usdValuePaid;
        uint256 purchaseDate;
        uint256 maturityDate;
        uint256 barrelPrice;
        uint256 yieldBonusPercent;
        address originalPurchaser;
        bool isBurned;
        address paymentToken;
        uint256 tokenAmountPaid;
    }
    
    function getFCRMetadata(uint256 tokenId) external view returns (FCRMetadata memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function markAsBurned(uint256 tokenId) external;
    function isNFTMature(uint256 tokenId) external view returns (bool);
    function getUserNFTs(address user) external view returns (uint256[] memory);
}

/**
 * @title IFCRFactory Interface
 * @notice Interface for FCR Factory
 */
interface IFCRFactory {
    function isValidCollection(address collection) external view returns (bool);
    function getCollectionCount() external view returns (uint256);
    function getCollection(uint256 id) external view returns (
        address contractAddress,
        string memory name,
        string memory symbol,
        uint256 proposalId,
        uint256 createdAt,
        bool isActive
    );
}

/**
 * @title IEnhancedGovernanceNFT Interface
 * @notice Interface for governance NFT
 */
interface IEnhancedGovernanceNFT {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title IOILReserveManager Interface
 * @notice Interface for OIL Reserve Manager
 */
interface IOILReserveManager {
    function releaseOILTokens(
        address recipient,
        address collection,
        uint256 tokenId,
        uint256 oilAmount
    ) external;
    
    function getAvailableReserve() external view returns (uint256);
    function getCollectionStats(address collection) external view returns (
        bool initialized,
        uint256 reserved,
        uint256 released,
        uint256 available,
        uint256 utilizationPercent
    );
    function isBurnProcessed(address collection, uint256 tokenId) external view returns (bool);
}

/**
 * @title FCRBurnManager
 * @dev Handles burning of mature FCR NFTs and releasing OIL tokens
 * @notice Core contract for the "burn to release" mechanism
 * @custom:security-contact security@petroleumclub.io
 */
contract FCRBurnManager is AccessControl, ReentrancyGuard, Pausable {
    
    // ========== Custom Errors ==========
    error InvalidAddress();
    error InvalidCollection();
    error TokenNotOwned();
    error TokenNotMature();
    error TokenAlreadyBurned();
    error InvalidAmount();
    error ReserveFailed();
    error NotTokenOwner();
    error CollectionNotSupported();
    error BatchSizeExceeded();
    error AlreadyProcessed();
    error NoEligibleTokens();

    // ========== Constants ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant GOVERNANCE_BONUS_PERCENT = 500; // 5% bonus for governance holders
    uint256 public constant PERCENT_PRECISION = 10000;

    // ========== State Variables ==========
    IOILReserveManager public immutable reserveManager;
    IFCRFactory public immutable fcrFactory;
    IEnhancedGovernanceNFT public immutable governanceNFT;
    
    // Collection management
    mapping(address => bool) public supportedCollections;
    mapping(address => uint256) public collectionBurnCount;
    mapping(address => uint256) public collectionTotalOilReleased;
    
    // User tracking
    mapping(address => uint256) public userTotalBurned;
    mapping(address => uint256) public userTotalOilClaimed;
    mapping(address => uint256) public userLastBurnTime;
    mapping(address => mapping(address => uint256[])) private userBurnedTokens; // user => collection => tokenIds
    
    // Global statistics
    uint256 public totalNFTsBurned;
    uint256 public totalOILReleased;
    uint256 public totalUSDValueBurned;
    
    // Burn records for history
    struct BurnRecord {
        address collection;
        uint256 tokenId;
        address burner;
        uint256 oilReceived;
        uint256 usdValuePaid;
        uint256 burnTime;
        bool hasGovernanceBonus;
    }
    
    mapping(uint256 => BurnRecord) public burnRecords;
    uint256 private _burnRecordCounter = 1;
    
    // Collection statistics
    struct CollectionInfo {
        bool isSupported;
        uint256 totalBurned;
        uint256 totalOilReleased;
        uint256 firstBurnTime;
        uint256 lastBurnTime;
    }
    
    mapping(address => CollectionInfo) public collectionInfo;

    // ========== Events ==========
    event CollectionSupported(address indexed collection, bool supported);
    event FCRNFTBurned(
        address indexed burner,
        address indexed collection,
        uint256 indexed tokenId,
        uint256 oilReceived,
        uint256 usdValuePaid,
        bool governanceBonus
    );
    event BatchBurnCompleted(
        address indexed burner,
        uint256 nftCount,
        uint256 totalOilReceived,
        address[] collections,
        uint256[] tokenIds
    );
    event GovernanceBonusApplied(
        address indexed user,
        uint256 bonusAmount,
        uint256 governanceBalance
    );
    event EmergencyBurnExecuted(
        address indexed admin,
        address indexed collection,
        uint256 indexed tokenId,
        address originalOwner
    );
    event UserStatsUpdated(
        address indexed user,
        uint256 totalBurned,
        uint256 totalOilClaimed
    );

    // ========== Constructor ==========
    constructor(
        address _reserveManager,
        address _fcrFactory,
        address _governanceNFT,
        address admin
    ) {
        if (_reserveManager == address(0) || _fcrFactory == address(0) || 
            _governanceNFT == address(0) || admin == address(0)) {
            revert InvalidAddress();
        }
        
        reserveManager = IOILReserveManager(_reserveManager);
        fcrFactory = IFCRFactory(_fcrFactory);
        governanceNFT = IEnhancedGovernanceNFT(_governanceNFT);
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    // ========== Core Burn Functions ==========
    
    /**
     * @notice Burn a single mature FCR NFT and receive OIL tokens
     * @param collection FCR collection address
     * @param tokenId Token ID to burn
     * @return oilReceived Amount of OIL tokens received
     */
    function burnFCRNFT(
        address collection,
        uint256 tokenId
    ) external nonReentrant whenNotPaused returns (uint256 oilReceived) {
        oilReceived = _processBurn(collection, tokenId, msg.sender);
        
        emit UserStatsUpdated(
            msg.sender,
            userTotalBurned[msg.sender],
            userTotalOilClaimed[msg.sender]
        );
    }

    /**
     * @notice Burn multiple mature FCR NFTs and receive OIL tokens
     * @param collections Array of collection addresses
     * @param tokenIds Array of token IDs (must match collections array)
     * @return totalOilReceived Total OIL tokens received
     */
    function batchBurnFCRNFTs(
        address[] calldata collections,
        uint256[] calldata tokenIds
    ) external nonReentrant whenNotPaused returns (uint256 totalOilReceived) {
        if (collections.length != tokenIds.length) revert InvalidAmount();
        if (collections.length == 0) revert InvalidAmount();
        if (collections.length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        for (uint256 i = 0; i < collections.length; i++) {
            uint256 oilReceived = _processBurn(collections[i], tokenIds[i], msg.sender);
            totalOilReceived += oilReceived;
        }
        
        emit BatchBurnCompleted(msg.sender, collections.length, totalOilReceived, collections, tokenIds);
        emit UserStatsUpdated(
            msg.sender,
            userTotalBurned[msg.sender],
            userTotalOilClaimed[msg.sender]
        );
    }

    /**
     * @notice Burn all eligible NFTs from a specific collection
     * @param collection Collection address
     * @return burnedCount Number of NFTs burned
     * @return totalOilReceived Total OIL tokens received
     */
    function burnAllEligibleFromCollection(
        address collection
    ) external nonReentrant whenNotPaused returns (uint256 burnedCount, uint256 totalOilReceived) {
        if (!supportedCollections[collection]) revert CollectionNotSupported();
        
        IFCRNFTCollection nftCollection = IFCRNFTCollection(collection);
        uint256[] memory userTokens = nftCollection.getUserNFTs(msg.sender);
        
        if (userTokens.length == 0) revert NoEligibleTokens();
        
        uint256 processed = 0;
        for (uint256 i = 0; i < userTokens.length && processed < MAX_BATCH_SIZE; i++) {
            uint256 tokenId = userTokens[i];
            
            // Check if eligible
            (uint256 oilAmount, bool isEligible,) = calculateBurnValue(collection, tokenId);
            
            if (isEligible && oilAmount > 0) {
                try this.burnFCRNFT(collection, tokenId) returns (uint256 oilReceived) {
                    totalOilReceived += oilReceived;
                    burnedCount++;
                    processed++;
                } catch {
                    // Skip tokens that fail
                    continue;
                }
            }
        }
        
        if (burnedCount == 0) revert NoEligibleTokens();
    }

    /**
     * @notice Process a single NFT burn (internal)
     * @param collection Collection address
     * @param tokenId Token ID
     * @param burner Address burning the NFT
     * @return oilReceived Amount of OIL tokens received
     */
    function _processBurn(
        address collection,
        uint256 tokenId,
        address burner
    ) private returns (uint256 oilReceived) {
        // Validate collection
        _validateCollection(collection);
        
        // Check if already processed
        if (reserveManager.isBurnProcessed(collection, tokenId)) {
            revert AlreadyProcessed();
        }
        
        // Get NFT contract
        IFCRNFTCollection nftCollection = IFCRNFTCollection(collection);
        
        // Validate ownership and maturity
        _validateBurnEligibility(nftCollection, tokenId, burner);
        
        // Get FCR metadata
        IFCRNFTCollection.FCRMetadata memory metadata = nftCollection.getFCRMetadata(tokenId);
        
        // Calculate base OIL tokens to release
        uint256 baseOilAmount = metadata.totalBarrels * 1e18;
        
        // Apply governance bonus if applicable
        bool hasGovernanceBonus = false;
        uint256 governanceBalance = governanceNFT.balanceOf(burner);
        
        if (governanceBalance > 0) {
            uint256 bonusAmount = (baseOilAmount * GOVERNANCE_BONUS_PERCENT) / PERCENT_PRECISION;
            oilReceived = baseOilAmount + bonusAmount;
            hasGovernanceBonus = true;
            
            emit GovernanceBonusApplied(burner, bonusAmount, governanceBalance);
        } else {
            oilReceived = baseOilAmount;
        }
        
        // Mark NFT as burned in the collection
        nftCollection.markAsBurned(tokenId);
        
        // Release OIL tokens from reserve
        reserveManager.releaseOILTokens(burner, collection, tokenId, oilReceived);
        
        // Update statistics
        _updateBurnStatistics(collection, burner, oilReceived, metadata.usdValuePaid);
        
        // Record the burn
        _recordBurn(
            collection,
            tokenId,
            burner,
            oilReceived,
            metadata.usdValuePaid,
            hasGovernanceBonus
        );
        
        // Track user's burned tokens
        userBurnedTokens[burner][collection].push(tokenId);
        
        emit FCRNFTBurned(
            burner,
            collection,
            tokenId,
            oilReceived,
            metadata.usdValuePaid,
            hasGovernanceBonus
        );
    }

    /**
     * @notice Validate collection is supported
     * @param collection Collection address to validate
     */
    function _validateCollection(address collection) private view {
        if (!fcrFactory.isValidCollection(collection)) revert InvalidCollection();
        if (!supportedCollections[collection]) revert CollectionNotSupported();
    }

    /**
     * @notice Validate NFT burn eligibility
     * @param nftCollection NFT collection contract
     * @param tokenId Token ID
     * @param burner Address attempting to burn
     */
    function _validateBurnEligibility(
        IFCRNFTCollection nftCollection,
        uint256 tokenId,
        address burner
    ) private view {
        // Check ownership
        address owner = nftCollection.ownerOf(tokenId);
        if (owner != burner) revert NotTokenOwner();
        
        // Check if already burned
        IFCRNFTCollection.FCRMetadata memory metadata = nftCollection.getFCRMetadata(tokenId);
        if (metadata.isBurned) revert TokenAlreadyBurned();
        
        // Check if mature
        if (!nftCollection.isNFTMature(tokenId)) revert TokenNotMature();
    }

    /**
     * @notice Update burn statistics
     * @param collection Collection address
     * @param burner Burner address
     * @param oilReceived OIL tokens received
     * @param usdValuePaid Original USD value paid
     */
    function _updateBurnStatistics(
        address collection,
        address burner,
        uint256 oilReceived,
        uint256 usdValuePaid
    ) private {
        // Update global stats
        totalNFTsBurned++;
        totalOILReleased += oilReceived;
        totalUSDValueBurned += usdValuePaid;
        
        // Update collection stats
        collectionBurnCount[collection]++;
        collectionTotalOilReleased[collection] += oilReceived;
        
        CollectionInfo storage info = collectionInfo[collection];
        info.totalBurned++;
        info.totalOilReleased += oilReceived;
        info.lastBurnTime = block.timestamp;
        if (info.firstBurnTime == 0) {
            info.firstBurnTime = block.timestamp;
        }
        
        // Update user stats
        userTotalBurned[burner]++;
        userTotalOilClaimed[burner] += oilReceived;
        userLastBurnTime[burner] = block.timestamp;
    }

    /**
     * @notice Record burn details
     * @param collection Collection address
     * @param tokenId Token ID
     * @param burner Burner address
     * @param oilReceived OIL tokens received
     * @param usdValuePaid Original USD value paid
     * @param hasGovernanceBonus Whether governance bonus was applied
     */
    function _recordBurn(
        address collection,
        uint256 tokenId,
        address burner,
        uint256 oilReceived,
        uint256 usdValuePaid,
        bool hasGovernanceBonus
    ) private {
        uint256 recordId = _burnRecordCounter++;
        
        burnRecords[recordId] = BurnRecord({
            collection: collection,
            tokenId: tokenId,
            burner: burner,
            oilReceived: oilReceived,
            usdValuePaid: usdValuePaid,
            burnTime: block.timestamp,
            hasGovernanceBonus: hasGovernanceBonus
        });
    }

    // ========== View Functions ==========
    
    /**
     * @notice Calculate potential OIL tokens for burning an NFT
     * @param collection Collection address
     * @param tokenId Token ID
     * @return oilAmount Amount of OIL tokens that would be received
     * @return isEligible Whether the NFT is eligible for burning
     * @return reason Reason if not eligible
     */
    function calculateBurnValue(
        address collection,
        uint256 tokenId
    ) public view returns (
        uint256 oilAmount,
        bool isEligible,
        string memory reason
    ) {
        if (!fcrFactory.isValidCollection(collection)) {
            return (0, false, "Invalid collection");
        }
        
        if (!supportedCollections[collection]) {
            return (0, false, "Collection not supported");
        }
        
        if (reserveManager.isBurnProcessed(collection, tokenId)) {
            return (0, false, "Already processed");
        }
        
        try IFCRNFTCollection(collection).getFCRMetadata(tokenId) returns (
            IFCRNFTCollection.FCRMetadata memory metadata
        ) {
            if (metadata.isBurned) {
                return (0, false, "Already burned");
            }
            
            uint256 baseAmount = metadata.totalBarrels * 1e18;
            
            // Add potential governance bonus for display
            address owner = IFCRNFTCollection(collection).ownerOf(tokenId);
            if (governanceNFT.balanceOf(owner) > 0) {
                uint256 bonus = (baseAmount * GOVERNANCE_BONUS_PERCENT) / PERCENT_PRECISION;
                oilAmount = baseAmount + bonus;
            } else {
                oilAmount = baseAmount;
            }
            
            if (block.timestamp >= metadata.maturityDate) {
                isEligible = true;
                reason = "Eligible for burning";
            } else {
                isEligible = false;
                uint256 timeLeft = metadata.maturityDate - block.timestamp;
                uint256 daysLeft = timeLeft / 86400;
                reason = string(abi.encodePacked("Matures in ", _toString(daysLeft), " days"));
            }
        } catch {
            return (0, false, "Token does not exist");
        }
    }

    /**
     * @notice Get user's burnable NFTs from a specific collection
     * @param user User address
     * @param collection Collection address
     * @return tokenIds Array of burnable token IDs
     * @return oilAmounts Array of OIL amounts for each NFT
     * @return maturityDates Array of maturity dates
     */
    function getUserBurnableNFTsFromCollection(
        address user,
        address collection
    ) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory oilAmounts,
        uint256[] memory maturityDates
    ) {
        if (!supportedCollections[collection]) {
            return (new uint256[](0), new uint256[](0), new uint256[](0));
        }
        
        IFCRNFTCollection nftCollection = IFCRNFTCollection(collection);
        uint256[] memory userTokens = nftCollection.getUserNFTs(user);
        
        // First pass: count eligible tokens
        uint256 eligibleCount = 0;
        for (uint256 i = 0; i < userTokens.length; i++) {
            (uint256 amount, bool eligible,) = calculateBurnValue(collection, userTokens[i]);
            if (eligible && amount > 0) {
                eligibleCount++;
            }
        }
        
        // Second pass: populate arrays
        tokenIds = new uint256[](eligibleCount);
        oilAmounts = new uint256[](eligibleCount);
        maturityDates = new uint256[](eligibleCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userTokens.length && index < eligibleCount; i++) {
            uint256 tokenId = userTokens[i];
            (uint256 amount, bool eligible,) = calculateBurnValue(collection, tokenId);
            
            if (eligible && amount > 0) {
                IFCRNFTCollection.FCRMetadata memory metadata = nftCollection.getFCRMetadata(tokenId);
                
                tokenIds[index] = tokenId;
                oilAmounts[index] = amount;
                maturityDates[index] = metadata.maturityDate;
                index++;
            }
        }
    }

    /**
     * @notice Get user's burned token history
     * @param user User address
     * @param collection Collection address (address(0) for all)
     * @return burnedTokenIds Array of burned token IDs
     */
    function getUserBurnHistory(
        address user,
        address collection
    ) external view returns (uint256[] memory burnedTokenIds) {
        if (collection != address(0)) {
            return userBurnedTokens[user][collection];
        }
        
        // Return empty array for all collections (would need additional tracking)
        return new uint256[](0);
    }

    /**
     * @notice Get comprehensive burn statistics
     * @return totalBurned Total NFTs burned
     * @return totalOil Total OIL tokens released
     * @return totalUSD Total USD value burned
     * @return avgOilPerBurn Average OIL per burn
     * @return activeCollections Number of active collections
     */
    function getBurnStatistics() external view returns (
        uint256 totalBurned,
        uint256 totalOil,
        uint256 totalUSD,
        uint256 avgOilPerBurn,
        uint256 activeCollections
    ) {
        totalBurned = totalNFTsBurned;
        totalOil = totalOILReleased;
        totalUSD = totalUSDValueBurned;
        avgOilPerBurn = totalBurned > 0 ? totalOil / totalBurned : 0;
        
        // Count active collections
        uint256 collectionCount = fcrFactory.getCollectionCount();
        for (uint256 i = 1; i <= collectionCount; i++) {
            (address collectionAddr,,,,,) = fcrFactory.getCollection(i);
            if (supportedCollections[collectionAddr] && collectionBurnCount[collectionAddr] > 0) {
                activeCollections++;
            }
        }
    }

    /**
     * @notice Get user burn statistics
     * @param user User address
     * @return totalBurned Total NFTs burned by user
     * @return totalOilClaimed Total OIL tokens claimed
     * @return lastBurnTime Last burn timestamp
     * @return avgOilPerBurn Average OIL per burn
     * @return hasGovernanceBonus Whether user gets governance bonus
     */
    function getUserBurnStats(address user) external view returns (
        uint256 totalBurned,
        uint256 totalOilClaimed,
        uint256 lastBurnTime,
        uint256 avgOilPerBurn,
        bool hasGovernanceBonus
    ) {
        totalBurned = userTotalBurned[user];
        totalOilClaimed = userTotalOilClaimed[user];
        lastBurnTime = userLastBurnTime[user];
        avgOilPerBurn = totalBurned > 0 ? totalOilClaimed / totalBurned : 0;
        hasGovernanceBonus = governanceNFT.balanceOf(user) > 0;
    }

    /**
     * @notice Get collection burn statistics
     * @param collection Collection address
     * @return info Collection burn information
     */
    function getCollectionBurnInfo(address collection) external view returns (
        CollectionInfo memory info
    ) {
        info = collectionInfo[collection];
        info.isSupported = supportedCollections[collection];
    }

    /**
     * @notice Check current governance bonus for a user
     * @param user User address
     * @return bonusPercent Bonus percentage (basis points)
     * @return governanceBalance User's governance NFT balance
     */
    function getUserGovernanceBonus(address user) external view returns (
        uint256 bonusPercent,
        uint256 governanceBalance
    ) {
        governanceBalance = governanceNFT.balanceOf(user);
        bonusPercent = governanceBalance > 0 ? GOVERNANCE_BONUS_PERCENT : 0;
    }

    // ========== Admin Functions ==========
    
    /**
     * @notice Add/remove support for an FCR collection
     * @param collection Collection address
     * @param supported Whether collection is supported
     */
    function setSupportedCollection(
        address collection,
        bool supported
    ) external onlyRole(ADMIN_ROLE) {
        if (!fcrFactory.isValidCollection(collection)) revert InvalidCollection();
        
        supportedCollections[collection] = supported;
        collectionInfo[collection].isSupported = supported;
        
        emit CollectionSupported(collection, supported);
    }

    /**
     * @notice Batch set supported collections
     * @param collections Array of collection addresses
     * @param supported Array of support status
     */
    function batchSetSupportedCollections(
        address[] calldata collections,
        bool[] calldata supported
    ) external onlyRole(ADMIN_ROLE) {
        if (collections.length != supported.length) revert InvalidAmount();
        
        for (uint256 i = 0; i < collections.length; i++) {
            if (fcrFactory.isValidCollection(collections[i])) {
                supportedCollections[collections[i]] = supported[i];
                collectionInfo[collections[i]].isSupported = supported[i];
                emit CollectionSupported(collections[i], supported[i]);
            }
        }
    }

    /**
     * @notice Emergency burn NFT (only when paused)
     * @param collection Collection address
     * @param tokenId Token ID
     */
    function emergencyBurn(
        address collection,
        uint256 tokenId
    ) external onlyRole(ADMIN_ROLE) whenPaused {
        IFCRNFTCollection nftCollection = IFCRNFTCollection(collection);
        
        address originalOwner = nftCollection.ownerOf(tokenId);
        nftCollection.markAsBurned(tokenId);
        
        emit EmergencyBurnExecuted(msg.sender, collection, tokenId, originalOwner);
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========== Utility Functions ==========
    
    /**
     * @dev Convert uint to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}
