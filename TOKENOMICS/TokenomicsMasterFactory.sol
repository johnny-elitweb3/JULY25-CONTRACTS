// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ITokenomicsMaster {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
    function TOKEN() external view returns (address);
}

interface IMicroEconomyIndex {
    function registerProject(
        address tokenomicsContract,
        string calldata name,
        string calldata symbol,
        string calldata description,
        string calldata logoUrl,
        string calldata websiteUrl,
        address paymentToken
    ) external;
}

/**
 * @title TokenomicsMasterFactory
 * @author CIFI Protocol
 * @notice Factory contract for deploying TokenomicsMaster instances with ERC20 payment
 * @dev Production-ready factory with comprehensive deployment management and MicroEconomy Index integration
 */
contract TokenomicsMasterFactory {
    // ============ State Variables ============
    
    // Core configuration
    address public owner;
    address public treasury;
    address public microEconomyIndex;
    
    // Deployment bytecode hash for verification
    bytes32 public immutable tokenomicsMasterBytecodeHash;
    
    // Payment configuration
    uint256 public constant BASE_FEE = 5000; // Base fee amount (5000 tokens)
    mapping(address => bool) public acceptedPaymentTokens;
    mapping(address => uint256) public tokenDecimals;
    mapping(address => uint256) public tokenPriceUSD; // Price per token in USD cents
    address[] public paymentTokenList;
    
    // Deployment tracking
    uint256 public totalDeployments;
    mapping(address => address[]) public deploymentsByUser;
    mapping(address => DeploymentInfo) public deploymentInfo;
    mapping(address => bool) public isValidDeployment;
    mapping(address => uint256) public deploymentIndex; // For efficient lookups
    address[] public allDeployments;
    
    // Revenue tracking
    mapping(address => uint256) public revenueByToken;
    uint256 public totalRevenueUSD; // Tracked in USD cents for precision
    
    // Discounts and promotions
    mapping(address => uint256) public userDiscounts; // Basis points (10000 = 100%)
    uint256 public globalDiscount; // Basis points
    bool public promotionActive;
    
    // Referral system
    mapping(address => address) public referrers;
    mapping(address => uint256) public referralRewards;
    mapping(address => uint256) public referralCount;
    uint256 public referralPercentage = 1000; // 10% in basis points
    
    // Template system for common deployments
    mapping(string => DeploymentTemplate) public templates;
    string[] public templateNames;
    
    // Whitelisting for special deployments
    mapping(address => bool) public whitelistedDeployers;
    
    // ============ Structs ============
    
    struct DeploymentInfo {
        address deployer;
        address tokenAddress;
        address paymentToken;
        uint256 feePaid;
        uint256 deploymentTime;
        string projectName;
        string projectSymbol;
        bytes32 deploymentId;
        DeploymentMetadata metadata;
    }
    
    struct DeploymentMetadata {
        string description;
        string logoUrl;
        string websiteUrl;
        string category; // DeFi, Gaming, NFT, etc.
        bool indexRegistered;
        uint256 initialSupply;
        uint256 deploymentBlock;
    }
    
    struct DeploymentParams {
        address tokenAddress;
        address paymentToken;
        string projectName;
        string projectSymbol;
        string description;
        string logoUrl;
        string websiteUrl;
        string category;
        address referrer;
        bool registerInIndex;
    }
    
    struct DeploymentTemplate {
        string name;
        string description;
        string category;
        bool isActive;
        uint256 discountPercent; // Additional discount for using template
    }
    
    struct PaymentConfig {
        address token;
        bool accepted;
        uint256 priceUSD; // Price per token in USD cents
        uint256 minAmount;
        uint256 maxAmount;
    }
    
    // ============ Events ============
    
    event TokenomicsMasterDeployed(
        address indexed deployer,
        address indexed deployment,
        address indexed tokenAddress,
        uint256 feePaid,
        address paymentToken,
        bytes32 deploymentId
    );
    
    event PaymentTokenUpdated(
        address indexed token,
        bool accepted,
        uint256 decimals,
        uint256 priceUSD
    );
    
    event FeeCollected(
        address indexed from,
        address indexed token,
        uint256 amount
    );
    
    event RevenueWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );
    
    event DiscountApplied(
        address indexed user,
        uint256 discountPercentage,
        uint256 finalFee
    );
    
    event ReferralPaid(
        address indexed referrer,
        address indexed referee,
        uint256 amount,
        address token
    );
    
    event MicroEconomyIndexSet(address indexed oldIndex, address indexed newIndex);
    event ProjectRegisteredInIndex(address indexed deployment, string projectName);
    event IndexRegistrationFailed(address indexed deployment);
    event TemplateAdded(string indexed templateName, string category);
    event TemplateUpdated(string indexed templateName);
    event WhitelistUpdated(address indexed account, bool whitelisted);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // ============ Errors ============
    
    error Unauthorized();
    error InvalidAddress();
    error InvalidParameters();
    error PaymentTokenNotAccepted();
    error InsufficientPayment();
    error DeploymentFailed();
    error TransferFailed();
    error InvalidDiscount();
    error AlreadyDeployed();
    error InvalidFeeAmount();
    error PaymentTokenAlreadyAdded();
    error ExceedsMaximumFee();
    error BelowMinimumFee();
    error TemplateNotFound();
    error TemplateAlreadyExists();
    error ArrayLengthMismatch();
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    
    modifier onlyWhitelisted() {
        if (!whitelistedDeployers[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize the factory
     * @param _treasury Address to receive fees
     * @param _tokenomicsMasterBytecode Bytecode of TokenomicsMaster for hash verification
     */
    constructor(
        address _treasury,
        bytes memory _tokenomicsMasterBytecode
    ) validAddress(_treasury) {
        owner = msg.sender;
        treasury = _treasury;
        tokenomicsMasterBytecodeHash = keccak256(_tokenomicsMasterBytecode);
        whitelistedDeployers[msg.sender] = true;
    }
    
    // ============ Main Deployment Functions ============
    
    /**
     * @notice Deploy a new TokenomicsMaster instance
     * @param params Deployment parameters struct
     * @return deployment The address of the deployed TokenomicsMaster
     */
    function deployTokenomicsMaster(
        DeploymentParams calldata params
    ) external validAddress(params.tokenAddress) returns (address deployment) {
        // Validate payment token
        if (!acceptedPaymentTokens[params.paymentToken]) {
            revert PaymentTokenNotAccepted();
        }
        
        // Calculate fee with discounts
        uint256 requiredFee = _calculateFee(msg.sender, params.paymentToken);
        
        // Process payment (skip for whitelisted deployers)
        if (!whitelistedDeployers[msg.sender]) {
            _processPayment(params.paymentToken, requiredFee);
            
            // Process referral if applicable
            if (params.referrer != address(0) && params.referrer != msg.sender) {
                _processReferral(params.referrer, msg.sender, params.paymentToken, requiredFee);
            }
        }
        
        // Deploy new TokenomicsMaster instance
        deployment = _deployContract(params.tokenAddress);
        
        // Generate unique deployment ID
        bytes32 deploymentId = _generateDeploymentId(msg.sender, params.tokenAddress, deployment);
        
        // Record deployment information
        _recordDeployment(
            deployment,
            msg.sender,
            params,
            requiredFee,
            deploymentId
        );
        
        // Transfer ownership to deployer
        ITokenomicsMaster(deployment).transferOwnership(msg.sender);
        
        // Auto-register in MicroEconomy Index if requested
        if (params.registerInIndex && microEconomyIndex != address(0)) {
            _registerInIndex(deployment, params);
        }
        
        // Emit deployment event
        emit TokenomicsMasterDeployed(
            msg.sender,
            deployment,
            params.tokenAddress,
            requiredFee,
            params.paymentToken,
            deploymentId
        );
        
        return deployment;
    }
    
    /**
     * @notice Deploy using a template
     * @param templateName Name of the template to use
     * @param params Deployment parameters (template values override some params)
     * @return deployment The deployed contract address
     */
    function deployWithTemplate(
        string calldata templateName,
        DeploymentParams calldata params
    ) external returns (address deployment) {
        DeploymentTemplate storage template = templates[templateName];
        if (!template.isActive) revert TemplateNotFound();
        
        // Apply template discount
        uint256 originalDiscount = userDiscounts[msg.sender];
        if (template.discountPercent > 0) {
            userDiscounts[msg.sender] = originalDiscount + template.discountPercent;
            if (userDiscounts[msg.sender] > 10000) {
                userDiscounts[msg.sender] = 10000; // Cap at 100%
            }
        }
        
        // Deploy with template values
        DeploymentParams memory templateParams = params;
        templateParams.category = template.category;
        
        deployment = this.deployTokenomicsMaster(templateParams);
        
        // Restore original discount
        userDiscounts[msg.sender] = originalDiscount;
        
        return deployment;
    }
    
    /**
     * @notice Batch deploy multiple TokenomicsMaster instances
     * @param deployments Array of deployment parameters
     * @return deployedContracts Array of deployed contract addresses
     */
    function batchDeploy(
        DeploymentParams[] calldata deployments
    ) external returns (address[] memory deployedContracts) {
        uint256 length = deployments.length;
        deployedContracts = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            deployedContracts[i] = this.deployTokenomicsMaster(deployments[i]);
        }
        
        return deployedContracts;
    }
    
    // ============ MicroEconomy Index Integration ============
    
    /**
     * @notice Set the MicroEconomy Index contract address
     * @param _index Address of the MicroEconomy Index contract
     */
    function setMicroEconomyIndex(address _index) external onlyOwner {
        address oldIndex = microEconomyIndex;
        microEconomyIndex = _index;
        emit MicroEconomyIndexSet(oldIndex, _index);
    }
    
    /**
     * @dev Register deployment in MicroEconomy Index
     */
    function _registerInIndex(address deployment, DeploymentParams memory params) internal {
        try IMicroEconomyIndex(microEconomyIndex).registerProject(
            deployment,
            params.projectName,
            params.projectSymbol,
            params.description,
            params.logoUrl,
            params.websiteUrl,
            params.paymentToken
        ) {
            deploymentInfo[deployment].metadata.indexRegistered = true;
            emit ProjectRegisteredInIndex(deployment, params.projectName);
        } catch {
            emit IndexRegistrationFailed(deployment);
        }
    }
    
    // ============ Template Management ============
    
    /**
     * @notice Add a deployment template
     * @param name Template name
     * @param description Template description
     * @param category Project category
     * @param discountPercent Additional discount for using this template
     */
    function addTemplate(
        string calldata name,
        string calldata description,
        string calldata category,
        uint256 discountPercent
    ) external onlyOwner {
        if (templates[name].isActive) revert TemplateAlreadyExists();
        
        templates[name] = DeploymentTemplate({
            name: name,
            description: description,
            category: category,
            isActive: true,
            discountPercent: discountPercent
        });
        
        templateNames.push(name);
        emit TemplateAdded(name, category);
    }
    
    /**
     * @notice Update a template
     * @param name Template name
     * @param description New description
     * @param category New category
     * @param discountPercent New discount
     * @param isActive Active status
     */
    function updateTemplate(
        string calldata name,
        string calldata description,
        string calldata category,
        uint256 discountPercent,
        bool isActive
    ) external onlyOwner {
        DeploymentTemplate storage template = templates[name];
        if (bytes(template.name).length == 0) revert TemplateNotFound();
        
        template.description = description;
        template.category = category;
        template.discountPercent = discountPercent;
        template.isActive = isActive;
        
        emit TemplateUpdated(name);
    }
    
    // ============ Payment Management ============
    
    /**
     * @notice Add a new accepted payment token
     * @param token Address of the ERC20 token to accept
     * @param priceUSD Price per token in USD cents
     */
    function addPaymentToken(address token, uint256 priceUSD) external onlyOwner validAddress(token) {
        _addPaymentToken(token, priceUSD);
    }
    
    /**
     * @notice Update payment token price
     * @param token Token address
     * @param priceUSD New price in USD cents
     */
    function updateTokenPrice(address token, uint256 priceUSD) external onlyOwner {
        if (!acceptedPaymentTokens[token]) revert PaymentTokenNotAccepted();
        tokenPriceUSD[token] = priceUSD;
        emit PaymentTokenUpdated(token, true, tokenDecimals[token], priceUSD);
    }
    
    /**
     * @notice Remove an accepted payment token
     * @param token Address of the token to remove
     */
    function removePaymentToken(address token) external onlyOwner {
        acceptedPaymentTokens[token] = false;
        tokenPriceUSD[token] = 0;
        emit PaymentTokenUpdated(token, false, 0, 0);
    }
    
    /**
     * @notice Batch update payment tokens
     * @param configs Array of payment configurations
     */
    function batchUpdatePaymentTokens(
        PaymentConfig[] calldata configs
    ) external onlyOwner {
        for (uint256 i = 0; i < configs.length; i++) {
            PaymentConfig memory config = configs[i];
            
            if (config.accepted) {
                _addPaymentToken(config.token, config.priceUSD);
            } else {
                acceptedPaymentTokens[config.token] = false;
                tokenPriceUSD[config.token] = 0;
                emit PaymentTokenUpdated(config.token, false, 0, 0);
            }
        }
    }
    
    // ============ Discount Management ============
    
    /**
     * @notice Set discount for specific user
     * @param user Address of the user
     * @param discount Discount in basis points (10000 = 100%)
     */
    function setUserDiscount(address user, uint256 discount) external onlyOwner {
        if (discount > 10000) revert InvalidDiscount();
        userDiscounts[user] = discount;
        emit DiscountApplied(user, discount, 0);
    }
    
    /**
     * @notice Set global discount for all users
     * @param discount Discount in basis points
     */
    function setGlobalDiscount(uint256 discount) external onlyOwner {
        if (discount > 10000) revert InvalidDiscount();
        globalDiscount = discount;
        promotionActive = discount > 0;
    }
    
    /**
     * @notice Batch set user discounts
     * @param users Array of user addresses
     * @param discounts Array of discounts
     */
    function batchSetUserDiscounts(
        address[] calldata users,
        uint256[] calldata discounts
    ) external onlyOwner {
        if (users.length != discounts.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < users.length; i++) {
            if (discounts[i] > 10000) revert InvalidDiscount();
            userDiscounts[users[i]] = discounts[i];
        }
    }
    
    // ============ Whitelist Management ============
    
    /**
     * @notice Update whitelist status for an address
     * @param account Address to update
     * @param whitelisted Whether to whitelist or remove from whitelist
     */
    function updateWhitelist(address account, bool whitelisted) external onlyOwner {
        whitelistedDeployers[account] = whitelisted;
        emit WhitelistUpdated(account, whitelisted);
    }
    
    /**
     * @notice Batch update whitelist
     * @param accounts Array of addresses
     * @param whitelisted Array of whitelist statuses
     */
    function batchUpdateWhitelist(
        address[] calldata accounts,
        bool[] calldata whitelisted
    ) external onlyOwner {
        if (accounts.length != whitelisted.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelistedDeployers[accounts[i]] = whitelisted[i];
            emit WhitelistUpdated(accounts[i], whitelisted[i]);
        }
    }
    
    // ============ Revenue Management ============
    
    /**
     * @notice Withdraw collected fees
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw (0 for full balance)
     */
    function withdrawRevenue(
        address token,
        uint256 amount
    ) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 toWithdraw = amount == 0 ? balance : amount;
        
        if (toWithdraw > balance) revert InsufficientPayment();
        
        bool success = IERC20(token).transfer(treasury, toWithdraw);
        if (!success) revert TransferFailed();
        
        emit RevenueWithdrawn(token, toWithdraw, treasury);
    }
    
    /**
     * @notice Withdraw all revenues across all tokens
     */
    function withdrawAllRevenues() external onlyOwner {
        for (uint256 i = 0; i < paymentTokenList.length; i++) {
            address token = paymentTokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                bool success = IERC20(token).transfer(treasury, balance);
                if (success) {
                    emit RevenueWithdrawn(token, balance, treasury);
                }
            }
        }
    }
    
    // ============ Query Functions ============
    
    /**
     * @notice Get all deployments by a user
     * @param user Address of the user
     * @return Array of deployment addresses
     */
    function getUserDeployments(address user) external view returns (address[] memory) {
        return deploymentsByUser[user];
    }
    
    /**
     * @notice Get detailed deployment information
     * @param deployment Address of the deployment
     * @return info Deployment information struct
     */
    function getDeploymentDetails(
        address deployment
    ) external view returns (DeploymentInfo memory info) {
        return deploymentInfo[deployment];
    }
    
    /**
     * @notice Get deployment metadata
     * @param deployment Address of the deployment
     * @return metadata Deployment metadata struct
     */
    function getDeploymentMetadata(
        address deployment
    ) external view returns (DeploymentMetadata memory metadata) {
        return deploymentInfo[deployment].metadata;
    }
    
    /**
     * @notice Calculate fee for a user with discounts applied
     * @param user Address of the user
     * @param paymentToken Token to be used for payment
     * @return Final fee amount
     */
    function calculateUserFee(
        address user,
        address paymentToken
    ) external view returns (uint256) {
        return _calculateFee(user, paymentToken);
    }
    
    /**
     * @notice Get all accepted payment tokens
     * @return tokens Array of accepted token addresses
     */
    function getAcceptedTokens() external view returns (address[] memory tokens) {
        return paymentTokenList;
    }
    
    /**
     * @notice Get all deployment templates
     * @return Array of template names
     */
    function getTemplates() external view returns (string[] memory) {
        return templateNames;
    }
    
    /**
     * @notice Get template details
     * @param name Template name
     * @return template Template struct
     */
    function getTemplate(string calldata name) external view returns (DeploymentTemplate memory template) {
        return templates[name];
    }
    
    /**
     * @notice Check if an address is a valid deployment from this factory
     * @param deployment Address to check
     * @return bool True if valid deployment
     */
    function isFactoryDeployment(address deployment) external view returns (bool) {
        return isValidDeployment[deployment];
    }
    
    /**
     * @notice Get paginated list of all deployments
     * @param offset Starting index
     * @param limit Number of deployments to return
     * @return deployments Array of deployment addresses
     * @return total Total number of deployments
     */
    function getAllDeployments(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory deployments, uint256 total) {
        total = allDeployments.length;
        
        if (offset >= total) {
            return (new address[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        deployments = new address[](end - offset);
        for (uint256 i = 0; i < deployments.length; i++) {
            deployments[i] = allDeployments[offset + i];
        }
    }
    
    /**
     * @notice Get deployment statistics
     * @return totalDeployments_ Total number of deployments
     * @return totalRevenueUSD_ Total revenue in USD
     * @return activeTemplates Number of active templates
     * @return paymentTokens Number of payment tokens
     */
    function getDeploymentStats() external view returns (
        uint256 totalDeployments_,
        uint256 totalRevenueUSD_,
        uint256 activeTemplates,
        uint256 paymentTokens
    ) {
        totalDeployments_ = totalDeployments;
        totalRevenueUSD_ = totalRevenueUSD;
        
        // Count active templates
        for (uint256 i = 0; i < templateNames.length; i++) {
            if (templates[templateNames[i]].isActive) {
                activeTemplates++;
            }
        }
        
        paymentTokens = paymentTokenList.length;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Add a payment token to accepted list
     * @param token Address of the token
     * @param priceUSD Price in USD cents
     */
    function _addPaymentToken(address token, uint256 priceUSD) internal {
        if (token == address(0)) revert InvalidAddress();
        if (acceptedPaymentTokens[token]) revert PaymentTokenAlreadyAdded();
        
        uint8 decimals = IERC20(token).decimals();
        acceptedPaymentTokens[token] = true;
        tokenDecimals[token] = decimals;
        tokenPriceUSD[token] = priceUSD;
        paymentTokenList.push(token);
        
        emit PaymentTokenUpdated(token, true, decimals, priceUSD);
    }
    
    /**
     * @dev Calculate fee with discounts
     * @param user User address
     * @param paymentToken Payment token address
     * @return fee Final fee amount
     */
    function _calculateFee(
        address user,
        address paymentToken
    ) internal view returns (uint256 fee) {
        // Get base fee in USD
        uint256 baseFeeUSD = BASE_FEE * 100; // Convert to cents (5000 tokens = $50)
        
        // Convert to payment token amount
        uint256 tokenPrice = tokenPriceUSD[paymentToken];
        if (tokenPrice == 0) revert PaymentTokenNotAccepted();
        
        uint256 decimals = tokenDecimals[paymentToken];
        fee = (baseFeeUSD * (10 ** decimals)) / tokenPrice;
        
        // Apply user-specific discount first
        uint256 discount = userDiscounts[user];
        
        // Apply global discount if higher
        if (globalDiscount > discount) {
            discount = globalDiscount;
        }
        
        // Calculate final fee
        if (discount > 0) {
            uint256 discountAmount = (fee * discount) / 10000;
            fee = fee - discountAmount;
        }
        
        return fee;
    }
    
    /**
     * @dev Process payment from user
     * @param paymentToken Token address
     * @param amount Amount to collect
     */
    function _processPayment(address paymentToken, uint256 amount) internal {
        bool success = IERC20(paymentToken).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        
        if (!success) revert TransferFailed();
        
        revenueByToken[paymentToken] += amount;
        
        // Update USD revenue
        uint256 amountUSD = (amount * tokenPriceUSD[paymentToken]) / (10 ** tokenDecimals[paymentToken]);
        totalRevenueUSD += amountUSD;
        
        emit FeeCollected(msg.sender, paymentToken, amount);
    }
    
    /**
     * @dev Process referral rewards
     * @param referrer Address of referrer
     * @param referee Address of referee
     * @param paymentToken Payment token used
     * @param feeAmount Fee amount paid
     */
    function _processReferral(
        address referrer,
        address referee,
        address paymentToken,
        uint256 feeAmount
    ) internal {
        referrers[referee] = referrer;
        referralCount[referrer]++;
        
        uint256 reward = (feeAmount * referralPercentage) / 10000;
        referralRewards[referrer] += reward;
        
        // Transfer referral reward immediately
        bool success = IERC20(paymentToken).transfer(referrer, reward);
        if (!success) revert TransferFailed();
        
        emit ReferralPaid(referrer, referee, reward, paymentToken);
    }
    
    /**
     * @dev Deploy new TokenomicsMaster contract
     * @param tokenAddress Token address for the TokenomicsMaster
     * @return deployment Address of deployed contract
     */
    function _deployContract(address tokenAddress) internal returns (address deployment) {
        // Get TokenomicsMaster bytecode with constructor arguments
        bytes memory bytecode = abi.encodePacked(
            _getTokenomicsMasterBytecode(),
            abi.encode(tokenAddress)
        );
        
        // Generate salt for CREATE2
        bytes32 salt = keccak256(
            abi.encodePacked(
                msg.sender,
                tokenAddress,
                block.timestamp,
                totalDeployments
            )
        );
        
        // Deploy using CREATE2
        assembly {
            deployment := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        if (deployment == address(0)) revert DeploymentFailed();
        
        // Verify deployment
        if (ITokenomicsMaster(deployment).TOKEN() != tokenAddress) {
            revert DeploymentFailed();
        }
        
        return deployment;
    }
    
    /**
     * @dev Get TokenomicsMaster bytecode
     * @return bytecode The bytecode to deploy
     */
    function _getTokenomicsMasterBytecode() internal pure returns (bytes memory) {
        // In production, this would return the actual TokenomicsMaster bytecode
        // For now, this is a placeholder that must be replaced with actual bytecode
        // You can get this by compiling TokenomicsMaster and using type(TokenomicsMaster).creationCode
        
        // IMPORTANT: Replace this with actual bytecode
        return hex""; // Placeholder - must be replaced with actual bytecode
    }
    
    /**
     * @dev Generate unique deployment ID
     */
    function _generateDeploymentId(
        address deployer,
        address tokenAddress,
        address deployment
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                deployer,
                tokenAddress,
                deployment,
                block.timestamp,
                totalDeployments
            )
        );
    }
    
    /**
     * @dev Record deployment information
     */
    function _recordDeployment(
        address deployment,
        address deployer,
        DeploymentParams memory params,
        uint256 feePaid,
        bytes32 deploymentId
    ) internal {
        // Create deployment info
        DeploymentInfo storage info = deploymentInfo[deployment];
        info.deployer = deployer;
        info.tokenAddress = params.tokenAddress;
        info.paymentToken = params.paymentToken;
        info.feePaid = feePaid;
        info.deploymentTime = block.timestamp;
        info.projectName = params.projectName;
        info.projectSymbol = params.projectSymbol;
        info.deploymentId = deploymentId;
        
        // Set metadata
        info.metadata.description = params.description;
        info.metadata.logoUrl = params.logoUrl;
        info.metadata.websiteUrl = params.websiteUrl;
        info.metadata.category = params.category;
        info.metadata.indexRegistered = false;
        info.metadata.deploymentBlock = block.number;
        
        // Update tracking
        deploymentsByUser[deployer].push(deployment);
        isValidDeployment[deployment] = true;
        deploymentIndex[deployment] = allDeployments.length;
        allDeployments.push(deployment);
        totalDeployments++;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner validAddress(newTreasury) {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Update referral percentage
     * @param newPercentage New referral percentage in basis points
     */
    function updateReferralPercentage(uint256 newPercentage) external onlyOwner {
        if (newPercentage > 5000) revert InvalidDiscount(); // Max 50%
        referralPercentage = newPercentage;
    }
    
    /**
     * @notice Transfer ownership of factory
     * @param newOwner Address of new owner
     */
    function transferOwnership(address newOwner) external onlyOwner validAddress(newOwner) {
        address oldOwner = owner;
        owner = newOwner;
        whitelistedDeployers[newOwner] = true;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    
    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Token address
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(
        address token,
        uint256 amount
    ) external onlyOwner {
        // Prevent recovery of revenue tokens unless emergency
        if (revenueByToken[token] > 0) {
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            require(
                amount <= contractBalance - revenueByToken[token],
                "Cannot recover revenue tokens"
            );
        }
        
        bool success = IERC20(token).transfer(owner, amount);
        if (!success) revert TransferFailed();
    }
    
    /**
     * @notice Verify if a deployment is valid by checking bytecode
     * @param deployment Address to verify
     * @return valid Whether the deployment is valid
     */
    function verifyDeployment(address deployment) external view returns (bool valid) {
        // Check if registered
        if (!isValidDeployment[deployment]) return false;
        
        // Additional checks can be added here
        try ITokenomicsMaster(deployment).owner() returns (address) {
            try ITokenomicsMaster(deployment).TOKEN() returns (address token) {
                return token != address(0);
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
