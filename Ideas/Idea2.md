# Idea 2: Bonded zero-custody commitments (Aqua + SwapVM LimitSwap)

> [!NOTE]
> **Two phases**
> - **During bonding (~1 hour):** backers sign conditional commitments. Committed USDC stays in their own wallets. A commitment tranche is fenced off from the public curve.
> - **At graduation:** commitments settle through stock SwapVM `LimitSwap`. Whatever fails to settle is burned, and the defector's bond stays in the pool as unbacked quote.

> [!IMPORTANT]
> **No SwapVM opcode changes.**
> Official 1inch SwapVM / Aqua with existing instructions (`LimitSwap`, min-rate, Aqua balance mode). Commitment fencing, bonding, and burning live in Weir contracts.

## Sources
- `src/WeirV2BondingCurve.sol` — bonding curve, `reservedTokens`, `readyToGraduate()`
- `src/WeirV2LaunchFactory.sol` — `_sweepCurve`, graduation sequencing
- `src/WeirV2LauncherToken.sol` — `ERC20Burnable`
- `src/WeirV2BuybackVault.sol` — forfeited-bond sink
- `deps/swap-vm` — official 1inch SwapVM
- `scope_of_work/1inch.md`, `scope_of_work/Uniswap.md`

---

## 1. The problem

A memecoin launch is roughly a one-hour bonding game. Two things are broken at the start of it.

**For backers:** a conventional presale means sending USDC into a stranger's escrow contract. If the launch rugs or never graduates, the money is stuck or refunds cost gas. So cautious capital stays out, and the people who do show up are the ones who can afford to lose it.

**For creators:** the alternative — no presale at all — means the curve opens with zero committed interest and competes for attention against every other launch that hour.

There is a third problem that only appears once you try to fix the first two. If commitments are *soft* (just a signature, funds stay home), a backer can walk away at settlement time for free. And the moment they can walk for free, the launch cannot rely on the commitment at all.

---

## 2. What this is

Backers pledge USDC that **never leaves their wallet**, and post a **20% bond** that does. If the launch graduates and they honour the pledge, they get tokens at a fixed pre-launch price and the bond back. If they walk, they lose the bond and get nothing.

The four parts:

1. **Commit with a 20% bond.** Pledge is a signature (Aqua / EIP-712). The bond is real escrowed USDC, and it is the only custody in the design.
2. **Unsettled tranche is burned, forfeited bond stays as quote.** A defector's tokens are destroyed, not resold. Their bond becomes quote backing everyone else's tokens.
3. **Defection is not free, and not filling is not a discount.** The bond is lost in full. No partial delivery.
4. **Open or whitelisted.** Per-launch flag.

### One-liner

Zero-custody pledges backed by a 20% bond; at graduation, stock SwapVM `LimitSwap` settles what honours, and Weir burns what doesn't.

---

## 3. Why the bond has to exist

This is the part worth understanding before the numbers, because it is the reason the design is shaped this way.

Aqua's model is that a commitment is a *signature*, not a transfer. It is a conditional authorization to pull, checked at fill time against what the wallet actually holds right then. That is what "your funds stay in your wallet" means, and it is the whole point of the track.

It also means the backer can always defeat it. Move the USDC and the fill fails. Revoke the allowance and the fill fails. There is no cryptographic way to make a signature irrevocable while leaving the funds spendable — those two properties are mutually exclusive.

So: **"they can't back out" and "funds stay in their wallet" cannot both be true.** Full escrow buys irrevocability and throws away the entire Aqua premise (and would make this a 2017 presale contract with a swap bolted on the end). A pure signature keeps the premise and gives the creator nothing to rely on.

The bond is the way out. 80%+ of the capital stays in the wallet and settles as a genuine wallet-bounded SwapVM fill, so the Aqua claim survives intact. The 20% bond prices defection rather than preventing it.

**Honest framing:** this is a better presale *for the backer*, not a guaranteed raise *for the creator*. Backers can still walk. They just pay for it.

### Why ~1 hour makes 20% workable

Bond cost scales with lock duration. Locking 20% for a week is real capital cost and backers price it in. Locking 20% for an hour is nearly free for anyone who intended to participate — but expensive for someone spraying commitments across fifty launches with no intent to fill.

Short windows make bonds cheap for honest actors and expensive for spammers. That asymmetry is what lets the bond stay small enough not to deter real use.

---

## 4. Three token partitions (naming matters)

`WeirV2BondingCurve` **already** has a field called `reservedTokens`, and it is *not* the commitment tranche. Conflating them will produce wrong code.

| Partition | Name | Set by | Purpose |
|---|---|---|---|
| Pool seed | `reservedTokens` (existing) | `initialize()`, line 263: `supply × phantomQuote / (phantomQuote + graduationThreshold)` | Seeds the v4 pool at graduation. Never sold on the curve. |
| Commitment tranche | `committedTokens` (new) | Launch config | Fenced off for committers. Public buys cannot touch it. |
| Public curve | remainder | derived | Open trading. |

`sellableTokens()` is currently `trackedTokens - reservedTokens`. It becomes:

```
sellableTokens() = trackedTokens - reservedTokens - committedTokens
```

The token mints its full supply to the curve in its own constructor, so all three partitions are accounting views over one balance the curve already holds. No extra minting.

---

## 5. Pricing: derive the discount, don't assert the price

The committer price is **not** picked by dividing a pledge by a tranche. That is asserting two numbers and reporting their quotient. Price it off the curve.

Backers take one real risk: capital is committed while the outcome is unknown. The discount pays for that risk.

```
committer price = P₀ × (1 − d)
```

where `P₀` is what the first public buyer pays (already determined by `phantomQuote` and `graduationThreshold`) and `d` is the discount.

**`d` in the 20–40% range.** Meaningful to backers, and small enough that a graduating launch doesn't hand them a windfall the public funded.

### Why a 90% discount cannot work here

The bond has to be at least as large as the profit the discount hands you, or a bad actor commits, waits to see which way the launch is going, and takes whichever side pays:

```
bond ≥ d × pledge
```

At `d = 30%`, a ~20–30% bond is in the right range and ~70–80% of capital stays in the wallet. At `d = 90%` the bond would need to be 90% of the pledge — at which point you have escrowed almost everything and the zero-custody property is dead.

**Deep discounts and zero custody are arithmetically incompatible.** That is the constraint, not a fairness opinion. Pick `d` first; tranche size and bond follow.

### Discount and bond answer different questions

If memecoins reliably get no volume post-graduation, that is a reason the **discount** can be generous — backers are being paid for a risk that is mostly real. It is *not* a reason the bond can be small. The discount prices launch risk; the bond prices defection. Conflating them gives you a mechanism that is generous to backers and unreliable for creators at once.

---

## 6. Failure path: burn the unsettled tranche

Worked example, using round numbers.

**Setup:** 10 backers, 1,000 USDC pledged total, 100M token commitment tranche. Seed price = 1,000 / 100M = **0.00001 USDC per token**. Each backer posts a 20% bond, so 200 USDC is escrowed in total.

**All 10 defect** — they move their USDC out just before settlement.

| Quantity | Value |
|---|---|
| Quote pledged | 1,000 USDC |
| Quote actually received | 0 USDC |
| Bonds forfeited | 200 USDC |
| Shortfall | 800 USDC |
| Commitment tokens delivered | **0** |
| Commitment tokens burned | **100M** |

Two things people get wrong here, both worth stating plainly:

**The shortfall is 800, not 200.** The bond *recovered* 20%; 80% is missing. The bond covers a fifth of the hole, and it was never meant to cover all of it.

**The forfeited 200 USDC does not buy tokens.** It would be tempting to deliver `100M × (200/1,000) = 20M` tokens for it. Don't. That turns defection into a discounted partial fill — the defector wanted ground-floor tokens, and abandoning the pledge would still get them a fifth of the allocation at the same price. The penalty becomes a feature.

So: **burn the whole unsettled tranche, and let the forfeited bond enter as pure quote with no tokens issued against it.**

Result for the public:
- Supply falls by the full 100M.
- 200 USDC sits in the pool backing the public's tokens.
- Defectors get no tokens and no bond back.

**Public holders gain twice** — fewer tokens outstanding, plus quote they didn't pay for. Which gives the claim worth putting in the pitch:

> A failed commitment round cannot leave public buyers worse off than no commitment round.

With the full burn, that is actually true.

### Partial defection

Same rule, pro rata. 6 of 10 honour their pledges:

| Quantity | Value |
|---|---|
| Quote received | 600 USDC |
| Tokens delivered | 60M |
| Bonds forfeited (4 × 20 USDC) | 80 USDC |
| Tokens burned | **40M** |
| Extra unbacked quote | 80 USDC |

`tokens delivered = tranche × (quote settled / quote pledged)`. Everything unsettled burns.

### Why "burn" means `burn()`, not `address(0)`

`WeirV2LauncherToken` is `ERC20Burnable`, so call `burn()` — it decrements `totalSupply`. OpenZeppelin's `_transfer` blocks transfers to `address(0)` anyway, and even where a transfer succeeds the tokens stay in `totalSupply` and every marketcap calculation keeps counting them. `WeirV2StakingReward.sol:217` already does this correctly; same call.

### Don't try to hold price and marketcap constant

Marketcap is price × supply. If 800 USDC never arrives, something has to move; pinning both would mean fabricating value nobody contributed.

The invariant to protect instead: **every circulating token is backed by quote that was actually paid.** Burning the unsettled tranche delivers exactly that, and forfeited bonds are a bonus on top.

---

## 7. Ordering is the hard requirement

Two sequencing facts, both load-bearing.

**Burn before the pool is seeded.** `_sweepCurve` moves reserves from curve to factory, then the pool is seeded from what arrived. Burning *after* seeding means pulling tokens out of live pool reserves and breaking the constant-product invariant mid-flight.

```
curve hits threshold
  → settlement attempted on all commitments
  → unsettled tranche burned, bonds forfeited
  → final supply and quote computed
  → pool seeded
  → graduation finalized
```

**Settlement cannot sit behind the existing `try` block.** `WeirV2BondingCurve.sol:649` reaches graduation via `try IWeirV2LaunchFactoryGraduation(factory).graduate(token) {}` — deliberately allowed to fail without reverting the swap. Commitment settlement must be in the graduation path proper, or "settles at graduation" is running through a call designed to swallow its own failure.

**`graduated` and `readyToGraduate()` are not interchangeable.** Once `graduated` is true, `readyToGraduate()` returns false (line 373). Use `readyToGraduate()` as the settlement trigger; `graduated` flips only after settlement and burn complete.

### The JIT defection window

The worst case is backers pulling USDC *after* the curve graduated on the strength of their pledges. The public bought into a threshold that included committed capital, and then the capital vanished.

The bond alone does not fix this. Fix it by ordering, one of:

- **Settlement as a graduation precondition** (preferred) — `readyToGraduate()` → settle → finalize on what actually settled. Defectors become non-participants, discovered before the public is exposed.
- **Exclude the commitment tranche from the threshold** — the curve graduates on public capital alone and commitments are pure upside. Simpler, but drops the "launches with progress already banked" framing.

Either way this settles the open question: **the commitment tranche cannot both count toward the threshold and be unsettled.** Pick one.

---

## 8. The concurrency hole, and the cap that closes it

This is the failure mode that survives everything above, so it needs its own fix.

**The capital-efficiency argument for 20% is good:** a bond sized to the full discount means a backer realistically commits to one launch at a time, which is an allocation desk, not a memecoin launchpad. And loss aversion is real — a visible stake at risk deters more than expected-value math suggests.

**But the same 5x multiplier that makes it attractive is the attack.** Walk it through:

Alice has 100 USDC. She commits 100 USDC to each of 5 pools — 500 USDC of pledges against 100 USDC of capital — and bonds 20 USDC per pool.

Now **two** pools graduate. She can only fill one.

The other graduating pool goes unsettled — and that pool *succeeded*. Its public buyers pushed the curve to the threshold in good faith. Alice fills the better one, forfeits ~20 USDC on the other against a 100 USDC pledge, and keeps the discount on the winner. **She is strictly better off than if she had committed honestly to one pool.**

Note who pays: not Alice, and not the failing launches. The *successful-but-unsettled* launch and its public buyers pay. That is the worst possible incidence.

The real sizing rule is therefore not `bond ≥ d`:

```
bond × (concurrent commitments a backer can carry) ≥ d
```

With unlimited concurrency the left side collapses, because the marginal bond on the abandoned pool is a rounding error against the winner's profit.

**Fix: cap aggregate exposure, not per-pool exposure.** Keep 20%. A registry tracks each address's total outstanding pledges against its bondable capital and refuses commitments beyond it. Alice keeps her 5x multiplier; what she cannot do is pledge 5,000 against 100.

Cheaper variants if the registry is too much for v1:
- **Escalating bond** — 20% for the first concurrent commitment, 25% for the second, 30% for the third. Self-limiting, no cap needed.
- **Correlated slashing** — failing to fill a graduated pool freezes or forfeits bonds on all other unsettled commitments, so over-committing becomes correlated risk instead of a free option.

Any of these keeps 20% and the multiplier. They only remove the *free* part of the free option.

---

## 9. Where forfeited bonds go

Not "to the pool" unqualified — on a failed launch that mostly pays whoever bought high on the curve, which is arbitrary. In priority order:

1. **Committers who did fill.** They took the same risk and honoured it, and absorbed the shortfall the defector created. Makes the bond mutual insurance rather than a fine.
2. **`WeirV2BuybackVault`.** Already exists; one line of integration, and it converts defection into buy pressure for remaining holders.

A split between the two is defensible.

---

## 10. Open or whitelisted

Per-launch flag, and both modes are genuinely useful:

**Open.** Anyone can commit up to the tranche, first-come by signature order. Best for a fair-launch story. The bond plus the concurrency cap is what keeps bots from hoovering the tranche — a bot spraying commitments across every launch hits the aggregate cap fast.

**Whitelisted.** Creator supplies an allowlist (or a merkle root). For community pre-sales, existing holders, or partner allocations. SwapVM already has access-guard instructions in bank `0x20-0x3f` (`PrivateOrder`, `WhitelistCoequal`, `WhitelistSequential`), so the taker-side restriction composes from stock opcodes rather than needing a new one.

**Point 3 from the brief, stated precisely:** if a backer *doesn't* commit, they buy on the open curve like anyone else — no bond, no fixed price, and they pay whatever the curve asks when they arrive. Committing is what buys the fixed pre-launch price; the bond is what pays for it. Bots and unbonded traders are not locked out of the launch, they are locked out of the *discount*. That is the whole trade: no bond, no ground floor.

### Over-subscription

Because commitments are soft, accept **more pledges than the tranche needs** — target 1,000 USDC, accept up to ~1,400. Fill in signature order until the target is met. A few defectors then don't dent the raise. Standard underwriting practice, and it converts defection from a cliff into noise.

---

## 11. What gets deployed

| Piece | Deploy? |
|---|---|
| Official SwapVM / Aqua | No — use 1inch deployments (local fork fine for demo) |
| Custom SwapVM opcodes | No |
| Weir commitment registry + bond escrow | Yes |
| `committedTokens` partition + burn path in curve | Yes |
| Settlement step in graduation path | Yes |

### Demo

Make the mechanism a per-launch flag so the same launch runs with it off and on — a much cleaner story than a protocol that only works one way. Three runs:

1. **Flag off** — baseline launch, mechanism inert.
2. **All commitments honour** — tranche delivers, bonds returned, pool seeded with full quote.
3. **Partial defection** — 6 of 10 fill, 40M burned, 80 USDC of bonds retained, and public price per token demonstrably *higher* than run 1.

Run 3 is the one to show a judge. It's the claim from §6 proven onchain.

---

## 12. Track fit, honestly

**1inch / Aqua ($5,000).** `scope_of_work/1inch.md`: judges want a "sophisticated DeFi position" with real onchain settlement, and SwapVM usage scores higher. A conditional maker commitment that settles against wallet balance at fill time is exactly the wallet-balance-bounded pattern Aqua exists to demonstrate — 80%+ of the capital never moves. The bond is a side-pot that prices defection; it is not where the position lives. Settlement is stock `LimitSwap`, demoed on a local fork, which the track explicitly permits.

**Uniswap — treat as optional, not a second target.** Both `scope_of_work/1inch.md` §2 and `scope_of_work/Uniswap.md` §2 independently list combining SwapVM with v4 hooks in one product under *not feasible*: separate execution environments, no shared settlement layer. This design is narrower than the perps case those warnings target — one atomic settlement at graduation, not continuously tracked cross-VM positions — so it is not automatically disqualified. But the bridge was always the risk, and dropping the custom opcode didn't change that. **Recommendation: submit single-track to 1inch.** If the v4 pool seeding is claimed for Uniswap at all, claim it as what it is — the launch graduates into a v4 pool — and don't build extra surface to justify it.

**Process note:** `scope_of_work/1inch.md` flags "no single-commit entries on the final day" as an explicit trust signal. Commit against this early.

---

## 13. Still open

1. **Pick `d`**, then derive tranche size and bond from it (§5). The 0.00001 seed price in §6 is an illustrative round number, not a derived one.
2. **Concurrency cap** (§8) — registry, escalating bond, or correlated slashing. Without one, JIT defection stays profitable no matter how clean the burn is.
3. **Threshold question** (§7) — does the commitment tranche count toward graduation, or not? It cannot count *and* be unsettled.
4. **`try` block at `WeirV2BondingCurve.sol:649`** — settlement cannot live behind a call designed to fail silently.
</content>
</invoke>
