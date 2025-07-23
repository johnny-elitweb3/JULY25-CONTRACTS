// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ========== Interfaces ==========

/**
 * @title IFCRNFTCollection Interface
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
}

/**
 * @title IFCRFactory Interface
 */
interface IFCRFactory {
    function isValidCollection(address collection) external view returns (bool);
}

/**
 * @title IEnhancedGovernanceNFT Interface
 */
interface IEnhancedGovernanceNFT {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// ========== OIL Token Contract ==========

/**
 * @title OILToken
 * @dev ERC20 token representing oil barrels with burn/mint capabilities
 * @notice Each token represents 1 barrel of oil
 */
contract OILToken is ERC20, ERC20Burnable, ERC20Permit, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ========== Custom Errors ==========
    error InvalidAddress();
    error ExceedsMaxSupply();
    error InsufficientBalance();
    error UnauthorizedMinter();
    error InvalidAmount();

    // ========== Constants ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B tokens max
    uint8 private constant DECIMALS = 18;

    // ========== State Variables ==========
    uint256 public totalMinted;
    uint256 public totalBurned;
    
    mapping(address => bool) public authorizedMinters;
    mapping(address => uint256) public minterAllowance;

    // ========== Events ==========
    event TokensMinted(address indexed to, uint256 amount, address indexed minter);
    event TokensBurned(address indexed from, uint256 amount, address indexed burner);
    event MinterAuthorized(address indexed minter, uint256 allowance);
    event MinterDeauthorized(address indexed minter);
    event MinterAllowanceUpdated(address indexed minter, uint256 newAllowance);

    // ========== Constructor ==========
    constructor(
        string memory name,
        string memory symbol,
        address admin
    ) ERC20(name, symbol) ERC20Permit(name) {
        if (admin == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    // ========== Minting Functions ==========
    
    /**
     * @notice Mint tokens to an address (only authorized minters)
     * @param to Recipient address
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        
        // Check minter allowance
        if (minterAllowance[msg.sender] > 0) {
            if (amount > minterAllowance[msg.sender]) revert InsufficientBalance();
            minterAllowance[msg.sender] -= amount;
        }
        
        totalMinted += amount;
        _mint(to, amount);
        
        emit TokensMinted(to, amount, msg.sender);
    }

    /**
     * @notice Batch mint to multiple addresses
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts for each recipient
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (recipients.length != amounts.length) revert InvalidAmount();
        if (recipients.length == 0) revert InvalidAmount();
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        if (totalSupply() + totalAmount > MAX_SUPPLY) revert ExceedsMaxSupply();
        
        // Check minter allowance
        if (minterAllowance[msg.sender] > 0) {
            if (totalAmount > minterAllowance[msg.sender]) revert InsufficientBalance();
            minterAllowance[msg.sender] -= totalAmount;
        }
        
        totalMinted += totalAmount;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert InvalidAddress();
            if (amounts[i] == 0) continue;
            
            _mint(recipients[i], amounts[i]);
            emit TokensMinted(recipients[i], amounts[i], msg.sender);
        }
    }

    // ========== Burning Functions ==========
    
    /**
     * @notice Burn tokens from an address (only authorized burners)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) public override {
        if (!hasRole(BURNER_ROLE, msg.sender)) {
            // Standard ERC20 burnFrom with allowance check
            super.burnFrom(from, amount);
        } else {
            // Authorized burner can burn without allowance
            if (balanceOf(from) < amount) revert InsufficientBalance();
            _burn(from, amount);
        }
        
        totalBurned += amount;
        emit TokensBurned(from, amount, msg.sender);
    }

    /**
     * @notice Burn own tokens
     * @param amount Amount to burn
     */
    function burn(uint256 amount) public override {
        super.burn(amount);
        totalBurned += amount;
        emit TokensBurned(msg.sender, amount, msg.sender);
    }

    // ========== Admin Functions ==========
    
    /**
     * @notice Authorize a minter with allowance
     * @param minter Address to authorize
     * @param allowance Maximum tokens they can mint (0 = unlimited)
     */
    function authorizeMinter(address minter, uint256 allowance) external onlyRole(ADMIN_ROLE) {
        if (minter == address(0)) revert InvalidAddress();
        
        _grantRole(MINTER_ROLE, minter);
        authorizedMinters[minter] = true;
        minterAllowance[minter] = allowance;
        
        emit MinterAuthorized(minter, allowance);
    }

    /**
     * @notice Deauthorize a minter
     * @param minter Address to deauthorize
     */
    function deauthorizeMinter(address minter) external onlyRole(ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
        authorizedMinters[minter] = false;
        minterAllowance[minter] = 0;
        
        emit MinterDeauthorized(minter);
    }

    /**
     * @notice Update minter allowance
     * @param minter Minter address
     * @param newAllowance New allowance (0 = unlimited)
     */
    function updateMinterAllowance(address minter, uint256 newAllowance) external onlyRole(ADMIN_ROLE) {
        if (!authorizedMinters[minter]) revert UnauthorizedMinter();
        
        minterAllowance[minter] = newAllowance;
        emit MinterAllowanceUpdated(minter, newAllowance);
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

    // ========== View Functions ==========
    
    /**
     * @notice Get circulating supply (total supply minus burned)
     * @return Circulating supply
     */
    function circulatingSupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Get minting statistics
     * @return totalMinted_ Total tokens ever minted
     * @return totalBurned_ Total tokens ever burned
     * @return remainingSupply Remaining mintable supply
     */
    function getMintingStats() external view returns (
        uint256 totalMinted_,
        uint256 totalBurned_,
        uint256 remainingSupply
    ) {
        totalMinted_ = totalMinted;
        totalBurned_ = totalBurned;
        remainingSupply = MAX_SUPPLY - totalSupply();
    }

    /**
     * @notice Check if address is authorized minter
     * @param account Address to check
     * @return authorized Whether address is authorized
     * @return allowance Minting allowance (0 = unlimited)
     */
    function getMinterInfo(address account) external view returns (
        bool authorized,
        uint256 allowance
    ) {
        authorized = authorizedMinters[account];
        allowance = minterAllowance[account];
    }

    // ========== Overrides ==========
    
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}
