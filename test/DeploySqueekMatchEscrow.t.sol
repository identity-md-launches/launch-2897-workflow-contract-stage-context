// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySqueekMatchEscrow} from "../script/DeploySqueekMatchEscrow.s.sol";
import {SqueekMatchEscrow} from "../src/SqueekMatchEscrow.sol";

contract DeploySqueekMatchEscrowTest is Test {
    function test_deploy_bindsGivenContracts() public {
        DeploySqueekMatchEscrow script = new DeploySqueekMatchEscrow();
        address nft = makeAddr("nft");
        address sqk = makeAddr("sqk");
        SqueekMatchEscrow escrow = script.deploy(nft, sqk);
        assertEq(address(escrow.SQUEEK()), nft);
        assertEq(address(escrow.SQK()), sqk);
    }

    function test_sepoliaConstants_areDocumentedAddresses() public {
        DeploySqueekMatchEscrow script = new DeploySqueekMatchEscrow();
        assertEq(script.SEPOLIA_SQUEEK_NFT(), 0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6);
        assertEq(script.SEPOLIA_SQK(), 0x6872BfA5CcC3E9e440C6c16e5fFdAbb8DBA4Cc76);
        SqueekMatchEscrow escrow = script.deploy(script.SEPOLIA_SQUEEK_NFT(), script.SEPOLIA_SQK());
        assertEq(address(escrow.SQUEEK()), script.SEPOLIA_SQUEEK_NFT());
    }
}
