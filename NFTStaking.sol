// SPDX-License-Identifier: MIT LICENSE
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Minimal interface for the NFT collection we are staking.
 *      Must support `ownerOf`, `transferFrom`, and `totalSupply`.
 */
interface ICollection {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title EnhancedNFTStaking
 * @dev A secure multi-vault NFT staking system with configurable daily reward rates.
 * This is an enhanced version of the original NFTStaking contract with improved
 * security features, gas optimizations, and resolved vulnerabilities.
 *
 * Each vault is defined by:
 *   - An NFT contract (ICollection)
 *   - A reward token (IERC20)
 *   - A daily reward rate (rewardRate)
 *   - Active/inactive status
 *   - A record of total staked
 *   - Maximum reward rate cap
 *
 * Vault tokens are intended solely for rewarding stakers. If an administrator
 * needs to reclaim tokens (e.g., accidental overfunding), a rescue function is
 * provided (restricted to the contract deployer by default).
 */
contract EnhancedNFTStaking is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========== Errors ==========
    error InvalidVaultId();
    error NotTokenOwner();
    error AlreadyStaked();
    error EmptyTokenArray();
    error BatchTooLarge();
    error DirectTransferNotAllowed();
    error ZeroAddress();
    error InactiveVault();
    error InvalidTokenId();
    error InsufficientRewardBalance();
    error ZeroAmount();
    error ExceedsMaxRewardRate();
    error InvalidPaginationParams();
    error TokenIdTooLarge();

    // ========== Roles ==========
    // Typically, the deployer has DEFAULT_ADMIN_ROLE.
    // MANAGER_ROLE can be granted to other addresses for vault mgmt & specialized tasks.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ========== Constants ==========
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 public constant MAX_TOKEN_ID = type(uint32).max; // 2^32 - 1, safe buffer
    uint256 public constant MAX_REWARD_RATE = 1000 * 1e18; // Maximum daily reward rate per NFT
    uint256 public constant REWARD_PRECISION = 1e18; // Precision factor for rewards
    uint256 public constant SECONDS_IN_DAY = 86400;

    // ========== Structs ==========
    /**
     * @dev Configuration for each "vault" where NFTs can be staked and earn rewards.
     * @param nft           The NFT collection contract
     * @param token         The ERC20 reward token
     * @param name          A descriptive name for front-end use
     * @param rewardRate    Daily reward rate in `token` per NFT (tokens/day/NFT)
     * @param isActive      Whether this vault is currently accepting stakes
     * @param totalStaked   How many NFTs are currently staked in this vault
     * @param lastUpdated   Last time the vault was updated
     */
    struct VaultInfo {
        ICollection nft;
        IERC20 token;
        string name;
        uint256 rewardRate; 
        bool isActive;
        uint256 totalStaked;
        uint256 lastUpdated;
    }

    /**
     * @dev Records an NFT stake.
     * @param tokenId    ID of the NFT staked
     * @param timestamp  When it was staked (used for reward calculations)
     * @param owner      Who staked this NFT
     * @param vaultId    Which vault the NFT is staked in
     */
    struct Stake {
        uint32 tokenId;
        uint64 timestamp;
        address owner;
        uint32 vaultId;
    }

    // ========== State Variables ==========

    // List of configured vaults. You can add more vaults post-deployment.
    VaultInfo[] public vaults;

    // Mapping from tokenId => stake details.
    mapping(uint256 => Stake) public stakes;

    // Double mapping to track staked tokens per user per vault
    // (user => (vaultId => array of token IDs))
    mapping(address => mapping(uint256 => uint256[])) private userStakedTokens;

    // Mapping of (user => (vaultId => count of staked tokens)).
    mapping(address => mapping(uint256 => uint256)) public userStakeCount;

    // ========== Events ==========
    event VaultAdded(uint256 indexed vaultId, address nft, address rewardToken, string name, uint256 rewardRate);
    event VaultUpdated(uint256 indexed vaultId, uint256 rewardRate, bool isActive);
    event VaultStatusUpdated(uint256 indexed vaultId, bool isActive);
    event RewardRateUpdated(uint256 indexed vaultId, uint256 previousRate, uint256 newRate);

    event NFTStaked(address indexed owner, uint256 indexed vaultId, uint256 tokenId, uint256 timestamp);
    event NFTUnstaked(address indexed owner, uint256 indexed vaultId, uint256 tokenId, uint256 timestamp);
    event BatchNFTStaked(address indexed owner, uint256 indexed vaultId, uint256 count, uint256 timestamp);
    event BatchNFTUnstaked(address indexed owner, uint256 indexed vaultId, uint256 count, uint256 timestamp);

    event RewardsClaimed(address indexed owner, uint256 indexed vaultId, uint256 amount);
    event VaultFunded(uint256 indexed vaultId, address indexed from, uint256 amount);

    // For administrative rescue of erroneously sent tokens.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev Constructor grants `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE` to the deployer.
     *      Optionally, you can add initial vaults here or remove them if you prefer to add externally.
     *
     * @param _nftCollection  The NFT Collection address
     * @param _rewardToken1   The first reward token address
     * @param _rewardToken2   The second reward token address
     */
    constructor(
        address _nftCollection,   
        address _rewardToken1,      
        address _rewardToken2       
    ) {
        if (_nftCollection == address(0) || _rewardToken1 == address(0) || _rewardToken2 == address(0)) revert ZeroAddress();

        // Grant admin + manager roles to contract deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        // Add initial vaults
        _addVault(
            ICollection(_nftCollection),
            IERC20(_rewardToken1),
            "NFT - Reward Token 1 Vault (8% APR)", 
            8 * REWARD_PRECISION / 365 // Daily reward rate for 8% APR
        );

        _addVault(
            ICollection(_nftCollection),
            IERC20(_rewardToken2),
            "NFT - Reward Token 2 Vault (20% APR)",
            20 * REWARD_PRECISION / 365 // Daily reward rate for 20% APR
        );
    }

    // ======================
    //   Vault Management
    // ======================

    /**
     * @dev Internal helper to add a new vault. 
     *      Reverts if addresses are zero, vault data is invalid, or reward rate is too high.
     */
    function _addVault(
        ICollection _nft,
        IERC20 _token,
        string memory _name,
        uint256 _rewardRate
    ) internal {
        if (address(_nft) == address(0) || address(_token) == address(0)) revert ZeroAddress();
        if (_rewardRate > MAX_REWARD_RATE) revert ExceedsMaxRewardRate();
        
        vaults.push(VaultInfo({
            nft: _nft,
            token: _token,
            name: _name,
            rewardRate: _rewardRate,
            isActive: true,
            totalStaked: 0,
            lastUpdated: block.timestamp
        }));
        
        uint256 vaultId = vaults.length - 1;
        emit VaultAdded(vaultId, address(_nft), address(_token), _name, _rewardRate);
    }

    /**
     * @dev Public function to add a vault if not adding them in constructor.
     *      Only callable by addresses with the MANAGER_ROLE.
     */
    function addVault(
        ICollection _nft,
        IERC20 _token,
        string calldata _name,
        uint256 _rewardRate
    ) external onlyRole(MANAGER_ROLE) {
        _addVault(_nft, _token, _name, _rewardRate);
    }

    /**
     * @dev Returns vault information by ID.
     * @notice Provides vault data plus the current token balance in this contract for that vault.
     */
    function getVaultInfo(uint256 _vaultId)
        external
        view
        returns (
            address nft,
            address rewardToken,
            string memory name,
            uint256 rewardRate,
            bool isActive,
            uint256 totalStaked,
            uint256 vaultBalance
        )
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        VaultInfo storage vault = vaults[_vaultId];
        vaultBalance = vault.token.balanceOf(address(this));
        return (
            address(vault.nft),
            address(vault.token),
            vault.name,
            vault.rewardRate,
            vault.isActive,
            vault.totalStaked,
            vaultBalance
        );
    }

    /**
     * @dev Set vault active/inactive status (e.g., to pause new stakes in that vault).
     */
    function setVaultStatus(uint256 _vaultId, bool _isActive)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        
        if (vaults[_vaultId].isActive != _isActive) {
            vaults[_vaultId].isActive = _isActive;
            emit VaultStatusUpdated(_vaultId, _isActive);
        }
    }

    /**
     * @dev Update the daily reward rate for a vault.
     *      E.g., adjusting APR or daily distribution.
     *      Enforces a maximum reward rate to prevent economic attacks.
     */
    function updateRewardRate(uint256 _vaultId, uint256 _newRate)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        if (_newRate > MAX_REWARD_RATE) revert ExceedsMaxRewardRate();
        
        uint256 previousRate = vaults[_vaultId].rewardRate;
        if (previousRate != _newRate) {
            vaults[_vaultId].rewardRate = _newRate;
            emit RewardRateUpdated(_vaultId, previousRate, _newRate);
        }
    }

    /**
     * @dev Fund a vault by transferring reward tokens from caller to the contract.
     *      Caller must have approved this contract beforehand (vault.token.approve).
     */
    function fundVault(uint256 _vaultId, uint256 _amount) external {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        if (_amount == 0) revert ZeroAmount();
        
        VaultInfo storage vault = vaults[_vaultId];
        vault.token.safeTransferFrom(msg.sender, address(this), _amount);
        emit VaultFunded(_vaultId, msg.sender, _amount);
    }

    // ======================
    //    Staking Logic
    // ======================

    /**
     * @dev Stakes NFTs in a specified vault.
     *      Reverts if vault is inactive or any NFT is already staked.
     * @param _vaultId The vault ID
     * @param tokenIds Array of token IDs to stake
     */
    function stake(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        if (tokenIds.length == 0) revert EmptyTokenArray();
        if (tokenIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        VaultInfo storage vault = vaults[_vaultId];
        if (!vault.isActive) revert InactiveVault();

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (tokenId > MAX_TOKEN_ID) revert TokenIdTooLarge();

            // Check ownership
            try vault.nft.ownerOf(tokenId) returns (address owner) {
                if (owner != msg.sender) revert NotTokenOwner();
            } catch {
                revert InvalidTokenId();
            }

            // Check if already staked
            if (stakes[tokenId].timestamp != 0) revert AlreadyStaked();

            // Transfer NFT to contract
            vault.nft.transferFrom(msg.sender, address(this), tokenId);

            // Record stake
            stakes[tokenId] = Stake({
                owner: msg.sender,
                tokenId: uint32(tokenId),
                timestamp: uint64(block.timestamp),
                vaultId: uint32(_vaultId)
            });

            // Track user's staked tokens for efficient querying
            userStakedTokens[msg.sender][_vaultId].push(tokenId);
            userStakeCount[msg.sender][_vaultId]++;
            vault.totalStaked++;

            emit NFTStaked(msg.sender, _vaultId, tokenId, block.timestamp);
        }
        
        // Additional batch event for efficient indexing
        emit BatchNFTStaked(msg.sender, _vaultId, tokenIds.length, block.timestamp);
    }

    /**
     * @dev Unstakes tokens and claims rewards in one transaction.
     *      Reverts if caller doesn't own the staked NFTs.
     * @param _vaultId The vault ID
     * @param tokenIds Tokens to unstake
     */
    function unstake(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        nonReentrant
    {
        _claim(msg.sender, _vaultId, tokenIds, true);
    }

    /**
     * @dev Internal function to unstake multiple tokens.
     * @param account The address of the token owner
     * @param _vaultId The vault ID
     * @param tokenIds Array of token IDs to unstake
     */
    function _unstakeMany(
        address account,
        uint256 _vaultId,
        uint256[] calldata tokenIds
    ) internal {
        VaultInfo storage vault = vaults[_vaultId];
        uint256[] storage stakedTokens = userStakedTokens[account][_vaultId];

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            Stake memory staked = stakes[tokenId];

            if (staked.owner != account) revert NotTokenOwner();
            if (staked.vaultId != uint32(_vaultId)) revert InvalidVaultId();

            // Remove stake record
            delete stakes[tokenId];

            // Return NFT to owner
            vault.nft.transferFrom(address(this), account, tokenId);

            // Remove tokenId from user's staked tokens array
            // Find the index of tokenId in stakedTokens array
            for (uint256 j = 0; j < stakedTokens.length; j++) {
                if (stakedTokens[j] == tokenId) {
                    // Replace with the last element and pop
                    stakedTokens[j] = stakedTokens[stakedTokens.length - 1];
                    stakedTokens.pop();
                    break;
                }
            }

            userStakeCount[account][_vaultId]--;
            vault.totalStaked--;

            emit NFTUnstaked(account, _vaultId, tokenId, block.timestamp);
        }
        
        // Additional batch event for efficient indexing
        emit BatchNFTUnstaked(account, _vaultId, tokenIds.length, block.timestamp);
    }

    // ======================
    //   Reward Claiming
    // ======================

    /**
     * @dev Claims rewards for staked tokens (without unstaking).
     * @param _vaultId The vault ID
     * @param tokenIds Tokens for which to claim
     */
    function claim(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
    {
        _claim(msg.sender, _vaultId, tokenIds, false);
    }

    /**
     * @dev Claims rewards for a specific address (Manager-only if not self).
     */
    function claimForAddress(
        address account,
        uint256 _vaultId,
        uint256[] calldata tokenIds
    ) external nonReentrant whenNotPaused {
        if (msg.sender != account) {
            if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotTokenOwner();
        }
        _claim(account, _vaultId, tokenIds, false);
    }

    /**
     * @dev Internal function to handle reward claiming and optional unstaking.
     * Improved reward calculation for better precision.
     * 
     * @param account The address for which to claim
     * @param _vaultId The vault ID
     * @param tokenIds Tokens to claim rewards for
     * @param _unstake Whether to unstake after claiming
     */
    function _claim(
        address account,
        uint256 _vaultId,
        uint256[] calldata tokenIds,
        bool _unstake
    ) internal {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        if (tokenIds.length == 0) revert EmptyTokenArray();

        VaultInfo storage vault = vaults[_vaultId];
        uint256 earned = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            Stake memory staked = stakes[tokenId];

            if (staked.owner != account) revert NotTokenOwner();
            if (staked.vaultId != uint32(_vaultId)) revert InvalidVaultId();

            // Calculate how long the NFT has been staked since last claim
            uint256 timeStaked = block.timestamp - staked.timestamp;
            
            // Improved reward calculation for precision
            // (rewardRate * timeStaked * REWARD_PRECISION) / (SECONDS_IN_DAY * REWARD_PRECISION)
            uint256 tokenEarned = vault.rewardRate.mulDiv(
                timeStaked,
                SECONDS_IN_DAY
            );
            
            earned += tokenEarned;

            // Reset the timestamp to current time
            stakes[tokenId].timestamp = uint64(block.timestamp);
        }

        if (earned > 0) {
            // Ensure the contract has enough tokens to pay out
            uint256 contractBalance = vault.token.balanceOf(address(this));
            if (contractBalance < earned) revert InsufficientRewardBalance();

            vault.token.safeTransfer(account, earned);
            emit RewardsClaimed(account, _vaultId, earned);
        }

        if (_unstake) {
            _unstakeMany(account, _vaultId, tokenIds);
        }
    }

    // ======================
    //   View-Only Helpers
    // ======================

    /**
     * @dev Returns the total rewards currently accrued for given tokens based on current time.
     * Improved reward calculation for better precision.
     */
    function calculateRewards(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        view
        returns (uint256 rewards)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        VaultInfo storage vault = vaults[_vaultId];

        for (uint256 i = 0; i < tokenIds.length; i++) {
            Stake memory staked = stakes[tokenIds[i]];
            // Skip if not staked or staked in another vault
            if (staked.owner == address(0) || staked.vaultId != uint32(_vaultId)) continue;

            uint256 timeStaked = block.timestamp - staked.timestamp;
            
            // Improved reward calculation for precision
            rewards += vault.rewardRate.mulDiv(
                timeStaked,
                SECONDS_IN_DAY
            );
        }
        return rewards;
    }

    /**
     * @dev Returns earning information for the given tokens:
     *      [total currently accrued, earnRatePerSecond].
     */
    function earningInfo(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        view
        returns (uint256[2] memory info)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        VaultInfo storage vault = vaults[_vaultId];

        uint256 earned = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Stake memory staked = stakes[tokenIds[i]];
            if (staked.owner != address(0) && staked.vaultId == uint32(_vaultId)) {
                uint256 timeStaked = block.timestamp - staked.timestamp;
                
                earned += vault.rewardRate.mulDiv(
                    timeStaked,
                    SECONDS_IN_DAY
                );
            }
        }
        
        // earnRatePerSecond = vault.rewardRate / SECONDS_IN_DAY
        uint256 earnRatePerSecond = vault.rewardRate / SECONDS_IN_DAY;
        return [earned, earnRatePerSecond];
    }

    /**
     * @dev Returns how many tokens a given account has staked in a particular vault.
     * Efficient implementation using tracked count instead of iterating.
     */
    function balanceOf(address account, uint256 _vaultId)
        public
        view
        returns (uint256)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        return userStakeCount[account][_vaultId];
    }

    /**
     * @dev Returns staked token IDs for an address in a specific vault with pagination.
     * @param account Owner address
     * @param _vaultId Vault ID
     * @param startIndex Start index for pagination
     * @param count Maximum number of tokens to return
     * @return Array of token IDs
     */
    function getStakedTokens(
        address account, 
        uint256 _vaultId, 
        uint256 startIndex, 
        uint256 count
    ) 
        external 
        view 
        returns (uint256[] memory)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        
        uint256[] storage userTokens = userStakedTokens[account][_vaultId];
        uint256 totalTokens = userTokens.length;
        
        if (startIndex >= totalTokens || (totalTokens > 0 && count == 0)) {
            revert InvalidPaginationParams();
        }
        
        // Calculate how many tokens we'll actually return
        uint256 returnCount = Math.min(count, totalTokens - startIndex);
        uint256[] memory result = new uint256[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            result[i] = userTokens[startIndex + i];
        }
        
        return result;
    }

    /**
     * @dev Returns all staked token IDs for an address in a specific vault.
     * Uses the tracked staked tokens instead of iterating over all tokens.
     */
    function getAllStakedTokens(address account, uint256 _vaultId)
        external
        view
        returns (uint256[] memory)
    {
        if (_vaultId >= vaults.length) revert InvalidVaultId();
        return userStakedTokens[account][_vaultId];
    }

    // ======================
    //  Emergency & Rescue
    // ======================

    /**
     * @dev Allows the admin (deployer) to pause the contract (disables staking & claim).
     *      This does NOT affect claiming or unstaking if the contract isn't paused,
     *      but once paused, new stake and normal claim calls revert.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract (enables staking & claiming).
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Allows emergency unstaking while the entire contract is paused.
     *      This bypasses reward claiming. The staker can re-stake or claim later if needed.
     */
    function emergencyWithdraw(uint256 _vaultId, uint256[] calldata tokenIds)
        external
        nonReentrant
    {
        require(paused(), "Contract must be paused");
        _unstakeMany(msg.sender, _vaultId, tokenIds);
    }

    /**
     * @dev Prevent direct NFT transfers into contract except via the `stake` flow.
     *      If someone tries to send NFT directly, it reverts unless minted from address(0).
     */
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        if (from != address(0)) revert DirectTransferNotAllowed();
        return this.onERC721Received.selector;
    }

    // ======================
    //   Admin Rescue Logic
    // ======================

    /**
     * @dev Rescue any ERC20 tokens stuck in this contract.
     *      Only the deployer (DEFAULT_ADMIN_ROLE) can call this.
     *      BE CAREFUL: Removing reward tokens can cause staker claims to revert if insufficient.
     * @param _token The address of the ERC20 token to rescue
     * @param _amount How many tokens to rescue
     */
    function rescueTokens(address _token, uint256 _amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_token == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        
        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit TokensRescued(_token, msg.sender, _amount);
    }
}
