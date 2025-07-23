// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

interface IChannelRegistry {
    function canSendMessages(address _user) external view returns (bool);
    function canSendRichContent(address _user) external view returns (bool);
    function getUserTier(address _user) external view returns (uint8);
    function usernameToAddress(string memory _username) external view returns (address);
    function addressToUsername(address _addr) external view returns (string memory);
    function logMessage(address _sender, string memory _recipient, string memory _ipfsHash, bool _isRichContent) external returns (uint256);
}

/**
 * @title DecentralizedMessaging
 * @dev Handles encrypted messaging between registered users with IPFS content support
 * @notice Supports text messages, rich media, encryption, and threading
 */
contract DecentralizedMessaging is Ownable, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    
    IChannelRegistry public immutable registry;
    
    // Message types
    enum MessageType {
        TEXT,           // Basic text message
        IMAGE,          // Images (GIF, JPG, PNG)
        VIDEO,          // MP4 videos
        AUDIO,          // MP3 audio
        DOCUMENT,       // PDF documents
        ENCRYPTED_BUNDLE // Multiple files in encrypted bundle
    }
    
    // Message structure
    struct Message {
        uint256 id;
        address sender;
        address recipient;
        string content;         // Text content or IPFS hash
        MessageType messageType;
        uint256 timestamp;
        uint256 threadId;       // For conversation threading
        bool isEncrypted;
        bool isRead;
        bool isDeleted;
        uint256 expiresAt;     // 0 for no expiration
        uint256 replyToId;     // 0 if not a reply
    }
    
    // Thread structure for conversations
    struct Thread {
        uint256 id;
        address participant1;
        address participant2;
        uint256 lastMessageTime;
        uint256 messageCount;
        uint256 unreadCount1;   // Unread count for participant1
        uint256 unreadCount2;   // Unread count for participant2
        bool isActive;
        bool isMuted1;          // Muted by participant1
        bool isMuted2;          // Muted by participant2
    }
    
    // Encryption key structure
    struct EncryptionKey {
        string publicKey;       // User's public encryption key
        uint256 updatedAt;
        bool isActive;
    }
    
    // Rate limiting
    struct RateLimit {
        uint256 messageCount;
        uint256 windowStart;
    }
    
    // Constants
    uint256 public constant RATE_LIMIT_WINDOW = 1 hours;
    uint256 public constant MAX_MESSAGES_PER_WINDOW_BASIC = 100;
    uint256 public constant MAX_MESSAGES_PER_WINDOW_PREMIUM = 1000;
    uint256 public constant MAX_MESSAGE_SIZE = 1024; // Max text message size
    uint256 public constant MAX_IPFS_HASH_LENGTH = 64;
    uint256 public constant CLEANUP_REWARD = 0.001 ether; // Reward for cleaning expired messages
    
    // Storage
    Counters.Counter private _messageIdCounter;
    Counters.Counter private _threadIdCounter;
    
    mapping(uint256 => Message) public messages;
    mapping(uint256 => Thread) public threads;
    mapping(address => mapping(address => uint256)) public userThreads; // user1 => user2 => threadId
    mapping(address => uint256[]) public userMessages; // user => messageIds
    mapping(address => uint256[]) public userInbox; // recipient => messageIds
    mapping(address => EncryptionKey) public encryptionKeys;
    mapping(address => RateLimit) public rateLimits;
    mapping(address => mapping(address => bool)) public blockedUsers; // blocker => blocked => bool
    mapping(uint256 => uint256[]) public threadMessages; // threadId => messageIds
    mapping(address => uint256) public unreadCount; // Total unread messages per user
    
    // Statistics
    uint256 public totalMessages;
    uint256 public totalRichMessages;
    uint256 public totalThreads;
    uint256 public totalActiveUsers;
    uint256 public totalExpiredMessages;
    mapping(address => uint256) public lastActiveTime;
    mapping(MessageType => uint256) public messageTypeCount;
    
    // Events
    event MessageSent(
        uint256 indexed messageId,
        address indexed sender,
        address indexed recipient,
        uint256 threadId,
        MessageType messageType,
        bool isEncrypted,
        uint256 replyToId
    );
    
    event MessageRead(
        uint256 indexed messageId,
        address indexed reader,
        uint256 timestamp
    );
    
    event MessageDeleted(
        uint256 indexed messageId,
        address indexed deleter,
        string reason
    );
    
    event MessageExpired(
        uint256 indexed messageId,
        address indexed cleaner,
        uint256 reward
    );
    
    event ThreadCreated(
        uint256 indexed threadId,
        address indexed participant1,
        address indexed participant2
    );
    
    event ThreadMuted(
        uint256 indexed threadId,
        address indexed muter,
        bool isMuted
    );
    
    event EncryptionKeyUpdated(
        address indexed user,
        string publicKey
    );
    
    event UserBlocked(
        address indexed blocker,
        address indexed blocked,
        uint256 timestamp
    );
    
    event UserUnblocked(
        address indexed unblocker,
        address indexed unblocked,
        uint256 timestamp
    );
    
    modifier onlyRegistered() {
        require(registry.canSendMessages(msg.sender), "Not registered or cannot send messages");
        _;
    }
    
    modifier onlyPremium() {
        require(registry.canSendRichContent(msg.sender), "Premium features required");
        _;
    }
    
    modifier rateLimited() {
        _checkRateLimit();
        _;
    }
    
    modifier validMessage(uint256 _messageId) {
        require(_messageId > 0 && _messageId <= _messageIdCounter.current(), "Invalid message ID");
        require(!messages[_messageId].isDeleted, "Message deleted");
        _;
    }
    
    /**
     * @dev Constructor
     * @param _registry Address of the channel registry contract
     * @param _initialOwner Address of the contract owner
     */
    constructor(address _registry, address _initialOwner) Ownable(_initialOwner) {
        require(_registry != address(0), "Invalid registry address");
        registry = IChannelRegistry(_registry);
    }
    
    /**
     * @dev Send a text message to another user
     * @param _recipient Username of recipient
     * @param _content Text content
     * @param _isEncrypted Whether content is encrypted
     * @param _replyToId Message ID being replied to (0 if not a reply)
     */
    function sendTextMessage(
        string memory _recipient,
        string memory _content,
        bool _isEncrypted,
        uint256 _replyToId
    ) external onlyRegistered rateLimited nonReentrant whenNotPaused returns (uint256) {
        require(bytes(_content).length > 0, "Empty content");
        require(bytes(_content).length <= MAX_MESSAGE_SIZE, "Content too large");
        
        address recipientAddr = registry.usernameToAddress(_recipient);
        require(recipientAddr != address(0), "Recipient not found");
        require(recipientAddr != msg.sender, "Cannot message yourself");
        require(!blockedUsers[recipientAddr][msg.sender], "You are blocked by recipient");
        
        // Validate reply
        if (_replyToId > 0) {
            require(_replyToId <= _messageIdCounter.current(), "Invalid reply message");
            Message memory replyTo = messages[_replyToId];
            require(
                replyTo.sender == recipientAddr || replyTo.recipient == recipientAddr ||
                replyTo.sender == msg.sender || replyTo.recipient == msg.sender,
                "Cannot reply to this message"
            );
        }
        
        uint256 threadId = _getOrCreateThread(msg.sender, recipientAddr);
        uint256 messageId = _createMessage(
            msg.sender,
            recipientAddr,
            _content,
            MessageType.TEXT,
            threadId,
            _isEncrypted,
            0, // No expiration for text
            _replyToId
        );
        
        // Update unread count
        unreadCount[recipientAddr]++;
        _updateThreadUnreadCount(threadId, recipientAddr, true);
        
        // Log in registry
        registry.logMessage(msg.sender, _recipient, "", false);
        
        totalMessages++;
        messageTypeCount[MessageType.TEXT]++;
        _updateActivity(msg.sender);
        
        emit MessageSent(
            messageId,
            msg.sender,
            recipientAddr,
            threadId,
            MessageType.TEXT,
            _isEncrypted,
            _replyToId
        );
        
        return messageId;
    }
    
    /**
     * @dev Send rich content message (Premium users only)
     * @param _recipient Username of recipient
     * @param _ipfsHash IPFS hash of encrypted content
     * @param _messageType Type of content
     * @param _textPreview Optional text preview
     * @param _expiresIn Expiration time in seconds (0 for no expiration)
     * @param _replyToId Message ID being replied to (0 if not a reply)
     */
    function sendRichMessage(
        string memory _recipient,
        string memory _ipfsHash,
        MessageType _messageType,
        string memory _textPreview,
        uint256 _expiresIn,
        uint256 _replyToId
    ) external onlyPremium rateLimited nonReentrant whenNotPaused returns (uint256) {
        require(bytes(_ipfsHash).length > 0, "Empty IPFS hash");
        require(bytes(_ipfsHash).length <= MAX_IPFS_HASH_LENGTH, "Invalid IPFS hash");
        require(_messageType != MessageType.TEXT, "Use sendTextMessage for text");
        require(_expiresIn == 0 || _expiresIn >= 300, "Minimum expiration is 5 minutes");
        
        address recipientAddr = registry.usernameToAddress(_recipient);
        require(recipientAddr != address(0), "Recipient not found");
        require(recipientAddr != msg.sender, "Cannot message yourself");
        require(!blockedUsers[recipientAddr][msg.sender], "You are blocked by recipient");
        
        // Validate reply
        if (_replyToId > 0) {
            require(_replyToId <= _messageIdCounter.current(), "Invalid reply message");
            Message memory replyTo = messages[_replyToId];
            require(
                replyTo.sender == recipientAddr || replyTo.recipient == recipientAddr ||
                replyTo.sender == msg.sender || replyTo.recipient == msg.sender,
                "Cannot reply to this message"
            );
        }
        
        uint256 threadId = _getOrCreateThread(msg.sender, recipientAddr);
        uint256 expiresAt = _expiresIn > 0 ? block.timestamp + _expiresIn : 0;
        
        // Store IPFS hash as content with optional preview
        string memory content = bytes(_textPreview).length > 0 
            ? string(abi.encodePacked(_ipfsHash, "|", _textPreview))
            : _ipfsHash;
            
        uint256 messageId = _createMessage(
            msg.sender,
            recipientAddr,
            content,
            _messageType,
            threadId,
            true, // Rich content is always encrypted
            expiresAt,
            _replyToId
        );
        
        // Update unread count
        unreadCount[recipientAddr]++;
        _updateThreadUnreadCount(threadId, recipientAddr, true);
        
        // Log in registry
        registry.logMessage(msg.sender, _recipient, _ipfsHash, true);
        
        totalMessages++;
        totalRichMessages++;
        messageTypeCount[_messageType]++;
        _updateActivity(msg.sender);
        
        emit MessageSent(
            messageId,
            msg.sender,
            recipientAddr,
            threadId,
            _messageType,
            true,
            _replyToId
        );
        
        return messageId;
    }
    
    /**
     * @dev Mark message as read
     * @param _messageId Message ID to mark as read
     */
    function markAsRead(uint256 _messageId) external validMessage(_messageId) {
        Message storage message = messages[_messageId];
        require(message.recipient == msg.sender, "Not the recipient");
        require(!message.isRead, "Already read");
        
        // Check expiration
        if (message.expiresAt > 0 && block.timestamp > message.expiresAt) {
            revert("Message has expired");
        }
        
        message.isRead = true;
        
        // Update unread counts
        if (unreadCount[msg.sender] > 0) {
            unreadCount[msg.sender]--;
        }
        _updateThreadUnreadCount(message.threadId, msg.sender, false);
        
        emit MessageRead(_messageId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Mark all messages in a thread as read
     * @param _threadId Thread ID
     */
    function markThreadAsRead(uint256 _threadId) external {
        Thread storage thread = threads[_threadId];
        require(
            thread.participant1 == msg.sender || thread.participant2 == msg.sender,
            "Not a participant"
        );
        
        uint256[] memory messageIds = threadMessages[_threadId];
        uint256 markedCount = 0;
        
        for (uint256 i = 0; i < messageIds.length; i++) {
            Message storage message = messages[messageIds[i]];
            if (message.recipient == msg.sender && !message.isRead && !message.isDeleted) {
                if (message.expiresAt == 0 || block.timestamp <= message.expiresAt) {
                    message.isRead = true;
                    markedCount++;
                    emit MessageRead(messageIds[i], msg.sender, block.timestamp);
                }
            }
        }
        
        // Update unread counts
        if (markedCount > 0) {
            if (unreadCount[msg.sender] >= markedCount) {
                unreadCount[msg.sender] -= markedCount;
            } else {
                unreadCount[msg.sender] = 0;
            }
            
            // Reset thread unread count
            if (thread.participant1 == msg.sender) {
                thread.unreadCount1 = 0;
            } else {
                thread.unreadCount2 = 0;
            }
        }
    }
    
    /**
     * @dev Delete a message (sender or recipient)
     * @param _messageId Message ID to delete
     * @param _reason Reason for deletion
     */
    function deleteMessage(uint256 _messageId, string memory _reason) external validMessage(_messageId) {
        Message storage message = messages[_messageId];
        require(
            message.sender == msg.sender || message.recipient == msg.sender,
            "Not authorized to delete"
        );
        
        // Update unread count if message was unread
        if (!message.isRead && message.recipient == msg.sender && unreadCount[msg.sender] > 0) {
            unreadCount[msg.sender]--;
            _updateThreadUnreadCount(message.threadId, msg.sender, false);
        }
        
        message.isDeleted = true;
        emit MessageDeleted(_messageId, msg.sender, _reason);
    }
    
    /**
     * @dev Clean up expired messages and earn rewards
     * @param _messageIds Array of message IDs to check
     */
    function cleanupExpiredMessages(uint256[] memory _messageIds) external nonReentrant {
        uint256 cleanedCount = 0;
        
        for (uint256 i = 0; i < _messageIds.length; i++) {
            uint256 messageId = _messageIds[i];
            if (messageId == 0 || messageId > _messageIdCounter.current()) continue;
            
            Message storage message = messages[messageId];
            
            // Check if message is expired and not already deleted
            if (!message.isDeleted && 
                message.expiresAt > 0 && 
                block.timestamp > message.expiresAt) {
                
                // Update unread count if necessary
                if (!message.isRead && unreadCount[message.recipient] > 0) {
                    unreadCount[message.recipient]--;
                    _updateThreadUnreadCount(message.threadId, message.recipient, false);
                }
                
                message.isDeleted = true;
                cleanedCount++;
                totalExpiredMessages++;
                
                emit MessageExpired(messageId, msg.sender, CLEANUP_REWARD);
            }
        }
        
        // Pay cleanup reward
        if (cleanedCount > 0 && address(this).balance >= CLEANUP_REWARD * cleanedCount) {
            payable(msg.sender).transfer(CLEANUP_REWARD * cleanedCount);
        }
    }
    
    /**
     * @dev Mute or unmute a thread
     * @param _threadId Thread ID to mute/unmute
     * @param _mute True to mute, false to unmute
     */
    function muteThread(uint256 _threadId, bool _mute) external {
        Thread storage thread = threads[_threadId];
        require(
            thread.participant1 == msg.sender || thread.participant2 == msg.sender,
            "Not a participant"
        );
        
        if (thread.participant1 == msg.sender) {
            thread.isMuted1 = _mute;
        } else {
            thread.isMuted2 = _mute;
        }
        
        emit ThreadMuted(_threadId, msg.sender, _mute);
    }
    
    /**
     * @dev Update user's encryption public key
     * @param _publicKey New public key for encryption
     */
    function updateEncryptionKey(string memory _publicKey) external onlyRegistered {
        require(bytes(_publicKey).length > 0, "Empty key");
        require(bytes(_publicKey).length <= 256, "Key too long");
        
        encryptionKeys[msg.sender] = EncryptionKey({
            publicKey: _publicKey,
            updatedAt: block.timestamp,
            isActive: true
        });
        
        emit EncryptionKeyUpdated(msg.sender, _publicKey);
    }
    
    /**
     * @dev Block a user from messaging you
     * @param _username Username to block
     */
    function blockUser(string memory _username) external onlyRegistered {
        address userToBlock = registry.usernameToAddress(_username);
        require(userToBlock != address(0), "User not found");
        require(userToBlock != msg.sender, "Cannot block yourself");
        require(!blockedUsers[msg.sender][userToBlock], "Already blocked");
        
        blockedUsers[msg.sender][userToBlock] = true;
        emit UserBlocked(msg.sender, userToBlock, block.timestamp);
    }
    
    /**
     * @dev Unblock a user
     * @param _username Username to unblock
     */
    function unblockUser(string memory _username) external onlyRegistered {
        address userToUnblock = registry.usernameToAddress(_username);
        require(userToUnblock != address(0), "User not found");
        require(blockedUsers[msg.sender][userToUnblock], "Not blocked");
        
        blockedUsers[msg.sender][userToUnblock] = false;
        emit UserUnblocked(msg.sender, userToUnblock, block.timestamp);
    }
    
    /**
     * @dev Get messages in a thread
     * @param _threadId Thread ID
     * @param _offset Starting index
     * @param _limit Number of messages to return
     */
    function getThreadMessages(
        uint256 _threadId,
        uint256 _offset,
        uint256 _limit
    ) external view returns (Message[] memory) {
        Thread memory thread = threads[_threadId];
        require(
            thread.participant1 == msg.sender || thread.participant2 == msg.sender,
            "Not a participant"
        );
        require(_limit > 0 && _limit <= 50, "Invalid limit");
        
        uint256[] memory messageIds = threadMessages[_threadId];
        uint256 totalThreadMessages = messageIds.length;
        
        if (_offset >= totalThreadMessages) {
            return new Message[](0);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalThreadMessages) {
            end = totalThreadMessages;
        }
        
        Message[] memory result = new Message[](end - _offset);
        uint256 resultIndex = 0;
        
        // Return newest first
        for (uint256 i = totalThreadMessages - _offset - 1; i >= totalThreadMessages - end; i--) {
            Message memory message = messages[messageIds[i]];
            if (!message.isDeleted && (message.expiresAt == 0 || block.timestamp <= message.expiresAt)) {
                result[resultIndex] = message;
                resultIndex++;
            }
            if (i == 0) break; // Prevent underflow
        }
        
        // Resize array to actual size
        assembly {
            mstore(result, resultIndex)
        }
        
        return result;
    }
    
    /**
     * @dev Get user's inbox (received messages)
     * @param _offset Starting index
     * @param _limit Number of messages to return
     * @param _unreadOnly Return only unread messages
     */
    function getInbox(
        uint256 _offset,
        uint256 _limit,
        bool _unreadOnly
    ) external view returns (Message[] memory) {
        require(_limit > 0 && _limit <= 50, "Invalid limit");
        
        uint256[] memory messageIds = userInbox[msg.sender];
        uint256 totalInboxMessages = messageIds.length;
        
        if (_offset >= totalInboxMessages) {
            return new Message[](0);
        }
        
        uint256 end = _offset + _limit;
        if (end > totalInboxMessages) {
            end = totalInboxMessages;
        }
        
        Message[] memory result = new Message[](end - _offset);
        uint256 resultIndex = 0;
        
        // Return newest first
        for (uint256 i = totalInboxMessages - _offset - 1; i >= totalInboxMessages - end; i--) {
            Message memory message = messages[messageIds[i]];
            
            // Apply filters
            bool includeMessage = !message.isDeleted && 
                (message.expiresAt == 0 || block.timestamp <= message.expiresAt);
                
            if (_unreadOnly) {
                includeMessage = includeMessage && !message.isRead;
            }
            
            if (includeMessage) {
                result[resultIndex] = message;
                resultIndex++;
            }
            
            if (i == 0) break; // Prevent underflow
        }
        
        // Resize array to actual size
        assembly {
            mstore(result, resultIndex)
        }
        
        return result;
    }
    
    /**
     * @dev Get user's active threads with details
     * @param _offset Starting index
     * @param _limit Number of threads to return
     */
    function getUserThreadsDetailed(
        uint256 _offset,
        uint256 _limit
    ) external view returns (
        Thread[] memory threadList,
        address[] memory otherParticipants,
        string[] memory otherUsernames,
        uint256 totalCount
    ) {
        require(_limit > 0 && _limit <= 50, "Invalid limit");
        
        // Count user's threads
        uint256 count = 0;
        for (uint256 i = 1; i <= _threadIdCounter.current(); i++) {
            Thread memory thread = threads[i];
            if ((thread.participant1 == msg.sender || thread.participant2 == msg.sender) && thread.isActive) {
                count++;
            }
        }
        
        totalCount = count;
        
        if (_offset >= count) {
            return (new Thread[](0), new address[](0), new string[](0), totalCount);
        }
        
        uint256 end = _offset + _limit;
        if (end > count) {
            end = count;
        }
        
        uint256 resultSize = end - _offset;
        threadList = new Thread[](resultSize);
        otherParticipants = new address[](resultSize);
        otherUsernames = new string[](resultSize);
        
        uint256 currentIndex = 0;
        uint256 resultIndex = 0;
        
        // Collect threads (newest activity first)
        for (uint256 i = _threadIdCounter.current(); i >= 1 && resultIndex < resultSize; i--) {
            Thread memory thread = threads[i];
            if ((thread.participant1 == msg.sender || thread.participant2 == msg.sender) && thread.isActive) {
                if (currentIndex >= _offset) {
                    threadList[resultIndex] = thread;
                    
                    // Get other participant
                    address otherParticipant = thread.participant1 == msg.sender 
                        ? thread.participant2 
                        : thread.participant1;
                    
                    otherParticipants[resultIndex] = otherParticipant;
                    otherUsernames[resultIndex] = registry.addressToUsername(otherParticipant);
                    
                    resultIndex++;
                }
                currentIndex++;
            }
            if (i == 0) break; // Prevent underflow
        }
        
        return (threadList, otherParticipants, otherUsernames, totalCount);
    }
    
    /**
     * @dev Get message statistics
     */
    function getMessageStats() external view returns (
        uint256 total,
        uint256 textMessages,
        uint256 richMessages,
        uint256 activeUsers,
        uint256 activeThreads,
        uint256 expiredMessages
    ) {
        return (
            totalMessages,
            messageTypeCount[MessageType.TEXT],
            totalRichMessages,
            totalActiveUsers,
            totalThreads,
            totalExpiredMessages
        );
    }
    
    /**
     * @dev Get encryption key for a user
     */
    function getEncryptionKey(address _user) external view returns (
        string memory publicKey,
        uint256 updatedAt,
        bool isActive
    ) {
        EncryptionKey memory key = encryptionKeys[_user];
        return (key.publicKey, key.updatedAt, key.isActive);
    }
    
    /**
     * @dev Get or create thread between two users
     */
    function _getOrCreateThread(address _user1, address _user2) private returns (uint256) {
        // Ensure consistent ordering
        address participant1 = _user1 < _user2 ? _user1 : _user2;
        address participant2 = _user1 < _user2 ? _user2 : _user1;
        
        uint256 existingThreadId = userThreads[participant1][participant2];
        
        if (existingThreadId > 0) {
            Thread storage thread = threads[existingThreadId];
            thread.lastMessageTime = block.timestamp;
            thread.messageCount++;
            return existingThreadId;
        }
        
        // Create new thread
        _threadIdCounter.increment();
        uint256 newThreadId = _threadIdCounter.current();
        
        threads[newThreadId] = Thread({
            id: newThreadId,
            participant1: participant1,
            participant2: participant2,
            lastMessageTime: block.timestamp,
            messageCount: 1,
            unreadCount1: 0,
            unreadCount2: 0,
            isActive: true,
            isMuted1: false,
            isMuted2: false
        });
        
        userThreads[participant1][participant2] = newThreadId;
        totalThreads++;
        
        emit ThreadCreated(newThreadId, participant1, participant2);
        
        return newThreadId;
    }
    
    /**
     * @dev Create a message
     */
    function _createMessage(
        address _sender,
        address _recipient,
        string memory _content,
        MessageType _messageType,
        uint256 _threadId,
        bool _isEncrypted,
        uint256 _expiresAt,
        uint256 _replyToId
    ) private returns (uint256) {
        _messageIdCounter.increment();
        uint256 messageId = _messageIdCounter.current();
        
        messages[messageId] = Message({
            id: messageId,
            sender: _sender,
            recipient: _recipient,
            content: _content,
            messageType: _messageType,
            timestamp: block.timestamp,
            threadId: _threadId,
            isEncrypted: _isEncrypted,
            isRead: false,
            isDeleted: false,
            expiresAt: _expiresAt,
            replyToId: _replyToId
        });
        
        userMessages[_sender].push(messageId);
        userInbox[_recipient].push(messageId);
        threadMessages[_threadId].push(messageId);
        
        return messageId;
    }
    
    /**
     * @dev Update thread unread count
     */
    function _updateThreadUnreadCount(uint256 _threadId, address _recipient, bool _increment) private {
        Thread storage thread = threads[_threadId];
        
        if (thread.participant1 == _recipient) {
            if (_increment) {
                thread.unreadCount1++;
            } else if (thread.unreadCount1 > 0) {
                thread.unreadCount1--;
            }
        } else if (thread.participant2 == _recipient) {
            if (_increment) {
                thread.unreadCount2++;
            } else if (thread.unreadCount2 > 0) {
                thread.unreadCount2--;
            }
        }
    }
    
    /**
     * @dev Check and update rate limit
     */
    function _checkRateLimit() private {
        RateLimit storage limit = rateLimits[msg.sender];
        
        // Reset window if needed
        if (block.timestamp >= limit.windowStart + RATE_LIMIT_WINDOW) {
            limit.messageCount = 0;
            limit.windowStart = block.timestamp;
        }
        
        uint256 maxMessages = registry.canSendRichContent(msg.sender)
            ? MAX_MESSAGES_PER_WINDOW_PREMIUM
            : MAX_MESSAGES_PER_WINDOW_BASIC;
            
        require(limit.messageCount < maxMessages, "Rate limit exceeded");
        limit.messageCount++;
    }
    
    /**
     * @dev Update user activity
     */
    function _updateActivity(address _user) private {
        if (lastActiveTime[_user] == 0) {
            totalActiveUsers++;
        }
        lastActiveTime[_user] = block.timestamp;
    }
    
    /**
     * @dev Admin functions
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Fund contract for cleanup rewards
     */
    receive() external payable {}
    
    /**
     * @dev Withdraw excess funds (owner only)
     */
    function withdrawExcessFunds(uint256 _amount) external onlyOwner {
        require(address(this).balance >= _amount, "Insufficient balance");
        payable(owner()).transfer(_amount);
    }
}
