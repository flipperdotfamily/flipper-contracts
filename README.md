# flipper.family contracts

Coin-flip tokens against a bankroll held in **$FLIPPER**, the protocol's own token, on **Robinhood Chain** (4663,
Arbitrum Nitro), with **Dice** (a Pyth Entropy v2 fork) for randomness. Addresses and defaults live in
`script/lib/RobinhoodAddresses.sol`; `script/Deploy.s.sol` deploys everything.

- **$FLIPPER** launches from the `RevenueRouter` on its own hookless Uniswap v4 ETH pool, seeded by the router, with
  holder rewards built into the token (see "Holder rewards").
- **Tradable tokens:** majors and trusted tokens are allowlisted, Robinhood stock tokens are approved by an attached
  verifier, and a curated set of Robinhood Chain tokens is whitelisted by exact pool, all set by the owner multisig
  (behind a timelock). A launchpad-attachment framework lets more launchpads plug in. Listings still need a test trade whose
  round trip costs ≤ 4% (`listingMaxRouteCostBps`).
- **No keeper:** upkeep is permissionless, with fixed onchain rules, triggered by anyone or by a lightweight worker
  (see "Keeperless upkeep").
- **Partners** earn a share of the flips they bring and can pass part of it to their players as better odds (see
  "Partners").

All upgradeable contracts are deployed behind `TransparentUpgradeableProxy`s (OpenZeppelin v5). Each proxy has its own
`ProxyAdmin`, owned by `PROXY_ADMIN_OWNER`; use a TimelockController or multisig in production.

```sh
git clone --recursive https://github.com/flipperdotfamily/flipper-contracts && cd flipper-contracts
forge build && forge test
```

The TypeScript SDK, the widget and the mobile SDKs are in
[flipperdotfamily/flipper-sdk](https://github.com/flipperdotfamily/flipper-sdk) (`@flipperdotfamily/sdk` ships the
deployment's addresses and typed ABIs of these contracts).


## Mainnet deploy (Ledger)

`script/mainnet.sh` deploys to Robinhood Chain in resumable steps (`script/DeployMainnet.s.sol`), every transaction
signed on a Ledger: each step is simulated, confirmed, broadcast with `--slow` and re-simulated to prove nothing is
left; any failed step is simply run again. Configure `.env.mainnet` from `.env.mainnet.example`. The script runs
from flipper's main repository, where this repo is checked out as `contracts/` beside the SDK at `packages/` (its
`pin`, `release` and `record` steps write the deployment into the SDK, publish it and push both); the full runbook
(wallets, funding, Railway and Vercel settings) is `DEPLOY.md` there. To rehearse on an anvil
fork: `REHEARSAL=1 SIGNER=unlocked OPERATOR_SIGNER=unlocked` with throwaway addresses and `STATE_FILE`/`MANIFEST_FILE`
pointing at `deployments/rehearsal.*`.

## Contracts

| Contract | Role |
|---|---|
| `FlipperHouse` | Escrow, pricing, bankroll accounting, randomness callback and settlement (the hot path). Its cold paths run in `house/HouseModule` by delegatecall behind one-line stubs, so its ABI is whole (see "House layout") |
| `PartnerRegistry` | Partner codes (ERC-8021 attribution), payouts, tiers and discounts; approval-gated (see "Partners") |
| `base/V4SwapEngine` | Multi-hop Uniswap v4 exact-in/exact-out swaps and revert-based quotes. Every call is gas-capped and wrapped in `try`, so it never reverts |
| `randomness/DiceEntropyAdapter` | Dice Protocol randomness (DiceEntropy, a Pyth Entropy v2 fork): prompt first deliveries settle normally, anything later or recovered settles in safe mode (see "Randomness") |
| `randomness/PythEntropyAdapter` / `ChainlinkVRFAdapter` | The same interface for Pyth Entropy v2 and Chainlink VRF v2.5 deployments |
| `ListingPolicy` | Decides which tokens list permissionlessly: whitelisted pools, attached launchpad verifiers, allowlisted tokens (see "Listing policy") |
| `verifiers/CodehashVerifier` (+ `PonsVerifier`) | Launchpad / issuer analysis attached to the ListingPolicy: registry provenance, canonical pool, pinned hook code, token code template |
| `adapters/V4RouteAdapter` | Permissionless listing of vetted v4 tokens, paired with ETH or an allowlisted quote (USDG). Keeps the deepest pool per token |
| `adapters/V3RouteAdapter` + `adapters/V3BridgeHook` | Permissionless listing of tokens whose liquidity is in Uniswap v3: the bridge hook turns a canonical v3 pool into a liquidity-less v4 pool that swaps through v3, so the house routes through it unchanged (see "Uniswap v3 liquidity") |
| `RevenueRouter` | Launches $FLIPPER (a self-seeded v4 pool) and receives all creator / LP fees. Anyone `harvest()`s them for a capped bounty; $FLIPPER is split to the bankroll and holders, ETH is auctioned for $FLIPPER (see "Keeperless upkeep") |
| `LiquidityKeeper` | Holds the launch position (a v4 PositionManager NFT) for good: immutable, no owner, no admin, no way to decrease or move it. Anyone `collect()`s its fees to the router; optionally locks it forever in UNCX (see "Launch path") |
| `DutchAuctionConverter` | Sells swept house inventory and the router's ETH revenue for $FLIPPER by descending-price auction: no oracle, no `minOut`, anyone takes |
| `adapters/WethWrapperHook` | One liquidity-free v4 pool (ETH, WETH, fee 0) that swaps 1:1 by wrapping / unwrapping: WETH's route to native ETH (see "WETH") |
| `FlipperRewardToken` | The reward-bearing $FLIPPER: holder rewards streamed in $FLIPPER to every eligible balance, built into the token (see "Holder rewards"). `FlipperToken` is the plain variant (`REWARD_BEARING=0`, tests) |
| `HolderRewards` | *Retired*: the keeper-posted Merkle holder rewards in a launchpad token. No longer deployed; the source is kept for existing proxies |
| `PrincipalLock` | The team's stake: the opening buy staked in the TreasuryVault for good. Not upgradeable; only its earnings above the principal (and its rewards) can come out, and only to the dev claim wallet, which its owner (a cold key) can change (see "Team stake") |
| `TreasuryVault` | Bankroll staking for a non-transferable receipt (sFLIPPER). Stakers keep 20% of their pro-rata share of bankroll growth above a high-water mark; the other 80% becomes protocol-owned. Once set, it is the only account that can withdraw bankroll |
| `FlipRewards` | *Retired*: volume-weighted launchpad-token rewards for flippers. The house no longer calls it (its hook was removed to make room for keeperless upkeep under EIP-170; the storage slot is kept) |
| `lens/FlipperLens` | Batched reads and previews for the frontend and SDK |

## Flip lifecycle

1. **`flip(token, amount, minWinChance, deadline)`.** The house prices the stake onchain in both directions by
   simulating the real swaps:
   - `S` is what selling the stake would yield in $FLIPPER; `B` is what buying the same amount would cost.
   - Route cost `h = (B−S)/(B+S)` covers LP fees, hook fees and price impact.
   - Win chance `p = min(45%, (1 − h − 2%)/2)`. The 2% is the minimum expected profit (`minHouseEdgeBps`) *after*
     every swap the house sponsors. The house's expected profit per flip is `V·(1 − h − 2p)`, i.e. 10% − h at base
     odds, so odds only start to shift once `h > 8%`.
   - Liability `L = 1.05·B`.
   - The flip is rejected if `h > 10%`, `p < 40%` or `L` exceeds its cap,
     `min(maxBetBps, kellyBps × f*) × (treasury − reserved)` (see "Max bet: half Kelly" below).
   - Otherwise `L` is reserved, the stake escrowed, and randomness requested. The player pays the randomness fee in
     `msg.value` (excess refunded; a sender that can't take ETH back, such as a contract without `receive`, gets it
     as a claimable ETH balance instead of a revert: `claim(address(0))`).
2. **The randomness callback** settles in the same transaction:
   - **Loss.** The stake is sold for $FLIPPER into the bankroll with a floor of `S·95%`. If the sale can't clear the
     floor, the house keeps the tokens as inventory. The loss stands either way. Half of the flip's expected
     profit, scaled up because only losses pay it (`÷(1−p)`), is set aside for holders.
   - **Win.** The house buys exactly `amount` of the token for at most `L` and pays out 2× the stake. If the buy
     fails, the player gets the stake back plus `min(B, S_settle·B/S)·1.05` in $FLIPPER. That value uses the
     settle-time sell quote, which can't be flash-manipulated. If the pool is unusable in both directions (or
     what's left of the callback budget after a failed buy can't fit the fallback quote), the stake is returned
     and the winnings are left `WinPending` for anyone to resolve (`resolvePendingWin`, see "Keeperless upkeep").
   - **$FLIPPER flips** pay 2.05× and need no swaps.
3. **Nothing in the callback can revert on an outcome-dependent path.** Every swap, quote, transfer and rewards
   call is gas-capped and wrapped in `try`, and every swap attempt leaves a 350k-gas settlement reserve untouched
   (`_attemptGas`), so the callback can't run out of gas whatever a token, hook or pool does
   (`test/SettlementGas.t.sol`). Two kinds of delivery settle in **safe mode**, with no swaps and no
   pushes (losses become inventory; wins return the stake and are resolved later by anyone):
   - a delivery whose timing may have been chosen by someone who already knows the outcome, such as an Entropy
     recovery after a failed first attempt;
   - a delivery nested inside one of our own calls.

## Economics (defaults, owner-tunable within hard bounds)

At launch (the edge schedule below steps these down as the house's net buybacks grow):

| | $FLIPPER flips | Token flips |
|---|---|---|
| Win chance | 45% | 45% while route cost ≤ 8%, then `(1 − h − 2%)/2` (≥ 40%) |
| Payout | 2.05× in $FLIPPER | 2× in the token (fallback: stake back + 1.05·B in $FLIPPER, a fixed 5% bonus) |
| House expected profit | 7.75% | `10% − h` at base odds, never below 2% after swap costs |
| To $FLIPPER holders | half of it | half of it |
| Max liability per flip | half Kelly: 2.08% of the free bankroll (a ~1.99% stake) | half Kelly: 0.6–2.75% (by route cost), ≤ 5% |

### Edge schedule

The base win chance and the $FLIPPER payout step down as the house proves itself, keyed on its own **net buybacks**
(`setEdgeSchedule`, owner):

| house net buybacks (`buybackHigh`, ETH) | base win chance | $FLIPPER payout | $FLIPPER edge | token edge (free route) |
|---|---|---|---|---|
| below 10 | 45% | 2.05× | 7.75% | 10% |
| 180 | 46.25% | 2.025× | 6.34% | 7.5% |
| 350 and above | 47.5% | 2.0× | 5% | 5% |

Linear in between, rounded in the house's favour (win chance and payout both rounded down).

- **The metric.** `netBuybackEth` counts the real ETH the house's own settlement swaps move through the $FLIPPER pool
  hop: + when a token flip's lost stake is sold (… → ETH → $FLIPPER), − when a token flip's winnings are bought
  ($FLIPPER → ETH → …), including `resolvePendingWin`. Every route ends in the ETH-paired $FLIPPER pool (WETH through
  the wrapper, USDG-quoted and v3-bridged routes through ETH), so every token flip counts. $FLIPPER flips and
  $FLIPPER fallback payouts don't swap and don't count. The amounts come from the swap engine's executed hops (the
  ETH into the last hop of a sale, out of the first hop of a buy), never a quote or a price. No event of its own
  (read `edgeProgress()`).
- **The ratchet.** The edge keys on `buybackHigh`, the highest `netBuybackEth` so far, so it only ever steps down. A
  losing streak doesn't raise it again; the drawdown-scaled Kelly (below) handles the risk during streaks. The owner
  can re-base the ratchet (`setBuybackHigh`, within [0, `toEth`]) for recovery or when migrating to a new house; a
  value below the net lasts only until the next booking raises it back.
- **Why it's hard to game.** The only way to raise `netBuybackEth` is for the house to actually receive value from
  players' lost token flips: the counted ETH is the real output of selling a real lost stake, and the real cost of
  buying a real win. A flash loan can't settle a flip. A price move around a settlement either worsens the house's
  trade (a dump before a sale: a smaller +; a pump before a buy: a larger −) or improves it, and then every extra wei
  was handed to the house by the manipulator (it sold into their pump or bought from their dump), so it costs at
  least what it moves (tested: a same-transaction pump-and-dump that added 0.1 ETH to the net cost the attacker
  0.29 ETH). The $FLIPPER pool's own price doesn't enter at all: the ETH amounts are set by the other hops. In
  expectation the net grows by about (loss chance − win chance) × stake, 10% of token-flip volume, which is about
  what players lose, so pushing it up costs about as much as it moves.
- **Unchanged around it.** A flip keeps the odds and payout it was made at. The schedule sets only the base: route
  costs (the chance-based fee), the minimum edge (`minHouseEdgeBps`, 2%, enforced on every flip, also between the
  endpoints) and partner discounts apply on top. Bounds: win chances within [`minWinChanceBps`, 49%], payouts within
  [2×, 2.15×], the edge at both ends at or above `minHouseEdgeBps`, from < to; `toEth` 0 turns it off (Params'
  `baseWinChanceBps` / `flipperPayoutBps` apply). Views: `currentBaseWinChanceBps()`, `currentFlipperPayoutBps()`,
  `edgeProgress()` (net, high, from, to, current win chance, current payout), `edgeSchedule()`.

### Max bet: half Kelly

Each flip's liability is capped at `min(maxBetBps, kellyBps × f*)` of the unreserved bankroll (`treasury −
reserved`). f* is the bankroll's exact Kelly fraction for that flip, computed onchain from the flip's own terms at
flip time: `f* = q − p·W/G`, where
- `p` is the player's win chance after the chance-based fee and any partner discount, and `q = 1 − p`;
- `W` is what the bankroll loses on a player win: the buy `B` on a token flip, or payout − stake (1.05× the stake)
  on a $FLIPPER flip;
- `G` is what it keeps on a player loss: the sale proceeds `S` less the partner's share and the holders' share of the
  edge, exactly as settlement books them.

`kellyBps` defaults to 5000 (half Kelly; bounds (0, 100%]) and `maxBetBps` stays a hard ceiling at 5%.

**Drawdown-scaled Kelly** (`setKellySchedule`, owner). Bets back off as the bankroll nears the breaker: with the
drawdown `dd = 1 − NAV per unit / its all-time high` (what the breaker measures), the multiplier is `kellyBps` (the
max, half Kelly) while `dd ≤ kellyDdStartBps` (0), sliding linearly to `kellyMinBps` (quarter Kelly, 2500) at
`kellyDdEndBps` (50%, the lock point). Before the drawdown check is live (no ATH yet, or a treasury under
`lockMinTreasury`) it is the max. Bounds: 0 < min ≤ max ≤ 100%, start < end ≤ 50%. View: `currentKellyBps()`. Costly routes,
partner discounts and partner shares all shrink the cap automatically, and a flip whose f* ≤ 0 is rejected
(`FlipRejected(7)`, the bet-size code).

**Flip limits** (`setFlipLimits`, owner or guardian). The randomness adapter caps open requests across all players
(`maxOpen`, 256 on Robinhood), so one player may hold at most `maxOpenPerPlayer` flips waiting for randomness
(default 4; `FlipRejected(9)` beyond it), and every flip must carry at least `minLiability` of liability
(`FlipRejected(2)` below it; 50,000 $FLIPPER at launch, about $0.34 or five randomness fees). Filling the adapter
then takes 64+ funded addresses, 256 fees and 256 real stakes at negative expected value, per refill; before, 32
one-wei flips from one address (about 0.0008 ETH) blocked every flip (stress test F-1). The floor is a fixed
$FLIPPER amount, so it reads no price and nothing can move it; it scales with the price, so the guardian (the operator key) or the owner
lowers it as $FLIPPER appreciates. A token flip's liability is `1.05·B` (it also reserves the fallback bonus),
so capping the liability keeps the buy actually at risk 5% under Kelly. `previewFlip(...).maxLiability` is the flip's
own cap (the lens `maxStake` searches against it); `maxLiability()` is only the ceiling.

| flip | exact Kelly f* | half-Kelly cap (share of the unreserved bankroll) |
|---|---|---|
| token, route cost ~0 (10% gross edge) | 5.5% | 2.75% |
| token, route cost ~5% | 2.8% | 1.41% |
| token, route cost ~10% (2% edge floor) | 1.2% | 0.62% |
| $FLIPPER (45% × 2.05×, 7.75% edge) | 4.17% | 2.08% (a ~1.99% stake) |

The exact form costs a few hundred gas more than the "EV per unit of liability" shortcut, which undershoots Kelly by
9–12% at these edges (it divides by W instead of G).

- **LP fees** of the protocol-owned $FLIPPER position are split `treasuryShareBps` to the bankroll and the rest to
  holders. The deployment sets it to 0: both legs go to holders, the $FLIPPER leg streamed directly and the ETH leg
  sold for $FLIPPER by Dutch auction first.
- **Holder rewards** are paid in $FLIPPER: the router hands the holders' share to its `rewards` distributor (the
  reward-bearing token's `distribute`).

## Holder rewards (`FlipperRewardToken`)

$FLIPPER pays holder rewards itself, in $FLIPPER, to every eligible balance: no staking, no
snapshots, no keeper, no owner.

- **Where it comes from.** Half of every flip's expected profit (`rewardsShareBps`, skimmed from losses into
  `house.rewardsAccrued`) and the protocol-owned pool's LP fees, both collected by anyone's `router.harvest()` and
  handed to `token.distribute(amount)`.
- **Streaming.** `distribute(amount)` adds to the stream without ever slowing it: the rate becomes the larger of the
  current rate and (everything not yet streamed) / 7 days (`STREAM`), and the stream runs until all of it is paid. A
  small amount extends the end at the current rate; a large one speeds the stream up and ends it 7 days out. Anyone
  can call it; `distribute(0)` only checkpoints and syncs the vault. (Re-spreading the remainder over a fresh week on
  every call, as before, let anyone delay ~37% of a stream past its week with hourly zero calls: stress test F-2.)
- **Accrual.** A reward-per-token accumulator and a signed correction per account: an account's earnings are
  `rewardPerToken × balance + correction` at all times. A transfer carries `rewardPerToken × value` of correction
  with the tokens, so accrued rewards never move with them. Earnings are exactly balance × time, which is why
  **snapshot sniping and flash loans earn ~0**: a balance held for a block earns a block's worth, and buying right
  before a distribution earns nothing retroactively (the new amount only starts streaming then). Transfers,
  self-transfers and churn create nothing (`test/RewardToken.t.sol` invariants: owed ≤ distributed, the reserve
  covers everything claimable, eligible supply = sum of eligible balances).
- **Claiming.** `claimable(account)`, `claim()`. Pull only: nothing is pushed into balances, so an AMM pair or a
  lending market never sees its balance change behind its back.
- **Where $FLIPPER earns.**
  - Wallets and smart wallets: accrue and `claim()`.
  - Stakers in the `TreasuryVault`: through the vault, on their share of the bankroll (depositor shares × price,
    net of the uncrystallised fee), plus 20% of bankroll gains; `vault.claimRewards()`. Protocol-owned shares never
    earn.
  - The official v4 pool (and every v4 pool: all v4 liquidity sits in the PoolManager) earns nothing: LPs earn swap
    fees.
  - Other contracts (a v3 pool, a lending market, a bridge) accrue to their own address like any holder. If they
    can call `claim()` they can collect it; otherwise it stays in the reserve forever (never re-streamed, never
    double counted), like a burn. Hold $FLIPPER in a wallet or stake it to earn.
  - Never (`rewardExempt(account)`): the token itself (the reward reserve), the dead address, the PoolManager, and
    the house, router, auction converter and LP keeper. The set is fixed: the first three in the constructor, the rest
    in a one-time `seal` by the deployer before any distribution. There is no owner and no way to change it
    afterwards. Exemption only affects rewards: the token has no pause, blacklist or transfer restriction.
- **The vault's virtual balance.** The vault holds no $FLIPPER of its own (stakes sit in the house bankroll, which is
  exempt), so the token credits it with `vault.depositorAssets()` as its eligible balance and ignores its real
  balance (claimed rewards waiting for stakers). The vault claims what that balance earned and passes it to
  depositors pro rata to shares (reward-per-share accumulator with per-account corrections, exact across deposits
  and withdrawals).
- **Lazy sync and its error bound.** The virtual balance is re-read on every vault deposit, request, withdrawal,
  crystallisation and claim, on every `distribute` (so on every harvest), and by anyone through `syncVault()`.
  Between syncs it is stale by the bankroll's PnL since the last sync: stakers are credited on `V_sync` instead of
  `V_now`, so over a window in which `R` $FLIPPER streams the misallocation between stakers and wallets is at most
  `R × |V_now − V_sync| / eligibleSupply`. Each flip moves the bankroll by at most its liability (≤ 5% of the free
  bankroll) and stakers carry only their share of it (20% of gains above the mark), so the error is small and resets
  at every harvest. A settlement-time sync was measured and left out: +96 B of house code (kept for the house refactor)
  and one `syncVault` call per settlement.
- **Gas.** A transfer between holders costs a constant ~2 extra storage writes (the two corrections); moving tokens
  into or out of an exempt address (a pool trade) also folds the stream into the accumulator. Figures are in
  `test/RewardToken.t.sol` (`test_gas_per_transfer`).

## House layout (`FlipperHouse` + `HouseModule`)

The house was at the EIP-170 limit, so its cold paths moved out:

- `house/FlipperHouseBase` holds everything shared: types, constants, immutables, storage (append-only), events,
  errors and helpers. Types, events and errors are referenced as `FlipperHouseBase.X` (Solidity doesn't expose
  inherited types through the derived contract's name).
- `FlipperHouse` (the proxy's implementation) keeps the hot path: `flip`, `previewFlip`, the randomness callback and
  settlement, `claim`, the bankroll, and the views.
- `house/HouseModule` holds the cold paths: `initialize`, `cancelFlip`, listing, `resolvePendingWin` /
  `sweepInventory` / `writeOffInventory`, every admin setter, and `claimPartner` / `setPartnerRegistry`. The
  house keeps a one-line stub per function with the same signature that delegatecalls the module and returns its
  raw result, so selectors, ABI and events are unchanged for every consumer.
- The module shares the house's storage layout exactly: `script/storage-layout.sh` checks it (`HouseModule ==
  FlipperHouse`). It refuses direct calls (`onlyDelegateCall`), holds no funds or state of its own, and never
  selfdestructs or delegatecalls out. The house's `module` is an immutable of its implementation, so an upgrade is
  `new HouseModule` + `new FlipperHouse(…, module)` + one `upgradeAndCall` (`script/Upgrade.s.sol TARGET=house`).
- Sizes: house 18.2 KB (6.4 KB of headroom), module 19.3 KB. `TokenConfig` already carries two unused fields
  for per-token overrides (`maxLiability`, `callbackGasLimit`: a per-token max bet, e.g. a token's max-transaction cap, and a
  callback gas class), so adding their logic needs no further layout change.

**Swallowed calls have gas floors.** Wherever a call's failure is swallowed (settlement swaps, the partner lookup,
the in-kind buy of `resolvePendingWin`, sweep and refund transfers, the router's flush / harvest calls /
`distribute`, the vault's reward `claim` / `syncVault`), a `gasleft()` check reverts the whole transaction when
there isn't enough gas for the call. Otherwise `eth_estimateGas` (which looks for the least gas that doesn't revert)
would starve the call and the transaction would "succeed" without its side effect. Settlement deliveries well short of
the callback budget (below 15/16 of it, allowing for the 63/64 kept at each of the ~3 call frames between the
provider and the house) revert, so the provider retries with the budget or recovers in safe mode. Raising
`callbackGasLimit` while flips are pending makes those flips' deliveries (requested with the old budget) recover in
safe mode.
`test/GasFloors.t.sol` and `test/RewardSystem.t.sol` send each call with exactly its estimate and check the side
effect happened.

## Drawdown circuit breaker

If the bankroll's value per unit falls below **50% of its all-time high**, the protocol locks completely, and only
the **unlocker** (an operator key; the owner can name a new one at any time) can unlock it.

- **What is measured: the NAV per bankroll unit, in $FLIPPER.** The bankroll is `house.treasury` (the $FLIPPER that
  backs flips, pending liabilities included). Capital deposits — the staking vault's, and the very first seed — mint
  *bankroll units* at the current NAV; capital withdrawals (stakers' exits, including the PrincipalLock's excess)
  burn them at the current NAV. So `treasury / navUnits` moves only with performance: paid-out wins and
  exploits lower it; lost stakes and income (revenue, auction proceeds, donations) raise it; stakers coming or going
  never move it. Protocol-owned shares are ordinary capital here, and the vault's performance fee (a transfer between
  share classes inside the vault) doesn't touch it. Inventory (tokens kept from failed sales) counts at zero until an
  auction turns it into $FLIPPER income.
- **No manipulable inputs.** Only the house's own $FLIPPER accounting is read: no spot price, pool or oracle, so no
  flash-loaned swing can trip or dodge the lock. (Consequence: the measure is in $FLIPPER, not USD; a $FLIPPER price
  crash doesn't trip it.)
- **Trigger.** The all-time high is tracked onchain; the check runs after every settlement, payout, pending-win
  resolution, inventory sweep and deposit, and anyone can call `checkDrawdown()`. It trips strictly below half
  (`DrawdownLocked(nav, ath)`). The high starts at the first seed, and the check doesn't run while the treasury is
  below `lockMinTreasury` (set to a tenth of the seed at deploy), so a dust bankroll can't grief it.
- **Complete lock.** New flips (`FlipRejected(8)`), listings, cancellations, pending-win resolution, sweeps, claims
  of deferred payouts and partner shares, bankroll deposits and withdrawals, every vault action (deposit, withdrawal
  request, withdrawal, reward claim, crystallisation), harvests, revenue processing, auction lots, and holder-reward
  claims and distributions on the $FLIPPER token all revert with `ProtocolLocked`. **Staker withdrawals are frozen
  while locked**, by design. Plain $FLIPPER transfers and governance settings are unaffected.
- **In-flight flips are kept.** Randomness delivered while locked is recorded (`SettlementDeferred`); after unlock
  anyone settles it with `settleDeferred(flipId)`, market-free (safe mode: losses become inventory, wins return the
  stake and reserve the winnings), because the outcome is already public. Such a flip can't be cancelled. The
  randomness adapter's delivery succeeds either way, so its failure / recovery paths are untouched.
- **Unlock.** `unlock(resetAth)` by the unlocker only (not the guardian; ownership transfers don't move the role).
  The owner can't unlock directly, but it can name the unlocker at any time (`setUnlocker`, which also drops a pending
  hand-over). `resetAth = true` re-bases the high to today's NAV (the usual choice after the cause is dealt with:
  keeping the old high would re-lock at the next check); `false` keeps it, for when the NAV has already recovered.
  The role moves in two steps (`transferUnlocker`, then `acceptUnlocker` by the new key), or directly by the owner.
  **If the unlocker key is lost or compromised, the owner names a new one**, so the breaker is never orphaned.
- **Manual reference reset.** `resetNavAth(newAth)` (the unlocker only, while unlocked) lowers the all-time high the
  50% line is measured against, to anything from today's NAV per unit up to the current high (`0` = today's NAV),
  and emits `NavAthReset(oldAth, newAth, nav, caller)`. Use it for a genuine cold streak (the NAV sliding on
  ordinary flips, no sign of exploitation or a broken pool) before the lock trips: the lock then comes at half the new
  reference, and new highs raise it again as usual. It can only lower the reference, never raise it (that could only
  force a lock), and it needs the unlocker's key (the operator's at launch). A house that already locked re-bases
  through `unlock(true)`.
- **The auction clock stops while locked.** Nobody may take a lot during a lock, so the Dutch auction subtracts the
  house's `lockedTime()` (seconds locked, the current lock included) from each lot's age: a lot resumes at the price
  it had when the lock began (liveness M-4).
- Cancel delays are bounded: `guardianCancelDelay` ≤ 30 days (the emergency delay), `playerCancelDelay` ≤ 30 days.
- Guardian cancellations now also require the randomness to be provably unrevealed, except after a 30-day emergency
  delay; `maxReservedBps` (default 30% on Robinhood) caps all pending liabilities as a share of the treasury.

## Partners (`PartnerRegistry`)

Partners that bring flips earn a share of each attributed flip's expected house profit, and can hand part of it
back to their players as better odds.

- **Attribution** is an ERC-8021 data suffix after `flip`'s arguments: `codes ‖ codesLength (1 byte) ‖ schemaId
  (0) ‖ 0x80218021802180218021802180218021`, codes ASCII and comma-separated (`registry.suffixOf(code)` builds
  it; viem: `dataSuffix`). The house hands the tail to `registry.resolve(player, tail)` in a gas-capped (50k),
  bounded-returndata staticcall; a failing, reverting, gas-burning or return-bombing registry means "no partner"
  and the flip goes on at normal odds. The same suffix on a `previewFlip` eth_call (from the player) previews the
  partner odds.
- **Registration** is approval-gated: anyone `register`s a code (1–32 of [a-z0-9_-]) with a payout and a discount;
  the owner `approve`s it into a tier, and may re-tier, suspend, or allow self-attribution. The controller changes
  payout / discount. A player can't attribute their own flips (player = payout or controller) unless allowed.
- **Pricing**, fixed at flip time: `E` = the flip's expected house profit (bps of value); the tier cut
  `C = tierCut·E`, capped so that `E − C ≥ minHouseEdgeBps`; the discount `D = C·discount` goes to the player as
  win chance (+D/2 on token flips, +D/payout on $FLIPPER flips); the partner keeps `A = C − D`. Default tiers: 10%,
  20%, 30% of `E` (at most 50%).
- **Accrual**: like the holder share, on a losing flip only, scaled by 1/P(loss): the partner gets `A` of the
  flip's mid value, the rest of the expected profit splits between holders and the bankroll as before, so the cut
  comes out of both halves proportionally, and all shares together never exceed the loss's proceeds.
  `claimPartner(id)` (anyone) pays the partner's current payout address.
- **Events**: `FlipPartner(flipId, partnerId, cutBps, discountBps, winChanceBonusBps, partnerShareBps)` for each
  attributed flip (`FlipRequested` is unchanged), `PartnerAccrued(partnerId, flipId, amount)`,
  `PartnerClaimed(partnerId, to, amount)`; registry events for registration, approval, updates and tiers.
- Views: `house.flipPartner(flipId)`, `house.partnerAccrued(id)`, `house.partnerAccruedTotal()`,
  `registry.partner(id)`, `registry.idOfCode(keccak256(code))`, `registry.tierCutBps(tier)`.

## Keeperless upkeep

No keeper role exists on the house or the router; every upkeep call is permissionless and follows fixed rules.

- **`house.resolvePendingWin(flipId)`** pays a `WinPending` flip (the stake was already returned at settlement):
  1. buy exactly `amount` of the token for at most the reserved liability `L` (the flip-time `1.05·B`) → `Won`;
  2. else, once `createdAt + pendingTimeout` has passed (`Params.pendingTimeout`, 1 day by default, bounds 1 hour
     – 30 days), pay `L` in $FLIPPER → `WonFallback`;
  3. else revert `TooEarly`.

  Whoever calls picks the moment, and can at most push the payout's cost to `L`, which the flip priced and reserved
  as its worst case. No settle-time valuation is used (a settled simulation's secret tag could be precomputed by a
  caller simulating the transaction), so nothing on this path can be inflated. Detect "resolvable now" by
  simulating the call (`eth_call`); `FlipperLens.pendingWins(house, player, fromId, toId)` lists open ones.
- **`house.sweepInventory(token, amount)`** moves `amount` of inventory (tokens the house kept when a loss's sale
  couldn't clear its floor) to the converter as a lot referenced at its flip-time value (`inventoryValue`,
  pro rata). A token that can't be transferred is skipped (`InventoryStuck`) and left for the guardian's
  `writeOffInventory(token)`.
- **`DutchAuctionConverter`** prices each lot in $FLIPPER per 1e18 units of the asset: it starts at
  `startMultiple` (4) × the best reference — the lot's own (inventory), the asset's last clearing price (ETH), or a
  one-time owner seed for an asset that has never cleared (`seedPrice`; the deploy seeds ETH at the pool's price
  right after launch) — or at 2^128 with none, and halves every `halfLife` (30 minutes; linear within each
  half-life). A lot with a reference has a **floor** at half of it, which itself halves every day: a thin market
  nobody watches can't clear a lot far below the last clearing price in one quick descent, while a real drop in the
  asset only delays the sale by days. One take can lower the asset's `lastPrice` by at most half, so a single cheap sale
can't collapse the next lots' start. The price never stops falling, so every lot clears at the market. Anyone `take(lotId, amount, maxPrice)`s any part at the current price; house
  lots pay straight into the bankroll (`depositTreasury`), router lots pay the router. Only the house and the router
  can kick lots; the owner only manages that list.
- **`router.harvest()`** flushes the house's holder share, runs each owner-set harvest call (fixed target and
  calldata, e.g. a launchpad fee escrow's `claim()`; none on the default deployment; a failing one is skipped), collects the
  protocol-owned LP position's fees (`liquidityKeeper.collect()`), pays the caller `bountyBps` (0.1%) of the ETH and $FLIPPER that brought in —
  capped at 0.005 ETH and 1e-6 of the $FLIPPER supply per call — then `process()`es. Pre-existing balances and the
  house share earn no bounty, so donating to a fee source to farm it loses 99.9% of the donation.
- **`router.process()`** (also permissionless) splits the $FLIPPER held — the house share 100% to holders; creator
  $FLIPPER `treasuryShareBps` (50%) to the bankroll, the rest to holders — and kicks all ETH (≥ `minLotEth`,
  0.001 ETH, so no dust lots can drag the ETH reference down) into a converter lot.

## Treasury staking vault (`TreasuryVault`)

The vault pays stakers to seed bankroll liquidity early while the bankroll itself becomes protocol-owned: it keeps
growing after every staker has left.

**Accounting.** Stakes go straight into the house bankroll (`house.depositTreasury`); the vault holds no tokens.
- `A = totalAssets() = house.treasury()`, the whole bankroll. It includes `reserved`, because pending flips are
  not realized yet.
- `S = totalShares() = totalSupply() + protocolShares`. sFLIPPER is the stakers' share; `protocolShares` is
  protocol-owned liquidity (POL) and is not an ERC-20 balance.
- The price per share is `pps = A / S`, scaled by `PPS_SCALE = 1e27`. Everything that moves the bankroll moves
  it:
  - lost flips, the router's treasury share of creator fees, and plain `depositTreasury` donations raise it;
  - won flips lower it.
- **Bootstrap.** Whenever nobody holds shares, the whole bankroll becomes POL at 1:1. That covers the deploy's
  seeded bankroll, any donations, and any residue after everyone leaves. The share base is therefore always large,
  which rules out the first-depositor inflation attack. The first deposit into an empty vault (`A = S = 0`) mints
  1:1. If the bankroll were ever wiped out while shares exist (`A = 0 < S`), deposits revert until something is
  donated.

**Performance fee.** `crystallize()` runs at the start of every deposit, withdrawal, request and parameter change,
and anyone may call it. When `pps` is above the high-water mark `hwm`, 80% of the stakers' gain above the mark
(`performanceFeeBps`, default 8000) becomes protocol-owned. The vault mints protocol shares until the price
equals `p' = hwm + 20%·(pps − hwm)`: `f = A/p' − S`. Stakers therefore keep exactly 20% of their pro-rata gain.
The mark then moves to `p'`.

The textbook fee mint `f = fee·S/(A − fee)` pays a third party. It would undercharge here, because the new shares
dilute the protocol's own shares too. Solving in price space also keeps rounding (always in the protocol's favour)
at the price's precision, however small a position is.

Worked example: the vault holds 10 $FLIPPER, 1 of them staked by a user, and the bankroll earns 1.

| | before | +1 inflow, without a fee | after crystallization |
|---|---|---|---|
| user (1 of 10 shares) | 1.00 | 1.10 | **1.02** (+0.02 = 20% of their 0.1) |
| protocol (9 of 10 shares) | 9.00 | 9.90 | **9.98** (+0.98) |
| price per share | 1.00 | 1.10 | 1.02, and this becomes the new mark |

**High-water mark.** Nothing is charged while `pps ≤ hwm`. After a drawdown, stakers bear their full pro-rata share
of the loss, and the recovery up to the previous high is fee-free. Only growth above the mark is charged, so
stakers get ~20% of their share of *net* growth; they never get 20% of gross gains while bearing 100% of losses.
Two properties follow from this design:
- **Fees crystallize continuously.** A fee taken at a peak is not refunded if the bankroll then falls, so on a
  path that ends below its peak a staker can keep less than 20% of their net growth. They never keep more.
- **The mark is global.** Someone who stakes during a drawdown buys in at the lower price (existing stakers are
  unaffected) and also recovers fee-free up to the mark. Removing that would need per-staker marks and lazy
  settlement.

`test/TreasuryVaultInvariant.t.sol` checks the bound in its exact form: per share, from a staker's last deposit,
`pps ≤ gross` while `gross ≤ mark`, and `pps ≤ mark + 20%·(gross − mark)` above it. `gross` is the fee-free price
path.

**Lock and cooldown.**
1. Each deposit locks all of the staker's shares until `max(unlockAt, now + lockDuration)` (default 7 days).
2. After that, `requestWithdraw(shares)` queues shares and (re)starts `withdrawCooldown` (default 2 days) for
   everything pending.
3. `withdraw(minAssets)` then burns all pending shares at the price of that moment.

Pending shares stay staked: they keep earning, keep bearing losses and keep counting for holder rewards.
`cancelWithdraw()` un-queues them. Withdrawals are paid only out of the free bankroll, `house.withdrawable()` (also
`vault.freeBankroll()`): never the pending flips' reserved liabilities, and never so much that what stays falls
under their `maxReservedBps` cap (at 30%, the treasury must keep ≥ reserved / 0.3). So a large exit can't leave
pending flips sized for a bankroll that is gone (liveness stress test M-1). While pending flips hold too much of it,
`withdraw` reverts with `InsufficientFreeBankroll(available)`, `maxWithdrawable(user)` returns 0, and the
PrincipalLock's `withdrawableExcess()` reports at most that limit.

Lock changes apply to new deposits and cooldown changes to new requests; existing `unlockAt` / `readyAt` are kept.
Dev deploys (`DEV=1`) default to a 1-day lock and a 10-minute cooldown. Override them with `VAULT_LOCK_DAYS`,
`VAULT_COOLDOWN_HOURS` and `VAULT_FEE_BPS`.

**Receipt.** sFLIPPER (18 decimals) can't be transferred or approved; it is only minted and burned. Locks therefore
can't be bypassed, and balances only change through mint and burn `Transfer` events.

Holder rewards reach stakers through the vault (see "Holder rewards"): `pendingRewards(user)`, `claimRewards()`.
The vault's real $FLIPPER balance (rewards waiting to be claimed) never earns; its depositors' assets do.

**POL growth.** Protocol-owned liquidity grows from three sources:
- the bootstrap: the seed and donations;
- 80% of stakers' gains above the mark;
- its own pro-rata share of every PnL.

Every exit leaves the protocol's share untouched. When the last staker leaves, the whole bankroll is
protocol-owned.

**Admin powers.**
- **Vault owner** (Ownable2Step):
  - `setParams(feeBps ≤ 95%, lock ≤ 365 days, cooldown ≤ 30 days)`. It crystallizes first, so a fee change never
    applies to gains already made.
  - It cannot move or burn stakers' shares, and nothing can withdraw the protocol's: protocol-owned liquidity is
    permanent bankroll (there is no `withdrawProtocol`).
- **House owner.** `setVault` is one-time. Once the vault is set, `withdrawTreasury` is vault-only, so the owner can
  no longer take bankroll. The remaining trust assumptions:
  - the owner tunes odds and bet size within hard bounds, and vouches for owner-listed tokens (a malicious listing
    could leak value through flips);
  - anyone settles `WinPending` flips, at a cost capped at the reserved liability.
- **ProxyAdmin owner.** Can upgrade the vault and the house. Put a timelock in front of it.

**Timing.** Withdrawals are priced at the moment of `withdraw`, including still-unrealized pending flips, and a
matured request can be executed at any time. A staker who could see randomness before it is delivered could time an
exit around a large settlement. Robinhood Chain has no public mempool, and a single flip is capped
at half its Kelly fraction of the free bankroll (at most 5%, typically 0.6–2.75%).

## Launch path (`RevenueRouter`)

`launchFlipperV4Token` (default): the reward-bearing $FLIPPER is deployed with its fixed supply minted to the router,
which initialises a hookless ETH/$FLIPPER pool at a **$5k starting market cap** (`V4_START_MCAP_USD`), seeds **all
of the supply** into it as single-sided liquidity from that price to the minimum tick (held by the LiquidityKeeper,
never removable), and makes the opening buy in the same transaction: **exactly 12.5% of the supply**
(`OPENING_BUY_SUPPLY_BPS`; the deploy computes the ETH from the pool maths and the router enforces the amount as the
buy's minimum out; about $890 of ETH at the $5k start, fee included). That ETH stays in the pool as permanent
protocol-owned depth (nobody can ever remove liquidity), and the tokens it bought become the bankroll through the
PrincipalLock (next section). The pool's LP fees are the protocol's creator revenue, collected by anyone through
`harvest()`. (`launchFlipperV4` does the same with a plain ERC20; `launchFlipperPons` is a legacy pons path kept
behind `LAUNCHPAD=pons`.)

### The launch position (`LiquidityKeeper`)

The position is a standard Uniswap v4 PositionManager NFT (explorers and the Uniswap app show it as a position),
minted to and held by the `LiquidityKeeper`, which has no owner, no admin and no upgrade path:

- **Launch, atomically.** Before launching, the router's owner points it at its keeper once (`setLiquidityKeeper`;
  the keeper's immutable `router` must be the router). The launch transaction then sends the pool supply to the
  keeper and calls its one-shot, router-only `launch`, which initialises the pool at the start price and mints the
  range through Permit2 to itself; the router makes the opening buy in the same transaction. Dust and unused ETH go
  back to the router. If someone initialised the pool first (the token's address is public once it is deployed), a
  price at or above the start price is harmless (the range still sits below it and the opening buy walks the price
  down through the empty ticks into it); below it the launch reverts (`PoolPreInitialized`), as it always did.
- **Nothing can take it.** The keeper has no function that decreases liquidity, transfers or approves the NFT, or
  changes its router. The router's owner, a router upgrade and the ProxyAdmin all have no authority over it
  (`test/LiquidityKeeper.t.sol`). The router's `lpPosition()` still returns the key and range.
- **Fees.** `collect()` is permissionless and pays the position's fees (ETH and $FLIPPER) to the router (DECREASE 0 +
  TAKE_PAIR), which `harvest()` calls as its step 3, so the bounty counts them.
- **Views.** `position()` → (poolId, tokenId, tickLower, tickUpper, liquidity); `positionAmounts()` → (ETH,
  $FLIPPER) the position holds at the current price, fees excluded (the API's circulating-supply read).
- **Optional UNCX lock** (`UNCX_LOCK=1`, off by default). The keeper also locks the NFT forever in UNCX's v4 locker
  (`UNCX_V4_LOCKER`; `ETERNAL_LOCK`), pays UNCX's flat fee out of the launch value (0.1 ETH, added by Deploy) unless
  UNCX whitelisted the keeper, and sets the lock's collect address to the router; `collect()` then goes through
  `locker.collect(lockId, router)`. UNCX takes 1% of the liquidity at lock time (≈10M $FLIPPER of the launch range;
  Deploy prices that into the opening buy, which still buys exactly its share) and 4% of collected fees. Its fees are
  checked against immutable caps first (`RobinhoodAddresses.UNCX_MAX_*`: 0.1 ETH, 1%, 4%) and the launch reverts if
  UNCX raised them. The keeper owns the lock and exposes none of UNCX's migrate, relock, transfer-ownership or
  unlock functions. Manifest: `contracts.liquidityKeeper`, `contracts.positionManager`, `contracts.uncxLocker`
  (zero when unlocked).

### Team stake (`PrincipalLock`)

**The team's opening buy, 12.5% of supply, is staked in the treasury through an immutable PrincipalLock. The principal
can never be withdrawn; only what it earns on top (its share of treasury gains and staking and holder rewards) can be
claimed, to fund development.**

- **Not upgradeable, no admin withdrawal.** The deployer stakes once (`stake`, in the deploy); that amount is the
  principal P. Its owner (Ownable2Step; the mainnet deploy's Ledger) can do one thing: point `devAddress` at another
  wallet (`setDevAddress`, `DevAddressSet`). Ownership can be handed over but never renounced.
- **Earnings only, to the dev claim wallet.** `devAddress` (`CLAIM_WALLET` in the mainnet deploy; `DEV_PAYOUT_ADDRESS`
  in Deploy.s.sol, default the deployer) is the only address anything is ever paid to: an everyday key, so the cold
  owner key isn't needed to claim. Only it can request and withdraw the excess,
  `value() − P` (its share of treasury gains, after the vault's 80% performance fee), through the vault's own request
  → cooldown → withdraw flow. A request must be worth no more than the excess when made; a withdrawal that would leave
  the position worth less than P (the price fell during the cooldown) reverts. Under water, nothing is withdrawable.
  Treasury losses can take the position below P like any stake's; withdrawals never can.
- **Rewards.** Holder rewards on the staked $FLIPPER accrue to the vault's virtual balance on the token and reach the
  lock through the vault's pass-through; the token also credits the lock's own wallet balance (in practice ~0).
  `sweepVaultRewards()`, `sweepHolderRewards()` and `sweepRewards()` claim them; anyone may call them, and they only
  ever pay `devAddress`. Every request and withdrawal sweeps both too (`RewardsSwept(vaultRewards, holderRewards)`).
- **Breaker.** While the house is locked every vault and token call reverts (`ProtocolLocked`), so requests,
  withdrawals and sweeps revert too.
- **Views:** `principal()`, `value()`, `withdrawableExcess()`, `pendingWithdrawal()` (shares, their value, ready
  time), `pendingVaultRewards()`, `pendingHolderRewards()`, `devAddress()`.
- **Keys.** If the claim wallet's key is lost or compromised, the owner replaces it (a withdrawal already queued is
  then paid to the new wallet); only the excess and rewards were ever exposed, never the principal. The same holds if
  the owner's key is compromised: it can redirect earnings, not the principal.
- **Trust boundary.** The lock is exactly as strong as the TreasuryVault, which is upgradeable: an upgrade by its
  proxy admin could change what the lock's shares are worth or how they exit. Put the vault's proxy admin behind a
  timelock or multisig.

## Randomness

Robinhood Chain has neither Chainlink VRF nor Pyth Entropy. The house uses **Dice Protocol**: `DiceEntropy`
(`0xd8A0…0A0c`, verified on Blockscout, immutable), a fork of Pyth Entropy v2, through the `DiceEntropyAdapter`
(see its NatSpec for the trust model: commit-reveal over one provider's hash chain mixed with the flip block's hash;
a prompt first delivery by the provider's revealer settles normally, a late, retried or recovered one settles in
safe mode; open-flip caps and a stall breaker bound what a provider halt can leave cancellable).

- **Fee:** Dice charges a flat 2.5e13 wei per request (the same for any callback gas limit from 100k to 2.5M), so
  the callback budget costs nothing extra and is sized for safety. The house reads it from the adapter
  (`randomnessFeeFor`, `previewFlip`), and a per-gas fee would flow through the same path.
- **Player cost** at Robinhood's ~0.035 gwei base fee and ETH at $2,687: the Dice fee (~$0.067) plus the flip
  transaction's own gas; the reveal and settlement are paid by Dice's provider. Measured on a Robinhood fork
  (`test/fork/RobinhoodDefault.t.sol`, the default deployment; L2 execution gas, before Arbitrum's small L1 data
  component):

  | flip | flip tx gas | gas cost | + Dice fee | total |
  |---|---|---|---|---|
  | token (TSLA: its ETH pool + the $FLIPPER pool) | 554k | 1.94e13 wei (~$0.052) | 2.5e13 | ≈ 4.4e13 wei (~$0.12) |
  | $FLIPPER (no swap) | 355k | 1.24e13 wei (~$0.033) | 2.5e13 | ≈ 3.7e13 wei (~$0.10) |
  | WETH (wrapper + $FLIPPER pool) | 589k | 2.06e13 wei (~$0.055) | 2.5e13 | ≈ 4.6e13 wei (~$0.12) |
- `ChainlinkVRFAdapter` and `PythEntropyAdapter` implement the same interface for other deployments.

### Settlement gas budgets

Measured on forks with every settlement in its own transaction, so storage is cold as in a real fulfilment
(`test/fork/RobinhoodFork.t.sol --isolate`; gas of the house callback frame and of each swap attempt):

| Route | buy attempt | sell attempt | callback win / loss |
|---|---|---|---|
| pons token, 2 pons hops | 218k | 171k | 304k / 266k |
| pons token with creator tax + buyback, both pools' hook fees just swept (heaviest) | 263k | 267k | 349k / 362k |
| TSLA (native-ETH pool) | 196k | 176k | 301k / 270k |
| SPY (USDG pool, 3 hops) | 231k | 245k | 343k / 346k |
| fallback: buy fails after a price move, settled sell quote, $FLIPPER bonus (SPY) | 186k + 232k | | 576k |
| $FLIPPER flip (no swap) | | | 63k / 72k |

The launch whitelist's routes are measured in `test/fork/RobinhoodWhitelist.t.sol`.

Every swap attempt keeps a 350k settlement reserve back (`_attemptGas`), so `setParams` only requires
`callbackGasLimit ≥ swapGasLimit + 350k` and the callback can't run out of gas whatever a token, hook or pool does
(`test/SettlementGas.t.sol` burns every capped call at the minimum budgets). A win's fallback quote runs on what the
budget has left; when that isn't enough the win is left `WinPending` for anyone to resolve.

Defaults: `swapGasLimit` 560k (≈1.2× the heaviest measured attempt, the launch whitelist's INDEX buy at 461k: v3
bridge plus the token's holder-registry writes) and `callbackGasLimit` 910k, the least `setParams` allows for it (one
full attempt plus the 350k reserve); `flipperCallbackGasLimit` 400k. Dice's keeper pays for the gas a settlement
actually uses — at most ~484k for any whitelisted route, well under the flat fee's worth — so the budgets are sized to
the measured routes rather than padded; only the heaviest route's fallback quote after a failed buy may not fit, and is
then left `WinPending` for anyone to resolve.

## Uniswap v3 liquidity (`V3RouteAdapter`, `V3BridgeHook`)

Much of Robinhood Chain's liquidity is in Uniswap v3 (e.g. USDG/WETH 0.01% holds ~3,100 WETH; BNKR, DEGEN and most
stock tokens have v3 pools). The house only speaks v4, and its EIP-170 headroom rules out a second swap engine, so v3
is bridged into v4 instead:

- **`V3BridgeHook`** (one immutable hook per chain, deployed at an address carrying its permission bits: before
  initialize / add liquidity / swap + swap-returns-delta). `bridge(v3Pool)` (permissionless, checked against the v3
  factory) creates one v4 pool per v3 pool: the same currencies with WETH shown as native ETH, the v3 fee and tick
  spacing, this hook, no liquidity. Its `beforeSwap` consumes the whole swap: it takes the input from the
  PoolManager inside the v3 pool's own callback (wrapping ETH), swaps in v3, settles the output back (unwrapping
  WETH) and returns the matching delta, so the v4 AMM step is a no-op. Exact input and exact output must fill
  completely (a v3 partial fill reverts). Pure quotes never pay their input, so when the PoolManager doesn't hold it
  the v3 swap is priced and reverted QuoterV2-style instead; in any real swap that would leave the hook owed an
  input only it could collect, so the unlock can't settle. The hook keeps no balances and only pays a v3 pool from
  inside that pool's callback (tracked in transient storage).
- **`V4SwapEngine`** pays an exact input *before* swapping when a swap really moves tokens, so the PoolManager holds
  the input while a bridge pool runs (flash accounting nets the same; v4 pools behave exactly as before).
- **`V3RouteAdapter`** mirrors `V4RouteAdapter`: `check(token, v3Pool)` / `register` / `registerAndList`, routes
  `[token/WETH (bridged), ETH/$FLIPPER]` or `[token/USDG (bridged), USDG→ETH v4 quote pool, ETH/$FLIPPER]`, and the
  house's listing probe, route-cost caps and gas caps apply unchanged (a failed v3 swap degrades like any other).
  `check` reason codes: those of `V4RouteAdapter` (5, HOOK_NOT_ALLOWED, never applies) plus 9 `NOT_V3_POOL`, 10
  `LISTED_ELSEWHERE`, 11 `IS_WETH`.
- **Gas** (Robinhood fork, cold storage): a v3 hop costs ~200–250k inside a swap attempt (the v3 swap, WETH
  wrap/unwrap and PoolManager settlement). Attempts measured buy / sell: USDG via WETH 0.01% 335k / 307k, BNKR via
  WETH 1% 317k / 282k, SGOV via USDG 0.3% + the v4 USDG/ETH pool (3 hops) 386k / 366k; callbacks 372k–498k. They fit
  the 560k `swapGasLimit`; a failed buy's fallback quote gets what the 910k budget has left.
- **Deepest pool across v3 and v4.** v4 is the default venue. A v3 registration is replaced only by a deeper v3
  pool on the same pairing currency, and it defers (`DEEPER_REGISTERED`) to a `V4RouteAdapter` registration for the
  same token and pairing that is at least as deep (both compare in-range virtual reserves of the pairing currency).
  Across adapters the first listing wins: the house refuses a permissionless listing that would overwrite another
  adapter's route (`AlreadyListed`; `check` reports `LISTED_ELSEWHERE`), and the owner moves a token to the deeper
  venue with `setTokenRoute`.

## Listing policy (`ListingPolicy`)

A token whose behaviour can change after listing drains the house one-sidedly: an upgradeable proxy, or owner
switches such as a blacklist, pause, tax or blocked transfers to the PoolManager. Losses then fail to sell and become
worthless inventory, while wins still buy real tokens out of the attacker's pool. (The settled-simulation fallback only
covers a win whose buy fails.) So permissionless listing is limited to tokens whose code can't change under us. Every
route adapter asks the one shared `ListingPolicy`; `routeFor` enforces it too, so calling `house.listToken` directly
can't bypass it. A listing passes on the first path that approves it:

1. **Pool whitelist.** The owner whitelists an exact pool: a v4 `PoolKey` (`setPoolWhitelisted`) or a Uniswap v3
   pool address (`setV3PoolWhitelisted`).
2. **Launchpad verifier.** An attached `ILaunchpadVerifier` approves the token on that pool:
   `verify(token, key) → (ok, reason, launchpadId)`. Each verifier carries its own analysis. The owner `attach`es
   and `detach`es verifiers (at most 8). Calls are capped at 500k gas, and a verifier that reverts, runs out of gas
   or returns garbage simply doesn't approve; it can never brick listings.
3. **Token allowlist.** Trusted issuers and majors. The pool must be hookless, a v3 pool (bridged by our own
   immutable hook), or use a hook pinned by address and runtime codehash (`pinHook`, after checking offchain that
   its EIP-1967 / beacon slots are empty; a proxy's runtime is its stub, so a pinned audited hook isn't a proxy).

If no path approves, adapters revert `NotVetted(reason, detail)`: 12 `NOT_VETTED` with the last verifier's reason,
or 13 `HOOK_NOT_PINNED`. `check()` reports the same, `ListingPolicy.evaluate(token, key, v3Pool)` also returns the
approving path (1 pool, 2 launchpad, 3 token) and the launchpad id, and registrations emit
`ListingVetted(token, pool, path, launchpadId)`. The owner can still list anything directly (`house.setTokenRoute`).
Tokens listed earlier stay listed, and the guardian can disable any token. An adapter with no policy set lists
nothing permissionlessly.

**Launch configuration:** USDG, WETH and cbBTC are allowlisted; the Robinhood stock-token `CodehashVerifier` is
attached (further launchpad verifiers can be attached by the owner; none is attached at launch); and a curated set of
Robinhood Chain tokens (PONS, ORBIO, INDEX, SHROOM, DICE) is whitelisted by exact pool
(`RobinhoodAddresses.launchWhitelist`).

**What the verifiers check (audited 2026-09-25):**
- **pons v2** (`PonsVerifier`, not attached):
  - The factory registry has the token and it has graduated.
  - The token is the `PonsV2LauncherToken` template: OZ ERC20 + Burnable with no owner, pause, blacklist, tax or
    hooks, masking 4 immutable words; one hash for all launches. This also guards against the pons Safe swapping
    the factory's token deployer.
  - The pool is the canonical meme-hook pool at the audited hook code. The meme hook's fees are frozen per pool;
    it has no pause, allowlist, proxy or delegatecall.
- **Robinhood stock tokens:** every one is an OZ BeaconProxy embedding Robinhood's beacon, so one codehash covers
  them. Roles and the blocklist come from a registry fixed in the implementation, so a copycat proxy is still
  issuer-governed. The issuer can pause, block, burn or upgrade: this is the trusted-issuer class.

## Security model

- **Price manipulation.** Payouts are denominated in the staked token, so dumping or pumping between request and
  callback doesn't help the player. Flip-time quotes can be flash-manipulated, but they only ever *lower* the
  player's outcome:
  - a deflated quote gives a lower cap and a lower fallback;
  - an inflated quote is neutralised because the fallback uses the settle-time quote.

  The rejected-cost cap, the loss floor and the 45% cap bound what an attacker can extract, even one who knows the
  outcome and picks the settlement moment. Adversarial tests cover each case (`test/Adversarial.t.sol`).
- **Pool shut off between request and callback.** Losses become house inventory (no free void). Wins return the
  stake and reserve the winnings until anyone resolves them.
- **Mutable tokens** are kept out by the listing policy (above); only owner listings bypass it.
- **Hostile tokens.** Tokens that block transfers, tax them or forge quote results can't extract a fallback or touch
  other players' escrow (`test/V4RouteAdapter.t.sol`). Permissionless listings check the pool, not the token
  contract.
- **Randomness trust.** Dice's provider can see outcomes early and withhold them, but can't bias them; the adapter
  settles anything but a prompt first delivery in safe mode, caps open flips and trips a stall breaker. Players can
  only cancel after 7 days, and only while the request is provably unrevealed.
- **Custody.** `treasury − reserved` is the only withdrawable bankroll, and once the staking vault is set only the
  vault can withdraw it (stakers' exits; the protocol-owned share can never be withdrawn). Escrow, reservations, inventory
  and claimables are untouchable except through settlement. The router can only send revenue to the house, the
  rewards distributor, the converter (ETH, sold for $FLIPPER that returns to the router) or, as the capped bounty,
  to whoever harvests. Its harvest-call targets are owner-set and can never be $FLIPPER, the house, the rewards
  distributor, the converter, the PoolManager or the router itself.
- **Upgrades.** The upgrade key can change everything, so put a timelock in front of the ProxyAdmins.
  `script/storage-layout.sh --check` enforces append-only storage.
- **Launchpad powers.** pons' 2-of-3 Safe can redirect any token's creator fees after a 3-day delay ("community
  takeover"). It cannot pause swaps, mint, or pull locked liquidity. $FLIPPER's own v4 pool has no third party.

## WETH (`WethWrapperHook`)

The web's "ETH" asset flips as WETH. WETH ↔ native ETH is a 1:1 wrap, so instead of an AMM pool WETH routes through one liquidity-free v4 pool, `(ETH, WETH, fee 0, tick spacing 1,
WethWrapperHook)`, whose hook consumes each swap and wraps / unwraps exactly 1:1 (in the style of v4-periphery's
`WETHHook`). WETH's route is `[wrapper pool, ETH/$FLIPPER]`, so its route cost is the $FLIPPER hop alone and WETH
flips get full odds; wins buy WETH through the same route (ETH → WETH wrap), with settlement unchanged.

- The hook is mined to its permission bits, creates its single pool itself (`initialize()`), refuses liquidity and
  any other pool, has no owner, fee or state, and never holds balances between calls. A pure quote whose input the
  PoolManager doesn't hold is priced 1:1 without moving anything.
- Deploy pins the hook (codehash) and whitelists its pool in the ListingPolicy; after that anyone can
  `v4Adapter.registerAndList(WETH, wrapperKey)` (Deploy.s.sol lists it right away). The V4RouteAdapter treats a
  liquidity-free hooked pool the policy whitelists as a custom curve of unbounded depth (`CUSTOM_CURVE_DEPTH`), so no
  AMM pool can displace it; the house's listing probe still prices the route.
- Manifest key: `contracts.wethWrapperHook`.

## Liquidity checks

- **Route cost.** For a route with per-hop fees `f_i` and ETH-side in-range depths `R_i`, a stake worth `V` ETH
  costs about `h ≈ Σf_i + V·Σ(1/R_i)` (one way; `h` averages the two directions). The house stays at base odds
  while `h ≤ 8%`, so the largest such stake is `V* ≈ (8% − Σf)/Σ(1/R_i)`.
  - Robinhood / pons (2 hops at 1%, both pools 4.2 ETH deep right after graduation): `V* ≈ 6%/(2/4.2) ≈ 0.13 ETH`.
    The bet cap (half Kelly, typically 0.6–2.75% of the bankroll) usually binds first.
  - Measured on a fork: 297 bps route cost for a 0.02 ETH stake of a freshly graduated pons token (45% odds).
- **Permissionless listing** requires a probe-sized round trip to cost ≤ 4% (`listingMaxRouteCostBps`). The probe is
  `listingProbeBps` (2%) of the current max bet, because thin pons pools would reject a larger probe on impact alone.
- **Per-flip check.** Every flip re-checks `h` at the actual stake size.

## Commands

```sh
forge build
forge test --no-match-path "test/fork/*"      # unit, adversarial, revenue, launch, vault, upgrade and invariant suites
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract RobinhoodFork -vv  # real pons/v3/v4
script/storage-layout.sh --check              # upgrade safety
```

Deployment: `script/Deploy.s.sol` (defaults: Robinhood, the reward-bearing $FLIPPER on v4 at a $5k start with all of
the supply in the pool, a 12.5%-of-supply opening buy staked through the PrincipalLock, Dice; see its NatSpec for env:
`ENTROPY_MODE` (`dice` / `dice-mirror` / `dice-mock`), `OPENING_BUY_SUPPLY_BPS`, `PRINCIPAL_LOCK`,
`DEV_PAYOUT_ADDRESS`, `REWARD_BEARING`, `VAULT_FEE_BPS`, `VAULT_LOCK_DAYS`, `VAULT_COOLDOWN_HOURS`, …), usually through
`../dev.sh`. The manifest lists the vault as `contracts.treasuryVault`, the team stake as `contracts.principalLock` and
the launch position's holder as `contracts.liquidityKeeper`.

**Verification** (after a mainnet deploy, from the deployed commit and its `forge build`): `script/verify.sh` verifies
every contract the broadcast created on Blockscout and Etherscan (API V2, chain 4663). It matches each creation's
init code against the local artifacts to get the source, profile and constructor arguments (proxies, their
ProxyAdmins and anything created inside a transaction included), then links each proxy to its implementation on
Etherscan (Blockscout detects EIP-1967 proxies itself).

```sh
script/verify.sh --dry-run --manifest deployments/<file>.json      # the plan and every command, nothing submitted
ETHERSCAN_API_KEY=… RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  script/verify.sh --manifest deployments/<file>.json                # default broadcast: broadcast/Deploy.s.sol/4663/run-latest.json
```

`test/fork/LaunchDepth.t.sol` measures the largest flip each token accepts (and that a win at that size really
routes) on a stack Deploy.s.sol deployed to a local Robinhood fork, optionally growing the market cap by organic buys
(see its NatSpec). On a fork, use `ENTROPY_MODE=dice-mirror` (or `dice-mock`): production `dice` reads Arbitrum's
ArbSys precompile, which forge's simulation and anvil don't have.

### Monitoring the books

The house runs with no buffer: its $FLIPPER balance equals exactly what it owes (treasury, reserved included; the
holders' accrual; escrowed stakes; deferred payments; partner accruals), and every other token's balance equals its
escrowed stakes, inventory and deferred payments. `FlipperLens.surplus(house, token)` returns balance − obligations
as a signed number: it should read 0 (a donation makes it positive; anything negative means a claim could fail).
The upkeep worker should alarm on anything but 0.

### Scripting gas-floored calls

Functions that make a swallowed or gas-capped external call refuse to run with too little gas left (`InsufficientGas`)
so that `eth_estimateGas` can never starve that inner call: the vault's reward-token sync (300k), the router's harvest
calls and `distribute` (300k), settlement, `resolvePendingWin`, `sweepInventory`, `cancelFlip`, the partner lookup and
the PrincipalLock's holder-reward claim. Wallets, `cast` and viem estimate by binary search and are fine. **`forge
script` is not**: it sizes each broadcast transaction from the gas its local simulation used (× the multiplier), and
that simulation never hits the floor, so the transaction reverts on chain. Every forge-scripted call to a gas-floored
function needs an explicit `{gas: …}` (Deploy uses `FlipperDeploy.VAULT_CALL_GAS` for its vault calls and the lock's
stake).
