# Idea 2: Zero-Custody Pre-Launch Virtual Commitment via SwapVM

## Sources
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/src/WeirV2BondingCurve.sol` — Constant-product bonding curve implementation
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/src/hooks/` & `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/deps/ponsfamily/contractsV2/` — Uniswap v4 hook-based launchpad architecture
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/deps/swap-vm` — 1inch SwapVM modular execution engine
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/scope_of_work/1inch.md` & `scope_of_work/Uniswap.md` — Scope and requirements

---

## Section 1: Why and What?

### 1. Technical Description
**Zero-Custody Pre-Launch Virtual Commitment** is a bonding curve presale mechanism governed by a custom 1inch **SwapVM opcode** paired with a **Uniswap v4 launchpad hook**.

In conventional launchpads (e.g., Pump.fun or standard presales), early backers must deposit upfront quote capital (USDC/ETH) into an escrow contract before launch. This exposes users to counterparty risk, rug pulls, locked capital, and high gas overheads for manual refund claims if the launch fails to graduate.

Under this architecture:
1. **Zero-Custody Commitments (Pre-Graduation):** Early community backers sign conditional EIP-712 SwapVM maker orders. Utilizing **Aqua’s balance model**, committed USDC **never leaves users' wallets** during the pre-launch and bonding curve phases.
2. **Supply Partitioning:** At launch initialization, the total token supply (e.g., 1 Billion tokens) is mathematically partitioned:
   - **Reserved Allocation (10% / 100M tokens):** Quarantined exclusively for the committed signers at a fixed ground-floor seed price ($1,000 USDC total = $0.00001 per token). The hook blocks public swaps from accessing or depleting this tranche.
   - **Public Curve Allocation (90% / 900M tokens):** Injected into the active bonding curve pool for open market trading, starting the curve with 10% effective progress already accomplished.
3. **Conditional Settlement (At Graduation):**
   - **Graduation Trigger:** The moment the public curve sells out its 900M tokens and reaches the graduation goal, the graduation executor calls `SwapVM.swap()` to atomically pull the $1,000 USDC from the committers' wallets and distribute the 100M tokens.
   - **Failure / Timeout Protection:** If the bonding curve fails to graduate before a set deadline, the conditional commitment expires worthless. No USDC is ever pulled, and zero gas is spent on refunds.

---

### 2. Simple (Layman) Description — Alice & The 9 Believers
Imagine **Alice** and **8 of her friends** discover a promising new meme/community project before it launches to the public. They want to be the earliest backers.

#### The Old Launchpad Way (High Risk & Stress):
- Alice and her friends have to send $1,000 USDC into a random creator's presale contract.
- If the creator rugs, or if the bonding curve flops and never graduates, Alice's money is trapped or she has to scramble and pay high gas fees to claim refunds.

#### The SwapVM Virtual Commit Way (Zero Risk & Ground-Floor Entry):
1. **The Handshake:** Alice and her 8 friends sign a digital pledge using a custom SwapVM rule: *"I pledge $111.11 USDC for 11,111,111 tokens, ONLY IF the project successfully sells out and graduates."*
2. **Money Stays at Home:** Crucially, **Alice’s $111.11 USDC never leaves her personal wallet**. She still holds her money.
3. **The Protected VIP Table:** The launchpad creates 1 Billion tokens. It locks 100 Million tokens (10%) behind velvet ropes for Alice and her friends. Public buyers can only trade the remaining 900 Million tokens (90%) on the bonding curve.
4. **The Big Day (Graduation):**
   - The public goes crazy trading the 900M tokens, pushing the bonding curve price up from $0.00001 to $0.00010.
   - The curve hits 100% and **graduates**!
   - The contract triggers the SwapVM rule: Alice's $111.11 USDC is automatically pulled from her wallet, and her 11.1M tokens land in her wallet at the original ground-floor $0.00001 price (she's already in 10x profit!).
   - If the project **flopped** and never graduated? The pledge simply cancels. Alice's money was in her wallet the entire time—**$0 lost, 0 hassle**.

---

### One-liner
**One-liner:** A zero-custody bonding curve presale mechanism where backers commit funds that remain in their wallets until the curve successfully graduates, locking in ground-floor allocations with zero rug or refund risk.

---

## Tokenomics & Mathematical Model

| Parameter | Value | Notes |
|---|---|---|
| **Total Token Supply** | **1,000,000,000 (1B)** | Fixed max supply created at genesis |
| **Committed VIP Tranche (10%)** | **100,000,000 (100M)** | Reserved for 9 friends; completely untouchable by public |
| **Public Bonding Curve (90%)** | **900,000,000 (900M)** | Active bonding curve pool (`WeirV2BondingCurve`) |
| **Total USDC Committed** | **$1,000 USDC** | Split across 9 friends (~$111.11 each) |
| **Ground-Floor Seed Price** | **$0.00001 / token** | $\frac{1,000\text{ USDC}}{100,000,000\text{ tokens}}$ ($100,000\text{ tokens / 1 USDC}$) |
| **Starting Curve Progress** | **10%** | Launches with initial momentum already accounted for |

---

## Architecture & Lifecycle Workflow

```
   [ Alice & 8 Friends ] (USDC stays in their own wallets via Aqua!)
            │
            ▼ (Sign EIP-712 orders with PreLaunchCommit opcode)
┌────────────────────────────────────────────────────────────────────────┐
│                   PRE-GRADUATION LAUNCHPAD HOOK                        │
│                                                                        │
│   [ 100M Reserved Tranche (10%) ]    [ 900M Public Bonding Curve (90%) ]
│    Locked for 9 Friends               Open for public trading          │
│    (Public cannot touch!)             Price climbs as buyers trade     │
│                                                   │                    │
│                                                   ▼                    │
│                                            [ afterSwap() ]             │
│                                       Did curve hit graduation goal?   │
└───────────────────────────────────────────────────┬────────────────────┘
                                                    │
                   ┌────────────────────────────────┴──────────────────┐
                   │                                                   │
                   ▼ (YES: Curve Graduated)                            ▼ (NO: Timeout / Flop)
     [ Call SwapVM.swap() ]                             [ Commitment Expired ]
     - Pull $1,000 USDC from friends' wallets            - $0 pulled from friends
     - Release 100M tokens to friends                   - No gas for refunds
     - Migrate pool liquidity to Uniswap v4              - Tokens recycled / closed
```

---

## Custom SwapVM Opcode Implementation

To implement this on SwapVM, we introduce a custom opcode:

### Opcode Name: `PreLaunchCommitReserve` (Bank `0x90` or `0x20`)
* **Bytecode Arguments:** `[address bondingCurve, uint256 minimumGraduationThreshold, uint32 deadline]`
* **Execution Logic:**
  1. **Status Verification:** The opcode checks `IBondingCurve(bondingCurve).isGraduated()`. If `false`, the swap reverts, preventing early execution or taker sniping before graduation.
  2. **Reserve Quota Validation:** Verifies that the order fills exclusively from the 100M reserved supply partition, preserving the 900M bonding curve invariant.
  3. **Zero-Loss Timeout:** If `block.timestamp > deadline` and graduation is not reached, the opcode halts permanently without touching the maker's wallet balance.

---

## Why This Wins Hackathon Judging

1. **Directly fulfills 1inch Track Requirements:** Uses official SwapVM contracts, modifies SwapVM opcodes, and demonstrates real onchain token settlements via local forks.
2. **Cross-Track Eligibility:** Qualifies for **both** the **1inch ($5,000 Aqua/SwapVM track)** and the **Uniswap ($3,000 v4 Hook track)**.
3. **Solves Real Web3 Pain Points:** Eliminates presale smart contract custody risk, provides bot-proof ground-floor access for communities, and guarantees automated execution upon pool graduation.
