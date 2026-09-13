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

## 5. Priority Ranking

If the Foundation picks up one thing from this:

1. **Richer flash-accounting revert data** — cheapest to ship, biggest daily impact on every hook developer.
2. **Official internal-swap helper** — removes the riskiest code from every fee-taking hook.
3. **Test-mode hook addresses** — makes hook iteration feel like normal Solidity development.
4. **End-to-end contract-side liquidity guide** — one document closing the four-layer gap.
