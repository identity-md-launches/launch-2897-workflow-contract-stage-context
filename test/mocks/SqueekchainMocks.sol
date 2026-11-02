// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ISqueekCore, ISqueekMining} from "../../src/interfaces/ISqueekchain.sol";

/// @notice Local stand-in for SqueekToken: a plain 18-decimal ERC-20 with open minting.
contract MockSQK is ERC20 {
    constructor() ERC20("Squeek Token", "SQK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Local stand-in for SqueekCore: only the completed Squeek block height matters to the escrow.
contract MockSqueekCore is ISqueekCore {
    uint64 public blockHeight;

    function setBlockHeight(uint64 height) external {
        blockHeight = height;
    }

    function state() external view returns (CoreState memory s) {
        s.blockHeight = blockHeight;
    }
}

/// @notice Local stand-in for SqueekMining: positions are set directly by tests.
contract MockSqueekMining is ISqueekMining {
    uint8 public constant MAXIMUM_LEVEL = 10;

    address public immutable core;
    address public nft;
    mapping(uint8 => mapping(uint256 => MiningPosition)) internal positions;

    constructor(address core_) {
        core = core_;
    }

    function setNft(address nft_) external {
        nft = nft_;
    }

    function setPosition(uint256 tokenId, uint8 level, uint40 pendingRound, uint48 nextMergeBlock) external {
        positions[0][tokenId] = MiningPosition({
            activeWeight: uint64(level) * 1000,
            pendingWeight: pendingRound == 0 ? 0 : uint64(level) * 3000,
            pendingRound: pendingRound,
            nextMergeBlock: nextMergeBlock,
            level: level,
            lastIndex: 0,
            accruedScaled: 0
        });
    }

    function clearPosition(uint256 tokenId) external {
        delete positions[0][tokenId];
    }

    function position(uint8 collection, uint256 tokenId) external view returns (MiningPosition memory) {
        return positions[collection][tokenId];
    }

    function collectionPolicy(uint8 collection) external view returns (MiningCollectionPolicy memory policy) {
        require(collection == 0, "CollectionNotBound");
        policy.nft = nft;
        policy.maxSupply = 9999;
        policy.maximumLevel = MAXIMUM_LEVEL;
        policy.levels = new MiningLevel[](MAXIMUM_LEVEL);
        for (uint8 i; i < MAXIMUM_LEVEL; ++i) {
            policy.levels[i] =
                MiningLevel({weight: uint64(1000) << i, cooldownBlocks: i == MAXIMUM_LEVEL - 1 ? 0 : 2 * (i + 1)});
        }
    }
}

/// @notice Local stand-in for SqueekNFT: a plain ERC-721 that points at the mock mining contract.
contract MockSqueekNFT is ERC721 {
    address public immutable mining;

    constructor(address mining_) ERC721("Squeek", "SQUEEK") {
        mining = mining_;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }
}
