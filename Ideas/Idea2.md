# Idea 2: Zero-custody virtual commitments → LimitSwap after graduation

> [!NOTE]
> **Two phases**  
> - **Before / during bonding:** virtual reserves (Aqua / signed commitments). USDC stays with backers; a reserved token tranche is fenced off from the public curve.  
> - **At / after graduation:** settlement and follow-on fills use stock SwapVM **`LimitSwap`** (and related existing instructions) against real post-grad liquidity.

> [!IMPORTANT]
> **No SwapVM opcode changes required.**  
> Graduation checks and reserve fencing live in Weir (bonding curve / hook / graduation executor). SwapVM is used with official contracts and existing instructions only. Redeploying a modified SwapVM is optional and not part of this plan.

## Sources
- `src/WeirV2BondingCurve.sol` — bonding curve
- `src/hooks/WeirV2MemeHook.sol` — Uniswap v4 launchpad hook
- `deps/swap-vm` — official 1inch SwapVM
- `scope_of_work/1inch.md` & `scope_of_work/Uniswap.md`

---

## Why and what

### Technical

Classic presales force early backers to send USDC into an escrow. If the launch fails or rugs, money is stuck or refunds cost gas.

This design:

1. **Pre-grad virtual reserves**  
   Backers sign conditional maker commitments (EIP-712 / Aqua balance mode). Committed USDC **does not leave** their wallets while the curve is live.  
   Supply is split, e.g. 10% reserved for committers, 90% on the public bonding curve. Public buys cannot eat the reserved tranche (enforced by Weir, not by a new opcode).

2. **Graduation gate (Weir)**  
   When the public curve hits the graduation threshold, Weir’s graduation path decides settlement is allowed. If the launch times out without graduating, commitments expire and **nothing is pulled**.

3. **Post-grad LimitSwap (official SwapVM)**  
   Settlement (and any later fills involving that reserved allocation / related quotes) runs through stock programs such as **`LimitSwap`**, optionally with min-rate / TWAP-style protection. No custom `PreLaunchCommitReserve` opcode.

### Layman — Alice and friends

Alice and eight friends want ground-floor access before the public curve.

**Old way:** send $1,000 into a presale contract and hope.

**This way:**

1. They pledge ~$111 each for a fixed token allotment, only if the launch graduates.
2. Money stays in their wallets (virtual / Aqua-backed commitment).
3. 100M tokens sit behind a rope for them; the public trades the other 900M on the curve.
4. If the curve graduates, Weir triggers settlement; SwapVM **LimitSwap** (existing) pulls USDC and delivers tokens.  
   If it flops, the pledge dies quietly. No pull, no refund gas.

### One-liner

Zero-custody pledges as virtual reserves during bonding; at graduation, settle with official SwapVM LimitSwap. No custom opcodes.

---

## Tokenomics sketch

| Parameter | Example | Notes |
|-----------|---------|--------|
| Total supply | 1,000,000,000 | Fixed at launch |
| Reserved for committers | 100,000,000 (10%) | Untouchable by public curve |
| Public bonding curve | 900,000,000 (90%) | `WeirV2BondingCurve` |
| Total USDC committed | $1,000 | Split across committers |
| Seed price | $0.00001 / token | $1,000 / 100M |

Numbers are illustrative; real launches set their own split and threshold.

---

## Lifecycle

```
[ Alice & friends ]  USDC stays in wallets (Aqua / signatures)
         │
         ▼  sign conditional commitments
┌────────────────────────────────────────────────────────────┐
│  PRE / DURING BONDING (Weir)                               │
│  [ Reserved tranche ]     [ Public bonding curve ]         │
│   virtual reserves         open trading                    │
│   (public cannot touch)    price moves with buys           │
│                                      │                     │
│                                      ▼                     │
│                              graduation check              │
└──────────────────────┬──────────────────┬──────────────────┘
                       │                  │
          graduated ───┘                  └── timeout / flop
                       │                       │
                       ▼                       ▼
         [ Official SwapVM LimitSwap ]   [ commitment expires ]
         pull USDC, deliver tokens        $0 pulled, no refunds
         (existing instructions only)
                       │
                       ▼
              Uniswap v4 pool live
```

---

## SwapVM usage (stock only)

| Phase | What runs where |
|--------|------------------|
| Pre-grad | Weir fences reserves; Aqua / EIP-712 holds the pledge |
| Graduation allowed? | Weir (`readyToGraduate` / executor), not a custom opcode |
| Settlement | Official SwapVM: `LimitSwap` (+ optional min-rate / TWAP) |
| After pool is live | Same LimitSwap-style programs for related fills if needed |

### What you deploy

| Piece | Deploy? |
|--------|---------|
| Official SwapVM / Aqua | No — use 1inch deployments (local fork OK for demo) |
| Custom SwapVM opcodes | No |
| Weir curve, hook, reserved tranche, graduation trigger | Yes |

---

## Why this still fits the 1inch + Uniswap tracks

- **1inch / Aqua:** real conditional maker commitments and onchain settlement via official SwapVM (fork demo is enough). Using SwapVM scores; modifying opcodes is optional and we are skipping it on purpose.
- **Uniswap:** reserved tranche + graduation still live in the v4 launchpad hook / curve path.

Custom opcodes remain a later optional boost, not a dependency for v1.
