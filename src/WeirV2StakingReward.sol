// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWeirV2FeeEscrow, IWeirV2FeePolicy} from "./interfaces/ILaunchpadV2.sol";
import {ISwapVM} from "./interfaces/ISwapVM.sol";
import {SwapVMOrderLib} from "./libraries/SwapVMOrderLib.sol";

/**
 * @notice Narrow ERC20Burnable surface. WeirV2LauncherToken is the only
 * `stakeToken` this contract is ever deployed against, and it implements
 * ERC20Burnable, but `stakeToken` is typed as plain IERC20 for the rest of
 * this contract's needs, so `burnAndExit` casts to this instead.
 */
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

interface IWeirV2HookRedemptionView {
    function poolRedemption() external view returns (address);
}

interface IWeirV2PoolRedemptionFor {
    function redeemFor(address token, address account, uint256 amount, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut);
}

/**
 * @title WeirV2StakingReward
 * @notice Lets holders of one graduated launch's memecoin stake it directly
 * (no LP position, no pool exposure, no impermanent loss) in exchange for a
 * share of that pool's trading fees, funded by WeirV2MemeHook's per-pool
 * `stakerFeeShareBps` cut on every `sweepPoolFees`. One instance covers one
 * pool, mirroring the per-pool StakePool resource this contract is a
 * Solidity port of.
 *
 * Reward accounting is the same accumulator the source used: `accRewardPerShare`
 * only ever grows, each staker's `rewardDebt` is what the accumulator already
 * owed them at their last checkpoint, and `pending = accRewardPerShare *
 * amount - rewardDebt` is what to release next. Because the accumulator is
 * fee-added / total-staked, the same fee inflow pays each staked token more
 * as fewer tokens are staked, so participation itself is the second reward on
 * top of any price appreciation from the reduced circulating float.
 *
 * A 7-day lock re-arms on every top-up, mirroring the source's
 * WEEK_IN_SECONDS unlock_time: it discourages staking in front of a known
 * sweep and unstaking right after.
 *
 * Auto-compound (Ideas/Idea1.md): a staker may opt in to have their accrued
 * quote reward kept here instead of paid out, then spent through the
 * official 1inch SwapVM router against any resting maker order selling the
 * memecoin (stock `LimitSwap` / `TWAPSwap` / AMM programs; no custom
 * opcodes). Whatever is bought lands straight back in their principal
 * without re-arming the unlock timer, so pool fees become buy pressure and
 * a larger stake next period.
 */
contract WeirV2StakingReward is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC_REWARD_SCALE = 1e18;
    uint256 public constant UNLOCK_PERIOD = 7 days;

    error ZeroAddress();
    error ZeroAmount();
    error NotHook();
    error InsufficientStake();
    error TooEarlyToUnstake();
    error NativeValueMismatch();
    error NotFutarchyProposal();
    error FutarchyProposalAlreadySet();
    error EarlyExitNotUnlocked();
    error CompoundRouterAlreadySet();
    error CompoundNotConfigured();
    error AutoCompoundDisabled();
    error NotCompoundOperator();
    error NothingToCompound();
    error OrderTokenMismatch();
    error CompoundBoughtNothing();
    error CompoundOverspent(uint256 spent, uint256 budget);
    error RedemptionNotConfigured();

    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 newAccRewardPerShare);
    event BurnedAndExited(address indexed user, uint256 amount, uint256 reward);
    event BurnedAndRedeemed(address indexed user, uint256 amount, uint256 reward, uint256 quoteOut);
    event FutarchyProposalSet(address proposal);
    event EarlyExitUnlocked(address proposal);
    event CompoundRouterSet(address swapVM, address weth);
    event AutoCompoundSet(address indexed user, bool enabled);
    event RewardHeldForCompound(address indexed user, uint256 amount);
    event Compounded(address indexed user, address indexed caller, uint256 quoteSpent, uint256 tokensRestaked);

    address public immutable hook;
    IERC20 public immutable stakeToken;
    address public immutable quoteToken; // address(0) denotes native ETH
    IWeirV2FeeEscrow public immutable feeEscrow;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;

    // The one WeirV2FutarchyProposal instance authorized to decide this
    // vault's early-exit question. Set at most once (a fresh proposal cycle
    // needs a fresh vault, exactly as WeirV2BuybackVault's per-token vest
    // terms are fixed once bound). Deciding "no" simply never unlocks
    // anything; there is no separate reject step to wire.
    address public futarchyProposal;
    // Once true, permanently lets any staker burn their stake and exit early
    // via burnAndExit, bypassing UNLOCK_PERIOD. Set only by futarchyProposal
    // when its pass market wins, and never unset.
    bool public earlyExitUnlocked;

    // Official 1inch SwapVM router compounds are executed through, and its
    // WETH (native-quote pools pay the fill in ETH, which the router accepts
    // only when the order's input token is its WETH). Wired once by the hook.
    ISwapVM public swapVM;
    address public weth;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 unlockTime;
    }

    mapping(address => UserInfo) public users;
    // Opt-in flag: while set, accrued rewards accumulate in `compoundable`
    // instead of being credited to the fee escrow.
    mapping(address => bool) public autoCompound;
    // Quote reward held here on the user's behalf, waiting to be swapped
    // into more stake. Owed to the user; never part of the reward pot.
    mapping(address => uint256) public compoundable;

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    /**
     * @param hook_ The WeirV2MemeHook governing this pool; the only caller
     * allowed to fund rewards via `notifyReward`.
     * @param stakeToken_ The launch's memecoin, staked directly.
     * @param quoteToken_ The pool's quote currency rewards are paid in
     * (address(0) for native ETH), matching the fee currency the hook sweeps.
     * @param feeEscrow_ Shared claimable balance ledger rewards are paid
     * through, the same escrow every other payout in the protocol uses.
     */
    constructor(address hook_, IERC20 stakeToken_, address quoteToken_, IWeirV2FeeEscrow feeEscrow_) {
        if (hook_ == address(0) || address(stakeToken_) == address(0) || address(feeEscrow_) == address(0)) {
            revert ZeroAddress();
        }
        hook = hook_;
        stakeToken = stakeToken_;
        quoteToken = quoteToken_;
        feeEscrow = feeEscrow_;
    }

    /**
     * @notice Stakes `amount` of the memecoin, re-arming the 7-day unlock on
     * top of any existing stake and settling previously accrued reward into
     * the user's claimable balance first so the new deposit does not dilute it.
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage u = users[msg.sender];
        _settle(msg.sender, u);

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        u.amount += amount;
        totalStaked += amount;
        u.unlockTime = block.timestamp + UNLOCK_PERIOD;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        emit Staked(msg.sender, amount, u.unlockTime);
    }

    /**
     * @notice Withdraws `amount` of previously staked memecoin plus any
     * reward accrued up to now. Reverts before the 7-day lock from the most
     * recent stake has elapsed.
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage u = users[msg.sender];
        if (amount > u.amount) revert InsufficientStake();
        if (block.timestamp < u.unlockTime) revert TooEarlyToUnstake();

        _settle(msg.sender, u);

        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claims accrued reward without touching the staked balance or
     * its unlock timer. For an auto-compounding staker this moves the accrual
     * into their compoundable balance instead of paying it out.
     */
    function harvest() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        _settle(msg.sender, u);
    }

    // ---------------------------------------------------------------------
    // Auto-compound (SwapVM)
    // ---------------------------------------------------------------------

    /**
     * @notice Wires the SwapVM router compounds execute through. Set once by
     * the governing hook, which carries the protocol-wide router address.
     */
    function setCompoundRouter(ISwapVM swapVM_, address weth_) external onlyHook {
        if (address(swapVM_) == address(0)) revert ZeroAddress();
        if (address(swapVM) != address(0)) revert CompoundRouterAlreadySet();
        // A native-quote pool pays its fills in ETH, which the router only
        // takes as msg.value against its own WETH; without it compounding
        // could never execute here.
        if (quoteToken == address(0) && weth_ == address(0)) revert ZeroAddress();
        swapVM = swapVM_;
        weth = weth_;
        emit CompoundRouterSet(address(swapVM_), weth_);
    }

    /**
     * @notice Opts the caller in to (or out of) auto-compounding. Default is
     * off. Reversible at any time; switching off pays any reward still held
     * for compounding out through the escrow like an ordinary harvest.
     * @dev Rewards accrued so far are settled first under the *old* mode,
     * so a toggle never reclassifies what was already earned.
     */
    function setAutoCompound(bool enabled) external nonReentrant {
        if (enabled && address(swapVM) == address(0)) revert CompoundNotConfigured();
        UserInfo storage u = users[msg.sender];
        _settle(msg.sender, u);
        autoCompound[msg.sender] = enabled;
        if (!enabled) {
            uint256 held = compoundable[msg.sender];
            if (held != 0) {
                compoundable[msg.sender] = 0;
                _payQuote(msg.sender, held);
                emit Harvested(msg.sender, held);
            }
        }
        emit AutoCompoundSet(msg.sender, enabled);
    }

    /**
     * @notice Spends `account`'s held quote reward on the memecoin through
     * the official SwapVM router and adds what was bought to their stake.
     * Callable by the staker themselves or by a protocol fee-sweep operator
     * (keeper), the same trust boundary every other slippage-sensitive
     * action in the protocol uses, since whoever calls chooses the order and
     * the floor.
     * @param order Any resting maker order on the router whose pair is
     * (memecoin, quote) — for a native-quote pool, (memecoin, WETH). Stock
     * programs only: LimitSwap, TWAPSwap, XYC, ... whatever the maker shipped.
     * @param signature The maker's EIP-712 signature over the order; empty
     * for Aqua-mode orders (the router then skips signature checks).
     * @param minTokensOut Floor on memecoin received for the full budget;
     * the router scales it pro rata if the order can only fill part.
     * @dev The stake grows but `unlockTime` is left alone: compounding is a
     * reinvestment of reward already earned, not a fresh deposit, so it must
     * not re-arm the 7-day lock against the staker (Idea1 §"why and what").
     */
    function compound(address account, ISwapVM.Order calldata order, bytes calldata signature, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 quoteSpent, uint256 tokensRestaked)
    {
        if (address(swapVM) == address(0)) revert CompoundNotConfigured();
        if (msg.sender != account && !IWeirV2FeePolicy(hook).isFeeSweepOperator(msg.sender)) {
            revert NotCompoundOperator();
        }
        if (!autoCompound[account]) revert AutoCompoundDisabled();

        UserInfo storage u = users[account];
        _settle(account, u);
        uint256 budget = compoundable[account];
        if (budget == 0) revert NothingToCompound();

        // The pair the order quotes must be exactly this vault's memecoin and
        // its quote (WETH standing in for native ETH). Order data begins with
        // the two sorted token addresses (MakerTraitsLib.tokens).
        address payToken = quoteToken == address(0) ? weth : quoteToken;
        (address tokenA, address tokenB, bool payIsA) = SwapVMOrderLib.sortTokens(payToken, address(stakeToken));
        if (order.data.length < 40) revert OrderTokenMismatch();
        if (address(bytes20(order.data[0:20])) != tokenA || address(bytes20(order.data[20:40])) != tokenB) {
            revert OrderTokenMismatch();
        }

        bytes memory takerData = SwapVMOrderLib.buildTakerTraits({
            isExactIn: true,
            isAToB: payIsA,
            allowPartialFill: true,
            strictThreshold: false,
            threshold: minTokensOut,
            deadline: 0,
            signature: signature
        });

        uint256 tokensBefore = stakeToken.balanceOf(address(this));
        if (quoteToken == address(0)) {
            uint256 ethBefore = address(this).balance;
            // The router wraps to WETH, pays the maker, and refunds any
            // unspent value to this vault (receive() below).
            swapVM.swap{value: budget}(order, budget, takerData);
            quoteSpent = ethBefore - address(this).balance;
        } else {
            IERC20 quote = IERC20(quoteToken);
            uint256 quoteBefore = quote.balanceOf(address(this));
            quote.forceApprove(address(swapVM), budget);
            swapVM.swap(order, budget, takerData);
            quote.forceApprove(address(swapVM), 0);
            quoteSpent = quoteBefore - quote.balanceOf(address(this));
        }
        tokensRestaked = stakeToken.balanceOf(address(this)) - tokensBefore;
        if (quoteSpent > budget) revert CompoundOverspent(quoteSpent, budget);
        if (tokensRestaked == 0) revert CompoundBoughtNothing();

        compoundable[account] = budget - quoteSpent;
        u.amount += tokensRestaked;
        totalStaked += tokensRestaked;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        emit Compounded(account, msg.sender, quoteSpent, tokensRestaked);
    }

    // ---------------------------------------------------------------------
    // Futarchy early exit
    // ---------------------------------------------------------------------

    /**
     * @notice Wires the one futarchy proposal contract allowed to unlock
     * early exit for this vault. Callable only by the governing hook (which
     * the factory drives after validating the proposal is bound to this
     * vault). Settable at most once: a vault already deciding (or already
     * unlocked) cannot be redirected to a second, competing proposal.
     * @dev Previously permissionless, which let any EOA seize the slot and
     * either unlock early exit without a decision market or permanently
     * grief futarchy. Gating through the hook closes both attacks.
     */
    function setFutarchyProposal(address proposal) external onlyHook {
        if (proposal == address(0)) revert ZeroAddress();
        if (futarchyProposal != address(0)) revert FutarchyProposalAlreadySet();
        futarchyProposal = proposal;
        emit FutarchyProposalSet(proposal);
    }

    /**
     * @notice Called by this vault's registered futarchy proposal once its
     * pass market has won, permanently letting stakers burn their stake and
     * exit early via `burnAndExit`. Idempotent: a proposal cannot double-call
     * this to any further effect, and there is no path back to locked.
     */
    function unlockEarlyExit() external {
        if (msg.sender != futarchyProposal) revert NotFutarchyProposal();
        earlyExitUnlocked = true;
        emit EarlyExitUnlocked(msg.sender);
    }

    /**
     * @notice Burns `amount` of the caller's staked memecoin outright
     * (instead of returning it) and pays out their full accrued reward plus
     * the pro-rata share of `amount` against their stake, bypassing
     * UNLOCK_PERIOD. Only callable once this vault's futarchy proposal has
     * resolved in favour of early exit. This is the "take out the 40% fee
     * liquidity by burning your tokens" path the decision market exists for;
     * ordinary `unstake` is unaffected and keeps returning the stake intact.
     */
    function burnAndExit(uint256 amount) external nonReentrant {
        if (!earlyExitUnlocked) revert EarlyExitNotUnlocked();
        if (amount == 0) revert ZeroAmount();

        UserInfo storage u = users[msg.sender];
        if (amount > u.amount) revert InsufficientStake();

        uint256 reward = _settle(msg.sender, u);

        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        IERC20Burnable(address(stakeToken)).burn(amount);
        emit BurnedAndExited(msg.sender, amount, reward);
    }

    /**
     * @notice The dead-pool exit the decision market is for. Burns `amount`
     * of the caller's stake through WeirV2PoolRedemption, which pays the
     * caller their pro-rata share of the pool's locked quote (subject to the
     * pool-wide 40% ceiling and the caller's own curve/commitment
     * contribution), plus their full accrued reward, bypassing UNLOCK_PERIOD.
     * Only callable once this vault's futarchy proposal has resolved PASS,
     * which is also what unlocked redemption on the pool.
     */
    function burnAndRedeem(uint256 amount, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        if (!earlyExitUnlocked) revert EarlyExitNotUnlocked();
        if (amount == 0) revert ZeroAmount();
        address redemption = IWeirV2HookRedemptionView(hook).poolRedemption();
        if (redemption == address(0)) revert RedemptionNotConfigured();

        UserInfo storage u = users[msg.sender];
        if (amount > u.amount) revert InsufficientStake();

        uint256 reward = _settle(msg.sender, u);

        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        stakeToken.forceApprove(redemption, amount);
        quoteOut = IWeirV2PoolRedemptionFor(redemption).redeemFor(address(stakeToken), msg.sender, amount, minQuoteOut);
        emit BurnedAndRedeemed(msg.sender, amount, reward, quoteOut);
    }

    // ---------------------------------------------------------------------
    // Reward funding
    // ---------------------------------------------------------------------

    /**
     * @notice Funds this pool's staker reward pot with `amount` of quote
     * token, pulled from the hook (attached as `msg.value` when this pool's
     * quote currency is native ETH). Called once per `sweepPoolFees` with
     * this pool's carved-out staker share. A sweep landing while nobody is
     * staked simply is not distributed here (the hook folds it back to the
     * creator bucket instead), since there is no share to credit it against;
     * the hook must not call this with native value unless it returns true.
     */
    function notifyReward(uint256 amount) external payable onlyHook returns (bool distributed) {
        if (amount == 0 || totalStaked == 0) return false;

        if (quoteToken == address(0)) {
            if (msg.value != amount) revert NativeValueMismatch();
        } else {
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        accRewardPerShare += (amount * ACC_REWARD_SCALE) / totalStaked;
        emit RewardNotified(amount, accRewardPerShare);
        return true;
    }

    /**
     * @notice Reward a user would receive if they harvested right now,
     * excluding anything already held for compounding.
     */
    function pendingReward(address account) external view returns (uint256) {
        UserInfo storage u = users[account];
        return (u.amount * accRewardPerShare) / ACC_REWARD_SCALE - u.rewardDebt;
    }

    /**
     * @dev Credits everything the accumulator owes `u` at its current
     * checkpoint, then re-bases its debt so the same reward is never paid
     * twice. Auto-compounding accounts keep the quote here for `compound`;
     * everyone else is paid through the shared fee escrow. Returns the
     * amount settled.
     */
    function _settle(address account, UserInfo storage u) private returns (uint256 accrued) {
        accrued = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE - u.rewardDebt;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;
        if (accrued == 0) return 0;

        if (autoCompound[account]) {
            compoundable[account] += accrued;
            emit RewardHeldForCompound(account, accrued);
            return accrued;
        }
        _payQuote(account, accrued);
        emit Harvested(account, accrued);
    }

    /**
     * @dev Pays `amount` of quote to `account` through the shared fee escrow.
     */
    function _payQuote(address account, uint256 amount) private {
        if (quoteToken == address(0)) {
            feeEscrow.credit{value: amount}(account);
        } else {
            IERC20(quoteToken).forceApprove(address(feeEscrow), amount);
            feeEscrow.creditToken(account, quoteToken, amount);
        }
    }

    /**
     * @notice Accepts native ETH pulled from the hook when this pool's quote
     * currency is native, and unspent value the SwapVM router refunds after
     * a partial compound fill.
     */
    receive() external payable {}
}
