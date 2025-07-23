// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./PayrollFlow.sol";
import "./interfaces/IPayrollFlowImplementation.sol";

/**
 * @title EnhancedPayrollFlowManager V2
 * @author CIFI Wealth Management Module V2 - Security Enhanced
 * @notice Integrated Payroll NFT system for revenue distribution with enhanced security
 * @dev Combines flow management with ERC721 payroll tokens with comprehensive security features
 */
contract EnhancedPayrollFlowManagerV2 is 
    IERC721, 
    IERC721Metadata, 
    ReentrancyGuard, 
    Pausable,
    AccessControl 
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ERC165Checker for address;
    using Counters for Counters.Counter;
    
    // ============ Constants ============
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public constant FEE_PRECISION = 1000000; // Higher precision for fee calculations
    uint256 public constant MAX_TOKEN_ID = 10000000; // Maximum payroll token ID
    uint256 public constant MAX_BATCH_SIZE = 100; // Maximum batch operation size
    uint256 public constant TIMELOCK_DURATION = 2 days; // Timelock for critical operations
    
    string public constant name = "CIFI Payroll Rights V2";
    string public constant symbol = "CIFI-PAY-V2";
    
    // ============ State Variables ============
    
    // ERC721 State
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    
    // Payroll Token State
    struct PayrollToken {
        uint256 governanceTokenId;
        address governanceContract;
        uint256 claimedAt;
        bool active;
        bool transferable; // Per-token transfer control
        string metadata;
    }
    
    mapping(uint256 => PayrollToken) public payrollTokens;
    mapping(address => mapping(uint256 => uint256)) public governanceToPayroll;
    mapping(uint256 => bool) public tokenTransferEnabled; // Per-token transfer control
    
    // Flow Management State
    struct FlowInfo {
        address flowContract;
        address nftContract;
        address manager;
        address treasury;
        uint256 deployedAt;
        bool active;
        bool usesPayrollNFTs;
        uint256 totalDistributed;
        uint256 lastDistribution;
        string metadata;
    }
    
    // Enhanced storage with EnumerableSet
    mapping(uint256 => FlowInfo) public flows;
    mapping(address => uint256) public flowToId;
    EnumerableSet.UintSet private activeFlowIds;
    mapping(address => EnumerableSet.UintSet) private managerFlowIds;
    mapping(address => EnumerableSet.UintSet) private nftContractFlowIds;
    EnumerableSet.AddressSet private eligibleGovernanceContracts;
    
    // Security and Configuration
    Counters.Counter private _tokenIdCounter;
    Counters.Counter private _flowIdCounter;
    address public feeRecipient;
    uint256 public feePercentage;
    address public flowImplementation; // Verified implementation for factory pattern
    bool public globalTransfersEnabled;
    bool public claimingEnabled = true;
    
    // Timelock State
    struct TimelockOperation {
        bytes32 operationId;
        uint256 timestamp;
        bool executed;
        bytes data;
    }
    
    mapping(bytes32 => TimelockOperation) public timelockOperations;
    
    // Emergency State
    uint256 public emergencyPauseTimestamp;
    uint256 public constant EMERGENCY_PAUSE_DURATION = 7 days;
    
    // ============ Events ============
    
    // Enhanced Events with indexed parameters
    event PayrollTokenClaimed(
        address indexed claimer,
        uint256 indexed payrollTokenId,
        address indexed governanceContract,
        uint256 governanceTokenId,
        uint256 timestamp
    );
    
    event PayrollTokenRevoked(
        uint256 indexed payrollTokenId,
        address indexed revoker,
        uint256 timestamp
    );
    
    event FlowDeployed(
        address indexed flow,
        address indexed nftContract,
        address indexed manager,
        uint256 flowId,
        bool usesPayrollNFTs,
        uint256 timestamp
    );
    
    event FlowTerminated(
        address indexed flow,
        uint256 indexed flowId,
        uint256 remainingBalance,
        address indexed initiator
    );
    
    event FeeUpdated(
        uint256 oldFeePercentage,
        uint256 newFeePercentage,
        address indexed updater
    );
    
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient,
        address indexed updater
    );
    
    event AdminTransferred(
        address indexed oldAdmin,
        address indexed newAdmin,
        uint256 timestamp
    );
    
    event TimelockOperationQueued(
        bytes32 indexed operationId,
        uint256 executionTime,
        address indexed initiator
    );
    
    event TimelockOperationExecuted(
        bytes32 indexed operationId,
        address indexed executor
    );
    
    event EmergencyPause(
        address indexed initiator,
        uint256 pauseUntil
    );
    
    // ============ Errors with Parameters ============
    
    error Unauthorized(address caller, bytes32 requiredRole);
    error InvalidConfiguration(string reason);
    error FlowNotFound(address flow);
    error InvalidFee(uint256 provided, uint256 maximum);
    error ZeroAddress(string parameter);
    error InvalidNFTContract(address contractAddress, string reason);
    error AlreadyClaimed(address governanceContract, uint256 tokenId);
    error NotGovernanceTokenOwner(address caller, address actualOwner);
    error ClaimingDisabled(uint256 timestamp);
    error TransfersDisabled(uint256 tokenId);
    error TokenDoesNotExist(uint256 tokenId);
    error NotTokenOwner(address caller, uint256 tokenId);
    error ContractNotEligible(address contractAddress);
    error BatchSizeExceeded(uint256 provided, uint256 maximum);
    error TokenIdLimitExceeded(uint256 tokenId, uint256 maximum);
    error TimelockNotReady(bytes32 operationId, uint256 readyTime);
    error OperationAlreadyExecuted(bytes32 operationId);
    error FlowHasBalance(address flow, uint256 balance);
    error InvalidFlowImplementation(address implementation);
    error ExternalCallFailed(address target, string reason);
    
    // ============ Modifiers ============
    
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) {
            revert Unauthorized(msg.sender, role);
        }
        _;
    }
    
    modifier flowExists(address flow) {
        if (flowToId[flow] == 0) {
            revert FlowNotFound(flow);
        }
        _;
    }
    
    modifier notZeroAddress(address addr, string memory paramName) {
        if (addr == address(0)) {
            revert ZeroAddress(paramName);
        }
        _;
    }
    
    modifier withinBatchLimit(uint256 size) {
        if (size > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(size, MAX_BATCH_SIZE);
        }
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _admin,
        address _feeRecipient,
        uint256 _feePercentage,
        address _flowImplementation,
        address[] memory _eligibleGovernanceContracts
    ) 
        notZeroAddress(_admin, "admin")
        notZeroAddress(_feeRecipient, "feeRecipient")
        notZeroAddress(_flowImplementation, "flowImplementation")
    {
        if (_feePercentage > MAX_FEE) {
            revert InvalidFee(_feePercentage, MAX_FEE);
        }
        
        // Verify flow implementation
        if (!_isValidFlowImplementation(_flowImplementation)) {
            revert InvalidFlowImplementation(_flowImplementation);
        }
        
        feeRecipient = _feeRecipient;
        feePercentage = _feePercentage;
        flowImplementation = _flowImplementation;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(DEPLOYER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        // Initialize eligible governance contracts
        for (uint256 i = 0; i < _eligibleGovernanceContracts.length; i++) {
            address govContract = _eligibleGovernanceContracts[i];
            if (govContract != address(0) && _isERC721(govContract)) {
                eligibleGovernanceContracts.add(govContract);
            }
        }
        
        // Start token ID counter at 1
        _tokenIdCounter.increment();
    }
    
    // ============ ERC721 Implementation ============
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(IERC721, AccessControl) 
        returns (bool) 
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    function balanceOf(address owner) public view returns (uint256) {
        if (owner == address(0)) {
            revert ZeroAddress("owner");
        }
        return _balances[owner];
    }
    
    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) {
            revert TokenDoesNotExist(tokenId);
        }
        return owner;
    }
    
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        if (!_exists(tokenId)) {
            revert TokenDoesNotExist(tokenId);
        }
        
        PayrollToken memory token = payrollTokens[tokenId];
        return string(abi.encodePacked(
            "data:application/json;base64,",
            _base64Encode(abi.encodePacked(
                '{"name":"Payroll Rights V2 #',
                _toString(tokenId),
                '","description":"Enhanced revenue distribution rights for governance token #',
                _toString(token.governanceTokenId),
                '","attributes":[{"trait_type":"Governance Contract","value":"',
                _toHexString(token.governanceContract),
                '"},{"trait_type":"Governance Token ID","value":"',
                _toString(token.governanceTokenId),
                '"},{"trait_type":"Transferable","value":"',
                token.transferable ? "true" : "false",
                '"}]}'
            ))
        ));
    }
    
    function approve(address to, uint256 tokenId) public whenNotPaused {
        address owner = ownerOf(tokenId);
        if (to == owner) {
            revert InvalidConfiguration("Cannot approve to self");
        }
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert NotTokenOwner(msg.sender, tokenId);
        }
        
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }
    
    function getApproved(uint256 tokenId) public view returns (address) {
        if (!_exists(tokenId)) {
            revert TokenDoesNotExist(tokenId);
        }
        return _tokenApprovals[tokenId];
    }
    
    function setApprovalForAll(address operator, bool approved) public whenNotPaused {
        if (operator == msg.sender) {
            revert InvalidConfiguration("Cannot approve self as operator");
        }
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }
    
    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }
    
    function transferFrom(address from, address to, uint256 tokenId) 
        public 
        whenNotPaused 
        nonReentrant 
    {
        _requireTransferable(tokenId);
        if (!_isApprovedOrOwner(msg.sender, tokenId)) {
            revert NotTokenOwner(msg.sender, tokenId);
        }
        _transfer(from, to, tokenId);
    }
    
    function safeTransferFrom(address from, address to, uint256 tokenId) 
        public 
        whenNotPaused 
        nonReentrant 
    {
        safeTransferFrom(from, to, tokenId, "");
    }
    
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) 
        public 
        whenNotPaused 
        nonReentrant 
    {
        _requireTransferable(tokenId);
        if (!_isApprovedOrOwner(msg.sender, tokenId)) {
            revert NotTokenOwner(msg.sender, tokenId);
        }
        _safeTransfer(from, to, tokenId, data);
    }
    
    // ============ Payroll Token Functions ============
    
    /**
     * @notice Claim a payroll NFT using governance NFT ownership
     * @param governanceContract Address of governance NFT contract
     * @param governanceTokenId ID of governance NFT owned
     * @return payrollTokenId The minted payroll token ID
     */
    function claimPayrollToken(
        address governanceContract,
        uint256 governanceTokenId
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 payrollTokenId) 
    {
        if (!claimingEnabled) {
            revert ClaimingDisabled(block.timestamp);
        }
        
        if (!eligibleGovernanceContracts.contains(governanceContract)) {
            revert ContractNotEligible(governanceContract);
        }
        
        // Check if already claimed
        if (governanceToPayroll[governanceContract][governanceTokenId] != 0) {
            revert AlreadyClaimed(governanceContract, governanceTokenId);
        }
        
        // Safe external call to verify ownership
        address owner;
        try IERC721(governanceContract).ownerOf(governanceTokenId) returns (address _owner) {
            owner = _owner;
        } catch {
            revert ExternalCallFailed(governanceContract, "Failed to get token owner");
        }
        
        if (owner != msg.sender) {
            revert NotGovernanceTokenOwner(msg.sender, owner);
        }
        
        // Get next token ID with limit check
        payrollTokenId = _tokenIdCounter.current();
        if (payrollTokenId > MAX_TOKEN_ID) {
            revert TokenIdLimitExceeded(payrollTokenId, MAX_TOKEN_ID);
        }
        _tokenIdCounter.increment();
        
        // Mint payroll NFT
        _mint(msg.sender, payrollTokenId);
        
        // Store payroll token data
        payrollTokens[payrollTokenId] = PayrollToken({
            governanceTokenId: governanceTokenId,
            governanceContract: governanceContract,
            claimedAt: block.timestamp,
            active: true,
            transferable: false, // Soulbound by default
            metadata: ""
        });
        
        // Create mapping
        governanceToPayroll[governanceContract][governanceTokenId] = payrollTokenId;
        
        emit PayrollTokenClaimed(
            msg.sender, 
            payrollTokenId, 
            governanceContract, 
            governanceTokenId,
            block.timestamp
        );
    }
    
    /**
     * @notice Batch claim payroll tokens for multiple governance NFTs
     * @param governanceContract Address of governance NFT contract
     * @param governanceTokenIds Array of governance NFT IDs
     */
    function batchClaimPayrollTokens(
        address governanceContract,
        uint256[] calldata governanceTokenIds
    ) 
        external 
        whenNotPaused 
        withinBatchLimit(governanceTokenIds.length) 
    {
        for (uint256 i = 0; i < governanceTokenIds.length; i++) {
            // Individual claims will revert if any fail
            this.claimPayrollToken(governanceContract, governanceTokenIds[i]);
        }
    }
    
    // ============ Enhanced Flow Deployment with Factory Pattern ============
    
    /**
     * @notice Deploy a flow using verified implementation
     * @param config Flow configuration parameters
     * @return flow Deployed flow contract address
     */
    function deployFlow(
        PayrollFlow.FlowConfig memory config,
        bool usesPayrollNFTs,
        string calldata metadata
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        onlyRole(DEPLOYER_ROLE) 
        returns (address flow) 
    {
        // Validate configuration
        _validateFlowConfig(config);
        
        // Deploy using clone pattern for gas efficiency and security
        flow = _deployFlowClone(config);
        
        // Register flow
        uint256 flowId = _flowIdCounter.current();
        _flowIdCounter.increment();
        
        flows[flowId] = FlowInfo({
            flowContract: flow,
            nftContract: config.nftContract,
            manager: config.manager,
            treasury: config.treasury,
            deployedAt: block.timestamp,
            active: true,
            usesPayrollNFTs: usesPayrollNFTs,
            totalDistributed: 0,
            lastDistribution: 0,
            metadata: metadata
        });
        
        flowToId[flow] = flowId;
        activeFlowIds.add(flowId);
        managerFlowIds[config.manager].add(flowId);
        nftContractFlowIds[config.nftContract].add(flowId);
        
        emit FlowDeployed(
            flow, 
            config.nftContract, 
            config.manager, 
            flowId, 
            usesPayrollNFTs,
            block.timestamp
        );
    }
    
    // ============ Flow Management Functions ============
    
    /**
     * @notice Terminate a flow with balance check
     * @param flow Address of flow to terminate
     */
    function terminateFlow(address payable flow) 
        external 
        whenNotPaused 
        nonReentrant 
        flowExists(flow) 
    {
        uint256 flowId = flowToId[flow];
        FlowInfo storage info = flows[flowId];
        
        // Check authorization
        if (!hasRole(ADMIN_ROLE, msg.sender) && info.manager != msg.sender) {
            revert Unauthorized(msg.sender, MANAGER_ROLE);
        }
        
        // Check flow balance before termination
        uint256 flowBalance = _getFlowBalance(flow);
        if (flowBalance > 0) {
            revert FlowHasBalance(flow, flowBalance);
        }
        
        // Update state
        info.active = false;
        activeFlowIds.remove(flowId);
        
        // Safe external call to terminate
        try PayrollFlow(flow).terminate() {
            emit FlowTerminated(flow, flowId, 0, msg.sender);
        } catch {
            revert ExternalCallFailed(flow, "Failed to terminate flow");
        }
    }
    
    /**
     * @notice Process payment with fee (with reentrancy protection)
     * @param flow Flow contract to receive payment
     * @param token Token address (0x0 for ETH)
     * @param amount Payment amount
     */
    function processPaymentWithFee(
        address payable flow,
        address token,
        uint256 amount
    ) 
        external 
        payable 
        whenNotPaused 
        nonReentrant 
        flowExists(flow) 
    {
        if (amount == 0) {
            revert InvalidConfiguration("Amount cannot be zero");
        }
        
        // Calculate fee with higher precision
        uint256 fee = (amount * feePercentage * 100) / FEE_PRECISION;
        uint256 netAmount = amount - fee;
        
        if (token == address(0)) {
            // ETH payment
            if (msg.value != amount) {
                revert InvalidConfiguration("Incorrect ETH amount");
            }
            
            // Effects before interactions
            flows[flowToId[flow]].totalDistributed += netAmount;
            flows[flowToId[flow]].lastDistribution = block.timestamp;
            
            // Transfer fee first (safer pattern)
            if (fee > 0) {
                (bool feeSuccess,) = feeRecipient.call{value: fee}("");
                if (!feeSuccess) {
                    revert ExternalCallFailed(feeRecipient, "Fee transfer failed");
                }
            }
            
            // Transfer to flow
            (bool flowSuccess,) = flow.call{value: netAmount}("");
            if (!flowSuccess) {
                revert ExternalCallFailed(flow, "Flow transfer failed");
            }
        } else {
            // ERC20 payment
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            
            // Effects before interactions
            flows[flowToId[flow]].totalDistributed += netAmount;
            flows[flowToId[flow]].lastDistribution = block.timestamp;
            
            // Transfer fee
            if (fee > 0) {
                IERC20(token).safeTransfer(feeRecipient, fee);
            }
            
            // Transfer to flow
            IERC20(token).safeTransfer(flow, netAmount);
        }
    }
    
    // ============ Admin Functions with Timelock ============
    
    /**
     * @notice Queue admin operation with timelock
     * @param target Target contract
     * @param data Encoded function call
     * @return operationId Timelock operation ID
     */
    function queueTimelockOperation(
        address target,
        bytes calldata data
    ) 
        external 
        onlyRole(ADMIN_ROLE) 
        returns (bytes32 operationId) 
    {
        operationId = keccak256(abi.encode(target, data, block.timestamp));
        
        timelockOperations[operationId] = TimelockOperation({
            operationId: operationId,
            timestamp: block.timestamp + TIMELOCK_DURATION,
            executed: false,
            data: data
        });
        
        emit TimelockOperationQueued(
            operationId, 
            block.timestamp + TIMELOCK_DURATION, 
            msg.sender
        );
    }
    
    /**
     * @notice Execute timelock operation
     * @param operationId Operation to execute
     */
    function executeTimelockOperation(bytes32 operationId) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        TimelockOperation storage operation = timelockOperations[operationId];
        
        if (operation.executed) {
            revert OperationAlreadyExecuted(operationId);
        }
        
        if (block.timestamp < operation.timestamp) {
            revert TimelockNotReady(operationId, operation.timestamp);
        }
        
        operation.executed = true;
        
        // Execute the operation
        (bool success,) = address(this).call(operation.data);
        if (!success) {
            revert ExternalCallFailed(address(this), "Timelock execution failed");
        }
        
        emit TimelockOperationExecuted(operationId, msg.sender);
    }
    
    /**
     * @notice Update fee with validation
     * @param newFeePercentage New fee percentage (in basis points)
     */
    function updateFee(uint256 newFeePercentage) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (newFeePercentage > MAX_FEE) {
            revert InvalidFee(newFeePercentage, MAX_FEE);
        }
        
        uint256 oldFee = feePercentage;
        feePercentage = newFeePercentage;
        
        emit FeeUpdated(oldFee, newFeePercentage, msg.sender);
    }
    
    /**
     * @notice Update fee recipient
     * @param newRecipient New fee recipient address
     */
    function updateFeeRecipient(address newRecipient) 
        external 
        onlyRole(ADMIN_ROLE) 
        notZeroAddress(newRecipient, "feeRecipient") 
    {
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        
        emit FeeRecipientUpdated(oldRecipient, newRecipient, msg.sender);
    }
    
    /**
     * @notice Emergency pause with automatic unpause
     */
    function emergencyPause() 
        external 
        onlyRole(PAUSER_ROLE) 
    {
        _pause();
        emergencyPauseTimestamp = block.timestamp;
        
        emit EmergencyPause(msg.sender, block.timestamp + EMERGENCY_PAUSE_DURATION);
    }
    
    /**
     * @notice Check and execute automatic unpause
     */
    function checkAutomaticUnpause() external {
        if (paused() && 
            emergencyPauseTimestamp > 0 && 
            block.timestamp > emergencyPauseTimestamp + EMERGENCY_PAUSE_DURATION
        ) {
            _unpause();
            emergencyPauseTimestamp = 0;
        }
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get active flows with pagination
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return flowIds Array of active flow IDs
     */
    function getActiveFlows(uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory flowIds) 
    {
        uint256 totalActive = activeFlowIds.length();
        
        if (offset >= totalActive) {
            return new uint256[](0);
        }
        
        uint256 end = offset + limit;
        if (end > totalActive) {
            end = totalActive;
        }
        
        flowIds = new uint256[](end - offset);
        for (uint256 i = 0; i < flowIds.length; i++) {
            flowIds[i] = activeFlowIds.at(offset + i);
        }
    }
    
    /**
     * @notice Get manager's flows with pagination
     * @param manager Manager address
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return flowIds Array of flow IDs
     */
    function getManagerFlows(address manager, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory flowIds) 
    {
        uint256 total = managerFlowIds[manager].length();
        
        if (offset >= total) {
            return new uint256[](0);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        flowIds = new uint256[](end - offset);
        for (uint256 i = 0; i < flowIds.length; i++) {
            flowIds[i] = managerFlowIds[manager].at(offset + i);
        }
    }
    
    /**
     * @notice Check if governance contract is eligible
     * @param contractAddress Contract to check
     * @return eligible Whether contract is eligible
     */
    function isEligibleGovernanceContract(address contractAddress) 
        external 
        view 
        returns (bool) 
    {
        return eligibleGovernanceContracts.contains(contractAddress);
    }
    
    /**
     * @notice Get total number of eligible governance contracts
     * @return count Number of eligible contracts
     */
    function getEligibleGovernanceContractsCount() 
        external 
        view 
        returns (uint256) 
    {
        return eligibleGovernanceContracts.length();
    }
    
    // ============ Internal Functions ============
    
    function _mint(address to, uint256 tokenId) internal {
        _balances[to]++;
        _owners[tokenId] = to;
        
        emit Transfer(address(0), to, tokenId);
    }
    
    function _transfer(address from, address to, uint256 tokenId) 
        internal 
        notZeroAddress(to, "to") 
    {
        if (ownerOf(tokenId) != from) {
            revert NotTokenOwner(from, tokenId);
        }
        
        delete _tokenApprovals[tokenId];
        
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
        
        emit Transfer(from, to, tokenId);
    }
    
    function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data) internal {
        _transfer(from, to, tokenId);
        if (_isContract(to)) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                if (retval != IERC721Receiver.onERC721Received.selector) {
                    revert InvalidConfiguration("Transfer to non ERC721Receiver");
                }
            } catch {
                revert ExternalCallFailed(to, "Failed to call onERC721Received");
            }
        }
    }
    
    function _requireTransferable(uint256 tokenId) internal view {
        if (!globalTransfersEnabled && !payrollTokens[tokenId].transferable) {
            revert TransfersDisabled(tokenId);
        }
    }
    
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }
    
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }
    
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
    
    function _isERC721(address contractAddress) internal view returns (bool) {
        return contractAddress.supportsInterface(type(IERC721).interfaceId);
    }
    
    function _isValidFlowImplementation(address implementation) internal view returns (bool) {
        // Check if implementation has required interface
        return IPayrollFlowImplementation(implementation).isPayrollFlow();
    }
    
    function _validateFlowConfig(PayrollFlow.FlowConfig memory config) internal view {
        if (config.nftContract == address(0)) {
            revert ZeroAddress("nftContract");
        }
        if (config.manager == address(0)) {
            revert ZeroAddress("manager");
        }
        if (!_isERC721(config.nftContract) && !config.isERC1155) {
            revert InvalidNFTContract(config.nftContract, "Not ERC721 or ERC1155");
        }
    }
    
    function _deployFlowClone(PayrollFlow.FlowConfig memory config) internal returns (address) {
        // Deploy using CREATE2 for deterministic addresses
        bytes32 salt = keccak256(abi.encode(config, block.timestamp, msg.sender));
        bytes memory bytecode = _getCloneBytecode(flowImplementation);
        
        address flow;
        assembly {
            flow := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        if (flow == address(0)) {
            revert InvalidConfiguration("Flow deployment failed");
        }
        
        // Initialize the clone
        IPayrollFlowImplementation(flow).initialize(config);
        
        return flow;
    }
    
    function _getCloneBytecode(address implementation) internal pure returns (bytes memory) {
        // Minimal proxy bytecode
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
    
    function _getFlowBalance(address flow) internal view returns (uint256) {
        // Get ETH balance
        uint256 ethBalance = flow.balance;
        
        // Could be extended to check ERC20 balances
        return ethBalance;
    }
    
    // Utility functions
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
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint160(addr) >> (8 * (19 - i))));
            buffer[2 + i * 2] = _hexChar(uint8(b) >> 4);
            buffer[3 + i * 2] = _hexChar(uint8(b) & 0x0f);
        }
        return string(buffer);
    }
    
    function _hexChar(uint8 value) internal pure returns (bytes1) {
        if (value < 10) return bytes1(value + 48);
        return bytes1(value + 87);
    }
    
    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        string memory result = new string(encodedLen);
        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for {
                let dataPtr := data
                let endPtr := add(dataPtr, mload(data))
            } lt(dataPtr, endPtr) {
            } {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 {
                mstore(sub(resultPtr, 2), shl(240, 0x3d3d))
            }
            case 2 {
                mstore(sub(resultPtr, 1), shl(248, 0x3d))
            }
        }
        return result;
    }
}
