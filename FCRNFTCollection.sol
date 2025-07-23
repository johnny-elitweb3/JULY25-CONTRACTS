// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ========== File 1: Interfaces.sol ==========

interface IEnhancedGovernanceNFT {
    struct FCRCollectionProposal {
        string collectionName;
        uint256 maxSupply;
        uint256 barrelPrice;
        uint256 yieldBonusPercent;
        uint256 lockupPeriod;
        address paymentToken;
        bool approved;
    }
    
    function isProposalApproved(uint256 proposalId) external view returns (bool);
    function getFCRProposal(uint256 proposalId) external view returns (FCRCollectionProposal memory);
}

interface IEnhancedPaymentManager {
    struct TokenConfig {
        bool accepted;
        address priceFeed;
        uint8 decimals;
        uint256 minAmount;
    }
    
    function processTokenPayment(address user, address token, uint256 amount) external returns (bool);
    function processETHPayment() external payable returns (bool);
    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function calculateTokenAmountFromUSD(address token, uint256 usdAmount) external view returns (uint256 tokenAmount, uint256 tokenPrice);
}

interface IFCRNFTCollection {
    function mintFCR(address to, uint256 usdAmount, uint256 tokenAmountPaid, address tokenUsed, string memory metadataURI) external returns (uint256);
    function totalSupply() external view returns (uint256);
}

// ========== File 2: FCRNFTCollection.sol ==========

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract FCRNFTCollection is ERC721Enumerable, ERC721URIStorage, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    uint256 private _tokenIdCounter = 1;
    
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
    
    mapping(uint256 => FCRMetadata) public nftMetadata;
    mapping(address => uint256[]) private userTokens;
    
    uint256 public immutable maxSupply;
    uint256 public immutable barrelPrice;
    uint256 public immutable yieldBonusPercent;
    uint256 public immutable lockupPeriod;
    address public immutable paymentToken;
    address public immutable factoryContract;
    uint256 public immutable proposalId;
    
    uint256 public totalBarrelsSold;
    uint256 public totalUSDCollected;
    
    event FCRMinted(address indexed to, uint256 indexed tokenId, uint256 barrels, uint256 usdValue);
    event NFTBurned(uint256 indexed tokenId, address indexed owner);
    
    error OnlyFactory();
    error MaxSupplyReached();
    error InvalidAmount();
    error TokenNotExist();
    error AlreadyBurned();
    
    modifier onlyFactory() {
        if (msg.sender != factoryContract) revert OnlyFactory();
        _;
    }
    
    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply,
        uint256 _barrelPrice,
        uint256 _yieldBonusPercent,
        uint256 _lockupPeriod,
        address _paymentToken,
        uint256 _proposalId
    ) ERC721(name, symbol) {
        maxSupply = _maxSupply;
        barrelPrice = _barrelPrice;
        yieldBonusPercent = _yieldBonusPercent;
        lockupPeriod = _lockupPeriod;
        paymentToken = _paymentToken;
        factoryContract = msg.sender;
        proposalId = _proposalId;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }
    
    function mintFCR(
        address to,
        uint256 usdAmount,
        uint256 tokenAmountPaid,
        address tokenUsed,
        string memory metadataURI
    ) external onlyFactory nonReentrant whenNotPaused returns (uint256) {
        if (totalSupply() >= maxSupply) revert MaxSupplyReached();
        if (usdAmount == 0) revert InvalidAmount();
        
        uint256 tokenId = _tokenIdCounter++;
        
        uint256 barrelsPurchased = usdAmount / barrelPrice;
        uint256 bonusBarrels = (barrelsPurchased * yieldBonusPercent) / 100;
        uint256 totalBarrels = barrelsPurchased + bonusBarrels;
        
        nftMetadata[tokenId] = FCRMetadata({
            barrelsPurchased: barrelsPurchased,
            bonusBarrels: bonusBarrels,
            totalBarrels: totalBarrels,
            usdValuePaid: usdAmount,
            purchaseDate: block.timestamp,
            maturityDate: block.timestamp + lockupPeriod,
            barrelPrice: barrelPrice,
            yieldBonusPercent: yieldBonusPercent,
            originalPurchaser: to,
            isBurned: false,
            paymentToken: tokenUsed,
            tokenAmountPaid: tokenAmountPaid
        });
        
        totalBarrelsSold += totalBarrels;
        totalUSDCollected += usdAmount;
        userTokens[to].push(tokenId);
        
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadataURI);
        
        emit FCRMinted(to, tokenId, totalBarrels, usdAmount);
        
        return tokenId;
    }
    
    function getUserNFTs(address user) external view returns (uint256[] memory) {
        return userTokens[user];
    }
    
    function isNFTMature(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotExist();
        return block.timestamp >= nftMetadata[tokenId].maturityDate;
    }
    
    function markAsBurned(uint256 tokenId) external onlyFactory {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotExist();
        if (nftMetadata[tokenId].isBurned) revert AlreadyBurned();
        
        nftMetadata[tokenId].isBurned = true;
        emit NFTBurned(tokenId, _ownerOf(tokenId));
    }
    
    function getFCRMetadata(uint256 tokenId) external view returns (FCRMetadata memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotExist();
        return nftMetadata[tokenId];
    }
    
    function _update(address to, uint256 tokenId, address auth) 
        internal 
        virtual 
        override(ERC721, ERC721Enumerable) 
        returns (address) 
    {
        address from = _ownerOf(tokenId);
        address previousOwner = super._update(to, tokenId, auth);
        
        if (from != address(0) && to != address(0) && from != to) {
            _removeTokenFromUser(from, tokenId);
            userTokens[to].push(tokenId);
        }
        
        return previousOwner;
    }
    
    function _removeTokenFromUser(address user, uint256 tokenId) private {
        uint256[] storage tokens = userTokens[user];
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (tokens[i] == tokenId) {
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
        }
    }
    
    function _increaseBalance(address account, uint128 value) 
        internal 
        virtual 
        override(ERC721, ERC721Enumerable) 
    {
        super._increaseBalance(account, value);
    }
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(ERC721Enumerable, ERC721URIStorage, AccessControl) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
    
    function tokenURI(uint256 tokenId) 
        public 
        view 
        virtual 
        override(ERC721, ERC721URIStorage) 
        returns (string memory) 
    {
        return super.tokenURI(tokenId);
    }
}

// ========== File 3: FCRFactory.sol ==========

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract FCRFactory is AccessControl, ReentrancyGuard, Pausable {
    using Strings for uint256;

    // Custom errors for gas efficiency
    error NotApproved();
    error AlreadyCreated();
    error TokenNotAccepted();
    error NotActive();
    error WrongPaymentMethod();
    error InsufficientReserve();
    error PaymentFailed();
    error ExceedsMaxToken();
    error InvalidCollection();
    error NoETH();
    error InvalidAddress();
    error MustSendETH();
    error DirectETHNotAllowed();

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant TOTAL_OIL_RESERVE = 25_000_000 * 1e18;
    
    uint256 private _collectionIdCounter = 1;
    
    struct CollectionCore {
        address contractAddress;
        string name;
        string symbol;
        uint256 proposalId;
        uint256 createdAt;
        bool isActive;
    }
    
    struct CollectionStats {
        uint256 totalMinted;
        uint256 totalUSDCollected;
        uint256 totalBarrelsReserved;
    }
    
    struct CollectionConfig {
        uint256 maxSupply;
        uint256 barrelPrice;
        uint256 yieldBonusPercent;
        uint256 lockupPeriod;
        address paymentToken;
    }
    
    mapping(uint256 => CollectionCore) public collectionCores;
    mapping(uint256 => CollectionStats) public collectionStats;
    mapping(uint256 => CollectionConfig) public collectionConfigs;
    mapping(address => bool) public isValidCollection;
    mapping(uint256 => uint256) public proposalToCollection;
    
    IEnhancedGovernanceNFT public governanceNFT;
    IEnhancedPaymentManager public paymentManager;
    address public stakingContract;
    address public oilReserveWallet;
    uint256 public reserveUtilization;
    
    string public baseURI = "https://api.petroleumclub.io/metadata/";
    
    event CollectionCreated(uint256 indexed id, address indexed addr, string name, uint256 proposalId);
    event FCRPurchased(address indexed buyer, address indexed collection, uint256 tokenId, uint256 usdAmount);
    event ReserveUpdated(address indexed oldReserve, address indexed newReserve);
    event ContractUpdated(string contractType, address indexed oldAddr, address indexed newAddr);
    
    constructor(
        address _governanceNFT,
        address _paymentManager,
        address _stakingContract,
        address _oilReserveWallet
    ) {
        if (_governanceNFT == address(0) || _paymentManager == address(0) || 
            _stakingContract == address(0) || _oilReserveWallet == address(0)) 
            revert InvalidAddress();
        
        governanceNFT = IEnhancedGovernanceNFT(_governanceNFT);
        paymentManager = IEnhancedPaymentManager(_paymentManager);
        stakingContract = _stakingContract;
        oilReserveWallet = _oilReserveWallet;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }
    
    function createFCRCollection(uint256 proposalId) 
        external 
        onlyRole(OPERATOR_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (uint256) 
    {
        if (!governanceNFT.isProposalApproved(proposalId)) revert NotApproved();
        if (proposalToCollection[proposalId] != 0) revert AlreadyCreated();
        
        IEnhancedGovernanceNFT.FCRCollectionProposal memory p = governanceNFT.getFCRProposal(proposalId);
        if (!p.approved) revert NotApproved();
        
        IEnhancedPaymentManager.TokenConfig memory tc = paymentManager.getTokenConfig(p.paymentToken);
        if (!tc.accepted) revert TokenNotAccepted();
        
        uint256 id = _collectionIdCounter++;
        
        FCRNFTCollection collection = new FCRNFTCollection(
            p.collectionName,
            string.concat("FCR", id.toString()),
            p.maxSupply,
            p.barrelPrice,
            p.yieldBonusPercent,
            p.lockupPeriod,
            p.paymentToken,
            proposalId
        );
        
        address addr = address(collection);
        
        collectionCores[id] = CollectionCore({
            contractAddress: addr,
            name: p.collectionName,
            symbol: string.concat("FCR", id.toString()),
            proposalId: proposalId,
            createdAt: block.timestamp,
            isActive: true
        });
        
        collectionConfigs[id] = CollectionConfig({
            maxSupply: p.maxSupply,
            barrelPrice: p.barrelPrice,
            yieldBonusPercent: p.yieldBonusPercent,
            lockupPeriod: p.lockupPeriod,
            paymentToken: p.paymentToken
        });
        
        isValidCollection[addr] = true;
        proposalToCollection[proposalId] = id;
        
        emit CollectionCreated(id, addr, p.collectionName, proposalId);
        
        return id;
    }
    
    function purchaseFCRWithETH(uint256 cId, uint256 usdAmt) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        returns (uint256) 
    {
        if (msg.value == 0) revert MustSendETH();
        
        CollectionCore memory core = collectionCores[cId];
        CollectionConfig memory cfg = collectionConfigs[cId];
        
        if (!core.isActive) revert NotActive();
        if (cfg.paymentToken != ETH_ADDRESS) revert WrongPaymentMethod();
        
        uint256 barrels = _calcBarrels(usdAmt, cfg.barrelPrice, cfg.yieldBonusPercent);
        if (reserveUtilization + barrels > TOTAL_OIL_RESERVE) revert InsufficientReserve();
        
        (bool ok,) = address(paymentManager).call{value: msg.value}(
            abi.encodeWithSelector(IEnhancedPaymentManager.processETHPayment.selector)
        );
        if (!ok) revert PaymentFailed();
        
        uint256 tokenId = _mint(core.contractAddress, msg.sender, usdAmt, msg.value, cfg.paymentToken, cId);
        
        _updateStats(cId, usdAmt, barrels);
        
        emit FCRPurchased(msg.sender, core.contractAddress, tokenId, usdAmt);
        
        return tokenId;
    }
    
    function purchaseFCRWithToken(uint256 cId, uint256 usdAmt, uint256 maxTokenAmt) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256) 
    {
        CollectionCore memory core = collectionCores[cId];
        CollectionConfig memory cfg = collectionConfigs[cId];
        
        if (!core.isActive) revert NotActive();
        if (cfg.paymentToken == ETH_ADDRESS) revert WrongPaymentMethod();
        
        uint256 barrels = _calcBarrels(usdAmt, cfg.barrelPrice, cfg.yieldBonusPercent);
        if (reserveUtilization + barrels > TOTAL_OIL_RESERVE) revert InsufficientReserve();
        
        (uint256 tokenAmt,) = paymentManager.calculateTokenAmountFromUSD(cfg.paymentToken, usdAmt);
        if (tokenAmt > maxTokenAmt) revert ExceedsMaxToken();
        
        if (!paymentManager.processTokenPayment(msg.sender, cfg.paymentToken, tokenAmt)) 
            revert PaymentFailed();
        
        uint256 tokenId = _mint(core.contractAddress, msg.sender, usdAmt, tokenAmt, cfg.paymentToken, cId);
        
        _updateStats(cId, usdAmt, barrels);
        
        emit FCRPurchased(msg.sender, core.contractAddress, tokenId, usdAmt);
        
        return tokenId;
    }
    
    function _mint(
        address coll,
        address to,
        uint256 usdAmt,
        uint256 tokenAmt,
        address pToken,
        uint256 cId
    ) private returns (uint256) {
        IFCRNFTCollection c = IFCRNFTCollection(coll);
        string memory uri = string.concat(
            baseURI,
            "c/",
            cId.toString(),
            "/t/",
            (c.totalSupply() + 1).toString(),
            ".json"
        );
        
        return c.mintFCR(to, usdAmt, tokenAmt, pToken, uri);
    }
    
    function _updateStats(uint256 cId, uint256 usdAmt, uint256 barrels) private {
        CollectionStats storage s = collectionStats[cId];
        s.totalMinted++;
        s.totalUSDCollected += usdAmt;
        s.totalBarrelsReserved += barrels;
        reserveUtilization += barrels;
    }
    
    function _calcBarrels(uint256 usdAmt, uint256 price, uint256 bonus) 
        private 
        pure 
        returns (uint256) 
    {
        uint256 b = usdAmt / price;
        return b + (b * bonus / 100);
    }
    
    // View functions
    function getCollection(uint256 id) external view returns (
        CollectionCore memory core,
        CollectionConfig memory config,
        CollectionStats memory stats
    ) {
        return (collectionCores[id], collectionConfigs[id], collectionStats[id]);
    }
    
    function getCollectionByProposal(uint256 pId) external view returns (uint256) {
        return proposalToCollection[pId];
    }
    
    function getPurchaseQuote(uint256 cId, uint256 usdAmt) external view returns (
        uint256 barrelsPurchased,
        uint256 bonusBarrels,
        uint256 totalBarrels,
        uint256 tokenAmountNeeded,
        bool reserveAvailable
    ) {
        CollectionConfig memory cfg = collectionConfigs[cId];
        if (collectionCores[cId].contractAddress == address(0)) revert InvalidCollection();
        
        barrelsPurchased = usdAmt / cfg.barrelPrice;
        bonusBarrels = barrelsPurchased * cfg.yieldBonusPercent / 100;
        totalBarrels = barrelsPurchased + bonusBarrels;
        reserveAvailable = (reserveUtilization + totalBarrels <= TOTAL_OIL_RESERVE);
        
        if (cfg.paymentToken != ETH_ADDRESS) {
            (tokenAmountNeeded,) = paymentManager.calculateTokenAmountFromUSD(cfg.paymentToken, usdAmt);
        }
    }
    
    function getReserveStats() external view returns (
        uint256 total,
        uint256 utilized,
        uint256 available,
        uint256 utilizationPercent
    ) {
        total = TOTAL_OIL_RESERVE;
        utilized = reserveUtilization;
        available = TOTAL_OIL_RESERVE - reserveUtilization;
        utilizationPercent = utilized * 10000 / TOTAL_OIL_RESERVE;
    }
    
    function getCollectionCount() external view returns (uint256) {
        return _collectionIdCounter - 1;
    }
    
    // Admin functions
    function setCollectionActive(uint256 id, bool active) external onlyRole(ADMIN_ROLE) {
        if (collectionCores[id].contractAddress == address(0)) revert InvalidCollection();
        collectionCores[id].isActive = active;
    }
    
    function setGovernanceNFT(address addr) external onlyRole(ADMIN_ROLE) {
        if (addr == address(0)) revert InvalidAddress();
        address old = address(governanceNFT);
        governanceNFT = IEnhancedGovernanceNFT(addr);
        emit ContractUpdated("GovernanceNFT", old, addr);
    }
    
    function setPaymentManager(address addr) external onlyRole(ADMIN_ROLE) {
        if (addr == address(0)) revert InvalidAddress();
        address old = address(paymentManager);
        paymentManager = IEnhancedPaymentManager(addr);
        emit ContractUpdated("PaymentManager", old, addr);
    }
    
    function setStakingContract(address addr) external onlyRole(ADMIN_ROLE) {
        if (addr == address(0)) revert InvalidAddress();
        address old = stakingContract;
        stakingContract = addr;
        emit ContractUpdated("StakingContract", old, addr);
    }
    
    function setOilReserveWallet(address addr) external onlyRole(ADMIN_ROLE) {
        if (addr == address(0)) revert InvalidAddress();
        address old = oilReserveWallet;
        oilReserveWallet = addr;
        emit ReserveUpdated(old, addr);
    }
    
    function setBaseURI(string memory uri) external onlyRole(ADMIN_ROLE) {
        baseURI = uri;
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    function emergencyWithdrawETH() external onlyRole(ADMIN_ROLE) whenPaused {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NoETH();
        
        (bool ok, ) = msg.sender.call{value: bal}("");
        require(ok, "ETH withdrawal failed");
    }
    
    receive() external payable {
        revert DirectETHNotAllowed();
    }
}
