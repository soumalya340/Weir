# Uniswap v4 Developer Feedback — Weir

> **Submission for ETHOnline 2026 — Uniswap Foundation Track**
> **Project:** Weir — fair-launch protocol on Uniswap v4 hooks & 1inch SwapVM
> **Author:** Soumalya Paul
> **Repository:** https://github.com/soumalya340/Weir
> **Architecture Reference:** [`Architecture.md`](Architecture.md)
> **Feedback Form:** [Uniswap Developer Feedback](https://developers.uniswap.org/hackathon-feedback)

---

## 1. What We Built On v4

Weir is a fair-launch launchpad. A bonding curve graduates **in place** into a permanently locked Uniswap v4 full-range position, and a singleton hook captures swap fees to stream real ETH/USDC yield to people who stake the memecoin directly — no LP exposure, no impermanent loss.

The v4 stack does three jobs that would each have needed a workaround on v2/v3:

| Job | v4 mechanism used |
|---|---|
| Graduate without a DEX migration | Singleton `PoolManager` + flash accounting — seed the pool in the same tx that settles the curve |
| Take a protocol/creator/staker fee cut per swap | `afterSwap` + `afterSwapReturnDelta` on a CREATE2-mined singleton hook |
| Convert memecoin-denominated fees to quote | `poolManager.unlock()` → `unlockCallback` internal swap against the pool's own liquidity |
| Guarantee liquidity is unruggable | Full-range position via `PositionManager` + `Permit2`, NFT locked forever |

---

## 2. Code Pointers for Verification

Line ranges verified against the committed source.

| Component | File & Lines | What it does |
|---|---|---|
| **Hook permissions** | [`src/hooks/WeirV2MemeHook.sol#L247-L264`](src/hooks/WeirV2MemeHook.sol#L247-L264) | `getHookPermissions()` — `beforeInitialize`, `afterSwap`, `afterSwapReturnDelta` all true |
| **Fee capture** | [`src/hooks/WeirV2MemeHook.sol#L642-L683`](src/hooks/WeirV2MemeHook.sol#L642-L683) | `_afterSwap()` takes `hookFeeBps + creatorTaxBps` off the unspecified leg and returns the delta |
| **Internal swap** | [`src/hooks/WeirV2MemeHook.sol#L1002-L1008`](src/hooks/WeirV2MemeHook.sol#L1002-L1008) | `_executeInternalSwap()` re-enters via `poolManager.unlock()`; callback at [`#L1010`](src/hooks/WeirV2MemeHook.sol#L1010) |
| **Fee sweep** | [`src/hooks/WeirV2MemeHook.sol#L698-L729`](src/hooks/WeirV2MemeHook.sol#L698-L729) | `sweepPoolFees()` — converts pending fees, bounded by `maxInternalPriceImpactBps` |
| **Fee split** | [`src/hooks/WeirV2MemeHook.sol#L878-L946`](src/hooks/WeirV2MemeHook.sol#L878-L946) | `_distribute()` — protocol / stakers / buyback-vest / creator, from a per-pool frozen snapshot |
| **Pool creation** | [`src/WeirV2LaunchFactory.sol#L1338-L1356`](src/WeirV2LaunchFactory.sol#L1338-L1356) | `createGraduatedPool()` initializes the pool and seeds it; `registerPool` call at [`#L1521`](src/WeirV2LaunchFactory.sol#L1521) |
| **Full-range mint** | [`src/WeirV2GraduationExecutor.sol#L81-L137`](src/WeirV2GraduationExecutor.sol#L81-L137) | `mintFullRangePosition()` — Permit2 dance + `modifyLiquidities()` action encoding |
| **Permanent lock** | [`src/WeirV2LaunchLocker.sol#L148-L155`](src/WeirV2LaunchLocker.sol#L148-L155) | `lockPosition()` — no withdraw function exists on this contract, by design |

**Hook tests:** `test/WeirV2MemeHook.t.sol`, `test/WeirV2LaunchFactory.t.sol`, `test/WeirV2LaunchLocker.t.sol`.

---

## 3. What Worked Well

**`afterSwapReturnDelta` is the feature that made this project possible.**
Taking a fee cut by returning a delta — rather than doing a second transfer after the fact — means the fee is part of the swap's own accounting. No double-charge, no separate approval, no leaked gas. On v3 this product would have needed a router wrapper that users had to be convinced to use; here it's enforced at the pool.

**Flash accounting turned graduation from a migration into a settlement.**
The v2/v3 version of "graduate a bonding curve" is: deploy a pair, approve, transfer, add liquidity, burn LP tokens — a multi-step window where bots front-run the transition and the price is briefly whatever an attacker wants. In v4 the whole thing is one `unlock` scope: settle commitments, burn what didn't honour, seed the pool. **There is no window, so there is nothing to front-run.** That removed an entire attack surface from the design rather than requiring us to defend it.

**`PositionManager`'s action encoding is genuinely elegant once it clicks.**
Packing `MINT_POSITION`, `SETTLE_PAIR`, and a conditional `SWEEP` into one `modifyLiquidities()` call ([`WeirV2GraduationExecutor.sol#L113-L131`](src/WeirV2GraduationExecutor.sol#L113-L131)) let us handle the native-ETH and ERC-20 quote cases with one code path and a branch on the action list.

---

## 4. Friction — and What Would Have Helped

### 4.1 Hook address mining is a real tax on iteration

Every permission-bitmask change means re-mining a CREATE2 salt. We call `HookMiner.find` in three places — `script/DeployWeirV2.s.sol#L162` and two test setups — and each test run pays for it.

> **The cost isn't the CPU, it's the feedback loop.** Toggling a permission to test a hypothesis stops being a one-line change.
>
> **Suggestion:** a test-only `PoolManager` mode, or an official cheatcode-based helper, that accepts a hook at any address and trusts a declared permission struct. Mine for real deployments; skip it in `forge test`.

### 4.2 Debugging flash-accounting reverts is opaque

When deltas don't net to zero, the revert surfaces from deep inside `PoolManager.unlock()` with no indication of *which* currency is unsettled or by how much. Our internal-swap path re-enters the manager ([`#L1002-L1010`](src/hooks/WeirV2MemeHook.sol#L1002-L1010)), so a mistake there produced errors several frames from the actual bug. Diagnosis was `forge test -vvvvv` and reading stack traces by hand.

> **Suggestion:** include the offending currency and the outstanding amount in the revert data. `CurrencyNotSettled(currency, delta)` instead of a bare selector would have saved hours, and costs nothing in the happy path.

### 4.3 The Permit2 → PositionManager path has four layers and no map

Minting one position means understanding token approval → Permit2 allowance → PositionManager action encoding → PoolManager settlement. The two-step approval in particular ([`#L140-L142`](src/WeirV2GraduationExecutor.sol#L140-L142)) — a standard ERC-20 approval to Permit2, *then* a Permit2 allowance to the PositionManager — is not obvious from any single doc page, and failure is silent until settlement.

> **Suggestion:** one canonical annotated "mint a full-range position from a contract" reference, covering both native-ETH and ERC-20 pairs. Most of what exists assumes an EOA with a frontend.

### 4.4 No canonical recipe for internal swaps

Converting accrued fees into the quote asset using the pool's own liquidity is something most fee-taking hooks eventually need. There's no official pattern, so every team writes its own `unlock`/`unlockCallback` re-entrancy dance and its own price-impact bound (ours is `maxInternalPriceImpactBps`). This is the single highest-risk code in our hook, and it's code that a library should own.

> **Suggestion:** ship it in `v4-periphery` — a `SwapInPool` helper with a slippage bound. It would be widely used and would concentrate the audit surface in one reviewed implementation instead of fifty hand-rolled ones.

---

## 5. What Support Was Missing / Could Have Been Better

Section 4 is about the protocol's developer experience. This section is about the **support around it** — docs, examples, and tooling — answering "what would have unblocked us faster."

### 5.1 The examples stop exactly where real hooks begin

Available hook examples are single-purpose: take a fee, return a delta, log an event. Every one we found handles a hook that **observes** a swap. Ours had to **act** — convert accrued fees to the quote asset using the pool's own liquidity.

That turned out to be the boundary where documentation ends. `DeltaResolver` (`v4-periphery/src/base/DeltaResolver.sol`) resolves deltas that already exist via `_take`/`_settle`, but nothing in periphery performs a swap inside `unlock`. `FeeTakingHook` in the core test suite takes a fee and stops — it never converts it. We were reading `V4Quoter` and `BaseActionsRouter` source to infer the re-entrancy pattern, because those were the closest working references we could find.

> **What would have helped:** one worked example of a hook that re-enters `PoolManager` during its own callback, with the re-entrancy and slippage caveats stated. This is the single most common thing a fee-taking hook needs after it has taken the fee, and it's the piece with no reference implementation.

### 5.2 Test scaffolding is available but not discoverable

`Deployers.sol` ships at `lib/v4-core/test/utils/Deployers.sol`. We never used it — our hook tests stand up `new PoolManager(...)` and a local `_mineHook()` helper by hand ([`test/WeirV2MemeHook.t.sol#L38-L57`](test/WeirV2MemeHook.t.sol#L38-L57)).

That isn't a criticism of the helper; it's that nothing pointed us at it. The cost shows up in our own test comment at [`#L24`](test/WeirV2MemeHook.t.sol#L24): *"No live pool swaps here."* Standing up a pool with real liquidity and routing a swap through it was enough setup friction that hook-level swap coverage got deferred to a different test file. **Setup cost directly shaped our test coverage** — the thing testing infrastructure is supposed to prevent.

> **What would have helped:** the hook quickstart opening with "inherit `Deployers`, here is a pool with liquidity and a swap through it, in fifteen lines." Ideally re-exported from `v4-periphery` so it doesn't read as a core-internal test utility.

### 5.3 No guidance on hooks that own state across many pools

Ours is a **singleton** — one CREATE2-mined hook serving every launched pool, holding per-pool fee policy, accrued balances, and staking-vault wiring. Every example we found assumes one hook per pool, or a stateless hook.

The questions that mattered had no documented answers: where should per-pool config live, how do you stop pool A's accounting touching pool B's, and what stops someone initializing a pool against your hook to register themselves into your fee split? We answered these ourselves (`beforeInitialize` gating plus a factory-only `registerPool`), but we were guessing at whether we'd chosen the intended shape.

> **What would have helped:** a short note on the multi-pool hook pattern — per-`PoolId` state isolation and how to gate `beforeInitialize` against unauthorized pools. It's a security-relevant pattern with no canonical guidance.

### 5.4 Contract-side integration assumes a frontend

Most liquidity documentation assumes an EOA with a wallet. Ours is a **contract** minting a position on behalf of a launch, so the Permit2 two-step ([`WeirV2GraduationExecutor.sol#L140-L142`](src/WeirV2GraduationExecutor.sol#L140-L142)) and the native-ETH vs. ERC-20 action-encoding branch had to be derived from source and tests.

> **What would have helped:** a "minting from a contract" page covering both quote types. This is what every launchpad, vault, and automated LP manager needs, and it's the path with the least written down.

### 5.5 Honest note on what we did not use

We didn't attend office hours or ask in a support channel during the build. Some of the above may well have been answerable in minutes by someone who knew where to look — so treat 5.1–5.4 as *"what we could not find on our own from docs and source"*, which is still the path most hackathon teams take under time pressure.

---

## 6. Priority Ranking

If the Foundation picks up one thing from this:

1. **Richer flash-accounting revert data** — cheapest to ship, biggest daily impact on every hook developer.
2. **Official internal-swap helper** — removes the riskiest code from every fee-taking hook.
3. **Test-mode hook addresses** — makes hook iteration feel like normal Solidity development.
4. **End-to-end contract-side liquidity guide** — one document closing the four-layer gap.
