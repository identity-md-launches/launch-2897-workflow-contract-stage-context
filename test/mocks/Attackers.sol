// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SqueekMatchEscrow} from "../../src/SqueekMatchEscrow.sol";

/// @notice A taker contract that, while receiving the Squeek of one ask, tries to re-enter the escrow.
/// It swallows the failure so the outer fill can finish and the test can read what happened.
contract ReentrantAskTaker is IERC721Receiver {
    SqueekMatchEscrow public immutable escrow;
    uint256 public reenterAskId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(SqueekMatchEscrow escrow_, IERC20 sqk) {
        escrow = escrow_;
        sqk.approve(address(escrow_), type(uint256).max);
    }

    function attack(uint256 firstAskId, uint256 secondAskId) external {
        reenterAskId = secondAskId;
        escrow.fillAsk(firstAskId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(escrow.SQUEEK()) && !reentryAttempted) {
            reentryAttempted = true;
            try escrow.fillAsk(reenterAskId) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice A bid maker contract that, while receiving the Squeek that fills its bid, tries to cancel the
/// same bid to get its SQK back as well (double spend attempt). It does not swallow the failure.
contract ReentrantBidMaker is IERC721Receiver {
    SqueekMatchEscrow public immutable escrow;
    uint256 public bidId;

    constructor(SqueekMatchEscrow escrow_, IERC20 sqk) {
        escrow = escrow_;
        sqk.approve(address(escrow_), type(uint256).max);
    }

    function placeBid(uint8 level, uint256 amount) external returns (uint256 id) {
        id = escrow.createBid(level, false, amount, 0);
        bidId = id;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        escrow.cancelBid(bidId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice A swap maker contract whose receive hook tries to cancel its own swap mid-fill. It swallows the
/// failure so the test can assert the fill still completes exactly once.
contract ReentrantSwapMaker is IERC721Receiver {
    SqueekMatchEscrow public immutable escrow;
    uint256 public swapId;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(SqueekMatchEscrow escrow_, IERC20 sqk) {
        escrow = escrow_;
        sqk.approve(address(escrow_), type(uint256).max);
    }

    function placeSwap(uint256 makerTokenId, uint8 wantedLevel, uint256 sqkFromMaker) external returns (uint256 id) {
        id = escrow.createSwap(makerTokenId, 0, wantedLevel, false, sqkFromMaker, 0, 0);
        swapId = id;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        try escrow.cancelSwap(swapId) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice A contract that cannot receive ERC-721 tokens (no receiver hook).
contract NonReceiver {}
