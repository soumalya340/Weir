# Idea 1: Auto-compounding staked tokens (SwapVM + Aqua)

> [!NOTE]
> **Phase: POST-DEX GRADUATION**  
> Runs after the token has graduated from the bonding curve into a live Uniswap v4 pool. Pool fees swept by the meme hook can be reinvested into more staked tokens instead of sitting as raw ETH/USDC.

> [!IMPORTANT]
> **No SwapVM opcode changes required.**  
> This uses official 1inch SwapVM / Aqua with existing instructions (`LimitSwap`, `TWAPSwap`, min-rate, fees). Weir deploys the staking + compound trigger; it does not redeploy a modified SwapVM for a custom opcode.

## Sources
- `src/WeirV2StakingReward.sol` — staking reward vault
- `deps/swap-vm` — official 1inch SwapVM (already deployed on many chains)
- `scope_of_work/1inch.md` — Aqua / SwapVM track notes

---

## Why and what

### Technical

Today, `WeirV2MemeHook` sweeps fees and `WeirV2StakingReward` pays stakers in quote (ETH/USDC). Stakers harvest manually.

Auto-compound adds a reinvest path:

1. Staker opts into auto-compound.
2. Accrued quote reward is passed into an official SwapVM program (e.g. `LimitSwap` and/or `TWAPSwap` with a min rate).
3. SwapVM buys `stakeToken` against available liquidity / makers.
4. Bought tokens are credited back to `users[alice].amount` (restaked), with reward debt updated without unfairly resetting unlock rules.

Optional: Aqua mode for balance/settlement instead of a one-off signature pull every time. Still no new opcodes.

### Layman — Alice's compounding

Alice stakes 10,000 community tokens.

**Without auto-compound:** she harvests ETH, swaps on a DEX (slippage, bots, extra gas), then stakes again. Most people skip it or sell the ETH.

**With auto-compound:** she opts in once. When fees arrive, a keeper/taker/Alice triggers compound; SwapVM buys more community tokens; those land back in her stake. Next period she earns on a larger pile, and fee flow becomes buy pressure into the token.

### One-liner

Pool fees go through official 1inch SwapVM (and optionally Aqua) to buy and restake the launch token for opted-in stakers. No custom SwapVM opcodes.

---

## Architecture

```
[ Traders on Uniswap v4 pool ]
            │ fees
            ▼
   [ WeirV2MemeHook sweep ]
            │ notifyReward (ETH/USDC)
            ▼
   [ WeirV2StakingReward ]
            ├── Option A: manual harvest (user takes quote)
            └── Option B: auto-compound
                        │
                        ▼
              [ Official SwapVM / Aqua router ]
              Existing programs only:
              - LimitSwap / TWAPSwap
              - Min rate / fee instructions
                        │
                        ▼ bought stakeToken
              [ Restake into Alice's principal ]
```

### End-to-end

1. Alice stakes and opts into auto-compound.
2. Hook notifies rewards; `accRewardPerShare` rises.
3. Someone calls `compound(alice)` (keeper, taker, or Alice).
4. Vault settles her accrued quote and calls `SwapVM.swap(...)` with a stock program.
5. Received `stakeToken` increases `users[alice].amount` and `totalStaked`.

### What you deploy

| Piece | Deploy? |
|--------|---------|
| Official SwapVM / Aqua | No — use 1inch deployments (fork OK for demo) |
| Custom SwapVM opcodes | No |
| Weir staking + compound entrypoint | Yes |

---

## Out of scope for v1

Custom opcodes such as a vault-only fee discount. Possible later for scoring flair; not needed for the product or a working Aqua/SwapVM demo.
