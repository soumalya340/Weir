# Weir V2 — Security Audit

**Scope:** `src/` (10 contracts + 2 libraries + 2 interface files), `script/DeployWeirV2.s.sol`
**Commit:** `3c4ac86` (working tree)
**Date:** 2026-09-13
**Method:** Full manual read of every contract in scope, plus executable proof-of-concept tests (`test/AuditPoC.t.sol`, 4 passing) for the access-control findings.

> Two files in scope were authored during this session and are audited here on the same footing as the rest: `src/WeirV2FeeEscrow.sol` and `script/DeployWeirV2.s.sol`.

---

## Summary

| # | Severity | Finding | Location |
|---|----------|---------|----------|
| 1 | **Critical** | `setFutarchyProposal` is permissionless — any EOA can unlock early exit with no decision market | `WeirV2StakingReward.sol:173` |
| 2 | **High** | The entire staking/futarchy subsystem is unreachable — `registerStakingVault` has no caller | `WeirV2MemeHook.sol:433` |
| 3 | **High** | `WeirV2FutarchyProposal.sol` does not compile — its dependency is missing and gitignored | `WeirV2FutarchyProposal.sol:5` |
| 4 | Medium | Protocol-owner creator-fee override can override a creator's own transfer | `WeirV2LaunchFactory.sol:946` |
| 5 | Medium | Anti-snipe tax is fully advertised but never charged | `WeirV2BondingCurve.sol:148` |
| 6 | Medium | CREATE2 salt / vanity addresses documented but not implemented | `WeirV2LaunchDeployer.sol:29` |
| 7 | Medium | Sweep operator is a single point of failure for all fee conversion | `WeirV2MemeHook.sol:556` |
| 8 | Low | `buybackVault.lock()` executes before the slippage check | `WeirV2MemeHook.sol:769` |
| 9 | Low | Staking reward rounding dust is permanently stranded | `WeirV2StakingReward.sol:236` |
| 10 | Low | `credit()` accepts zero-value calls and a zero-amount `creditToken` | `WeirV2FeeEscrow.sol:29` |
| 11 | Low | Deploy script's one-time wiring is not idempotent and has no verification step | `script/DeployWeirV2.s.sol:101` |
| 12 | Info | Test coverage omits the three largest contracts entirely | `test/` |

**Not a finding (investigated and cleared):** bonding-curve `sell()` quote accounting — see [Appendix A](#appendix-a--investigated-and-cleared).

---

## 1. Critical — `setFutarchyProposal` is permissionless

**Location:** `src/WeirV2StakingReward.sol:173-178`

```solidity
function setFutarchyProposal(address proposal) external {
    if (proposal == address(0)) revert ZeroAddress();
    if (futarchyProposal != address(0)) revert FutarchyProposalAlreadySet();
    futarchyProposal = proposal;
    emit FutarchyProposalSet(proposal);
}
```

There is no access control. Any address may name **itself** as the vault's futarchy proposal, then immediately call `unlockEarlyExit()` (`:186`), which only checks `msg.sender == futarchyProposal`.

The entire decision-market apparatus — the LMSR pass/fail markets, the 3-day trading window, the 0.01 ETH proposer bond — is bypassed. The attacker needs none of it.

### Impact

Two distinct attacks, both proven:

**(a) Unlock bypass.** An attacker unlocks early exit on any vault, defeating the 7-day `UNLOCK_PERIOD` for every staker in it. The lock exists specifically to stop staking in front of a known fee sweep and unstaking straight after (`:36-38`); removing it re-opens exactly that.

**(b) Permanent griefing.** Because the slot is single-use (`FutarchyProposalAlreadySet`), an attacker who seizes it and *never* unlocks has permanently bricked futarchy for that vault. No legitimate `WeirV2FutarchyProposal` can ever wire itself in — and `WeirV2FutarchyProposal`'s constructor calls `setFutarchyProposal` (`:97`), so deploying one against a squatted vault reverts in construction.

### Proof of concept

Both attacks are demonstrated by passing tests in `test/AuditPoC.t.sol`:

```
[PASS] test_poc_anyoneCanUnlockEarlyExitWithoutDecisionMarket()
[PASS] test_poc_squattingTheProposalSlotBricksFutarchyForever()
```

The first stakes as a normal user, has an unrelated EOA seize the slot and unlock, then burns out *inside* the lock window. The second shows a legitimate proposal address being permanently locked out.

### Why the existing design note doesn't cover this

The docstring argues the call is "permissionless and settable at most once" so "anyone can point a fresh `WeirV2FutarchyProposal` at an unwired vault." That intent is reasonable, but the implementation never checks that `proposal` **is** a `WeirV2FutarchyProposal` — so "anyone can wire a proposal" is in practice "anyone can wire themselves."

### Recommendation

The vault must verify the proposal is genuine and bound to itself. Options, strongest first:

1. **Have the factory/hook register it**, matching the trust model every other per-pool wiring call already uses (`registerStakingVault` is `onlyFactory`).
2. **Verify the callback shape** — require `WeirV2FutarchyProposal(proposal).vault() == address(this)`, so the proposal must at minimum be a contract that has committed to this vault. Combine with a deployer allowlist, since a malicious contract can still satisfy this.
3. At minimum, require the caller to post `PROPOSE_BOND` so squatting is not free.

Note that (2) alone does not fully close attack (a): an attacker can write their own contract exposing `vault()` and an unlock trigger. A registry of factory-deployed proposals is the robust fix.

---

## 2. High — The staking and futarchy subsystem is unreachable in the deployed protocol

**Location:** `src/hooks/WeirV2MemeHook.sol:433`

`registerStakingVault` is `onlyFactory`. `WeirV2LaunchFactory` never calls it:

```
$ grep -rn "registerStakingVault\|WeirV2StakingReward\|stakingVault" src/WeirV2LaunchFactory.sol
(no matches)

$ grep -rn "new WeirV2StakingReward" src/ script/
(no matches)
```

No contract in `src/` or `script/` ever deploys a `WeirV2StakingReward`, and the only function that could register one has no reachable caller.

### Impact

`stakingVaults[poolId]` is permanently `address(0)` for every pool. In `_fundStakingVault` (`:817`):

```solidity
if (address(vault) == address(0) || vault.totalStaked() == 0) return 0;
```

…always returns `0`, so `_distribute` folds the entire staker share back into the creator bucket every time.

The hook's default `stakerFeeShareBps` is **4000 (40%)** and is documented as the headline community-yield mechanism. In the system as it stands, that 40% silently accrues to the creator instead, on every pool, forever. This is a direct contradiction between the protocol's stated economics and its behaviour — and it fails open (no revert, no event), so it would not be noticed in testing.

This also renders finding #1 currently unexploitable *in production*, since no vault can be registered. That is not mitigation — it means the whole feature is absent. Fixing #2 without fixing #1 activates the Critical.

### Recommendation

Decide which is true and make the code say it:

- **If staking ships:** add a factory path that deploys a `WeirV2StakingReward` per launch (or lets the creator deploy one) and calls `memeHook.registerStakingVault`. Fix #1 *before* this lands.
- **If staking does not ship yet:** set `stakerFeeShareBps` default to `0` and document the 100% creator split, so the advertised economics match reality.

---

## 3. High — `WeirV2FutarchyProposal.sol` cannot compile; its dependency is absent and gitignored

**Location:** `src/WeirV2FutarchyProposal.sol:5`

```solidity
import {BinaryMarket} from "../deps/degencalls_smartcontracts/src/Binary.sol";
```

- `deps/` does not exist on disk.
- `deps` is listed in `.gitignore:145`.
- It is not a submodule (`.gitmodules` lists only the six `lib/` deps).

`forge build` fails on this file, and on `test/WeirV2FutarchyProposal.t.sol` which imports it. **The project does not currently build.** This is pre-existing and unrelated to the deployment script, but it means the futarchy layer exists only as uncompilable source, and its 213-line test suite cannot run.

### Impact

Beyond the broken build: because the dependency is gitignored, anyone cloning this repo gets a non-building project with no path to obtain the missing code. The LMSR market implementation that `WeirV2FutarchyProposal` delegates all of its pricing and resolution to is entirely outside audit scope and outside version control — its correctness is unverifiable.

### Recommendation

Vendor `BinaryMarket` as a proper git submodule under `lib/` (as with the other six dependencies) and remove `deps` from `.gitignore`, or inline the contract into `src/`. Until then, treat the futarchy feature as unshipped. Any audit assurance about `WeirV2FutarchyProposal` is contingent on `BinaryMarket`, which was not reviewable.

---

## 4. Medium — Owner's creator-fee override supersedes a creator's own transfer

**Location:** `src/WeirV2LaunchFactory.sol:946-957`, `:888-894`

The docstring is explicit and self-aware about this, so it is reported as a design risk rather than a bug — but it deserves prominence because it is a standing protocol power, not the lost-key recovery it is framed as at first glance.

`setCreatorFeeRecipient` (owner) proposes a change on a 3-day timelock. `transferCreatorFeeRecipient` (creator) **deliberately does not cancel it** (`:932-935`). So:

1. Owner proposes redirecting creator fees to address `X`.
2. Creator notices and transfers their recipient to their own new safe address `Y`.
3. Timelock elapses; anyone calls `executeCreatorFeeRecipientChange`; recipient becomes `X`.

The creator cannot veto. `_setCreatorFeeRecipient` additionally redirects the **buyback vest** (`:1003`), so vested buyback tokens follow too.

### Impact

The protocol owner can unilaterally seize any launch's future creator fee stream and its accrued buyback vest, with 3 days' notice and no creator recourse. For a launchpad whose pitch is breaking from extractive models, this is a meaningful centralization risk that creators should be able to price in.

### Recommendation

This is a product decision, not strictly a vulnerability. Either:
- Have `transferCreatorFeeRecipient` cancel any pending override (making the timelock a genuine notice-and-veto window), **or**
- Document this power prominently in user-facing material. The in-code documentation is good; the risk is that creators never read it.

---

## 5. Medium — Anti-snipe tax is fully plumbed but never charged

**Locations:** `src/WeirV2BondingCurve.sol:144-148`, `:304-310`; `src/WeirV2LaunchFactory.sol:319-320`, `:564-583`, `:746-751`

The factory maintains `snipeTaxStartBps` (default **9900 = 99%**) and `snipeTaxSeconds` (15), validates them in two owner setters, accepts bounded per-launch exemption lists, and auto-exempts the creator's addresses. The curve stores `snipeTaxExempt`.

`buy()` and `sell()` never read `snipeTaxExempt` and never charge any snipe tax. The curve's own comment confirms it (`:146-147`).

### Impact

Launches are fully exposed to opening-block sniping while the surrounding API strongly implies protection. A creator who passes an exemption list, sees it accepted, and sees a 99% default tax configured has every reason to believe their launch is protected. It is not. The gas spent on exemption writes is also pure waste.

### Recommendation

Implement the decaying tax in `buy()`, or remove the parameters, setters, exemption plumbing, and `MAX_SNIPE_TAX_*` constants until it is implemented. Shipping the configuration surface without the mechanism is the dangerous middle ground.

---

## 6. Medium — CREATE2 salt and address prediction are documented but unimplemented

**Location:** `src/WeirV2LaunchDeployer.sol:29-34`, `src/WeirV2LaunchFactory.sol:146-157`

`TokenParams.salt` carries ~12 lines of documentation describing deterministic addresses, vanity mining, front-running resistance ("cannot be taken by a launch that lands first"), and a `predictLaunchAddresses` helper. The deployer uses plain `new`, consumes the salt for nothing, and `predictLaunchAddresses` does not exist.

### Impact

Reusing a salt does **not** revert as documented. Addresses are not predictable, so a creator cannot pre-compute or pre-fund a launch address, and any integration relying on the documented behaviour will silently misbehave. The claimed front-running protection is absent.

### Recommendation

Implement CREATE2 deployment in `WeirV2LaunchDeployer.deployLaunch` with the salt namespaced by `originalDeployer` as documented, and add `predictLaunchAddresses`. Otherwise remove `salt` from `TokenParams` and its documentation.

---

## 7. Medium — Sweep operator is a liveness single point of failure

**Location:** `src/hooks/WeirV2MemeHook.sol:550-558`, `:661-667`; `src/WeirV2BondingCurve.sol:498-506`

Any sweep involving an internal swap (`_requiresTrustedOperator`) is restricted to the single `feeSweepOperator` address. The reasoning is sound — it prevents an arbitrary caller choosing a permissive minimum around a manipulable spot price, and the code says so clearly (`:843-856`).

The cost is that if the operator key is lost or goes offline, **every pool's memecoin-denominated fees become unconvertible**. Creators cannot self-serve because `_requiresTrustedOperator` returns true precisely when conversion is needed.

Mitigations exist (`rescuePoolFees`, `rescueCurveFees`) but both are `onlyOwner` and bypass the escrow — recovery tools, not operations.

### Recommendation

Allow a set of operators rather than one address, or permit the creator to sweep with a minimum derived from a Chainlink feed. At minimum, run the operator as a multisig and document the recovery runbook.

---

## 8. Low — `buybackVault.lock()` runs before the slippage check

**Location:** `src/hooks/WeirV2MemeHook.sol:767-778`

```solidity
if (tokensLocked != 0) {
    IERC20(info.memecoin).forceApprove(address(buybackVault), tokensLocked);
    buybackVault.lock(...);                       // state change + transfer
    if (tokensLocked < minBuybackTokensOut) {     // check AFTER
        revert SlippageExceeded(...);
    }
}
```

The lock (an external call that moves tokens and mutates vest accounting) executes before the minimum-output check that may revert it.

Not currently exploitable — the revert unwinds the whole transaction, and `_distribute` is reached only under `nonReentrant`. But it inverts checks-effects-interactions, and it wastes the gas of a full vest update on a doomed path. It would become a real bug if this branch were ever made non-atomic (try/catch, or a multi-pool batch sweep).

### Recommendation

Move the `tokensLocked < minBuybackTokensOut` check above the `forceApprove`/`lock` pair. The curve's equivalent path (`WeirV2BondingCurve.sol:704`) already orders it correctly.

---

## 9. Low — Staking reward rounding dust is permanently stranded

**Location:** `src/WeirV2StakingReward.sol:236`

```solidity
accRewardPerShare += (amount * ACC_REWARD_SCALE) / totalStaked;
```

Integer division truncates. The remainder of `amount * 1e18 / totalStaked` is never credited to anyone but the ETH/tokens for it have already been transferred in. Over many sweeps the vault accrues a balance no one can withdraw — there is no sweep-dust function and `receive()` accepts the ETH silently.

Magnitude is small (< 1 wei of reward per notify, scaled), so this is genuinely Low. It is noted because there is no recovery path at all.

### Recommendation

Either carry the remainder forward into the next `notifyReward`, or accept it and document that vault dust is unrecoverable.

---

## 10. Low — Fee escrow accepts zero-value and zero-amount credits

**Location:** `src/WeirV2FeeEscrow.sol:29-39` *(authored this session)*

`credit(recipient)` accepts a zero-`msg.value` call, and `creditToken` accepts `amount == 0`, each emitting no event but costing the caller gas and performing a pointless `safeTransferFrom`. Neither is a security issue — balances are unaffected — but `creditToken` with a zero amount will revert on tokens that disallow zero-value transfers, which could surprise an integrator.

Also note `_sendNative` reverts the whole claim if the recipient rejects ETH. That is correct (it only ever affects the claimant's own balance, and failing loudly beats silently zeroing it), but a recipient contract without a payable fallback will find its balance permanently unclaimable. `claim(uint256)` gives no escape since it uses the same path.

### Recommendation

Early-return on zero in both credit functions. Consider a `claimTo(address)` variant so a contract recipient can direct funds to a payable address.

---

## 11. Low — Deployment script wiring is non-idempotent with no verification

**Location:** `script/DeployWeirV2.s.sol:101-108` *(authored this session)*

The six wiring calls (`setFactory`, `setBuybackVault`, `setLaunchDeployer`, `setGraduationExecutor`, …) each revert on a second call. A script run that fails partway — say, out of gas after deploying but before wiring — leaves deployed-but-unwired contracts and cannot simply be re-run; it will deploy a *second* full set.

The script also never calls `factory._requireLaunchDependenciesWired()`'s public equivalent to confirm the stack is correctly wired before finishing, so a misconfiguration surfaces only at the first `launchToken` call.

### Recommendation

Add a post-wiring verification block asserting the same invariants `_requireLaunchDependenciesWired` checks, and log all seven addresses in a machine-readable form for re-use. For production, consider splitting deploy and wire into separate scripts with addresses read from env.

---

## 12. Info — Test coverage omits the three largest contracts

Current suite: 61 tests across 4 files, covering `WeirV2BuybackVault`, `WeirV2StakingReward`, `WeirV2LaunchLocker`, and `WeirV2FutarchyProposal` (the last cannot run — finding #3).

No tests exist for:

| Contract | Lines | Tests |
|---|---|---|
| `WeirV2LaunchFactory.sol` | ~1520 | **0** |
| `WeirV2BondingCurve.sol` | 792 | **0** |
| `WeirV2MemeHook.sol` | 979 | **0** |
| `WeirV2GraduationExecutor.sol` | 210 | **0** |
| `WeirV2GraduationGuard.sol` | 126 | **0** |

These are the contracts holding user funds, computing trade prices, and executing graduation. The untested surface includes all bonding-curve trade math, the partial-fill clamp in `buy()`, every graduation path and its rescue branches, and all hook fee accounting and internal swaps.

The existing tests are of good quality — they assert real behaviour rather than restating the implementation. The concern is purely distribution.

### Recommendation

Prioritise, in order: (1) bonding curve buy/sell/graduate including the partial-fill and refund path; (2) hook `_afterSwap` fee accrual and `_distribute` splits; (3) the factory's full launch→graduate→pool lifecycle against a forked or mocked V4 `PoolManager`. Fuzz the curve math against the constant-product invariant.

---

## Appendix A — Investigated and cleared

**Bonding curve `sell()` quote accounting** (`WeirV2BondingCurve.sol:460-485`) — initially flagged as a possible under-debit: `sell()` books `fee + tax` into `quoteFeeBalance`/`creatorTaxBalance` while subtracting only the *net* `quoteOut` from `trackedQuote`.

Traced numerically and **confirmed correct**. The fee is carved out of the gross output and never physically leaves the curve, so `trackedQuote` and the contract's real balance move in lockstep:

```
physical held:  T → T − (G − f − x)
trackedQuote:   T → T − (G − f − x)        ✅ match

realQuoteReserve = trackedQuote − F − X
                 = [T − (G−f−x)] − (F+f) − (X+x)
```

which is exactly "physical holdings minus outstanding fee liabilities." No leak, no drift. Reported here so the reasoning is not re-derived in a future review.

---

## Notes on methodology and limits

- Every contract in `src/` was read in full, not sampled.
- Findings #1 and #2 are backed by executable tests (`test/AuditPoC.t.sol`), kept in the repo as regression tests — they will begin failing once the access control is fixed, which is the intended signal.
- `BinaryMarket` (finding #3) was **not** reviewed; it is absent from the repo. All `WeirV2FutarchyProposal` behaviour depending on LMSR pricing and resolution is therefore unverified.
- No fork testing against live Uniswap V4 was performed. Hook-to-`PoolManager` interactions were reviewed by reading against the vendored `lib/v4-core` and `lib/v4-hooks-public`, not executed. The `afterSwap` delta accounting and `unlockCallback` settlement in particular would benefit from fork tests before mainnet.
- `.env` was checked and is correctly gitignored and untracked; no committed secrets were found.
