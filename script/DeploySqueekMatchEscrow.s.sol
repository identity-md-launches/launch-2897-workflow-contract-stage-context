// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SqueekMatchEscrow} from "../src/SqueekMatchEscrow.sol";

/// @notice Reviewable deployment reference for SqueekMatchEscrow. The IdentityMD launch deploys the contract
/// through its factory from the manifest, so this script is documentation of the constructor arguments and a
/// local rehearsal, not the launch path. It reads no environment and holds no key.
contract DeploySqueekMatchEscrow is Script {
    /// @notice SqueekNFT on Sepolia (docs.squeekchain.com Deployments, assets/deployments/sepolia.json).
    address public constant SEPOLIA_SQUEEK_NFT = 0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6;
    /// @notice SqueekToken (SQK) on Sepolia (same source).
    address public constant SEPOLIA_SQK = 0x6872BfA5CcC3E9e440C6c16e5fFdAbb8DBA4Cc76;

    /// @notice Deploys an escrow bound to the given Squeekchain contracts. Tests call this directly.
    function deploy(address squeekNft, address sqk) public returns (SqueekMatchEscrow escrow) {
        escrow = new SqueekMatchEscrow(squeekNft, sqk);
    }

    /// @notice Local rehearsal with the Sepolia constructor arguments.
    function run() external returns (SqueekMatchEscrow escrow) {
        vm.startBroadcast();
        escrow = deploy(SEPOLIA_SQUEEK_NFT, SEPOLIA_SQK);
        vm.stopBroadcast();
    }
}
