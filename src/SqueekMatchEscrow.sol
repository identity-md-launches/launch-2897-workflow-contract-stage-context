// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISqueekCore, ISqueekMining, ISqueekNFT} from "./interfaces/ISqueekchain.sol";

/// @title SqueekMatchEscrow
/// @notice Non-custodial, fee-free peer-to-peer market for Squeeks (Squeekchain's ERC-721) priced in SQK,
/// built so holders of a lone Squeek at a level can find a merge partner.
///
/// Three order kinds, each with create / fill / cancel:
/// - Ask: the maker sells one wallet-held Squeek for a fixed SQK price. The Squeek stays in the maker's
///   wallet; the maker only approves this contract. The taker pays SQK straight to the maker.
/// - Bid: the maker escrows SQK here and buys any Squeek at a chosen level, optionally only one that is
///   merge-ready on chain at fill time. The taker's Squeek goes straight to the maker.
/// - Swap: the maker trades one wallet-held Squeek for another Squeek (a specific id, or any Squeek at a
///   level, optionally merge-ready). Either side may add an SQK difference; the maker's share is escrowed.
///
/// Every order expires (default 7 days, maximum 30 days). The maker may cancel at any time; after expiry
/// anyone may cancel, which refunds escrowed SQK to the maker. Level and merge eligibility are read from
/// the live Squeekchain contracts at fill. There is no owner, no fee, no upgrade path and no pause.
///
/// @dev The contract never holds Squeeks, only the SQK that bid and swap makers escrow. It is reentrancy
/// guarded and follows checks-effects-interactions: an order is marked Filled or Cancelled before any
/// token moves. SQK is Squeekchain's fixed 18-decimal token with no transfer fee.
contract SqueekMatchEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    enum Kind {
        None,
        Ask,
        Bid,
        Swap
    }

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Ask {
        address maker;
        uint64 expiresAt;
        Status status;
        uint256 tokenId;
        uint256 price; // SQK base units the taker pays the maker
    }

    struct Bid {
        address maker;
        uint64 expiresAt;
        Status status;
        uint8 level; // exact level the delivered Squeek must have at fill
        bool mergeReady; // when true, the delivered Squeek must pass the on-chain merge-ready check
        uint256 amount; // SQK base units escrowed here and paid to the taker
    }

    struct Swap {
        address maker;
        uint64 expiresAt;
        Status status;
        uint8 wantedLevel; // exact level the taker's Squeek must have at fill
        bool mergeReady; // when true, the taker's Squeek must pass the on-chain merge-ready check
        uint256 makerTokenId; // the Squeek the maker gives (stays in the maker's wallet until fill)
        uint256 wantedTokenId; // a specific Squeek the maker wants, or ANY_SQUEEK (0)
        uint256 sqkFromMaker; // SQK the maker adds, escrowed here and paid to the taker
        uint256 sqkFromTaker; // SQK the taker adds, paid straight to the maker at fill
    }

    // ---------------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice Expiry applied when an order is created with duration 0.
    uint64 public constant DEFAULT_DURATION = 7 days;
    /// @notice Longest expiry an order may have.
    uint64 public constant MAX_DURATION = 30 days;
    /// @notice SqueekMining collection selector for Squeeks (SqueekNFT).
    uint8 public constant SQUEEKS_COLLECTION = 0;
    /// @notice `wantedTokenId` value meaning "any Squeek at `wantedLevel`". Token id 0 is never minted.
    uint256 public constant ANY_SQUEEK = 0;

    /// @notice The Squeek ERC-721 collection (SqueekNFT).
    ISqueekNFT public immutable SQUEEK;
    /// @notice The SQK ERC-20 token (SqueekToken).
    IERC20 public immutable SQK;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Id the next order of any kind receives. Ids are unique across asks, bids and swaps.
    uint256 public nextOrderId = 1;
    /// @notice Which kind of order an id refers to (None for ids not yet used).
    mapping(uint256 orderId => Kind) public kindOf;
    mapping(uint256 orderId => Ask) public asks;
    mapping(uint256 orderId => Bid) public bids;
    mapping(uint256 orderId => Swap) public swaps;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event AskCreated(
        uint256 indexed askId, address indexed maker, uint256 indexed tokenId, uint256 price, uint64 expiresAt
    );
    event AskFilled(
        uint256 indexed askId, address indexed taker, address indexed maker, uint256 tokenId, uint256 price
    );
    event AskCancelled(uint256 indexed askId, address indexed caller, bool expired);

    event BidCreated(
        uint256 indexed bidId,
        address indexed maker,
        uint8 indexed level,
        bool mergeReady,
        uint256 amount,
        uint64 expiresAt
    );
    event BidFilled(
        uint256 indexed bidId, address indexed taker, uint256 indexed tokenId, address maker, uint256 amount
    );
    event BidCancelled(uint256 indexed bidId, address indexed caller, bool expired, uint256 refund);

    event SwapCreated(
        uint256 indexed swapId,
        address indexed maker,
        uint256 indexed makerTokenId,
        uint256 wantedTokenId,
        uint8 wantedLevel,
        bool mergeReady,
        uint256 sqkFromMaker,
        uint256 sqkFromTaker,
        uint64 expiresAt
    );
    event SwapFilled(
        uint256 indexed swapId,
        address indexed taker,
        uint256 indexed takerTokenId,
        address maker,
        uint256 makerTokenId,
        uint256 sqkFromMaker,
        uint256 sqkFromTaker
    );
    event SwapCancelled(uint256 indexed swapId, address indexed caller, bool expired, uint256 refund);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InvalidLevel();
    error DurationTooLong(uint256 duration, uint256 maximum);
    error NotTokenOwner(uint256 tokenId, address owner);
    error EscrowNotApproved(uint256 tokenId, address owner);
    error OrderNotOpen(uint256 orderId);
    error OrderExpired(uint256 orderId, uint64 expiresAt);
    error NotMakerAndNotExpired(uint256 orderId);
    error SelfTrade();
    error MakerNoLongerOwns(uint256 orderId, uint256 tokenId);
    error SameToken();
    error BothSidesPaySqk();
    error WrongToken(uint256 wanted, uint256 offered);
    error LevelMismatch(uint256 tokenId, uint8 wanted, uint8 actual);
    error NoLivePosition(uint256 tokenId);
    error PowerChangePending(uint256 tokenId, uint40 pendingRound);
    error CooldownActive(uint256 tokenId, uint48 nextMergeBlock, uint64 blockHeight);
    error AtMaximumLevel(uint256 tokenId, uint8 level);

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param squeek_ SqueekNFT, the Squeek ERC-721 collection on the launch chain.
    /// @param sqk_ SqueekToken, the SQK ERC-20 on the launch chain.
    /// @dev Makes no external call so it deploys on an empty chain; both contracts are checked on first use.
    constructor(address squeek_, address sqk_) {
        if (squeek_ == address(0) || sqk_ == address(0)) revert ZeroAddress();
        SQUEEK = ISqueekNFT(squeek_);
        SQK = IERC20(sqk_);
    }

    // ---------------------------------------------------------------------------------------------
    // Asks: sell one wallet-held Squeek for SQK
    // ---------------------------------------------------------------------------------------------

    /// @notice List `tokenId`, which stays in your wallet, for `price` SQK.
    /// @param tokenId Squeek you own and have approved this contract to transfer.
    /// @param price SQK base units the buyer pays you. Must be > 0.
    /// @param duration Seconds until expiry; 0 means DEFAULT_DURATION, at most MAX_DURATION.
    function createAsk(uint256 tokenId, uint256 price, uint64 duration) external nonReentrant returns (uint256 askId) {
        if (price == 0) revert ZeroAmount();
        _requireOwnerAndApproval(tokenId, msg.sender);
        uint64 expiresAt = _expiry(duration);

        askId = _nextId(Kind.Ask);
        asks[askId] =
            Ask({maker: msg.sender, expiresAt: expiresAt, status: Status.Open, tokenId: tokenId, price: price});
        emit AskCreated(askId, msg.sender, tokenId, price, expiresAt);
    }

    /// @notice Buy the Squeek of ask `askId`: you pay the maker its price in SQK and receive the Squeek.
    /// @dev You must have approved this contract for at least `price` SQK.
    function fillAsk(uint256 askId) external nonReentrant {
        Ask storage ask = asks[askId];
        _requireOpen(askId, ask.status, ask.expiresAt);
        address maker = ask.maker;
        if (msg.sender == maker) revert SelfTrade();
        uint256 tokenId = ask.tokenId;
        if (SQUEEK.ownerOf(tokenId) != maker) revert MakerNoLongerOwns(askId, tokenId);
        if (!_escrowApproved(tokenId, maker)) revert EscrowNotApproved(tokenId, maker);
        uint256 price = ask.price;

        ask.status = Status.Filled;
        emit AskFilled(askId, msg.sender, maker, tokenId, price);

        SQK.safeTransferFrom(msg.sender, maker, price);
        SQUEEK.safeTransferFrom(maker, msg.sender, tokenId);
    }

    /// @notice Cancel ask `askId`. The maker may cancel at any time; anyone may cancel once it has expired.
    function cancelAsk(uint256 askId) external nonReentrant {
        Ask storage ask = asks[askId];
        if (ask.status != Status.Open) revert OrderNotOpen(askId);
        bool expired = _cancelAllowed(askId, ask.maker, ask.expiresAt);
        ask.status = Status.Cancelled;
        emit AskCancelled(askId, msg.sender, expired);
    }

    // ---------------------------------------------------------------------------------------------
    // Bids: escrow SQK for any Squeek at a level
    // ---------------------------------------------------------------------------------------------

    /// @notice Escrow `amount` SQK to buy any Squeek at exactly `level`.
    /// @param level Level the delivered Squeek must have at fill (1..maximum level).
    /// @param mergeReady When true the delivered Squeek must also be merge-ready at fill: below the maximum
    /// level, no scheduled power change, and its merge cooldown reached at SqueekCore's completed height.
    /// @param amount SQK base units escrowed now and paid to whoever fills the bid. Must be > 0.
    /// @param duration Seconds until expiry; 0 means DEFAULT_DURATION, at most MAX_DURATION.
    function createBid(uint8 level, bool mergeReady, uint256 amount, uint64 duration)
        external
        nonReentrant
        returns (uint256 bidId)
    {
        if (amount == 0) revert ZeroAmount();
        if (level == 0) revert InvalidLevel();
        uint64 expiresAt = _expiry(duration);

        bidId = _nextId(Kind.Bid);
        bids[bidId] = Bid({
            maker: msg.sender,
            expiresAt: expiresAt,
            status: Status.Open,
            level: level,
            mergeReady: mergeReady,
            amount: amount
        });
        emit BidCreated(bidId, msg.sender, level, mergeReady, amount, expiresAt);

        SQK.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Sell `tokenId` into bid `bidId`: the Squeek goes to the maker and the escrowed SQK to you.
    /// @dev You must own `tokenId` and have approved this contract to transfer it. The Squeek's level (and
    /// merge readiness, if the bid asks for it) is read from SqueekMining in this same call.
    function fillBid(uint256 bidId, uint256 tokenId) external nonReentrant {
        Bid storage bid = bids[bidId];
        _requireOpen(bidId, bid.status, bid.expiresAt);
        address maker = bid.maker;
        if (msg.sender == maker) revert SelfTrade();
        _requireOwnerAndApproval(tokenId, msg.sender);
        _requireMatches(tokenId, bid.level, bid.mergeReady);
        uint256 amount = bid.amount;

        bid.status = Status.Filled;
        emit BidFilled(bidId, msg.sender, tokenId, maker, amount);

        SQUEEK.safeTransferFrom(msg.sender, maker, tokenId);
        SQK.safeTransfer(msg.sender, amount);
    }

    /// @notice Cancel bid `bidId` and refund its SQK to the maker. The maker may cancel at any time; anyone
    /// may cancel once it has expired (the refund still goes to the maker).
    function cancelBid(uint256 bidId) external nonReentrant {
        Bid storage bid = bids[bidId];
        if (bid.status != Status.Open) revert OrderNotOpen(bidId);
        address maker = bid.maker;
        bool expired = _cancelAllowed(bidId, maker, bid.expiresAt);
        uint256 refund = bid.amount;

        bid.status = Status.Cancelled;
        emit BidCancelled(bidId, msg.sender, expired, refund);

        SQK.safeTransfer(maker, refund);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: Squeek for Squeek, either side may add SQK
    // ---------------------------------------------------------------------------------------------

    /// @notice Offer `makerTokenId` (stays in your wallet) for another Squeek, plus an optional SQK difference.
    /// @param makerTokenId Squeek you own and have approved this contract to transfer.
    /// @param wantedTokenId A specific Squeek you want, or ANY_SQUEEK (0) for any Squeek at `wantedLevel`.
    /// @param wantedLevel Level the delivered Squeek must have at fill (1..maximum level); always checked.
    /// @param mergeReady When true the delivered Squeek must also be merge-ready at fill.
    /// @param sqkFromMaker SQK you add on top of your Squeek; escrowed now, paid to the taker at fill.
    /// @param sqkFromTaker SQK the taker must add; paid straight to you at fill. Not both > 0.
    /// @param duration Seconds until expiry; 0 means DEFAULT_DURATION, at most MAX_DURATION.
    function createSwap(
        uint256 makerTokenId,
        uint256 wantedTokenId,
        uint8 wantedLevel,
        bool mergeReady,
        uint256 sqkFromMaker,
        uint256 sqkFromTaker,
        uint64 duration
    ) external nonReentrant returns (uint256 swapId) {
        if (wantedLevel == 0) revert InvalidLevel();
        if (wantedTokenId == makerTokenId) revert SameToken();
        if (sqkFromMaker != 0 && sqkFromTaker != 0) revert BothSidesPaySqk();
        _requireOwnerAndApproval(makerTokenId, msg.sender);
        uint64 expiresAt = _expiry(duration);

        swapId = _nextId(Kind.Swap);
        swaps[swapId] = Swap({
            maker: msg.sender,
            expiresAt: expiresAt,
            status: Status.Open,
            wantedLevel: wantedLevel,
            mergeReady: mergeReady,
            makerTokenId: makerTokenId,
            wantedTokenId: wantedTokenId,
            sqkFromMaker: sqkFromMaker,
            sqkFromTaker: sqkFromTaker
        });
        emit SwapCreated(
            swapId,
            msg.sender,
            makerTokenId,
            wantedTokenId,
            wantedLevel,
            mergeReady,
            sqkFromMaker,
            sqkFromTaker,
            expiresAt
        );

        if (sqkFromMaker != 0) SQK.safeTransferFrom(msg.sender, address(this), sqkFromMaker);
    }

    /// @notice Fill swap `swapId` with your Squeek `tokenId`: the two Squeeks change hands and the SQK
    /// difference, if any, is paid.
    /// @dev You must own `tokenId` and have approved this contract for it, and, when the swap asks for SQK
    /// from the taker, have approved this contract for that amount of SQK.
    function fillSwap(uint256 swapId, uint256 tokenId) external nonReentrant {
        Swap storage swap_ = swaps[swapId];
        _requireOpen(swapId, swap_.status, swap_.expiresAt);
        address maker = swap_.maker;
        if (msg.sender == maker) revert SelfTrade();
        uint256 wanted = swap_.wantedTokenId;
        if (wanted != ANY_SQUEEK && wanted != tokenId) revert WrongToken(wanted, tokenId);
        uint256 makerTokenId = swap_.makerTokenId;
        if (SQUEEK.ownerOf(makerTokenId) != maker) revert MakerNoLongerOwns(swapId, makerTokenId);
        if (!_escrowApproved(makerTokenId, maker)) revert EscrowNotApproved(makerTokenId, maker);
        _requireOwnerAndApproval(tokenId, msg.sender);
        _requireMatches(tokenId, swap_.wantedLevel, swap_.mergeReady);
        uint256 sqkFromMaker = swap_.sqkFromMaker;
        uint256 sqkFromTaker = swap_.sqkFromTaker;

        swap_.status = Status.Filled;
        emit SwapFilled(swapId, msg.sender, tokenId, maker, makerTokenId, sqkFromMaker, sqkFromTaker);

        if (sqkFromTaker != 0) SQK.safeTransferFrom(msg.sender, maker, sqkFromTaker);
        SQUEEK.safeTransferFrom(msg.sender, maker, tokenId);
        SQUEEK.safeTransferFrom(maker, msg.sender, makerTokenId);
        if (sqkFromMaker != 0) SQK.safeTransfer(msg.sender, sqkFromMaker);
    }

    /// @notice Cancel swap `swapId` and refund any escrowed SQK to the maker. The maker may cancel at any
    /// time; anyone may cancel once it has expired (the refund still goes to the maker).
    function cancelSwap(uint256 swapId) external nonReentrant {
        Swap storage swap_ = swaps[swapId];
        if (swap_.status != Status.Open) revert OrderNotOpen(swapId);
        address maker = swap_.maker;
        bool expired = _cancelAllowed(swapId, maker, swap_.expiresAt);
        uint256 refund = swap_.sqkFromMaker;

        swap_.status = Status.Cancelled;
        emit SwapCancelled(swapId, msg.sender, expired, refund);

        if (refund != 0) SQK.safeTransfer(maker, refund);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The SqueekMining contract SqueekNFT points to.
    function mining() public view returns (ISqueekMining) {
        return ISqueekMining(SQUEEK.mining());
    }

    /// @notice Level of `tokenId` as SqueekMining reports it; 0 for a burned or unminted Squeek.
    function levelOf(uint256 tokenId) external view returns (uint8) {
        return mining().position(SQUEEKS_COLLECTION, tokenId).level;
    }

    /// @notice Whether `tokenId` could merge right now: live, below the maximum level, no scheduled power
    /// change, and its cooldown reached at SqueekCore's completed Squeek block height.
    function isMergeReady(uint256 tokenId) external view returns (bool) {
        ISqueekMining m = mining();
        ISqueekMining.MiningPosition memory pos = m.position(SQUEEKS_COLLECTION, tokenId);
        if (pos.level == 0 || pos.pendingRound != 0) return false;
        if (pos.level >= m.collectionPolicy(SQUEEKS_COLLECTION).maximumLevel) return false;
        return pos.nextMergeBlock <= ISqueekCore(m.core()).state().blockHeight;
    }

    /// @notice Whether an order of any kind is open and not yet expired.
    function isOpen(uint256 orderId) external view returns (bool) {
        Kind kind = kindOf[orderId];
        if (kind == Kind.Ask) return _isOpen(asks[orderId].status, asks[orderId].expiresAt);
        if (kind == Kind.Bid) return _isOpen(bids[orderId].status, bids[orderId].expiresAt);
        if (kind == Kind.Swap) return _isOpen(swaps[orderId].status, swaps[orderId].expiresAt);
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _nextId(Kind kind) private returns (uint256 id) {
        id = nextOrderId++;
        kindOf[id] = kind;
    }

    function _expiry(uint64 duration) private view returns (uint64) {
        if (duration == 0) duration = DEFAULT_DURATION;
        if (duration > MAX_DURATION) revert DurationTooLong(duration, MAX_DURATION);
        return uint64(block.timestamp) + duration;
    }

    function _isOpen(Status status, uint64 expiresAt) private view returns (bool) {
        return status == Status.Open && block.timestamp < expiresAt;
    }

    function _requireOpen(uint256 orderId, Status status, uint64 expiresAt) private view {
        if (status != Status.Open) revert OrderNotOpen(orderId);
        if (block.timestamp >= expiresAt) revert OrderExpired(orderId, expiresAt);
    }

    /// @dev Returns whether the order had expired; reverts unless the caller is the maker or it has expired.
    function _cancelAllowed(uint256 orderId, address maker, uint64 expiresAt) private view returns (bool expired) {
        expired = block.timestamp >= expiresAt;
        if (msg.sender != maker && !expired) revert NotMakerAndNotExpired(orderId);
    }

    function _escrowApproved(uint256 tokenId, address owner) private view returns (bool) {
        return SQUEEK.getApproved(tokenId) == address(this) || SQUEEK.isApprovedForAll(owner, address(this));
    }

    function _requireOwnerAndApproval(uint256 tokenId, address account) private view {
        address owner = SQUEEK.ownerOf(tokenId);
        if (owner != account) revert NotTokenOwner(tokenId, owner);
        if (!_escrowApproved(tokenId, owner)) revert EscrowNotApproved(tokenId, owner);
    }

    /// @dev Reads the Squeek's live position and reverts unless it is at `level` and, when `mergeReady` is
    /// requested, could merge right now.
    function _requireMatches(uint256 tokenId, uint8 level, bool mergeReady) private view {
        ISqueekMining m = mining();
        ISqueekMining.MiningPosition memory pos = m.position(SQUEEKS_COLLECTION, tokenId);
        if (pos.level == 0) revert NoLivePosition(tokenId);
        if (pos.level != level) revert LevelMismatch(tokenId, level, pos.level);
        if (!mergeReady) return;
        if (pos.pendingRound != 0) revert PowerChangePending(tokenId, pos.pendingRound);
        uint8 maximumLevel = m.collectionPolicy(SQUEEKS_COLLECTION).maximumLevel;
        if (pos.level >= maximumLevel) revert AtMaximumLevel(tokenId, pos.level);
        uint64 height = ISqueekCore(m.core()).state().blockHeight;
        if (pos.nextMergeBlock > height) revert CooldownActive(tokenId, pos.nextMergeBlock, height);
    }
}
