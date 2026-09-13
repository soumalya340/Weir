# Idea 1: SwapVM-Powered Auto-Compounding Staking Flywheel

> [!NOTE]
> **Phase: POST-DEX GRADUATION**  
> This mechanism operates **after** the token has successfully graduated from the bonding curve into a live Uniswap v4 DEX pool. It intercepts trading fees swept by the pool hook and continuously routes them into automated token buybacks and compounding.

## Sources
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/src/WeirV2StakingReward.sol` — Staking reward vault for fee distribution
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/deps/swap-vm` — 1inch SwapVM execution engine and opcode sets
- `/Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/scope_of_work/1inch.md` — 1inch ETHGlobal prize track requirements and constraints

---

## Section 1: Why and What?

### 1. Technical Description
The **SwapVM-Powered Auto-Compounder** is an onchain yield-reinvestment extension for [`WeirV2StakingReward.sol`](file:///Users/soumalyapaul/Documents/EVM/Eth_Global_Discussions/Weir/src/WeirV2StakingReward.sol). 

In the standard staking design, liquidity pool trading fees swept by `WeirV2MemeHook` are notified as quote currency (ETH/USDC) into the staking accumulator (`accRewardPerShare`). Stakers harvest raw ETH into escrow.

The Auto-Compounder introduces a programmatic reinvestment layer using **1inch SwapVM**:
1. Accrued yield in ETH is routed directly into signed SwapVM execution orders (e.g., `LimitSwap`, `TWAPSwap`, or a custom `AutoCompoundOpcode`).
2. SwapVM executes MEV-resistant spot swaps to buy back the underlying launch token (`stakeToken`) without subjecting thin pools to sandwich attacks or manual slippage losses.
3. The repurchased `stakeToken` is directly added back to the staker's staked principal (`u.amount += repurchasedAmount`), auto-updating their reward debt checkpoint without resetting their primary unlock period unfairly.
4. This creates a perpetual onchain flywheel: **Trading Volume $\to$ Fee Generation $\to$ SwapVM Market Buy Pressure $\to$ Supply Lockup $\to$ Compounded APY.**

---

### 2. Simple (Layman) Description — Alice's Compounding Machine
Imagine **Alice** is a big believer in a community project. She stakes 10,000 community tokens into the staking vault.

#### Without Auto-Compounding (The Tedious Way):
- Alice waits a week. 
- The pool generates $50 worth of ETH in trading fees for her.
- Alice has to wake up, pay gas to harvest the ETH, go to a DEX, worry about slippage or bots frontrunning her, buy more community tokens, and pay gas *again* to stake them. Most users are lazy and just sell the ETH or leave it sitting idle.

#### With the SwapVM Auto-Compounder (The Smart Way):
- Alice ticks one box: **"Auto-Compound"**.
- Now, whenever fees arrive, the contract automatically uses Alice’s ETH reward to buy more community tokens for her at fair limit prices through 1inch SwapVM.
- Those new tokens are automatically tucked right into her staking pile.
- Next week, Alice earns fees not just on her original 10,000 tokens, but on 10,200 tokens! 
- Meanwhile, the entire community celebrates because trading fees are constantly and automatically **buying back the token and locking it away**.

---

### One-liner
**One-liner:** An automated staking engine that routes pool trading fees through 1inch SwapVM to continuously buy back and restake community tokens, turning passive fees into automated buy pressure and compounded APY.

---

## Architecture & Mental Workflow

```
[ Traders on Uniswap v4 / Launchpad Pool ]
                 │ (Trading Fees)
                 ▼
     [ WeirV2MemeHook Sweep ]
                 │ (notifyReward in ETH)
                 ▼
    [ WeirV2StakingReward Vault ]
                 │
                 ├──► Option A: Manual Harvest (User takes ETH)
                 │
                 └──► Option B: Auto-Compounder Engine
                             │
                             ▼
              [ 1inch SwapVM Router ]
              (Custom / Built-in Opcodes)
              - LimitSwap / TWAPSwap
              - MEV / Slippage Protection
              - Optional Custom Discount Opcode
                             │
                             ▼ (Bought stakeToken)
             [ Restaked into Alice's Principal ]
              u.amount += boughtAmount
```

### End-to-End Workflow:
1. **Staking:** Alice deposits `stakeToken` into `WeirV2StakingReward` and opts into auto-compounding.
2. **Fee Accumulation:** As traders swap on the community pool, the hook periodically calls `notifyReward(ethAmount)`. The global accumulator `accRewardPerShare` ticks up.
3. **Triggering Compounding:** A keeper, taker, or Alice herself triggers `compound(aliceAddress)`:
   - Alice's accrued ETH is calculated via `_settle()`.
   - The vault passes this ETH as `amountIn` to `SwapVM.swap()` with pre-validated taker parameters.
4. **SwapVM Execution:** SwapVM uses its opcode bytecode to settle the swap against available liquidity or market makers at guaranteed minimum rates.
5. **Auto-Restake:** The received `stakeToken` is not transferred to Alice's EOA; it is directly credited to `users[alice].amount`, and `totalStaked` increases.

---

## Custom SwapVM Opcode Opportunity (Hackathon Winning Factor)

To qualify for the highest score in the 1inch hackathon track, this idea can implement a custom opcode:

### Opcode Name: `AutoCompoundDiscount` (Bank `0x70` or `0xb0`)
* **What it does:** When SwapVM detects that the `query.taker` or caller is an authorized `WeirV2StakingReward` vault performing an auto-compound buyback, it:
  1. Reduces the swap protocol fee to **0%** (supporting community flywheels).
  2. Applies a TWAP/Dutch auction ceiling to protect the vault from buying during artificial price spikes.
* **Why judges will love it:** It directly links a custom SwapVM opcode modification to a real-world community DeFi app.
