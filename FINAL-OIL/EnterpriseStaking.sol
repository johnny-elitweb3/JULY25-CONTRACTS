// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title EnterpriseStaking
 * @notice Professional-grade staking contract with comprehensive security features
 * @dev Uses OpenZeppelin upgradeable contracts pattern with enhanced security
 * @custom:security-contact security@yourdomain.com
 */
contract EnterpriseStaking is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // --------------------------
    // Roles
    // --------------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // --------------------------
    // Constants
    // --------------------------
    uint256 public constant EARLY_UNSTAKE_FEE = 3000; // 30% in basis points
    uint256 public constant MAX_INTEREST_RATE = 3000; // 30% maximum interest rate
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant MAX_INTEREST_RATE_CHANGE = 500; // 5% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 365 days;

    // For front-running protection: two-step withdrawals
    struct WithdrawalRequest {
        uint256 timestamp;
        uint256 amount;
        bool isProcessed;
    }
    mapping(uint256 => WithdrawalRequest) private _withdrawalRequests;
    uint256 public constant WITHDRAWAL_DELAY = 1 days;

    // For rate limiting: cooldown
    mapping(address => uint256) private _lastWithdrawalTime;
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 days;

    // --------------------------
    // Configurable state (timelocked changes)
    // --------------------------
    uint256 public maxDailyWithdrawal;
    uint256 public minStakeAmount;
    uint256 public maxStakeAmount;
    uint256 public emergencyWithdrawalFee;

    // --------------------------
    // Reserve Management (NEW)
    // --------------------------
    uint256 public totalInterestObligations;
    uint256 public interestReserve;
    uint256 public minimumReserveRatio; // Basis points (e.g., 5000 = 50%)

    // --------------------------
    // Data Structures
    // --------------------------
    struct Position {
        uint256 positionId;
        address walletAddress;
        uint256 createdDate;
        uint256 unlockDate;
        uint256 percentInterest;
        uint256 amountStaked;  // Renamed from weiStaked
        uint256 interestAmount; // Renamed from weiInterest
        bool open;
        uint8 tierLevel;
        bool emergencyWithdrawn;
    }

    struct LockPeriod {
        uint256 duration;
        uint256 interestRate;
        bool active;
        uint256 minimumStake;
    }

    struct PendingChange {
        uint256 newValue;
        uint256 effectiveTime;
        bool exists;
        bytes32 changeType;
    }

    // --------------------------
    // Mappings & Arrays
    // --------------------------
    mapping(uint256 => Position) private _positions;
    mapping(address => uint256[]) private _positionIdsByAddress;
    mapping(uint256 => LockPeriod) private _lockPeriods;
    mapping(bytes32 => PendingChange) public pendingChanges;
    mapping(uint256 => uint256) public dailyWithdrawals;

    // --------------------------
    // Global State
    // --------------------------
    address public beneficiary;
    uint256 public currentPositionId;
    uint256 public totalValueLocked;
    uint256 public totalCollectedFees;
    uint256 public totalPositions;
    uint256 public activePositions;
    bool public emergencyMode;
    uint256[] private _activeLockPeriods;

    // The ERC20 token to be staked
    IERC20 public stakingToken;

    // Reserve storage space for future upgrades (47 slots used, 3 for new reserve vars)
    uint256[47] private __gap;

    // --------------------------
    // Events
    // --------------------------
    event PositionCreated(
        uint256 indexed positionId,
        address indexed staker,
        uint256 amount,
        uint256 duration,
        uint256 unlockDate,
        uint256 interestAmount
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed staker,
        uint256 principal,
        uint256 interest,
        bool earlyWithdrawal
    );
    event WithdrawalRequested(
        uint256 indexed positionId,
        address indexed staker,
        uint256 amount,
        uint256 requestTime
    );
    event InterestRateUpdateScheduled(
        uint256 duration,
        uint256 newRate,
        uint256 effectiveTime
    );
    event InterestRateUpdated(uint256 duration, uint256 newRate);
    event BeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );
    event PlatformFeesCollected(
        address indexed beneficiary,
        uint256 amount,
        uint256 timestamp
    );
    event EmergencyWithdraw(
        address indexed staker,
        uint256 indexed positionId,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );
    event DailyWithdrawalLimitUpdated(
        uint256 oldLimit,
        uint256 newLimit,
        uint256 timestamp
    );
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event EmergencyWithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event StakingPaused(address indexed admin, uint256 timestamp);
    event StakingUnpaused(address indexed admin, uint256 timestamp);
    event LockPeriodAdded(uint256 duration, uint256 interestRate);
    event LockPeriodRemoved(uint256 duration);
    event EmergencyActionPerformed(
        string indexed actionType,
        address indexed performer,
        uint256 timestamp
    );
    event ReserveDeposited(uint256 amount, uint256 newReserve);
    event ReserveWithdrawn(uint256 amount, uint256 newReserve);
    event SolvencyCheckFailed(uint256 required, uint256 available);

    // --------------------------
    // Errors
    // --------------------------
    error InvalidDuration();
    error InsufficientStake();
    error PositionNotFound();
    error PositionNotMature();
    error Unauthorized();
    error ContractPaused();
    error WithdrawalFailed();
    error ExceedsMaxInterestRate();
    error InvalidTimelock();
    error ExceedsMaxRateChange();
    error ExceedsDailyWithdrawalLimit();
    error InvalidBeneficiary();
    error FeesTransferFailed();
    error InvalidAmount();
    error DurationNotFound();
    error InvalidParameter();
    error OperationNotAllowed();
    error EmergencyActionFailed();
    error WithdrawalRequestNotFound();
    error WithdrawalDelayNotMet();
    error WithdrawalAlreadyProcessed();
    error InterestCalculationOverflow();
    error ZeroAddressTransfer();
    error TransferFailed();
    error WithdrawalCooldownActive();
    error InsufficientReserve();
    error EmergencyModeNotActive();

    // --------------------------
    // Initialization
    // --------------------------
    /**
     * @notice Initialize with separate role addresses for better decentralization
     * @param adminAddress Address to receive ADMIN_ROLE
     * @param operatorAddress Address to receive OPERATOR_ROLE
     * @param emergencyAddress Address to receive EMERGENCY_ROLE
     * @param initialBeneficiary Address to receive platform fees
     * @param token The ERC20 token to stake
     */
    function initialize(
        address adminAddress,
        address operatorAddress,
        address emergencyAddress,
        address initialBeneficiary,
        address token
    ) public initializer {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (adminAddress == address(0) || 
            operatorAddress == address(0) || 
            emergencyAddress == address(0)) revert InvalidParameter();
        if (initialBeneficiary == address(0)) revert InvalidBeneficiary();
        if (token == address(0)) revert InvalidParameter();

        // Separate roles for better security
        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
        _grantRole(OPERATOR_ROLE, operatorAddress);
        _grantRole(EMERGENCY_ROLE, emergencyAddress);

        beneficiary = initialBeneficiary;
        stakingToken = IERC20(token);

        minStakeAmount = 0.1 ether;
        maxStakeAmount = 100 ether;
        maxDailyWithdrawal = 1000 ether;
        emergencyWithdrawalFee = 100; // 1% fee
        minimumReserveRatio = 5000; // 50% minimum reserve ratio

        _initializeLockPeriods();
    }

    // --------------------------
    // Core Staking Logic
    // --------------------------
    /**
     * @notice Stake an ERC20 token amount for a specified duration (in days).
     * @dev Includes solvency check to ensure contract can pay interest
     */
    function stake(uint256 duration, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount < minStakeAmount || amount > maxStakeAmount) {
            revert InsufficientStake();
        }
        LockPeriod memory lockPeriod = _lockPeriods[duration];
        if (!lockPeriod.active) revert InvalidDuration();
        if (amount < lockPeriod.minimumStake) revert InsufficientStake();

        uint256 interestRate = lockPeriod.interestRate;
        uint256 interest = _calculateInterest(interestRate, amount);

        // Solvency check: ensure we can pay this interest
        uint256 newTotalObligations = totalInterestObligations + interest;
        uint256 requiredReserve = (newTotalObligations * minimumReserveRatio) / BASIS_POINTS;
        
        uint256 contractBalance = stakingToken.balanceOf(address(this));
        uint256 effectiveReserve = contractBalance > totalValueLocked 
            ? contractBalance - totalValueLocked 
            : 0;

        if (effectiveReserve < requiredReserve) {
            emit SolvencyCheckFailed(requiredReserve, effectiveReserve);
            revert InsufficientReserve();
        }

        // Pull tokens in from staker
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        Position memory newPosition = Position({
            positionId: currentPositionId,
            walletAddress: msg.sender,
            createdDate: block.timestamp,
            unlockDate: block.timestamp + (duration * 1 days),
            percentInterest: interestRate,
            amountStaked: amount,
            interestAmount: interest,
            open: true,
            tierLevel: _getTierLevel(duration),
            emergencyWithdrawn: false
        });

        _positions[currentPositionId] = newPosition;
        _positionIdsByAddress[msg.sender].push(currentPositionId);

        totalValueLocked += amount;
        totalInterestObligations += interest;
        totalPositions++;
        activePositions++;

        emit PositionCreated(
            currentPositionId,
            msg.sender,
            amount,
            duration,
            newPosition.unlockDate,
            interest
        );
        currentPositionId++;
    }

    /**
     * @notice First step of the two-step withdrawal process
     */
    function requestWithdrawal(uint256 positionId) external nonReentrant {
        Position storage position = _positions[positionId];

        if (position.walletAddress != msg.sender) revert Unauthorized();
        if (!position.open) revert PositionNotFound();
        if (position.emergencyWithdrawn) revert OperationNotAllowed();

        uint256 withdrawalAmount;
        uint256 fee = 0;

        // Early withdrawal check
        if (block.timestamp < position.unlockDate) {
            fee = (position.amountStaked * EARLY_UNSTAKE_FEE) / BASIS_POINTS;
            withdrawalAmount = position.amountStaked - fee;
            totalCollectedFees += fee;
        } else {
            withdrawalAmount = position.amountStaked + position.interestAmount;
        }

        _withdrawalRequests[positionId] = WithdrawalRequest({
            timestamp: block.timestamp,
            amount: withdrawalAmount,
            isProcessed: false
        });

        emit WithdrawalRequested(positionId, msg.sender, withdrawalAmount, block.timestamp);
    }

    /**
     * @notice Second step of the two-step withdrawal process
     */
    function executeWithdrawal(uint256 positionId) external nonReentrant {
        WithdrawalRequest storage request = _withdrawalRequests[positionId];
        Position storage position = _positions[positionId];

        if (position.walletAddress != msg.sender) revert Unauthorized();
        if (request.timestamp == 0) revert WithdrawalRequestNotFound();
        if (request.isProcessed) revert WithdrawalAlreadyProcessed();
        if (block.timestamp < request.timestamp + WITHDRAWAL_DELAY)
            revert WithdrawalDelayNotMet();

        // Check cooldown
        if (block.timestamp < _lastWithdrawalTime[msg.sender] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldownActive();
        }

        // Check daily limit (using timestamp is acceptable for daily limits)
        uint256 currentDay = block.timestamp / 1 days;
        if (dailyWithdrawals[currentDay] + request.amount > maxDailyWithdrawal)
            revert ExceedsDailyWithdrawalLimit();
        dailyWithdrawals[currentDay] += request.amount;

        // Mark as processed & close position
        request.isProcessed = true;
        position.open = false;
        activePositions--;
        totalValueLocked -= position.amountStaked;
        
        // Reduce interest obligations only if position matured
        if (block.timestamp >= position.unlockDate) {
            totalInterestObligations -= position.interestAmount;
        }

        // Transfer out tokens
        if (!_processTransfer(msg.sender, request.amount)) revert WithdrawalFailed();

        _lastWithdrawalTime[msg.sender] = block.timestamp;

        emit PositionClosed(
            positionId,
            msg.sender,
            position.amountStaked,
            position.interestAmount,
            (block.timestamp < position.unlockDate)
        );
    }

    /**
     * @notice User-initiated emergency withdrawal when emergency mode is active
     */
    function userEmergencyWithdraw(uint256 positionId) external nonReentrant {
        if (!emergencyMode) revert EmergencyModeNotActive();
        
        Position storage position = _positions[positionId];
        if (position.walletAddress != msg.sender) revert Unauthorized();
        if (!position.open || position.emergencyWithdrawn) revert PositionNotFound();

        uint256 withdrawalAmount = position.amountStaked;
        uint256 fee = (withdrawalAmount * emergencyWithdrawalFee) / BASIS_POINTS;
        uint256 finalAmount = withdrawalAmount - fee;

        position.open = false;
        position.emergencyWithdrawn = true;
        activePositions--;
        totalValueLocked -= position.amountStaked;
        totalInterestObligations -= position.interestAmount;
        totalCollectedFees += fee;

        if (!_processTransfer(msg.sender, finalAmount)) revert EmergencyActionFailed();
        if (!_processTransfer(beneficiary, fee)) revert FeesTransferFailed();

        emit PlatformFeesCollected(beneficiary, fee, block.timestamp);
        emit EmergencyWithdraw(msg.sender, positionId, finalAmount, fee, block.timestamp);
    }

    /**
     * @notice Admin emergency withdrawal for specific positions
     */
    function adminEmergencyWithdraw(uint256 positionId)
        external
        nonReentrant
        onlyRole(EMERGENCY_ROLE)
    {
        if (!emergencyMode) revert EmergencyModeNotActive();

        Position storage position = _positions[positionId];
        if (!position.open || position.emergencyWithdrawn) revert PositionNotFound();

        uint256 withdrawalAmount = position.amountStaked;
        uint256 fee = (withdrawalAmount * emergencyWithdrawalFee) / BASIS_POINTS;
        uint256 finalAmount = withdrawalAmount - fee;

        position.open = false;
        position.emergencyWithdrawn = true;
        activePositions--;
        totalValueLocked -= position.amountStaked;
        totalInterestObligations -= position.interestAmount;
        totalCollectedFees += fee;

        if (!_processTransfer(position.walletAddress, finalAmount)) revert EmergencyActionFailed();
        if (!_processTransfer(beneficiary, fee)) revert FeesTransferFailed();

        emit PlatformFeesCollected(beneficiary, fee, block.timestamp);
        emit EmergencyWithdraw(position.walletAddress, positionId, finalAmount, fee, block.timestamp);
    }

    // --------------------------
    // Reserve Management Functions
    // --------------------------
    /**
     * @notice Deposit tokens to interest reserve
     */
    function depositReserve(uint256 amount) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert InvalidAmount();
        
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        interestReserve += amount;
        
        emit ReserveDeposited(amount, interestReserve);
    }

    /**
     * @notice Withdraw excess reserves
     */
    function withdrawReserve(uint256 amount) external nonReentrant onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert InvalidAmount();
        
        uint256 requiredReserve = (totalInterestObligations * minimumReserveRatio) / BASIS_POINTS;
        uint256 contractBalance = stakingToken.balanceOf(address(this));
        uint256 effectiveReserve = contractBalance > totalValueLocked 
            ? contractBalance - totalValueLocked 
            : 0;
        
        if (effectiveReserve - amount < requiredReserve) revert InsufficientReserve();
        
        interestReserve -= amount;
        stakingToken.safeTransfer(beneficiary, amount);
        
        emit ReserveWithdrawn(amount, interestReserve);
    }

    /**
     * @notice Check contract solvency status
     */
    function checkSolvency() external view returns (bool isSolvent, uint256 reserve, uint256 obligations) {
        obligations = totalInterestObligations;
        uint256 contractBalance = stakingToken.balanceOf(address(this));
        reserve = contractBalance > totalValueLocked ? contractBalance - totalValueLocked : 0;
        
        uint256 requiredReserve = (obligations * minimumReserveRatio) / BASIS_POINTS;
        isSolvent = reserve >= requiredReserve;
    }

    // --------------------------
    // View Functions
    // --------------------------
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    function getPositionsForAddress(address wallet) external view returns (uint256[] memory) {
        return _positionIdsByAddress[wallet];
    }

    function getPositionsForAddressPaginated(
        address wallet,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory positions, uint256 total) {
        uint256[] storage userPositions = _positionIdsByAddress[wallet];
        uint256 totalPositionsForUser = userPositions.length;

        if (offset >= totalPositionsForUser) {
            return (new uint256[](0), totalPositionsForUser);
        }

        uint256 end = offset + limit;
        if (end > totalPositionsForUser) {
            end = totalPositionsForUser;
        }

        uint256 resultLength = end - offset;
        positions = new uint256[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            positions[i] = userPositions[offset + i];
        }

        return (positions, totalPositionsForUser);
    }

    function getInterestRate(uint256 duration) external view returns (uint256) {
        return _lockPeriods[duration].interestRate;
    }

    function getActiveLockPeriods() external view returns (uint256[] memory) {
        return _activeLockPeriods;
    }

    function getLockPeriodInfo(uint256 duration) external view returns (LockPeriod memory) {
        return _lockPeriods[duration];
    }

    // --------------------------
    // Admin Functions
    // --------------------------
    function scheduleRateChange(uint256 duration, uint256 newRate)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newRate > MAX_INTEREST_RATE) revert ExceedsMaxInterestRate();
        LockPeriod memory lockPeriod = _lockPeriods[duration];
        if (!lockPeriod.active) revert DurationNotFound();

        uint256 rateChange = newRate > lockPeriod.interestRate
            ? newRate - lockPeriod.interestRate
            : lockPeriod.interestRate - newRate;
        if (rateChange > MAX_INTEREST_RATE_CHANGE) revert ExceedsMaxRateChange();

        bytes32 operationId = keccak256(abi.encode(duration, newRate));
        pendingChanges[operationId] = PendingChange({
            newValue: newRate,
            effectiveTime: block.timestamp + TIMELOCK_DURATION,
            exists: true,
            changeType: keccak256("INTEREST_RATE")
        });

        emit InterestRateUpdateScheduled(duration, newRate, block.timestamp + TIMELOCK_DURATION);
    }

    function executeRateChange(uint256 duration, uint256 newRate)
        external
        onlyRole(ADMIN_ROLE)
    {
        bytes32 operationId = keccak256(abi.encode(duration, newRate));
        PendingChange memory pendingChangeData = pendingChanges[operationId];
        if (!_validatePendingChange(pendingChangeData, "INTEREST_RATE")) revert InvalidTimelock();

        _lockPeriods[duration].interestRate = newRate;
        delete pendingChanges[operationId];

        emit InterestRateUpdated(duration, newRate);
    }

    function updateBeneficiary(address newBeneficiary)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        address oldBeneficiary = beneficiary;
        beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(oldBeneficiary, newBeneficiary);
    }

    function scheduleDailyWithdrawalLimitUpdate(uint256 newLimit)
        external
        onlyRole(ADMIN_ROLE)
    {
        bytes32 operationId = keccak256(abi.encode("DAILY_LIMIT", newLimit));
        pendingChanges[operationId] = PendingChange({
            newValue: newLimit,
            effectiveTime: block.timestamp + TIMELOCK_DURATION,
            exists: true,
            changeType: keccak256("DAILY_LIMIT")
        });
    }

    function executeDailyWithdrawalLimitUpdate(uint256 newLimit)
        external
        onlyRole(ADMIN_ROLE)
    {
        bytes32 operationId = keccak256(abi.encode("DAILY_LIMIT", newLimit));
        PendingChange memory pendingChangeData = pendingChanges[operationId];
        if (!_validatePendingChange(pendingChangeData, "DAILY_LIMIT")) revert InvalidTimelock();

        uint256 oldLimit = maxDailyWithdrawal;
        maxDailyWithdrawal = newLimit;
        delete pendingChanges[operationId];

        emit DailyWithdrawalLimitUpdated(oldLimit, newLimit, block.timestamp);
    }

    function addLockPeriod(
        uint256 duration,
        uint256 interestRate,
        uint256 minimumStake
    )
        external
        onlyRole(ADMIN_ROLE)
    {
        if (duration < MIN_DURATION || duration > MAX_DURATION)
            revert InvalidDuration();
        if (interestRate > MAX_INTEREST_RATE) revert ExceedsMaxInterestRate();
        if (_lockPeriods[duration].active) revert OperationNotAllowed();

        _lockPeriods[duration] = LockPeriod({
            duration: duration,
            interestRate: interestRate,
            active: true,
            minimumStake: minimumStake
        });
        _activeLockPeriods.push(duration);

        emit LockPeriodAdded(duration, interestRate);
    }

    function removeLockPeriod(uint256 duration) external onlyRole(ADMIN_ROLE) {
        if (!_lockPeriods[duration].active) revert DurationNotFound();
        _lockPeriods[duration].active = false;

        for (uint256 i = 0; i < _activeLockPeriods.length; i++) {
            if (_activeLockPeriods[i] == duration) {
                _activeLockPeriods[i] = _activeLockPeriods[_activeLockPeriods.length - 1];
                _activeLockPeriods.pop();
                break;
            }
        }
        emit LockPeriodRemoved(duration);
    }

    function activateEmergencyMode(uint256 newFee) external onlyRole(EMERGENCY_ROLE) {
        if (newFee > BASIS_POINTS) revert InvalidParameter();
        emergencyMode = true;
        emergencyWithdrawalFee = newFee;
        emit EmergencyActionPerformed("EMERGENCY_MODE_ACTIVATED", msg.sender, block.timestamp);
    }

    function deactivateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = false;
        emit EmergencyActionPerformed("EMERGENCY_MODE_DEACTIVATED", msg.sender, block.timestamp);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit StakingPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit StakingUnpaused(msg.sender, block.timestamp);
    }

    // --------------------------
    // Internal Utilities
    // --------------------------
    function _calculateInterest(uint256 basisPoints, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            uint256 result = amount * basisPoints;
            if (result / amount != basisPoints) revert InterestCalculationOverflow();

            if (result > type(uint256).max - (BASIS_POINTS - 1)) {
                revert InterestCalculationOverflow();
            }
            return result / BASIS_POINTS;
        }
    }

    function _getTierLevel(uint256 duration) internal pure returns (uint8) {
        if (duration >= 365) return 4;
        if (duration >= 180) return 3;
        if (duration >= 90) return 2;
        return 1;
    }

    function _processTransfer(address recipient, uint256 amount)
        internal
        returns (bool)
    {
        if (recipient == address(0)) revert ZeroAddressTransfer();
        if (amount == 0) revert InvalidAmount();

        stakingToken.safeTransfer(recipient, amount);
        return true;
    }

    function _validatePendingChange(PendingChange memory change, string memory expectedType)
        internal
        view
        returns (bool)
    {
        return (
            change.exists &&
            block.timestamp >= change.effectiveTime &&
            change.changeType == keccak256(abi.encode(expectedType))
        );
    }

    function _initializeLockPeriods() internal {
        uint256[4] memory periods = [uint256(30), 90, 180, 365];
        uint256[4] memory rates = [uint256(700), 900, 1200, 1500];

        for (uint256 i = 0; i < periods.length; i++) {
            _lockPeriods[periods[i]] = LockPeriod({
                duration: periods[i],
                interestRate: rates[i],
                active: true,
                minimumStake: minStakeAmount
            });
            _activeLockPeriods.push(periods[i]);
        }
    }

    // Required override
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/**
 * @title StakingFactory
 * @notice Factory contract for deploying new staking pools
 */
contract StakingFactory is AccessControlUpgradeable {
    event StakingPoolCreated(
        address indexed pool,
        address indexed admin,
        address indexed beneficiary,
        address token
    );

    /**
     * @notice Creates a new staking pool with separated roles
     * @param adminAddress Address to receive ADMIN_ROLE
     * @param operatorAddress Address to receive OPERATOR_ROLE
     * @param emergencyAddress Address to receive EMERGENCY_ROLE
     * @param beneficiary Address to receive platform fees
     * @param token The ERC20 token to stake
     */
    function createStakingPool(
        address adminAddress,
        address operatorAddress,
        address emergencyAddress,
        address beneficiary,
        address token
    )
        external
        returns (address)
    {
        EnterpriseStaking pool = new EnterpriseStaking();
        pool.initialize(adminAddress, operatorAddress, emergencyAddress, beneficiary, token);

        emit StakingPoolCreated(address(pool), adminAddress, beneficiary, token);
        return address(pool);
    }
}
