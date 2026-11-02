// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekMatchEscrow} from "../src/SqueekMatchEscrow.sol";
import {SqueekMatchEscrowTestBase} from "./SqueekMatchEscrow.t.sol";

/// @notice Edge and failure paths the main suite does not pin: unknown and cross-kind ids, exact expiry
/// boundaries for every kind, callers who are operators rather than owners, single-token approvals,
/// unreachable levels, and orders whose Squeek left and came back.
contract SqueekMatchEscrowEdgeTest is SqueekMatchEscrowTestBase {
    uint256 internal constant UNKNOWN = 999_999;

    // ---------------------------------------------------------------------------------------------
    // Unknown, zero and cross-kind ids
    // ---------------------------------------------------------------------------------------------

    function test_cancel_unknownIdsRevertForEveryKind() public {
        uint256[2] memory ids = [uint256(0), UNKNOWN];
        for (uint256 i; i < ids.length; ++i) {
            vm.startPrank(alice);
            vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, ids[i]));
            escrow.cancelAsk(ids[i]);
            vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, ids[i]));
            escrow.cancelBid(ids[i]);
            vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, ids[i]));
            escrow.cancelSwap(ids[i]);
            vm.stopPrank();
            assertFalse(escrow.isOpen(ids[i]));
        }
    }

    function test_fill_unknownIdsRevert() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, 0));
        escrow.fillAsk(0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, 0));
        escrow.fillBid(0, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, UNKNOWN));
        escrow.fillSwap(UNKNOWN, B1);
        vm.stopPrank();
    }

    /// A bid's id used on the ask or swap entry points must not release its escrow or move anything.
    function test_crossKindIds_cannotTouchAnotherKindsOrder() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 0);
        vm.prank(alice);
        uint256 askId = escrow.createAsk(A1, 10 ether, 0);
        vm.prank(carol);
        uint256 swapId = escrow.createSwap(C1, 0, 1, false, 5 ether, 0, 0);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, bidId));
        escrow.cancelSwap(bidId);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, bidId));
        escrow.cancelAsk(bidId);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, askId));
        escrow.cancelBid(askId);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, swapId));
        escrow.fillBid(swapId, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, bidId));
        escrow.fillSwap(bidId, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, swapId));
        escrow.fillAsk(swapId);
        vm.stopPrank();

        assertEq(sqk.balanceOf(address(escrow)), 105 ether);
        assertTrue(escrow.isOpen(bidId) && escrow.isOpen(askId) && escrow.isOpen(swapId));
    }

    // ---------------------------------------------------------------------------------------------
    // Expiry boundaries
    // ---------------------------------------------------------------------------------------------

    function test_bidAndSwap_fillAtExpiryReverts_lastSecondWorks() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 1 hours);
        vm.prank(alice);
        uint256 swapId = escrow.createSwap(A2, 0, 2, false, 0, 0, 1 hours);
        uint64 expiresAt = uint64(block.timestamp + 1 hours);

        vm.warp(expiresAt);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderExpired.selector, bidId, expiresAt));
        escrow.fillBid(bidId, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderExpired.selector, swapId, expiresAt));
        escrow.fillSwap(swapId, B2);
        vm.stopPrank();

        vm.warp(expiresAt - 1);
        vm.startPrank(bob);
        escrow.fillBid(bidId, B1);
        escrow.fillSwap(swapId, B2);
        vm.stopPrank();
        assertEq(nft.ownerOf(B1), alice);
        assertEq(nft.ownerOf(B2), alice);
        assertEq(nft.ownerOf(A2), bob);
    }

    function test_strangerCancel_oneSecondBeforeExpiryReverts_atExpiryWorks() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 2 days);
        uint64 expiresAt = uint64(block.timestamp + 2 days);

        vm.warp(expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotMakerAndNotExpired.selector, bidId));
        vm.prank(carol);
        escrow.cancelBid(bidId);

        vm.warp(expiresAt);
        uint256 carolBefore = sqk.balanceOf(carol);
        vm.expectEmit(true, true, false, true);
        emit SqueekMatchEscrow.BidCancelled(bidId, carol, true, 100 ether);
        vm.prank(carol);
        escrow.cancelBid(bidId);
        assertEq(sqk.balanceOf(carol), carolBefore, "stranger gets nothing");
        assertEq(sqk.balanceOf(alice), INITIAL_SQK, "maker refunded in full");
        _assertNoSqkLost();
    }

    function test_makerCancelEvents_reportExpiredFlag() public {
        vm.startPrank(alice);
        uint256 a1 = escrow.createAsk(A1, 1 ether, 0);
        uint256 s1 = escrow.createSwap(A2, 0, 2, false, 3 ether, 0, 0);

        vm.expectEmit(true, true, false, true);
        emit SqueekMatchEscrow.AskCancelled(a1, alice, false);
        escrow.cancelAsk(a1);

        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, false, true);
        emit SqueekMatchEscrow.SwapCancelled(s1, alice, true, 3 ether);
        escrow.cancelSwap(s1);
        vm.stopPrank();
        _assertNoSqkLost();
    }

    // ---------------------------------------------------------------------------------------------
    // Who may fill
    // ---------------------------------------------------------------------------------------------

    /// An operator approved for all of bob's Squeeks is still not their owner and cannot sell them.
    function test_fillBid_operatorWhoIsNotOwnerReverts() public {
        vm.prank(bob);
        nft.setApprovalForAll(carol, true);
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, B1, bob));
        vm.prank(carol);
        escrow.fillBid(bidId, B1);
        assertEq(nft.ownerOf(B1), bob);
        assertTrue(escrow.isOpen(bidId));
    }

    function test_fillBid_unmintedTokenReverts() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, UNKNOWN));
        vm.prank(bob);
        escrow.fillBid(bidId, UNKNOWN);
    }

    /// A bid is filled by a token approved on its own (no operator approval), and that approval is used up.
    function test_fillBid_withSingleTokenApprovalOnly() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 100 ether, 0);
        vm.startPrank(bob);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, B1, bob));
        escrow.fillBid(bidId, B1);
        nft.approve(address(escrow), B1);
        escrow.fillBid(bidId, B1);
        vm.stopPrank();
        assertEq(nft.ownerOf(B1), alice);
        assertEq(nft.getApproved(B1), address(0), "approval cleared by the transfer");
        assertEq(sqk.balanceOf(bob), INITIAL_SQK + 100 ether);
    }

    /// The maker's Squeek in a swap may be approved on its own; revoking it later blocks the fill and the
    /// escrowed difference stays refundable.
    function test_swap_makerSingleApprovalRevoked_blocksFill_refundStillWorks() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(escrow), false);
        nft.approve(address(escrow), A1);
        uint256 swapId = escrow.createSwap(A1, B1, 1, false, 7 ether, 0, 0);
        nft.approve(address(0), A1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        vm.prank(bob);
        escrow.fillSwap(swapId, B1);

        vm.warp(block.timestamp + 7 days);
        vm.prank(carol);
        escrow.cancelSwap(swapId);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(address(escrow)), 0);
    }

    /// A swap whose wanted Squeek is named is only filled by that Squeek's owner with that Squeek.
    function test_fillSwap_namedToken_otherOwnerOrOtherTokenReverts() public {
        vm.prank(alice);
        uint256 swapId = escrow.createSwap(A1, B1, 1, false, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.WrongToken.selector, B1, C1));
        vm.prank(carol);
        escrow.fillSwap(swapId, C1);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, B1, bob));
        vm.prank(carol);
        escrow.fillSwap(swapId, B1);

        vm.prank(bob);
        escrow.fillSwap(swapId, B1);
        assertEq(nft.ownerOf(A1), bob);
        assertEq(nft.ownerOf(B1), alice);
    }

    // ---------------------------------------------------------------------------------------------
    // Create-time validation
    // ---------------------------------------------------------------------------------------------

    /// makerTokenId 0 with ANY_SQUEEK (0) is rejected as the same token before any ownership read.
    function test_createSwap_tokenZeroWithAnyIsSameToken() public {
        vm.expectRevert(SqueekMatchEscrow.SameToken.selector);
        vm.prank(alice);
        escrow.createSwap(0, 0, 1, false, 0, 0, 0);
    }

    function test_createSwap_namedTokenNeedNotExistYet_butFillNeedsIt() public {
        vm.prank(alice);
        uint256 swapId = escrow.createSwap(A1, UNKNOWN, 1, false, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.WrongToken.selector, UNKNOWN, B1));
        vm.prank(bob);
        escrow.fillSwap(swapId, B1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, UNKNOWN));
        vm.prank(bob);
        escrow.fillSwap(swapId, UNKNOWN);
    }

    /// A level above the collection's maximum is rejected at creation, so no SQK is ever escrowed for a bid
    /// that could never fill.
    function test_bidAboveMaximumLevel_rejectedBeforeEscrow() public {
        uint8 tooHigh = mining.MAXIMUM_LEVEL() + 1;
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        vm.prank(alice);
        escrow.createBid(tooHigh, false, 100 ether, 0);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        assertEq(escrow.nextOrderId(), 1, "no id consumed");
    }

    /// The maximum level is read from the live policy: once it is lowered, levels above it are rejected.
    function test_createBid_followsALoweredMaximumLevel() public {
        mining.setMaximumLevel(5);
        vm.startPrank(alice);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createBid(6, false, 1 ether, 0);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createBid(5, true, 1 ether, 0);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createSwap(A1, 0, 6, false, 0, 0, 0);
        escrow.createBid(5, false, 1 ether, 0);
        escrow.createBid(4, true, 1 ether, 0);
        vm.stopPrank();
        assertEq(sqk.balanceOf(address(escrow)), 2 ether);
    }

    /// A merge-ready bid made below the maximum cannot be filled once the policy lowers the maximum to its
    /// level (such a Squeek can no longer merge); the escrowed SQK stays fully refundable.
    function test_mergeReadyBid_maximumLoweredToItsLevel_blocksFill_refundable() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(3, true, 40 ether, 0);
        mining.setMaximumLevel(3);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.AtMaximumLevel.selector, B3, 3));
        vm.prank(bob);
        escrow.fillBid(bidId, B3);
        assertFalse(escrow.isMergeReady(B3));
        assertEq(nft.ownerOf(B3), bob);

        vm.prank(alice);
        escrow.cancelBid(bidId);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(address(escrow)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Squeeks moving under open orders
    // ---------------------------------------------------------------------------------------------

    /// A maker who sold the listed Squeek through a bid cannot have the old ask filled against its new
    /// owner, and the bid's buyer keeps it.
    function test_askAfterSqueekSoldIntoBid_cannotTakeFromNewOwner() public {
        vm.prank(alice);
        uint256 askId = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(bob);
        uint256 bidId = escrow.createBid(1, false, 50 ether, 0);
        vm.prank(alice);
        escrow.fillBid(bidId, A1);
        assertEq(nft.ownerOf(A1), bob);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, askId, A1));
        vm.prank(carol);
        escrow.fillAsk(askId);
        assertEq(nft.ownerOf(A1), bob);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK + 50 ether);
        _assertNoSqkLost();
    }

    /// A Squeek that levelled up or lost its live position after a bid was made is judged by its level at
    /// fill, not at creation.
    function test_fillBid_usesLevelAtFill() public {
        vm.prank(alice);
        uint256 bidId = escrow.createBid(2, false, 10 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, B1, 2, 1));
        vm.prank(bob);
        escrow.fillBid(bidId, B1);

        mining.setPosition(B1, 2, 0, 0);
        mining.clearPosition(B2);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NoLivePosition.selector, B2));
        vm.prank(bob);
        escrow.fillBid(bidId, B2);

        vm.prank(bob);
        escrow.fillBid(bidId, B1);
        assertEq(nft.ownerOf(B1), alice);
    }

    /// A swap whose offered Squeek the maker sold through one of its own asks cannot fill, and the SQK it
    /// escrowed stays refundable; once the Squeek is bought back here the swap is stale, not revived.
    function test_swapWithEscrowedSqk_makerSqueekSoldAndBoughtBack_staleAndRefundable() public {
        vm.startPrank(alice);
        uint256 swapId = escrow.createSwap(A1, 0, 1, false, 25 ether, 0, 30 days);
        uint256 askId = escrow.createAsk(A1, 3 ether, 0);
        vm.stopPrank();
        vm.prank(carol);
        escrow.fillAsk(askId);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, swapId, A1));
        vm.prank(bob);
        escrow.fillSwap(swapId, B1);

        vm.prank(carol);
        uint256 backId = escrow.createAsk(A1, 4 ether, 0);
        vm.prank(alice);
        escrow.fillAsk(backId);
        assertEq(nft.ownerOf(A1), alice);
        assertTrue(escrow.isOpen(swapId));
        assertFalse(escrow.isFillable(swapId));

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.StaleOrder.selector, swapId, A1));
        vm.prank(bob);
        escrow.fillSwap(swapId, B1);
        assertEq(nft.ownerOf(B1), bob);

        uint256 aliceBefore = sqk.balanceOf(alice);
        vm.warp(block.timestamp + 30 days);
        vm.prank(bob);
        escrow.cancelSwap(swapId);
        assertEq(sqk.balanceOf(alice), aliceBefore + 25 ether, "escrowed difference refunded to the maker");
        assertEq(sqk.balanceOf(address(escrow)), 0);
        _assertNoSqkLost();
    }

    /// Selling a Squeek as the *taker* of a bid also counts as a trade: the seller's earlier swap offering
    /// that Squeek is stale even after the Squeek returns through the escrow.
    function test_takerSideTrade_makesSellersOwnSwapStale() public {
        vm.prank(bob);
        uint256 bobSwap = escrow.createSwap(B1, 0, 2, false, 0, 0, 0);
        vm.prank(alice);
        uint256 aliceBid = escrow.createBid(1, false, 10 ether, 0);
        vm.prank(bob);
        escrow.fillBid(aliceBid, B1);
        assertEq(escrow.tradeCount(B1), 1);
        vm.prank(alice);
        uint256 aliceAsk = escrow.createAsk(B1, 11 ether, 0);
        vm.prank(bob);
        escrow.fillAsk(aliceAsk);
        assertEq(nft.ownerOf(B1), bob);
        assertEq(escrow.tradeCount(B1), 2);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.StaleOrder.selector, bobSwap, B1));
        vm.prank(alice);
        escrow.fillSwap(bobSwap, A2);
        assertEq(nft.ownerOf(A2), alice);
    }

    /// forge-config: default.fuzz.runs = 1000
    /// An ask fills only while its Squeek's live level is exactly the listed one; any other live level
    /// (including 0, a cleared position) reverts with the listed and live levels, and moves nothing.
    function testFuzz_askLevelBinding(uint8 listed, uint8 live) public {
        listed = uint8(bound(listed, 1, mining.MAXIMUM_LEVEL()));
        live = uint8(bound(live, 0, mining.MAXIMUM_LEVEL()));
        mining.setPosition(A1, listed, 0, 0);
        vm.prank(alice);
        uint256 askId = escrow.createAsk(A1, 9 ether, 0);
        mining.setPosition(A1, live, 0, 0);

        assertEq(escrow.isFillable(askId), live == listed);
        if (live != listed) {
            vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, A1, listed, live));
        }
        vm.prank(bob);
        escrow.fillAsk(askId);
        assertEq(nft.ownerOf(A1), live == listed ? bob : alice);
        assertEq(sqk.balanceOf(bob), live == listed ? INITIAL_SQK - 9 ether : INITIAL_SQK);
    }

    // ---------------------------------------------------------------------------------------------
    // Escrow isolation (fuzzed)
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_escrowOnlyOwesItsOpenOrders(uint256 a, uint256 b, uint256 donation, uint8 order) public {
        a = bound(a, 1, INITIAL_SQK / 4);
        b = bound(b, 1, INITIAL_SQK / 4);
        donation = bound(donation, 0, INITIAL_SQK / 4);
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, a, 0);
        vm.prank(carol);
        uint256 swapId = escrow.createSwap(C1, 0, 2, false, b, 0, 0);
        vm.prank(bob);
        sqk.transfer(address(escrow), donation);

        if (order % 2 == 0) {
            vm.prank(bob);
            escrow.fillBid(bidId, B1);
            vm.prank(carol);
            escrow.cancelSwap(swapId);
        } else {
            vm.prank(bob);
            escrow.fillSwap(swapId, B2);
            vm.prank(alice);
            escrow.cancelBid(bidId);
        }
        // Both orders are closed; only the donation (which no order owns) is left behind.
        assertEq(sqk.balanceOf(address(escrow)), donation);
        assertEq(sqk.balanceOf(alice) + sqk.balanceOf(carol) + sqk.balanceOf(bob), 3 * INITIAL_SQK - donation);
        assertEq(sqk.balanceOf(alice), order % 2 == 0 ? INITIAL_SQK - a : INITIAL_SQK);
        assertEq(sqk.balanceOf(carol), order % 2 == 0 ? INITIAL_SQK : INITIAL_SQK - b);
    }
}
