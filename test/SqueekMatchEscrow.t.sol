// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SqueekMatchEscrow} from "../src/SqueekMatchEscrow.sol";
import {ISqueekMining} from "../src/interfaces/ISqueekchain.sol";
import {MockSQK, MockSqueekCore, MockSqueekMining, MockSqueekNFT} from "./mocks/SqueekchainMocks.sol";
import {
    ClaimingSwapMaker,
    NonReceiver,
    ReentrantAskTaker,
    ReentrantBidMaker,
    ReentrantSwapMaker
} from "./mocks/Attackers.sol";

contract SqueekMatchEscrowTestBase is Test {
    MockSQK internal sqk;
    MockSqueekCore internal core;
    MockSqueekMining internal mining;
    MockSqueekNFT internal nft;
    SqueekMatchEscrow internal escrow;

    address internal alice = makeAddr("alice"); // typical maker
    address internal bob = makeAddr("bob"); // typical taker
    address internal carol = makeAddr("carol"); // bystander
    address internal factory = makeAddr("factory"); // deploys the escrow, must get no power

    uint256 internal constant A1 = 11; // alice's level-1 Squeek
    uint256 internal constant A2 = 12; // alice's level-2 Squeek
    uint256 internal constant B1 = 21; // bob's level-1 Squeek
    uint256 internal constant B2 = 22; // bob's level-2 Squeek
    uint256 internal constant B3 = 23; // bob's level-3 Squeek
    uint256 internal constant C1 = 31; // carol's level-1 Squeek
    uint256 internal constant INITIAL_SQK = 1_000_000 ether;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        sqk = new MockSQK();
        core = new MockSqueekCore();
        mining = new MockSqueekMining(address(core));
        nft = new MockSqueekNFT(address(mining));
        mining.setNft(address(nft));
        vm.prank(factory);
        escrow = new SqueekMatchEscrow(address(nft), address(sqk));

        core.setBlockHeight(100);
        _mintSqueek(alice, A1, 1);
        _mintSqueek(alice, A2, 2);
        _mintSqueek(bob, B1, 1);
        _mintSqueek(bob, B2, 2);
        _mintSqueek(bob, B3, 3);
        _mintSqueek(carol, C1, 1);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            sqk.mint(users[i], INITIAL_SQK);
            vm.startPrank(users[i]);
            sqk.approve(address(escrow), type(uint256).max);
            nft.setApprovalForAll(address(escrow), true);
            vm.stopPrank();
        }
    }

    /// @dev Mints a Squeek whose position is live, at `level`, with no pending power and cooldown reached.
    function _mintSqueek(address to, uint256 tokenId, uint8 level) internal {
        nft.mint(to, tokenId);
        mining.setPosition(tokenId, level, 0, 0);
    }

    function _totalSqk() internal view returns (uint256) {
        return sqk.balanceOf(alice) + sqk.balanceOf(bob) + sqk.balanceOf(carol) + sqk.balanceOf(address(escrow));
    }

    function _assertNoSqkLost() internal view {
        assertEq(_totalSqk(), 3 * INITIAL_SQK, "SQK conservation");
    }
}

// =================================================================================================
// Deployment
// =================================================================================================

contract SqueekMatchEscrowDeployTest is SqueekMatchEscrowTestBase {
    function test_constructor_setsImmutables() public view {
        assertEq(address(escrow.SQUEEK()), address(nft));
        assertEq(address(escrow.SQK()), address(sqk));
        assertEq(address(escrow.mining()), address(mining));
        assertEq(escrow.nextOrderId(), 1);
        assertEq(escrow.DEFAULT_DURATION(), 7 days);
        assertEq(escrow.MAX_DURATION(), 30 days);
        assertEq(escrow.SQUEEKS_COLLECTION(), 0);
        assertEq(escrow.ANY_SQUEEK(), 0);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SqueekMatchEscrow.ZeroAddress.selector);
        new SqueekMatchEscrow(address(0), address(sqk));
        vm.expectRevert(SqueekMatchEscrow.ZeroAddress.selector);
        new SqueekMatchEscrow(address(nft), address(0));
    }

    function test_constructor_makesNoExternalCall() public {
        // Addresses with no code at all: the constructor must still succeed (launch rehearses on an empty chain).
        address bareNft = makeAddr("bare-nft");
        address bareSqk = makeAddr("bare-sqk");
        SqueekMatchEscrow e = new SqueekMatchEscrow(bareNft, bareSqk);
        assertEq(address(e.SQUEEK()), bareNft);
        assertEq(address(e.SQK()), bareSqk);
    }

    function test_noOwnerOrAdminSurface() public view {
        // There is no owner(): a call to the Ownable selector must not succeed.
        (bool ok,) = address(escrow).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner() must not exist");
        assertEq(address(escrow).balance, 0);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(escrow).code.length, 24_576);
    }
}

// =================================================================================================
// Asks
// =================================================================================================

contract SqueekMatchEscrowAskTest is SqueekMatchEscrowTestBase {
    function test_createAsk_success() public {
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.AskCreated(1, alice, A1, 1, 500 ether, uint64(block.timestamp + 7 days));
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 500 ether, 0);

        assertEq(id, 1);
        assertEq(uint8(escrow.kindOf(id)), uint8(SqueekMatchEscrow.Kind.Ask));
        (
            address maker,
            uint64 expiresAt,
            SqueekMatchEscrow.Status status,
            uint8 level,
            uint256 tokenId,
            uint256 price,
            uint256 tradeCountAt
        ) = escrow.asks(id);
        assertEq(maker, alice);
        assertEq(expiresAt, block.timestamp + 7 days);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Open));
        assertEq(level, 1, "level recorded at listing");
        assertEq(tokenId, A1);
        assertEq(price, 500 ether);
        assertEq(tradeCountAt, 0, "trade count recorded at listing");
        assertEq(nft.ownerOf(A1), alice, "Squeek stays in the maker's wallet");
        assertTrue(escrow.isOpen(id));
        assertTrue(escrow.isFillable(id));
        assertEq(escrow.nextOrderId(), 2);
    }

    function test_createAsk_recordsCurrentLevelAndTradeCount() public {
        mining.setPosition(A2, 7, 0, 0);
        vm.prank(alice);
        uint256 id = escrow.createAsk(A2, 1 ether, 0);
        (,,, uint8 level,,,) = escrow.asks(id);
        assertEq(level, 7);

        // After the Squeek has traded through the escrow once, a new listing records the new count.
        vm.prank(bob);
        escrow.fillAsk(id);
        assertEq(escrow.tradeCount(A2), 1);
        vm.prank(bob);
        uint256 relist = escrow.createAsk(A2, 2 ether, 0);
        (,,,,,, uint256 tradeCountAt) = escrow.asks(relist);
        assertEq(tradeCountAt, 1);
        assertTrue(escrow.isFillable(relist));
    }

    function test_createAsk_revertsNoLivePosition() public {
        mining.clearPosition(A1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NoLivePosition.selector, A1));
        vm.prank(alice);
        escrow.createAsk(A1, 1 ether, 0);
    }

    function test_createAsk_customAndMaxDuration() public {
        vm.startPrank(alice);
        uint256 id1 = escrow.createAsk(A1, 1, 1 days);
        uint256 id2 = escrow.createAsk(A2, 1, 30 days);
        vm.stopPrank();
        (, uint64 e1,,,,,) = escrow.asks(id1);
        (, uint64 e2,,,,,) = escrow.asks(id2);
        assertEq(e1, block.timestamp + 1 days);
        assertEq(e2, block.timestamp + 30 days);
    }

    function test_createAsk_revertsDurationTooLong() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.DurationTooLong.selector, 30 days + 1, 30 days));
        vm.prank(alice);
        escrow.createAsk(A1, 1, 30 days + 1);
    }

    function test_createAsk_revertsZeroPrice() public {
        vm.expectRevert(SqueekMatchEscrow.ZeroAmount.selector);
        vm.prank(alice);
        escrow.createAsk(A1, 0, 0);
    }

    function test_createAsk_revertsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, B1, bob));
        vm.prank(alice);
        escrow.createAsk(B1, 1, 0);
    }

    function test_createAsk_revertsNonexistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        vm.prank(alice);
        escrow.createAsk(999, 1, 0);
    }

    function test_createAsk_revertsWithoutApproval() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        escrow.createAsk(A1, 1, 0);
        // A single-token approval is enough.
        nft.approve(address(escrow), A1);
        escrow.createAsk(A1, 1, 0);
        vm.stopPrank();
    }

    function test_fillAsk_success() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 500 ether, 0);

        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.AskFilled(id, bob, alice, A1, 500 ether);
        vm.prank(bob);
        escrow.fillAsk(id);

        assertEq(nft.ownerOf(A1), bob);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK + 500 ether);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK - 500 ether);
        assertEq(sqk.balanceOf(address(escrow)), 0, "asks never escrow anything");
        (,, SqueekMatchEscrow.Status status,,,,) = escrow.asks(id);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Filled));
        assertFalse(escrow.isOpen(id));
        assertFalse(escrow.isFillable(id));
        assertEq(escrow.tradeCount(A1), 1, "fill counts one trade of the Squeek");
        _assertNoSqkLost();
    }

    function test_fillAsk_revertsWhenMakerMergedIntoTheListedSqueek() public {
        // Alice lists her lone level-1 Squeek, finds a partner elsewhere and merges A2 into A1 as survivor.
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 100 ether, 0);
        // SqueekMining.merge keeps the survivor's id and owner, raises its level and burns only the donor: no
        // ERC-721 transfer touches A1, so the escrow's approval for it survives and the ask is still Open.
        nft.burn(A2);
        mining.clearPosition(A2);
        mining.setPosition(A1, 2, 0, 0);
        assertTrue(escrow.isOpen(id));
        assertFalse(escrow.isFillable(id), "isFillable sees the level change");

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, A1, 1, 2));
        vm.prank(bob);
        escrow.fillAsk(id);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK);

        // The maker relists at the new level and that listing fills.
        vm.startPrank(alice);
        escrow.cancelAsk(id);
        uint256 relist = escrow.createAsk(A1, 300 ether, 0);
        vm.stopPrank();
        (,,, uint8 level,,,) = escrow.asks(relist);
        assertEq(level, 2);
        vm.prank(bob);
        escrow.fillAsk(relist);
        assertEq(nft.ownerOf(A1), bob);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK + 300 ether);
    }

    function test_fillAsk_revertsAfterTheSqueekTradedHereAndCameBack() public {
        // Alice lists A1 for 1 SQK (and forgets it), sells A1 into Bob's 5 SQK bid, then buys it back from Bob's
        // 6 SQK ask. Her forgotten listing must not revive under her standing setApprovalForAll.
        vm.prank(alice);
        uint256 oldAsk = escrow.createAsk(A1, 1 ether, 30 days);
        vm.prank(bob);
        uint256 bobBid = escrow.createBid(1, false, 5 ether, 0);
        vm.prank(alice);
        escrow.fillBid(bobBid, A1);
        assertEq(nft.ownerOf(A1), bob);
        assertEq(escrow.tradeCount(A1), 1);
        assertFalse(escrow.isFillable(oldAsk));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, oldAsk, A1));
        vm.prank(carol);
        escrow.fillAsk(oldAsk);

        vm.prank(bob);
        uint256 bobAsk = escrow.createAsk(A1, 6 ether, 0);
        vm.prank(alice);
        escrow.fillAsk(bobAsk);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(escrow.tradeCount(A1), 2);
        assertTrue(escrow.isOpen(oldAsk), "status alone still says Open");
        assertFalse(escrow.isFillable(oldAsk), "but the order is stale");

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.StaleOrder.selector, oldAsk, A1));
        vm.prank(carol);
        escrow.fillAsk(oldAsk);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(sqk.balanceOf(carol), INITIAL_SQK);

        // The maker can still cancel the stale order, and a fresh listing fills normally.
        vm.startPrank(alice);
        escrow.cancelAsk(oldAsk);
        uint256 fresh = escrow.createAsk(A1, 7 ether, 0);
        vm.stopPrank();
        vm.prank(carol);
        escrow.fillAsk(fresh);
        assertEq(nft.ownerOf(A1), carol);
        _assertNoSqkLost();
    }

    function test_fillAsk_revertsAfterTheSqueekTradedHereViaSwapAndCameBack() public {
        // Same revival through swaps: A1 leaves in a swap and returns in another swap.
        vm.prank(alice);
        uint256 oldAsk = escrow.createAsk(A1, 1 ether, 30 days);
        vm.prank(bob);
        uint256 swap1 = escrow.createSwap(B1, A1, 1, false, 0, 0, 0);
        vm.prank(alice);
        escrow.fillSwap(swap1, A1);
        assertEq(nft.ownerOf(A1), bob);
        vm.prank(alice);
        uint256 swap2 = escrow.createSwap(B1, A1, 1, false, 0, 0, 0);
        vm.prank(bob);
        escrow.fillSwap(swap2, A1);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(escrow.tradeCount(A1), 2);
        assertEq(escrow.tradeCount(B1), 2);

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.StaleOrder.selector, oldAsk, A1));
        vm.prank(carol);
        escrow.fillAsk(oldAsk);
        assertEq(nft.ownerOf(A1), alice);
    }

    function test_fillAsk_transferOutsideTheEscrowAndBackStillNeedsCancel() public {
        // Documented limit: a transfer the escrow does not perform does not bump the trade count. The maker
        // must cancel; until then the live checks (owner, approval, level) are all that protect the order.
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(alice);
        nft.transferFrom(alice, carol, A1);
        vm.prank(carol);
        nft.transferFrom(carol, alice, A1);
        assertEq(escrow.tradeCount(A1), 0);
        assertTrue(escrow.isFillable(id));
        vm.prank(alice);
        escrow.cancelAsk(id);
        assertFalse(escrow.isFillable(id));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_fillAsk_atLastSecondBeforeExpiry() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(bob);
        escrow.fillAsk(id);
        assertEq(nft.ownerOf(A1), bob);
    }

    function test_fillAsk_revertsExpired() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        vm.warp(expiresAt);
        assertFalse(escrow.isOpen(id));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderExpired.selector, id, expiresAt));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_fillAsk_revertsTwice() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(bob);
        escrow.fillAsk(id);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(carol);
        escrow.fillAsk(id);
    }

    function test_fillAsk_revertsUnknownAndWrongKindId() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, 42));
        vm.prank(bob);
        escrow.fillAsk(42);
        // A bid id is not an ask id.
        vm.prank(alice);
        uint256 bidId = escrow.createBid(1, false, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, bidId));
        vm.prank(bob);
        escrow.fillAsk(bidId);
    }

    function test_fillAsk_revertsSelfTrade() public {
        vm.startPrank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.expectRevert(SqueekMatchEscrow.SelfTrade.selector);
        escrow.fillAsk(id);
        vm.stopPrank();
    }

    function test_fillAsk_revertsWhenMakerTransferredTheSqueek() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(alice);
        nft.transferFrom(alice, carol, A1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, id, A1));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_fillAsk_revertsWhenSqueekWasBurned() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        nft.burn(A1); // e.g. the maker used it as a merge donor
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, A1));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_fillAsk_revertsWhenMakerRevokedApproval() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(alice);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_fillAsk_revertsWhenTakerCannotPay() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, INITIAL_SQK + 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, INITIAL_SQK, INITIAL_SQK + 1)
        );
        vm.prank(bob);
        escrow.fillAsk(id);
        assertEq(nft.ownerOf(A1), alice);
    }

    function test_fillAsk_revertsWhenTakerDidNotApproveSqk() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.startPrank(bob);
        sqk.approve(address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, 1 ether)
        );
        escrow.fillAsk(id);
        vm.stopPrank();
    }

    function test_fillAsk_revertsWhenTakerCannotReceiveSqueeks() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        NonReceiver taker = new NonReceiver();
        sqk.mint(address(taker), 1 ether);
        vm.prank(address(taker));
        sqk.approve(address(escrow), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(taker)));
        vm.prank(address(taker));
        escrow.fillAsk(id);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(sqk.balanceOf(address(taker)), 1 ether, "whole fill reverted");
    }

    function test_cancelAsk_byMaker() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.AskCancelled(id, alice, false);
        vm.prank(alice);
        escrow.cancelAsk(id);
        (,, SqueekMatchEscrow.Status status,,,,) = escrow.asks(id);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Cancelled));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(bob);
        escrow.fillAsk(id);
    }

    function test_cancelAsk_byOtherOnlyAfterExpiry() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotMakerAndNotExpired.selector, id));
        vm.prank(bob);
        escrow.cancelAsk(id);

        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.AskCancelled(id, bob, true);
        vm.prank(bob);
        escrow.cancelAsk(id);
    }

    function test_cancelAsk_revertsWhenNotOpen() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(alice);
        escrow.cancelAsk(id);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelAsk(id);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, 77));
        vm.prank(alice);
        escrow.cancelAsk(77);
    }

    function test_cancelAsk_filledCannotBeCancelled() public {
        vm.prank(alice);
        uint256 id = escrow.createAsk(A1, 1 ether, 0);
        vm.prank(bob);
        escrow.fillAsk(id);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelAsk(id);
    }

    function test_sameSqueekCanBeListedTwice_onlyOneFills() public {
        vm.startPrank(alice);
        uint256 id1 = escrow.createAsk(A1, 1 ether, 0);
        uint256 id2 = escrow.createAsk(A1, 2 ether, 0);
        vm.stopPrank();
        vm.prank(bob);
        escrow.fillAsk(id1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, id2, A1));
        vm.prank(carol);
        escrow.fillAsk(id2);
        // Stale listing can be cleaned up by anyone once expired.
        vm.warp(block.timestamp + 7 days);
        vm.prank(carol);
        escrow.cancelAsk(id2);
    }
}

// =================================================================================================
// Bids
// =================================================================================================

contract SqueekMatchEscrowBidTest is SqueekMatchEscrowTestBase {
    function test_createBid_success_escrowsSqk() public {
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.BidCreated(1, alice, 2, true, 300 ether, uint64(block.timestamp + 7 days));
        vm.prank(alice);
        uint256 id = escrow.createBid(2, true, 300 ether, 0);

        assertEq(uint8(escrow.kindOf(id)), uint8(SqueekMatchEscrow.Kind.Bid));
        (
            address maker,
            uint64 expiresAt,
            SqueekMatchEscrow.Status status,
            uint8 level,
            bool mergeReady,
            uint256 amount
        ) = escrow.bids(id);
        assertEq(maker, alice);
        assertEq(expiresAt, block.timestamp + 7 days);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Open));
        assertEq(level, 2);
        assertTrue(mergeReady);
        assertEq(amount, 300 ether);
        assertEq(sqk.balanceOf(address(escrow)), 300 ether);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK - 300 ether);
        _assertNoSqkLost();
    }

    function test_createBid_revertsZeroAmount() public {
        vm.expectRevert(SqueekMatchEscrow.ZeroAmount.selector);
        vm.prank(alice);
        escrow.createBid(1, false, 0, 0);
    }

    function test_createBid_revertsLevelZero() public {
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        vm.prank(alice);
        escrow.createBid(0, false, 1 ether, 0);
    }

    function test_createBid_revertsLevelNoSqueekCanHave() public {
        uint8 max = mining.MAXIMUM_LEVEL();
        vm.startPrank(alice);
        // Above the collection's maximum level: no Squeek could ever match.
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createBid(max + 1, false, 1 ether, 0);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createBid(type(uint8).max, true, 1 ether, 0);
        // Merge-ready at the maximum level: a Squeek there can never merge.
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createBid(max, true, 1 ether, 0);
        // The boundaries that are satisfiable are accepted.
        escrow.createBid(max, false, 1 ether, 0);
        escrow.createBid(max - 1, true, 1 ether, 0);
        vm.stopPrank();
        assertEq(escrow.nextOrderId(), 3, "exactly the two valid bids were created");
        assertEq(sqk.balanceOf(address(escrow)), 2 ether, "nothing escrowed for the rejected bids");
    }

    function test_createBid_revertsDurationTooLong() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.DurationTooLong.selector, 31 days, 30 days));
        vm.prank(alice);
        escrow.createBid(1, false, 1 ether, 31 days);
    }

    function test_createBid_revertsWithoutSqkAllowanceOrBalance() public {
        vm.startPrank(alice);
        sqk.approve(address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, 1 ether)
        );
        escrow.createBid(1, false, 1 ether, 0);
        sqk.approve(address(escrow), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_SQK, INITIAL_SQK + 1)
        );
        escrow.createBid(1, false, INITIAL_SQK + 1, 0);
        vm.stopPrank();
        assertEq(escrow.nextOrderId(), 1, "nothing created");
    }

    function test_fillBid_success_levelOnly() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(2, false, 300 ether, 0);
        // Not merge-ready (cooldown far in the future) but the bid does not ask for it.
        mining.setPosition(B2, 2, 0, 10_000);

        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.BidFilled(id, bob, B2, alice, 300 ether);
        vm.prank(bob);
        escrow.fillBid(id, B2);

        assertEq(nft.ownerOf(B2), alice);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK + 300 ether);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK - 300 ether);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        (,, SqueekMatchEscrow.Status status,,,) = escrow.bids(id);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Filled));
        _assertNoSqkLost();
    }

    function test_fillBid_success_mergeReady() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, true, 100 ether, 0);
        mining.setPosition(B1, 1, 0, 100); // cooldown exactly reached at height 100
        assertTrue(escrow.isMergeReady(B1));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        assertEq(nft.ownerOf(B1), alice);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK + 100 ether);
    }

    function test_fillBid_revertsLevelMismatch() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(2, false, 100 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, B1, 2, 1));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, B3, 2, 3));
        vm.prank(bob);
        escrow.fillBid(id, B3);
    }

    function test_fillBid_revertsNoLivePosition() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        mining.clearPosition(B1); // the NFT exists but mining knows no live position
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NoLivePosition.selector, B1));
        vm.prank(bob);
        escrow.fillBid(id, B1);
    }

    function test_fillBid_revertsNotTokenOwner() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, C1, carol));
        vm.prank(bob);
        escrow.fillBid(id, C1);
    }

    function test_fillBid_revertsWithoutNftApproval() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.startPrank(bob);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, B1, bob));
        escrow.fillBid(id, B1);
        vm.stopPrank();
    }

    function test_fillBid_mergeReady_revertsPowerChangePending() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, true, 100 ether, 0);
        mining.setPosition(B1, 1, 55, 0);
        assertFalse(escrow.isMergeReady(B1));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.PowerChangePending.selector, B1, 55));
        vm.prank(bob);
        escrow.fillBid(id, B1);
    }

    function test_fillBid_mergeReady_revertsCooldownActive() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, true, 100 ether, 0);
        mining.setPosition(B1, 1, 0, 101); // height is 100
        assertFalse(escrow.isMergeReady(B1));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.CooldownActive.selector, B1, 101, 100));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        // Completed Squeek blocks, not time, end the cooldown.
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.CooldownActive.selector, B1, 101, 100));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        core.setBlockHeight(101);
        assertTrue(escrow.isMergeReady(B1));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        assertEq(nft.ownerOf(B1), alice);
    }

    function test_fillBid_mergeReady_revertsAtMaximumLevel() public {
        uint8 max = mining.MAXIMUM_LEVEL();
        // A merge-ready bid at the maximum level cannot be created while the maximum is `max`. If Squeekchain
        // later lowers the maximum under an open merge-ready bid, the fill still refuses a Squeek that can no
        // longer merge.
        mining.setMaximumLevel(max + 1);
        vm.prank(alice);
        uint256 id = escrow.createBid(max, true, 100 ether, 0);
        mining.setMaximumLevel(max);
        _mintSqueek(bob, 99, max);
        assertFalse(escrow.isMergeReady(99));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.AtMaximumLevel.selector, 99, max));
        vm.prank(bob);
        escrow.fillBid(id, 99);
        // The same Squeek fills a plain (non merge-ready) bid at the maximum level.
        vm.prank(alice);
        uint256 plain = escrow.createBid(max, false, 100 ether, 0);
        vm.prank(bob);
        escrow.fillBid(plain, 99);
        assertEq(nft.ownerOf(99), alice);
    }

    function test_fillBid_revertsExpired() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        vm.warp(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderExpired.selector, id, expiresAt));
        vm.prank(bob);
        escrow.fillBid(id, B1);
    }

    function test_fillBid_revertsSelfTrade() public {
        vm.startPrank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.expectRevert(SqueekMatchEscrow.SelfTrade.selector);
        escrow.fillBid(id, A1);
        vm.stopPrank();
    }

    function test_fillBid_revertsTwice_secondSellerKeepsSqueek() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.prank(bob);
        escrow.fillBid(id, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(carol);
        escrow.fillBid(id, C1);
        assertEq(nft.ownerOf(C1), carol);
        _assertNoSqkLost();
    }

    function test_fillBid_revertsWhenMakerCannotReceiveSqueeks() public {
        NonReceiver maker = new NonReceiver();
        sqk.mint(address(maker), 10 ether);
        vm.startPrank(address(maker));
        sqk.approve(address(escrow), 10 ether);
        uint256 id = escrow.createBid(1, false, 10 ether, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(maker)));
        vm.prank(bob);
        escrow.fillBid(id, B1);
        // The maker can still get the escrowed SQK back.
        vm.prank(address(maker));
        escrow.cancelBid(id);
        assertEq(sqk.balanceOf(address(maker)), 10 ether);
    }

    function test_cancelBid_byMaker_refunds() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.BidCancelled(id, alice, false, 100 ether);
        vm.prank(alice);
        escrow.cancelBid(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        (,, SqueekMatchEscrow.Status status,,,) = escrow.bids(id);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Cancelled));
        _assertNoSqkLost();
    }

    function test_cancelBid_byOtherAfterExpiry_refundsMaker() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 3 days);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotMakerAndNotExpired.selector, id));
        vm.prank(carol);
        escrow.cancelBid(id);

        vm.warp(block.timestamp + 3 days);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.BidCancelled(id, carol, true, 100 ether);
        vm.prank(carol);
        escrow.cancelBid(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK, "refund goes to the maker, not the caller");
        assertEq(sqk.balanceOf(carol), INITIAL_SQK);
    }

    function test_cancelBid_makerAfterExpiry() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.warp(block.timestamp + 40 days);
        vm.prank(alice);
        escrow.cancelBid(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
    }

    function test_cancelBid_revertsTwice_noDoubleRefund() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.prank(alice);
        escrow.cancelBid(id);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelBid(id);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(bob);
        escrow.cancelBid(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
    }

    function test_cancelBid_filledCannotBeCancelled() public {
        vm.prank(alice);
        uint256 id = escrow.createBid(1, false, 100 ether, 0);
        vm.prank(bob);
        escrow.fillBid(id, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelBid(id);
        _assertNoSqkLost();
    }

    function test_manyBids_escrowIsolated() public {
        vm.prank(alice);
        uint256 a = escrow.createBid(1, false, 100 ether, 0);
        vm.prank(carol);
        uint256 c = escrow.createBid(1, false, 250 ether, 0);
        assertEq(sqk.balanceOf(address(escrow)), 350 ether);
        vm.prank(bob);
        escrow.fillBid(c, B1);
        assertEq(sqk.balanceOf(address(escrow)), 100 ether, "alice's escrow untouched");
        vm.prank(alice);
        escrow.cancelBid(a);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        _assertNoSqkLost();
    }
}

// =================================================================================================
// Swaps
// =================================================================================================

contract SqueekMatchEscrowSwapTest is SqueekMatchEscrowTestBase {
    function test_createSwap_specificToken_makerPays() public {
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.SwapCreated(1, alice, A1, 1, B2, 2, false, 50 ether, 0, uint64(block.timestamp + 7 days));
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 50 ether, 0, 0);

        assertEq(uint8(escrow.kindOf(id)), uint8(SqueekMatchEscrow.Kind.Swap));
        (
            address maker,
            uint64 expiresAt,
            SqueekMatchEscrow.Status status,
            uint8 wantedLevel,
            bool mergeReady,
            uint8 makerLevel,
            uint256 makerTokenId,
            uint256 wantedTokenId,
            uint256 sqkFromMaker,
            uint256 sqkFromTaker,
            uint256 tradeCountAt
        ) = escrow.swaps(id);
        assertEq(maker, alice);
        assertEq(expiresAt, block.timestamp + 7 days);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Open));
        assertEq(wantedLevel, 2);
        assertFalse(mergeReady);
        assertEq(makerLevel, 1, "maker Squeek's level recorded at creation");
        assertEq(makerTokenId, A1);
        assertEq(wantedTokenId, B2);
        assertEq(sqkFromMaker, 50 ether);
        assertEq(sqkFromTaker, 0);
        assertEq(tradeCountAt, 0);
        assertEq(sqk.balanceOf(address(escrow)), 50 ether);
        assertEq(nft.ownerOf(A1), alice);
        assertTrue(escrow.isFillable(id));
    }

    function test_createSwap_anyToken_takerPays_escrowsNothing() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A2, 0, 1, true, 0, 40 ether, 10 days);
        (, uint64 expiresAt,,,, uint8 makerLevel,,,, uint256 sqkFromTaker,) = escrow.swaps(id);
        assertEq(expiresAt, block.timestamp + 10 days);
        assertEq(makerLevel, 2);
        assertEq(sqkFromTaker, 40 ether);
        assertEq(sqk.balanceOf(address(escrow)), 0);
    }

    function test_createSwap_revertsWhenMakerSqueekHasNoLivePosition() public {
        mining.clearPosition(A1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NoLivePosition.selector, A1));
        vm.prank(alice);
        escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
    }

    function test_createSwap_revertsWantedLevelNoSqueekCanHave() public {
        uint8 max = mining.MAXIMUM_LEVEL();
        vm.startPrank(alice);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createSwap(A1, 0, max + 1, false, 0, 0, 0);
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        escrow.createSwap(A1, 0, max, true, 0, 0, 0);
        escrow.createSwap(A1, 0, max, false, 0, 0, 0);
        escrow.createSwap(A1, 0, max - 1, true, 0, 0, 0);
        vm.stopPrank();
        assertEq(escrow.nextOrderId(), 3);
    }

    function test_createSwap_noDifference() public {
        vm.prank(alice);
        escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        assertEq(sqk.balanceOf(address(escrow)), 0);
    }

    function test_createSwap_revertsBothSidesPay() public {
        vm.expectRevert(SqueekMatchEscrow.BothSidesPaySqk.selector);
        vm.prank(alice);
        escrow.createSwap(A1, 0, 1, false, 1, 1, 0);
    }

    function test_createSwap_revertsSameToken() public {
        vm.expectRevert(SqueekMatchEscrow.SameToken.selector);
        vm.prank(alice);
        escrow.createSwap(A1, A1, 1, false, 0, 0, 0);
    }

    function test_createSwap_revertsLevelZero() public {
        vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
        vm.prank(alice);
        escrow.createSwap(A1, B1, 0, false, 0, 0, 0);
    }

    function test_createSwap_revertsNotOwnerOrNotApproved() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, B1, bob));
        vm.prank(alice);
        escrow.createSwap(B1, A1, 1, false, 0, 0, 0);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        escrow.createSwap(A1, B1, 1, false, 0, 0, 0);
        vm.stopPrank();
    }

    function test_createSwap_revertsDurationTooLong() public {
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.DurationTooLong.selector, 60 days, 30 days));
        vm.prank(alice);
        escrow.createSwap(A1, B1, 1, false, 0, 0, 60 days);
    }

    function test_createSwap_revertsWhenMakerCannotEscrowDifference() public {
        vm.startPrank(alice);
        sqk.approve(address(escrow), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 1 ether, 2 ether)
        );
        escrow.createSwap(A1, B1, 1, false, 2 ether, 0, 0);
        vm.stopPrank();
    }

    function test_fillSwap_specificToken_makerPaysDifference() public {
        // Alice gives her L1 plus 50 SQK for Bob's L2.
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 50 ether, 0, 0);

        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.SwapFilled(id, bob, B2, alice, A1, 50 ether, 0);
        vm.prank(bob);
        escrow.fillSwap(id, B2);

        assertEq(nft.ownerOf(A1), bob);
        assertEq(nft.ownerOf(B2), alice);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK + 50 ether);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK - 50 ether);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        (,, SqueekMatchEscrow.Status status,,,,,,,,) = escrow.swaps(id);
        assertEq(uint8(status), uint8(SqueekMatchEscrow.Status.Filled));
        assertEq(escrow.tradeCount(A1), 1, "both Squeeks count one trade");
        assertEq(escrow.tradeCount(B2), 1, "both Squeeks count one trade");
        _assertNoSqkLost();
    }

    function test_fillSwap_revertsWhenMakerMergedIntoTheOfferedSqueek() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        // Alice merges A2 into A1: A1 keeps id, owner and approval but is now level 2.
        nft.burn(A2);
        mining.clearPosition(A2);
        mining.setPosition(A1, 2, 0, 0);
        assertTrue(escrow.isOpen(id));
        assertFalse(escrow.isFillable(id));

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, A1, 1, 2));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(nft.ownerOf(B1), bob);
    }

    function test_fillSwap_revertsAfterMakerSqueekTradedHereAndCameBack() public {
        // Alice offers A1 for any level-1 (forgets it), sells A1 to Bob's bid, buys it back from Bob's ask.
        vm.prank(alice);
        uint256 oldSwap = escrow.createSwap(A1, 0, 1, false, 0, 0, 30 days);
        vm.prank(bob);
        uint256 bobBid = escrow.createBid(1, false, 5 ether, 0);
        vm.prank(alice);
        escrow.fillBid(bobBid, A1);
        vm.prank(bob);
        uint256 bobAsk = escrow.createAsk(A1, 6 ether, 0);
        vm.prank(alice);
        escrow.fillAsk(bobAsk);
        assertEq(nft.ownerOf(A1), alice);
        assertFalse(escrow.isFillable(oldSwap));

        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.StaleOrder.selector, oldSwap, A1));
        vm.prank(carol);
        escrow.fillSwap(oldSwap, C1);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(nft.ownerOf(C1), carol);
    }

    function test_fillSwap_deliversMakerSqueekBeforeTakerSqueek() public {
        // A contract maker that tries to claim the offered Squeek's unclaimed SQK from its receive hook no
        // longer owns it when the hook runs, so SqueekMining's owner rule refuses the claim.
        ClaimingSwapMaker maker = new ClaimingSwapMaker(escrow, mining);
        _mintSqueek(address(maker), 40, 1);
        mining.setAccrued(40, 6230 ether);
        vm.prank(address(maker));
        nft.setApprovalForAll(address(escrow), true);
        uint256 id = maker.placeSwap(40, 1);

        vm.prank(bob);
        escrow.fillSwap(id, B1);

        assertTrue(maker.hookRan());
        assertFalse(maker.claimSucceeded(), "claim from the hook must fail");
        assertEq(bytes4(maker.claimError()), MockSqueekMining.NotOwner.selector);
        assertEq(nft.ownerOf(40), bob);
        assertEq(nft.ownerOf(B1), address(maker));
        assertEq(mining.position(0, 40).accruedScaled, 6230 ether, "credit travels with the Squeek");
    }

    function test_fillSwap_anyToken_takerPaysDifference() public {
        // Alice gives her L2 for any L1 plus 40 SQK.
        vm.prank(alice);
        uint256 id = escrow.createSwap(A2, 0, 1, false, 0, 40 ether, 0);
        vm.prank(carol);
        escrow.fillSwap(id, C1);
        assertEq(nft.ownerOf(A2), carol);
        assertEq(nft.ownerOf(C1), alice);
        assertEq(sqk.balanceOf(carol), INITIAL_SQK - 40 ether);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK + 40 ether);
        _assertNoSqkLost();
    }

    function test_fillSwap_noDifference() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        assertEq(nft.ownerOf(A1), bob);
        assertEq(nft.ownerOf(B1), alice);
        _assertNoSqkLost();
    }

    function test_fillSwap_revertsWrongToken() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.WrongToken.selector, B2, B3));
        vm.prank(bob);
        escrow.fillSwap(id, B3);
    }

    function test_fillSwap_specificToken_levelStillChecked() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 0, 0, 0);
        mining.setPosition(B2, 3, 0, 0); // B2 was merged up to level 3 in the meantime
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, B2, 2, 3));
        vm.prank(bob);
        escrow.fillSwap(id, B2);
    }

    function test_fillSwap_anyToken_revertsLevelMismatch() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 2, false, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.LevelMismatch.selector, B1, 2, 1));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
    }

    function test_fillSwap_mergeReadyChecks() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A2, 0, 1, true, 0, 0, 0);
        mining.setPosition(B1, 1, 7, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.PowerChangePending.selector, B1, 7));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        mining.setPosition(B1, 1, 0, 500);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.CooldownActive.selector, B1, 500, 100));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        core.setBlockHeight(500);
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        assertEq(nft.ownerOf(B1), alice);
    }

    function test_fillSwap_revertsNoLivePosition() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        mining.clearPosition(B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NoLivePosition.selector, B1));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
    }

    function test_fillSwap_revertsTakerNotOwnerOrNotApproved() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotTokenOwner.selector, C1, carol));
        vm.prank(bob);
        escrow.fillSwap(id, C1);
        vm.startPrank(bob);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, B1, bob));
        escrow.fillSwap(id, B1);
        vm.stopPrank();
    }

    function test_fillSwap_revertsWhenMakerNoLongerOwnsOrRevoked() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        vm.prank(alice);
        nft.setApprovalForAll(address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        vm.prank(alice);
        nft.transferFrom(alice, carol, A1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.MakerNoLongerOwns.selector, id, A1));
        vm.prank(bob);
        escrow.fillSwap(id, B1);
    }

    function test_fillSwap_revertsExpiredSelfTradeAndTwice() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 0, 0);
        vm.expectRevert(SqueekMatchEscrow.SelfTrade.selector);
        vm.prank(alice);
        escrow.fillSwap(id, A2);

        vm.prank(bob);
        escrow.fillSwap(id, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(carol);
        escrow.fillSwap(id, C1);

        vm.prank(alice);
        uint256 id2 = escrow.createSwap(A2, 0, 2, false, 0, 0, 0);
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        vm.warp(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderExpired.selector, id2, expiresAt));
        vm.prank(bob);
        escrow.fillSwap(id2, B2);
    }

    function test_fillSwap_revertsWhenTakerCannotPayDifference() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, INITIAL_SQK + 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, INITIAL_SQK, INITIAL_SQK + 1)
        );
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        assertEq(nft.ownerOf(A1), alice);
        assertEq(nft.ownerOf(B1), bob);
    }

    function test_cancelSwap_byMaker_refundsEscrowedDifference() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 50 ether, 0, 0);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.SwapCancelled(id, alice, false, 50 ether);
        vm.prank(alice);
        escrow.cancelSwap(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(address(escrow)), 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelSwap(id);
        _assertNoSqkLost();
    }

    function test_cancelSwap_byOtherOnlyAfterExpiry_refundsMaker() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, B2, 2, false, 50 ether, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.NotMakerAndNotExpired.selector, id));
        vm.prank(bob);
        escrow.cancelSwap(id);
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit SqueekMatchEscrow.SwapCancelled(id, bob, true, 50 ether);
        vm.prank(bob);
        escrow.cancelSwap(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK);
    }

    function test_cancelSwap_withoutEscrowTransfersNothing() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 0, 10 ether, 0);
        vm.prank(alice);
        escrow.cancelSwap(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK);
    }

    function test_cancelSwap_filledCannotBeCancelled() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, 5 ether, 0, 0);
        vm.prank(bob);
        escrow.fillSwap(id, B1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.OrderNotOpen.selector, id));
        vm.prank(alice);
        escrow.cancelSwap(id);
        _assertNoSqkLost();
    }
}

// =================================================================================================
// Views and ids
// =================================================================================================

contract SqueekMatchEscrowViewTest is SqueekMatchEscrowTestBase {
    function test_idsAreUniqueAcrossKinds() public {
        vm.startPrank(alice);
        uint256 a = escrow.createAsk(A1, 1 ether, 0);
        uint256 b = escrow.createBid(1, false, 1 ether, 0);
        uint256 s = escrow.createSwap(A2, 0, 1, false, 0, 0, 0);
        vm.stopPrank();
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(s, 3);
        assertEq(uint8(escrow.kindOf(1)), uint8(SqueekMatchEscrow.Kind.Ask));
        assertEq(uint8(escrow.kindOf(2)), uint8(SqueekMatchEscrow.Kind.Bid));
        assertEq(uint8(escrow.kindOf(3)), uint8(SqueekMatchEscrow.Kind.Swap));
        assertEq(uint8(escrow.kindOf(4)), uint8(SqueekMatchEscrow.Kind.None));
        assertTrue(escrow.isOpen(1));
        assertTrue(escrow.isOpen(2));
        assertTrue(escrow.isOpen(3));
        assertFalse(escrow.isOpen(4));
        assertFalse(escrow.isOpen(0));
    }

    function test_isOpen_tracksStatusAndExpiry() public {
        vm.startPrank(alice);
        uint256 a = escrow.createAsk(A1, 1 ether, 0);
        uint256 b = escrow.createBid(1, false, 1 ether, 1 days);
        uint256 s = escrow.createSwap(A2, 0, 1, false, 0, 0, 0);
        escrow.cancelSwap(s);
        vm.stopPrank();
        assertFalse(escrow.isOpen(s));
        assertFalse(escrow.isFillable(s));
        vm.warp(block.timestamp + 1 days);
        assertTrue(escrow.isOpen(a));
        assertTrue(escrow.isFillable(a));
        assertFalse(escrow.isOpen(b));
        assertFalse(escrow.isFillable(b));
    }

    function test_isFillable_ask_followsTheMakerSide() public {
        // Per-token approval only, so revoking it is visible.
        vm.startPrank(alice);
        nft.setApprovalForAll(address(escrow), false);
        nft.approve(address(escrow), A1);
        uint256 id = escrow.createAsk(A1, 1, 30 days);
        assertTrue(escrow.isFillable(id));

        // Approval revoked: still Open, not fillable, and the fill reverts the same way.
        nft.approve(address(0), A1);
        vm.stopPrank();
        assertTrue(escrow.isOpen(id));
        assertFalse(escrow.isFillable(id));
        vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.EscrowNotApproved.selector, A1, alice));
        vm.prank(bob);
        escrow.fillAsk(id);

        // Approval restored: fillable again (the token never moved and its level is unchanged).
        vm.prank(alice);
        nft.approve(address(escrow), A1);
        assertTrue(escrow.isFillable(id));

        // Moved away outside the escrow: not fillable.
        vm.prank(alice);
        nft.transferFrom(alice, carol, A1);
        assertFalse(escrow.isFillable(id));

        // Burned: ownerOf reverts, the view reports false rather than reverting.
        nft.burn(A1);
        assertFalse(escrow.isFillable(id));
    }

    function test_isFillable_swap_followsTheMakerSide() public {
        vm.prank(alice);
        uint256 id = escrow.createSwap(A2, 0, 1, false, 0, 0, 0);
        assertTrue(escrow.isFillable(id));
        vm.prank(alice);
        nft.setApprovalForAll(address(escrow), false);
        assertFalse(escrow.isFillable(id));
        vm.prank(alice);
        nft.setApprovalForAll(address(escrow), true);
        assertTrue(escrow.isFillable(id));
        mining.setPosition(A2, 3, 0, 0);
        assertFalse(escrow.isFillable(id), "level changed");
        mining.setPosition(A2, 2, 0, 0);
        assertTrue(escrow.isFillable(id));
        vm.warp(block.timestamp + 7 days);
        assertFalse(escrow.isFillable(id), "expired");
    }

    function test_isFillable_bid_equalsIsOpen_andUnknownIdsAreFalse() public {
        vm.prank(alice);
        uint256 b = escrow.createBid(1, true, 1 ether, 0);
        assertTrue(escrow.isFillable(b));
        vm.prank(alice);
        escrow.cancelBid(b);
        assertFalse(escrow.isFillable(b));
        assertFalse(escrow.isFillable(0));
        assertFalse(escrow.isFillable(99));
    }

    function test_levelOfAndIsMergeReady() public {
        assertEq(escrow.levelOf(A1), 1);
        assertEq(escrow.levelOf(B3), 3);
        assertEq(escrow.levelOf(999), 0);
        assertFalse(escrow.isMergeReady(999));
        assertTrue(escrow.isMergeReady(A1));
        mining.setPosition(A1, 1, 3, 0);
        assertFalse(escrow.isMergeReady(A1));
        mining.setPosition(A1, 1, 0, 101);
        assertFalse(escrow.isMergeReady(A1));
        mining.setPosition(A1, mining.MAXIMUM_LEVEL(), 0, 0);
        assertFalse(escrow.isMergeReady(A1));
    }

    function test_viewsRevertWhenSqueekContractsAbsent() public {
        // Deployed against addresses without code (as the launch rehearsal does): reads fail loudly, not silently.
        SqueekMatchEscrow bare = new SqueekMatchEscrow(makeAddr("no-nft"), makeAddr("no-sqk"));
        vm.expectRevert();
        bare.levelOf(1);
        vm.expectRevert();
        bare.createBid(1, false, 1, 0);
    }
}

// =================================================================================================
// Reentrancy
// =================================================================================================

contract SqueekMatchEscrowReentrancyTest is SqueekMatchEscrowTestBase {
    function test_askTaker_cannotReenterFromReceiveHook() public {
        vm.startPrank(alice);
        uint256 first = escrow.createAsk(A1, 10 ether, 0);
        uint256 second = escrow.createAsk(A2, 20 ether, 0);
        vm.stopPrank();

        ReentrantAskTaker attacker = new ReentrantAskTaker(escrow, sqk);
        sqk.mint(address(attacker), 100 ether);
        attacker.attack(first, second);

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(bytes4(attacker.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(nft.ownerOf(A1), address(attacker));
        assertEq(nft.ownerOf(A2), alice, "second ask untouched");
        assertEq(sqk.balanceOf(address(attacker)), 90 ether);
        assertTrue(escrow.isOpen(second));
    }

    function test_bidMaker_cannotCancelWhileBeingFilled() public {
        ReentrantBidMaker attacker = new ReentrantBidMaker(escrow, sqk);
        sqk.mint(address(attacker), 100 ether);
        uint256 id = attacker.placeBid(1, 100 ether);
        assertEq(sqk.balanceOf(address(escrow)), 100 ether);

        // The hook reverts, so the whole fill reverts: seller keeps the Squeek, escrow keeps the SQK.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(bob);
        escrow.fillBid(id, B1);
        assertEq(nft.ownerOf(B1), bob);
        assertEq(sqk.balanceOf(address(escrow)), 100 ether);
        assertTrue(escrow.isOpen(id));
    }

    function test_swapMaker_cannotCancelWhileBeingFilled() public {
        ReentrantSwapMaker attacker = new ReentrantSwapMaker(escrow, sqk);
        sqk.mint(address(attacker), 100 ether);
        _mintSqueek(address(attacker), 500, 1);
        vm.prank(address(attacker));
        nft.setApprovalForAll(address(escrow), true);
        uint256 id = attacker.placeSwap(500, 1, 100 ether);

        vm.prank(bob);
        escrow.fillSwap(id, B1);

        assertFalse(attacker.reentrySucceeded());
        assertEq(bytes4(attacker.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(nft.ownerOf(B1), address(attacker));
        assertEq(nft.ownerOf(500), bob);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK + 100 ether);
        assertEq(sqk.balanceOf(address(attacker)), 0, "difference paid once, not refunded as well");
        assertEq(sqk.balanceOf(address(escrow)), 0);
    }
}

// =================================================================================================
// Fuzz
// =================================================================================================

contract SqueekMatchEscrowFuzzTest is SqueekMatchEscrowTestBase {
    function testFuzz_expiry(uint64 duration) public {
        vm.prank(alice);
        if (duration > 30 days) {
            vm.expectRevert(abi.encodeWithSelector(SqueekMatchEscrow.DurationTooLong.selector, duration, 30 days));
            escrow.createAsk(A1, 1, duration);
            return;
        }
        uint256 id = escrow.createAsk(A1, 1, duration);
        (, uint64 expiresAt,,,,,) = escrow.asks(id);
        uint64 expected = uint64(block.timestamp) + (duration == 0 ? 7 days : duration);
        assertEq(expiresAt, expected);
        vm.warp(expected - 1);
        assertTrue(escrow.isOpen(id));
        vm.warp(expected);
        assertFalse(escrow.isOpen(id));
    }

    function testFuzz_bidLifecycle_conservesSqk(uint256 amount, uint8 level, bool fill, bool mergeReady) public {
        amount = bound(amount, 1, INITIAL_SQK);
        level = uint8(bound(level, 1, 9));
        vm.prank(alice);
        uint256 id = escrow.createBid(level, mergeReady, amount, 0);
        assertEq(sqk.balanceOf(address(escrow)), amount);
        _assertNoSqkLost();

        if (fill) {
            _mintSqueek(bob, 1000, level);
            vm.prank(bob);
            escrow.fillBid(id, 1000);
            assertEq(nft.ownerOf(1000), alice);
            assertEq(sqk.balanceOf(bob), INITIAL_SQK + amount);
        } else {
            vm.prank(alice);
            escrow.cancelBid(id);
            assertEq(sqk.balanceOf(alice), INITIAL_SQK);
        }
        assertEq(sqk.balanceOf(address(escrow)), 0);
        _assertNoSqkLost();
    }

    function testFuzz_askFill_movesExactPrice(uint256 price) public {
        price = bound(price, 1, INITIAL_SQK);
        vm.prank(alice);
        uint256 id = escrow.createAsk(A2, price, 0);
        vm.prank(bob);
        escrow.fillAsk(id);
        assertEq(sqk.balanceOf(alice), INITIAL_SQK + price);
        assertEq(sqk.balanceOf(bob), INITIAL_SQK - price);
        assertEq(nft.ownerOf(A2), bob);
        _assertNoSqkLost();
    }

    function testFuzz_swapDifference_eitherSide(uint256 difference, bool makerPays, bool cancel) public {
        difference = bound(difference, 0, INITIAL_SQK);
        uint256 fromMaker = makerPays ? difference : 0;
        uint256 fromTaker = makerPays ? 0 : difference;
        vm.prank(alice);
        uint256 id = escrow.createSwap(A1, 0, 1, false, fromMaker, fromTaker, 0);
        assertEq(sqk.balanceOf(address(escrow)), fromMaker);

        if (cancel) {
            vm.prank(alice);
            escrow.cancelSwap(id);
            assertEq(sqk.balanceOf(alice), INITIAL_SQK);
            assertEq(nft.ownerOf(A1), alice);
        } else {
            vm.prank(bob);
            escrow.fillSwap(id, B1);
            assertEq(nft.ownerOf(A1), bob);
            assertEq(nft.ownerOf(B1), alice);
            assertEq(sqk.balanceOf(alice), INITIAL_SQK - fromMaker + fromTaker);
            assertEq(sqk.balanceOf(bob), INITIAL_SQK + fromMaker - fromTaker);
        }
        assertEq(sqk.balanceOf(address(escrow)), 0);
        _assertNoSqkLost();
    }

    function testFuzz_mergeReadyGate(uint48 nextMergeBlock, uint64 height, uint40 pendingRound, uint8 level) public {
        level = uint8(bound(level, 1, mining.MAXIMUM_LEVEL()));
        core.setBlockHeight(height);
        mining.setPosition(B1, level, pendingRound, nextMergeBlock);
        bool expected = pendingRound == 0 && level < mining.MAXIMUM_LEVEL() && nextMergeBlock <= height;
        assertEq(escrow.isMergeReady(B1), expected);

        bool atMaximum = level == mining.MAXIMUM_LEVEL();
        vm.prank(alice);
        if (atMaximum) {
            // No Squeek at the maximum level can merge, so the bid itself is refused.
            vm.expectRevert(SqueekMatchEscrow.InvalidLevel.selector);
            escrow.createBid(level, true, 1 ether, 0);
            return;
        }
        uint256 id = escrow.createBid(level, true, 1 ether, 0);
        vm.prank(bob);
        if (!expected) vm.expectRevert();
        escrow.fillBid(id, B1);
        assertEq(nft.ownerOf(B1), expected ? alice : bob);
    }
}
