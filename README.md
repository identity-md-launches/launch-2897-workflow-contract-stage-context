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
- **The taker's Squeek is judged live at fill** from SqueekMining (reached through `SqueekNFT.mining()`), never
  cached. A Squeek is "merge-ready" when its position is live, below the collection's maximum level, has no
  scheduled power change (`pendingRound == 0`) and its `nextMergeBlock` is at or below SqueekCore's completed
  Squeek block height. That is exactly the precondition SqueekMining's `merge` enforces, so a bid or swap with
  `mergeReady = true` only ever receives a Squeek the maker can merge in the next transaction.
- **An ask or swap is bound to the maker's Squeek as it was when listed.** `createAsk` and `createSwap` record the
  Squeek's level (`Ask.level`, `Swap.makerLevel`) and the escrow's per-token trade counter (`tradeCount(tokenId)`,
  which every fill that moves the Squeek increments). `fillAsk` and `fillSwap` revert with `LevelMismatch` if the
  live level differs (a merge raises the survivor's level without any ERC-721 transfer, so a standing approval
  alone would have let a stale listing sell the upgraded Squeek at the old price) and with `StaleOrder` if the
  Squeek has been traded through this escrow since the order was created (so a forgotten listing does not revive
  when the Squeek comes back to its maker under `setApprovalForAll`). They also require, as before, that the maker
  still owns the Squeek and the escrow is still approved for it. `isFillable(id)` reports all of this for a UI.
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
| `createAsk(tokenId, price, duration)` | Squeek owner who approved the escrow | Lists the Squeek and records its level and trade count. Reverts on zero price, not owner, no approval, no live position, duration > 30 days |
| `fillAsk(askId)` | Anyone but the maker, with SQK allowance | Pays `price` to the maker, receives the Squeek. Reverts if closed, expired, maker no longer owns or approves the Squeek, it was traded here since listing (`StaleOrder`), or its level changed (`LevelMismatch`) |
| `cancelAsk(askId)` | Maker, or anyone after expiry | Closes the ask |
| `createBid(level, mergeReady, amount, duration)` | Anyone with SQK allowance | Escrows `amount`. Reverts on zero amount, level 0, level above SqueekMining's maximum, or `mergeReady` at the maximum level (no Squeek could fill it) |
| `fillBid(bidId, tokenId)` | Owner of `tokenId` who approved the escrow | Sends the Squeek to the maker, pays the escrow to the caller. Reverts on level mismatch, dead position, failed merge-ready check |
| `cancelBid(bidId)` | Maker, or anyone after expiry | Refunds the escrow to the maker |
| `createSwap(makerTokenId, wantedTokenId, wantedLevel, mergeReady, sqkFromMaker, sqkFromTaker, duration)` | Squeek owner who approved the escrow | Escrows `sqkFromMaker`; records the maker Squeek's level and trade count. Reverts if both SQK sides are non-zero, same token, `wantedLevel` 0 or unfillable (as for bids), maker Squeek has no live position |
| `fillSwap(swapId, tokenId)` | Owner of `tokenId` | Swaps the Squeeks and settles the SQK difference. `wantedLevel` is always checked; `wantedTokenId` additionally pins a token unless it is `ANY_SQUEEK`. Maker side checked as in `fillAsk`. The maker's Squeek is delivered to the taker before the taker's Squeek reaches the maker |
| `cancelSwap(swapId)` | Maker, or anyone after expiry | Refunds `sqkFromMaker` to the maker |
| `isOpen(id)` | view | Status is Open and not expired. Says nothing about the maker's side: an ask or swap whose maker revoked approval, moved or merged the Squeek still reports open until cancelled |
| `isFillable(id)` | view | `isOpen` plus the maker-side checks `fillAsk` / `fillSwap` make (owner, approval, trade count, level); equals `isOpen` for bids. Filter Match Board floors and Market summaries on this, not on `isOpen` |
| `tradeCount(tokenId)`, `levelOf(tokenId)`, `isMergeReady(tokenId)`, `mining()` | view | Helpers for the website; the fill functions perform the same checks and revert with named errors |

Named errors (`OrderExpired`, `LevelMismatch`, `CooldownActive(tokenId, nextMergeBlock, blockHeight)`,
`PowerChangePending`, `AtMaximumLevel`, `MakerNoLongerOwns`, `StaleOrder`, `EscrowNotApproved`, ...) carry the
values a UI needs for plain-language messages after an `eth_call` dry run.

Events: `AskCreated` carries the recorded `level` and `SwapCreated` the recorded `makerLevel`, so an indexer knows
the level each listing was priced at without a second read.

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
  proxies governed by Squeekchain's timelock; a breaking change to `position` or `collectionPolicy` would make
  every create and fill revert (asks read `position` too, to pin and re-check the listed level), while cancels
  and refunds never touch SqueekMining and keep working. Because they are resolved through the NFT at use, no
  redeploy is needed if the NFT's pointer stays valid; if Squeekchain redeploys SqueekNFT or SqueekToken, a new
  escrow must be launched with the new addresses. Should Squeekchain lower `maximumLevel` under an open
  merge-ready order, the fill still refuses a Squeek that can no longer merge (`AtMaximumLevel`).
- **Staking / deposited Squeeks.** The brief mentions deposited Squeeks and `Staking mergeDeposited`. Squeekchain
  documents staking as "in active development" and the published ABIs contain no deposit function. A Squeek held
  by any other contract simply is not owned by the maker, so every fill involving it reverts with
  `MakerNoLongerOwns` or `NotTokenOwner`; the website should tell holders to withdraw before trading.
- **Unclaimed SQK travels with the Squeek and is not part of the trade.** SqueekMining credits rewards to the
  token, not the owner, and only the current owner may claim. The escrow does not touch claims and no order
  pins a credit amount: a seller or swap maker may claim right before a fill, and the buyer's dry run is not
  binding on it. The website must warn sellers to claim first and show buyers what they would be getting. What
  the contract does rule out is the same-transaction window: `fillSwap` hands the maker's Squeek to the taker
  before the taker's Squeek reaches the maker, so a contract maker cannot claim from its `onERC721Received` hook
  while it still owns the Squeek it is giving away (the taker always controls fill timing, so the mirror image
  gives the taker nothing it could not do in the previous transaction).
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
  `OrderNotOpen` before any transfer. Asks and swaps are per token: if a maker lists the same Squeek twice, only
  one fill can succeed. The other listing reverts with `MakerNoLongerOwns` while the Squeek is away and with
  `StaleOrder` for good once it has been traded through the escrow, even if the Squeek later returns to the maker.
- **Stale orders still need a cancel.** The trade counter only sees transfers this escrow performs. If a maker moves
  a listed Squeek out and back by any other route (a direct transfer, another marketplace) with the escrow still
  approved, the listing is live again at its old terms; and a listing whose Squeek was merged into, moved or
  un-approved stays `Open` (no event) until cancelled or expired. Makers should cancel orders they no longer want,
  and the website should show `isFillable`, not `isOpen`, as the state of an ask or swap and prompt the maker to
  cancel leftovers after every merge, sale or transfer.
- **Price discovery** is off-chain. Prices are the makers' own; the contract charges nothing and enforces no
  bounds beyond non-zero.
- **The website must verify addresses** (escrow from the launch handoff, Squeekchain contracts from the
  Deployments page and API identities) and refuse trading on mismatch, dry-run every transaction with `eth_call`,
  and show the testnet banner, as the approved brief requires.

## Security notes

- `ReentrancyGuard` on every state-changing function, checks-effects-interactions throughout: an order is marked
  Filled or Cancelled, the trade counters are bumped and its event emitted before any token moves. Tests exercise
  reentry through ERC-721 receive hooks from a taker, a bid maker and a swap maker, and a swap maker that tries to
  claim the offered Squeek's SQK credit from its hook (it no longer owns the Squeek when the hook runs).
- `transferFrom` on SQK only ever moves tokens from `msg.sender` (ask taker paying the maker, bid maker escrowing,
  swap maker escrowing, swap taker paying). Escrowed SQK leaves only via `safeTransfer` to the order's taker or
  maker.
- No `selfdestruct`, `delegatecall`, assembly, external library calls, initializers, upgrade paths, or
  `abi.encodePacked` with dynamic data. The runtime is about 12 KB (EIP-170 limit 24 KB; a test asserts it). A
  scratch test deploying the init code with CREATE2 from a factory on an empty chain and scanning the runtime for
  DELEGATECALL / CALLCODE / SELFDESTRUCT passes.
- `forge` lint reports only notes: `block.timestamp` comparisons (the expiry design), a `uint64(block.timestamp)`
  cast that cannot truncate for the next five hundred billion years, and `reentrancy-no-eth` on the ERC-721
  transfers, which is the linter not seeing OpenZeppelin's `nonReentrant` modifier; the reentrancy tests cover
  those calls.
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

Tests (`test/SqueekMatchEscrow.t.sol`, 107 tests across 8 suites) use local mocks of SqueekToken, SqueekNFT,
SqueekMining and SqueekCore (`test/mocks/`) and cover every create/fill/cancel success path, each named failure
(expired, closed, wrong kind id, self-trade, not owner, approval missing or revoked, maker transferred or burned
the Squeek, maker merged into the listed Squeek, Squeek traded through the escrow and returned, level mismatch,
dead position, pending power change, cooldown active, at maximum level, unfillable bid or swap level, insufficient
SQK balance or allowance, both swap sides paying, same token, duration too long, receiver cannot accept
ERC-721), SQK conservation, refund routing, reentrancy, swap settlement order against a claiming maker contract,
`isFillable`, and fuzzed expiry, amounts, swap differences and the merge-ready gate. They read no environment
variables and do not depend on the caller address.

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
