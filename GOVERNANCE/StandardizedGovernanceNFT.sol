// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title IStakingSystem
 * @notice Interface for staking systems to determine voting power multipliers
 */
interface IStakingSystem {
    function getUserMultiplier(address _user) external view returns (uint256);
}

/**
 * @title StandardizedGovernanceNFT
 * @dev Production-ready governance NFT with automated profit sharing and full compatibility
 * @notice Features pull-based distribution system with error isolation and timelock security
 * @author Enhanced Implementation v2.0.0
 */
contract StandardizedGovernanceNFT is
    ERC721Enumerable,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using Strings for uint256;

    // ========== Version ==========
    string public constant VERSION = "2.0.0";

    // ========== Roles ==========
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ========= NFT Properties ==========
    string public baseURI;
    string public baseExtension = ".json";
    uint256 public immutable maxSupply;
    uint256 public totalMinted;
    uint256 public mintStartTime;
    bool public publicMintEnabled;

    // ========= Purchase Price Tracking (NEW) ==========
    mapping(uint256 => uint256) private tokenPurchasePrices;
    mapping(uint256 => address) private tokenPaymentTokens;

    // ========= Governance Integration ==========
    address public governanceContract;
    address public stakingContract;

    // ========= Configuration ==========
    uint256 public mintPrice; // Price in native currency (in wei)

    // ========= Profit Sharing ==========
    // Beneficiary addresses (immutable for security)
    address payable public immutable developersAddress;
    address payable public immutable consultingAddress;
    address payable public immutable payrollAddress;
    address payable public immutable treasuryAddress;
    address payable public immutable marketingAddress;
    address payable public immutable operationsAddress;

    // Distribution percentages (out of 10000 for precision)
    uint256 public constant DEVELOPERS_SHARE = 1000; // 10%
    uint256 public constant CONSULTING_SHARE = 1000; // 10%
    uint256 public constant PAYROLL_SHARE = 3000; // 30%
    uint256 public constant TREASURY_SHARE = 3000; // 30%
    uint256 public constant MARKETING_SHARE = 1000; // 10%
    uint256 public constant OPERATIONS_SHARE = 1000; // 10%
    uint256 public constant TOTAL_SHARES = 10000; // 100%

    // ========= Pull-based Distribution System ==========
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPendingWithdrawals;

    // ========= Timelock for Emergency Functions ==========
    uint256 public constant TIMELOCK_DURATION = 48 hours;
    uint256 public emergencyWithdrawalTimestamp;
    address payable public pendingEmergencyRecipient;
    uint256 public pendingEmergencyAmount;

    // ========= Contract Balance Tracking ==========
    uint256 public undistributedBalance;

    // ========= Tracking ==========
    uint256 public totalRevenue;
    uint256 public totalDistributed;
    uint256 public totalClaimed;

    mapping(address => uint256) public beneficiaryReceived;
    mapping(address => uint256) public beneficiaryClaimed;

    // ========= Events ==========
    event BaseURIUpdated(string newBaseURI);
    event TokenMinted(
        address indexed to,
        uint256 tokenId,
        uint256 timestamp,
        uint256 price
    );
    event BatchMinted(
        address indexed to,
        uint256 amount,
        uint256 startTokenId,
        uint256 timestamp
    );
    event GovernanceContractUpdated(
        address previousContract,
        address newContract
    );
    event StakingContractUpdated(address previousContract, address newContract);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event VotingPowerCalculated(address indexed user, uint256 totalPower);
    event PublicMintToggled(bool enabled);
    event MintStartTimeSet(uint256 timestamp);
    event RevenueDistributed(
        uint256 amount,
        uint256 toDevelopers,
        uint256 toConsulting,
        uint256 toPayroll,
        uint256 toTreasury,
        uint256 toMarketing,
        uint256 toOperations
    );
    event DistributionFailed(address indexed beneficiary, uint256 amount);
    event WithdrawalClaimed(address indexed beneficiary, uint256 amount);
    event EmergencyWithdrawalInitiated(
        address indexed recipient,
        uint256 amount,
        uint256 executeTime
    );
    event EmergencyWithdrawalExecuted(
        address indexed recipient,
        uint256 amount
    );
    event EmergencyWithdrawalCancelled();
    event RefundIssued(address indexed to, uint256 amount);
    event ManualDistributionTriggered(address indexed by, uint256 amount);
    event PurchasePriceRecorded(
        uint256 indexed tokenId,
        uint256 price,
        address paymentToken
    );

    // ========= Custom Errors ==========
    error InvalidParameters();
    error InvalidAddress();
    error InvalidAmount();
    error MaxSupplyReached();
    error PublicMintNotEnabled();
    error MintNotStarted();
    error InsufficientPayment();
    error RefundFailed();
    error NoBalanceToDistribute();
    error NoPendingEmergencyWithdrawal();
    error TimelockNotExpired();
    error EmergencyWithdrawalFailed();
    error TokenDoesNotExist();
    error InvalidExtension();
    error NotAContract();
    error OnlyThroughFallback();

    /**
     * @dev Constructor for the StandardizedGovernanceNFT
     * @param _name Name of the NFT collection
     * @param _symbol Symbol of the NFT collection
     * @param _initBaseURI Base URI for token metadata
     * @param _maxSupply Maximum number of tokens that can be minted
     * @param _initialPrice Initial price for minting (in wei)
     * @param _developers Address for developers share (10%)
     * @param _consulting Address for consulting group share (10%)
     * @param _payroll Address for payroll share (30%)
     * @param _treasury Address for treasury share (30%)
     * @param _marketing Address for marketing share (10%)
     * @param _operations Address for operations share (10%)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _initBaseURI,
        uint256 _maxSupply,
        uint256 _initialPrice,
        address payable _developers,
        address payable _consulting,
        address payable _payroll,
        address payable _treasury,
        address payable _marketing,
        address payable _operations
    ) ERC721(_name, _symbol) {
        // Validate parameters
        if (_maxSupply == 0) revert InvalidParameters();
        if (_developers == address(0)) revert InvalidAddress();
        if (_consulting == address(0)) revert InvalidAddress();
        if (_payroll == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        if (_marketing == address(0)) revert InvalidAddress();
        if (_operations == address(0)) revert InvalidAddress();

        // Ensure all beneficiary addresses are unique
        if (
            _developers == _consulting ||
            _developers == _payroll ||
            _developers == _treasury ||
            _developers == _marketing ||
            _developers == _operations
        ) revert InvalidParameters();
        if (
            _consulting == _payroll ||
            _consulting == _treasury ||
            _consulting == _marketing ||
            _consulting == _operations
        ) revert InvalidParameters();
        if (
            _payroll == _treasury ||
            _payroll == _marketing ||
            _payroll == _operations
        ) revert InvalidParameters();
        if (_treasury == _marketing || _treasury == _operations)
            revert InvalidParameters();
        if (_marketing == _operations) revert InvalidParameters();

        // Initialize contract variables
        baseURI = _initBaseURI;
        maxSupply = _maxSupply;
        mintPrice = _initialPrice;

        // Set beneficiary addresses (immutable)
        developersAddress = _developers;
        consultingAddress = _consulting;
        payrollAddress = _payroll;
        treasuryAddress = _treasury;
        marketingAddress = _marketing;
        operationsAddress = _operations;

        // Default: public mint disabled until explicitly enabled
        publicMintEnabled = false;

        // Set up roles for contract deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    // ========== Version Function (NEW) ==========

    /**
     * @notice Get contract version
     * @return Contract version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ========== Core NFT Functions ==========

    /**
     * @dev Override the base URI function
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /**
     * @dev Get the token URI for a specific token ID
     */
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        _requireOwned(tokenId);

        string memory currentBaseURI = _baseURI();
        return
            bytes(currentBaseURI).length > 0
                ? string(
                    abi.encodePacked(
                        currentBaseURI,
                        tokenId.toString(),
                        baseExtension
                    )
                )
                : "";
    }

    /**
     * @dev Hook that is called before any token transfer. This includes minting
     * and burning. Used to implement pause functionality.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Check if paused (skip for minting and burning)
        if (from != address(0) && to != address(0) && paused()) {
            revert("Token transfers paused");
        }

        return super._update(to, tokenId, auth);
    }

    // ========== Purchase Price Tracking (NEW) ==========

    /**
     * @notice Get the purchase price and payment token for a specific NFT
     * @param tokenId The token ID to query
     * @return price The purchase price of the token
     * @return paymentToken The token used for payment (address(0) for ETH)
     */
    function getPurchasePrice(uint256 tokenId)
        external
        view
        returns (uint256 price, address paymentToken)
    {
        _requireOwned(tokenId);
        return (tokenPurchasePrices[tokenId], tokenPaymentTokens[tokenId]);
    }

    // ========== Pull-based Profit Distribution ==========

    /**
     * @dev Distributes revenue to all beneficiaries with error isolation
     * @param _amount Total amount to distribute
     */
    function _distributeRevenue(uint256 _amount) private {
        if (_amount == 0) return;

        // Calculate individual shares
        uint256 developersAmount = (_amount * DEVELOPERS_SHARE) / TOTAL_SHARES;
        uint256 consultingAmount = (_amount * CONSULTING_SHARE) / TOTAL_SHARES;
        uint256 payrollAmount = (_amount * PAYROLL_SHARE) / TOTAL_SHARES;
        uint256 treasuryAmount = (_amount * TREASURY_SHARE) / TOTAL_SHARES;
        uint256 marketingAmount = (_amount * MARKETING_SHARE) / TOTAL_SHARES;
        uint256 operationsAmount = (_amount * OPERATIONS_SHARE) / TOTAL_SHARES;

        // Handle any rounding dust by adding to treasury
        uint256 totalAllocated = developersAmount +
            consultingAmount +
            payrollAmount +
            treasuryAmount +
            marketingAmount +
            operationsAmount;
        if (_amount > totalAllocated) {
            treasuryAmount += (_amount - totalAllocated);
        }

        // Update tracking
        totalRevenue += _amount;
        totalDistributed += _amount;

        // Add to pending withdrawals (pull-based system)
        _addToPendingWithdrawal(developersAddress, developersAmount);
        _addToPendingWithdrawal(consultingAddress, consultingAmount);
        _addToPendingWithdrawal(payrollAddress, payrollAmount);
        _addToPendingWithdrawal(treasuryAddress, treasuryAmount);
        _addToPendingWithdrawal(marketingAddress, marketingAmount);
        _addToPendingWithdrawal(operationsAddress, operationsAmount);

        emit RevenueDistributed(
            _amount,
            developersAmount,
            consultingAmount,
            payrollAmount,
            treasuryAmount,
            marketingAmount,
            operationsAmount
        );

        // Attempt immediate distribution with error isolation
        _attemptWithdrawal(developersAddress);
        _attemptWithdrawal(consultingAddress);
        _attemptWithdrawal(payrollAddress);
        _attemptWithdrawal(treasuryAddress);
        _attemptWithdrawal(marketingAddress);
        _attemptWithdrawal(operationsAddress);
    }

    /**
     * @dev Add amount to pending withdrawal for a beneficiary
     * @param _beneficiary Address to receive funds
     * @param _amount Amount to add
     */
    function _addToPendingWithdrawal(address _beneficiary, uint256 _amount)
        private
    {
        if (_amount > 0) {
            pendingWithdrawals[_beneficiary] += _amount;
            totalPendingWithdrawals += _amount;
            beneficiaryReceived[_beneficiary] += _amount;
        }
    }

    /**
     * @dev Attempt to withdraw pending amount with error isolation
     * @param _beneficiary Address to send funds to
     */
    function _attemptWithdrawal(address _beneficiary) private {
        uint256 amount = pendingWithdrawals[_beneficiary];
        if (amount == 0) return;

        // Reset pending amount before transfer to prevent reentrancy
        pendingWithdrawals[_beneficiary] = 0;
        totalPendingWithdrawals -= amount;

        // Attempt transfer with gas limit to prevent DoS
        (bool success, ) = _beneficiary.call{value: amount, gas: 30000}("");

        if (success) {
            beneficiaryClaimed[_beneficiary] += amount;
            totalClaimed += amount;
            emit WithdrawalClaimed(_beneficiary, amount);
        } else {
            // If transfer fails, add back to pending
            pendingWithdrawals[_beneficiary] += amount;
            totalPendingWithdrawals += amount;
            emit DistributionFailed(_beneficiary, amount);
        }
    }

    /**
     * @notice Claim pending withdrawals for a beneficiary
     * @dev Can be called by anyone to trigger withdrawal for a beneficiary
     * @param _beneficiary Address to claim for
     */
    function claimWithdrawal(address _beneficiary) external nonReentrant {
        if (_beneficiary == address(0)) revert InvalidAddress();
        _attemptWithdrawal(_beneficiary);
    }

    /**
     * @notice Claim all pending withdrawals for all beneficiaries
     * @dev Can be called by admin to retry all failed distributions
     */
    function claimAllWithdrawals() external onlyRole(ADMIN_ROLE) nonReentrant {
        _attemptWithdrawal(developersAddress);
        _attemptWithdrawal(consultingAddress);
        _attemptWithdrawal(payrollAddress);
        _attemptWithdrawal(treasuryAddress);
        _attemptWithdrawal(marketingAddress);
        _attemptWithdrawal(operationsAddress);
    }

    /**
     * @notice Manually trigger distribution of accumulated balance
     * @dev Only admin can trigger manual distribution
     */
    function distributeAccumulatedBalance()
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        uint256 balance = undistributedBalance;
        if (balance == 0) revert NoBalanceToDistribute();

        undistributedBalance = 0;
        _distributeRevenue(balance);

        emit ManualDistributionTriggered(msg.sender, balance);
    }

    // ========== Governance Integration ==========

    /**
     * @notice Calculate the total voting power of a token holder
     * @param _holder Address of the token holder
     * @return totalPower Total voting power including any staking boosts
     */
    function calculateVotingPower(address _holder)
        public
        view
        returns (uint256 totalPower)
    {
        uint256 tokenCount = balanceOf(_holder);
        if (tokenCount == 0) return 0;

        // Base voting power is always 1 per token
        totalPower = tokenCount;

        // Apply staking multiplier if staking contract is set
        if (stakingContract != address(0)) {
            try
                IStakingSystem(stakingContract).getUserMultiplier(_holder)
            returns (uint256 multiplier) {
                if (multiplier > 0) {
                    // Apply multiplier (based on basis points, e.g. 10000 = 1x, 15000 = 1.5x)
                    totalPower = (totalPower * multiplier) / 10000;
                }
            } catch {
                // If call fails, use base voting power
            }
        }

        // Event removed - this is a view function that should not emit events
        return totalPower;
    }

    /**
     * @notice Set the governance contract address
     * @param _governanceContract Address of the governance contract
     */
    function setGovernanceContract(address _governanceContract)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_governanceContract == address(0)) revert InvalidAddress();
        if (_governanceContract.code.length == 0) revert NotAContract();

        address oldGovernance = governanceContract;
        governanceContract = _governanceContract;

        // Grant governance role to the new contract
        _grantRole(GOVERNANCE_ROLE, _governanceContract);

        // Revoke from old governance if it exists and is not the same
        if (
            oldGovernance != address(0) && oldGovernance != _governanceContract
        ) {
            _revokeRole(GOVERNANCE_ROLE, oldGovernance);
        }

        emit GovernanceContractUpdated(oldGovernance, _governanceContract);
    }

    /**
     * @notice Set the staking contract address
     * @param _stakingContract Address of the staking contract
     */
    function setStakingContract(address _stakingContract)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_stakingContract == address(0)) revert InvalidAddress();
        if (_stakingContract.code.length == 0) revert NotAContract();

        address oldStaking = stakingContract;
        stakingContract = _stakingContract;

        emit StakingContractUpdated(oldStaking, _stakingContract);
    }

    // ========== Minting Configuration ==========

    /**
     * @notice Set the mint price
     * @param _newPrice New price in wei
     */
    function setMintPrice(uint256 _newPrice) external onlyRole(ADMIN_ROLE) {
        uint256 oldPrice = mintPrice;
        mintPrice = _newPrice;
        emit MintPriceUpdated(oldPrice, _newPrice);
    }

    /**
     * @notice Toggle public minting functionality
     * @param _enabled Whether public minting should be enabled
     */
    function togglePublicMint(bool _enabled) external onlyRole(ADMIN_ROLE) {
        publicMintEnabled = _enabled;
        emit PublicMintToggled(_enabled);
    }

    /**
     * @notice Set the start time for minting
     * @param _startTime Timestamp when minting should start
     */
    function setMintStartTime(uint256 _startTime)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_startTime <= block.timestamp) revert InvalidParameters();
        mintStartTime = _startTime;
        emit MintStartTimeSet(_startTime);
    }

    // ========== Minting Functions ==========

    /**
     * @notice Public mint function with automatic profit distribution
     * @return tokenId The ID of the minted token
     */
    function mint()
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!publicMintEnabled) revert PublicMintNotEnabled();

        // Check if minting has started
        if (mintStartTime > 0 && block.timestamp < mintStartTime) {
            revert MintNotStarted();
        }

        if (msg.value < mintPrice) revert InsufficientPayment();

        // Check supply
        if (totalMinted >= maxSupply) revert MaxSupplyReached();

        // Calculate refund if user sent more than needed
        uint256 refundAmount = 0;
        if (msg.value > mintPrice) {
            refundAmount = msg.value - mintPrice;
        }

        // Mint the token
        tokenId = totalMinted + 1;
        totalMinted += 1;

        _safeMint(msg.sender, tokenId);

        // Record purchase price (NEW)
        tokenPurchasePrices[tokenId] = mintPrice;
        tokenPaymentTokens[tokenId] = address(0); // ETH
        emit PurchasePriceRecorded(tokenId, mintPrice, address(0));

        emit TokenMinted(msg.sender, tokenId, block.timestamp, mintPrice);

        // Distribute the mint price immediately
        if (mintPrice > 0) {
            _distributeRevenue(mintPrice);
        }

        // Refund excess payment if any
        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            if (!success) revert RefundFailed();
            emit RefundIssued(msg.sender, refundAmount);
        }

        return tokenId;
    }

    /**
     * @notice Admin minting of NFTs (no payment required)
     * @param _to Recipient address
     * @param _amount Amount of NFTs to mint
     */
    function adminMint(address _to, uint256 _amount)
        external
        whenNotPaused
        onlyRole(MINTER_ROLE)
    {
        if (_to == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmount();

        if (totalMinted + _amount > maxSupply) revert MaxSupplyReached();

        uint256 startTokenId = totalMinted + 1;

        for (uint256 i = 0; i < _amount; i++) {
            uint256 tokenId = startTokenId + i;
            totalMinted += 1;
            _safeMint(_to, tokenId);

            // Record purchase price as 0 for admin mints (NEW)
            tokenPurchasePrices[tokenId] = 0;
            tokenPaymentTokens[tokenId] = address(0);
            emit PurchasePriceRecorded(tokenId, 0, address(0));
        }

        emit BatchMinted(_to, _amount, startTokenId, block.timestamp);
    }

    // ========== Admin Functions ==========

    /**
     * @notice Set the base URI for token metadata
     * @param _newBaseURI New base URI
     */
    function setBaseURI(string memory _newBaseURI)
        external
        onlyRole(ADMIN_ROLE)
    {
        baseURI = _newBaseURI;
        emit BaseURIUpdated(_newBaseURI);
    }

    /**
     * @notice Set the base extension for token URIs
     * @param _newBaseExtension New base extension
     */
    function setBaseExtension(string memory _newBaseExtension)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (bytes(_newBaseExtension).length == 0) revert InvalidExtension();
        if (bytes(_newBaseExtension)[0] != ".") revert InvalidExtension();
        baseExtension = _newBaseExtension;
    }

    /**
     * @notice Pause the contract - stops minting and transfers
     */
    function pauseContract() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpauseContract() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========== Timelock Emergency Functions ==========

    /**
     * @notice Initiate emergency withdrawal with timelock
     * @param _to Recipient address for emergency withdrawal
     */
    function initiateEmergencyWithdrawal(address payable _to)
        external
        onlyRole(ADMIN_ROLE)
        whenPaused
    {
        if (_to == address(0)) revert InvalidAddress();
        uint256 contractBalance = address(this).balance;
        uint256 availableBalance = contractBalance > totalPendingWithdrawals
            ? contractBalance - totalPendingWithdrawals
            : 0;
        if (availableBalance == 0) revert NoBalanceToDistribute();

        emergencyWithdrawalTimestamp = block.timestamp + TIMELOCK_DURATION;
        pendingEmergencyRecipient = _to;
        pendingEmergencyAmount = availableBalance;

        emit EmergencyWithdrawalInitiated(
            _to,
            availableBalance,
            emergencyWithdrawalTimestamp
        );
    }

    /**
     * @notice Execute emergency withdrawal after timelock period
     */
    function executeEmergencyWithdrawal()
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenPaused
    {
        if (emergencyWithdrawalTimestamp == 0)
            revert NoPendingEmergencyWithdrawal();
        if (block.timestamp < emergencyWithdrawalTimestamp)
            revert TimelockNotExpired();
        if (pendingEmergencyRecipient == address(0)) revert InvalidAddress();

        address payable recipient = pendingEmergencyRecipient;
        uint256 amount = pendingEmergencyAmount;

        // Reset emergency withdrawal state
        emergencyWithdrawalTimestamp = 0;
        pendingEmergencyRecipient = payable(address(0));
        pendingEmergencyAmount = 0;

        // Execute withdrawal
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert EmergencyWithdrawalFailed();

        emit EmergencyWithdrawalExecuted(recipient, amount);
    }

    /**
     * @notice Cancel pending emergency withdrawal
     */
    function cancelEmergencyWithdrawal() external onlyRole(ADMIN_ROLE) {
        if (emergencyWithdrawalTimestamp == 0)
            revert NoPendingEmergencyWithdrawal();

        emergencyWithdrawalTimestamp = 0;
        pendingEmergencyRecipient = payable(address(0));
        pendingEmergencyAmount = 0;

        emit EmergencyWithdrawalCancelled();
    }

    // ========== View Functions ==========

    /**
     * @notice Get tokens owned by an address
     * @param _owner Owner address
     * @return Array of token IDs
     */
    function tokensOfOwner(address _owner)
        external
        view
        returns (uint256[] memory)
    {
        uint256 tokenCount = balanceOf(_owner);
        if (tokenCount == 0) {
            return new uint256[](0);
        }

        uint256[] memory tokenIds = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(_owner, i);
        }

        return tokenIds;
    }

    /**
     * @notice Check if address is eligible to vote in governance
     * @param _address Address to check
     * @return true if address has any governance power
     */
    function isVoter(address _address) external view returns (bool) {
        return balanceOf(_address) > 0;
    }

    /**
     * @notice Get token purchase information for multiple tokens
     * @param tokenIds Array of token IDs to query
     * @return prices Array of purchase prices
     * @return paymentTokens Array of payment token addresses
     */
    function getBatchPurchaseInfo(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory prices, address[] memory paymentTokens)
    {
        prices = new uint256[](tokenIds.length);
        paymentTokens = new address[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf(tokenIds[i]) != address(0)) {
                prices[i] = tokenPurchasePrices[tokenIds[i]];
                paymentTokens[i] = tokenPaymentTokens[tokenIds[i]];
            }
        }
    }

    /**
     * @notice Get beneficiary information
     * @return addresses Array of beneficiary addresses
     * @return shares Array of distribution shares for each beneficiary
     * @return received Array of total amounts received by each beneficiary
     * @return pending Array of pending withdrawal amounts for each beneficiary
     * @return claimed Array of total amounts claimed by each beneficiary
     */
    function getBeneficiaryInfo()
        external
        view
        returns (
            address payable[6] memory addresses,
            uint256[6] memory shares,
            uint256[6] memory received,
            uint256[6] memory pending,
            uint256[6] memory claimed
        )
    {
        addresses = [
            developersAddress,
            consultingAddress,
            payrollAddress,
            treasuryAddress,
            marketingAddress,
            operationsAddress
        ];
        shares = [
            DEVELOPERS_SHARE,
            CONSULTING_SHARE,
            PAYROLL_SHARE,
            TREASURY_SHARE,
            MARKETING_SHARE,
            OPERATIONS_SHARE
        ];
        received = [
            beneficiaryReceived[developersAddress],
            beneficiaryReceived[consultingAddress],
            beneficiaryReceived[payrollAddress],
            beneficiaryReceived[treasuryAddress],
            beneficiaryReceived[marketingAddress],
            beneficiaryReceived[operationsAddress]
        ];
        pending = [
            pendingWithdrawals[developersAddress],
            pendingWithdrawals[consultingAddress],
            pendingWithdrawals[payrollAddress],
            pendingWithdrawals[treasuryAddress],
            pendingWithdrawals[marketingAddress],
            pendingWithdrawals[operationsAddress]
        ];
        claimed = [
            beneficiaryClaimed[developersAddress],
            beneficiaryClaimed[consultingAddress],
            beneficiaryClaimed[payrollAddress],
            beneficiaryClaimed[treasuryAddress],
            beneficiaryClaimed[marketingAddress],
            beneficiaryClaimed[operationsAddress]
        ];
    }

    /**
     * @notice Get contract balance information
     */
    function getBalanceInfo()
        external
        view
        returns (
            uint256 contractBalance,
            uint256 pendingWithdrawalsTotal,
            uint256 undistributed,
            uint256 availableForEmergency
        )
    {
        contractBalance = address(this).balance;
        pendingWithdrawalsTotal = totalPendingWithdrawals;
        undistributed = undistributedBalance;
        availableForEmergency = contractBalance > totalPendingWithdrawals
            ? contractBalance - totalPendingWithdrawals
            : 0;
    }

    /**
     * @notice Get minting configuration
     */
    function getMintingConfig()
        external
        view
        returns (
            uint256 currentSupply,
            uint256 maxSupplyLimit,
            uint256 currentPrice,
            bool isPublicMintEnabled,
            uint256 startTime,
            bool isMintingActive
        )
    {
        currentSupply = totalMinted;
        maxSupplyLimit = maxSupply;
        currentPrice = mintPrice;
        isPublicMintEnabled = publicMintEnabled;
        startTime = mintStartTime;
        isMintingActive =
            publicMintEnabled &&
            (mintStartTime == 0 || block.timestamp >= mintStartTime) &&
            totalMinted < maxSupply;
    }

    /**
     * @notice Override supportsInterface
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Fallback function to receive ETH - accumulates for manual distribution
     * @notice ETH sent directly to contract is held until manually distributed
     */
    receive() external payable {
        // Accumulate received ETH for manual distribution
        if (msg.value > 0) {
            undistributedBalance += msg.value;
        }
    }

    /**
     * @dev Reject any other function calls
     */
    fallback() external payable {
        revert OnlyThroughFallback();
    }
}
