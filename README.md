# SqueekMatchEscrow

Non-custodial, fee-free peer-to-peer market for Squeeks (Squeekchain's ERC-721) priced in SQK, built so holders
of a lone Squeek at a level can find a merge partner. This repository holds the contract stage of SqueekMatch:
the Solidity source, its tests, the ABI export and this document. The website is a later stage.

Fan-made and unofficial. Sepolia only. Not affiliated with Squeekchain.

## What it does

One contract, `SqueekMatchEscrow`, with three order kinds. Every kind has create, fill and cancel, every action
emits an event, and every order expires.

| Kind | Maker gives | Maker gets | Where value sits before fill |
|---|---|---|---|
| Ask | one specific Squeek | fixed SQK price | Squeek stays in the maker's wallet (approval only); nothing escrowed |
| Bid | SQK | any Squeek at an exact level, optionally merge-ready | SQK escrowed in the contract |
| Swap | one specific Squeek, optionally plus SQK | a specific Squeek or any Squeek at a level, optionally merge-ready, optionally plus SQK | Squeek stays in the wallet; only the maker's SQK difference is escrowed |

- **Fill** moves everything in one transaction. Asks: taker's SQK goes straight to the maker, maker's Squeek to the
  taker. Bids: taker's Squeek goes to the maker, escrowed SQK to the taker. Swaps: both Squeeks change hands, the
  SQK difference is paid in whichever direction the maker set.
- **Cancel** is allowed for the maker at any time. After expiry anyone may cancel an order; escrowed SQK is always
  refunded to the maker, never to the caller. Expired orders cannot be filled.
- **Level and eligibility are read live at fill** from SqueekMining (reached through `SqueekNFT.mining()`), never
  cached. A Squeek is "merge-ready" when its position is live, below the collection's maximum level, has no
  scheduled power change (`pendingRound == 0`) and its `nextMergeBlock` is at or below SqueekCore's completed
  Squeek block height. That is exactly the precondition SqueekMining's `merge` enforces, so a bid or swap with
  `mergeReady = true` only ever receives a Squeek the maker can merge in the next transaction.
- The contract never holds a Squeek. It holds only SQK that bid and swap makers escrowed for their own open orders.

## Deployment parameters

The launch deploys `SqueekMatchEscrow` through the project factory on Sepolia (chain id 11155111). It has no
owner, so `$owner` is not used anywhere. The constructor makes no external call and takes two addresses:

| Position | Argument | Type | Sepolia value | Source |
|---|---|---|---|---|
| 0 | `squeek_` | address | `0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6` | SqueekNFT, Squeekchain Deployments (docs.squeekchain.com/developers#deployments, `assets/deployments/sepolia.json`) |
| 1 | `sqk_` | address | `0x6872BfA5CcC3E9e440C6c16e5fFdAbb8DBA4Cc76` | SqueekToken (SQK), same source |

Both values were verified on Sepolia on 2026-11-02 through a public RPC: the NFT address has code and returns
`name() = "Squeek"`, `symbol() = "SQUEEK"` and `mining() = 0x3beE588fC20dE788Bac17d33b41Da7346cb27EC4`; the token
address has code and returns `symbol() = "SQK"`, `decimals() = 18`; SqueekMining's `configuration()` names the same
token and genesis collection, and `collectionPolicy(0)` names the NFT with maximum level 10. The deployment record
lists both as `kind: immutable`. SqueekMining and SqueekCore are **not** constructor arguments: the escrow reads
`SQUEEK.mining()` and `mining.core()` at use, so it follows whatever the NFT points to.

`script/DeploySqueekMatchEscrow.s.sol` repeats the two values as constants and exposes `deploy(address, address)`,
which the tests call. It is a reviewable reference; the launch does not run it.

### After launch

Nothing. There is no owner, no setter, no pause, no fee switch and no upgrade path. The address the launch records
for `SqueekMatchEscrow` is the only thing the website needs, and the website must verify it against the deployment
handoff before enabling trading.

## Constants chosen here

The brief left these open; they are named constants in the contract.

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_DURATION` | 7 days | Expiry applied when `duration` is 0 (brief: default 7d) |
| `MAX_DURATION` | 30 days | Longest allowed expiry (brief: max 30d) |
| `SQUEEKS_COLLECTION` | 0 | SqueekMining collection selector for SqueekNFT (per Squeekchain docs) |
| `ANY_SQUEEK` | 0 | `wantedTokenId` sentinel in swaps meaning "any Squeek at `wantedLevel`"; token id 0 is never minted by SqueekNFT |

Order ids are shared across kinds and start at 1; `kindOf(id)` tells an indexer which mapping to read.

## Interface summary

Full ABI: `docs/abi/SqueekMatchEscrow.json`.

| Function | Caller | Effect |
|---|---|---|
| `createAsk(tokenId, price, duration)` | Squeek owner who approved the escrow | Lists the Squeek. Reverts on zero price, not owner, no approval, duration > 30 days |
| `fillAsk(askId)` | Anyone but the maker, with SQK allowance | Pays `price` to the maker, receives the Squeek. Reverts if closed, expired, maker no longer owns or approves the Squeek |
| `cancelAsk(askId)` | Maker, or anyone after expiry | Closes the ask |
| `createBid(level, mergeReady, amount, duration)` | Anyone with SQK allowance | Escrows `amount`. Reverts on zero amount or level 0 |
| `fillBid(bidId, tokenId)` | Owner of `tokenId` who approved the escrow | Sends the Squeek to the maker, pays the escrow to the caller. Reverts on level mismatch, dead position, failed merge-ready check |
| `cancelBid(bidId)` | Maker, or anyone after expiry | Refunds the escrow to the maker |
| `createSwap(makerTokenId, wantedTokenId, wantedLevel, mergeReady, sqkFromMaker, sqkFromTaker, duration)` | Squeek owner who approved the escrow | Escrows `sqkFromMaker`. Reverts if both SQK sides are non-zero, same token, level 0 |
| `fillSwap(swapId, tokenId)` | Owner of `tokenId` | Swaps the Squeeks and settles the SQK difference. `wantedLevel` is always checked; `wantedTokenId` additionally pins a token unless it is `ANY_SQUEEK` |
| `cancelSwap(swapId)` | Maker, or anyone after expiry | Refunds `sqkFromMaker` to the maker |
| `isOpen(id)`, `levelOf(tokenId)`, `isMergeReady(tokenId)`, `mining()` | view | Helpers for the website; the fill functions perform the same checks and revert with named errors |

Named errors (`OrderExpired`, `LevelMismatch`, `CooldownActive(tokenId, nextMergeBlock, blockHeight)`,
`PowerChangePending`, `AtMaximumLevel`, `MakerNoLongerOwns`, `EscrowNotApproved`, ...) carry the values a UI
needs for plain-language messages after an `eth_call` dry run.

## Assumptions

- **SQK** is Squeekchain's SqueekToken: 18 decimals, no transfer fee, no rebasing, standard return values. The
  escrow uses OpenZeppelin `SafeERC20` and does not measure balance deltas.
- **SqueekNFT** is a standard OpenZeppelin ERC-721. `safeTransferFrom` is used so a contract that cannot receive
  ERC-721 tokens cannot end up holding a Squeek. The escrow must be approved (`approve` or `setApprovalForAll`)
  by whoever delivers a Squeek; it checks this explicitly and reverts with `EscrowNotApproved`.
- **SqueekMining** version 6 as published: `position(0, id)` returns level 0 for a burned or unminted id rather
  than reverting, `collectionPolicy(0).maximumLevel` is the merge ceiling, and `core().state().blockHeight` is the
  completed Squeek block height merge cooldowns are compared against. Squeekchain says these contracts are in
  active development and the Sepolia deployment may be upgraded. SqueekMining and SqueekCore are transparent
  proxies governed by Squeekchain's timelock; a breaking change to these views would make bid and swap fills
  revert (asks do not read SqueekMining and keep working). Because they are resolved through the NFT at use,
  no redeploy is needed if the NFT's pointer stays valid; if Squeekchain redeploys SqueekNFT or SqueekToken, a
  new escrow must be launched with the new addresses.
- **Staking / deposited Squeeks.** The brief mentions deposited Squeeks and `Staking mergeDeposited`. Squeekchain
  documents staking as "in active development" and the published ABIs contain no deposit function. A Squeek held
  by any other contract simply is not owned by the maker, so every fill involving it reverts with
  `MakerNoLongerOwns` or `NotTokenOwner`; the website should tell holders to withdraw before trading.
- **Unclaimed SQK travels with the Squeek.** SqueekMining credits rewards to the token, not the owner. The escrow
  does not touch claims; the website must warn sellers to claim first and show buyers what they are getting.
- **Expiry uses `block.timestamp`.** A validator can shift a fill or cancel by a few seconds around the boundary;
  nothing of value depends on that precision. Merge cooldowns are compared in Squeek blocks, not time.
- **Token id 0 does not exist** (SqueekNFT reverts `ERC721NonexistentToken(0)` on Sepolia); it is the swap "any
  Squeek" sentinel. Should a collection ever mint id 0, that one token could not be pinned in a swap.

## Trust and operational responsibilities

- **No privileged party.** There is no owner, admin, pauser, fee recipient or upgrade authority. The deploying
  factory and the launch wallet get no role. Nobody can move escrowed SQK except through the order that holds it
  (fill pays the taker; cancel pays the maker).
- **Custody.** The contract holds only SQK from open bids and swaps. Any SQK or other token sent to it directly,
  outside an order, is unrecoverable by design; the website must never ask a user to transfer tokens to the escrow
  address.
- **Expired orders.** Nothing happens automatically. The maker, the website on the maker's behalf, or any keeper
  may call `cancelBid` / `cancelSwap` after expiry to return the maker's SQK; the refund goes to the maker regardless
  of who calls.
- **Front-running.** Fills are first come, first served; a second fill of the same order reverts with
  `OrderNotOpen` before any transfer. Asks are per token: if a maker lists the same Squeek twice, only one fill can
  succeed and the other listing reverts with `MakerNoLongerOwns` until it is cancelled.
- **Price discovery** is off-chain. Prices are the makers' own; the contract charges nothing and enforces no
  bounds beyond non-zero.
- **The website must verify addresses** (escrow from the launch handoff, Squeekchain contracts from the
  Deployments page and API identities) and refuse trading on mismatch, dry-run every transaction with `eth_call`,
  and show the testnet banner, as the approved brief requires.

## Security notes

- `ReentrancyGuard` on every state-changing function, checks-effects-interactions throughout: an order is marked
  Filled or Cancelled and its event emitted before any token moves. Tests exercise reentry through ERC-721 receive
  hooks from a taker, a bid maker and a swap maker.
- `transferFrom` on SQK only ever moves tokens from `msg.sender` (ask taker paying the maker, bid maker escrowing,
  swap maker escrowing, swap taker paying). Escrowed SQK leaves only via `safeTransfer` to the order's taker or
  maker.
- No `selfdestruct`, `delegatecall`, assembly, external library calls, initializers, upgrade paths, or
  `abi.encodePacked` with dynamic data. The runtime is about 10.5 KB. A scratch test deploying the init code
  with CREATE2 from a factory on an empty chain and scanning the runtime for DELEGATECALL / CALLCODE /
  SELFDESTRUCT passes.
- `forge` lint reports only informational notes (`block.timestamp` comparisons, which are the expiry design, and
  a `uint64(block.timestamp)` cast that cannot truncate for the next five hundred billion years).
- Tests passing is not an audit. The independent review in this workflow stage should look in particular at the
  merge-ready predicate against the live SqueekMining source and at the swap settlement order.

## Build and test

```
forge build
forge test
forge fmt --check
```

Pinned toolchain: `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer 200 runs, `bytecode_hash = "none"`,
no `ffi`, no `fs_permissions`. Dependencies are vendored as plain files under `lib/`: forge-std 1.17.0 and
OpenZeppelin Contracts 5.4.0 (`contracts/` tree only). No git submodules.

Tests (`test/SqueekMatchEscrow.t.sol`, 92 tests across 8 suites) use local mocks of SqueekToken, SqueekNFT,
SqueekMining and SqueekCore (`test/mocks/`) and cover every create/fill/cancel success path, each named failure
(expired, closed, wrong kind id, self-trade, not owner, approval missing or revoked, maker transferred or burned
the Squeek, level mismatch, dead position, pending power change, cooldown active, at maximum level, insufficient
SQK balance or allowance, both swap sides paying, same token, duration too long, receiver cannot accept
ERC-721), SQK conservation, refund routing, reentrancy, and fuzzed expiry, amounts, swap differences and the
merge-ready gate. They read no environment variables and do not depend on the caller address.

## Layout

```
foundry.toml, remappings.txt        Foundry configuration (compiler pin, remappings)
src/SqueekMatchEscrow.sol           the contract
src/interfaces/ISqueekchain.sol     the slices of SqueekNFT, SqueekMining and SqueekCore it uses
script/DeploySqueekMatchEscrow.s.sol  constructor-argument reference and local rehearsal
test/                               tests and mocks
docs/abi/SqueekMatchEscrow.json     ABI export (forge inspect)
lib/                                vendored forge-std and OpenZeppelin
```

## References

- Squeekchain Developers / Deployments: https://docs.squeekchain.com/developers/
- SqueekMining reference (positions, merge rules): https://docs.squeekchain.com/developers/mining/
- Build owner actions (merge preflight the escrow mirrors): https://docs.squeekchain.com/developers/owner-actions/
- Merging Squeeks: https://docs.squeekchain.com/squeeks/merge/
