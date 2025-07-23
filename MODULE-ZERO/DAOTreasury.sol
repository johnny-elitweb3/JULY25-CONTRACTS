// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title DAOTreasury
 * @author CIFI Wealth Management Module
 * @notice Enterprise-grade DAO-governed treasury with multi-asset support and budget management
 * @dev Non-proxy implementation with comprehensive asset management and governance integration
 */
contract DAOTreasury {
    // ============ Libraries ============
    
    using SafeERC20 for IERC20;
    
    // ============ Events ============
    
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, ProposalType proposalType);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event AssetWhitelisted(address indexed asset, AssetType assetType);
    event AssetDelisted(address indexed asset);
    event DepositReceived(address indexed asset, address indexed from, uint256 amount, uint256 tokenId);
    event WithdrawalExecuted(address indexed asset, address indexed to, uint256 amount, uint256 tokenId);
    event BudgetAllocated(bytes32 indexed budgetId, uint256 amount, uint256 period);
    event BudgetSpent(bytes32 indexed budgetId, uint256 amount);
    event EmergencyActionExecuted(address indexed executor, bytes32 action);
    event GovernanceTokenSet(address indexed token);
    event QuorumUpdated(uint256 newQuorum);
    event TimelockUpdated(uint256 newTimelock);
    
    // ============ Errors ============
    
    error Unauthorized();
    error InvalidProposal();
    error ProposalNotActive();
    error ProposalNotSucceeded();
    error ProposalNotReady();
    error AlreadyVoted();
    error InsufficientVotingPower();
    error AssetNotWhitelisted();
    error AssetAlreadyWhitelisted();
    error InvalidAssetType();
    error InvalidAmount();
    error InvalidRecipient();
    error BudgetExceeded();
    error BudgetNotFound();
    error WithdrawalFailed();
    error InvalidQuorum();
    error InvalidTimelock();
    error EmergencyOnly();
    error Paused();
    error ZeroAddress();
    error InvalidBudgetPeriod();
    error ProposalExpired();
    
    // ============ Constants ============
    
    uint256 public constant PROPOSAL_DURATION = 7 days;
    uint256 public constant MIN_TIMELOCK = 2 days;
    uint256 public constant MAX_TIMELOCK = 30 days;
    uint256 public constant EMERGENCY_DELAY = 12 hours;
    uint256 public constant MAX_BUDGET_PERIOD = 365 days;
    
    // ============ Enums ============
    
    enum AssetType {
        ETH,
        ERC20,
        ERC721,
        ERC1155
    }
    
    enum ProposalType {
        WITHDRAWAL,
        WHITELIST_ASSET,
        DELIST_ASSET,
        ALLOCATE_BUDGET,
        UPDATE_GOVERNANCE,
        EMERGENCY_ACTION
    }
    
    enum ProposalState {
        PENDING,
        ACTIVE,
        SUCCEEDED,
        EXECUTED,
        CANCELLED,
        EXPIRED
    }
    
    // ============ Structs ============
    
    struct Asset {
        bool whitelisted;
        AssetType assetType;
        uint256 totalBalance;
        mapping(uint256 => address) nftOwners; // For NFTs
        mapping(address => uint256) erc1155Balances; // For ERC1155 per holder
    }
    
    struct Proposal {
        ProposalType proposalType;
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint256 startTime;
        uint256 endTime;
        uint256 executionTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool cancelled;
        string description;
        mapping(address => bool) hasVoted;
    }
    
    struct Budget {
        uint256 allocated;
        uint256 spent;
        uint256 period;
        uint256 lastReset;
        bool active;
        address manager;
    }
    
    struct EmergencyAction {
        address initiator;
        bytes32 actionHash;
        uint256 initiatedAt;
        bool executed;
    }
    
    // ============ State Variables ============
    
    // Governance
    address public governanceToken;
    uint256 public quorum;
    uint256 public timelock;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    
    // Assets
    mapping(address => Asset) public assets;
    address[] public whitelistedAssets;
    mapping(address => mapping(uint256 => bool)) public nftDeposited; // For ERC721
    
    // Budgets
    mapping(bytes32 => Budget) public budgets;
    bytes32[] public activeBudgets;
    
    // Security
    bool public paused;
    mapping(address => bool) public guardians;
    mapping(bytes32 => EmergencyAction) public emergencyActions;
    uint256 public emergencyActionCount;
    
    // Access Control
    address public admin;
    mapping(address => bool) public managers;
    
    // Reentrancy
    uint256 private locked = 1;
    
    // ============ Modifiers ============
    
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyManager() {
        if (!managers[msg.sender] && msg.sender != admin) revert Unauthorized();
        _;
    }
    
    modifier onlyGuardian() {
        if (!guardians[msg.sender]) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }
    
    modifier nonReentrant() {
        require(locked == 1, "Reentrancy");
        locked = 2;
        _;
        locked = 1;
    }
    
    modifier onlyWhitelisted(address asset) {
        if (!assets[asset].whitelisted && asset != address(0)) revert AssetNotWhitelisted();
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize the DAO Treasury
     * @param _admin Initial admin address
     * @param _governanceToken Token used for voting
     * @param _quorum Minimum votes required
     * @param _timelock Execution delay in seconds
     */
    constructor(
        address _admin,
        address _governanceToken,
        uint256 _quorum,
        uint256 _timelock
    ) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_governanceToken == address(0)) revert ZeroAddress();
        if (_quorum == 0) revert InvalidQuorum();
        if (_timelock < MIN_TIMELOCK || _timelock > MAX_TIMELOCK) revert InvalidTimelock();
        
        admin = _admin;
        governanceToken = _governanceToken;
        quorum = _quorum;
        timelock = _timelock;
        
        // Whitelist ETH by default
        assets[address(0)].whitelisted = true;
        assets[address(0)].assetType = AssetType.ETH;
        whitelistedAssets.push(address(0));
        
        emit GovernanceTokenSet(_governanceToken);
        emit QuorumUpdated(_quorum);
        emit TimelockUpdated(_timelock);
    }
    
    // ============ Proposal Functions ============
    
    /**
     * @notice Create a withdrawal proposal
     * @param asset Asset address (0x0 for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw (or tokenId for NFTs)
     * @param description Proposal description
     * @return proposalId The ID of the created proposal
     */
    function proposeWithdrawal(
        address asset,
        address to,
        uint256 amount,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        if (to == address(0)) revert InvalidRecipient();
        if (!assets[asset].whitelisted) revert AssetNotWhitelisted();
        
        bytes memory data = abi.encode(asset, to, amount);
        proposalId = _createProposal(
            ProposalType.WITHDRAWAL,
            asset,
            amount,
            data,
            description
        );
    }
    
    /**
     * @notice Create an asset whitelist proposal
     * @param asset Asset address to whitelist
     * @param assetType Type of asset
     * @param description Proposal description
     * @return proposalId The ID of the created proposal
     */
    function proposeAssetWhitelist(
        address asset,
        AssetType assetType,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        if (asset == address(0) && assetType != AssetType.ETH) revert InvalidAssetType();
        if (assets[asset].whitelisted) revert AssetAlreadyWhitelisted();
        
        bytes memory data = abi.encode(asset, assetType);
        proposalId = _createProposal(
            ProposalType.WHITELIST_ASSET,
            asset,
            0,
            data,
            description
        );
    }
    
    /**
     * @notice Create a budget allocation proposal
     * @param budgetId Unique budget identifier
     * @param amount Budget amount
     * @param period Budget period in seconds
     * @param manager Budget manager address
     * @param description Proposal description
     * @return proposalId The ID of the created proposal
     */
    function proposeBudgetAllocation(
        bytes32 budgetId,
        uint256 amount,
        uint256 period,
        address manager,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        if (amount == 0) revert InvalidAmount();
        if (period == 0 || period > MAX_BUDGET_PERIOD) revert InvalidBudgetPeriod();
        if (manager == address(0)) revert ZeroAddress();
        
        bytes memory data = abi.encode(budgetId, amount, period, manager);
        proposalId = _createProposal(
            ProposalType.ALLOCATE_BUDGET,
            address(this),
            amount,
            data,
            description
        );
    }
    
    /**
     * @notice Vote on a proposal
     * @param proposalId Proposal ID
     * @param support True for yes, false for no
     */
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        ProposalState state = getProposalState(proposalId);
        
        if (state != ProposalState.ACTIVE) revert ProposalNotActive();
        if (proposal.hasVoted[msg.sender]) revert AlreadyVoted();
        
        uint256 votingPower = _getVotingPower(msg.sender);
        if (votingPower == 0) revert InsufficientVotingPower();
        
        proposal.hasVoted[msg.sender] = true;
        
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }
        
        emit VoteCast(proposalId, msg.sender, support, votingPower);
    }
    
    /**
     * @notice Execute a succeeded proposal
     * @param proposalId Proposal ID to execute
     */
    function executeProposal(uint256 proposalId) external whenNotPaused nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        ProposalState state = getProposalState(proposalId);
        
        if (state != ProposalState.SUCCEEDED) revert ProposalNotSucceeded();
        if (block.timestamp < proposal.endTime + timelock) revert ProposalNotReady();
        
        proposal.executed = true;
        
        if (proposal.proposalType == ProposalType.WITHDRAWAL) {
            _executeWithdrawal(proposal.data);
        } else if (proposal.proposalType == ProposalType.WHITELIST_ASSET) {
            _executeWhitelist(proposal.data);
        } else if (proposal.proposalType == ProposalType.ALLOCATE_BUDGET) {
            _executeBudgetAllocation(proposal.data);
        } else if (proposal.proposalType == ProposalType.DELIST_ASSET) {
            _executeDelistAsset(proposal.data);
        }
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @notice Cancel a proposal (only proposer or admin)
     * @param proposalId Proposal ID to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (msg.sender != proposal.proposer && msg.sender != admin) revert Unauthorized();
        if (proposal.executed || proposal.cancelled) revert InvalidProposal();
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }
    
    // ============ Asset Management Functions ============
    
    /**
     * @notice Deposit ETH into treasury
     */
    receive() external payable {
        assets[address(0)].totalBalance += msg.value;
        emit DepositReceived(address(0), msg.sender, msg.value, 0);
    }
    
    /**
     * @notice Deposit ERC20 tokens
     * @param token Token address
     * @param amount Amount to deposit
     */
    function depositERC20(address token, uint256 amount) 
        external 
        whenNotPaused 
        onlyWhitelisted(token) 
    {
        if (amount == 0) revert InvalidAmount();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        assets[token].totalBalance += amount;
        
        emit DepositReceived(token, msg.sender, amount, 0);
    }
    
    /**
     * @notice Deposit ERC721 NFT
     * @param token NFT contract address
     * @param tokenId Token ID
     */
    function depositERC721(address token, uint256 tokenId) 
        external 
        whenNotPaused 
        onlyWhitelisted(token) 
    {
        IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        assets[token].nftOwners[tokenId] = msg.sender;
        nftDeposited[token][tokenId] = true;
        assets[token].totalBalance++;
        
        emit DepositReceived(token, msg.sender, 1, tokenId);
    }
    
    /**
     * @notice Deposit ERC1155 tokens
     * @param token Token address
     * @param id Token ID
     * @param amount Amount to deposit
     */
    function depositERC1155(address token, uint256 id, uint256 amount) 
        external 
        whenNotPaused 
        onlyWhitelisted(token) 
    {
        IERC1155(token).safeTransferFrom(msg.sender, address(this), id, amount, "");
        assets[token].erc1155Balances[msg.sender] += amount;
        assets[token].totalBalance += amount;
        
        emit DepositReceived(token, msg.sender, amount, id);
    }
    
    /**
     * @notice Spend from allocated budget
     * @param budgetId Budget identifier
     * @param recipient Payment recipient
     * @param amount Amount to spend
     */
    function spendFromBudget(
        bytes32 budgetId,
        address recipient,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        Budget storage budget = budgets[budgetId];
        
        if (!budget.active) revert BudgetNotFound();
        if (msg.sender != budget.manager && !managers[msg.sender]) revert Unauthorized();
        if (recipient == address(0)) revert InvalidRecipient();
        
        // Reset budget if period ended
        if (block.timestamp >= budget.lastReset + budget.period) {
            budget.spent = 0;
            budget.lastReset = block.timestamp;
        }
        
        if (budget.spent + amount > budget.allocated) revert BudgetExceeded();
        
        budget.spent += amount;
        
        // Execute ETH transfer
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert WithdrawalFailed();
        
        emit BudgetSpent(budgetId, amount);
        emit WithdrawalExecuted(address(0), recipient, amount, 0);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get proposal state
     * @param proposalId Proposal ID
     * @return Current proposal state
     */
    function getProposalState(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.cancelled) return ProposalState.CANCELLED;
        if (proposal.executed) return ProposalState.EXECUTED;
        if (block.timestamp < proposal.startTime) return ProposalState.PENDING;
        if (block.timestamp > proposal.endTime + timelock + PROPOSAL_DURATION) return ProposalState.EXPIRED;
        if (block.timestamp <= proposal.endTime) return ProposalState.ACTIVE;
        
        if (proposal.forVotes > proposal.againstVotes && proposal.forVotes >= quorum) {
            return ProposalState.SUCCEEDED;
        }
        
        return ProposalState.EXPIRED;
    }
    
    /**
     * @notice Get whitelisted assets
     * @return Array of whitelisted asset addresses
     */
    function getWhitelistedAssets() external view returns (address[] memory) {
        return whitelistedAssets;
    }
    
    /**
     * @notice Get active budgets
     * @return Array of active budget IDs
     */
    function getActiveBudgets() external view returns (bytes32[] memory) {
        return activeBudgets;
    }
    
    /**
     * @notice Get budget details
     * @param budgetId Budget identifier
     * @return allocated Allocated budget amount
     * @return spent Amount spent from budget
     * @return period Budget period duration
     * @return lastReset Last reset timestamp
     * @return active Whether budget is active
     * @return manager Budget manager address
     */
    function getBudgetDetails(bytes32 budgetId) external view returns (
        uint256 allocated,
        uint256 spent,
        uint256 period,
        uint256 lastReset,
        bool active,
        address manager
    ) {
        Budget storage budget = budgets[budgetId];
        return (
            budget.allocated,
            budget.spent,
            budget.period,
            budget.lastReset,
            budget.active,
            budget.manager
        );
    }
    
    /**
     * @notice Check asset balance
     * @param asset Asset address
     * @return Balance held by treasury
     */
    function getAssetBalance(address asset) external view returns (uint256) {
        if (asset == address(0)) {
            return address(this).balance;
        }
        return assets[asset].totalBalance;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update governance parameters
     * @param _governanceToken New governance token
     * @param _quorum New quorum
     * @param _timelock New timelock period
     */
    function updateGovernance(
        address _governanceToken,
        uint256 _quorum,
        uint256 _timelock
    ) external onlyAdmin {
        if (_governanceToken != address(0)) {
            governanceToken = _governanceToken;
            emit GovernanceTokenSet(_governanceToken);
        }
        
        if (_quorum > 0) {
            quorum = _quorum;
            emit QuorumUpdated(_quorum);
        }
        
        if (_timelock >= MIN_TIMELOCK && _timelock <= MAX_TIMELOCK) {
            timelock = _timelock;
            emit TimelockUpdated(_timelock);
        }
    }
    
    /**
     * @notice Add a manager
     * @param manager Address to add as manager
     */
    function addManager(address manager) external onlyAdmin {
        if (manager == address(0)) revert ZeroAddress();
        managers[manager] = true;
    }
    
    /**
     * @notice Remove a manager
     * @param manager Address to remove as manager
     */
    function removeManager(address manager) external onlyAdmin {
        managers[manager] = false;
    }
    
    /**
     * @notice Add a guardian for emergency actions
     * @param guardian Address to add as guardian
     */
    function addGuardian(address guardian) external onlyAdmin {
        if (guardian == address(0)) revert ZeroAddress();
        guardians[guardian] = true;
    }
    
    /**
     * @notice Transfer admin role
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Initiate emergency action
     * @param actionHash Hash of the emergency action
     */
    function initiateEmergencyAction(bytes32 actionHash) external onlyGuardian {
        emergencyActions[actionHash] = EmergencyAction({
            initiator: msg.sender,
            actionHash: actionHash,
            initiatedAt: block.timestamp,
            executed: false
        });
        emergencyActionCount++;
    }
    
    /**
     * @notice Execute emergency pause
     */
    function emergencyPause() external onlyGuardian {
        bytes32 actionHash = keccak256(abi.encode("PAUSE", block.timestamp));
        EmergencyAction storage action = emergencyActions[actionHash];
        
        if (action.initiatedAt == 0) revert EmergencyOnly();
        if (block.timestamp < action.initiatedAt + EMERGENCY_DELAY) revert ProposalNotReady();
        if (action.executed) revert InvalidProposal();
        
        action.executed = true;
        paused = true;
        
        emit EmergencyActionExecuted(msg.sender, actionHash);
    }
    
    /**
     * @notice Emergency withdrawal (requires guardian consensus)
     * @param token Token address (0x0 for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyGuardian nonReentrant {
        bytes32 actionHash = keccak256(abi.encode("WITHDRAW", token, to, amount));
        EmergencyAction storage action = emergencyActions[actionHash];
        
        if (action.initiatedAt == 0) revert EmergencyOnly();
        if (block.timestamp < action.initiatedAt + EMERGENCY_DELAY) revert ProposalNotReady();
        if (action.executed) revert InvalidProposal();
        
        action.executed = true;
        
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert WithdrawalFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit EmergencyActionExecuted(msg.sender, actionHash);
        emit WithdrawalExecuted(token, to, amount, 0);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Create a new proposal
     */
    function _createProposal(
        ProposalType proposalType,
        address target,
        uint256 value,
        bytes memory data,
        string calldata description
    ) internal returns (uint256 proposalId) {
        uint256 votingPower = _getVotingPower(msg.sender);
        if (votingPower == 0) revert InsufficientVotingPower();
        
        proposalId = proposalCount++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.proposalType = proposalType;
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.value = value;
        proposal.data = data;
        proposal.startTime = block.timestamp;
        proposal.endTime = block.timestamp + PROPOSAL_DURATION;
        proposal.description = description;
        
        emit ProposalCreated(proposalId, msg.sender, proposalType);
    }
    
    /**
     * @dev Get voting power of an address
     */
    function _getVotingPower(address voter) internal view returns (uint256) {
        if (governanceToken == address(0)) return 0;
        return IERC20(governanceToken).balanceOf(voter);
    }
    
    /**
     * @dev Execute withdrawal proposal
     */
    function _executeWithdrawal(bytes memory data) internal {
        (address asset, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        
        if (asset == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert WithdrawalFailed();
        } else if (assets[asset].assetType == AssetType.ERC20) {
            IERC20(asset).safeTransfer(to, amount);
            assets[asset].totalBalance -= amount;
        } else if (assets[asset].assetType == AssetType.ERC721) {
            IERC721(asset).safeTransferFrom(address(this), to, amount);
            delete assets[asset].nftOwners[amount];
            nftDeposited[asset][amount] = false;
            assets[asset].totalBalance--;
        }
        
        emit WithdrawalExecuted(asset, to, amount, 0);
    }
    
    /**
     * @dev Execute asset whitelist proposal
     */
    function _executeWhitelist(bytes memory data) internal {
        (address asset, AssetType assetType) = abi.decode(data, (address, AssetType));
        
        assets[asset].whitelisted = true;
        assets[asset].assetType = assetType;
        whitelistedAssets.push(asset);
        
        emit AssetWhitelisted(asset, assetType);
    }
    
    /**
     * @dev Execute budget allocation proposal
     */
    function _executeBudgetAllocation(bytes memory data) internal {
        (bytes32 budgetId, uint256 amount, uint256 period, address manager) = 
            abi.decode(data, (bytes32, uint256, uint256, address));
        
        Budget storage budget = budgets[budgetId];
        budget.allocated = amount;
        budget.period = period;
        budget.lastReset = block.timestamp;
        budget.active = true;
        budget.manager = manager;
        
        if (budget.spent == 0) { // New budget
            activeBudgets.push(budgetId);
        }
        
        emit BudgetAllocated(budgetId, amount, period);
    }
    
    /**
     * @dev Execute asset delisting proposal
     */
    function _executeDelistAsset(bytes memory data) internal {
        address asset = abi.decode(data, (address));
        
        assets[asset].whitelisted = false;
        
        // Remove from whitelisted array
        for (uint256 i = 0; i < whitelistedAssets.length; i++) {
            if (whitelistedAssets[i] == asset) {
                whitelistedAssets[i] = whitelistedAssets[whitelistedAssets.length - 1];
                whitelistedAssets.pop();
                break;
            }
        }
        
        emit AssetDelisted(asset);
    }
    
    // ============ Token Reception Functions ============
    
    /**
     * @notice Handle ERC721 token reception
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external returns (bytes4) {
        if (assets[msg.sender].whitelisted && assets[msg.sender].assetType == AssetType.ERC721) {
            assets[msg.sender].nftOwners[tokenId] = from;
            nftDeposited[msg.sender][tokenId] = true;
            assets[msg.sender].totalBalance++;
            emit DepositReceived(msg.sender, from, 1, tokenId);
        }
        return this.onERC721Received.selector;
    }
    
    /**
     * @notice Handle ERC1155 token reception
     */
    function onERC1155Received(
        address,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata
    ) external returns (bytes4) {
        if (assets[msg.sender].whitelisted && assets[msg.sender].assetType == AssetType.ERC1155) {
            assets[msg.sender].erc1155Balances[from] += value;
            assets[msg.sender].totalBalance += value;
            emit DepositReceived(msg.sender, from, value, id);
        }
        return this.onERC1155Received.selector;
    }
    
    /**
     * @notice Handle ERC1155 batch token reception
     */
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata
    ) external returns (bytes4) {
        if (assets[msg.sender].whitelisted && assets[msg.sender].assetType == AssetType.ERC1155) {
            uint256 totalValue = 0;
            for (uint256 i = 0; i < values.length; i++) {
                totalValue += values[i];
                // Emit event for each token ID received
                if (i < ids.length) {
                    emit DepositReceived(msg.sender, from, values[i], ids[i]);
                }
            }
            assets[msg.sender].erc1155Balances[from] += totalValue;
            assets[msg.sender].totalBalance += totalValue;
        }
        return this.onERC1155BatchReceived.selector;
    }
}

// ============ External Interfaces ============

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
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
