# Weir V2 — Bug Fix Report (AUDIT.md #1–#7)

**Date:** 2026-09-13  
**Scope:** Critical, High, and Medium findings from `AUDIT.md`  
**Verification:** `forge build` + `forge test` (including `test/AuditPoC.t.sol`, futarchy, staking)

---

## Summary

| # | Severity | Status | Fix |
|---|----------|--------|-----|
| 1 | Critical | **Fixed** | `setFutarchyProposal` is `onlyHook`; factory **deploys** `WeirV2FutarchyProposal` via `createFutarchyProposal` (no arbitrary-address register) |
| 2 | High | **Fixed** | `registerPool` deploys + wires a `WeirV2StakingReward` per pool |
| 3 | High | **Fixed** | Vendored `BinaryMarket` under tracked `deps/`; removed `deps` from `.gitignore` |
| 4 | Medium | **Fixed** | Creator `transferCreatorFeeRecipient` cancels pending owner override (notice-and-veto) |
| 5 | Medium | **Fixed** | Decaying anti-snipe tax charged in `buy()` |
| 6 | Medium | **Fixed** | CREATE2 deploy + `predictLaunchAddresses` in `WeirV2LaunchDeployer` |
| 7 | Medium | **Fixed** | Multi-operator set via `setFeeSweepOperatorAuthorization` / `isFeeSweepOperator` |

Low/Info findings (#8–#12) were out of scope for this pass.

---

## Finding #1 — Critical: permissionless `setFutarchyProposal`

**Problem:** Any EOA could seize the one-shot proposal slot and unlock early exit (or grief forever). A `vault()`-only check is insufficient — a malicious contract can fake that getter.

**Fix:**
- `WeirV2StakingReward.setFutarchyProposal` is now `onlyHook`.
- `WeirV2FutarchyProposal` no longer self-wires in the constructor.
- Removed permissionless `registerFutarchyProposal(token, proposal)`.
- Added `WeirV2LaunchFactory.createFutarchyProposal(token)` which **deploys** `new WeirV2FutarchyProposal` and wires only that address through the hook. Arbitrary contracts cannot become the vault's proposal.
- `WeirV2FutarchyProposal` constructor takes an explicit `proposer_` so factory-path deployment records the paying EOA (not the factory) as bond recipient for `returnBond`.

**Verification:**
- `test_poc_anyoneCanUnlockEarlyExitWithoutDecisionMarket` — attacker direct seize/unlock reverts.
- `test_poc_squattingTheProposalSlotBricksFutarchyForever` — only hook can wire.
- `test_poc_fakeVaultMatchingProposalCannotUnlockViaFactory` — fake with matching `vault()` cannot be registered; factory creates a real proposal with `proposer == attacker`; `returnBond` credits the paying EOA (factory balance unchanged); fake cannot `unlockEarlyExit`.
- Futarchy suite wires via hook and still resolves pass/fail correctly.

---

## Finding #2 — High: staking vaults never registered

**Problem:** `registerStakingVault` was `onlyFactory` with no caller; `stakerFeeShareBps` (default 40%) always folded to the creator.

**Fix:**
- `WeirV2MemeHook._registerPool` deploys `new WeirV2StakingReward(...)` and stores it in `stakingVaults[poolId]` on every graduated pool registration.

**Verification:**
- `test_fix_registerPoolDeploysStakingVault` calls live `memeHook.registerPool` and asserts `stakingVaults[poolId] != 0` with correct hook/memecoin/quote bindings.

---

## Finding #3 — High: missing `BinaryMarket` / broken build

**Problem:** Import pointed at gitignored `deps/degencalls_smartcontracts`; clones could not build or run futarchy tests.

**Fix:**
- Vendored compatible `BinaryMarket` (+ unused `FixedPointMath` helper) under `deps/degencalls_smartcontracts/src/`.
- Removed the standalone `deps` entry from `.gitignore` so the dependency is tracked.

**Verification:**
- `forge build` succeeds including `WeirV2FutarchyProposal`.
- All 12 tests in `test/WeirV2FutarchyProposal.t.sol` pass.
- `test_fix_binaryMarketVendoredInRepo` constructs a real `WeirV2FutarchyProposal` against the vendored market.

---

## Finding #4 — Medium: owner override beats creator transfer

**Problem:** Pending owner timelock override still executed after a creator self-transfer (no veto).

**Fix:**
- `transferCreatorFeeRecipient` calls `_cancelPendingCreatorFeeRecipientChange` before applying the new recipient.
- Docs updated: timelock is a notice-and-veto window; owner may re-propose after cancel.

**Verification:**
- `test_fix_creatorTransferCancelsPendingOverride` on a live `FactoryHarness`: owner proposes override → creator transfers → `pendingCreatorFeeRecipient` cleared → `executeCreatorFeeRecipientChange` reverts `NoPendingChange`.

---

## Finding #5 — Medium: anti-snipe tax never charged

**Problem:** Factory configured `snipeTaxStartBps` / exemptions, but `buy()` never charged tax.

**Fix:**
- Curve stores `snipeTaxStartBps`, `snipeTaxSeconds`, `launchedAt`.
- `currentSnipeTaxBps(account)` decays linearly; exempt addresses pay 0.
- `buy()` applies snipe as additional creator-tax ledger take (clamped so total take &lt; 100%).

**Verification:**
- `test_fix_snipeTaxIsChargedOnBuy` — sniper at t0 pays ~99% into `creatorTaxBalance`; creator exemption is 0 bps.

---

## Finding #6 — Medium: CREATE2 salt documented but unused

**Problem:** `TokenParams.salt` was ignored; `predictLaunchAddresses` did not exist.

**Fix:**
- `WeirV2LaunchDeployer.deployLaunch` uses CREATE2 with salts namespaced by `originalDeployer`.
- Added `predictLaunchAddresses` with matching address derivation.
- Launch deployment passes live `snipeTaxStartBps` / `snipeTaxSeconds` into the curve constructor.

**Verification:**
- `test_fix_create2PredictMatchesDeploy` — predicted token/curve addresses equal deployed addresses.

---

## Finding #7 — Medium: single fee-sweep operator SPOF

**Problem:** Only one `feeSweepOperator` could run slippage-sensitive sweeps; key loss stranded conversions.

**Fix:**
- Hook keeps a primary `feeSweepOperator` plus `feeSweepOperators` mapping.
- `setFeeSweepOperatorAuthorization(operator, authorized)` for multi-key liveness.
- `IWeirV2FeePolicy.isFeeSweepOperator(account)`; curve and hook sweeps use it.

**Verification:**
- `test_fix_multiFeeSweepOperator` on a HookMiner-deployed `WeirV2MemeHook` — authorize/revoke secondary operator.

---

## Files touched (high level)

| Area | Files |
|------|-------|
| Access control / futarchy | `src/WeirV2StakingReward.sol`, `src/WeirV2FutarchyProposal.sol`, `src/hooks/WeirV2MemeHook.sol`, `src/WeirV2LaunchFactory.sol` |
| Staking wiring | `src/hooks/WeirV2MemeHook.sol` |
| Dependency | `deps/degencalls_smartcontracts/src/Binary.sol`, `.gitignore` |
| Snipe tax | `src/WeirV2BondingCurve.sol`, `src/WeirV2LaunchDeployer.sol`, `src/WeirV2LaunchFactory.sol` |
| CREATE2 | `src/WeirV2LaunchDeployer.sol` |
| Operators | `src/hooks/WeirV2MemeHook.sol`, `src/interfaces/ILaunchpadV2.sol`, `src/WeirV2BondingCurve.sol` |
| Tests | `test/AuditPoC.t.sol`, `test/WeirV2FutarchyProposal.t.sol`, `test/WeirV2StakingReward.t.sol`, `test/WeirV2BuybackVault.t.sol` |
| Config | `foundry.toml` (`fs_permissions` for structural AuditPoC checks) |

---

## How to re-verify

```bash
forge build
forge test --match-path 'test/AuditPoC.t.sol' -vv
forge test --match-path 'test/WeirV2FutarchyProposal.t.sol' -vv
forge test
```
