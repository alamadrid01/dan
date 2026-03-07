// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "hardhat/console.sol";

contract DANCore is ReentrancyGuard {
    uint256 public constant GRANULAR_SCALAR = 1e16;
    uint256 public constant MIN_DEPOSIT = 0.5 ether;
    uint256 public constant MIN_REWARD = 0.05 ether;
    uint256 public constant MIN_WITHDRAWAL = 0.5 ether;
    uint256 public constant COOLDOWN_PERIOD = 24 hours;
    uint256 public constant USER_SHARE_BPS = 7000;
    uint256 public constant PUBLISHER_SHARE_BPS = 2000;
    uint256 public constant TREASURY_SHARE_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;

    address public owner;
    address public verifier;
    address public treasury;

    uint256 public questCounter;

    enum QuestType {
        CONNECT_WALLET,
        FIRST_TRANSACTION,
        FIRST_SWAP,
        MINT_NFT,
        TIME_ON_APP
    }

    enum QuestStatus {
        ACTIVE,
        PAUSED,
        ENDED,
        EXHAUSTED
    }

    enum CampaignType {
        PUBLIC,
        PRIVATE
    }

    struct Quest {
        uint256 id;
        address advertiser;
        string appName;
        string appDescription;
        string appUrl;
        string imageUrl;
        QuestType questType;
        address targetContract;
        uint256 rewardPerUser;
        uint256 totalBudget;
        uint256 remainingBudget;
        uint256 dailyCap;
        uint256 dailySpent;
        uint256 lastDayReset;
        uint256 maxCompletions;
        uint256 completionCount;
        uint256 startTime;
        uint256 endTime;
        uint256 endedAt;
        QuestStatus status;
        bytes32 publisherKeyHash;
        CampaignType campaignType;
    }

    struct UserProfile {
        bool registered;
        uint256 pendingBalance;
        uint256 totalEarned;
        uint256 completionCount;
    }

    struct Publisher {
        bool registered;
        bytes32 publisherKeyHash;
        string publisherKey;
        address wallet;
        uint256 pendingBalance;
        uint256 totalEarned;
    }

    mapping(uint256 => Quest) public quests;

    mapping(address => UserProfile) public users;

    mapping(bytes32 => Publisher) public publishersByHash;

    mapping(address => bytes32) public publisherKeyHashByWallet;

    mapping(uint256 => mapping(address => bool)) public hasCompleted;

    uint256 public treasuryBalance;

    error NonGranularWei(string field, uint256 value, uint256 scalar);

    event QuestCreated(
        uint256 indexed questId,
        address indexed advertiser,
        string appName,
        QuestType questType,
        uint256 rewardPerUser,
        uint256 totalBudget
    );

    event QuestCompleted(
        uint256 indexed questId,
        address indexed user,
        uint256 userReward,
        uint256 publisherReward,
        uint256 treasuryFee,
        string publisherKey
    );

    event UserRegistered(address indexed user);

    event UserWithdrawal(address indexed user, uint256 amount);

    event PublisherRegistered(string publisherKey, address indexed wallet);

    event PublisherWithdrawal(
        string publisherKey,
        address indexed wallet,
        uint256 amount
    );

    event CampaignEnded(uint256 indexed questId, QuestStatus reason);

    event AdvertiserRefund(
        uint256 indexed questId,
        address indexed advertiser,
        uint256 amount
    );

    event QuestPaused(uint256 indexed questId);

    event QuestResumed(uint256 indexed questId);

    event TreasuryWithdrawal(address indexed treasury, uint256 amount);

    event VerifierUpdated(
        address indexed oldVerifier,
        address indexed newVerifier
    );

    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "DAN: Not owner");
        _;
    }

    modifier onlyVerifier() {
        require(msg.sender == verifier, "DAN: Not verifier");
        _;
    }

    modifier questExists(uint256 _questId) {
        require(
            _questId > 0 && _questId <= questCounter,
            "DAN: Quest does not exist"
        );
        _;
    }

    modifier onlyRegisteredUser() {
        require(users[msg.sender].registered, "DAN: Register first");
        _;
    }

    constructor(address _verifier, address _treasury) {
        require(_verifier != address(0), "DAN: Invalid verifier");
        require(_treasury != address(0), "DAN: Invalid treasury");
        owner = msg.sender;
        verifier = _verifier;
        treasury = _treasury;
    }

    /// @notice Register as a DAN user to participate in quests and earn rewards
    function registerUser() external {
        require(!users[msg.sender].registered, "DAN: Already registered");
        users[msg.sender].registered = true;
        emit UserRegistered(msg.sender);
    }

    /// @notice Register as a publisher to earn revenue share
    /// @param _publisherKey Unique string key for this publisher (e.g. "arena", "myapp")
    function registerPublisher(string calldata _publisherKey) external {
        _validatePublisherKey(_publisherKey);
        bytes32 publisherKeyHash = _publisherKeyHash(_publisherKey);

        require(
            !publishersByHash[publisherKeyHash].registered,
            "DAN: Key already taken"
        );
        require(
            publisherKeyHashByWallet[msg.sender] == bytes32(0),
            "DAN: Wallet already registered"
        );

        publishersByHash[publisherKeyHash] = Publisher({
            registered: true,
            publisherKeyHash: publisherKeyHash,
            publisherKey: _publisherKey,
            wallet: msg.sender,
            pendingBalance: 0,
            totalEarned: 0
        });

        publisherKeyHashByWallet[msg.sender] = publisherKeyHash;

        emit PublisherRegistered(_publisherKey, msg.sender);
    }

    /// @notice Advertiser creates and funds a new discovery quest
    /// @param _appName         Name of the application being promoted
    /// @param _appDescription  Short description shown on the Discovery Card
    /// @param _appUrl          URL of the application
    /// @param _imageUrl        Image/logo URL for the Discovery Card
    /// @param _questType       Type of task the user must complete
    /// @param _targetContract  The advertiser's app contract address (used for backend verification)
    /// @param _rewardPerUser   AVAX amount per completion (full amount before split)
    /// @param _dailyCap        Max AVAX to spend per day (0 = no daily cap)
    /// @param _maxCompletions  Max number of users (0 = unlimited)
    /// @param _durationDays    Campaign duration in days (0 = no end date)
    /// @param _publisherKey    Publisher key if created through a publisher's platform (empty = direct)
    function createQuest(
        string calldata _appName,
        string calldata _appDescription,
        string calldata _appUrl,
        string calldata _imageUrl,
        QuestType _questType,
        address _targetContract,
        uint256 _rewardPerUser,
        uint256 _dailyCap,
        uint256 _maxCompletions,
        uint256 _durationDays,
        string calldata _publisherKey,
        CampaignType _campaignType
    ) external payable {
        _requireGranularWei(_rewardPerUser, "rewardPerUser");
        _requireGranularWei(msg.value, "totalBudget(avax)");


        require(msg.value >= MIN_DEPOSIT, "DAN: Avax passed into the contract is below minimum deposit");
        require(_dailyCap == 0 || _dailyCap >= MIN_DEPOSIT, "DAN: Daily cap must be 0 or above minimum deposit");
        require(_rewardPerUser >= MIN_REWARD, "DAN: Reward too low");
        require(_rewardPerUser <= msg.value, "DAN: Reward exceeds budget");
        require(bytes(_appName).length > 0, "DAN: App name required");
        require(_targetContract != address(0), "DAN: Target contract required");

        bytes32 questPublisherKeyHash = bytes32(0);
        if (bytes(_publisherKey).length > 0) {
            _validatePublisherKey(_publisherKey);
            questPublisherKeyHash = _publisherKeyHash(_publisherKey);
            require(
                publishersByHash[questPublisherKeyHash].registered,
                "DAN: Unknown publisher key"
            );
        }

        if (_dailyCap > 0) {
            require(_dailyCap >= _rewardPerUser, "DAN: Daily cap too low");
        }

        questCounter++;

        uint256 endTime = _durationDays > 0
            ? block.timestamp + (_durationDays * 1 days)
            : 0;

        quests[questCounter] = Quest({
            id: questCounter,
            advertiser: msg.sender,
            appName: _appName,
            appDescription: _appDescription,
            appUrl: _appUrl,
            imageUrl: _imageUrl,
            questType: _questType,
            targetContract: _targetContract,
            rewardPerUser: _rewardPerUser,
            totalBudget: msg.value,
            remainingBudget: msg.value,
            dailyCap: _dailyCap,
            dailySpent: 0,
            lastDayReset: block.timestamp,
            maxCompletions: _maxCompletions,
            completionCount: 0,
            startTime: block.timestamp,
            endTime: endTime,
            endedAt: 0,
            status: QuestStatus.ACTIVE,
            publisherKeyHash: questPublisherKeyHash,
            campaignType: _campaignType
        });

        emit QuestCreated(
            questCounter,
            msg.sender,
            _appName,
            _questType,
            _rewardPerUser,
            msg.value
        );
    }

    /// @notice Called by the backend verifier after confirming task completion
    /// @param _questId     The quest the user completed
    /// @param _user        The user's wallet address
    /// @param _publisherKey Publisher key to attribute revenue share (empty = no publisher)
    function completeQuest(
        uint256 _questId,
        address _user,
        string calldata _publisherKey
    ) external onlyVerifier questExists(_questId) {
        Quest storage quest = quests[_questId];

        require(_user != address(0), "DAN: Invalid user");
        require(quest.status == QuestStatus.ACTIVE, "DAN: Quest not active");

        if (!users[_user].registered) {
            users[_user].registered = true;
            emit UserRegistered(_user);
        }

        require(!hasCompleted[_questId][_user], "DAN: Already completed");
        require(
            quest.remainingBudget >= quest.rewardPerUser,
            "DAN: Insufficient budget"
        );

        if (quest.endTime > 0) {
            require(block.timestamp <= quest.endTime, "DAN: Quest expired");
        }

        if (quest.maxCompletions > 0) {
            require(
                quest.completionCount < quest.maxCompletions,
                "DAN: Max completions reached"
            );
        }

        if (block.timestamp >= quest.lastDayReset + 1 days) {
            quest.dailySpent = 0;
            quest.lastDayReset = block.timestamp;
        }

        if (quest.dailyCap > 0) {
            require(
                quest.dailySpent + quest.rewardPerUser <= quest.dailyCap,
                "DAN: Daily cap reached"
            );
        }

        uint256 reward = quest.rewardPerUser;
        uint256 userAmount = (reward * USER_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 publisherAmount = 0;
        uint256 treasuryAmount = 0;

        bytes32 effectivePublisherKeyHash = bytes32(0);
        if (bytes(_publisherKey).length > 0) {
            _validatePublisherKey(_publisherKey);
            effectivePublisherKeyHash = _publisherKeyHash(_publisherKey);
        } else {
            effectivePublisherKeyHash = quest.publisherKeyHash;
        }

        bool hasPublisher = effectivePublisherKeyHash != bytes32(0) &&
            publishersByHash[effectivePublisherKeyHash].registered;

        string memory effectivePublisherKey = "";
        if (hasPublisher) {
            effectivePublisherKey =
                publishersByHash[effectivePublisherKeyHash].publisherKey;
        }

        if (hasPublisher) {
            publisherAmount =
                (reward * PUBLISHER_SHARE_BPS) /
                BPS_DENOMINATOR;
            treasuryAmount = reward - userAmount - publisherAmount;
        } else {
            treasuryAmount = reward - userAmount;
        }

        hasCompleted[_questId][_user] = true;
        quest.remainingBudget -= reward;
        quest.completionCount++;
        quest.dailySpent += reward;

        users[_user].pendingBalance += userAmount;
        users[_user].totalEarned += userAmount;
        users[_user].completionCount++;

        if (hasPublisher) {
            publishersByHash[effectivePublisherKeyHash]
                .pendingBalance += publisherAmount;
            publishersByHash[effectivePublisherKeyHash]
                .totalEarned += publisherAmount;
        }

        treasuryBalance += treasuryAmount;

        emit QuestCompleted(
            _questId,
            _user,
            userAmount,
            publisherAmount,
            treasuryAmount,
            effectivePublisherKey
        );

        if (quest.remainingBudget < quest.rewardPerUser) {
            _endQuest(_questId, QuestStatus.EXHAUSTED);
        }
    }

    /// @notice User withdraws their accumulated AVAX earnings
    function withdrawUserBalance() external onlyRegisteredUser nonReentrant {
        uint256 balance = users[msg.sender].pendingBalance;

        require(
            balance >= MIN_WITHDRAWAL,
            "DAN: Below minimum withdrawal threshold"
        );

        users[msg.sender].pendingBalance = 0;

        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "DAN: Withdrawal transfer failed");

        emit UserWithdrawal(msg.sender, balance);
    }

    /// @notice Publisher withdraws their accumulated revenue share
    function withdrawPublisherBalance() external nonReentrant {
        bytes32 keyHash = publisherKeyHashByWallet[msg.sender];
        require(keyHash != bytes32(0), "DAN: Not a registered publisher");

        Publisher storage pub = publishersByHash[keyHash];
        uint256 balance = pub.pendingBalance;

        require(balance > 0, "DAN: No publisher balance");

        pub.pendingBalance = 0;

        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "DAN: Publisher withdrawal failed");

        emit PublisherWithdrawal(pub.publisherKey, msg.sender, balance);
    }

    /// @notice Advertiser withdraws unspent budget after campaign ends (24hr cooldown)
    /// @param _questId The campaign to refund from
    function withdrawUnspentBudget(
        uint256 _questId
    ) external questExists(_questId) nonReentrant {
        Quest storage quest = quests[_questId];

        require(quest.advertiser == msg.sender, "DAN: Not campaign advertiser");
        require(
            quest.status == QuestStatus.ENDED ||
                quest.status == QuestStatus.EXHAUSTED,
            "DAN: Campaign still active"
        );
        require(quest.endedAt > 0, "DAN: Campaign end not recorded");
        require(
            block.timestamp >= quest.endedAt + COOLDOWN_PERIOD,
            "DAN: 24hr cooldown not passed"
        );
        require(quest.remainingBudget > 0, "DAN: No remaining budget");

        uint256 refundAmount = quest.remainingBudget;
        quest.remainingBudget = 0;

        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "DAN: Refund transfer failed");

        emit AdvertiserRefund(_questId, msg.sender, refundAmount);
    }

    /// @notice Owner withdraws accumulated platform fees to treasury wallet
    function withdrawTreasury() external onlyOwner nonReentrant {
        uint256 amount = treasuryBalance;
        require(amount > 0, "DAN: No treasury balance");

        treasuryBalance = 0;

        (bool success, ) = payable(treasury).call{value: amount}("");
        require(success, "DAN: Treasury withdrawal failed");

        emit TreasuryWithdrawal(treasury, amount);
    }

    /// @notice Advertiser pauses their active campaign
    function pauseCampaign(uint256 _questId) external questExists(_questId) {
        Quest storage quest = quests[_questId];
        require(quest.advertiser == msg.sender, "DAN: Not advertiser");
        require(quest.status == QuestStatus.ACTIVE, "DAN: Not active");

        quest.status = QuestStatus.PAUSED;
        emit QuestPaused(_questId);
    }

    /// @notice Advertiser resumes a paused campaign
    function resumeCampaign(uint256 _questId) external questExists(_questId) {
        Quest storage quest = quests[_questId];
        require(quest.advertiser == msg.sender, "DAN: Not advertiser");
        require(quest.status == QuestStatus.PAUSED, "DAN: Not paused");

        if (quest.endTime > 0 && block.timestamp > quest.endTime) {
            _endQuest(_questId, QuestStatus.ENDED);
            return;
        }

        quest.status = QuestStatus.ACTIVE;
        emit QuestResumed(_questId);
    }

    /// @notice Advertiser ends their campaign early
    function endCampaignEarly(uint256 _questId) external questExists(_questId) {
        Quest storage quest = quests[_questId];
        require(quest.advertiser == msg.sender, "DAN: Not advertiser");
        require(
            quest.status == QuestStatus.ACTIVE ||
                quest.status == QuestStatus.PAUSED,
            "DAN: Campaign already ended"
        );
        _endQuest(_questId, QuestStatus.ENDED);
    }

    /// @notice Owner or verifier can end an expired campaign
    function endExpiredCampaign(
        uint256 _questId
    ) external questExists(_questId) {
        Quest storage quest = quests[_questId];
        require(
            msg.sender == owner || msg.sender == verifier,
            "DAN: Not authorized"
        );
        require(quest.endTime > 0, "DAN: No end date set");
        require(block.timestamp > quest.endTime, "DAN: Not yet expired");
        require(
            quest.status == QuestStatus.ACTIVE ||
                quest.status == QuestStatus.PAUSED,
            "DAN: Already ended"
        );
        _endQuest(_questId, QuestStatus.ENDED);
    }

    /// @notice Top up an active campaign's budget
    function topUpCampaign(
        uint256 _questId
    ) external payable questExists(_questId) {
        _requireGranularWei(msg.value, "total budget (avax)");

        Quest storage quest = quests[_questId];
        require(quest.advertiser == msg.sender, "DAN: Not advertiser");
        require(
            quest.status == QuestStatus.ACTIVE ||
                quest.status == QuestStatus.PAUSED,
            "DAN: Campaign ended"
        );
        require(msg.value > 0, "DAN: No AVAX sent");

        quest.totalBudget += msg.value;
        quest.remainingBudget += msg.value;

        if (quest.status == QuestStatus.EXHAUSTED) {
            quest.status = QuestStatus.ACTIVE;
            quest.endedAt = 0;
        }
    }

    function _endQuest(uint256 _questId, QuestStatus _reason) internal {
        Quest storage quest = quests[_questId];
        quest.status = _reason;
        quest.endedAt = block.timestamp;
        emit CampaignEnded(_questId, _reason);
    }

    /// @notice Update the trusted verifier address (e.g. when backend wallet rotates)
    function setVerifier(address _newVerifier) external onlyOwner {
        require(_newVerifier != address(0), "DAN: Invalid address");
        emit VerifierUpdated(verifier, _newVerifier);
        verifier = _newVerifier;
    }

    /// @notice Update the treasury wallet
    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "DAN: Invalid address");
        emit TreasuryUpdated(treasury, _newTreasury);
        treasury = _newTreasury;
    }

    /// @notice Transfer contract ownership
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "DAN: Invalid address");
        owner = _newOwner;
    }

    /// @notice Get full quest details
    function getQuest(
        uint256 _questId
    ) external view questExists(_questId) returns (Quest memory) {
        return quests[_questId];
    }

    // TODO: this is gas expensive, use another method, prolly the array method or perform this on the FE 
    /// @notice Get all active quest IDs
    function getActiveQuestIds() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i <= questCounter; i++) {
            if (quests[i].status == QuestStatus.ACTIVE) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= questCounter; i++) {
            if (quests[i].status == QuestStatus.ACTIVE) {
                ids[index++] = i;
            }
        }
        return ids;
    }

    /// @notice Check if a user has completed a specific quest
    function hasUserCompleted(
        uint256 _questId,
        address _user
    ) external view returns (bool) {
        return hasCompleted[_questId][_user];
    }

    /// @notice Get user's pending withdrawable balance
    function getUserBalance(address _user) external view returns (uint256) {
        return users[_user].pendingBalance;
    }

    /// @notice Get publisher's pending withdrawable balance
    function getPublisherBalance(
        string calldata _key
    ) external view returns (uint256) {
        return publishersByHash[_publisherKeyHash(_key)].pendingBalance;
    }

    function _publisherKeyHash(
        string memory _key
    ) internal pure returns (bytes32) {
        return keccak256(bytes(_key));
    }

    function _validatePublisherKey(string calldata _publisherKey) internal pure {
        bytes calldata raw = bytes(_publisherKey);
        uint256 length = raw.length;

        require(length > 0, "DAN: Empty publisher key");
        require(length <= 32, "DAN: Key too long");

        for (uint256 i = 0; i < length; i++) {
            bytes1 char = raw[i];
            bool isLowerAlpha = char >= 0x61 && char <= 0x7A;
            bool isDigit = char >= 0x30 && char <= 0x39;
            bool isDash = char == 0x2D;
            bool isUnderscore = char == 0x5F;

            require(
                isLowerAlpha || isDigit || isDash || isUnderscore,
                "DAN: Invalid publisher key format"
            );
        }
    }

    function _requireGranularWei(
        uint256 _value,
        string memory _field
    ) internal pure {
        if (_value % GRANULAR_SCALAR != 0) {
            revert NonGranularWei(_field, _value, GRANULAR_SCALAR);
        }
    }

    /// @notice Check if a quest is currently claimable
    function isQuestClaimable(
        uint256 _questId
    ) external view questExists(_questId) returns (bool) {
        Quest memory quest = quests[_questId];
        if (quest.status != QuestStatus.ACTIVE) return false;
        if (quest.endTime > 0 && block.timestamp > quest.endTime) return false;
        if (
            quest.maxCompletions > 0 &&
            quest.completionCount >= quest.maxCompletions
        ) return false;
        if (quest.remainingBudget < quest.rewardPerUser) return false;
        return true;
    }

    /// @notice Get contract's total AVAX balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Reject direct AVAX transfers — all deposits must go through createQuest
    receive() external payable {
        revert("DAN: Use createQuest to deposit");
    }
}
