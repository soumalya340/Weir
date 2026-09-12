// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWeirV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice Narrow ERC20Burnable surface. WeirV2LauncherToken is the only
 * `stakeToken` this contract is ever deployed against, and it implements
 * ERC20Burnable, but `stakeToken` is typed as plain IERC20 for the rest of
 * this contract's needs, so `burnAndExit` casts to this instead.
 */
interface IERC20Burnable {
    function burn(uint256 amount) external;
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

    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 newAccRewardPerShare);
    event BurnedAndExited(address indexed user, uint256 amount, uint256 reward);
    event FutarchyProposalSet(address proposal);
    event EarlyExitUnlocked(address proposal);

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

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 unlockTime;
    }

    mapping(address => UserInfo) public users;

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
        _settle(u);

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

        _settle(u);

        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claims accrued reward without touching the staked balance or
     * its unlock timer.
     */
    function harvest() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        _settle(u);
    }

    /**
     * @notice Wires the one futarchy proposal contract allowed to unlock
     * early exit for this vault. Permissionless and settable at most once:
     * anyone can point a fresh WeirV2FutarchyProposal at an unwired vault to
     * kick off a decision market on it, but a vault already deciding (or
     * already unlocked) cannot be redirected to a second, competing proposal.
     */
    function setFutarchyProposal(address proposal) external {
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

        uint256 reward = _settle(u);

        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;

        IERC20Burnable(address(stakeToken)).burn(amount);
        emit BurnedAndExited(msg.sender, amount, reward);
    }

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
     * @notice Reward a user would receive if they harvested right now.
     */
    function pendingReward(address account) external view returns (uint256) {
        UserInfo storage u = users[account];
        return (u.amount * accRewardPerShare) / ACC_REWARD_SCALE - u.rewardDebt;
    }

    /**
     * @dev Credits everything the accumulator owes `u` at its current
     * checkpoint through the shared fee escrow, then re-bases its debt so
     * the same reward is never paid twice. Returns the amount credited.
     */
    function _settle(UserInfo storage u) private returns (uint256 accrued) {
        accrued = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE - u.rewardDebt;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_REWARD_SCALE;
        if (accrued == 0) return 0;

        if (quoteToken == address(0)) {
            feeEscrow.credit{value: accrued}(msg.sender);
        } else {
            IERC20(quoteToken).forceApprove(address(feeEscrow), accrued);
            feeEscrow.creditToken(msg.sender, quoteToken, accrued);
        }
        emit Harvested(msg.sender, accrued);
    }

    /**
     * @notice Accepts native ETH pulled from the hook when this pool's quote
     * currency is native.
     */
    receive() external payable {}
}
