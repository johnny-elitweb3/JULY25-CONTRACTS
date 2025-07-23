// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title OilCertificate
 * @author OIL Protocol
 * @notice ERC721 NFT representing OIL purchase certificates with maturity dates
 * @dev Each NFT contains purchase data and can only be minted by TradeDesk contract
 */
contract OilCertificate is 
    ERC721,
    ERC721Enumerable,
    ERC721URIStorage,
    ERC721Burnable,
    ReentrancyGuard,
    Pausable,
    Ownable(msg.sender)
{
    using Strings for uint256;

    // ==================== State Variables ====================
    
    uint256 private _nextTokenId = 1; // Start token IDs at 1
    address public tradeDeskContract;
    string public baseTokenURI;
    
    // Certificate data storage
    mapping(uint256 => Certificate) private certificates;
    
    // User tracking
    mapping(address => uint256[]) private userCertificates;
    mapping(uint256 => uint256) private userCertificateIndex;
    
    // Offer tracking
    mapping(uint256 => uint256[]) private offerCertificates;
    
    // ==================== Structs ====================
    
    struct Certificate {
        uint256 offerId;
        uint256 barrelsPurchased;
        uint256 bonusBarrels;
        uint256 purchaseDate;
        uint256 maturityDate;
        bool isRedeemed;
    }
    
    // ==================== Events ====================
    
    event CertificateMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 indexed offerId,
        uint256 barrels,
        uint256 bonus,
        uint256 maturityDate
    );
    
    event CertificateBurned(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 offerId,
        uint256 totalBarrels
    );
    
    event TradeDeskUpdated(address indexed oldAddress, address indexed newAddress);
    event BaseURIUpdated(string newBaseURI);
    
    // ==================== Errors ====================
    
    error OnlyTradeDesk();
    error ZeroAddress();
    error CertificateNotFound();
    error InvalidTokenId();
    
    // ==================== Modifiers ====================
    
    modifier onlyTradeDesk() {
        if (msg.sender != tradeDeskContract) revert OnlyTradeDesk();
        _;
    }
    
    // ==================== Constructor ====================
    
    /**
     * @notice Initialize the OilCertificate NFT contract
     * @param _name NFT collection name
     * @param _symbol NFT collection symbol
     * @param _initialBaseURI Base URI for token metadata
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _initialBaseURI
    ) ERC721(_name, _symbol) {
        baseTokenURI = _initialBaseURI;
    }
    
    // ==================== Admin Functions ====================
    
    /**
     * @notice Set the TradeDesk contract address
     * @param _tradeDeskContract Address of the TradeDesk contract
     */
    function setTradeDeskContract(address _tradeDeskContract) external onlyOwner {
        if (_tradeDeskContract == address(0)) revert ZeroAddress();
        address oldAddress = tradeDeskContract;
        tradeDeskContract = _tradeDeskContract;
        emit TradeDeskUpdated(oldAddress, _tradeDeskContract);
    }
    
    /**
     * @notice Update base URI for token metadata
     * @param _newBaseURI New base URI
     */
    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        baseTokenURI = _newBaseURI;
        emit BaseURIUpdated(_newBaseURI);
    }
    
    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ==================== TradeDesk Functions ====================
    
    /**
     * @notice Mint a new certificate NFT (only callable by TradeDesk)
     * @param to Recipient address
     * @param offerId The offer ID this certificate belongs to
     * @param barrels Number of barrels purchased
     * @param bonus Bonus barrels to be received at maturity
     * @param maturityDate Unix timestamp when certificate matures
     * @return tokenId The minted token ID
     */
    function mintCertificate(
        address to,
        uint256 offerId,
        uint256 barrels,
        uint256 bonus,
        uint256 maturityDate
    ) external onlyTradeDesk nonReentrant whenNotPaused returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        
        uint256 tokenId = _nextTokenId++;
        
        // Store certificate data
        certificates[tokenId] = Certificate({
            offerId: offerId,
            barrelsPurchased: barrels,
            bonusBarrels: bonus,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            isRedeemed: false
        });
        
        // Update offer tracking
        offerCertificates[offerId].push(tokenId);
        
        // Mint NFT (user tracking handled in _update)
        _safeMint(to, tokenId);
        
        emit CertificateMinted(tokenId, to, offerId, barrels, bonus, maturityDate);
        
        return tokenId;
    }
    
    /**
     * @notice Burn a certificate upon redemption (only callable by TradeDesk)
     * @param tokenId The certificate to burn
     * @dev User tracking removal is handled separately since _update isn't called on burn
     */
    function burnCertificate(uint256 tokenId) external onlyTradeDesk nonReentrant {
        // ownerOf will revert if token doesn't exist
        address owner = ownerOf(tokenId);
        
        Certificate storage cert = certificates[tokenId];
        cert.isRedeemed = true;
        
        // Remove from user's certificate list
        uint256 lastIndex = userCertificates[owner].length - 1;
        uint256 tokenIndex = userCertificateIndex[tokenId];
        
        if (tokenIndex != lastIndex) {
            uint256 lastTokenId = userCertificates[owner][lastIndex];
            userCertificates[owner][tokenIndex] = lastTokenId;
            userCertificateIndex[lastTokenId] = tokenIndex;
        }
        
        userCertificates[owner].pop();
        delete userCertificateIndex[tokenId];
        
        emit CertificateBurned(
            tokenId, 
            owner, 
            cert.offerId, 
            cert.barrelsPurchased + cert.bonusBarrels
        );
        
        _burn(tokenId);
    }
    
    // ==================== View Functions ====================
    
    /**
     * @notice Get complete certificate data
     * @param tokenId The certificate to query
     * @return offerId The offer this certificate belongs to
     * @return barrelsPurchased Number of barrels purchased
     * @return bonusBarrels Bonus barrels at maturity
     * @return purchaseDate When the purchase was made
     * @return maturityDate When the certificate matures
     * @return isRedeemed Whether the certificate has been redeemed
     */
    function getCertificateData(uint256 tokenId) 
        external 
        view 
        returns (
            uint256 offerId,
            uint256 barrelsPurchased,
            uint256 bonusBarrels,
            uint256 purchaseDate,
            uint256 maturityDate,
            bool isRedeemed
        ) 
    {
        // Check if certificate exists by checking if it has data
        Certificate memory cert = certificates[tokenId];
        if (cert.purchaseDate == 0 && !cert.isRedeemed) {
            revert CertificateNotFound();
        }
        
        return (
            cert.offerId,
            cert.barrelsPurchased,
            cert.bonusBarrels,
            cert.purchaseDate,
            cert.maturityDate,
            cert.isRedeemed
        );
    }
    
    /**
     * @notice Get all certificate IDs owned by a user
     * @param user The user address to query
     * @return Array of token IDs
     */
    function getUserCertificates(address user) external view returns (uint256[] memory) {
        return userCertificates[user];
    }
    
    /**
     * @notice Get all active (non-redeemed) certificates for a user
     * @param user The user address to query
     * @return tokenIds Array of active certificate token IDs
     */
    function getActiveCertificates(address user) external view returns (uint256[] memory) {
        uint256[] memory allCerts = userCertificates[user];
        uint256 activeCount = 0;
        
        // Count active certificates
        for (uint256 i = 0; i < allCerts.length; i++) {
            if (!certificates[allCerts[i]].isRedeemed) {
                activeCount++;
            }
        }
        
        // Build active certificates array
        uint256[] memory activeCerts = new uint256[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allCerts.length; i++) {
            if (!certificates[allCerts[i]].isRedeemed) {
                activeCerts[currentIndex] = allCerts[i];
                currentIndex++;
            }
        }
        
        return activeCerts;
    }
    
    /**
     * @notice Get all certificate IDs for a specific offer
     * @param offerId The offer to query
     * @return Array of token IDs
     */
    function getOfferCertificates(uint256 offerId) external view returns (uint256[] memory) {
        return offerCertificates[offerId];
    }
    
    /**
     * @notice Check if a certificate is matured
     * @param tokenId The certificate to check
     * @return Whether the certificate is matured
     */
    function isCertificateMatured(uint256 tokenId) external view returns (bool) {
        if (certificates[tokenId].purchaseDate == 0) revert CertificateNotFound();
        return block.timestamp >= certificates[tokenId].maturityDate;
    }
    
    /**
     * @notice Get time until maturity
     * @param tokenId The certificate to check
     * @return Seconds until maturity (0 if already matured)
     */
    function getTimeUntilMaturity(uint256 tokenId) external view returns (uint256) {
        if (certificates[tokenId].purchaseDate == 0) revert CertificateNotFound();
        uint256 maturityDate = certificates[tokenId].maturityDate;
        if (block.timestamp >= maturityDate) {
            return 0;
        }
        return maturityDate - block.timestamp;
    }
    
    /**
     * @notice Calculate total barrels for a certificate (purchased + bonus)
     * @param tokenId The certificate to calculate for
     * @return Total barrels claimable at maturity
     */
    function getTotalBarrels(uint256 tokenId) external view returns (uint256) {
        Certificate memory cert = certificates[tokenId];
        if (cert.purchaseDate == 0) revert CertificateNotFound();
        return cert.barrelsPurchased + cert.bonusBarrels;
    }
    
    /**
     * @notice Get the next token ID that will be minted
     * @return The next token ID
     */
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }
    
    /**
     * @notice Get certificate data for multiple tokens in one call
     * @param tokenIds Array of token IDs to query
     * @return certificates Array of certificate data
     */
    function getCertificatesData(uint256[] calldata tokenIds) 
        external 
        view 
        returns (Certificate[] memory) 
    {
        Certificate[] memory result = new Certificate[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (certificates[tokenIds[i]].purchaseDate == 0 && !certificates[tokenIds[i]].isRedeemed) {
                revert CertificateNotFound();
            }
            result[i] = certificates[tokenIds[i]];
        }
        return result;
    }
    
    // ==================== URI Functions ====================
    
    /**
     * @dev Base URI for computing tokenURI
     */
    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }
    
    /**
     * @notice Get metadata URI for a token
     * @param tokenId The token to get URI for
     */
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override(ERC721, ERC721URIStorage) 
        returns (string memory) 
    {
        // This will revert if token doesn't exist
        _requireOwned(tokenId);
        
        string memory baseURI = _baseURI();
        Certificate memory cert = certificates[tokenId];
        
        // If there's a specific URI set, use it
        string memory _tokenURI = super.tokenURI(tokenId);
        if (bytes(_tokenURI).length > 0) {
            return _tokenURI;
        }
        
        // Otherwise, construct from base URI and include offer ID for grouping
        return bytes(baseURI).length > 0
            ? string(abi.encodePacked(baseURI, "offer/", cert.offerId.toString(), "/", tokenId.toString(), ".json"))
            : "";
    }
    
    // ==================== Transfer Control ====================
    
    /**
     * @dev Hook that is called before any token transfer
     * @notice Certificates can only be transferred when not paused
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused returns (address) {
        // Call parent _update and get the previous owner
        address from = super._update(to, tokenId, auth);
        
        // Update user tracking on transfer
        if (from != address(0) && to != address(0) && from != to) {
            // Transfer: Remove from sender's list
            uint256 lastIndex = userCertificates[from].length - 1;
            uint256 tokenIndex = userCertificateIndex[tokenId];
            
            if (tokenIndex != lastIndex) {
                uint256 lastTokenId = userCertificates[from][lastIndex];
                userCertificates[from][tokenIndex] = lastTokenId;
                userCertificateIndex[lastTokenId] = tokenIndex;
            }
            
            userCertificates[from].pop();
            delete userCertificateIndex[tokenId];
            
            // Add to receiver's list
            userCertificates[to].push(tokenId);
            userCertificateIndex[tokenId] = userCertificates[to].length - 1;
        } else if (from == address(0) && to != address(0)) {
            // Minting: Add to receiver's list
            userCertificates[to].push(tokenId);
            userCertificateIndex[tokenId] = userCertificates[to].length - 1;
        }
        // Note: Burning is handled in burnCertificate function
        
        return from;
    }
    
    // ==================== Required Overrides ====================
    
    function _increaseBalance(address account, uint128 value) 
        internal 
        override(ERC721, ERC721Enumerable) 
    {
        super._increaseBalance(account, value);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
