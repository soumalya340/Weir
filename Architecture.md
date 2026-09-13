# Weir — Architecture

Weir is a fair-launch memecoin launchpad built on a **Uniswap v4 hook** (fee capture, in-place graduation, staking real yield) and **official 1inch SwapVM** (bonded zero-custody pre-launch commitments, auto-compounding of staking rewards). This document is the end-to-end technical reference for every contract in `src/`, the asset and control flows between them, and the design decisions taken while implementing `Ideas/Idea1.md`, `Ideas/Idea2.md` and `Ideas/Plan.md`.

No SwapVM opcode is added or modified. Every SwapVM interaction uses stock instructions on the official routers.

---

## 1. System overview

```
                                   ┌────────────────────────────────────────────┐
                                   │              WeirV2LaunchFactory            │
                                   │  launchToken / launchTokenWithCampaign      │
                                   │  graduate → settle → sweep → seed v4 pool   │
                                   └────┬──────────────┬───────────────┬─────────┘
             deploys (CREATE2)          │              │               │
     ┌──────────────────────────────────┘              │               │ registerPool
     ▼                                                 ▼               ▼
┌──────────────────────┐  releaseCommittedTokens ┌──────────────────┐  ┌──────────────────────┐
│  WeirV2BondingCurve  │ ───────────────────────►│ WeirV2Commitment │  │    WeirV2MemeHook    │
│  public partition    │                         │     Registry     │  │  afterSwap fee cut   │
│  reservedTokens      │                         │ campaigns, bonds │  │  sweep → split       │
│  committedTokens     │◄─── quote seeds pool ───│ settle via       │  │  staking vault mgmt  │
│  tradingOpensAt      │        (via factory)    │ SwapVM LimitSwap │  └─────────┬────────────┘
└──────────┬───────────┘                         └────────┬─────────┘            │ deploys via
           │ mints to                                     │ swap()                │ WeirV2StakingVaultDeployer
           ▼                                              ▼                       ▼
┌──────────────────────┐                        ┌──────────────────┐   ┌──────────────────────┐
│ WeirV2LauncherToken  │                        │ 1inch SwapVM     │◄──│ WeirV2StakingReward  │
│ ERC20Burnable        │                        │ (official router)│   │ stake / harvest /    │
└──────────────────────┘                        │ + Aqua (optional)│   │ auto-compound        │
                                                └──────────────────┘   │ burnAndRedeem        │
                                                                       └─────────┬────────────┘
                                                              unlockEarlyExit    │ redeemFor
                                                    ┌────────────────────────┐   ▼
                                                    │ WeirV2FutarchyProposal │  ┌──────────────────────┐
                                                    │ PASS/FAIL LMSR markets │─►│ WeirV2PoolRedemption │
                                                    │ member-gated voting    │  │ 40% cap, membership  │
                                                    └────────────────────────┘  └─────────┬────────────┘
                                                                                          │ redeemLiquidity
                                                                                ┌─────────▼────────────┐
                                                                                │  WeirV2LaunchLocker  │
                                                                                │  v4 position NFT     │
                                                                                └──────────────────────┘

Shared singletons: WeirV2FeeEscrow (claimable ledger), WeirV2BuybackVault (5-year vest),
WeirV2LaunchLocker (LP lock; ≤40% redeemable after a PASS), WeirV2GraduationExecutor + WeirV2LaunchDeployer +
WeirV2StakingVaultDeployer (EIP-170 size helpers), WeirV2GraduationGuard (seed preflight).
```

### Lifecycle of one launch

```
T−24h+   launchTokenWithCampaign()  token + curve deployed, curve CLOSED (tradingOpensAt = T)
         backers: commit()          sign SwapVM LimitSwap order, post 20% bond, pledge stays in wallet
T        curve opens                public trades the public partition; anti-snipe tax decays
T+~1h    sellable partition = 0     readyToGraduate() == true
         factory.graduate()         1. curve.releaseCommittedTokens(registry)
                                    2. registry.settle(): SwapVM fills honourers, burns defectors' tokens
                                    3. seed preflight on curve quote + settled quote
                                    4. curve.graduate(): sweep fees, hand reserves to factory
         factory.createGraduatedPool()  init v4 pool, registerPool on hook (deploys staking vault),
                                        mint full-range position → WeirV2LaunchLocker (permanent)
T+…      every swap                 hook takes hookFeeBps + creatorTax via afterSwap
         sweepPoolFees()            protocol / stakers / buyback-vest / creator
         stakers: setAutoCompound() rewards held; compound() buys more token via SwapVM, restakes
         member: createFutarchyProposal()  members vote whether the pool is dead
         PASS → members burn tokens, take pro-rata quote from the locked position (≤ 40%)
```

---

## 2. Contract catalogue

| Contract | File | Role | Deployed per |
|---|---|---|---|
| `WeirV2LaunchFactory` | `src/WeirV2LaunchFactory.sol` | Launch orchestration, graduation phases, creator-fee governance, futarchy proposal deployer | protocol |
| `WeirV2LaunchDeployer` | `src/WeirV2LaunchDeployer.sol` | CREATE2 deploys curve + token (factory size helper) | protocol |
| `WeirV2BondingCurve` | `src/WeirV2BondingCurve.sol` | Constant-product curve with phantom quote, three token partitions, fee accrual, trading gate | launch |
| `WeirV2LauncherToken` | `src/WeirV2LauncherToken.sol` | Fixed-supply `ERC20Burnable`, mints full supply to its curve | launch |
| `WeirV2CommitmentRegistry` | `src/WeirV2CommitmentRegistry.sol` | Bonded pre-launch commitments, SwapVM settlement, burn, bond distribution | protocol |
| `WeirV2MemeHook` | `src/hooks/WeirV2MemeHook.sol` | Singleton v4 hook: afterSwap fee capture, internal swaps, fee split, per-pool policy snapshot, vault registry | protocol |
| `WeirV2StakingVaultDeployer` | `src/WeirV2StakingVaultDeployer.sol` | Deploys staking vaults for the hook (hook size helper) | protocol |
| `WeirV2StakingReward` | `src/WeirV2StakingReward.sol` | Direct-stake real-yield vault, auto-compound via SwapVM, futarchy early exit | pool |
| `WeirV2FutarchyProposal` | `src/WeirV2FutarchyProposal.sol` | Member-gated one-question decision market (PASS/FAIL LMSR) that unlocks pool redemption and early exit | proposal |
| `WeirV2PoolRedemption` | `src/WeirV2PoolRedemption.sol` | Dead-pool exit: members burn tokens for pro-rata locked-liquidity quote, capped at 40% | protocol |
| `MemePredictionMarket/Binary.sol` | `src/MemePredictionMarket/` | Vendored LMSR binary market used by futarchy, plus an optional trade gate | market |
| `WeirV2BuybackVault` | `src/WeirV2BuybackVault.sol` | 5-year vest for bought-back tokens (creator/protocol split) | protocol |
| `WeirV2FeeEscrow` | `src/WeirV2FeeEscrow.sol` | Pull-payment ledger for ETH and ERC-20 payouts | protocol |
| `WeirV2LaunchLocker` | `src/WeirV2LaunchLocker.sol` | Holds the graduated position NFT and excess tokens; the only liquidity exit is `redeemLiquidity`, callable solely by the redemption contract | protocol |
| `WeirV2GraduationExecutor` | `src/WeirV2GraduationExecutor.sol` | Permit2 + PositionManager mint (factory size helper) | protocol |
| `WeirV2GraduationGuard` | `src/WeirV2GraduationGuard.sol` | Pure preflight: will v4 mint this seed? | protocol |
| `ISwapVM` | `src/interfaces/ISwapVM.sol` | ABI mirror of the official router interface | — |
| `SwapVMOrderLib` | `src/libraries/SwapVMOrderLib.sol` | Byte-exact builders for stock SwapVM programs and taker traits | — |

---

## 3. The bonding curve and its three token partitions

`WeirV2BondingCurve` trades the launch token against the quote asset the graduated pool will use (native ETH or an approved ERC-20), with a virtual `phantomQuote` reserve so the first buy has a price. Every fee is charged on the quote leg.

### 3.1 Partitions (`Ideas/Idea2.md §4`)

| Partition | Field | Set in | Purpose |
|---|---|---|---|
| Pool seed | `reservedTokens` | `_initialize` | Never sold. Handed to the v4 pool at graduation. |
| Commitment tranche | `committedTokens` | `_initialize` (from registry) | Fenced off for backers. Released only to the registry at graduation. |
| Public curve | `trackedTokens − reservedTokens` = `sellableTokens()` | derived | Open trading. |

**Implementation decision.** Idea2 wrote the formula as `sellable = tracked − reserved − committed`. The implementation instead keeps `committedTokens` *outside* `trackedTokens` (`src/WeirV2BondingCurve.sol:285-317`). `trackedTokens` is the token reserve that feeds the constant-product price; if the tranche were inside it the public would be trading against tokens they can never buy, and the price would be wrong by the tranche's size. Holding the tranche as a separate accounting view over the same balance gives the identical `sellableTokens()` semantics with correct pricing.

Consequences:

- `reservedTokens` and the constant product are derived from the **public supply** (`supply − committedTokens`), so a launch with a campaign still graduates at exactly `graduationThreshold` of real public quote. The deterministic graduation price every downstream guard relies on is unchanged.
- **The tranche does not count toward the graduation threshold.** This resolves the open question in Idea2 §7 / Plan §5.3 in favour of "public capital alone graduates; commitments are pure upside." The alternative ("commitments count") would have required graduating on a threshold that includes unsettled pledges, which is the JIT-defection hole the docs identify. Ordering (settle before seed) is still enforced regardless, see §5.

### 3.2 Trading gate

`tradingOpensAt` (`src/WeirV2BondingCurve.sol:158`) closes `buy` and `sell` until the campaign closes (`:473`, `:564`). The snipe-tax clock (`launchedAt`) starts at the open, not at deployment, so a 24-hour campaign does not consume the anti-sniper window.

### 3.3 Graduation trigger

`readyToGraduate()` (`:436`) is `sellableTokens() == 0`, evaluated on the token side because a buy cannot overshoot it. The crossing buy calls `factory.graduate` inside `try/catch` (`_tryAutoGraduate`, `:713`) so a failed graduation never reverts the buy; the launch stays permissionlessly retryable and a keeper sees `AutoGraduationFailed`.

`releaseCommittedTokens(to)` (`:324`) is `onlyFactory`, requires `readyToGraduate()`, zeroes `committedTokens` and transfers the tranche. It can only be reached from the factory's graduation path.

---

## 4. Commitment registry (Idea 2)

`WeirV2CommitmentRegistry` holds every campaign's configuration, every backer's bond and order signature, and performs settlement. The factory is its only privileged caller.

### 4.1 Campaign configuration (`Plan.md §1`)

`openCampaign` (`src/WeirV2CommitmentRegistry.sol:266`) is called by `launchTokenWithCampaign` (`src/WeirV2LaunchFactory.sol:752`) immediately after the token and curve exist.

| Field | Set by | Rule |
|---|---|---|
| `discountBps` (`d`) | creator | 20%–40% (`MIN_DISCOUNT_BPS`, `MAX_DISCOUNT_BPS`) |
| `targetQuote` (`Q`) | creator | > 0 |
| `oversubscriptionBps` | creator | 100%–200%, default 140% |
| `tradingOpensAt` | creator | ≥ now + 24h (`MIN_CAMPAIGN_DURATION`, `:52`) |
| `allowlistRoot` | creator | zero = open mode; otherwise Merkle root of `keccak256(abi.encodePacked(backer))` |
| `committedTokens` | **derived** | `Q × supply × 10000 / (phantomQuote × (10000 − d))`, capped at 50% of supply |
| Bond | **protocol constant** | `COMMITMENT_BOND_BPS = 2000` (`:50`), not settable by anyone |
| Quote asset | launch | ERC-20 only; native-quote launches revert `NativeQuoteUnsupported` (see §9) |

`P₀` is the curve's opening marginal price with no tranche, `phantomQuote / supply`. The committer price is `P₀ × (1 − d)`. Because the tranche is fenced off, the real public opening price is marginally higher than `P₀`, so the backer's effective discount is slightly larger than `d`. The bound `bond ≥ d` from Idea2 §5 is enforced by construction: `d ≤ 40%` with a 20% bond is only defensible together with the exposure cap (§4.3), which is why both ship together.

All fields are immutable after `openCampaign`.

### 4.2 The commitment order (what a backer signs)

A pledge is a resting **SwapVM order** in which the backer is the maker. The registry rebuilds it deterministically from `(campaign, backer, pledge)` rather than storing bytecode (`_buildOrder`, `:520`; `previewCommitmentOrder`, `:244`):

```
program  = InvalidateBit(nonceBit)            one-shot: fills at most once per maker
         · Deadline(tradingOpensAt + 30d)     ORDER_LIFETIME: stale orders stop being fillable
         · StaticBalances(balanceA, balanceB)  balanceA/B = (allocationTokens, pledgeQuote) in sorted order
         · LimitSwap(direction)                direction = launchToken < quoteToken
order    = { maker: backer, traits: no hooks / no receiver / [useAqua], data: tokenA ++ tokenB ++ program }
```

Encodings are byte-exact with the official `InstructionBuilder`, `MakerTraitsLib.build` and `TakerTraitsLib.build` (`src/libraries/SwapVMOrderLib.sol:50-130`), so the official `SwapVMRouter` / `LimitSwapVMRouter` execute them unchanged. Opcodes used: `0x40 InvalidateBit`, `0x20 Deadline`, `0x90 StaticBalances`, `0x53 LimitSwap`; all present in both routers' opcode sets.

Two authorisation modes:

- **Signature mode** (default): backer signs `swapVM.hash(order)` (EIP-712) and approves the router to spend their quote. Verified at commit via `SignatureChecker` (EOA or EIP-1271).
- **Aqua mode** (`useAqua = true`): no signature; the backer `ship()`s the identical order to Aqua and the router sources and settles the maker's balance through Aqua's virtual-balance accounting. The registry only flips the maker-traits flag.

In both modes the pledged quote **never leaves the backer's wallet** until the fill executes; the fill is checked against what the wallet holds at that moment. That is the Aqua property the track exists to demonstrate.

### 4.3 Commit and the aggregate exposure cap (`Idea2 §8`)

`commit` (`:433`):

1. Campaign open, before `closesAt`, not already committed, allowlist proof if required, `≤ MAX_COMMITMENTS = 64` backers, total pledged `≤ maxPledged`.
2. `bond = pledge × 20%`.
3. **Exposure cap:** `quote.balanceOf(backer) ≥ outstandingPledge[backer] + pledge + bond`. A wallet must be able to honour *every* resting pledge plus the new bond at commit time. This is the "cap aggregate exposure, not per-pool exposure" fix: a backer cannot pledge 5,000 against 100 of capital. Moving funds afterwards is still possible, which is exactly what the bond prices.
4. Order rebuilt, hash computed on the router, signature verified (signature mode).
5. Bond pulled (balance-delta checked). Commitment stored with signature; backer appended in commit order.

### 4.4 Settlement (`settle`, `:330`)

Called by `factory.graduate` after `curve.releaseCommittedTokens(registry)`. Requires the tranche to be physically held.

```
approve router for committedTokens
for backer in commit order:
    outstandingPledge[backer] -= pledge
    remaining = Q − settledQuote
    if expired or remaining == 0:  Outcome.Unfilled   (bond refundable, no tokens, not a defector)
    fillQuote  = min(pledge, remaining)
    fillTokens = fillQuote / pledge × allocation
    try swapVM.swap(order, fillTokens, takerTraits{exactIn, strict=false, threshold=expectedQuote,
                                                   allowPartialFill=false, isAToB, signature})
        success → Outcome.Filled; settledQuote += quoteIn; deliveredTokens += tokensOut
        revert  → Outcome.Defected; forfeitedBonds += bond          (router state rolls back)
burn(committedTokens − deliveredTokens)                                  ERC20Burnable.burn → totalSupply falls
bondsToPool = settledQuote == 0 ? forfeitedBonds : 0
transfer(settledQuote + bondsToPool) → factory
status = Settled
```

The registry is the **taker**: it pays launch tokens (`tokenIn`) and receives quote (`tokenOut`) pulled from the backer's wallet by the router (`safeTransferFrom(maker, taker)` in signature mode, `Aqua.pull` in Aqua mode). Any reason the pull fails (quote moved, allowance revoked, invalidator already flipped, deadline hit) surfaces as a revert inside `swap`, is caught in `_fill` (`:541`), and marks the backer defected. Router state changes from the failed attempt roll back with the revert. Success is measured by balance deltas, not return values.

Over-subscription fills in commit order until `Q` is met; defectors are skipped over and later backers fill the gap. Tokens delivered are always `settledQuote / committerPrice`; everything else burns, so:

> A failed commitment round cannot leave public buyers worse off than no commitment round.

Supply falls by the unsettled tranche and every circulating token is backed by quote that was actually paid.

### 4.5 Where forfeited bonds go (`Idea2 §9`, `Plan §4`)

The two source docs disagree (fillers first vs. "stays as pool quote"). Implemented as a priority order that satisfies both:

1. **Committers who honoured**, pro rata by filled quote, claimable via `claimBond` (`:490`): the bond is mutual insurance among backers, not a fine paid to strangers who bought high on the curve.
2. **The pool seed**, only when nobody honoured (the all-defect example in Idea2 §6: "200 USDC sits in the pool backing the public's tokens").

`WeirV2BuybackVault` was not used as a sink: it locks *tokens*, and converting forfeited quote into tokens would need a swap at settlement time that has no natural counterparty.

### 4.6 Expiry

If a launch never graduates, `expire` (`:401`) after `tradingOpensAt + ORDER_LIFETIME` marks everyone `Unfilled`, releases the exposure cap and lets bonds be reclaimed. A graduation after that still routes through `settle`, which sees the expired state, attempts no fills and burns the whole tranche. Backers are never locked in by a stalled launch.

---

## 5. Graduation path (factory)

`graduate` (`src/WeirV2LaunchFactory.sol:1188`):

```
require phase == NotGraduated && curve.readyToGraduate()
settledQuote = _settleCommitments(token)          §4.4; 0 when no campaign
_assertGraduationSeedable(realQuote + settledQuote, tokenReserve)
_sweepCurve(extraQuote = settledQuote)            curve.graduate() → sweptQuote = curveQuote + settledQuote
phase = Swept
```

Ordering facts this enforces (`Idea2 §7`):

- **Settlement lives in the graduation path proper**, not behind the curve's `try`. The curve's auto-graduation still wraps `factory.graduate` in `try/catch`, but that only decides whether the *crossing buy* survives. A structural settlement failure emits `AutoGraduationFailed`; a keeper then calls `factory.graduate` directly and sees the real revert. A single backer's failed fill never reverts anything.
- **Burn before seed.** `settle` burns before `curve.graduate` moves reserves and long before `createGraduatedPool` (`:1329`) initialises the pool.
- **Atomic.** Settlement, burn, and the seed preflight are one transaction; a preflight refusal reverts the settlement with it, so a launch can never be half-settled.
- `readyToGraduate()` is the trigger and `graduated` flips only inside `curve.graduate`, after settlement.

Settled quote is measured as the factory's balance delta across `registry.settle` (`_settleCommitments`, `:1242`) and added to `sweptQuote` (`_sweepCurve`, `:1263`). `createGraduatedPool` sizes the pool's token side as `sweptTokens × sweptQuote / (sweptQuote + phantomQuote)`; extra settled quote therefore seeds the pool at a **higher** price than the curve's terminal price, with the leftover tokens permanently locked. This is the on-chain form of the demo claim "public price per token demonstrably higher" in Idea2 §11.

`forceSweptGraduation` (`:1216`), the owner's path for a seed the preflight refuses, settles too, so a stuck launch still resolves bonds and burns the tranche.

---

## 6. Post-graduation: hook, fee split, staking

### 6.1 Hook

`WeirV2MemeHook` is one CREATE2-mined singleton shared by every graduated pool (`beforeInitialize` + `afterSwap` + `afterSwapReturnsDelta`). On every swap `_afterSwap` (`src/hooks/WeirV2MemeHook.sol:621`) takes `hookFeeBps + creatorTaxBps` of the unspecified leg into `pendingFees` / `pendingCreatorTax`, earmarking the buyback slice per swap at accrual. `sweepPoolFees` (`:677`) converts any memecoin-denominated fees to quote against the pool's own liquidity (bounded by `maxInternalPriceImpactBps`), then `_distribute` (`:857`) splits.

### 6.2 Fee split (`Plan §3a`)

```
total swept fee (hookFeeBps of volume)
  ├── protocol      = total × protocolFeeShareBps          frozen per pool
  └── creator bucket
        ├── stakers  = bucket × stakerFeeShareBps          frozen per pool  ← NEW (was read live)
        ├── buyback  = per-swap earmark, clamped to bucket  frozen per pool
        └── creator  = remainder + creatorTax
```

`stakerFeeShareBps` was the one leg still read from the live global at sweep time, letting the owner reprice every pool's staker share retroactively. It is now part of `FeePolicySnapshot` (`src/interfaces/ILaunchpadV2.sol`), snapshotted at launch into `_launchFeePolicies[token]`, pinned by the creator's `expectedEconomics` digest (eleven values), passed into `registerPool`, stored in `LaunchInfo`, and read from there (`:874`). A staker opting into auto-compound knows the exact share they are compounding: at defaults (1% fee, 30% protocol, 40% staker) that is 0.28% of swap volume.

Creators confirm the split; they do not set it (`Plan §5.6` decided: no creator-settable staker share, same race-to-the-bottom shape as the bond argument).

### 6.3 Staking vault

Deployed per pool in `_registerPool` (`:444`) through `WeirV2StakingVaultDeployer` (§8). `notifyReward` (`src/WeirV2StakingReward.sol:397`) raises `accRewardPerShare`; stakers hold the memecoin directly with no LP exposure, a 7-day lock re-armed on each top-up, and pull rewards through `WeirV2FeeEscrow`.

### 6.4 Auto-compound (Idea 1)

| Step | Where |
|---|---|
| Hook hands the vault its SwapVM router + WETH at creation (or later via `configureStakingVaultCompounding`) | hook `:326`, vault `setCompoundRouter :209` |
| Staker opts in | `setAutoCompound(true)` `:228`; settles under the old mode first, so the toggle never reclassifies earned reward |
| Accrual | `_settle` `:427` routes accrued quote into `compoundable[user]` `:123` instead of the escrow |
| Execution | `compound(account, order, signature, minTokensOut)` `:262` |

`compound` may be called by the staker or by a protocol fee-sweep operator (the same trust boundary as every other slippage-sensitive action). It validates that the order's pair is exactly `(memecoin, quote)` (WETH standing in for native ETH), builds taker traits (exact-in, `allowPartialFill`, threshold `minTokensOut`), and fills:

- ERC-20 quote: `forceApprove(router, budget)` → `swap` → approval reset.
- Native quote: `swap{value: budget}`; the router wraps to WETH and refunds any unspent value.

Spend and purchase are measured by balance deltas; `quoteSpent ≤ budget` and `tokensRestaked > 0` are enforced. Bought tokens are added to `users[account].amount` and `totalStaked`, `rewardDebt` is rebased, and **`unlockTime` is not touched**: compounding is reinvestment of earned reward, not a new deposit. Any leftover budget stays compoundable. The maker can be any resting SwapVM strategy (limit order, TWAP, XYC AMM, Aqua-shipped), so protocol fee flow becomes standing buy pressure through the official router with no custom opcode.

### 6.5 Futarchy: the dead-pool exit

Launchpads are littered with pools whose liquidity is trapped forever. Weir lets the people who built a launch decide, by decision market, to open it for redemption, and then take a bounded share of the locked liquidity out by burning their tokens.

**Who counts as a member.** `WeirV2PoolRedemption.contribution(token, account)` = tokens bought on the bonding curve net of sells (`WeirV2BondingCurve.curveBought`, credited in `buy`, debited in `sell`) plus tokens delivered through a filled commitment (`WeirV2CommitmentRegistry` `filledTokens`). Buyers on the v4 pool after graduation are not members. Membership is both the vote gate and the per-account redemption allowance.

**The market.** `WeirV2FutarchyProposal` deploys two independent LMSR `BinaryMarket`s (PASS / FAIL), trades for `TRADING_WINDOW = 3 days`, and `finalize` resolves both and, if PASS priced above FAIL, calls `unlockEarlyExit` on the staking vault and `unlockRedemption` on the redemption contract. Both markets have their `tradeGate` set to the proposal, whose `canTrade` asks `isMember(token, trader)`; the gate is the single addition made to the vendored market and applies to buying shares only (selling and claiming stay open). A `PROPOSE_BOND` of 0.01 ETH prices out spam and is returned unconditionally. Only `WeirV2LaunchFactory.createFutarchyProposal` can create a proposal: it wires it into the vault through the hook's validated `registerFutarchyProposal` and binds it on the redemption contract through `registerProposal`, so a look-alike proposal can neither seize a vault nor unlock a pool. There is no TWAP oracle; the end-of-window LMSR price is the accepted manipulation surface for this member-gated question.

**Redemption.** After PASS, `WeirV2PoolRedemption` snapshots the position's liquidity `L0`; at most `MAX_REDEEMABLE_BPS = 40%` of `L0` may ever be removed, the other 60% stays locked forever. A member burning `a` tokens against supply `S`:

```
liquidity = a / S × L_current                       (proportional: pool price does not move)
locker.redeemLiquidity(token, liquidity, redemption) → DECREASE_LIQUIDITY + TAKE_PAIR
quoteOut → member (checked against minQuoteOut)
burn(a + tokensFromPool)                            supply falls by both legs
```

Requirements: `a ≤ eligibleTokens(token, member)` (lifetime contribution minus already redeemed) and `liquidity ≤ remaining 40% budget`. The share is taken against total supply, which still counts pool- and locker-held tokens, so it is deliberately conservative.

Two entry points: `redeem` for any member holding tokens, and `redeemFor`, callable only by the pool's staking vault, which `burnAndRedeem` uses so a staker can exit the 7-day lock straight into a redemption with their accrued reward paid alongside. The older `burnAndExit` (burn stake, receive only accrued reward) is kept for stakers who simply want out without a pool claim.

**Locker change.** `WeirV2LaunchLocker` previously exposed no liquidity path at all. It now has exactly one, `redeemLiquidity`, restricted to the redemption contract, which in turn only acts after a PASS, for members, within the cap. Slippage minimums are zero at the locker because the redemption contract enforces the member's quote floor on what actually arrived.

---

## 7. SwapVM integration summary (for 1inch judges)

| Concern | Choice |
|---|---|
| Router | Official `SwapVMRouter` or `LimitSwapVMRouter` (both contain every opcode used). Local-fork redeploy for demo. Address supplied via `SWAP_VM_ROUTER` in `script/DeployWeirV2.s.sol`. |
| Interface | `src/interfaces/ISwapVM.sol`, ABI-identical mirror (the vendored sources pin solc 0.8.30 and unpublished npm deps). |
| Maker side | Commitment: backer's one-shot `StaticBalances · LimitSwap` order (`SwapVMOrderLib.limitOrderProgram`). Auto-compound: any maker's resting strategy. |
| Taker side | Registry (settlement) and staking vault (compound) are takers; traits built by `SwapVMOrderLib.buildTakerTraits`. |
| Auth modes | EIP-712 signature (default) or Aqua balance mode (`useAqua`), same order bytes. |
| Replay protection | `InvalidateBit` per (registry, launch) plus a `Deadline`; the registry never stores an order without both. |
| Custom opcodes | None. |

---

## 8. Contract size and deployment

The repo builds without the optimizer (`foundry.toml`), so raw `--sizes` numbers are inflated. Optimized (`--optimize --optimizer-runs 200`) runtime sizes after this change:

| Contract | Before | After | Limit 24,576 |
|---|---|---|---|
| `WeirV2MemeHook` | 21,625 | 19,138 | ✅ (vault creation code moved to `WeirV2StakingVaultDeployer`) |
| `WeirV2StakingReward` | 3,580 | 7,033 | ✅ |
| `WeirV2BondingCurve` | 10,022 | 11,100 | ✅ |
| `WeirV2CommitmentRegistry` | — | 11,435 | ✅ |
| `WeirV2PoolRedemption` | — | 6,307 | ✅ |
| `WeirV2LaunchLocker` | — | 3,335 | ✅ |
| `WeirV2LaunchFactory` | 36,085 | 39,983 | ❌ pre-existing; was already over before this work |

The factory oversize predates this change; splitting it further (e.g. moving creator-fee governance out) is a known follow-up, unrelated to the two ideas.

Deployment order (`script/DeployWeirV2.s.sol`): escrow → hook (CREATE2 mined) → buyback vault → locker → factory → launch deployer → graduation executor → **staking vault deployer** → **pool redemption** → wiring (`hook.setPoolRedemption`, `locker.setRedemption`) → optional: **commitment registry + compound router** when `SWAP_VM_ROUTER` is set.

---

## 9. Decisions, trade-offs and known gaps

| Topic | Decision | Why |
|---|---|---|
| Tranche vs threshold | Excluded from threshold | Keeps the deterministic graduation price every guard depends on; commitments are upside, not a promise the public trades against. |
| Settlement trigger | Inside `factory.graduate`, before sweep, atomic | Burn-before-seed; not behind a swallowed `try`. |
| Bond ratio | Protocol constant 20% | Creator-settable bonds race to zero and externalise onto public buyers. |
| Concurrency | Aggregate exposure cap on wallet balance at commit | Removes the *free* multi-pool option without a leverage constant. Escalating bonds / correlated slashing not implemented. |
| Forfeited bonds | Fillers pro rata, else pool | Reconciles Idea2 §9 and Plan §4. |
| Token address at commit | Token + curve deployed at campaign open, curve gated by `tradingOpensAt` | Backers sign against the real address; no CREATE2 prediction needed. |
| Quote asset for campaigns | ERC-20 only | Native ETH would need WETH wrapping on the backer and the seed side. Gap. |
| Cure window (`Plan §1d`) | Not implemented | Would delay pool seeding by the window; settlement is atomic at graduation instead. Gap. |
| Whitelist mechanism | Merkle root in registry | SwapVM's whitelist opcodes gate *takers*; the taker here is always the registry. |
| Settlement gas | ≤ 64 fills per campaign | One external `swap` per backer; the keeper path exists for a crossing buy that underfunds gas. |
| Compound authorisation | Staker or fee-sweep operator | Caller picks the order and the floor; same boundary as fee sweeps. |
| Auto-compound price protection | Caller's `minTokensOut`, router-scaled | No oracle in the system; same model as `minBuybackTokensOut`. |
| Redemption ceiling | 40% of liquidity at unlock, protocol constant | "Not all": a dead-pool exit for builders, not a full unwind; 60% stays as permanent floor liquidity. |
| Redemption share basis | `a / totalSupply` of current liquidity | Proportional removal keeps price fixed; counting pool/locker tokens in the denominator under-pays slightly rather than over-pays. |
| Who may redeem / vote | Curve buyers (net) + filled committers | The reward is for those who took launch risk; v4 buyers and outsiders cannot vote a pool dead or drain it. |
| Vote gate placement | `BinaryMarket.swapIn` only | Buying shares is the vote; selling and claiming stay open so nobody is trapped in a position. |
| Vendored market | One additive change (`tradeGate`) | Member gating cannot be done from outside without wrapping every call; a single optional hook is the smallest edit. |

Known gaps: no oracle on futarchy resolution (end-of-window LMSR price); `curveBought` follows the buyer, not the tokens, so a member may redeem with tokens acquired elsewhere up to their contribution; redemption of a native-quote pool pays ETH to the member and requires the redemption contract's `receive()`.

---

## 10. Invariants worth testing (see `TestCase.md`)

1. `trackedTokens + committedTokens + (tokens delivered or burned) == balance the curve was minted` until release.
2. A launch with a campaign graduates at exactly `graduationThreshold` real public quote.
3. `deliveredTokens + burnedTokens == committedTokens` after settlement.
4. `sweptQuote == curve real quote + settledQuote + bondsToPool`.
5. Sum of claimable bonds + forfeited-to-pool == `totalBonded`.
6. `outstandingPledge[b] == 0` for every backer after settle or expire.
7. `compoundable` balances are never counted in `accRewardPerShare` and `quoteSpent ≤ budget` on every compound.
8. `unlockTime` is unchanged by `compound`.
9. `info.stakerFeeShareBps` never changes after `registerPool`, whatever the global does.
10. Hook runtime size < 24,576 in an optimized build.
11. `liquidityRedeemed ≤ 0.4 × liquidityAtUnlock` for every pool, forever.
12. `redeemed[token][a] ≤ contribution(token, a)` for every member; non-members can neither redeem nor buy market shares.
13. A redemption never changes the pool's `sqrtPriceX96`.

---

## 11. File index with judge pointers

- Uniswap v4: `src/hooks/WeirV2MemeHook.sol` (`_afterSwap :621`, `_executeInternalSwap :984`, `_distribute :857`), `src/WeirV2LaunchFactory.sol` (`createGraduatedPool :1329`, `registerPool call :1512`), `src/WeirV2GraduationExecutor.sol`, `src/WeirV2LaunchLocker.sol`.
- 1inch SwapVM / Aqua: `src/WeirV2CommitmentRegistry.sol` (`commit :433`, `settle :330`, `_fill :541`, `_buildOrder :520`), `src/WeirV2StakingReward.sol` (`compound :262`), `src/libraries/SwapVMOrderLib.sol`, `src/interfaces/ISwapVM.sol`.
- Curve partitions and trading gate: `src/WeirV2BondingCurve.sol` (`_initialize :285-317`, `releaseCommittedTokens :324`, `TradingNotOpen :473/:564`).
- Futarchy and dead-pool redemption: `src/WeirV2FutarchyProposal.sol` (`canTrade`, `finalize`), `src/WeirV2PoolRedemption.sol` (`contribution`, `unlockRedemption`, `redeem`, `redeemFor`), `src/WeirV2LaunchLocker.sol` (`redeemLiquidity`), `src/WeirV2StakingReward.sol` (`burnAndRedeem`), `src/WeirV2BondingCurve.sol` (`curveBought`), `src/MemePredictionMarket/Binary.sol` (`tradeGate`), `src/WeirV2LaunchFactory.sol` (`createFutarchyProposal`).
- Idea sources: `Ideas/Idea1.md`, `Ideas/Idea2.md`, `Ideas/Plan.md`.
