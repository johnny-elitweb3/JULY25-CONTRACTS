// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import all governance contracts
import "./StandardizedGovernanceNFT.sol";
import "./RewardCalculator.sol";
import "./GovernanceNFTStaking.sol";
import "./DAppRegistry.sol";
import "./ProposalManager.sol";

/**
 * @title GovernanceModuleFactory
 * @author Circularity Finance
 * @notice Factory contract for deploying complete governance infrastructure
 * @dev Ultra-modular architecture to completely avoid stack depth issues
 * @custom:version 1.0.0
 */
contract GovernanceModuleFactory is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Constants ==========
    string public constant VERSION = "1.0.0";
    uint256 public constant FULL_DEPLOYMENT_FEE = 10000 * 10**18;
    uint256 public constant MODULE_FEE = 5000 * 10**18;
    
    // Revenue shares (basis points)
    uint256 public constant BP_BENEFICIARY_1 = 3000; // 30%
    uint256 public constant BP_BENEFICIARY_2 = 3000; // 30%
    uint256 public constant BP_BENEFICIARY_3 = 4000; // 40%
    uint256 public constant BP_TOTAL = 10000; // 100%

    // Module IDs
    uint8 public constant MODULE_NFT = 1;
    uint8 public constant MODULE_CALCULATOR = 2;
    uint8 public constant MODULE_STAKING = 3;
    uint8 public constant MODULE_REGISTRY = 4;
    uint8 public constant MODULE_PROPOSALS = 5;

    // ========== Storage Structs ==========
    
    // Permanent storage structures
    struct DeploymentRecord {
        address deployer;
        address nftContract;
        address calculatorContract;
        address stakingContract;
        address registryContract;
        address proposalsContract;
        uint256 deploymentTime;
        uint256 feesPaid;
        bool isFullDeployment;
    }
    
    struct BeneficiaryInfo {
        address payable addr;
        uint256 pendingRevenue;
    }
    
    // Temporary storage for active deployment
    struct ActiveDeployment {
        address deployer;
        uint256 feeAmount;
        bool isFullDeployment;
        // Contract addresses
        address nftContract;
        address calculatorContract;
        address stakingContract;
        address registryContract;
        address proposalsContract;
        // Module flags
        bool deployNFT;
        bool deployCalculator;
        bool deployStaking;
        bool deployRegistry;
        bool deployProposals;
        // Version strings
        string nftVersion;
        string stakingVersion;
    }
    
    // NFT parameters stored separately to avoid stack issues
    struct NFTDeploymentParams {
        // Basic info
        string name;
        string symbol;
        string baseURI;
        uint256 maxSupply;
        uint256 mintPrice;
        // Beneficiaries stored as array
        address payable[6] beneficiaries;
        // 0: developers, 1: consulting, 2: payroll, 3: treasury, 4: marketing, 5: operations
    }

    // ========== State Variables ==========
    IERC20 public immutable feeToken;
    
    // Beneficiary management
    BeneficiaryInfo public beneficiary1;
    BeneficiaryInfo public beneficiary2;
    BeneficiaryInfo public beneficiary3;
    
    // Revenue tracking
    uint256 public totalRevenue;
    uint256 public totalDistributed;
    
    // Authorization
    mapping(address => bool) public authorizedDeployers;
    
    // Deployment history
    mapping(address => DeploymentRecord[]) public deploymentHistory;
    mapping(address => uint256) public deploymentCounts;
    uint256 public globalDeploymentCount;
    
    // Active deployment state (temporary storage)
    ActiveDeployment private activeDeployment;
    NFTDeploymentParams private nftParams;
    
    // Deployment mutex to prevent reentrancy at deployment level
    bool private deploying;

    // ========== Events ==========
    event DeployerAuthorized(address indexed deployer, bool authorized);
    event ModuleDeployed(
        address indexed deployer,
        uint8 indexed moduleId,
        address moduleAddress
    );
    event DeploymentCompleted(
        address indexed deployer,
        uint256 indexed deploymentId,
        uint256 modulesDeployed,
        uint256 feesPaid
    );
    event RevenueDistributed(
        address indexed beneficiary,
        uint256 amount
    );
    event RevenueWithdrawn(
        address indexed beneficiary,
        uint256 amount
    );
    event ContractConfigured(
        address indexed contractAddress,
        string contractType
    );
    event RoleTransferred(
        address indexed contractAddress,
        bytes32 role,
        address indexed recipient
    );

    // ========== Errors ==========
    error NotAuthorized();
    error InvalidAddress();
    error InvalidConfiguration();
    error NoModulesSelected();
    error DeploymentInProgress();
    error NoDeploymentInProgress();
    error ModuleDependencyMissing();
    error InsufficientFee();
    error NoPendingRevenue();
    error TransferFailed();

    // ========== Constructor ==========
    constructor(
        address _feeToken,
        address payable _beneficiary1,
        address payable _beneficiary2,
        address payable _beneficiary3
    ) Ownable(msg.sender) {
        if (_feeToken == address(0) || 
            _beneficiary1 == address(0) || 
            _beneficiary2 == address(0) || 
            _beneficiary3 == address(0)) {
            revert InvalidAddress();
        }
        
        feeToken = IERC20(_feeToken);
        
        beneficiary1.addr = _beneficiary1;
        beneficiary2.addr = _beneficiary2;
        beneficiary3.addr = _beneficiary3;
        
        authorizedDeployers[msg.sender] = true;
    }

    // ========== Modifiers ==========
    
    modifier onlyAuthorized() {
        if (!authorizedDeployers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }
    
    modifier noActiveDeployment() {
        if (deploying) revert DeploymentInProgress();
        deploying = true;
        _;
        deploying = false;
    }
    
    modifier requiresActiveDeployment() {
        if (!deploying) revert NoDeploymentInProgress();
        _;
    }

    // ========== Main Entry Points ==========

    /**
     * @notice Deploy all governance modules
     * @param nftName NFT collection name
     * @param nftSymbol NFT collection symbol
     * @param nftBaseURI NFT metadata base URI
     * @param nftMaxSupply Maximum NFT supply
     * @param nftMintPrice NFT mint price
     * @param nftBeneficiaries Array of 6 beneficiary addresses
     * @param stakingVersion Expected staking contract version
     */
    function deployFullSuite(
        string calldata nftName,
        string calldata nftSymbol,
        string calldata nftBaseURI,
        uint256 nftMaxSupply,
        uint256 nftMintPrice,
        address payable[6] calldata nftBeneficiaries,
        string calldata stakingVersion
    ) external nonReentrant whenNotPaused onlyAuthorized noActiveDeployment {
        // Initialize deployment
        _initializeFullDeployment(stakingVersion);
        
        // Store NFT parameters
        _storeNFTParams(
            nftName,
            nftSymbol,
            nftBaseURI,
            nftMaxSupply,
            nftMintPrice,
            nftBeneficiaries
        );
        
        // Execute deployment
        _executeFullDeployment();
    }

    /**
     * @notice Deploy selected modules only
     * @param deployFlags Array of 5 booleans for module selection
     * @param nftName NFT collection name (if deploying NFT)
     * @param nftSymbol NFT collection symbol (if deploying NFT)
     * @param nftBaseURI NFT metadata base URI (if deploying NFT)
     * @param nftMaxSupply Maximum NFT supply (if deploying NFT)
     * @param nftMintPrice NFT mint price (if deploying NFT)
     * @param nftBeneficiaries Array of 6 beneficiary addresses (if deploying NFT)
     * @param stakingVersion Expected staking contract version
     */
    function deploySelected(
        bool[5] calldata deployFlags,
        string calldata nftName,
        string calldata nftSymbol,
        string calldata nftBaseURI,
        uint256 nftMaxSupply,
        uint256 nftMintPrice,
        address payable[6] calldata nftBeneficiaries,
        string calldata stakingVersion
    ) external nonReentrant whenNotPaused onlyAuthorized noActiveDeployment {
        // Validate at least one module selected
        if (!_anyModuleSelected(deployFlags)) revert NoModulesSelected();
        
        // Initialize deployment
        _initializeSelectiveDeployment(deployFlags, stakingVersion);
        
        // Store NFT parameters if needed
        if (deployFlags[0]) {
            _storeNFTParams(
                nftName,
                nftSymbol,
                nftBaseURI,
                nftMaxSupply,
                nftMintPrice,
                nftBeneficiaries
            );
        }
        
        // Execute deployment
        _executeSelectiveDeployment();
    }

    // ========== Initialization Functions ==========

    function _initializeFullDeployment(string calldata stakingVersion) private {
        activeDeployment.deployer = msg.sender;
        activeDeployment.feeAmount = FULL_DEPLOYMENT_FEE;
        activeDeployment.isFullDeployment = true;
        activeDeployment.deployNFT = true;
        activeDeployment.deployCalculator = true;
        activeDeployment.deployStaking = true;
        activeDeployment.deployRegistry = true;
        activeDeployment.deployProposals = true;
        activeDeployment.stakingVersion = stakingVersion;
        activeDeployment.nftVersion = "2.0.0"; // Default NFT version
    }

    function _initializeSelectiveDeployment(
        bool[5] calldata deployFlags,
        string calldata stakingVersion
    ) private {
        activeDeployment.deployer = msg.sender;
        activeDeployment.isFullDeployment = false;
        activeDeployment.deployNFT = deployFlags[0];
        activeDeployment.deployCalculator = deployFlags[1];
        activeDeployment.deployStaking = deployFlags[2];
        activeDeployment.deployRegistry = deployFlags[3];
        activeDeployment.deployProposals = deployFlags[4];
        activeDeployment.stakingVersion = stakingVersion;
        activeDeployment.nftVersion = "2.0.0"; // Default NFT version
        
        // Calculate fee
        uint256 fee = 0;
        for (uint i = 0; i < 5; i++) {
            if (deployFlags[i]) fee += MODULE_FEE;
        }
        activeDeployment.feeAmount = fee;
    }

    function _storeNFTParams(
        string calldata name,
        string calldata symbol,
        string calldata baseURI,
        uint256 maxSupply,
        uint256 mintPrice,
        address payable[6] calldata beneficiaries
    ) private {
        nftParams.name = name;
        nftParams.symbol = symbol;
        nftParams.baseURI = baseURI;
        nftParams.maxSupply = maxSupply;
        nftParams.mintPrice = mintPrice;
        
        // Copy beneficiaries array
        for (uint i = 0; i < 6; i++) {
            nftParams.beneficiaries[i] = beneficiaries[i];
        }
    }

    // ========== Execution Functions ==========

    function _executeFullDeployment() private {
        // Validate configuration
        _validateFullDeployment();
        
        // Collect fees
        _collectFees();
        
        // Deploy all modules
        _deployNFT();
        _deployCalculator();
        _deployStaking();
        _deployRegistry();
        _deployProposals();
        
        // Configure all contracts
        _configureContracts();
        
        // Finalize deployment
        _finalizeDeployment();
    }

    function _executeSelectiveDeployment() private {
        // Validate configuration
        _validateSelectiveDeployment();
        
        // Collect fees
        _collectFees();
        
        // Deploy selected modules
        if (activeDeployment.deployNFT) _deployNFT();
        if (activeDeployment.deployCalculator) _deployCalculator();
        if (activeDeployment.deployStaking) _deployStaking();
        if (activeDeployment.deployRegistry) _deployRegistry();
        if (activeDeployment.deployProposals) _deployProposals();
        
        // Configure deployed contracts
        _configureContracts();
        
        // Finalize deployment
        _finalizeDeployment();
    }

    // ========== Validation Functions ==========

    function _validateFullDeployment() private view {
        // Validate NFT parameters
        _validateNFTName();
        _validateNFTSymbol();
        _validateNFTSupply();
        _validateNFTBeneficiaries();
        _validateVersions();
    }

    function _validateSelectiveDeployment() private view {
        // Validate NFT if selected
        if (activeDeployment.deployNFT) {
            _validateNFTName();
            _validateNFTSymbol();
            _validateNFTSupply();
            _validateNFTBeneficiaries();
        }
        
        // Validate dependencies
        _validateDependencies();
        _validateVersions();
    }

    function _validateNFTName() private view {
        if (bytes(nftParams.name).length == 0) revert InvalidConfiguration();
    }

    function _validateNFTSymbol() private view {
        if (bytes(nftParams.symbol).length == 0) revert InvalidConfiguration();
    }

    function _validateNFTSupply() private view {
        if (nftParams.maxSupply == 0) revert InvalidConfiguration();
    }

    function _validateNFTBeneficiaries() private view {
        for (uint i = 0; i < 6; i++) {
            if (nftParams.beneficiaries[i] == address(0)) revert InvalidAddress();
        }
    }

    function _validateDependencies() private view {
        // Staking requires NFT
        if (activeDeployment.deployStaking && !activeDeployment.deployNFT) {
            if (activeDeployment.nftContract == address(0)) {
                revert ModuleDependencyMissing();
            }
        }
        
        // Proposals requires Staking and Registry
        if (activeDeployment.deployProposals) {
            bool hasStaking = activeDeployment.deployStaking || 
                            activeDeployment.stakingContract != address(0);
            bool hasRegistry = activeDeployment.deployRegistry || 
                             activeDeployment.registryContract != address(0);
            
            if (!hasStaking || !hasRegistry) {
                revert ModuleDependencyMissing();
            }
        }
    }

    function _validateVersions() private view {
        if (bytes(activeDeployment.stakingVersion).length == 0) {
            revert InvalidConfiguration();
        }
    }

    // ========== Fee Management ==========

    function _collectFees() private {
        feeToken.safeTransferFrom(
            activeDeployment.deployer,
            address(this),
            activeDeployment.feeAmount
        );
        totalRevenue += activeDeployment.feeAmount;
    }

    // ========== Deployment Functions ==========

    function _deployNFT() private requiresActiveDeployment {
        activeDeployment.nftContract = address(
            new StandardizedGovernanceNFT(
                nftParams.name,
                nftParams.symbol,
                nftParams.baseURI,
                nftParams.maxSupply,
                nftParams.mintPrice,
                nftParams.beneficiaries[0], // developers
                nftParams.beneficiaries[1], // consulting
                nftParams.beneficiaries[2], // payroll
                nftParams.beneficiaries[3], // treasury
                nftParams.beneficiaries[4], // marketing
                nftParams.beneficiaries[5]  // operations
            )
        );
        
        emit ModuleDeployed(activeDeployment.deployer, MODULE_NFT, activeDeployment.nftContract);
    }

    function _deployCalculator() private requiresActiveDeployment {
        activeDeployment.calculatorContract = address(new RewardCalculator());
        emit ModuleDeployed(activeDeployment.deployer, MODULE_CALCULATOR, activeDeployment.calculatorContract);
    }

    function _deployStaking() private requiresActiveDeployment {
        activeDeployment.stakingContract = address(
            new GovernanceNFTStaking(activeDeployment.nftContract)
        );
        emit ModuleDeployed(activeDeployment.deployer, MODULE_STAKING, activeDeployment.stakingContract);
    }

    function _deployRegistry() private requiresActiveDeployment {
        activeDeployment.registryContract = address(
            new DAppRegistry(address(this))
        );
        emit ModuleDeployed(activeDeployment.deployer, MODULE_REGISTRY, activeDeployment.registryContract);
    }

    function _deployProposals() private requiresActiveDeployment {
        activeDeployment.proposalsContract = address(
            new ProposalManager(
                activeDeployment.stakingContract,
                activeDeployment.registryContract,
                activeDeployment.stakingVersion
            )
        );
        emit ModuleDeployed(activeDeployment.deployer, MODULE_PROPOSALS, activeDeployment.proposalsContract);
    }

    // ========== Configuration Master Function ==========

    function _configureContracts() private requiresActiveDeployment {
        if (activeDeployment.nftContract != address(0)) {
            _configureNFTStep1();
            _configureNFTStep2();
        }
        
        if (activeDeployment.calculatorContract != address(0)) {
            _configureCalculator();
        }
        
        if (activeDeployment.stakingContract != address(0)) {
            _configureStakingStep1();
            _configureStakingStep2();
        }
        
        if (activeDeployment.registryContract != address(0)) {
            _configureRegistryStep1();
            _configureRegistryStep2();
        }
        
        if (activeDeployment.proposalsContract != address(0)) {
            _configureProposalsStep1();
            _configureProposalsStep2();
        }
    }

    // ========== NFT Configuration ==========

    function _configureNFTStep1() private {
        StandardizedGovernanceNFT nft = StandardizedGovernanceNFT(
            payable(activeDeployment.nftContract)
        );
        
        // Set governance contract
        if (activeDeployment.proposalsContract != address(0)) {
            nft.setGovernanceContract(activeDeployment.proposalsContract);
        }
        
        // Set staking contract
        if (activeDeployment.stakingContract != address(0)) {
            nft.setStakingContract(activeDeployment.stakingContract);
        }
        
        emit ContractConfigured(activeDeployment.nftContract, "NFT");
    }

    function _configureNFTStep2() private {
        StandardizedGovernanceNFT nft = StandardizedGovernanceNFT(
            payable(activeDeployment.nftContract)
        );
        
        address deployer = activeDeployment.deployer;
        
        // Transfer ADMIN_ROLE
        bytes32 adminRole = nft.ADMIN_ROLE();
        nft.grantRole(adminRole, deployer);
        nft.renounceRole(adminRole, address(this));
        emit RoleTransferred(activeDeployment.nftContract, adminRole, deployer);
        
        // Transfer MINTER_ROLE
        bytes32 minterRole = nft.MINTER_ROLE();
        nft.grantRole(minterRole, deployer);
        nft.renounceRole(minterRole, address(this));
        emit RoleTransferred(activeDeployment.nftContract, minterRole, deployer);
        
        // Transfer DEFAULT_ADMIN_ROLE
        bytes32 defaultAdminRole = nft.DEFAULT_ADMIN_ROLE();
        nft.grantRole(defaultAdminRole, deployer);
        nft.renounceRole(defaultAdminRole, address(this));
        emit RoleTransferred(activeDeployment.nftContract, defaultAdminRole, deployer);
    }

    // ========== Calculator Configuration ==========

    function _configureCalculator() private {
        RewardCalculator calc = RewardCalculator(activeDeployment.calculatorContract);
        
        // Set staking contract
        if (activeDeployment.stakingContract != address(0)) {
            calc.setStakingContract(activeDeployment.stakingContract);
        }
        
        // Transfer ownership
        calc.transferOwnership(activeDeployment.deployer);
        
        emit ContractConfigured(activeDeployment.calculatorContract, "Calculator");
    }

    // ========== Staking Configuration ==========

    function _configureStakingStep1() private {
        GovernanceNFTStaking staking = GovernanceNFTStaking(
            payable(activeDeployment.stakingContract)
        );
        
        // Set calculator
        if (activeDeployment.calculatorContract != address(0)) {
            staking.setRewardCalculator(activeDeployment.calculatorContract, "1.0");
        }
        
        // Set governance
        if (activeDeployment.proposalsContract != address(0)) {
            staking.setGovernanceContract(
                activeDeployment.proposalsContract,
                activeDeployment.stakingVersion
            );
        }
        
        emit ContractConfigured(activeDeployment.stakingContract, "Staking");
    }

    function _configureStakingStep2() private {
        GovernanceNFTStaking staking = GovernanceNFTStaking(
            payable(activeDeployment.stakingContract)
        );
        
        address deployer = activeDeployment.deployer;
        
        // Transfer each role separately
        _transferStakingAdminRole(staking, deployer);
        _transferStakingPoolManagerRole(staking, deployer);
        _transferStakingEmergencyRole(staking, deployer);
        _transferStakingDefaultAdminRole(staking, deployer);
    }

    function _transferStakingAdminRole(GovernanceNFTStaking staking, address deployer) private {
        bytes32 role = staking.ADMIN_ROLE();
        staking.grantRole(role, deployer);
        staking.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.stakingContract, role, deployer);
    }

    function _transferStakingPoolManagerRole(GovernanceNFTStaking staking, address deployer) private {
        bytes32 role = staking.POOL_MANAGER_ROLE();
        staking.grantRole(role, deployer);
        staking.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.stakingContract, role, deployer);
    }

    function _transferStakingEmergencyRole(GovernanceNFTStaking staking, address deployer) private {
        bytes32 role = staking.EMERGENCY_ROLE();
        staking.grantRole(role, deployer);
        staking.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.stakingContract, role, deployer);
    }

    function _transferStakingDefaultAdminRole(GovernanceNFTStaking staking, address deployer) private {
        bytes32 role = staking.DEFAULT_ADMIN_ROLE();
        staking.grantRole(role, deployer);
        staking.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.stakingContract, role, deployer);
    }

    // ========== Registry Configuration ==========

    function _configureRegistryStep1() private {
        DAppRegistry registry = DAppRegistry(activeDeployment.registryContract);
        
        // Grant governance role to proposals
        if (activeDeployment.proposalsContract != address(0)) {
            registry.grantRole(
                registry.GOVERNANCE_ROLE(),
                activeDeployment.proposalsContract
            );
        }
        
        emit ContractConfigured(activeDeployment.registryContract, "Registry");
    }

    function _configureRegistryStep2() private {
        DAppRegistry registry = DAppRegistry(activeDeployment.registryContract);
        address deployer = activeDeployment.deployer;
        
        // Transfer each role
        _transferRegistryAdminRole(registry, deployer);
        _transferRegistryRegistrarRole(registry, deployer);
        _transferRegistryConfigRole(registry, deployer);
        _transferRegistryDefaultAdminRole(registry, deployer);
        
        // Renounce governance role from factory
        registry.renounceRole(registry.GOVERNANCE_ROLE(), address(this));
    }

    function _transferRegistryAdminRole(DAppRegistry registry, address deployer) private {
        bytes32 role = registry.ADMIN_ROLE();
        registry.grantRole(role, deployer);
        registry.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.registryContract, role, deployer);
    }

    function _transferRegistryRegistrarRole(DAppRegistry registry, address deployer) private {
        bytes32 role = registry.REGISTRAR_ROLE();
        registry.grantRole(role, deployer);
        registry.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.registryContract, role, deployer);
    }

    function _transferRegistryConfigRole(DAppRegistry registry, address deployer) private {
        bytes32 role = registry.CONFIG_ROLE();
        registry.grantRole(role, deployer);
        registry.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.registryContract, role, deployer);
    }

    function _transferRegistryDefaultAdminRole(DAppRegistry registry, address deployer) private {
        bytes32 role = registry.DEFAULT_ADMIN_ROLE();
        registry.grantRole(role, deployer);
        registry.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.registryContract, role, deployer);
    }

    // ========== Proposals Configuration ==========

    function _configureProposalsStep1() private {
        emit ContractConfigured(activeDeployment.proposalsContract, "Proposals");
    }

    function _configureProposalsStep2() private {
        ProposalManager proposals = ProposalManager(activeDeployment.proposalsContract);
        address deployer = activeDeployment.deployer;
        
        // Transfer each role
        _transferProposalsAdminRole(proposals, deployer);
        _transferProposalsExecutorRole(proposals, deployer);
        _transferProposalsEmergencyRole(proposals, deployer);
        _transferProposalsDefaultAdminRole(proposals, deployer);
    }

    function _transferProposalsAdminRole(ProposalManager proposals, address deployer) private {
        bytes32 role = proposals.ADMIN_ROLE();
        proposals.grantRole(role, deployer);
        proposals.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.proposalsContract, role, deployer);
    }

    function _transferProposalsExecutorRole(ProposalManager proposals, address deployer) private {
        bytes32 role = proposals.EXECUTOR_ROLE();
        proposals.grantRole(role, deployer);
        proposals.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.proposalsContract, role, deployer);
    }

    function _transferProposalsEmergencyRole(ProposalManager proposals, address deployer) private {
        bytes32 role = proposals.EMERGENCY_ROLE();
        proposals.grantRole(role, deployer);
        proposals.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.proposalsContract, role, deployer);
    }

    function _transferProposalsDefaultAdminRole(ProposalManager proposals, address deployer) private {
        bytes32 role = proposals.DEFAULT_ADMIN_ROLE();
        proposals.grantRole(role, deployer);
        proposals.renounceRole(role, address(this));
        emit RoleTransferred(activeDeployment.proposalsContract, role, deployer);
    }

    // ========== Finalization ==========

    function _finalizeDeployment() private requiresActiveDeployment {
        // Create deployment record
        DeploymentRecord memory record = DeploymentRecord({
            deployer: activeDeployment.deployer,
            nftContract: activeDeployment.nftContract,
            calculatorContract: activeDeployment.calculatorContract,
            stakingContract: activeDeployment.stakingContract,
            registryContract: activeDeployment.registryContract,
            proposalsContract: activeDeployment.proposalsContract,
            deploymentTime: block.timestamp,
            feesPaid: activeDeployment.feeAmount,
            isFullDeployment: activeDeployment.isFullDeployment
        });
        
        // Store deployment record
        deploymentHistory[activeDeployment.deployer].push(record);
        uint256 deploymentId = deploymentCounts[activeDeployment.deployer];
        deploymentCounts[activeDeployment.deployer]++;
        globalDeploymentCount++;
        
        // Distribute revenue
        _distributeRevenue();
        
        // Count deployed modules
        uint256 moduleCount = _countDeployedModules();
        
        // Emit completion event
        emit DeploymentCompleted(
            activeDeployment.deployer,
            deploymentId,
            moduleCount,
            activeDeployment.feeAmount
        );
        
        // Clear temporary storage
        _clearDeploymentState();
    }

    function _distributeRevenue() private {
        uint256 amount = activeDeployment.feeAmount;
        
        // Calculate shares
        uint256 share1 = (amount * BP_BENEFICIARY_1) / BP_TOTAL;
        uint256 share2 = (amount * BP_BENEFICIARY_2) / BP_TOTAL;
        uint256 share3 = (amount * BP_BENEFICIARY_3) / BP_TOTAL;
        
        // Handle rounding
        uint256 distributed = share1 + share2 + share3;
        if (amount > distributed) {
            share3 += amount - distributed;
        }
        
        // Update pending revenues
        beneficiary1.pendingRevenue += share1;
        beneficiary2.pendingRevenue += share2;
        beneficiary3.pendingRevenue += share3;
        
        totalDistributed += amount;
        
        // Emit events
        emit RevenueDistributed(beneficiary1.addr, share1);
        emit RevenueDistributed(beneficiary2.addr, share2);
        emit RevenueDistributed(beneficiary3.addr, share3);
    }

    function _countDeployedModules() private view returns (uint256) {
        uint256 count = 0;
        if (activeDeployment.nftContract != address(0)) count++;
        if (activeDeployment.calculatorContract != address(0)) count++;
        if (activeDeployment.stakingContract != address(0)) count++;
        if (activeDeployment.registryContract != address(0)) count++;
        if (activeDeployment.proposalsContract != address(0)) count++;
        return count;
    }

    function _clearDeploymentState() private {
        delete activeDeployment;
        delete nftParams;
    }

    // ========== Admin Functions ==========

    function setAuthorization(address deployer, bool authorized) external onlyOwner {
        if (deployer == address(0)) revert InvalidAddress();
        authorizedDeployers[deployer] = authorized;
        emit DeployerAuthorized(deployer, authorized);
    }

    function updateBeneficiaries(
        address payable newBeneficiary1,
        address payable newBeneficiary2,
        address payable newBeneficiary3
    ) external onlyOwner {
        if (newBeneficiary1 == address(0) || 
            newBeneficiary2 == address(0) || 
            newBeneficiary3 == address(0)) {
            revert InvalidAddress();
        }
        
        beneficiary1.addr = newBeneficiary1;
        beneficiary2.addr = newBeneficiary2;
        beneficiary3.addr = newBeneficiary3;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== Withdrawal Functions ==========

    function withdrawRevenue() external nonReentrant {
        uint256 amount;
        
        if (msg.sender == beneficiary1.addr) {
            amount = beneficiary1.pendingRevenue;
            beneficiary1.pendingRevenue = 0;
        } else if (msg.sender == beneficiary2.addr) {
            amount = beneficiary2.pendingRevenue;
            beneficiary2.pendingRevenue = 0;
        } else if (msg.sender == beneficiary3.addr) {
            amount = beneficiary3.pendingRevenue;
            beneficiary3.pendingRevenue = 0;
        } else {
            revert NotAuthorized();
        }
        
        if (amount == 0) revert NoPendingRevenue();
        
        feeToken.safeTransfer(msg.sender, amount);
        emit RevenueWithdrawn(msg.sender, amount);
    }

    function emergencyWithdraw(address token, address to) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        
        uint256 balance;
        if (token == address(feeToken)) {
            uint256 totalPending = beneficiary1.pendingRevenue + 
                                 beneficiary2.pendingRevenue + 
                                 beneficiary3.pendingRevenue;
            uint256 totalBalance = feeToken.balanceOf(address(this));
            if (totalBalance > totalPending) {
                balance = totalBalance - totalPending;
            }
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
        
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }

    // ========== View Functions ==========

    function getDeploymentHistory(address deployer) 
        external 
        view 
        returns (DeploymentRecord[] memory) 
    {
        return deploymentHistory[deployer];
    }

    function getDeployment(address deployer, uint256 index) 
        external 
        view 
        returns (DeploymentRecord memory) 
    {
        require(index < deploymentCounts[deployer], "Invalid index");
        return deploymentHistory[deployer][index];
    }

    function getPendingRevenue(address beneficiary) external view returns (uint256) {
        if (beneficiary == beneficiary1.addr) return beneficiary1.pendingRevenue;
        if (beneficiary == beneficiary2.addr) return beneficiary2.pendingRevenue;
        if (beneficiary == beneficiary3.addr) return beneficiary3.pendingRevenue;
        return 0;
    }

    function getBeneficiaries() 
        external 
        view 
        returns (
            address ben1,
            address ben2,
            address ben3,
            uint256 pending1,
            uint256 pending2,
            uint256 pending3
        ) 
    {
        return (
            beneficiary1.addr,
            beneficiary2.addr,
            beneficiary3.addr,
            beneficiary1.pendingRevenue,
            beneficiary2.pendingRevenue,
            beneficiary3.pendingRevenue
        );
    }

    function getRevenueStats() 
        external 
        view 
        returns (uint256 total, uint256 distributed) 
    {
        return (totalRevenue, totalDistributed);
    }

    function calculateDeploymentCost(bool[5] calldata deployFlags) 
        external 
        pure 
        returns (uint256) 
    {
        uint256 cost = 0;
        for (uint i = 0; i < 5; i++) {
            if (deployFlags[i]) cost += MODULE_FEE;
        }
        return cost;
    }

    function isAuthorized(address deployer) external view returns (bool) {
        return authorizedDeployers[deployer] || deployer == owner();
    }

    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ========== Helper Functions ==========

    function _anyModuleSelected(bool[5] calldata flags) private pure returns (bool) {
        for (uint i = 0; i < 5; i++) {
            if (flags[i]) return true;
        }
        return false;
    }
}
