// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// ============ Interfaces and Libraries ============

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }
    
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), "SafeERC20: operation failed");
    }
}

/**
 * @title WealthManagementFactory
 * @author CIFI Wealth Management Module
 * @notice Master factory for deploying complete wealth management suites or individual components with fee distribution
 * @dev Uses a registry pattern - implementations must be deployed separately and registered
 */
contract WealthManagementFactory {
    using SafeERC20 for IERC20;
    
    // ============ Events ============
    
    event SuiteDeployed(
        uint256 indexed suiteId,
        address indexed deployer,
        address multiSigWallet,
        address daoTreasury,
        address payrollFlowManager,
        string projectName
    );
    
    event ComponentDeployed(
        uint256 indexed deploymentId,
        address indexed deployer,
        address contractAddress,
        ComponentType componentType,
        string projectName
    );
    
    event FeeCollected(
        uint256 indexed deploymentId,
        address indexed payer,
        uint256 feeAmount,
        uint256 timestamp
    );
    
    event FeeDistributed(
        address indexed beneficiary,
        uint256 amount,
        uint256 share
    );
    
    event DeploymentFeeUpdated(uint256 suiteFee, uint256 componentFee);
    event FeeTokenUpdated(address indexed newToken);
    event BeneficiaryUpdated(uint256 index, address newBeneficiary, uint256 newShare);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event FactoryPausedStateChanged(bool paused);
    event AuthorizedDeployerUpdated(address indexed deployer, bool authorized);
    event ImplementationUpdated(ComponentType componentType, address newImplementation);
    
    // ============ Errors ============
    
    error Unauthorized();
    error InvalidConfiguration();
    error InvalidFeeToken();
    error InsufficientFeePayment();
    error InvalidBeneficiary();
    error InvalidShares();
    error DeploymentFailed();
    error TransferFailed();
    error FactoryIsPaused();
    error ZeroAddress();
    error InvalidProjectName();
    error SuiteNotFound();
    error ComponentNotFound();
    error ArrayLengthMismatch();
    error TooManyOwners();
    error InvalidThreshold();
    error InvalidComponentType();
    error ImplementationNotSet();
    
    // ============ Enums ============
    
    enum ComponentType {
        MULTI_SIG_WALLET,
        DAO_TREASURY,
        PAYROLL_FLOW_MANAGER
    }
    
    // ============ Constants ============
    
    uint256 public constant SHARE_DENOMINATOR = 100;
    uint256 public constant MAX_PROJECT_NAME_LENGTH = 64;
    uint256 public constant BENEFICIARY_1_SHARE = 30;
    uint256 public constant BENEFICIARY_2_SHARE = 30;
    uint256 public constant BENEFICIARY_3_SHARE = 40;
    uint256 public constant SUITE_FEE = 10000; // 10,000 units for complete suite
    uint256 public constant COMPONENT_FEE = 5000; // 5,000 units per component
    
    // ============ Structs ============
    
    struct Suite {
        address multiSigWallet;
        address daoTreasury;
        address payrollFlowManager;
        address deployer;
        string projectName;
        uint256 deployedAt;
        uint256 feePaid;
        bool active;
    }
    
    struct ComponentDeployment {
        address contractAddress;
        ComponentType componentType;
        address deployer;
        string projectName;
        uint256 deployedAt;
        uint256 feePaid;
        bool active;
        uint256 linkedSuiteId; // 0 if standalone
    }
    
    struct DeploymentParams {
        // MultiSig parameters
        bytes multiSigInitData;
        
        // DAO Treasury parameters
        bytes daoInitData;
        
        // Payroll parameters
        bytes payrollInitData;
        
        // Project metadata
        string projectName;
        string metadata; // IPFS hash or other metadata
    }
    
    struct Beneficiary {
        address recipient;
        uint256 share; // Percentage (out of 100)
        uint256 totalReceived;
    }
    
    // ============ State Variables ============
    
    // Factory configuration
    address public admin;
    address public feeToken;
    uint256 public suiteFee;
    uint256 public componentFee;
    bool public paused;
    
    // Implementation contracts
    mapping(ComponentType => address) public implementations;
    
    // Beneficiaries (30/30/40 split)
    Beneficiary[3] public beneficiaries;
    
    // Suite registry
    uint256 public suiteCount;
    mapping(uint256 => Suite) public suites;
    mapping(address => uint256[]) public deployerSuites;
    mapping(address => uint256) public contractToSuiteId;
    
    // Component registry (for à la carte deployments)
    uint256 public componentCount;
    mapping(uint256 => ComponentDeployment) public components;
    mapping(address => uint256[]) public deployerComponents;
    mapping(address => uint256) public contractToComponentId;
    
    // Access control
    mapping(address => bool) public authorizedDeployers;
    
    // Fee tracking
    uint256 public totalFeesCollected;
    uint256 public totalFeesDistributed;
    
    // Reentrancy guard
    uint256 private locked = 1;
    
    // ============ Modifiers ============
    
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorized() {
        if (!authorizedDeployers[msg.sender] && msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert FactoryIsPaused();
        _;
    }
    
    modifier nonReentrant() {
        require(locked == 1, "Reentrancy");
        locked = 2;
        _;
        locked = 1;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize the factory with fee configuration
     * @param _admin Factory admin address
     * @param _feeToken ERC20 token for fee payment
     * @param _beneficiaries Array of 3 beneficiary addresses
     */
    constructor(
        address _admin,
        address _feeToken,
        address[3] memory _beneficiaries
    ) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_feeToken == address(0)) revert InvalidFeeToken();
        
        for (uint256 i = 0; i < 3; i++) {
            if (_beneficiaries[i] == address(0)) revert InvalidBeneficiary();
        }
        
        admin = _admin;
        feeToken = _feeToken;
        suiteFee = SUITE_FEE;
        componentFee = COMPONENT_FEE;
        
        // Initialize beneficiaries with fixed shares
        beneficiaries[0] = Beneficiary({
            recipient: _beneficiaries[0],
            share: BENEFICIARY_1_SHARE,
            totalReceived: 0
        });
        
        beneficiaries[1] = Beneficiary({
            recipient: _beneficiaries[1],
            share: BENEFICIARY_2_SHARE,
            totalReceived: 0
        });
        
        beneficiaries[2] = Beneficiary({
            recipient: _beneficiaries[2],
            share: BENEFICIARY_3_SHARE,
            totalReceived: 0
        });
        
        // Verify shares total 100%
        uint256 totalShares = BENEFICIARY_1_SHARE + BENEFICIARY_2_SHARE + BENEFICIARY_3_SHARE;
        if (totalShares != SHARE_DENOMINATOR) revert InvalidShares();
        
        authorizedDeployers[_admin] = true;
    }
    
    // ============ Implementation Management ============
    
    /**
     * @notice Set implementation contracts for cloning
     * @param multiSigImpl MultiSigWallet implementation address
     * @param daoImpl DAOTreasury implementation address  
     * @param payrollImpl PayrollFlowManager implementation address
     * @dev Implementation contracts must be deployed separately before calling this
     */
    function setImplementations(
        address multiSigImpl,
        address daoImpl,
        address payrollImpl
    ) external onlyAdmin {
        if (multiSigImpl == address(0) || daoImpl == address(0) || payrollImpl == address(0)) {
            revert ZeroAddress();
        }
        
        implementations[ComponentType.MULTI_SIG_WALLET] = multiSigImpl;
        implementations[ComponentType.DAO_TREASURY] = daoImpl;
        implementations[ComponentType.PAYROLL_FLOW_MANAGER] = payrollImpl;
        
        emit ImplementationUpdated(ComponentType.MULTI_SIG_WALLET, multiSigImpl);
        emit ImplementationUpdated(ComponentType.DAO_TREASURY, daoImpl);
        emit ImplementationUpdated(ComponentType.PAYROLL_FLOW_MANAGER, payrollImpl);
    }
    
    // ============ Suite Deployment Functions ============
    
    /**
     * @notice Deploy a complete wealth management suite using CREATE2
     * @param params Deployment parameters for all components
     * @param salt Salt for deterministic deployment
     * @return suiteId Unique identifier for the deployed suite
     */
    function deploySuite(
        DeploymentParams calldata params,
        bytes32 salt
    ) external whenNotPaused onlyAuthorized nonReentrant returns (uint256 suiteId) {
        // Validate project name
        if (bytes(params.projectName).length == 0 || 
            bytes(params.projectName).length > MAX_PROJECT_NAME_LENGTH) {
            revert InvalidProjectName();
        }
        
        // Ensure implementations are set
        if (implementations[ComponentType.MULTI_SIG_WALLET] == address(0) ||
            implementations[ComponentType.DAO_TREASURY] == address(0) ||
            implementations[ComponentType.PAYROLL_FLOW_MANAGER] == address(0)) {
            revert ImplementationNotSet();
        }
        
        // Collect suite deployment fee
        _collectFee(msg.sender, suiteFee);
        
        // Deploy all components using CREATE2
        address multiSig = _deployWithCreate2(
            implementations[ComponentType.MULTI_SIG_WALLET],
            params.multiSigInitData,
            salt
        );
        
        address daoTreasury = _deployWithCreate2(
            implementations[ComponentType.DAO_TREASURY],
            params.daoInitData,
            keccak256(abi.encode(salt, "dao"))
        );
        
        address payrollManager = _deployWithCreate2(
            implementations[ComponentType.PAYROLL_FLOW_MANAGER],
            params.payrollInitData,
            keccak256(abi.encode(salt, "payroll"))
        );
        
        // Register the suite
        suiteId = ++suiteCount;
        suites[suiteId] = Suite({
            multiSigWallet: multiSig,
            daoTreasury: daoTreasury,
            payrollFlowManager: payrollManager,
            deployer: msg.sender,
            projectName: params.projectName,
            deployedAt: block.timestamp,
            feePaid: suiteFee,
            active: true
        });
        
        // Update mappings
        deployerSuites[msg.sender].push(suiteId);
        contractToSuiteId[multiSig] = suiteId;
        contractToSuiteId[daoTreasury] = suiteId;
        contractToSuiteId[payrollManager] = suiteId;
        
        emit SuiteDeployed(
            suiteId,
            msg.sender,
            multiSig,
            daoTreasury,
            payrollManager,
            params.projectName
        );
        
        emit FeeCollected(suiteId, msg.sender, suiteFee, block.timestamp);
    }
    
    // ============ À La Carte Deployment Functions ============
    
    /**
     * @notice Deploy only a MultiSigWallet
     * @param initData Initialization data for the contract
     * @param projectName Project name for identification
     * @param salt Salt for deterministic deployment
     * @return componentId Unique identifier for the deployment
     */
    function deployMultiSigWallet(
        bytes calldata initData,
        string calldata projectName,
        bytes32 salt
    ) external whenNotPaused onlyAuthorized nonReentrant returns (uint256 componentId) {
        // Validate parameters
        if (bytes(projectName).length == 0 || bytes(projectName).length > MAX_PROJECT_NAME_LENGTH) {
            revert InvalidProjectName();
        }
        
        // Ensure implementation is set
        if (implementations[ComponentType.MULTI_SIG_WALLET] == address(0)) {
            revert ImplementationNotSet();
        }
        
        // Collect component fee
        _collectFee(msg.sender, componentFee);
        
        // Deploy MultiSigWallet
        address multiSig = _deployWithCreate2(
            implementations[ComponentType.MULTI_SIG_WALLET],
            initData,
            salt
        );
        
        // Register component
        componentId = _registerComponent(
            multiSig,
            ComponentType.MULTI_SIG_WALLET,
            projectName,
            0 // No linked suite
        );
    }
    
    /**
     * @notice Deploy only a DAOTreasury
     * @param initData Initialization data for the contract
     * @param projectName Project name for identification
     * @param salt Salt for deterministic deployment
     * @return componentId Unique identifier for the deployment
     */
    function deployDAOTreasury(
        bytes calldata initData,
        string calldata projectName,
        bytes32 salt
    ) external whenNotPaused onlyAuthorized nonReentrant returns (uint256 componentId) {
        // Validate parameters
        if (bytes(projectName).length == 0 || bytes(projectName).length > MAX_PROJECT_NAME_LENGTH) {
            revert InvalidProjectName();
        }
        
        // Ensure implementation is set
        if (implementations[ComponentType.DAO_TREASURY] == address(0)) {
            revert ImplementationNotSet();
        }
        
        // Collect component fee
        _collectFee(msg.sender, componentFee);
        
        // Deploy DAOTreasury
        address daoTreasury = _deployWithCreate2(
            implementations[ComponentType.DAO_TREASURY],
            initData,
            salt
        );
        
        // Register component
        componentId = _registerComponent(
            daoTreasury,
            ComponentType.DAO_TREASURY,
            projectName,
            0 // No linked suite
        );
    }
    
    /**
     * @notice Deploy only a PayrollFlowManager
     * @param initData Initialization data for the contract
     * @param projectName Project name for identification
     * @param salt Salt for deterministic deployment
     * @return componentId Unique identifier for the deployment
     */
    function deployPayrollFlowManager(
        bytes calldata initData,
        string calldata projectName,
        bytes32 salt
    ) external whenNotPaused onlyAuthorized nonReentrant returns (uint256 componentId) {
        // Validate parameters
        if (bytes(projectName).length == 0 || bytes(projectName).length > MAX_PROJECT_NAME_LENGTH) {
            revert InvalidProjectName();
        }
        
        // Ensure implementation is set
        if (implementations[ComponentType.PAYROLL_FLOW_MANAGER] == address(0)) {
            revert ImplementationNotSet();
        }
        
        // Collect component fee
        _collectFee(msg.sender, componentFee);
        
        // Deploy PayrollFlowManager
        address payrollManager = _deployWithCreate2(
            implementations[ComponentType.PAYROLL_FLOW_MANAGER],
            initData,
            salt
        );
        
        // Register component
        componentId = _registerComponent(
            payrollManager,
            ComponentType.PAYROLL_FLOW_MANAGER,
            projectName,
            0 // No linked suite
        );
    }
    
    // ============ Fee Management Functions ============
    
    /**
     * @notice Update deployment fees
     * @param newSuiteFee New fee for complete suite deployment
     * @param newComponentFee New fee for individual component deployment
     */
    function updateDeploymentFees(uint256 newSuiteFee, uint256 newComponentFee) external onlyAdmin {
        if (newSuiteFee == 0 || newComponentFee == 0) revert InvalidConfiguration();
        suiteFee = newSuiteFee;
        componentFee = newComponentFee;
        emit DeploymentFeeUpdated(newSuiteFee, newComponentFee);
    }
    
    /**
     * @notice Update fee token
     * @param newToken New ERC20 token address
     */
    function updateFeeToken(address newToken) external onlyAdmin {
        if (newToken == address(0)) revert InvalidFeeToken();
        feeToken = newToken;
        emit FeeTokenUpdated(newToken);
    }
    
    /**
     * @notice Update beneficiary address
     * @param index Beneficiary index (0, 1, or 2)
     * @param newRecipient New beneficiary address
     */
    function updateBeneficiary(uint256 index, address newRecipient) external onlyAdmin {
        if (index >= 3) revert InvalidConfiguration();
        if (newRecipient == address(0)) revert InvalidBeneficiary();
        
        beneficiaries[index].recipient = newRecipient;
        emit BeneficiaryUpdated(index, newRecipient, beneficiaries[index].share);
    }
    
    /**
     * @notice Distribute accumulated fees to beneficiaries
     */
    function distributeFees() external nonReentrant {
        uint256 balance = IERC20(feeToken).balanceOf(address(this));
        if (balance == 0) return;
        
        // Calculate distribution amounts
        uint256 amount1 = (balance * beneficiaries[0].share) / SHARE_DENOMINATOR;
        uint256 amount2 = (balance * beneficiaries[1].share) / SHARE_DENOMINATOR;
        uint256 amount3 = balance - amount1 - amount2; // Remainder goes to third beneficiary
        
        // Distribute to beneficiaries
        if (amount1 > 0) {
            IERC20(feeToken).safeTransfer(beneficiaries[0].recipient, amount1);
            beneficiaries[0].totalReceived += amount1;
            emit FeeDistributed(beneficiaries[0].recipient, amount1, beneficiaries[0].share);
        }
        
        if (amount2 > 0) {
            IERC20(feeToken).safeTransfer(beneficiaries[1].recipient, amount2);
            beneficiaries[1].totalReceived += amount2;
            emit FeeDistributed(beneficiaries[1].recipient, amount2, beneficiaries[1].share);
        }
        
        if (amount3 > 0) {
            IERC20(feeToken).safeTransfer(beneficiaries[2].recipient, amount3);
            beneficiaries[2].totalReceived += amount3;
            emit FeeDistributed(beneficiaries[2].recipient, amount3, beneficiaries[2].share);
        }
        
        totalFeesDistributed += balance;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get suite details
     * @param suiteId Suite identifier
     * @return suite Complete suite information
     */
    function getSuite(uint256 suiteId) external view returns (Suite memory) {
        if (suiteId == 0 || suiteId > suiteCount) revert SuiteNotFound();
        return suites[suiteId];
    }
    
    /**
     * @notice Get component details
     * @param componentId Component identifier
     * @return component Complete component information
     */
    function getComponent(uint256 componentId) external view returns (ComponentDeployment memory) {
        if (componentId == 0 || componentId > componentCount) revert ComponentNotFound();
        return components[componentId];
    }
    
    /**
     * @notice Get all suites deployed by an address
     * @param deployer Deployer address
     * @return suiteIds Array of suite IDs
     */
    function getDeployerSuites(address deployer) external view returns (uint256[] memory) {
        return deployerSuites[deployer];
    }
    
    /**
     * @notice Get all components deployed by an address
     * @param deployer Deployer address
     * @return componentIds Array of component IDs
     */
    function getDeployerComponents(address deployer) external view returns (uint256[] memory) {
        return deployerComponents[deployer];
    }
    
    /**
     * @notice Get all beneficiary information
     * @return recipients Array of beneficiary addresses
     * @return shares Array of beneficiary shares
     * @return totalReceived Array of total amounts received
     */
    function getBeneficiaries() external view returns (
        address[3] memory recipients,
        uint256[3] memory shares,
        uint256[3] memory totalReceived
    ) {
        for (uint256 i = 0; i < 3; i++) {
            recipients[i] = beneficiaries[i].recipient;
            shares[i] = beneficiaries[i].share;
            totalReceived[i] = beneficiaries[i].totalReceived;
        }
    }
    
    /**
     * @notice Get fee distribution statistics
     * @return totalCollected Total fees collected
     * @return totalDistributed Total fees distributed
     * @return pendingDistribution Fees pending distribution
     */
    function getFeeStats() external view returns (
        uint256 totalCollected,
        uint256 totalDistributed,
        uint256 pendingDistribution
    ) {
        totalCollected = totalFeesCollected;
        totalDistributed = totalFeesDistributed;
        pendingDistribution = IERC20(feeToken).balanceOf(address(this));
    }
    
    /**
     * @notice Calculate deployment address for CREATE2
     * @param implementation Implementation contract address
     * @param initData Initialization data
     * @param salt Salt value
     * @return predicted Predicted deployment address
     */
    function getDeploymentAddress(
        address implementation,
        bytes calldata initData,
        bytes32 salt
    ) external view returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(bytecode, initData))
            )
        );
        
        predicted = address(uint160(uint256(hash)));
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Pause or unpause factory
     * @param _paused Whether to pause (true) or unpause (false)
     */
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit FactoryPausedStateChanged(_paused);
    }
    
    /**
     * @notice Add or remove authorized deployer
     * @param deployer Address to update
     * @param authorized Whether to authorize (true) or revoke (false)
     */
    function setAuthorizedDeployer(address deployer, bool authorized) external onlyAdmin {
        if (deployer == address(0)) revert ZeroAddress();
        authorizedDeployers[deployer] = authorized;
        emit AuthorizedDeployerUpdated(deployer, authorized);
    }
    
    /**
     * @notice Transfer admin role
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        authorizedDeployers[newAdmin] = true;
    }
    
    /**
     * @notice Emergency withdrawal of tokens
     * @param token Token address (0x0 for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit EmergencyWithdrawal(token, to, amount);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Deploy contract using CREATE2 with initialization
     */
    function _deployWithCreate2(
        address implementation,
        bytes memory initData,
        bytes32 salt
    ) internal returns (address deployed) {
        // Create minimal proxy bytecode
        bytes memory bytecode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        
        // Deploy the contract
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        if (deployed == address(0)) revert DeploymentFailed();
        
        // Initialize the contract if initData is provided
        if (initData.length > 0) {
            (bool success,) = deployed.call(initData);
            if (!success) revert DeploymentFailed();
        }
        
        return deployed;
    }
    
    /**
     * @dev Register a component deployment
     */
    function _registerComponent(
        address contractAddress,
        ComponentType componentType,
        string calldata projectName,
        uint256 linkedSuiteId
    ) internal returns (uint256 componentId) {
        componentId = ++componentCount;
        components[componentId] = ComponentDeployment({
            contractAddress: contractAddress,
            componentType: componentType,
            deployer: msg.sender,
            projectName: projectName,
            deployedAt: block.timestamp,
            feePaid: componentFee,
            active: true,
            linkedSuiteId: linkedSuiteId
        });
        
        deployerComponents[msg.sender].push(componentId);
        contractToComponentId[contractAddress] = componentId;
        
        emit ComponentDeployed(
            componentId,
            msg.sender,
            contractAddress,
            componentType,
            projectName
        );
        
        emit FeeCollected(componentId, msg.sender, componentFee, block.timestamp);
    }
    
    /**
     * @dev Collect deployment fee from deployer
     */
    function _collectFee(address payer, uint256 feeAmount) internal {
        uint256 balanceBefore = IERC20(feeToken).balanceOf(address(this));
        
        IERC20(feeToken).safeTransferFrom(payer, address(this), feeAmount);
        
        uint256 balanceAfter = IERC20(feeToken).balanceOf(address(this));
        if (balanceAfter - balanceBefore < feeAmount) {
            revert InsufficientFeePayment();
        }
        
        totalFeesCollected += feeAmount;
    }
    
    // ============ Receive Function ============
    
    /**
     * @notice Receive ETH (for emergency withdrawals)
     */
    receive() external payable {}
}
