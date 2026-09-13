# Weir — Test plan

Test cases to write, grouped by contract. Each entry names the case and what it must assert. None of these are implemented yet; this is the to-do list. Existing suites (`test/*.t.sol`, 80 tests) cover the pre-existing launchpad, buyback vault, locker, staking basics and futarchy proposal.

**Known item before adding anything:** three cases in `test/AuditPoC.t.sol` currently fail with `OwnableUnauthorizedAccount`. Cause: in `_mineHook`, `vm.prank(owner)` is consumed by the `new WeirV2StakingVaultDeployer(...)` inside the call arguments instead of by `setStakingVaultDeployer`. Fix: construct the deployer into a local first, then prank, then call.

Shared fixtures needed:

- **Mock SwapVM router** implementing `ISwapVM` for unit tests: records `(order, amount, takerData)`, can be told to succeed (pull quote from maker, push tokens from taker), revert, or under-deliver; exposes `hash()` as a keccak so signatures can be produced with `vm.sign`.
- **Fork fixture** against the official `SwapVMRouter` / `LimitSwapVMRouter` deployment (or a local redeploy of the vendored `deps/swap-vm`) for the end-to-end demo runs, since the byte-level order encoding must be proven against real code.
- An ERC-20 quote (6-decimal "USDC" mock) with an approved `PairTokenEconomics` config on the factory.

---

## 1. `SwapVMOrderLib` (byte-exact encoding)

| # | Case | Assert |
|---|---|---|
| 1.1 | `limitOrderProgram` layout | Bytes equal `[0x40,4,nonce][0x20,5,deadline][0x90,64,balA,balB][0x53,1,dir]`; `dir` byte is `0x80` for true, `0x00` for false; the Deadline instruction is omitted when `deadline == 0`. |
| 1.2 | `buildOrder` traits | `traits >> 160 & 0xffff…` slice indexes all equal 40; bit 254 set iff `useAqua`; receiver bits zero; `data[0:20] == tokenA`, `data[20:40] == tokenB`; reverts `TokensNotSorted` when `tokenA >= tokenB`. |
| 1.3 | `buildTakerTraits` layout | First 20 bytes are ten uint16 indexes in `index9..index0` order with `index0 == 32`; next 2 bytes are flags with `0x0001 exactIn`, `0x0010 strict`, `0x0080 AToB`, `0x0100 partial`; then 32-byte threshold, optional 5-byte deadline, then signature. |
| 1.4 | Fork parity | On a fork, `router.quote(order, amount, takerData)` on an order built here returns the same `(amountIn, amountOut)` as an order built with the upstream `MakerTraitsLib.build` / `TakerTraitsLib.build` helpers in a 0.8.30 test harness. |
| 1.5 | `sortTokens` | Returns `(min, max, first < second)` for both orderings and equal-ish edge (adjacent addresses). |

## 2. `WeirV2BondingCurve` — partitions and trading gate

| # | Case | Assert |
|---|---|---|
| 2.1 | `initialize(token)` unchanged | `committedTokens == 0`, `tradingOpensAt == 0`, `trackedTokens == totalSupply`, `reservedTokens` as before. Existing tests keep passing. |
| 2.2 | `initialize(token, committed, opensAt)` | `trackedTokens == supply − committed`, `committedTokens == committed`, `reservedTokens == (supply − committed) × phantom / (phantom + threshold)`, `launchedAt == opensAt`. |
| 2.3 | Committed ≥ supply | Reverts `CommittedTokensTooLarge`. |
| 2.4 | Committed leaves reserved zero | Reverts `InvalidLaunchEconomics`. |
| 2.5 | Buy before open | Reverts `TradingNotOpen(opensAt)`; succeeds at `opensAt`. |
| 2.6 | Sell before open | Reverts `TradingNotOpen`. |
| 2.7 | Snipe tax before open | `currentSnipeTaxBps` returns `snipeTaxStartBps`, no underflow; decays from `opensAt`, not from deployment. |
| 2.8 | Tranche untouchable | Buying the whole public partition graduates the curve while the tranche is still on the curve; `sellableTokens()` never includes it; `getReserves()` token side never includes it. |
| 2.9 | Graduation price unchanged | With and without a tranche, `realQuoteReserve()` at `readyToGraduate()` equals `graduationThreshold` (± fee rounding). |
| 2.10 | `releaseCommittedTokens` access | Reverts `NotFactory` from non-factory; reverts `NotReadyToGraduate` before threshold; reverts `AlreadyGraduated` after; reverts `ZeroAddress` on zero recipient. |
| 2.11 | `releaseCommittedTokens` effect | Transfers exactly `committedTokens` to `to`, zeroes the field, emits `CommittedTokensReleased`; second call returns 0 and transfers nothing. |
| 2.12 | Internal buyback never eats tranche | `sweepFees` buyback is bounded by `sellableTokens()` and cannot lock tranche tokens. |

## 3. `WeirV2CommitmentRegistry`

### 3.1 `openCampaign`

| # | Case | Assert |
|---|---|---|
| 3.1.1 | Only factory | `NotFactory` otherwise. |
| 3.1.2 | Native quote | `NativeQuoteUnsupported` when `quoteToken == address(0)`. |
| 3.1.3 | Discount bounds | `InvalidDiscount` below 2000 and above 4000; 2000 and 4000 accepted. |
| 3.1.4 | Oversubscription bounds | `0 → 14000` default; `< 10000` or `> 20000` reverts `InvalidOversubscription`. |
| 3.1.5 | 24h floor | `CampaignTooShort` when `tradingOpensAt < now + 24h`; exactly `now + 24h` accepted. |
| 3.1.6 | Derived tranche | `committedTokens == Q × supply × 1e4 / (phantom × (1e4 − d))` for a table of `(Q, d, phantom, supply)`; `TrancheTooLarge` above 50% of supply; `ZeroAmount` when it rounds to 0. |
| 3.1.7 | Double open | `CampaignExists`. |
| 3.1.8 | Stored fields | `maxPledged`, `closesAt`, `orderDeadline == closesAt + 30d`, `nonceBit == uint32(keccak(registry, token))`, event emitted. |

### 3.2 `commit`

| # | Case | Assert |
|---|---|---|
| 3.2.1 | Happy path (signature) | Bond of 20% pulled; `pledge`, `bond`, `signature` stored; backer appended; `totalPledged`, `totalBonded`, `outstandingPledge` updated; `Committed` emitted with the router's hash. |
| 3.2.2 | Happy path (Aqua) | Empty signature accepted; order traits bit 254 set in `previewCommitmentOrder`. |
| 3.2.3 | Bad signature | `InvalidSignature` for a wrong signer or wrong pledge amount (hash mismatch). |
| 3.2.4 | EIP-1271 backer | A contract wallet returning the magic value can commit. |
| 3.2.5 | Closed campaign | `CampaignClosed` at/after `closesAt`; `CampaignNotOpen` for unknown token or settled/expired campaign. |
| 3.2.6 | Duplicate backer | `AlreadyCommitted`. |
| 3.2.7 | Over-subscription ceiling | Pledges up to `1.4 × Q` accepted; the one crossing it reverts `OverSubscribed`. |
| 3.2.8 | Cap on count | 65th backer reverts `TooManyCommitments`. |
| 3.2.9 | Allowlist | Whitelisted campaign: valid proof passes, invalid/empty proof reverts `NotAllowlisted`; open campaign ignores proof. |
| 3.2.10 | Exposure cap, single campaign | Wallet with `1.2 × pledge − 1` reverts `ExposureCapExceeded(balance, required)`; exactly `1.2 × pledge` passes. |
| 3.2.11 | Exposure cap, across campaigns | Alice with 100 pledges 80 to campaign A (needs 96); pledging 80 to campaign B requires `80 + 80 + 16 = 176` and reverts; after A settles/expires it passes. |
| 3.2.12 | Fee-on-transfer bond token | Received ≠ bond reverts. |
| 3.2.13 | Zero pledge / dust pledge | `ZeroAmount` when pledge is 0 or bond rounds to 0. |

### 3.3 `settle`

| # | Case | Assert |
|---|---|---|
| 3.3.1 | Only factory, tranche present | `NotFactory`; `TrancheNotReceived(expected, held)` if tokens not released first; `CampaignNotClosed` before `closesAt`; `CampaignClosed` if already settled. |
| 3.3.2 | All honour (mock router) | Every backer `Filled`; `settledQuote == Q`; `deliveredTokens == committedTokens`; `burnedTokens == 0`; token `totalSupply` unchanged; factory receives `Q`; `outstandingPledge == 0` for all. |
| 3.3.3 | All defect | Every backer `Defected`; `forfeitedBonds == totalBonded`; `burnedTokens == committedTokens` and `totalSupply` decreased by it; factory receives exactly `forfeitedBonds` (bonds-to-pool rule); `deliveredTokens == 0`. |
| 3.3.4 | Partial (6 of 10) | Delivered `= 0.6 × tranche`, burned `= 0.4 × tranche`, forfeited `= 4 bonds`, factory receives `0.6 × Q` only (bonds stay for fillers). |
| 3.3.5 | Over-subscribed, defectors skipped | 14 pledges of `0.1 Q`; backers 3 and 7 defect; first 12 non-defectors fill `Q` exactly; remaining honest backers `Unfilled` with bond refundable; defectors forfeited. |
| 3.3.6 | Last fill is partial | Remaining `Q` < pledge: `fillTokens` and `expectedQuote` scale pro rata (floor), backer `Filled` with `filledQuote == expectedQuote`. |
| 3.3.7 | Router success but wrong delta | Mock returns success without pulling quote → treated as `Defected` (delta check). |
| 3.3.8 | Approval hygiene | Router allowance for the token is 0 after settle. |
| 3.3.9 | Expired then graduated | `expire()` first, then `settle`: no router calls, whole tranche burned, `quoteForwarded == 0`, all `Unfilled`. |
| 3.3.10 | Past `orderDeadline` without `expire` | Same as 3.3.9 through the `block.timestamp > orderDeadline` branch. |
| 3.3.11 | Gas bound | 64 backers settle within the block gas limit on the mock router; record gas for the fork router. |
| 3.3.12 | Reentrancy | A malicious quote token re-entering `settle`/`claimBond` during a fill is blocked by `nonReentrant`. |

### 3.4 `claimBond` / `expire`

| # | Case | Assert |
|---|---|---|
| 3.4.1 | Filled backer | Receives bond + `forfeitedBonds × filledQuote / settledQuote`; sum over fillers ≤ `forfeitedBonds` (rounding dust stays). |
| 3.4.2 | Unfilled backer | Receives exactly bond. |
| 3.4.3 | Defector | `NothingToClaim`. |
| 3.4.4 | Double claim / never committed / before settlement | `NothingToClaim` / `NothingToClaim` / `CampaignNotClosed`. |
| 3.4.5 | Conservation | After every claim, `Σ claimed + bondsToPool == totalBonded` (dust aside). |
| 3.4.6 | `expire` timing | `CampaignNotExpired` at `orderDeadline`; succeeds one second later; `CampaignNotOpen` on second call; clears `outstandingPledge` for every pending backer. |

### 3.5 Views

| # | Case | Assert |
|---|---|---|
| 3.5.1 | `allocationFor` linearity | `allocationFor(2p) == 2 × allocationFor(p)` (floor aside); equals `pledge / (P₀ × (1 − d))`. |
| 3.5.2 | `previewCommitmentOrder` determinism | Same inputs → identical bytes and hash; hash equals what `commit` emitted. |
| 3.5.3 | Sorted-token symmetry | Campaigns where `token < quote` and `token > quote` both produce `StaticBalances` with `(allocation, pledge)` on the correct sides and matching `LimitSwap` direction; fork fill succeeds for both. |

## 4. `WeirV2LaunchFactory` — campaign launch and graduation

| # | Case | Assert |
|---|---|---|
| 4.1 | `setCommitmentRegistry` | Once only (`AlreadySet`), non-zero, `CommitmentRegistryMismatch` when `registry.factory() != factory`. |
| 4.2 | `launchTokenWithCampaign` without registry | `CommitmentRegistryNotSet`. |
| 4.3 | `launchTokenWithCampaign` zero target | `InvalidTokenParams`. |
| 4.4 | Campaign launch wiring | Registry has the campaign keyed by token; curve `committedTokens` equals registry's; `tradingOpensAt` matches; snipe exemptions applied; `TokenLaunched` emitted. |
| 4.5 | Plain `launchToken` unaffected | No registry call, `committedTokens == 0`, trading open immediately. |
| 4.6 | Economics digest | `previewLaunchEconomics` changes when the hook's `stakerFeeShareBps` changes; a pinned `expectedEconomics` from before the change reverts `LaunchEconomicsMismatch`. |
| 4.7 | `graduate` with campaign | Order of events: `CommittedTokensReleased` → registry fills/burns → `CommitmentsSettled(settledQuote)` → `LaunchSwept`; `sweptQuote == curve quote + settledQuote`; phase `Swept`. |
| 4.8 | `graduate` without campaign | No registry interaction; behaviour identical to before. |
| 4.9 | Preflight refusal reverts settlement | Force the guard to refuse; assert no tokens burned, no bonds forfeited, campaign still `Open`. |
| 4.10 | Auto-graduation via crossing buy | The buy that exhausts the public partition triggers settlement atomically; if the registry reverts structurally, the buy still succeeds and `AutoGraduationFailed` is emitted; a direct `graduate` then surfaces the revert. |
| 4.11 | `forceSweptGraduation` with campaign | Settles and burns before sweeping. |
| 4.12 | Seed price with settled quote | `createGraduatedPool` initialises at `sqrtPrice` derived from `(curveQuote + settledQuote)`; pool price higher than the no-campaign baseline; excess tokens locked in the locker. |
| 4.13 | Dependencies wired | `_requireLaunchDependenciesWired` reverts `LaunchDependenciesNotWired` when the hook has no `stakingVaultDeployer`. |

## 5. `WeirV2MemeHook` — frozen staker share, vault deployer, compound router

| # | Case | Assert |
|---|---|---|
| 5.1 | Snapshot | `registerPool` stores `policy.stakerFeeShareBps` in `LaunchInfo`; rejects `> 5000` with `InvalidBps`. |
| 5.2 | Owner cannot reprice | Change global `setStakerFeeShareBps` after registration; a sweep still uses the frozen share (compare vault `notifyReward` amount). |
| 5.3 | `currentFeePolicy` | Includes `stakerFeeShareBps`. |
| 5.4 | `setStakingVaultDeployer` | Once only, non-zero, `StakingVaultDeployerMismatch` when `deployer.hook() != hook`. |
| 5.5 | `registerPool` without deployer | `StakingVaultDeployerNotSet`. |
| 5.6 | Vault via deployer | Vault's `hook()` is the hook (not the deployer); `stakeToken`, `quoteToken`, `feeEscrow` correct; `deployVault` from a non-hook caller reverts `NotHook`. |
| 5.7 | Compound router propagation | With `setCompoundRouter` set before registration the new vault has `swapVM`/`weth`; without it the vault's `swapVM == 0` and `configureStakingVaultCompounding` wires it later; a second configure reverts `CompoundRouterAlreadySet`. |
| 5.8 | Size | Optimized runtime of the hook < 24,576 bytes (`forge build --sizes --optimize`). |

## 6. `WeirV2StakingReward` — auto-compound

| # | Case | Assert |
|---|---|---|
| 6.1 | `setCompoundRouter` | Only hook; once; native-quote vault with `weth == 0` reverts `ZeroAddress`. |
| 6.2 | Opt-in without router | `CompoundNotConfigured`. |
| 6.3 | Opt-in settles old mode | Reward accrued before `setAutoCompound(true)` is paid to the escrow, not held. |
| 6.4 | Accrual while opted in | After `notifyReward`, `harvest` moves reward to `compoundable`, escrow untouched, `RewardHeldForCompound` emitted, `pendingReward` returns 0. |
| 6.5 | Opt-out pays held balance | `setAutoCompound(false)` credits `compoundable` to escrow and zeroes it. |
| 6.6 | `compound` authorisation | Staker OK; fee-sweep operator OK; random caller `NotCompoundOperator`; opted-out account `AutoCompoundDisabled`. |
| 6.7 | Nothing to compound | `NothingToCompound` when `compoundable == 0` after settle. |
| 6.8 | Pair validation | Order with wrong tokens (or `data.length < 40`) reverts `OrderTokenMismatch`; for a native-quote vault the pair must be `(WETH, memecoin)`. |
| 6.9 | ERC-20 quote fill (mock router) | Router pulls `budget`, pushes tokens; `users[a].amount` and `totalStaked` grow by tokens bought; `compoundable == 0`; allowance reset to 0; `Compounded` emitted; `rewardDebt` rebased so `pendingReward == 0` right after. |
| 6.10 | Native quote fill | `swap{value: budget}`; router refunds unspent; `quoteSpent` measured by ETH delta; vault balance conserved. |
| 6.11 | Partial fill | Router fills half: `compoundable == budget / 2` remains; tokens credited for the half. |
| 6.12 | Unlock timer untouched | `unlockTime` before == after `compound`; `unstake` timing unaffected. |
| 6.13 | Guards | Router returns tokens elsewhere → `CompoundBoughtNothing`; router pulls more than budget → `CompoundOverspent` (mock with over-pull). |
| 6.14 | Accounting isolation | Held `compoundable` balances do not change `accRewardPerShare` for other stakers; a second staker's reward is unaffected by the first one's compound. |
| 6.15 | Existing behaviour | Every pre-existing staking test still passes (stake/unstake/harvest/burnAndExit/notifyReward, ERC-20 and native). |
| 6.16 | Fork: real router | Against the official router with a maker's `StaticBalances · LimitSwap` order selling the memecoin for USDC: `compound` fills and restakes; against an Aqua-shipped XYC strategy: same. |

## 7. `WeirV2FutarchyProposal` (regression only)

Existing suite covers deploy, bond, resolution and the factory-only wiring. Add:

| # | Case | Assert |
|---|---|---|
| 7.1 | Early exit after compounding | A staker who compounded can `burnAndExit` the full (grown) stake once PASS resolves. |
| 7.2 | Proposal on a vault created via the deployer | `createFutarchyProposal` works with the deployer-created vault (hook validates `vault()` match). |

## 8. End-to-end demo runs (fork, official router) — `Idea2 §11`

These three are the judge-facing scenarios. Same launch config, same public trading script, three campaign states.

| Run | Setup | Assert / show |
|---|---|---|
| **A. Flag off** | `launchToken` (no campaign). Public buys to threshold. | Baseline pool price `P_A`, supply `S`. Mechanism inert. |
| **B. All honour** | `launchTokenWithCampaign(d=30%, Q, 24h)`; 10 backers commit via signed LimitSwap orders on the real router; warp to open; same public buys; graduate. | 10 `CommitmentFilled` events; `totalSupply == S`; all bonds returned; pool seeded with `threshold + Q`; pool price `P_B > P_A`. |
| **C. Partial defection** | As B, but 4 backers move their USDC (or revoke allowance) before graduation. | 6 `CommitmentFilled`, 4 `CommitmentDefected`; `burnedTokens == 0.4 × tranche` and `totalSupply == S − burned`; `forfeitedBonds == 4 bonds`, claimable by the 6 fillers; pool price `P_C > P_A`; defectors' `claimBond` reverts. |

Also record on the fork: `settle` gas for 10 and 64 backers; `compound` gas for a limit order and an XYC order.

## 9. Invariant / fuzz targets

- **Curve:** for random buy/sell sequences with a tranche, `trackedTokens + committedTokens + Σ tokens sold − Σ tokens bought back == initial balance` and `sellableTokens()` never draws on `committedTokens`.
- **Registry:** for random honour/defect patterns and pledge sizes (including over-subscription), `deliveredTokens + burnedTokens == committedTokens`, `quoteForwarded == settledQuote + (settledQuote == 0 ? forfeitedBonds : 0)`, and `Σ claims + bondsToPool == totalBonded`.
- **Vault:** for random stake/notify/compound/harvest interleavings across several stakers, no staker can extract more quote (paid + held + spent) than the accumulator credited them, and `totalStaked == Σ users[i].amount`.
