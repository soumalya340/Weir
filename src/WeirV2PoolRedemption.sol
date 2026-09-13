// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {WeirV2LaunchLocker} from "./WeirV2LaunchLocker.sol";
import {WeirV2BondingCurve} from "./WeirV2BondingCurve.sol";
import {WeirV2CommitmentRegistry} from "./WeirV2CommitmentRegistry.sol";
import {WeirV2MemeHook} from "./hooks/WeirV2MemeHook.sol";
import {IWeirV2LaunchFactory} from "./interfaces/ILaunchpadV2.sol";

interface IERC20BurnableRedeem {
    function burn(uint256 amount) external;
}

interface IWeirV2FactoryRedemptionView {
    function getLaunchedToken(address token) external view returns (IWeirV2LaunchFactory.LaunchedToken memory);
    function commitmentRegistry() external view returns (WeirV2CommitmentRegistry);
}

/**
 * @title WeirV2PoolRedemption
 * @notice Dead-pool exit for the people who built the launch. Once a pool's
 * futarchy market resolves PASS, members may burn launch tokens and take
 * their pro-rata share of the graduated Uniswap v4 position's quote, up to
 * a hard ceiling of 40% of the liquidity that existed at unlock. The
 * remaining 60% stays locked forever.
 *
 * Who is a member: anyone who bought on the bonding curve (net of what they
 * sold back) or whose pre-launch commitment was filled. Membership is both
 * the vote gate on the futarchy markets and the per-account cap on how much
 * may be redeemed: you can burn at most as many tokens as you contributed.
 *
 * How a redemption works: burning `a` tokens against a supply of `S`
 * removes `a / S` of the position's current liquidity. The quote that comes
 * out goes to the redeemer; the tokens that come out are burned together
 * with `a`. Liquidity is removed proportionally, so the pool's price does
 * not move and remaining holders are not diluted. The share is taken
 * against total supply (which still counts pool-held and locker-held
 * tokens), so it is deliberately conservative.
 */
contract WeirV2PoolRedemption is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASIS_POINTS = 10_000;
    /// @notice At most this share of the position's liquidity at unlock may ever be redeemed.
    uint256 public constant MAX_REDEEMABLE_BPS = 4_000;

    struct RedemptionState {
        address proposal; // the one futarchy proposal allowed to unlock
        bool unlocked;
        uint128 liquidityAtUnlock;
        uint128 liquidityRedeemed;
        uint256 quotePaid;
        uint256 tokensBurned;
    }

    error ZeroAddress();
    error ZeroAmount();
    error NotFactory();
    error NotProposal();
    error NotStakingVault();
    error ProposalAlreadySet();
    error AlreadyUnlocked();
    error NotUnlocked();
    error PositionNotLocked();
    error NotMember();
    error ExceedsContribution(uint256 requested, uint256 eligible);
    error RedemptionCapReached(uint256 requested, uint256 remaining);
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error TransferFailed();

    event ProposalRegistered(address indexed token, address proposal);
    event RedemptionUnlocked(address indexed token, uint128 liquidityAtUnlock, uint128 redeemableLiquidity);
    event Redeemed(
        address indexed token,
        address indexed account,
        uint256 tokensBurned,
        uint128 liquidityRemoved,
        uint256 quoteOut
    );

    IWeirV2FactoryRedemptionView public immutable factory;
    WeirV2LaunchLocker public immutable locker;
    IPositionManager public immutable positionManager;
    WeirV2MemeHook public immutable memeHook;

    mapping(address token => RedemptionState) public states;
    mapping(address token => mapping(address account => uint256 amount)) public redeemed;

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert NotFactory();
        _;
    }

    constructor(address factory_, WeirV2LaunchLocker locker_, IPositionManager positionManager_, WeirV2MemeHook memeHook_) {
        if (
            factory_ == address(0) || address(locker_) == address(0) || address(positionManager_) == address(0)
                || address(memeHook_) == address(0)
        ) revert ZeroAddress();
        factory = IWeirV2FactoryRedemptionView(factory_);
        locker = locker_;
        positionManager = positionManager_;
        memeHook = memeHook_;
    }

    // ---------------------------------------------------------------------
    // Membership
    // ---------------------------------------------------------------------

    /**
     * @notice Tokens `account` contributed to this launch: bought on the
     * bonding curve (net of sells) plus delivered through a filled
     * commitment. This is the account's lifetime redemption allowance.
     */
    function contribution(address token, address account) public view returns (uint256 total) {
        IWeirV2LaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        if (!launch.exists) return 0;
        total = WeirV2BondingCurve(payable(launch.curve)).curveBought(account);
        WeirV2CommitmentRegistry registry = factory.commitmentRegistry();
        if (address(registry) != address(0) && registry.hasCampaign(token)) {
            total += registry.getCommitment(token, account).filledTokens;
        }
    }

    /**
     * @notice Contribution not yet redeemed.
     */
    function eligibleTokens(address token, address account) public view returns (uint256) {
        uint256 total = contribution(token, account);
        uint256 used = redeemed[token][account];
        return total > used ? total - used : 0;
    }

    /**
     * @notice Whether `account` helped build this launch and may vote on its
     * futarchy markets. Read by WeirV2FutarchyProposal as the trade gate.
     */
    function isMember(address token, address account) external view returns (bool) {
        return contribution(token, account) != 0;
    }

    /**
     * @notice Liquidity still redeemable under the 40% ceiling.
     */
    function remainingRedeemableLiquidity(address token) public view returns (uint128) {
        RedemptionState storage s = states[token];
        if (!s.unlocked) return 0;
        uint128 cap = uint128((uint256(s.liquidityAtUnlock) * MAX_REDEEMABLE_BPS) / BASIS_POINTS);
        return cap > s.liquidityRedeemed ? cap - s.liquidityRedeemed : 0;
    }

    /**
     * @notice Preview of what burning `amount` would remove and pay right now.
     */
    function previewRedeem(address token, uint256 amount)
        external
        view
        returns (uint128 liquidityRemoved, uint128 liquidityRemaining)
    {
        (uint256 tokenId,) = _position(token);
        liquidityRemoved = _liquidityFor(tokenId, token, amount);
        liquidityRemaining = remainingRedeemableLiquidity(token);
    }

    // ---------------------------------------------------------------------
    // Futarchy wiring
    // ---------------------------------------------------------------------

    /**
     * @notice Binds the one proposal allowed to unlock redemption for
     * `token`. Called by the factory when it deploys the proposal, so a
     * look-alike contract can never unlock a pool.
     */
    function registerProposal(address token, address proposal) external onlyFactory {
        if (proposal == address(0)) revert ZeroAddress();
        RedemptionState storage s = states[token];
        if (s.proposal != address(0)) revert ProposalAlreadySet();
        s.proposal = proposal;
        emit ProposalRegistered(token, proposal);
    }

    /**
     * @notice Called by the registered proposal once PASS has won. Snapshots
     * the position's liquidity; 40% of it becomes the redeemable budget.
     */
    function unlockRedemption(address token) external {
        RedemptionState storage s = states[token];
        if (msg.sender != s.proposal) revert NotProposal();
        if (s.unlocked) revert AlreadyUnlocked();
        (uint256 tokenId,) = _position(token);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        s.unlocked = true;
        s.liquidityAtUnlock = liquidity;
        emit RedemptionUnlocked(token, liquidity, uint128((uint256(liquidity) * MAX_REDEEMABLE_BPS) / BASIS_POINTS));
    }

    // ---------------------------------------------------------------------
    // Redemption
    // ---------------------------------------------------------------------

    /**
     * @notice Burns `amount` of the caller's tokens and pays their pro-rata
     * share of the pool's quote. Caller must be a member with enough
     * unredeemed contribution.
     */
    function redeem(address token, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return _redeem(token, msg.sender, amount, minQuoteOut);
    }

    /**
     * @notice Same as `redeem`, invoked by the pool's staking vault on behalf
     * of a staker exiting early through `burnAndExit`. The vault has already
     * approved this contract for `amount`.
     */
    function redeemFor(address token, address account, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        (, PoolKey memory key) = _position(token);
        if (msg.sender != address(memeHook.stakingVaults(key.toId()))) revert NotStakingVault();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return _redeem(token, account, amount, minQuoteOut);
    }

    function _redeem(address token, address account, uint256 amount, uint256 minQuoteOut)
        private
        returns (uint256 quoteOut)
    {
        if (amount == 0) revert ZeroAmount();
        RedemptionState storage s = states[token];
        if (!s.unlocked) revert NotUnlocked();

        uint256 eligible = eligibleTokens(token, account);
        if (eligible == 0) revert NotMember();
        if (amount > eligible) revert ExceedsContribution(amount, eligible);

        (uint256 tokenId, PoolKey memory key) = _position(token);
        uint128 liquidity = _liquidityFor(tokenId, token, amount);
        uint128 remaining = remainingRedeemableLiquidity(token);
        if (liquidity == 0) revert ZeroAmount();
        if (liquidity > remaining) revert RedemptionCapReached(liquidity, remaining);

        address quote = Currency.unwrap(key.currency0) == token
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 quoteBefore = _quoteBalance(quote);
        locker.redeemLiquidity(token, liquidity, address(this));
        uint256 tokensFromPool = IERC20(token).balanceOf(address(this)) - tokenBefore;
        quoteOut = _quoteBalance(quote) - quoteBefore;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        // Burn the redeemer's tokens and the pool-side tokens that came out
        // with the liquidity, so supply falls by both and price is untouched.
        uint256 toBurn = amount + tokensFromPool;
        IERC20BurnableRedeem(token).burn(toBurn);

        redeemed[token][account] += amount;
        s.liquidityRedeemed += liquidity;
        s.quotePaid += quoteOut;
        s.tokensBurned += toBurn;

        _sendQuote(quote, account, quoteOut);
        emit Redeemed(token, account, toBurn, liquidity, quoteOut);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _position(address token) private view returns (uint256 tokenId, PoolKey memory key) {
        if (!locker.isLocked(token)) revert PositionNotLocked();
        tokenId = locker.lockedPositions(token);
        (key,) = positionManager.getPoolAndPositionInfo(tokenId);
    }

    /**
     * @dev Liquidity share for burning `amount`: `amount / totalSupply` of
     * the position's current liquidity.
     */
    function _liquidityFor(uint256 tokenId, address token, uint256 amount) private view returns (uint128) {
        uint128 current = positionManager.getPositionLiquidity(tokenId);
        uint256 supply = IERC20(token).totalSupply();
        if (supply == 0) return 0;
        return uint128(Math.mulDiv(current, amount, supply));
    }

    function _quoteBalance(address quote) private view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    function _sendQuote(address quote, address to, uint256 amount) private {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    /// @notice Accepts native quote taken out of the position.
    receive() external payable {}
}
