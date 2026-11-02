// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice The subset of SqueekNFT (the Squeek ERC-721 collection) that SqueekMatchEscrow uses.
/// @dev Source: docs.squeekchain.com, published ABI `assets/abi/SqueekNFT.json`. Levels, cooldowns and
/// pending power are not stored on the NFT; they live in SqueekMining, which the NFT points to.
interface ISqueekNFT is IERC721 {
    /// @notice The SqueekMining contract that tracks every Squeek's position (level, power, cooldown).
    function mining() external view returns (address);
}

/// @notice The subset of SqueekMining that SqueekMatchEscrow reads at fill time.
/// @dev Source: docs.squeekchain.com/developers/mining (version 6). Squeeks use collection selector 0.
interface ISqueekMining {
    struct MiningPosition {
        uint64 activeWeight; // power earning now
        uint64 pendingWeight; // full replacement power from pendingRound; 0 if none
        uint40 pendingRound; // SqueekCore round the pending power starts earning; 0 if none
        uint48 nextMergeBlock; // completed Squeek block height at which a merge is allowed
        uint8 level; // 0 means no live position (burned or unminted)
        uint256 lastIndex;
        uint256 accruedScaled;
    }

    struct MiningLevel {
        uint64 weight;
        uint64 cooldownBlocks;
    }

    struct MiningCollectionPolicy {
        address nft;
        uint16 maxSupply;
        uint8 maximumLevel;
        MiningLevel[] levels; // index 0 is level 1
    }

    /// @notice One NFT's position. A burned or unminted id returns level 0 rather than reverting.
    function position(uint8 collection, uint256 tokenId) external view returns (MiningPosition memory);

    /// @notice The collection's NFT address, supply limit, maximum level and level table.
    function collectionPolicy(uint8 collection) external view returns (MiningCollectionPolicy memory);

    /// @notice The SqueekCore contract whose completed Squeek block height gates merge cooldowns.
    function core() external view returns (address);
}

/// @notice The subset of SqueekCore that SqueekMatchEscrow reads at fill time.
/// @dev Source: docs.squeekchain.com, published ABI `assets/abi/SqueekCore.json`.
interface ISqueekCore {
    struct CoreState {
        uint64 settledThroughRound;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint64 blockHeight; // completed Squeek blocks; merge cooldowns are compared against this
        uint96 blockProgress;
        uint32 workPerThousandBlocks;
        uint256 authorizationNonce;
        bool paused;
    }

    function state() external view returns (CoreState memory);
}
