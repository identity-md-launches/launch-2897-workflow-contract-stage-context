// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekMatchEscrow} from "../src/SqueekMatchEscrow.sol";
import {ISqueekMining} from "../src/interfaces/ISqueekchain.sol";
import {MockSQK, MockSqueekCore, MockSqueekMining, MockSqueekNFT} from "./mocks/SqueekchainMocks.sol";

/// @notice Drives SqueekMatchEscrow with random sequences of creates, fills and cancels of all three order
/// kinds, interleaved with the things the outside world does between them: time passing, Squeeks changing
/// level / cooldown / pending power, the policy's maximum level moving, Squeeks moving between wallets,
/// approvals being revoked, SQK being sent
/// to the escrow directly.
///
/// For every escrow call the handler first predicts, from its own independent model of the order book,
/// whether the call must succeed, and after it checks the actual outcome and the exact token movements.
/// A mismatch never reverts the handler (that would just discard the run); it is written to `violation`
/// and the invariant contract fails on it.
contract EscrowHandler is Test {
    uint8 internal constant ASK = 1;
    uint8 internal constant BID = 2;
    uint8 internal constant SWAP = 3;
    uint8 internal constant OPEN = 1;
    uint8 internal constant FILLED = 2;
    uint8 internal constant CANCELLED = 3;

    uint8 internal constant MAX_LEVEL = 10; // MockSqueekMining.MAXIMUM_LEVEL
    uint256 internal constant NUM_TOKENS = 12;
    uint256 internal constant MAX_PRICE = 50_000 ether;

    struct GhostOrder {
        uint8 kind;
        uint8 status;
        address maker;
        uint64 expiresAt;
        uint256 tokenId; // ask tokenId or swap makerTokenId
        uint256 amount; // ask price, bid amount, swap sqkFromMaker
        uint256 wantedTokenId;
        uint8 level;
        bool mergeReady;
        uint256 sqkFromTaker;
        uint8 makerLevel; // ask / swap: level of the maker's Squeek when the order was created
        uint256 tradeCountAt; // ask / swap: escrow trades of the maker's Squeek when the order was created
    }

    SqueekMatchEscrow public immutable escrow;
    MockSQK public immutable sqk;
    MockSqueekNFT public immutable nft;
    MockSqueekMining public immutable mining;
    MockSqueekCore public immutable core;

    address[] public actors;
    uint256[] public orderIds;
    mapping(uint8 => uint256[]) internal idsOfKind;
    mapping(uint256 => GhostOrder) internal ghost;
    /// @dev How many fills moved each Squeek; asks and swaps of an older trade count must not fill.
    mapping(uint256 => uint256) public ghostTrades;

    // Ghost accounting.
    uint256 public ghostOwed; // SQK the escrow owes open bids and swaps
    uint256 public ghostDonated; // SQK sent to the escrow outside any order
    uint256 public ghostEscrowedIn; // all SQK ever escrowed by makers
    uint256 public ghostEscrowedOut; // all SQK ever paid out of escrow (fills + refunds)
    uint256 public ghostCreated; // successful creates
    mapping(address => uint256) public ghostMakerIn;
    mapping(address => uint256) public ghostMakerRefunded;

    // Coverage counters, to show the run did not check nothing.
    mapping(bytes32 => uint256) public calls;

    string public violation;

    constructor(
        SqueekMatchEscrow escrow_,
        MockSQK sqk_,
        MockSqueekNFT nft_,
        MockSqueekMining mining_,
        MockSqueekCore core_
    ) {
        escrow = escrow_;
        sqk = sqk_;
        nft = nft_;
        mining = mining_;
        core = core_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function ghostOrder(uint256 id) external view returns (GhostOrder memory) {
        return ghost[id];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal pure returns (uint256) {
        return (seed % NUM_TOKENS) + 1; // ids 1..12, never ANY_SQUEEK (0)
    }

    /// @dev Mostly a real order id, sometimes an id never created (0 or past the end).
    function _orderId(uint256 seed) internal view returns (uint256) {
        if (orderIds.length == 0 || seed % 10 == 0) return seed % 3 == 0 ? 0 : escrow.nextOrderId() + (seed % 5);
        return orderIds[seed % orderIds.length];
    }

    /// @dev Mostly a still-open order of `kind` (the newest few first), sometimes any order of `kind`, any
    /// order, or an id never created.
    function _orderIdOf(uint8 kind, uint256 seed) internal view returns (uint256) {
        return _orderIdOf(kind, seed, true);
    }

    /// @dev As above; `preferLive` false picks uniformly among the orders of `kind` (used by cancels, so
    /// they do not close every order before a fill can reach it).
    function _orderIdOf(uint8 kind, uint256 seed, bool preferLive) internal view returns (uint256) {
        uint256[] storage list = idsOfKind[kind];
        if (list.length == 0 || seed % 5 == 0) return _orderId(seed / 5);
        if (preferLive && seed % 5 != 1) {
            uint256 skip = (seed / 5) % 3;
            for (uint256 i = list.length; i > 0 && list.length - i < 12; --i) {
                if (_liveOpen(ghost[list[i - 1]])) {
                    if (skip == 0) return list[i - 1];
                    --skip;
                }
            }
        }
        return list[(seed / 5) % list.length];
    }

    /// @dev Mostly an actor other than `avoid`, sometimes any actor (so self-trades are still tried).
    function _actorNot(uint256 seed, address avoid) internal view returns (address a) {
        a = _actor(seed);
        if (a == avoid && seed % 8 != 0) a = _actor(seed % actors.length + 1);
    }

    /// @dev Mostly the token's owner, sometimes a random actor.
    function _makerFor(uint256 actorSeed, uint256 tokenId) internal view returns (address) {
        return actorSeed % 4 == 0 ? _actor(actorSeed / 4) : nft.ownerOf(tokenId);
    }

    /// @dev Mostly a level some Squeek has right now, sometimes any level in 0..MAX_LEVEL + 1.
    function _levelFor(uint256 seed) internal view returns (uint8) {
        if (seed % 4 == 0) return uint8(bound(seed / 4, 0, MAX_LEVEL + 1));
        return mining.position(0, _token(seed / 4)).level;
    }

    /// @dev Mostly a Squeek at `level` not owned by `maker` (if one exists), else a random one.
    function _tokenFor(uint256 seed, uint8 level, address maker) internal view returns (uint256) {
        if (seed % 4 != 0) {
            for (uint256 i; i < NUM_TOKENS; ++i) {
                uint256 t = _token(seed / 4 + i);
                if (mining.position(0, t).level == level && nft.ownerOf(t) != maker) return t;
            }
        }
        return _token(seed / 4);
    }

    function _push(uint256 id, uint8 kind) internal {
        orderIds.push(id);
        idsOfKind[kind].push(id);
        ++ghostCreated;
    }

    function _approved(uint256 tokenId, address owner) internal view returns (bool) {
        return nft.getApproved(tokenId) == address(escrow) || nft.isApprovedForAll(owner, address(escrow));
    }

    function _ownsAndApproved(uint256 tokenId, address who) internal view returns (bool) {
        return nft.ownerOf(tokenId) == who && _approved(tokenId, who);
    }

    function _durationOk(uint64 d) internal pure returns (bool) {
        return d <= 30 days;
    }

    function _expiry(uint64 d) internal view returns (uint64) {
        return uint64(block.timestamp) + (d == 0 ? 7 days : d);
    }

    function _liveOpen(GhostOrder storage g) internal view returns (bool) {
        return g.status == OPEN && block.timestamp < g.expiresAt;
    }

    function _matches(uint256 tokenId, uint8 level, bool mergeReady) internal view returns (bool) {
        ISqueekMining.MiningPosition memory p = mining.position(0, tokenId);
        if (p.level == 0 || p.level != level) return false;
        if (!mergeReady) return true;
        return p.pendingRound == 0 && p.level < mining.maximumLevel() && p.nextMergeBlock <= core.blockHeight();
    }

    /// @dev Whether some Squeek could ever satisfy a bid / swap's wanted level under the current policy.
    function _fillableLevel(uint8 level, bool mergeReady) internal view returns (bool) {
        uint8 maximum = mining.maximumLevel();
        return level != 0 && level <= maximum && !(mergeReady && level >= maximum);
    }

    /// @dev The maker side of an ask or swap: still the maker's, not traded here since, approved, same level.
    function _makerSideOk(GhostOrder storage g) internal view returns (bool) {
        return _ownsAndApproved(g.tokenId, g.maker) && ghostTrades[g.tokenId] == g.tradeCountAt
            && mining.position(0, g.tokenId).level == g.makerLevel;
    }

    /// @dev What `isFillable` must report for `id`, from the model alone.
    function predictedFillable(uint256 id) external view returns (bool) {
        GhostOrder storage g = ghost[id];
        if (g.kind == 0 || !_liveOpen(g)) return false;
        if (g.kind == BID) return true;
        return _makerSideOk(g);
    }

    function _fail(string memory what) internal {
        if (bytes(violation).length == 0) violation = what;
    }

    function _check(bool predicted, bool actual, string memory what) internal {
        if (predicted && !actual) _fail(string.concat(what, ": expected success, reverted"));
        if (!predicted && actual) _fail(string.concat(what, ": succeeded but must have reverted"));
    }

    // ---------------------------------------------------------------------------------------------
    // Asks
    // ---------------------------------------------------------------------------------------------

    function createAsk(uint256 actorSeed, uint256 tokenSeed, uint256 price, uint64 duration) external {
        uint256 tokenId = _token(tokenSeed);
        address maker = _makerFor(actorSeed, tokenId);
        price = bound(price, 0, MAX_PRICE);
        duration = uint64(bound(duration, 0, 31 days));
        uint8 level = mining.position(0, tokenId).level;
        bool ok = price != 0 && _durationOk(duration) && _ownsAndApproved(tokenId, maker) && level != 0;
        uint256 expectedId = escrow.nextOrderId();

        vm.prank(maker);
        try escrow.createAsk(tokenId, price, duration) returns (uint256 id) {
            _check(ok, true, "createAsk");
            if (id != expectedId) _fail("createAsk: id not nextOrderId");
            ghost[id] = GhostOrder(
                ASK, OPEN, maker, _expiry(duration), tokenId, price, 0, 0, false, 0, level, ghostTrades[tokenId]
            );
            _push(id, ghost[id].kind);
            ++calls["createAsk"];
        } catch {
            _check(ok, false, "createAsk");
        }
    }

    function fillAsk(uint256 actorSeed, uint256 orderSeed) external {
        uint256 id = _orderIdOf(ASK, orderSeed);
        GhostOrder storage g = ghost[id];
        address taker = _actorNot(actorSeed, g.maker);
        bool ok =
            g.kind == ASK && _liveOpen(g) && taker != g.maker && _makerSideOk(g) && sqk.balanceOf(taker) >= g.amount;
        uint256 takerBefore = sqk.balanceOf(taker);
        uint256 makerBefore = sqk.balanceOf(g.maker);
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(taker);
        try escrow.fillAsk(id) {
            _check(ok, true, "fillAsk");
            g.status = FILLED;
            ++ghostTrades[g.tokenId];
            if (nft.ownerOf(g.tokenId) != taker) _fail("fillAsk: taker did not get the Squeek");
            if (sqk.balanceOf(taker) != takerBefore - g.amount) _fail("fillAsk: taker paid wrong amount");
            if (sqk.balanceOf(g.maker) != makerBefore + g.amount) _fail("fillAsk: maker paid wrong amount");
            if (sqk.balanceOf(address(escrow)) != escrowBefore) _fail("fillAsk: escrow balance moved");
            ++calls["fillAsk"];
        } catch {
            _check(ok, false, "fillAsk");
        }
    }

    function cancelAsk(uint256 actorSeed, uint256 orderSeed) external {
        uint256 id = _orderIdOf(ASK, orderSeed, false);
        GhostOrder storage g = ghost[id];
        address caller = actorSeed % 2 == 0 && g.maker != address(0) ? g.maker : _actor(actorSeed);
        bool ok = g.kind == ASK && g.status == OPEN && (caller == g.maker || block.timestamp >= g.expiresAt);
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(caller);
        try escrow.cancelAsk(id) {
            _check(ok, true, "cancelAsk");
            g.status = CANCELLED;
            if (sqk.balanceOf(address(escrow)) != escrowBefore) _fail("cancelAsk: escrow balance moved");
            ++calls["cancelAsk"];
        } catch {
            _check(ok, false, "cancelAsk");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Bids
    // ---------------------------------------------------------------------------------------------

    function createBid(uint256 actorSeed, uint8 level, bool mergeReady, uint256 amount, uint64 duration) external {
        address maker = _actor(actorSeed);
        level = _levelFor(uint256(keccak256(abi.encode(level, actorSeed))));
        amount = bound(amount, 0, MAX_PRICE);
        duration = uint64(bound(duration, 0, 31 days));
        bool ok =
            amount != 0 && _fillableLevel(level, mergeReady) && _durationOk(duration) && sqk.balanceOf(maker) >= amount;
        uint256 expectedId = escrow.nextOrderId();
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(maker);
        try escrow.createBid(level, mergeReady, amount, duration) returns (uint256 id) {
            _check(ok, true, "createBid");
            if (id != expectedId) _fail("createBid: id not nextOrderId");
            if (sqk.balanceOf(address(escrow)) != escrowBefore + amount) _fail("createBid: wrong escrow amount");
            ghost[id] = GhostOrder(BID, OPEN, maker, _expiry(duration), 0, amount, 0, level, mergeReady, 0, 0, 0);
            _push(id, ghost[id].kind);
            ghostOwed += amount;
            ghostEscrowedIn += amount;
            ghostMakerIn[maker] += amount;
            ++calls["createBid"];
        } catch {
            _check(ok, false, "createBid");
        }
    }

    function fillBid(uint256 actorSeed, uint256 orderSeed, uint256 tokenSeed) external {
        uint256 id = _orderIdOf(BID, orderSeed);
        GhostOrder storage g = ghost[id];
        uint256 tokenId = _tokenFor(tokenSeed, g.level, g.maker);
        // Mostly fill as the token's owner, sometimes as someone else.
        address taker = actorSeed % 4 == 0 ? _actor(actorSeed / 4) : nft.ownerOf(tokenId);
        bool ok = g.kind == BID && _liveOpen(g) && taker != g.maker && _ownsAndApproved(tokenId, taker)
            && _matches(tokenId, g.level, g.mergeReady);
        uint256 takerBefore = sqk.balanceOf(taker);
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(taker);
        try escrow.fillBid(id, tokenId) {
            _check(ok, true, "fillBid");
            g.status = FILLED;
            ++ghostTrades[tokenId];
            ghostOwed -= g.amount;
            ghostEscrowedOut += g.amount;
            if (nft.ownerOf(tokenId) != g.maker) _fail("fillBid: maker did not get the Squeek");
            if (sqk.balanceOf(taker) != takerBefore + g.amount) _fail("fillBid: taker paid wrong amount");
            if (sqk.balanceOf(address(escrow)) != escrowBefore - g.amount) _fail("fillBid: escrow paid wrong amount");
            ++calls["fillBid"];
        } catch {
            _check(ok, false, "fillBid");
        }
    }

    function cancelBid(uint256 actorSeed, uint256 orderSeed) external {
        uint256 id = _orderIdOf(BID, orderSeed, false);
        GhostOrder storage g = ghost[id];
        address caller = actorSeed % 2 == 0 && g.maker != address(0) ? g.maker : _actor(actorSeed);
        bool ok = g.kind == BID && g.status == OPEN && (caller == g.maker || block.timestamp >= g.expiresAt);
        uint256 makerBefore = sqk.balanceOf(g.maker);
        uint256 callerBefore = sqk.balanceOf(caller);

        vm.prank(caller);
        try escrow.cancelBid(id) {
            _check(ok, true, "cancelBid");
            g.status = CANCELLED;
            ghostOwed -= g.amount;
            ghostEscrowedOut += g.amount;
            ghostMakerRefunded[g.maker] += g.amount;
            if (sqk.balanceOf(g.maker) != makerBefore + g.amount) _fail("cancelBid: maker refund wrong");
            if (caller != g.maker && sqk.balanceOf(caller) != callerBefore) _fail("cancelBid: caller got SQK");
            ++calls["cancelBid"];
        } catch {
            _check(ok, false, "cancelBid");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    function createSwap(
        uint256 actorSeed,
        uint256 tokenSeed,
        uint256 wantedSeed,
        uint8 level,
        bool mergeReady,
        uint256 difference,
        uint8 payMode,
        uint64 duration
    ) public returns (uint256) {
        GhostOrder memory o;
        o.kind = SWAP;
        o.status = OPEN;
        o.tokenId = _token(tokenSeed);
        o.maker = _makerFor(actorSeed, o.tokenId);
        // Half the time ANY_SQUEEK (0), otherwise a specific id (possibly the maker's own, which must revert).
        o.wantedTokenId = wantedSeed % 2 == 0 ? 0 : (wantedSeed / 2) % (NUM_TOKENS + 1);
        o.level = _levelFor(uint256(keccak256(abi.encode(level, wantedSeed))));
        // A named wanted Squeek is usually asked for at its current level.
        if (o.wantedTokenId != 0 && level % 4 != 0) o.level = mining.position(0, o.wantedTokenId).level;
        o.mergeReady = mergeReady;
        difference = bound(difference, 1, MAX_PRICE);
        // 0: no difference, 1: maker pays, 2: taker pays, 3: both pay (must revert, so tried less often)
        payMode = payMode % 8 == 7 ? 3 : payMode % 3;
        o.amount = payMode == 1 || payMode == 3 ? difference : 0;
        o.sqkFromTaker = payMode == 2 || payMode == 3 ? difference : 0;
        duration = uint64(bound(duration, 0, 31 days));
        o.expiresAt = _expiry(duration);
        o.makerLevel = mining.position(0, o.tokenId).level;
        o.tradeCountAt = ghostTrades[o.tokenId];
        bool ok = _fillableLevel(o.level, o.mergeReady) && o.wantedTokenId != o.tokenId && payMode != 3
            && _durationOk(duration) && _ownsAndApproved(o.tokenId, o.maker) && o.makerLevel != 0
            && sqk.balanceOf(o.maker) >= o.amount;
        return _createSwap(o, duration, ok);
    }

    /// @dev A swap made and then taken straight away (in two separate escrow calls), so the swap fill path
    /// is reached in most runs rather than only when a random fill happens to find a live swap. The taker is
    /// mostly the owner of a Squeek at the wanted level; the model still predicts both outcomes.
    function createThenFillSwap(
        uint256 actorSeed,
        uint256 tokenSeed,
        uint256 wantedSeed,
        uint8 level,
        bool mergeReady,
        uint256 difference,
        uint8 payMode,
        uint256 takerSeed
    ) external {
        uint256 id = createSwap(actorSeed, tokenSeed, wantedSeed, level, mergeReady, difference, payMode, 0);
        if (id != 0) _fillSwap(takerSeed, id, takerSeed / 7);
    }

    function _createSwap(GhostOrder memory o, uint64 duration, bool ok) internal returns (uint256) {
        uint256 expectedId = escrow.nextOrderId();
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(o.maker);
        try escrow.createSwap(
            o.tokenId, o.wantedTokenId, o.level, o.mergeReady, o.amount, o.sqkFromTaker, duration
        ) returns (
            uint256 id
        ) {
            _check(ok, true, "createSwap");
            if (id != expectedId) _fail("createSwap: id not nextOrderId");
            if (sqk.balanceOf(address(escrow)) != escrowBefore + o.amount) _fail("createSwap: wrong escrow amount");
            ghost[id] = o;
            _push(id, ghost[id].kind);
            ghostOwed += o.amount;
            ghostEscrowedIn += o.amount;
            ghostMakerIn[o.maker] += o.amount;
            ++calls["createSwap"];
            return id;
        } catch {
            _check(ok, false, "createSwap");
        }
        return 0;
    }

    function fillSwap(uint256 actorSeed, uint256 orderSeed, uint256 tokenSeed) external {
        _fillSwap(actorSeed, _orderIdOf(SWAP, orderSeed), tokenSeed);
    }

    function _fillSwap(uint256 actorSeed, uint256 id, uint256 tokenSeed) internal {
        GhostOrder storage g = ghost[id];
        // Mostly offer the wanted token when the swap names one.
        uint256 tokenId =
            g.wantedTokenId != 0 && tokenSeed % 4 != 0 ? g.wantedTokenId : _tokenFor(tokenSeed, g.level, g.maker);
        address taker = actorSeed % 4 == 0 ? _actor(actorSeed / 4) : nft.ownerOf(tokenId);
        bool ok = g.kind == SWAP && _liveOpen(g) && taker != g.maker
            && (g.wantedTokenId == 0 || g.wantedTokenId == tokenId) && _makerSideOk(g)
            && _ownsAndApproved(tokenId, taker) && _matches(tokenId, g.level, g.mergeReady)
            && sqk.balanceOf(taker) >= g.sqkFromTaker;
        uint256 takerBefore = sqk.balanceOf(taker);
        uint256 makerBefore = sqk.balanceOf(g.maker);
        uint256 escrowBefore = sqk.balanceOf(address(escrow));

        vm.prank(taker);
        try escrow.fillSwap(id, tokenId) {
            _check(ok, true, "fillSwap");
            g.status = FILLED;
            ++ghostTrades[g.tokenId];
            ++ghostTrades[tokenId];
            ghostOwed -= g.amount;
            ghostEscrowedOut += g.amount;
            if (nft.ownerOf(tokenId) != g.maker) _fail("fillSwap: maker did not get taker's Squeek");
            if (nft.ownerOf(g.tokenId) != taker) _fail("fillSwap: taker did not get maker's Squeek");
            if (sqk.balanceOf(taker) != takerBefore + g.amount - g.sqkFromTaker) _fail("fillSwap: taker SQK wrong");
            if (sqk.balanceOf(g.maker) != makerBefore + g.sqkFromTaker) _fail("fillSwap: maker SQK wrong");
            if (sqk.balanceOf(address(escrow)) != escrowBefore - g.amount) _fail("fillSwap: escrow SQK wrong");
            ++calls["fillSwap"];
        } catch {
            _check(ok, false, "fillSwap");
        }
    }

    function cancelSwap(uint256 actorSeed, uint256 orderSeed) external {
        uint256 id = _orderIdOf(SWAP, orderSeed, false);
        GhostOrder storage g = ghost[id];
        address caller = actorSeed % 2 == 0 && g.maker != address(0) ? g.maker : _actor(actorSeed);
        bool ok = g.kind == SWAP && g.status == OPEN && (caller == g.maker || block.timestamp >= g.expiresAt);
        uint256 makerBefore = sqk.balanceOf(g.maker);
        uint256 callerBefore = sqk.balanceOf(caller);

        vm.prank(caller);
        try escrow.cancelSwap(id) {
            _check(ok, true, "cancelSwap");
            g.status = CANCELLED;
            ghostOwed -= g.amount;
            ghostEscrowedOut += g.amount;
            ghostMakerRefunded[g.maker] += g.amount;
            if (sqk.balanceOf(g.maker) != makerBefore + g.amount) _fail("cancelSwap: maker refund wrong");
            if (caller != g.maker && sqk.balanceOf(caller) != callerBefore) _fail("cancelSwap: caller got SQK");
            ++calls["cancelSwap"];
        } catch {
            _check(ok, false, "cancelSwap");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The outside world
    // ---------------------------------------------------------------------------------------------

    /// @dev Mostly short steps so orders are often still live; sometimes a jump past any expiry.
    function warp(uint256 seconds_) external {
        vm.warp(
            block.timestamp + (seconds_ % 16 == 0 ? bound(seconds_, 7 days, 31 days) : bound(seconds_, 1, 12 hours))
        );
    }

    /// @dev Changes a Squeek's live position: sometimes no live position or a new level (a merge or burn),
    /// otherwise the same level with a pending power change or a cooldown the core height may not have reached.
    function setPosition(uint256 tokenSeed, uint8 level, uint40 pendingRound, uint48 nextMergeBlock) external {
        uint256 tokenId = _token(tokenSeed);
        uint8 current = mining.position(0, tokenId).level;
        if (level % 8 == 0) level = 0;
        else if (level % 8 == 4 || current == 0) level = uint8(bound(level, 1, MAX_LEVEL));
        else level = current;
        pendingRound = pendingRound % 4 == 0 ? pendingRound : 0;
        nextMergeBlock = uint48(bound(nextMergeBlock, 0, 130));
        mining.setPosition(tokenId, level, pendingRound, nextMergeBlock);
    }

    /// @dev Moves the collection's maximum level (a policy change), mostly back to the default.
    function setMaximumLevel(uint8 maximum) external {
        mining.setMaximumLevel(maximum % 8 == 0 ? uint8(bound(maximum, 2, MAX_LEVEL)) : MAX_LEVEL);
    }

    function setCoreHeight(uint64 height) external {
        core.setBlockHeight(uint64(bound(height, 80, 140)));
    }

    function transferSqueek(uint256 tokenSeed, uint256 toSeed) external {
        uint256 tokenId = _token(tokenSeed);
        address from = nft.ownerOf(tokenId);
        address to = _actor(toSeed);
        vm.prank(from);
        nft.transferFrom(from, to, tokenId);
    }

    /// @dev Revokes a quarter of the time, re-approves otherwise.
    function setApprovalForAll(uint256 actorSeed, uint8 mode) external {
        vm.prank(_actor(actorSeed));
        nft.setApprovalForAll(address(escrow), mode % 4 != 0);
    }

    function approveOne(uint256 tokenSeed, bool approveEscrow) external {
        uint256 tokenId = _token(tokenSeed);
        vm.prank(nft.ownerOf(tokenId));
        nft.approve(approveEscrow ? address(escrow) : address(0), tokenId);
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address from = _actor(actorSeed);
        amount = bound(amount, 0, sqk.balanceOf(from) / 100);
        vm.prank(from);
        sqk.transfer(address(escrow), amount);
        ghostDonated += amount;
    }
}

contract SqueekMatchEscrowInvariantTest is Test {
    MockSQK internal sqk;
    MockSqueekCore internal core;
    MockSqueekMining internal mining;
    MockSqueekNFT internal nft;
    SqueekMatchEscrow internal escrow;
    EscrowHandler internal handler;

    uint256 internal constant INITIAL_SQK = 1_000_000 ether;
    uint256 internal totalSqk;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        sqk = new MockSQK();
        core = new MockSqueekCore();
        mining = new MockSqueekMining(address(core));
        nft = new MockSqueekNFT(address(mining));
        mining.setNft(address(nft));
        escrow = new SqueekMatchEscrow(address(nft), address(sqk));
        handler = new EscrowHandler(escrow, sqk, nft, mining, core);
        core.setBlockHeight(100);

        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            sqk.mint(a, INITIAL_SQK);
            vm.startPrank(a);
            sqk.approve(address(escrow), type(uint256).max);
            nft.setApprovalForAll(address(escrow), true);
            vm.stopPrank();
        }
        totalSqk = n * INITIAL_SQK;
        for (uint256 t = 1; t <= 12; ++t) {
            nft.mint(handler.actors(t % n), t);
            mining.setPosition(t, uint8((t % 4) + 1), 0, 0);
        }

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCallBehavedAsModelled() public view {
        assertEq(handler.violation(), "", handler.violation());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_escrowHoldsExactlyWhatOpenOrdersAreOwed() public view {
        // Recomputed from the contract's own storage, not from the handler's running total.
        uint256 owedFromStorage;
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.orderIds(i);
            SqueekMatchEscrow.Kind kind = escrow.kindOf(id);
            if (kind == SqueekMatchEscrow.Kind.Bid) {
                (,, SqueekMatchEscrow.Status s,,, uint256 amount) = escrow.bids(id);
                if (s == SqueekMatchEscrow.Status.Open) owedFromStorage += amount;
            } else if (kind == SqueekMatchEscrow.Kind.Swap) {
                (,, SqueekMatchEscrow.Status s,,,,,, uint256 fromMaker,,) = escrow.swaps(id);
                if (s == SqueekMatchEscrow.Status.Open) owedFromStorage += fromMaker;
            }
        }
        assertEq(owedFromStorage, handler.ghostOwed(), "storage liabilities != ghost liabilities");
        assertEq(sqk.balanceOf(address(escrow)), owedFromStorage + handler.ghostDonated(), "escrow balance != owed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_paidOutNeverExceedsPaidIn() public view {
        assertLe(handler.ghostEscrowedOut(), handler.ghostEscrowedIn(), "escrow paid out more than was escrowed");
        assertEq(handler.ghostEscrowedIn() - handler.ghostEscrowedOut(), handler.ghostOwed());
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertLe(handler.ghostMakerRefunded(a), handler.ghostMakerIn(a), "maker refunded more than escrowed");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_sqkAndSqueeksConserved() public view {
        uint256 sum = sqk.balanceOf(address(escrow));
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += sqk.balanceOf(handler.actors(i));
        }
        assertEq(sum, totalSqk, "SQK created or destroyed");
        assertEq(sqk.totalSupply(), totalSqk);

        // Non-custodial: the escrow never holds a Squeek, every Squeek stays with some actor.
        assertEq(nft.balanceOf(address(escrow)), 0, "escrow holds a Squeek");
        uint256 held;
        for (uint256 i; i < n; ++i) {
            held += nft.balanceOf(handler.actors(i));
        }
        assertEq(held, 12, "Squeek lost");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_storageMatchesModelAndTerminalStatesStayTerminal() public view {
        assertEq(escrow.nextOrderId(), 1 + handler.ghostCreated(), "nextOrderId drifted");
        assertEq(uint8(escrow.kindOf(0)), 0, "id 0 used");
        assertEq(uint8(escrow.kindOf(escrow.nextOrderId())), 0, "unissued id has a kind");
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.orderIds(i);
            EscrowHandler.GhostOrder memory g = handler.ghostOrder(id);
            assertEq(uint8(escrow.kindOf(id)), g.kind, "kind");
            uint8 status;
            if (g.kind == 1) status = _checkAsk(id, g);
            else if (g.kind == 2) status = _checkBid(id, g);
            else status = _checkSwap(id, g);
            // The ghost status only moves Open -> Filled|Cancelled, so equality means no order reopened.
            assertEq(status, g.status, "status diverged from model");
            assertEq(escrow.isOpen(id), g.status == 1 && block.timestamp < g.expiresAt, "isOpen");
            assertEq(escrow.isFillable(id), handler.predictedFillable(id), "isFillable diverged from model");
        }
        for (uint256 t = 1; t <= 12; ++t) {
            assertEq(escrow.tradeCount(t), handler.ghostTrades(t), "tradeCount diverged from model");
        }
    }

    function _checkAsk(uint256 id, EscrowHandler.GhostOrder memory g) internal view returns (uint8) {
        (
            address maker,
            uint64 expiresAt,
            SqueekMatchEscrow.Status s,
            uint8 level,
            uint256 tokenId,
            uint256 price,
            uint256 tradeCountAt
        ) = escrow.asks(id);
        assertEq(maker, g.maker);
        assertEq(expiresAt, g.expiresAt);
        assertEq(level, g.makerLevel, "ask level");
        assertEq(tokenId, g.tokenId);
        assertEq(price, g.amount);
        assertEq(tradeCountAt, g.tradeCountAt, "ask tradeCount");
        return uint8(s);
    }

    function _checkBid(uint256 id, EscrowHandler.GhostOrder memory g) internal view returns (uint8) {
        (address maker, uint64 expiresAt, SqueekMatchEscrow.Status s, uint8 level, bool mr, uint256 amount) =
            escrow.bids(id);
        assertEq(maker, g.maker);
        assertEq(expiresAt, g.expiresAt);
        assertEq(level, g.level);
        assertEq(mr, g.mergeReady);
        assertEq(amount, g.amount);
        return uint8(s);
    }

    function _checkSwap(uint256 id, EscrowHandler.GhostOrder memory g) internal view returns (uint8) {
        (
            address maker,
            uint64 expiresAt,
            SqueekMatchEscrow.Status s,
            uint8 wantedLevel,
            bool mr,
            uint8 makerLevel,,,,,
        ) = escrow.swaps(id);
        assertEq(maker, g.maker);
        assertEq(expiresAt, g.expiresAt);
        assertEq(wantedLevel, g.level);
        assertEq(mr, g.mergeReady);
        assertEq(makerLevel, g.makerLevel, "swap makerLevel");
        _checkSwapAmounts(id, g);
        return uint8(s);
    }

    function _checkSwapAmounts(uint256 id, EscrowHandler.GhostOrder memory g) internal view {
        (,,,,,, uint256 makerTokenId, uint256 wanted, uint256 fromMaker, uint256 fromTaker, uint256 tradeCountAt) =
            escrow.swaps(id);
        assertEq(makerTokenId, g.tokenId);
        assertEq(wanted, g.wantedTokenId);
        assertEq(fromMaker, g.amount);
        assertEq(fromTaker, g.sqkFromTaker);
        assertEq(tradeCountAt, g.tradeCountAt, "swap tradeCount");
    }
}
