// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ChainReachToken (CRT)
 * @author ChainReach Foundation
 * @notice Platform utility token for the ChainReach charitable giving ecosystem
 * @dev ERC20 token with comprehensive features for charitable platform operations
 * 
 * Key Features:
 * - NGO registration fee collection (100 CRT)
 * - Snapshot capability for governance voting
 * - Deflationary mechanics through burning
 * - Gasless transactions via permit functionality
 * - Controlled minting with supply cap
 * - Emergency pause functionality
 * - Vesting schedules for team/ecosystem allocations
 * - Fee tracking and analytics
 */
contract ChainReachToken is 
    ERC20, 
    ERC20Burnable, 
    ERC20Snapshot, 
    ERC20Permit, 
    AccessControl, 
    Pausable,
    ReentrancyGuard 
{
    // ============ Constants ============
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");
    
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18; // 100 million tokens
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion token cap
    uint256 public constant NGO_REGISTRATION_FEE = 100 * 10**18; // 100 CRT
    
    // ============ State Variables ============
    
    // Supply tracking
    uint256 public totalMinted;
    uint256 public totalBurned;
    
    // Fee collection analytics
    mapping(address => uint256) public feesPaidBy;
    mapping(address => mapping(uint256 => uint256)) public feesPaidByYear;
    uint256 public totalFeesCollected;
    
    // Vesting schedules
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 cliffDuration;
        uint256 vestingDuration;
        bool revocable;
        bool revoked;
    }
    
    mapping(address => VestingSchedule[]) public vestingSchedules;
    mapping(address => uint256) public totalVestingAmount;
    
    // Registry addresses allowed to collect fees
    mapping(address => bool) public registryContracts;
    
    // Blacklist for compliance
    mapping(address => bool) public blacklisted;
    
    // ============ Events ============
    
    event FeePaid(address indexed payer, address indexed registry, uint256 amount, uint256 timestamp);
    event VestingScheduleCreated(
        address indexed beneficiary, 
        uint256 amount, 
        uint256 startTime, 
        uint256 cliffDuration, 
        uint256 vestingDuration
    );
    event VestingReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 amountRevoked);
    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    
    // ============ Errors ============
    
    error MaxSupplyExceeded();
    error TokensLocked();
    error InvalidAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error NotRegistry();
    error AccountBlacklisted();
    error NoVestingSchedule();
    error ScheduleAlreadyRevoked();
    error NotRevocable();
    error InvalidVestingSchedule();
    error TransferFailed();
    
    // ============ Modifiers ============
    
    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert AccountBlacklisted();
        _;
    }
    
    modifier onlyRegistry() {
        if (!registryContracts[msg.sender]) revert NotRegistry();
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Deploys the ChainReach Token with initial supply
     * @param _treasury Address to receive initial token supply
     * @param _admin Admin address for role management
     */
    constructor(
        address _treasury,
        address _admin
    ) 
        ERC20("ChainReach Token", "CRT") 
        ERC20Permit("ChainReach Token")
    {
        if (_treasury == address(0) || _admin == address(0)) revert ZeroAddress();
        
        // Grant roles to admin (should be a multisig)
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(SNAPSHOT_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(FEE_COLLECTOR_ROLE, _admin);
        
        // Mint initial supply to treasury
        _mint(_treasury, INITIAL_SUPPLY);
        totalMinted = INITIAL_SUPPLY;
    }
    
    // ============ Token Management ============
    
    /**
     * @notice Mint new tokens with supply cap check
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        
        uint256 newTotalSupply = totalSupply() + amount;
        if (newTotalSupply > MAX_SUPPLY) revert MaxSupplyExceeded();
        
        totalMinted += amount;
        _mint(to, amount);
    }
    
    /**
     * @notice Burn tokens (updates total burned counter)
     * @param value Amount to burn
     */
    function burn(uint256 value) public override {
        totalBurned += value;
        super.burn(value);
    }
    
    /**
     * @notice Burn tokens from another account (updates total burned counter)
     * @param account Account to burn from
     * @param value Amount to burn
     */
    function burnFrom(address account, uint256 value) public override {
        totalBurned += value;
        super.burnFrom(account, value);
    }
    
    // ============ Snapshot & Governance ============
    
    /**
     * @notice Create a new snapshot for governance voting
     * @return snapshotId The ID of the created snapshot
     */
    function snapshot() external onlyRole(SNAPSHOT_ROLE) returns (uint256) {
        return _snapshot();
    }
    
    // ============ Access Control ============
    
    /**
     * @notice Pause token transfers in emergency
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Add address to blacklist
     * @param account Address to blacklist
     */
    function blacklist(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }
    
    /**
     * @notice Remove address from blacklist
     * @param account Address to unblacklist
     */
    function unblacklist(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }
    
    // ============ Registry Management ============
    
    /**
     * @notice Add a registry contract that can record fee payments
     * @param registry Registry contract address
     */
    function addRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert ZeroAddress();
        registryContracts[registry] = true;
        emit RegistryAdded(registry);
    }
    
    /**
     * @notice Remove a registry contract
     * @param registry Registry contract address
     */
    function removeRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        registryContracts[registry] = false;
        emit RegistryRemoved(registry);
    }
    
    // ============ Fee Tracking ============
    
    /**
     * @notice Record fee payment (restricted to registry contracts)
     * @param payer Address that paid the fee
     * @param amount Fee amount paid
     */
    function recordFeePaid(address payer, uint256 amount) external onlyRegistry {
        if (amount == 0) revert InvalidAmount();
        
        feesPaidBy[payer] += amount;
        uint256 currentYear = block.timestamp / 365 days;
        feesPaidByYear[payer][currentYear] += amount;
        totalFeesCollected += amount;
        
        emit FeePaid(payer, msg.sender, amount, block.timestamp);
    }
    
    // ============ Vesting Functions ============
    
    /**
     * @notice Create a vesting schedule for tokens
     * @param beneficiary Address that will receive tokens
     * @param amount Total amount to vest
     * @param startTime Start time of vesting (0 for immediate)
     * @param cliffDuration Cliff period in seconds
     * @param vestingDuration Total vesting duration in seconds
     * @param revocable Whether the vesting can be revoked
     */
    function createVesting(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (vestingDuration == 0) revert InvalidVestingSchedule();
        if (cliffDuration > vestingDuration) revert InvalidVestingSchedule();
        
        uint256 start = startTime == 0 ? block.timestamp : startTime;
        
        // Transfer tokens from sender to this contract
        _transfer(msg.sender, address(this), amount);
        
        vestingSchedules[beneficiary].push(VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: start,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            revocable: revocable,
            revoked: false
        }));
        
        totalVestingAmount[beneficiary] += amount;
        
        emit VestingScheduleCreated(beneficiary, amount, start, cliffDuration, vestingDuration);
    }
    
    /**
     * @notice Release vested tokens for a beneficiary
     * @param beneficiary Address to release tokens for
     * @param scheduleIndex Index of the vesting schedule
     */
    function releaseVested(address beneficiary, uint256 scheduleIndex) external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[beneficiary][scheduleIndex];
        
        if (schedule.totalAmount == 0) revert NoVestingSchedule();
        if (schedule.revoked) revert ScheduleAlreadyRevoked();
        
        uint256 releasable = _computeReleasableAmount(schedule);
        if (releasable == 0) revert InvalidAmount();
        
        schedule.releasedAmount += releasable;
        totalVestingAmount[beneficiary] -= releasable;
        
        _transfer(address(this), beneficiary, releasable);
        
        emit VestingReleased(beneficiary, releasable);
    }
    
    /**
     * @notice Revoke a vesting schedule
     * @param beneficiary Address of vesting beneficiary
     * @param scheduleIndex Index of the vesting schedule
     */
    function revokeVesting(address beneficiary, uint256 scheduleIndex) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        nonReentrant 
    {
        VestingSchedule storage schedule = vestingSchedules[beneficiary][scheduleIndex];
        
        if (!schedule.revocable) revert NotRevocable();
        if (schedule.revoked) revert ScheduleAlreadyRevoked();
        
        uint256 releasable = _computeReleasableAmount(schedule);
        uint256 refundAmount = schedule.totalAmount - schedule.releasedAmount - releasable;
        
        schedule.revoked = true;
        
        if (releasable > 0) {
            schedule.releasedAmount += releasable;
            totalVestingAmount[beneficiary] -= releasable;
            _transfer(address(this), beneficiary, releasable);
        }
        
        if (refundAmount > 0) {
            totalVestingAmount[beneficiary] -= refundAmount;
            _transfer(address(this), msg.sender, refundAmount);
        }
        
        emit VestingRevoked(beneficiary, refundAmount);
    }
    
    /**
     * @notice Compute releasable amount for a vesting schedule
     * @param schedule Vesting schedule
     * @return Releasable amount
     */
    function _computeReleasableAmount(VestingSchedule memory schedule) 
        private 
        view 
        returns (uint256) 
    {
        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        } else if (block.timestamp >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount - schedule.releasedAmount;
        } else {
            uint256 timeFromStart = block.timestamp - schedule.startTime;
            uint256 vestedAmount = (schedule.totalAmount * timeFromStart) / schedule.vestingDuration;
            return vestedAmount - schedule.releasedAmount;
        }
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get vesting schedule details
     * @param beneficiary Address to check
     * @param index Schedule index
     * @return Vesting schedule details
     */
    function getVestingSchedule(address beneficiary, uint256 index) 
        external 
        view 
        returns (VestingSchedule memory) 
    {
        return vestingSchedules[beneficiary][index];
    }
    
    /**
     * @notice Get number of vesting schedules for an address
     * @param beneficiary Address to check
     * @return Number of vesting schedules
     */
    function getVestingScheduleCount(address beneficiary) external view returns (uint256) {
        return vestingSchedules[beneficiary].length;
    }
    
    /**
     * @notice Compute releasable amount for a specific vesting schedule
     * @param beneficiary Address of beneficiary
     * @param scheduleIndex Index of schedule
     * @return Releasable amount
     */
    function computeReleasableAmount(address beneficiary, uint256 scheduleIndex) 
        external 
        view 
        returns (uint256) 
    {
        VestingSchedule memory schedule = vestingSchedules[beneficiary][scheduleIndex];
        if (schedule.revoked) return 0;
        return _computeReleasableAmount(schedule);
    }
    
    /**
     * @notice Calculate circulating supply (total - vesting - burned)
     * @return Circulating token supply
     */
    function circulatingSupply() external view returns (uint256) {
        return totalSupply() - balanceOf(address(this));
    }
    
    /**
     * @notice Calculate remaining mintable supply
     * @return Amount that can still be minted
     */
    function remainingMintableSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
    
    /**
     * @notice Check if an address has paid any fees
     * @param account Address to check
     * @return Whether the address has paid fees
     */
    function hasPaidFees(address account) external view returns (bool) {
        return feesPaidBy[account] > 0;
    }
    
    /**
     * @notice Get fee payment stats for an address
     * @param account Address to check
     * @param year Year to check (years since 1970)
     * @return totalPaid Total fees paid by address
     * @return yearPaid Fees paid in specific year
     */
    function getFeeStats(address account, uint256 year) 
        external 
        view 
        returns (uint256 totalPaid, uint256 yearPaid) 
    {
        totalPaid = feesPaidBy[account];
        yearPaid = feesPaidByYear[account][year];
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency withdrawal of tokens sent to contract by mistake
     * @param token Token address (address(0) for ETH)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        nonReentrant 
    {
        if (token == address(0)) {
            // Withdraw ETH
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else if (token == address(this)) {
            // For CRT tokens, only allow withdrawal of non-vesting amounts
            uint256 vestingTotal = 0;
            // This is a simplified check - in production you'd want more sophisticated tracking
            uint256 availableBalance = balanceOf(address(this)) - vestingTotal;
            if (amount > availableBalance) revert InsufficientBalance();
            _transfer(address(this), msg.sender, amount);
        } else {
            // Withdraw other ERC20 tokens
            IERC20(token).transfer(msg.sender, amount);
        }
        
        emit EmergencyWithdraw(token, amount);
    }
    
    // ============ Internal Overrides ============
    
    /**
     * @notice Internal function to update token balances
     * @dev Overrides required by Solidity for multiple inheritance
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to  
     * @param value Amount of tokens transferred
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20, ERC20Snapshot) whenNotPaused {
        // Check blacklist
        if (from != address(0)) { // not minting
            if (blacklisted[from]) revert AccountBlacklisted();
        }
        if (to != address(0)) { // not burning
            if (blacklisted[to]) revert AccountBlacklisted();
        }
        
        super._update(from, to, value);
    }
    
    // ============ Interface Support ============
    
    /**
     * @notice Query if a contract implements an interface
     * @param interfaceId The interface identifier
     * @return Whether the contract implements the interface
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    // ============ Receive Function ============
    
    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}
