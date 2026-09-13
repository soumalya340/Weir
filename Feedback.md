# Uniswap v4 Developer Feedback — Weir

> **Submission for ETHOnline 2026 — Uniswap Foundation Track**  
> **Project:** Weir (Fair-launchpad on Uniswap v4 Hooks & 1inch SwapVM)  
> **Author:** Soumalya Paul  
> **Repository:** [Weir](.)  
> **Architecture Reference:** [`Architecture.md`](Architecture.md)  
> **Feedback Form Submission:** [Submitted to Uniswap Developer Feedback](https://developers.uniswap.org/hackathon-feedback)

---

## 1. Project Overview & Uniswap Integration

Weir is a fair-launch memecoin launchpad where graduated bonding curves transition in-place into permanently locked Uniswap v4 full-range positions, and a singleton v4 hook captures swap fees to stream real yield to direct memecoin stakers.

### Core Uniswap Stack Components Used:
1. **Uniswap v4 Singleton `PoolManager`:** Direct pool initialization, transient balance deltas, and swap execution.
2. **Custom Hook (`WeirV2MemeHook`):** Inheriting from `BaseHook`, enabling `afterSwap: true` and `afterSwapReturnDelta: true` to capture dynamic fee cuts and execute Flaunch-style internal swaps.
3. **`PositionManager` & `Permit2`:** Orchestrated via `WeirV2GraduationExecutor` to mint full-range canonical liquidity positions at graduation without slippage or migration intermediaries.
4. **`WeirV2LaunchLocker`:** Permanent onchain custody of the Uniswap v4 position NFT.

---

## 2. Code Pointers for Verification (Judges Checklist)

Per the Uniswap Foundation prize requirements, here are the direct pointers to the contracts and lines of code implementing the Uniswap v4 integration:

| Component | File & Line Range | Exact Integration Functionality |
|---|---|---|
| **Hook Permissions** | [`src/hooks/WeirV2MemeHook.sol#L240-L253`](src/hooks/WeirV2MemeHook.sol#L240-L253) | Sets `afterSwap: true` and `afterSwapReturnDelta: true` bitmask flags. |
| **Hook Fee Capture** | [`src/hooks/WeirV2MemeHook.sol#L621-L662`](src/hooks/WeirV2MemeHook.sol#L621-L662) | `_afterSwap()` captures dynamic hook fees (`hookFeeBps` + `creatorTaxBps`) from taker deltas. |
| **Internal Swaps on v4** | [`src/hooks/WeirV2MemeHook.sol#L984-L1058`](src/hooks/WeirV2MemeHook.sol#L984-L1058) | `_executeInternalSwap()` uses pool liquidity to auto-convert memecoin fee tranches into quote tokens. |
| **Fee Distribution & Sweep** | [`src/hooks/WeirV2MemeHook.sol#L790-L920`](src/hooks/WeirV2MemeHook.sol#L790-L920) | Sweeps accumulated pool fees and splits them across protocol, stakers, buyback-vest, and creator. |
| **Pool Initialization** | [`src/WeirV2LaunchFactory.sol#L1329-L1380`](src/WeirV2LaunchFactory.sol#L1329-L1380) | `createGraduatedPool()` initializes the v4 pool with hook attachment and seeds liquidity. |
| **Full-Range LP Minting** | [`src/WeirV2GraduationExecutor.sol#L81-L160`](src/WeirV2GraduationExecutor.sol#L81-L160) | `mintFullRangePosition()` handles Permit2 allowances, calls `PositionManager.modifyLiquidities()`, and locks the position NFT. |
| **Permanent NFT Locker** | [`src/WeirV2LaunchLocker.sol#L75-L115`](src/WeirV2LaunchLocker.sol#L75-L115) | Forever locks the v4 position NFT to guarantee permanent unruggable liquidity. |

---

## 3. Developer Experience (DX) — What Went Well

* **The Power of `afterSwapReturnDelta`:** The ability for a hook to directly participate in the swap accounting delta without initiating a second external transaction is revolutionary. It allowed us to capture swap fees and route them seamlessly without double-charging or leaking gas.
* **Singleton `PoolManager` & Flash Accounting:** In Uniswap v2/v3, graduation from a bonding curve meant deploying a new pair, approving tokens, transferring liquidity, and burning LP tokens. In v4, seeding the pool in `createGraduatedPool` using flash accounting was dramatically faster, cleaner, and avoided intermediate oracle manipulation risks.
* **Composability with PositionManager:** The action-based multicall design in `PositionManager` (combining Permit2 approval, position initialization, and minting in one call) is elegant once understood.

---

## 4. Pain Points & Friction Encountered

1. **Hook Address Mining (`CREATE2` Salt Finding):**
   * *The Problem:* Mining an address whose low bits match the permission flags (`afterSwap` + `afterSwapReturnDelta`) requires external tooling (`HookMiner`) and significant local CPU cycles.
   * *DX Impact:* For rapid prototyping and testing, address mining creates initial friction, especially when tweaking hook permissions during development.
2. **Tracing Reverts in Flash Accounting:**
   * *The Problem:* When delta accounting doesn't net to zero or a custom hook reverts during `afterSwap`, debugging the root cause through `PoolManager.unlock()` can be opaque. Error codes like `CurrencyNotSettled()` or assembly reverts often required running `forge test -vvvvv` to inspect stack traces.
3. **Complexity of Permit2 + PositionManager Wiring:**
   * *The Problem:* Wiring up `Permit2` allowances $\to$ `PositionManager` actions $\to$ `PoolManager` balances requires deep understanding of four separate contract layers. While powerful, the learning curve is steep compared to classic `v2.addLiquidity()`.

---

## 5. Suggestions for the Uniswap Foundation

1. **Native Mocking & Testing Harness:** Provide an official Foundry testing library that allows developers to test hooks against mock pools without needing to mine real salt addresses in local tests.
2. **Standardized Internal Swap Utility:** Many launchpads and yield hooks want to convert token fees to quote fees via the pool's own liquidity ("internal swaps"). An official library or canonical recipe for re-entrant / unlock-based internal swaps would save builders weeks of trial and error.
3. **Interactive Debugger Tool:** A web or CLI visualizer that simulates a v4 transaction and displays balance deltas per currency before and after hook execution would drastically reduce debugging time.
