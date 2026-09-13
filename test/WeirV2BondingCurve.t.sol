// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2BondingCurve} from "../src/WeirV2BondingCurve.sol";
import {WeirV2LauncherToken} from "../src/WeirV2LauncherToken.sol";
import {WeirV2BuybackVault} from "../src/WeirV2BuybackVault.sol";
import {FeePolicySnapshot} from "../src/interfaces/ILaunchpadV2.sol";
import {MockUSDC, MockFeePolicy, MockFeeEscrowFull, MockBuybackVault} from "./support/Mocks.sol";

/// @notice TestCase §2: WeirV2BondingCurve partitions and trading gate.
/// The factory here is the test contract itself (curves are constructed with
/// factory_ = address(this)).
contract WeirV2BondingCurveTest is Test {
    MockUSDC internal usdc;
    MockFeePolicy internal feePolicy;
    MockFeeEscrowFull internal escrow;
    MockBuybackVault internal vault;
    FeePolicySnapshot internal policy;

    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant PHANTOM = 10_000e6;
    uint256 internal constant THRESHOLD = 40_000e6;

    event CommittedTokensReleased(address indexed to, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        feePolicy = new MockFeePolicy();
        escrow = new MockFeeEscrowFull();
        vault = new MockBuybackVault();
        policy = FeePolicySnapshot({
            protocolFeeRecipient: creator,
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300,
            stakerFeeShareBps: 4000
        });
        feePolicy.setOperator(address(this), true);

        usdc.mint(buyer, 10_000_000e6);
    }

    /// @dev Deploys a curve + token pair; the token mints SUPPLY to the curve.
    function _deploy(
        uint256 supply,
        uint256 phantom,
        uint256 threshold,
        uint256 feeBps,
        uint256 snipeStart,
        uint256 snipeSecs,
        bool buybackEnabled
    ) internal returns (WeirV2BondingCurve curve, WeirV2LauncherToken token) {
        curve = new WeirV2BondingCurve(
            address(usdc),
            creator,
            address(this),
            feePolicy,
            policy,
            escrow,
            WeirV2BuybackVault(address(vault)),
            phantom,
            feeBps,
            0,
            buybackEnabled,
            threshold,
            snipeStart,
            snipeSecs
        );
        token = new WeirV2LauncherToken(
            "Weir",
            "WEIR",
            "",
            "",
            WeirV2LauncherToken.Socials("", "", "", "", ""),
            creator,
            address(curve),
            address(this),
            supply
        );
    }

    function _buy(WeirV2BondingCurve curve, uint256 quoteIn) internal returns (uint256) {
        vm.startPrank(buyer);
        usdc.approve(address(curve), quoteIn);
        uint256 out = curve.buy(quoteIn, 0, buyer);
        vm.stopPrank();
        return out;
    }

    // 2.1: plain initialize leaves economics untouched.
    function test_initialize_plainUnchanged() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        curve.initialize(address(token));

        assertEq(curve.committedTokens(), 0);
        assertEq(curve.tradingOpensAt(), 0);
        assertEq(curve.trackedTokens(), SUPPLY);
        uint256 expectedReserved = (SUPPLY * PHANTOM) / (PHANTOM + THRESHOLD);
        assertEq(curve.reservedTokens(), expectedReserved);
    }

    // 2.2: campaign initialize partitions the tranche off the public curve.
    function test_initialize_withTranche() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        uint256 committed = SUPPLY / 4;
        uint256 opensAt = block.timestamp + 2 days;
        curve.initialize(address(token), committed, opensAt);

        assertEq(curve.committedTokens(), committed);
        assertEq(curve.trackedTokens(), SUPPLY - committed);
        uint256 expectedReserved = ((SUPPLY - committed) * PHANTOM) / (PHANTOM + THRESHOLD);
        assertEq(curve.reservedTokens(), expectedReserved);
        assertEq(curve.tradingOpensAt(), opensAt);
        assertEq(curve.launchedAt(), opensAt);
    }

    // 2.3: a tranche at or above supply reverts.
    function test_initialize_committedTooLarge() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        vm.expectRevert(WeirV2BondingCurve.CommittedTokensTooLarge.selector);
        curve.initialize(address(token), SUPPLY, block.timestamp + 2 days);
    }

    // 2.4: a tranche that rounds the reserve away reverts.
    function test_initialize_trancheLeavesReservedZero() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(1000, PHANTOM, THRESHOLD, 0, 0, 0, false);
        // publicSupply = 1 wei -> reserved rounds to 0.
        vm.expectRevert(WeirV2BondingCurve.InvalidLaunchEconomics.selector);
        curve.initialize(address(token), 999, block.timestamp + 2 days);
    }

    // 2.5: buys are gated on the open time, then succeed exactly at it.
    function test_buy_beforeOpenRevertsAtOpenSucceeds() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        uint256 opensAt = block.timestamp + 1 days;
        curve.initialize(address(token), SUPPLY / 10, opensAt);

        vm.startPrank(buyer);
        usdc.approve(address(curve), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(WeirV2BondingCurve.TradingNotOpen.selector, opensAt));
        curve.buy(1000e6, 0, buyer);
        vm.stopPrank();

        vm.warp(opensAt);
        uint256 out = _buy(curve, 1000e6);
        assertGt(out, 0);
    }

    // 2.6: sells are gated on the open time too.
    function test_sell_beforeOpenReverts() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        uint256 opensAt = block.timestamp + 1 days;
        curve.initialize(address(token), 0, opensAt);

        // Gate is checked before any token movement, so the seller needs no balance.
        vm.expectRevert(abi.encodeWithSelector(WeirV2BondingCurve.TradingNotOpen.selector, opensAt));
        curve.sell(1e18, 0, buyer);
    }

    // 2.7: snipe tax peaks before the open (no underflow) and decays from it.
    function test_snipeTax_beforeOpenPeakAndDecay() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 1000, 100, false);
        uint256 opensAt = block.timestamp + 1 days;
        curve.initialize(address(token), 0, opensAt);

        assertEq(curve.currentSnipeTaxBps(buyer), 1000);

        vm.warp(opensAt);
        assertEq(curve.currentSnipeTaxBps(buyer), 1000);
        vm.warp(opensAt + 50);
        assertEq(curve.currentSnipeTaxBps(buyer), 500);
        vm.warp(opensAt + 100);
        assertEq(curve.currentSnipeTaxBps(buyer), 0);
    }

    /// @dev Curve opened immediately with a 10% tranche, bought out in one
    /// oversized trade (clamped + refunded, auto-graduation fails benignly
    /// because this test contract exposes no graduate()).
    function _readyCurve(bool withTranche)
        internal
        returns (WeirV2BondingCurve curve, WeirV2LauncherToken token, uint256 committed)
    {
        (curve, token) = _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        committed = withTranche ? SUPPLY / 10 : 0;
        curve.initialize(address(token), committed, 0);
        _buy(curve, THRESHOLD * 10);
        assertTrue(curve.readyToGraduate());
    }

    // 2.8: buying out the public partition never touches the tranche.
    function test_trancheUntouchableOnGraduation() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token, uint256 committed) = _readyCurve(true);

        assertEq(curve.sellableTokens(), 0);
        assertEq(curve.committedTokens(), committed);
        (, uint256 tokenReserve) = curve.getReserves();
        assertEq(tokenReserve, curve.reservedTokens());
        assertEq(token.balanceOf(address(curve)), curve.reservedTokens() + committed);
    }

    // 2.9: graduation lands on the same quote reserve with or without a tranche.
    function test_graduationPriceUnchangedByTranche() public {
        (WeirV2BondingCurve plain,,) = _readyCurve(false);
        (WeirV2BondingCurve withTranche,,) = _readyCurve(true);

        uint256 reservePlain = plain.realQuoteReserve();
        uint256 reserveTranched = withTranche.realQuoteReserve();
        assertApproxEqAbs(reservePlain, reserveTranched, 1e6);
        assertApproxEqRel(reservePlain, THRESHOLD, 0.001e18);
        assertApproxEqRel(reserveTranched, THRESHOLD, 0.001e18);
    }

    // 2.10: releaseCommittedTokens access control.
    function test_releaseCommittedTokens_access() public {
        (WeirV2BondingCurve curve,,) = _readyCurve(true);

        vm.prank(stranger);
        vm.expectRevert(WeirV2BondingCurve.NotFactory.selector);
        curve.releaseCommittedTokens(stranger);

        vm.expectRevert(WeirV2BondingCurve.ZeroAddress.selector);
        curve.releaseCommittedTokens(address(0));

        // Not ready on a fresh curve.
        (WeirV2BondingCurve fresh, WeirV2LauncherToken freshToken) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 0, 0, 0, false);
        fresh.initialize(address(freshToken), SUPPLY / 10, 0);
        vm.expectRevert(WeirV2BondingCurve.NotReadyToGraduate.selector);
        fresh.releaseCommittedTokens(stranger);

        // Graduated curves refuse too.
        curve.graduate(address(this));
        vm.expectRevert(WeirV2BondingCurve.AlreadyGraduated.selector);
        curve.releaseCommittedTokens(stranger);
    }

    // 2.11: release effect — exact transfer, zeroed field, event, idempotent.
    function test_releaseCommittedTokens_effect() public {
        (WeirV2BondingCurve curve, WeirV2LauncherToken token, uint256 committed) = _readyCurve(true);

        vm.expectEmit(true, false, false, true);
        emit CommittedTokensReleased(stranger, committed);
        uint256 released = curve.releaseCommittedTokens(stranger);

        assertEq(released, committed);
        assertEq(token.balanceOf(stranger), committed);
        assertEq(curve.committedTokens(), 0);

        uint256 releasedAgain = curve.releaseCommittedTokens(stranger);
        assertEq(releasedAgain, 0);
        assertEq(token.balanceOf(stranger), committed);
    }

    // 2.12: the internal fee buyback is bounded by sellableTokens and can
    // never lock tranche tokens.
    function test_internalBuybackNeverEatsTranche() public {
        uint256 committed = SUPPLY / 10;
        (WeirV2BondingCurve curve, WeirV2LauncherToken token) =
            _deploy(SUPPLY, PHANTOM, THRESHOLD, 100, 0, 0, true);
        curve.initialize(address(token), committed, 0);

        _buy(curve, 1000e6);
        _buy(curve, 1000e6);
        assertGt(curve.quoteFeeBalance(), 0);

        curve.sweepFees(1);
        assertGt(vault.totalLocked(), 0);
        assertEq(curve.committedTokens(), committed);
        assertGe(curve.trackedTokens(), curve.reservedTokens());
    }
}
