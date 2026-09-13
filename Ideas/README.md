# Weir ideas (1inch SwapVM / Aqua + Uniswap v4)

Shared decision for both ideas in this folder:

**We are not changing SwapVM opcodes for v1.**  
Build on official 1inch SwapVM / Aqua deployments and existing instructions (`LimitSwap`, `TWAPSwap`, min-rate, fees, Aqua balance mode). Weir owns launch, staking, and graduation logic.

| Idea | Phase | SwapVM role | Custom opcodes? |
|------|--------|-------------|-----------------|
| [Idea1.md](./Idea1.md) | Post-graduation | Auto-compound stake rewards via LimitSwap / TWAP | No |
| [Idea2.md](./Idea2.md) | Pre-bond virtual reserves → settle at/after graduation | LimitSwap for settlement after Weir says graduated | No |

Redeploying a modified SwapVM is allowed by the track if we ever add an opcode later. It is out of scope for these writeups.
