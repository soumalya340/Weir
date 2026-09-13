# Weir

**Weir** is a fair launchpad on Uniswap v4 hooks and 1inch SwapVM: sniper-protected bonding curves, bonded zero-custody pre-launch commitments, in-place graduation into a permanently locked v4 pool, real yield streamed to stakers, and a decision market that decides when they can leave. Backers are not exit liquidity.

## What is different about Weir

### 1. Pre-launch commitments where the money stays in your wallet
Backers pledge USDC to a launch **without sending it anywhere**. A pledge is a resting 1inch SwapVM limit order (signed EIP-712, or shipped to Aqua) that buys a fixed allocation at `P₀ × (1 − d)`, checked against the wallet at fill time. The only escrow is a **20% bond**. Honour the pledge at graduation and you get the tokens and the bond back. Walk, and you lose the bond and get nothing.

### 2. Defection is burned, never resold
Tokens a defector would have received are destroyed with `burn()`, so supply falls. Their forfeited bond becomes quote backing everyone else. A failed commitment round cannot leave public buyers worse off than no round at all. Forfeited bonds go first to the backers who honoured (mutual insurance), and only to the pool if nobody did.

### 3. The bond is a protocol constant
20%, hardcoded, not a creator or governance knob. Creators compete on discount (their own dilution), never on bond (the public's protection). An **aggregate exposure cap** refuses any pledge a wallet cannot cover across all its open commitments, so the multi-pool free option does not exist.

### 4. Settle, then burn, then seed, atomically
Commitment settlement runs inside the graduation transaction, before the curve is swept and before the Uniswap v4 pool is initialised. Nothing is seeded on quote that did not arrive. Settled quote seeds the pool on top of the curve's reserves, so a successful round opens the pool at a higher price than a launch without one.

### 5. Three-partition bonding curve with a trading gate
Every launch fences its supply into a **pool seed**, a **commitment tranche**, and a **public curve**. The tranche never enters the price and can never be bought or sold into. The curve opens at a fixed time at least 24 hours after the campaign starts, so backers pledge against a token that already exists but nobody can trade yet. A decaying anti-snipe tax (up to 99%, seconds-long) protects the open.

### 6. Graduation without migration
The curve trades in the same quote asset the pool will use. At graduation the reserves seed a full-range Uniswap v4 position directly, no swap, no oracle, no DEX migration, and the position NFT is locked forever in the launch locker. Excess tokens from the virtual reserve are permanently locked too.

### 7. A singleton v4 hook that pays stakers, not just LPs
One hook governs every graduated pool. It takes a fee on each swap (`afterSwap`), converts memecoin-denominated fees to quote against the pool itself, and splits: protocol, **stakers**, buyback-and-vest, creator. Holders stake the memecoin directly, no LP position, no impermanent loss, and earn ETH/USDC.

### 8. Fee split frozen per launch
Every leg of the split, including the staker share, is snapshotted when the launch is created and pinned by the creator's economics digest. The protocol owner cannot reprice a live pool. What a staker signed up for is what they get.

### 9. Auto-compounding through official 1inch SwapVM
Opt in once. Your fee rewards are held and swapped into more of the token through the official SwapVM router against any resting maker strategy (limit, TWAP, AMM, Aqua-shipped), then restaked **without resetting your 7-day unlock**. Pool fees become standing buy pressure. No custom opcodes anywhere.

### 10. Futarchy decides early exit
Anyone can post a small bond and open a MetaDAO-style decision market on one question: should stakers be allowed to burn their stake and exit before the lock? Two LMSR markets (PASS / FAIL) trade for three days; the higher-priced side wins and, if PASS, permanently unlocks `burnAndExit` on that vault.

### 11. Buyback that vests instead of burning
Bought-back tokens go into a five-year vest split between creator and protocol, so buybacks reduce float today without handing anyone an instant dump.

## Flow in one picture

```
T−24h+  launch with campaign ─► backers sign SwapVM orders + post 20% bond (pledge stays home)
T       curve opens ───────────► public trades the public partition, snipe tax decays
T+~1h   public partition sold ─► graduate: fill honourers via SwapVM, burn defectors' tokens,
                                 seed v4 pool (locked forever), register hook
T+…     every swap pays fees ──► stakers / protocol / buyback-vest / creator
        stakers auto-compound ─► SwapVM buys more token, restakes
        futarchy market ───────► may unlock early exit
```

## Where the integrations live (for verification)

**Uniswap v4**
- `src/hooks/WeirV2MemeHook.sol` — `_afterSwap` fee capture, `_executeInternalSwap` conversions, `_distribute` split, per-pool staking vaults.
- `src/WeirV2LaunchFactory.sol` — `createGraduatedPool` (pool init, full-range mint), `registerPool` call.
- `src/WeirV2GraduationExecutor.sol`, `src/WeirV2LaunchLocker.sol` — PositionManager mint and permanent lock.

**1inch SwapVM / Aqua** (official routers only, no opcode changes)
- `src/WeirV2CommitmentRegistry.sol` — `commit`, `settle`, `_fill`, `_buildOrder` (StaticBalances · LimitSwap · InvalidateBit · Deadline).
- `src/WeirV2StakingReward.sol` — `compound`.
- `src/libraries/SwapVMOrderLib.sol` — byte-exact program and taker-traits builders.
- `src/interfaces/ISwapVM.sol` — ABI mirror of the official interface.

**Decision market**
- `src/WeirV2FutarchyProposal.sol`, `src/MemePredictionMarket/Binary.sol`.

## Repository map

| Path | Contents |
|---|---|
| `src/` | All contracts |
| `script/DeployWeirV2.s.sol` | Full deployment and wiring (set `SWAP_VM_ROUTER` to enable commitments and auto-compound) |
| `test/` | Foundry suites |
| `Architecture.md` | Complete architecture, flows, decisions and trade-offs |
| `TestCase.md` | Test plan |
| `Ideas/` | Design writeups (`Idea1.md` auto-compound, `Idea2.md` commitments, `Plan.md` campaign setup) |
| `deps/swap-vm` | Vendored official 1inch SwapVM, reference only |

## Build

```bash
forge build
forge test
forge build --sizes --optimize --optimizer-runs 200   # deploy-size check
```

Required env for deployment: `PRIVATE_KEY`, `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2`. Optional: `SWAP_VM_ROUTER`, `PROTOCOL_FEE_RECIPIENT`, `INITIAL_LAUNCH_FEE`, `CREATE2_DEPLOYER`.
