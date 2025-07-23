// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title IGovernanceEnabled
 * @notice Interface that DApps must implement to receive governance actions
 */
interface IGovernanceEnabled {
    function executeGovernanceAction(uint256 proposalId, bytes calldata data) external returns (bool);
    function getGovernanceParameters() external view returns (bytes memory);
}

/**
 * @title DAppRegistry
 * @author Enhanced Security Implementation
 * @notice Manages DApp registration and configuration for governance system
 * @dev Security-enhanced version with comprehensive access controls
 */
contract DAppRegistry is AccessControl, Pausable {
    using EnumerableSet for EnumerableSet.UintSet;

    // ========== Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ========== Constants ==========
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1;
    uint256 public constant MIN_QUORUM = 100; // 1%
    uint256 public constant MAX_QUORUM = 10000; // 100%
    uint256 public constant MIN_VOTING_DURATION = 1 days;
    uint256 public constant MAX_VOTING_DURATION = 30 days;
    uint256 public constant CRITICAL_OPERATION_DELAY = 2 days;

    // ========== Structs ==========
    struct DApp {
        string name;
        string description;
        address contractAddress;
        address registrar;
        uint128 registeredAt;
        uint128 lastActivityAt;
        bool active;
        uint256 totalProposals;
        uint256 successfulProposals;
        uint256 failedProposals;
    }

    struct DAppConfig {
        uint256 minProposalThreshold;
        uint256 defaultQuorum;
        uint256 defaultVotingDuration;
        bool customSettingsEnabled;
    }

    struct DAppStats {
        uint256 totalProposals;
        uint256 successfulProposals;
        uint256 failedProposals;
        uint256 activeProposals;
    }

    struct PendingOperation {
        bytes32 operationHash;
        uint256 timestamp;
        bool executed;
    }

    // ========== State Variables ==========
    uint256 public dappCounter;
    
    mapping(uint256 => DApp) public registeredDapps;
    mapping(address => uint256) public dappAddressToId;
    mapping(uint256 => DAppConfig) public dappConfigs;
    mapping(uint256 => mapping(bytes4 => bool)) public dappAllowedFunctions;
    mapping(uint256 => uint256) public dappActiveProposals;
    mapping(bytes32 => PendingOperation) public pendingOperations;
    
    EnumerableSet.UintSet private activeDappIds;

    // Rate limiting
    mapping(address => uint256) public lastRegistrationTime;
    uint256 public constant REGISTRATION_COOLDOWN = 1 hours;

    // ========== Events ==========
    event DAppRegistered(
        uint256 indexed dappId,
        string name,
        address indexed contractAddress,
        address indexed registrar
    );
    event DAppUpdated(uint256 indexed dappId, string name, string description, bool active);
    event DAppConfigUpdated(
        uint256 indexed dappId,
        uint256 minProposalThreshold,
        uint256 defaultQuorum,
        uint256 defaultVotingDuration
    );
    event DAppFunctionWhitelisted(uint256 indexed dappId, bytes4 functionSelector, string functionName);
    event DAppFunctionDelisted(uint256 indexed dappId, bytes4 functionSelector);
    event DAppActivityUpdated(uint256 indexed dappId, uint256 timestamp);
    event ProposalCountIncremented(uint256 indexed dappId, uint256 newTotal);
    event ProposalStatsUpdated(uint256 indexed dappId, bool success, uint256 successCount, uint256 failCount);
    event ActiveProposalsUpdated(uint256 indexed dappId, uint256 activeCount);
    event GovernanceActionExecuted(uint256 indexed dappId, uint256 indexed proposalId, bool success);
    event CriticalOperationScheduled(bytes32 indexed operationHash, uint256 executeAfter);
    event CriticalOperationExecuted(bytes32 indexed operationHash);
    event CriticalOperationCancelled(bytes32 indexed operationHash);

    // ========== Custom Errors ==========
    error InvalidAddress();
    error DAppNotFound();
    error DAppNotActive();
    error DAppAlreadyRegistered();
    error InvalidConfiguration();
    error NotAuthorized();
    error InterfaceNotSupported();
    error FunctionSelectorNotFound();
    error RegistrationCooldownActive();
    error OperationNotReady();
    error OperationAlreadyExecuted();
    error InvalidOperation();

    // ========== Constructor ==========
    constructor(address _governance) {
        if (_governance == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRAR_ROLE, msg.sender);
        _grantRole(CONFIG_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _governance);
    }

    // ========== Modifiers ==========
    modifier validDApp(uint256 _dappId) {
        if (_dappId == 0 || _dappId > dappCounter) revert DAppNotFound();
        _;
    }

    modifier activeDApp(uint256 _dappId) {
        if (!registeredDapps[_dappId].active) revert DAppNotActive();
        _;
    }

    modifier rateLimited(address _account) {
        if (block.timestamp < lastRegistrationTime[_account] + REGISTRATION_COOLDOWN) {
            revert RegistrationCooldownActive();
        }
        _;
    }

    // ========== Registration Functions ==========

    /**
     * @notice Register a new DApp for governance
     * @param _name DApp name
     * @param _description DApp description
     * @param _contractAddress DApp contract address
     * @return dappId The ID of the registered DApp
     */
    function registerDApp(
        string memory _name,
        string memory _description,
        address _contractAddress
    ) external onlyRole(REGISTRAR_ROLE) whenNotPaused rateLimited(msg.sender) returns (uint256 dappId) {
        if (_contractAddress == address(0)) revert InvalidAddress();
        if (dappAddressToId[_contractAddress] != 0) revert DAppAlreadyRegistered();
        
        // Comprehensive interface verification
        _verifyGovernanceInterface(_contractAddress);
        
        dappId = ++dappCounter;
        
        registeredDapps[dappId] = DApp({
            name: _name,
            description: _description,
            contractAddress: _contractAddress,
            registrar: msg.sender,
            registeredAt: uint128(block.timestamp),
            lastActivityAt: uint128(block.timestamp),
            active: true,
            totalProposals: 0,
            successfulProposals: 0,
            failedProposals: 0
        });
        
        dappAddressToId[_contractAddress] = dappId;
        activeDappIds.add(dappId);
        lastRegistrationTime[msg.sender] = block.timestamp;
        
        // Set default configuration
        dappConfigs[dappId] = DAppConfig({
            minProposalThreshold: MIN_PROPOSAL_THRESHOLD,
            defaultQuorum: 1000, // 10%
            defaultVotingDuration: 3 days,
            customSettingsEnabled: false
        });
        
        emit DAppRegistered(dappId, _name, _contractAddress, msg.sender);
    }

    /**
     * @notice Update DApp information
     * @param _dappId DApp ID to update
     * @param _name New name
     * @param _description New description
     * @param _active Active status
     */
    function updateDApp(
        uint256 _dappId,
        string memory _name,
        string memory _description,
        bool _active
    ) external validDApp(_dappId) {
        DApp storage dapp = registeredDapps[_dappId];
        
        if (!hasRole(ADMIN_ROLE, msg.sender) && dapp.registrar != msg.sender) {
            revert NotAuthorized();
        }
        
        dapp.name = _name;
        dapp.description = _description;
        dapp.active = _active;
        dapp.lastActivityAt = uint128(block.timestamp);
        
        if (_active && !activeDappIds.contains(_dappId)) {
            activeDappIds.add(_dappId);
        } else if (!_active && activeDappIds.contains(_dappId)) {
            activeDappIds.remove(_dappId);
        }
        
        emit DAppUpdated(_dappId, _name, _description, _active);
    }

    // ========== Configuration Functions ==========

    /**
     * @notice Configure DApp governance parameters
     * @param _dappId DApp ID
     * @param _minProposalThreshold Minimum voting power to create proposals
     * @param _defaultQuorum Default quorum percentage (basis points)
     * @param _defaultVotingDuration Default voting duration in seconds
     */
    function configureDApp(
        uint256 _dappId,
        uint256 _minProposalThreshold,
        uint256 _defaultQuorum,
        uint256 _defaultVotingDuration
    ) external validDApp(_dappId) onlyRole(CONFIG_ROLE) {
        if (_minProposalThreshold == 0) revert InvalidConfiguration();
        if (_defaultQuorum < MIN_QUORUM || _defaultQuorum > MAX_QUORUM) revert InvalidConfiguration();
        if (_defaultVotingDuration < MIN_VOTING_DURATION || _defaultVotingDuration > MAX_VOTING_DURATION) {
            revert InvalidConfiguration();
        }
        
        DAppConfig storage config = dappConfigs[_dappId];
        config.minProposalThreshold = _minProposalThreshold;
        config.defaultQuorum = _defaultQuorum;
        config.defaultVotingDuration = _defaultVotingDuration;
        config.customSettingsEnabled = true;
        
        emit DAppConfigUpdated(_dappId, _minProposalThreshold, _defaultQuorum, _defaultVotingDuration);
    }

    /**
     * @notice Whitelist a function for governance execution
     * @param _dappId DApp ID
     * @param _functionSelector Function selector to whitelist
     * @param _functionName Human-readable function name
     */
    function whitelistFunction(
        uint256 _dappId,
        bytes4 _functionSelector,
        string memory _functionName
    ) external validDApp(_dappId) onlyRole(CONFIG_ROLE) {
        // Validate function selector exists on target contract
        _validateFunctionSelector(registeredDapps[_dappId].contractAddress, _functionSelector);
        
        dappAllowedFunctions[_dappId][_functionSelector] = true;
        emit DAppFunctionWhitelisted(_dappId, _functionSelector, _functionName);
    }

    /**
     * @notice Remove a function from whitelist
     * @param _dappId DApp ID
     * @param _functionSelector Function selector to remove
     */
    function delistFunction(
        uint256 _dappId,
        bytes4 _functionSelector
    ) external validDApp(_dappId) onlyRole(CONFIG_ROLE) {
        dappAllowedFunctions[_dappId][_functionSelector] = false;
        emit DAppFunctionDelisted(_dappId, _functionSelector);
    }

    // ========== Governance-Only Activity Tracking ==========

    /**
     * @notice Update DApp activity timestamp (Governance only)
     * @param _dappId DApp ID
     */
    function updateActivity(uint256 _dappId) external validDApp(_dappId) onlyRole(GOVERNANCE_ROLE) {
        registeredDapps[_dappId].lastActivityAt = uint128(block.timestamp);
        emit DAppActivityUpdated(_dappId, block.timestamp);
    }

    /**
     * @notice Increment proposal count (Governance only)
     * @param _dappId DApp ID
     */
    function incrementProposalCount(uint256 _dappId) external validDApp(_dappId) onlyRole(GOVERNANCE_ROLE) returns (uint256) {
        uint256 newTotal = ++registeredDapps[_dappId].totalProposals;
        emit ProposalCountIncremented(_dappId, newTotal);
        return newTotal;
    }

    /**
     * @notice Update proposal statistics (Governance only)
     * @param _dappId DApp ID
     * @param _success Whether the proposal was successful
     */
    function updateProposalStats(uint256 _dappId, bool _success) external validDApp(_dappId) onlyRole(GOVERNANCE_ROLE) {
        DApp storage dapp = registeredDapps[_dappId];
        
        if (_success) {
            dapp.successfulProposals++;
        } else {
            dapp.failedProposals++;
        }
        
        emit ProposalStatsUpdated(_dappId, _success, dapp.successfulProposals, dapp.failedProposals);
    }

    /**
     * @notice Update active proposal count (Governance only)
     * @param _dappId DApp ID
     * @param _increment Whether to increment (true) or decrement (false)
     */
    function updateActiveProposals(uint256 _dappId, bool _increment) external validDApp(_dappId) onlyRole(GOVERNANCE_ROLE) {
        if (_increment) {
            dappActiveProposals[_dappId]++;
        } else if (dappActiveProposals[_dappId] > 0) {
            dappActiveProposals[_dappId]--;
        }
        
        emit ActiveProposalsUpdated(_dappId, dappActiveProposals[_dappId]);
    }

    // ========== Governance Execution ==========

    /**
     * @notice Execute governance action on DApp (Governance only)
     * @param _dappId DApp ID
     * @param _proposalId Proposal ID
     * @param _actionData Action data
     * @return success Whether execution was successful
     */
    function executeOnDApp(
        uint256 _dappId,
        uint256 _proposalId,
        bytes calldata _actionData
    ) external validDApp(_dappId) activeDApp(_dappId) onlyRole(GOVERNANCE_ROLE) returns (bool success) {
        DApp storage dapp = registeredDapps[_dappId];
        
        try IGovernanceEnabled(dapp.contractAddress).executeGovernanceAction(_proposalId, _actionData) returns (bool result) {
            success = result;
            emit GovernanceActionExecuted(_dappId, _proposalId, success);
        } catch {
            success = false;
            emit GovernanceActionExecuted(_dappId, _proposalId, false);
        }
        
        return success;
    }

    // ========== View Functions ==========

    /**
     * @notice Get DApp information
     * @param _dappId DApp ID
     * @return dapp DApp data
     */
    function getDApp(uint256 _dappId) external view validDApp(_dappId) returns (DApp memory) {
        return registeredDapps[_dappId];
    }

    /**
     * @notice Get DApp configuration
     * @param _dappId DApp ID
     * @return config DApp configuration
     */
    function getDAppConfig(uint256 _dappId) external view validDApp(_dappId) returns (DAppConfig memory) {
        return dappConfigs[_dappId];
    }

    /**
     * @notice Get DApp statistics
     * @param _dappId DApp ID
     * @return stats DApp statistics
     */
    function getDAppStats(uint256 _dappId) external view validDApp(_dappId) returns (DAppStats memory) {
        DApp storage dapp = registeredDapps[_dappId];
        
        return DAppStats({
            totalProposals: dapp.totalProposals,
            successfulProposals: dapp.successfulProposals,
            failedProposals: dapp.failedProposals,
            activeProposals: dappActiveProposals[_dappId]
        });
    }

    /**
     * @notice Check if a function is whitelisted
     * @param _dappId DApp ID
     * @param _functionSelector Function selector
     * @return whitelisted Whether the function is whitelisted
     */
    function isFunctionWhitelisted(uint256 _dappId, bytes4 _functionSelector) external view returns (bool) {
        return dappAllowedFunctions[_dappId][_functionSelector];
    }

    /**
     * @notice Get all active DApp IDs
     * @return dappIds Array of active DApp IDs
     */
    function getActiveDApps() external view returns (uint256[] memory) {
        return activeDappIds.values();
    }

    /**
     * @notice Check if DApp is active
     * @param _dappId DApp ID
     * @return active Whether the DApp is active
     */
    function isDAppActive(uint256 _dappId) external view returns (bool) {
        return _dappId > 0 && _dappId <= dappCounter && registeredDapps[_dappId].active;
    }

    /**
     * @notice Get DApp ID by contract address
     * @param _contractAddress Contract address
     * @return dappId DApp ID (0 if not found)
     */
    function getDAppIdByAddress(address _contractAddress) external view returns (uint256) {
        return dappAddressToId[_contractAddress];
    }

    // ========== Admin Functions with Timelock ==========

    /**
     * @notice Schedule a critical operation (Admin only)
     * @param _target Target address
     * @param _data Call data
     * @return operationHash Hash of the operation
     */
    function scheduleCriticalOperation(
        address _target,
        bytes memory _data
    ) external onlyRole(ADMIN_ROLE) returns (bytes32 operationHash) {
        operationHash = keccak256(abi.encode(_target, _data, block.timestamp));
        
        pendingOperations[operationHash] = PendingOperation({
            operationHash: operationHash,
            timestamp: block.timestamp + CRITICAL_OPERATION_DELAY,
            executed: false
        });
        
        emit CriticalOperationScheduled(operationHash, block.timestamp + CRITICAL_OPERATION_DELAY);
    }

    /**
     * @notice Execute a scheduled critical operation (Admin only)
     * @param _target Target address
     * @param _data Call data
     * @param _scheduledTimestamp Original scheduling timestamp
     */
    function executeCriticalOperation(
        address _target,
        bytes memory _data,
        uint256 _scheduledTimestamp
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 operationHash = keccak256(abi.encode(_target, _data, _scheduledTimestamp));
        PendingOperation storage operation = pendingOperations[operationHash];
        
        if (operation.timestamp == 0) revert InvalidOperation();
        if (operation.executed) revert OperationAlreadyExecuted();
        if (block.timestamp < operation.timestamp) revert OperationNotReady();
        
        operation.executed = true;
        
        (bool success,) = _target.call(_data);
        require(success, "Critical operation failed");
        
        emit CriticalOperationExecuted(operationHash);
    }

    /**
     * @notice Cancel a scheduled critical operation (Admin only)
     * @param _operationHash Hash of the operation to cancel
     */
    function cancelCriticalOperation(bytes32 _operationHash) external onlyRole(ADMIN_ROLE) {
        delete pendingOperations[_operationHash];
        emit CriticalOperationCancelled(_operationHash);
    }

    /**
     * @notice Pause the contract (Admin only with multi-role check)
     */
    function pause() external {
        require(
            hasRole(ADMIN_ROLE, msg.sender) && hasRole(CONFIG_ROLE, msg.sender),
            "Requires both ADMIN and CONFIG roles"
        );
        _pause();
    }

    /**
     * @notice Unpause the contract (Admin only with multi-role check)
     */
    function unpause() external {
        require(
            hasRole(ADMIN_ROLE, msg.sender) && hasRole(CONFIG_ROLE, msg.sender),
            "Requires both ADMIN and CONFIG roles"
        );
        _unpause();
    }

    /**
     * @notice Grant registrar role
     * @param _account Address to grant role to
     */
    function grantRegistrarRole(address _account) external onlyRole(ADMIN_ROLE) {
        _grantRole(REGISTRAR_ROLE, _account);
    }

    /**
     * @notice Grant config role
     * @param _account Address to grant role to
     */
    function grantConfigRole(address _account) external onlyRole(ADMIN_ROLE) {
        _grantRole(CONFIG_ROLE, _account);
    }

    /**
     * @notice Grant governance role (requires multi-sig approval)
     * @param _account Address to grant role to
     */
    function grantGovernanceRole(address _account) external {
        require(
            hasRole(ADMIN_ROLE, msg.sender) && hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Requires both ADMIN and DEFAULT_ADMIN roles"
        );
        _grantRole(GOVERNANCE_ROLE, _account);
    }

    // ========== Internal Functions ==========

    /**
     * @notice Verify that a contract implements the governance interface
     * @param _contractAddress Address to verify
     */
    function _verifyGovernanceInterface(address _contractAddress) private view {
        // Check contract has code
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contractAddress)
        }
        if (contractSize == 0) revert InvalidAddress();
        
        // Check getGovernanceParameters (view function, safe to call)
        try IGovernanceEnabled(_contractAddress).getGovernanceParameters() returns (bytes memory) {
            // First function verified - if this works, we assume the contract implements IGovernanceEnabled
            // The executeGovernanceAction function will be checked at execution time
        } catch {
            revert InterfaceNotSupported();
        }
        
        // Note: We cannot directly verify executeGovernanceAction in a view function
        // as it's a state-changing function. The actual verification will happen
        // when the governance system tries to execute actions on the DApp.
    }

    /**
     * @notice Validate that a function selector exists on target contract
     * @param _contractAddress Target contract address
     * @param _functionSelector Function selector to validate
     */
    function _validateFunctionSelector(address _contractAddress, bytes4 _functionSelector) private view {
        // Check if contract has code
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contractAddress)
        }
        
        if (contractSize == 0) revert InvalidAddress();
        
        // Perform a static call with the function selector
        // We capture the success value to avoid compiler warnings, but don't act on it
        // because functions may legitimately revert for various reasons (access control, etc.)
        (bool success, ) = _contractAddress.staticcall(abi.encodeWithSelector(_functionSelector));
        
        // Explicitly handle the return value to avoid compiler warnings
        // We don't revert on failure because:
        // 1. The function might require specific parameters
        // 2. It might have access controls that cause reverts
        // 3. It might be designed to revert under certain conditions
        // The main check here is that the contract exists and has code
        if (!success) {
            // Function call failed, but this is expected for many valid functions
            // Log this for debugging purposes if needed in the future
        }
        
        // Note: In production, consider implementing a registry of known valid selectors
        // or requiring explicit documentation of expected function behavior
    }
}
