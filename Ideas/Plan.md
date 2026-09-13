# Plan: campaign setup for commitments + auto-compound

How a creator actually configures and starts these two mechanisms. Idea1 and Idea2 describe *what* they do; this is *how a launch turns them on*.

See [Idea1.md](./Idea1.md) (auto-compound) and [Idea2.md](./Idea2.md) (bonded commitments).

---

## The asymmetry to get straight first

The two mechanisms are not parallel, but they are not fully independent either. Both need something decided before launch; they differ in *what* and in *who decides*.

| | Commitments (Idea2) | Auto-compound (Idea1) |
|---|---|---|
| Needs a campaign? | **Yes** — a configured, time-boxed pre-launch round | **No** — no round, no deadline, no access list |
| Needs pre-launch confirmation? | Yes — access, discount, tranche | **Yes** — LP fee level and split (§3a) |
| Who configures it | Creator, before launch | Creator confirms the split; each staker opts in individually |
| When it runs | Before and during bonding | After graduation, indefinitely |
| Timing constraint | Must open **≥ 24h before** the coin launches | Inherits the same 24h floor via the campaign |

Commitments are an *event* with a start button and a deadline. Auto-compound is a *setting* — but the setting only means anything if the fee level and split feeding it were fixed at launch, which is what §3a adds.

---

## 1. Commitment campaign configuration

A creator opening a commitment round sets these before the token launches. All of it is per-launch, immutable once the campaign opens (otherwise a creator could reprice mid-round against committed backers).

### 1a. Access mode

| Mode | Who can commit | Use case |
|---|---|---|
| **Open** | Anyone, first-come by signature order | Fair-launch story; relies on the aggregate concurrency cap to stop bots hoovering the tranche |
| **Whitelisted** | Addresses on the creator's allowlist (or merkle root) | Community rounds, existing holders, partner allocations |

Whitelisting composes from stock SwapVM access guards in bank `0x20-0x3f` (`PrivateOrder`, `WhitelistCoequal`, `WhitelistSequential`) — no new opcode.

In **open** mode, the concurrency cap is doing the anti-bot work, not the access list. A bot spraying commitments across every live launch hits its aggregate bondable-capital limit quickly. Without that cap, open mode is exactly what a bot wants.

### 1b. Tranche size and price — derive, don't assert

This is the part that must not be set by picking two numbers and dividing. Order of operations:

**Step 1 — pick the discount `d`.** What backers are paid for committing capital against an unknown outcome. Target range **20–40%**.

**Step 2 — read `P₀` off the curve.** The price the first public buyer pays, already determined by the launch's `phantomQuote` and `graduationThreshold`. Not a free parameter.

**Step 3 — derive the committer price:**

```
committer price = P₀ × (1 − d)
```

**Step 4 — decide how much capital the launch actually needs committed.** Call it `Q`.

**Step 5 — tranche size falls out:**

```
committedTokens = Q / (P₀ × (1 − d))
```

Tranche size is an *output*, not an input. Setting the tranche first and backing into a price is how you end up at a 90% discount by accident.

**Bound to check before opening:** `bond% ≥ d`, and with concurrency, `bond% × max concurrent commitments ≥ d`. At a hardcoded 20% bond (§2), this caps the defensible discount — a 20% bond supports roughly a 20% discount per commitment slot. Pushing `d` to 40% requires the aggregate cap to be doing real work. **A 90% discount cannot be bonded at 20% at all**; the arithmetic doesn't close.

### 1c. Over-subscription target

Because commitments are soft, accept more pledges than the tranche needs:

```
accept up to ~1.4 × Q, fill in signature order until Q is met
```

Turns a few defectors from a cliff into noise. Standard underwriting.

### 1d. Campaign window

| Field | Notes |
|---|---|
| Opens at | Creator-set |
| Closes at | Token launch (curve goes live) |
| Minimum duration | **24h** (see §3) |
| Settlement window | Slightly wider than the commitment window, so an honest backer with a pending tx or temporarily-moved USDC can cure before being slashed |

That last row matters. Slashing someone for a network hiccup is both unfair and the kind of thing a judge pokes at.

### 1e. Config summary

| Field | Set by | Immutable after open? |
|---|---|---|
| Access mode (open / whitelist) | Creator | Yes |
| Allowlist / merkle root | Creator | Yes |
| Discount `d` | Creator | Yes |
| Target quote `Q` | Creator | Yes |
| `committedTokens` | **Derived** from `d`, `P₀`, `Q` | Yes |
| Over-subscription ceiling | Creator (default 1.4×) | Yes |
| Bond percentage | **Hardcoded 20%** — not creator-settable | N/A |
| Campaign open / close | Creator, ≥24h span | Close may not move earlier |

---

## 2. The 20% bond is hardcoded

**Not a creator parameter. Not a governance parameter. A protocol constant.**

```solidity
uint256 public constant COMMITMENT_BOND_BPS = 2000; // 20%, not configurable
```

### Why it cannot be creator-settable

A creator competing for backers in a one-hour launch window has every incentive to undercut on bond. "Commit to my launch, only 5% bond" attracts more pledges than a 20% neighbour. The race goes to zero, and at a 0% bond the commitment is a pure free option — exactly the failure mode the bond exists to close.

Worse, the creator isn't the one harmed by a low bond. **The public buyers are**, because they're the ones trading against a threshold that includes pledged capital. Letting creators set the number lets them sell someone else's protection.

So the bond is fixed protocol-wide. A creator who wants more committed interest competes on discount, which is *their* cost to bear, not on bond, which is the public's.

### What stays fixed vs. what flexes

| Parameter | Who sets it | Why |
|---|---|---|
| Bond % | **Protocol, hardcoded at 20%** | Race-to-zero; creators would externalize the cost onto public buyers |
| Discount `d` | Creator | It's the creator's own dilution — their cost, their call |
| Tranche size | Derived | Follows from `d`, `P₀`, `Q` |

### The consequence to accept

Hardcoding at 20% means the protocol has taken a position: **commitments are soft, and defection is priced, not prevented.** A creator who needs a hard guarantee cannot get one here. That's the honest tradeoff from Idea2 §3, and it should be stated on the campaign screen rather than buried.

It also means the aggregate concurrency cap is not optional. At a fixed 20%, the cap is the only remaining defence against the multi-pool free option (Idea2 §8). Bond and cap ship together or neither works.

---

## 3. Auto-compound: no campaign, but a pre-launch fee confirmation and a 24h floor

Auto-compound needs **no separate campaign** — no round, no deadline, no access list. A staker toggles it on their own position in a live vault and it applies to their accrued rewards from then on.

```
stake → toggle auto-compound → fees arrive → compound(alice) → restaked
```

Default is **off** (manual harvest). Opt-in, per staker, reversible at any time.

**But it does need one pre-launch decision:** how much LP fee the pool charges, and how that fee splits. Auto-compound buys `stakeToken` with the staker's slice of swept fees — so if the fee level or the staker share isn't fixed before launch, the yield the mechanism compounds is undefined at the moment stakers commit to it. That's §3a.

### 3a. LP fee level and split — confirm before launch

**What the code does today** (`src/hooks/WeirV2MemeHook.sol`), because this is the part that needs changing:

| Parameter | Default | Set by | Per-pool frozen? |
|---|---|---|---|
| `hookFeeBps` | 100 (1%) | `setHookFeeBps`, `onlyOwner` | **Yes** — snapshot into `LaunchInfo` at `registerPool` |
| `protocolFeeShareBps` | — | `setProtocolFeeShareBps`, `onlyOwner` | **Yes** — `_distribute` reads `info.protocolFeeShareBps` |
| `buybackBurnBps` | 5000 (50%) | `setBuybackBurnBps`, `onlyOwner` | **Yes** — snapshot, and earmarked per swap at accrual |
| `creatorTaxBps` | per-pool | factory at `registerPool` | Yes |
| **`stakerFeeShareBps`** | **4000 (40%)** | `setStakerFeeShareBps`, `onlyOwner` | **No — read live at every sweep** |

That last row is the problem. `_distribute` computes the staker slice off the *current* global, and the code says so in its own comment: *"Staker share is computed live off the current policy (unlike the buyback earmark, which is fixed per swap as it accrues)."*

Two consequences:

1. **The owner can change every pool's staker share at any time**, including retroactively over fees already accrued but not yet swept. A staker who opted into auto-compound on a 40% staker share can find it at 10% before the next sweep.
2. **None of these are creator parameters.** They're protocol globals. A creator today cannot offer "this launch pays stakers 50%" — they get whatever the global says at sweep time.

**What this plan requires:**

- **Snapshot `stakerFeeShareBps` per pool at `registerPool`**, the way `protocolFeeShareBps` and `buybackBurnBps` already are. `_distribute` then reads `info.stakerFeeShareBps`. This is the one contract change auto-compound genuinely needs.
- **Show the resulting split on the pre-launch screen** and freeze it with the launch, so a staker opting in knows what they're compounding.

### The split a staker actually sees

Order of operations in `_distribute`, which matters because each leg carves out of what's left:

```
total swept fee (hookFeeBps of swap volume)
  ├── protocol      = total × protocolFeeShareBps
  └── creator bucket = total − protocol
        ├── stakers  = bucket × stakerFeeShareBps   ← auto-compound's input
        ├── buyback  = per-swap earmark, clamped to bucket
        └── creator  = remainder + creatorTax
```

Worked example at defaults — 1% pool fee, 10,000 USDC of swap volume, 20% protocol share, 40% staker share:

| Leg | Amount |
|---|---|
| Total fee (1% of 10,000) | 100 USDC |
| Protocol (20% of 100) | 20 USDC |
| Creator bucket | 80 USDC |
| **Stakers (40% of 80)** | **32 USDC** ← what auto-compound buys with |
| Buyback + creator | 48 USDC |

So the headline number for a staker is not `hookFeeBps` and not `stakerFeeShareBps` — it's the product of the chain. A 1% fee with a 40% staker share on an 80% bucket pays stakers **0.32% of swap volume**. That's the figure the pre-launch screen should display, because it's the one that determines whether compounding is worth the gas.

**Two existing behaviours to keep in mind, neither of which needs changing:**

- **No vault, or nobody staked → the slice stays with the creator.** `_fundStakingVault` returns what it actually funded and `creatorBucket` is reduced by that, so an unstaked pool doesn't strand the slice. Auto-compound on an empty vault is a no-op, not a revert.
- **The buyback earmark is fixed per swap at accrual**, so toggling `buybackEnabled` only affects future swaps. The staker share, by contrast, is currently live — which is exactly the inconsistency §3a fixes.

### The one timing rule

**The backing campaign must run at least 24 hours before the coin launches.**

This is a constraint on the *commitment* campaign (§1d), not on auto-compound — but it's recorded here because it's the rule that binds the two mechanisms into one timeline. Auto-compound only has fees to compound after graduation, and graduation only happens after a curve that opened after the campaign closed.

Why 24h rather than "whenever":

- **A one-hour bonding game needs its audience assembled beforehand.** If the commitment window and the curve run concurrently, backers are deciding under the same time pressure as curve traders, which is the opposite of what a considered pre-launch commitment is for.
- **Bond capital needs time to arrive.** A backer has to actually post 20% before the curve opens. An hour isn't enough for anyone not already watching.
- **It's the signal the curve trades against.** If the tranche counts toward the graduation threshold (Idea2 §7 — still open), public buyers need the committed interest to be *settled as visible* before they price the curve, not discovered mid-flight.

### Full timeline

```
T−24h+   commitment campaign opens
         backers sign pledges + post 20% bonds
            │
T−0      campaign closes, curve goes live
         ~1 hour bonding game, public trades the sellable partition
            │
T+~1h    readyToGraduate() → settle commitments
         → burn unsettled tranche, retain forfeited bonds
         → seed v4 pool → graduated = true
            │
T+1h…    staking vault live; hook sweeps fees
         stakers individually toggle auto-compound
         compound() buys stakeToken via stock LimitSwap/TWAP, restakes
```

Note what that ordering forces: settlement, burn, and seeding all sit inside the graduation transaction, which is why settlement cannot live behind the `try` block at `WeirV2BondingCurve.sol:649` (Idea2 §7).

---

## 4. What a creator actually fills in

Practical summary, one launch:

**Required — commitment campaign**
- Access mode: open or whitelisted (+ allowlist if whitelisted)
- Discount `d` (20–40%)
- Target committed quote `Q`
- Campaign open time (≥24h before launch)

**Required — fee confirmation (feeds auto-compound)**
- Confirm `hookFeeBps` (pool fee level)
- Confirm the split: protocol / staker / buyback / creator
- Acknowledge the frozen staker share, snapshotted at `registerPool`

**Derived, shown back for confirmation**
- Committer price = `P₀ × (1 − d)`
- `committedTokens` = `Q / committer price`
- Over-subscription ceiling = `1.4 × Q`
- Revised `sellableTokens()` = `trackedTokens − reservedTokens − committedTokens`
- **Effective staker yield = `hookFeeBps × (1 − protocolShare) × stakerShare`**, shown as a % of swap volume (0.32% at defaults)

**Fixed, displayed as non-editable**
- Bond: 20%
- Unsettled tranche is burned
- Forfeited bonds stay as pool quote

**Not on this screen**
- The auto-compound toggle itself. That's staker-side, per position, after graduation — the creator confirms the *fee split* it draws from, not whether anyone uses it.

---

## 5. Open items this plan inherits

Unchanged from Idea2 §13, and all four gate the build:

1. **Pick `d`** for the reference launch, then derive tranche and price off the real `phantomQuote` / `graduationThreshold`.
2. **Aggregate concurrency cap** — mandatory once the bond is hardcoded at 20% (§2), not a nice-to-have.
3. **Does the commitment tranche count toward the graduation threshold?** It cannot count *and* be unsettled.
4. **`try` block at `WeirV2BondingCurve.sol:649`** — settlement cannot sit behind a call designed to fail silently.
5. **Snapshot `stakerFeeShareBps` per pool** (§3a). Today it's read live in `_distribute`, so the owner can change every pool's staker share retroactively over unswept fees. Auto-compound needs it frozen at `registerPool` like the other legs already are.
6. **Should creators set the split at all, or only confirm it?** Letting creators raise the staker share is a real product option (it competes for stakers), but it's the same race-to-the-bottom shape as §2's bond argument pointed the other way — worth deciding deliberately rather than by default.
</content>
