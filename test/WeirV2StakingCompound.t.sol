// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";
import {SwapVMOrderLib} from "../src/libraries/SwapVMOrderLib.sol";
import {MockUSDC, MockBurnableToken, MockSenderTaxQuote, MockFeeEscrowFull, MockHookPolicy} from "./support/Mocks.sol";
import {MockSwapVM} from "./support/MockSwapVM.sol";

/// @notice TestCase §6: WeirV2StakingReward auto-compound (ERC-20 quote).
contract WeirV2StakingCompoundTest is Test {
    MockBurnableToken internal meme;
    MockUSDC internal quote;
    MockFeeEscrowFull internal escrow;
    MockHookPolicy internal hook;
    MockSwapVM internal router;
    WeirV2StakingReward internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal maker = makeAddr("maker");

    event CompoundRouterSet(address swapVM, address weth);
    event AutoCompoundSet(address indexed user, bool enabled);
    event RewardHeldForCompound(address indexed user, uint256 amount);
    event Compounded(address indexed user, address indexed caller, uint256 quoteSpent, uint256 tokensRestaked);

    function setUp() public {
        meme = new MockBurnableToken("Meme", "MEME");
        quote = new MockUSDC();
        escrow = new MockFeeEscrowFull();
        hook = new MockHookPolicy();
        router = new MockSwapVM(makeAddr("weth"));
        vault = new WeirV2StakingReward(address(hook), IERC20(address(meme)), address(quote), escrow);

        meme.mint(alice, 10_000e18);
        meme.mint(bob, 10_000e18);
        meme.mint(maker, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(maker);
        meme.approve(address(router), type(uint256).max);

        quote.mint(address(hook), 10_000_000e6);
        vm.prank(address(hook));
        quote.approve(address(vault), type(uint256).max);
    }

    /// @dev Wires the router through the hook (onlyHook).
    function _wireRouter() internal {
        vm.prank(address(hook));
        vault.setCompoundRouter(ISwapVM(address(router)), makeAddr("weth"));
    }

    /// @dev Builds a maker order selling memecoin for the ERC-20 quote.
    function _makerOrder(uint256 payAmount, uint256 tokenAmount) internal view returns (ISwapVM.Order memory order) {
        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(address(quote), address(meme));
        bytes memory program = SwapVMOrderLib.limitOrderProgram(
            1, 0, payAmount == 0 ? 1 : payAmount, tokenAmount == 0 ? 1 : tokenAmount, address(quote) < address(meme)
        );
        order = SwapVMOrderLib.buildOrder(maker, tokenA, tokenB, program, false);
    }

    function _routerHash(ISwapVM.Order memory order) internal view returns (bytes32) {
        return router.hash(order);
    }

    // 6.1: setCompoundRouter gating — hook-only, once, native needs WETH.
    function test_setCompoundRouter_gating() public {
        vm.expectRevert(WeirV2StakingReward.NotHook.selector);
        vault.setCompoundRouter(ISwapVM(address(router)), address(0));

        vm.prank(address(hook));
        vm.expectEmit(false, false, false, true);
        emit CompoundRouterSet(address(router), address(111));
        vault.setCompoundRouter(ISwapVM(address(router)), address(111));

        vm.prank(address(hook));
        vm.expectRevert(WeirV2StakingReward.CompoundRouterAlreadySet.selector);
        vault.setCompoundRouter(ISwapVM(address(router)), address(111));

        WeirV2StakingReward nativeVault =
            new WeirV2StakingReward(address(hook), IERC20(address(meme)), address(0), escrow);
        vm.prank(address(hook));
        vm.expectRevert(WeirV2StakingReward.ZeroAddress.selector);
        nativeVault.setCompoundRouter(ISwapVM(address(router)), address(0));
    }

    // 6.2: opt-in without a router reverts.
    function test_optIn_withoutRouter() public {
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.CompoundNotConfigured.selector);
        vault.setAutoCompound(true);
    }

    /// @dev Stakes, opts in, accrues `reward` and harvests it into
    /// compoundable. Returns the held budget.
    function _heldBudget(address who, uint256 stakeAmt, uint256 reward) internal returns (uint256) {
        vm.prank(who);
        vault.stake(stakeAmt);
        vm.prank(who);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward(reward);
        vm.prank(who);
        vault.harvest();
        return vault.compoundable(who);
    }

    // 6.3: opting in settles the old (payout) mode first.
    function test_optIn_settlesOldMode() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(address(hook));
        vault.notifyReward(10_000e6);

        _wireRouter();
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit AutoCompoundSet(alice, true);
        vault.setAutoCompound(true);

        assertEq(escrow.tokenCredited(alice, address(quote)), 10_000e6);
        assertEq(vault.compoundable(alice), 0);
    }

    // 6.4: accrual while opted in is held, not paid; pending reads zero.
    function test_accrualWhileOptedIn_held() public {
        _wireRouter();
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward(10_000e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit RewardHeldForCompound(alice, 10_000e6);
        vault.harvest();

        assertEq(vault.compoundable(alice), 10_000e6);
        assertEq(escrow.tokenCredited(alice, address(quote)), 0);
        assertEq(vault.pendingReward(alice), 0);
    }

    // 6.5: opting out pays the held balance through the escrow.
    function test_optOut_paysHeldBalance() public {
        _wireRouter();
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward(10_000e6);
        vm.prank(alice);
        vault.harvest();
        assertEq(vault.compoundable(alice), 10_000e6);

        vm.prank(alice);
        vault.setAutoCompound(false);

        assertEq(vault.compoundable(alice), 0);
        assertEq(escrow.tokenCredited(alice, address(quote)), 10_000e6);
        assertFalse(vault.autoCompound(alice));
    }

    // 6.6: compound authorisation — staker, sweep operator, nobody else.
    function test_compound_authorisation() public {
        _wireRouter();
        uint256 budget = _heldBudget(alice, 100e18, 10_000e6);

        ISwapVM.Order memory order = _makerOrder(budget, 50e18);
        router.planFill(_routerHash(order), address(quote), address(meme), 0, 50e18);

        // Random caller is refused even with a valid order.
        vm.expectRevert(WeirV2StakingReward.NotCompoundOperator.selector);
        vault.compound(alice, order, bytes(""), 0);

        // The staker herself succeeds...
        vm.prank(alice);
        (uint256 spentSelf, uint256 gotSelf) = vault.compound(alice, order, bytes(""), 0);
        assertEq(spentSelf, budget);
        assertEq(gotSelf, 50e18);
    }

    // 6.6b: a fee-sweep operator may compound for an opted-in staker, but
    // an opted-out account refuses even the operator.
    function test_compound_operatorAndOptedOut() public {
        _wireRouter();
        hook.setOperator(keeper, true);
        uint256 budget = _heldBudget(alice, 100e18, 10_000e6);

        ISwapVM.Order memory order = _makerOrder(budget, 50e18);
        router.planFill(_routerHash(order), address(quote), address(meme), 0, 50e18);

        vm.prank(keeper);
        (uint256 spent, uint256 got) = vault.compound(alice, order, bytes(""), 0);
        assertEq(spent, budget);
        assertEq(got, 50e18);

        // Bob never opted in: the operator cannot compound for him.
        vm.prank(bob);
        vault.stake(100e18);
        vm.prank(keeper);
        vm.expectRevert(WeirV2StakingReward.AutoCompoundDisabled.selector);
        vault.compound(bob, order, bytes(""), 0);
    }

    // 6.7: nothing held means nothing to compound.
    function test_compound_nothingToCompound() public {
        _wireRouter();
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.setAutoCompound(true);

        ISwapVM.Order memory order = _makerOrder(10_000e6, 50e18);
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.NothingToCompound.selector);
        vault.compound(alice, order, bytes(""), 0);
    }

    // 6.8: the order pair must be exactly (quote, memecoin).
    function test_compound_orderTokenMismatch() public {
        _wireRouter();
        uint256 budget = _heldBudget(alice, 100e18, 10_000e6);
        assertGt(budget, 0);

        // Wrong tokens entirely.
        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(address(quote), address(meme));
        ISwapVM.Order memory wrong =
            SwapVMOrderLib.buildOrder(maker, tokenA, tokenB, SwapVMOrderLib.limitOrderProgram(1, 0, 1, 1, true), false);
        // Corrupt the pair by swapping in an unrelated address.
        wrong.data = bytes.concat(abi.encodePacked(address(9999), tokenB), hex"00");
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.OrderTokenMismatch.selector);
        vault.compound(alice, wrong, bytes(""), 0);

        // Truncated data.
        ISwapVM.Order memory short = ISwapVM.Order({maker: maker, traits: 0, data: hex"0011"});
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.OrderTokenMismatch.selector);
        vault.compound(alice, short, bytes(""), 0);
    }

    // 6.9: full ERC-20 fill restakes everything and rebases the debt.
    function test_compound_fullFillRestakes() public {
        _wireRouter();
        uint256 budget = _heldBudget(alice, 100e18, 10_000e6);
        (uint256 amountBefore,, uint256 unlockBefore) = vault.users(alice);

        ISwapVM.Order memory order = _makerOrder(budget, 50e18);
        router.planFill(_routerHash(order), address(quote), address(meme), 0, 50e18);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Compounded(alice, alice, budget, 50e18);
        (uint256 spent, uint256 restaked) = vault.compound(alice, order, bytes(""), 0);

        assertEq(spent, budget);
        assertEq(restaked, 50e18);
        (uint256 amountAfter,, uint256 unlockAfter) = vault.users(alice);
        assertEq(amountAfter, amountBefore + 50e18);
        // 6.12: compounding reinvests reward; the 7-day timer must not re-arm.
        assertEq(unlockAfter, unlockBefore);
        assertEq(vault.totalStaked(), amountBefore + 50e18);
        assertEq(vault.compoundable(alice), 0);
        assertEq(quote.allowance(address(vault), address(router)), 0);
        assertEq(vault.pendingReward(alice), 0);
    }
}

/// @notice TestCase §6 continued: native-quote fills, partial fills, guards,
/// accounting isolation and the fork placeholder.
contract WeirV2StakingCompoundNativeTest is Test {
    MockBurnableToken internal meme;
    MockFeeEscrowFull internal escrow;
    MockHookPolicy internal hook;
    MockSwapVM internal router;
    WeirV2StakingReward internal vault;

    address internal weth;
    address internal alice = makeAddr("aliceN");
    address internal bob = makeAddr("bobN");
    address internal maker = makeAddr("makerN");

    event Compounded(address indexed user, address indexed caller, uint256 quoteSpent, uint256 tokensRestaked);

    function setUp() public {
        meme = new MockBurnableToken("Meme", "MEME");
        escrow = new MockFeeEscrowFull();
        hook = new MockHookPolicy();
        weth = makeAddr("weth");
        router = new MockSwapVM(weth);
        vault = new WeirV2StakingReward(address(hook), IERC20(address(meme)), address(0), escrow);

        meme.mint(alice, 10_000e18);
        meme.mint(bob, 10_000e18);
        meme.mint(maker, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(maker);
        meme.approve(address(router), type(uint256).max);

        vm.deal(address(hook), 100 ether);
        vm.prank(address(hook));
        vault.setCompoundRouter(ISwapVM(address(router)), weth);
    }

    /// @dev Native maker order: the pair must be (WETH, memecoin).
    function _nativeOrder(uint256 payAmount, uint256 tokenAmount) internal view returns (ISwapVM.Order memory order) {
        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(weth, address(meme));
        bytes memory program = SwapVMOrderLib.limitOrderProgram(
            1, 0, payAmount == 0 ? 1 : payAmount, tokenAmount == 0 ? 1 : tokenAmount, weth < address(meme)
        );
        order = SwapVMOrderLib.buildOrder(maker, tokenA, tokenB, program, false);
    }

    /// @dev Stakes, opts in and harvests `rewardEth` of held ETH budget.
    function _heldEth(address who, uint256 stakeAmt, uint256 rewardEth) internal returns (uint256) {
        vm.prank(who);
        vault.stake(stakeAmt);
        vm.prank(who);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward{value: rewardEth}(rewardEth);
        vm.prank(who);
        vault.harvest();
        return vault.compoundable(who);
    }

    // 6.10: native fill spends ETH, refunds unspent, conserves the vault.
    function test_compound_nativeFill() public {
        uint256 budget = _heldEth(alice, 100e18, 2 ether);
        assertEq(address(vault).balance, 2 ether);

        ISwapVM.Order memory order = _nativeOrder(budget, 100e18);
        router.planFill(router.hash(order), address(0), address(meme), 0, 100e18);

        uint256 makerEthBefore = maker.balance;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Compounded(alice, alice, budget, 100e18);
        (uint256 spent, uint256 restaked) = vault.compound(alice, order, bytes(""), 0);

        assertEq(spent, budget);
        assertEq(restaked, 100e18);
        assertEq(vault.compoundable(alice), 0);
        assertEq(address(vault).balance, 0);
        assertEq(maker.balance, makerEthBefore);
        (uint256 amount,,) = vault.users(alice);
        assertEq(amount, 200e18);
    }

    // 6.11: partial native fill leaves the remainder compoundable.
    function test_compound_nativePartialFill() public {
        uint256 budget = _heldEth(alice, 100e18, 2 ether);

        ISwapVM.Order memory order = _nativeOrder(budget, 100e18);
        router.planFill(router.hash(order), address(0), address(meme), 1 ether, 50e18);

        vm.prank(alice);
        (uint256 spent, uint256 restaked) = vault.compound(alice, order, bytes(""), 0);

        assertEq(spent, 1 ether);
        assertEq(restaked, 50e18);
        assertEq(vault.compoundable(alice), budget - 1 ether);
        assertEq(vault.compoundable(alice), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    // 6.8b: native vaults only accept (WETH, memecoin) pairs.
    function test_compound_nativeOrderTokenMismatch() public {
        uint256 budget = _heldEth(alice, 100e18, 2 ether);
        assertGt(budget, 0);

        MockUSDC foreign = new MockUSDC();
        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(address(foreign), address(meme));
        ISwapVM.Order memory wrong =
            SwapVMOrderLib.buildOrder(maker, tokenA, tokenB, SwapVMOrderLib.limitOrderProgram(1, 0, 1, 1, true), false);
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.OrderTokenMismatch.selector);
        vault.compound(alice, wrong, bytes(""), 0);
    }

    // 6.13: router returning nothing for spent budget is bought-nothing.
    function test_compound_boughtNothing() public {
        _heldEth(alice, 100e18, 2 ether);

        ISwapVM.Order memory order = _nativeOrder(2 ether, 100e18);
        router.planFill(router.hash(order), address(0), address(meme), 0, 0);

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.CompoundBoughtNothing.selector);
        vault.compound(alice, order, bytes(""), 0);
    }

    // 6.14: held balances never move accRewardPerShare; others unaffected.
    function test_compound_accountingIsolation() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(100e18);
        vm.prank(alice);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward{value: 2 ether}(2 ether);
        vm.prank(alice);
        vault.harvest();

        uint256 accBefore = vault.accRewardPerShare();
        assertEq(vault.pendingReward(bob), 1 ether);

        ISwapVM.Order memory order = _nativeOrder(1 ether, 60e18);
        router.planFill(router.hash(order), address(0), address(meme), 0, 60e18);
        vm.prank(alice);
        vault.compound(alice, order, bytes(""), 0);

        assertEq(vault.accRewardPerShare(), accBefore);
        assertEq(vault.pendingReward(bob), 1 ether);
        vm.prank(bob);
        vault.harvest();
        assertEq(escrow.nativeCredited(bob), 1 ether);

        // Later rewards split over the grown stake normally (replicating the
        // accumulator's own flooring rather than assuming exact division).
        vm.prank(address(hook));
        vault.notifyReward{value: 2 ether}(2 ether);
        uint256 total = vault.totalStaked();
        assertEq(total, 260e18);
        // Exact accumulator replication: acc grows by amount*scale/total.
        uint256 accDelta = (2 ether * 1e18) / total;
        (uint256 bobAmount,,) = vault.users(bob);
        assertApproxEqAbs(vault.pendingReward(bob), (bobAmount * accDelta) / 1e18, 10);
    }

    // 6.16: fork fill against the official router (LimitSwap + Aqua XYC).
    // Needs FORK_RPC_URL plus funded maker orders on the official routers,
    // so it is recorded as a gated placeholder, not silently dropped.
    function test_fork_realRouterCompound() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP 6.16: no FORK_RPC_URL; needs official router + resting LimitSwap/XYC maker orders");
            vm.skip(true);
        }
        vm.skip(true);
    }
}

/// @notice TestCase 6.13 (overspend): a quote asset that debits the vault
/// more than the approved pull trips CompoundOverspent.
contract WeirV2StakingCompoundOverspendTest is Test {
    MockBurnableToken internal meme;
    MockSenderTaxQuote internal stax;
    MockFeeEscrowFull internal escrow;
    MockHookPolicy internal hook;
    MockSwapVM internal router;
    WeirV2StakingReward internal vault;

    address internal alice = makeAddr("aliceS");
    address internal maker = makeAddr("makerS");

    function setUp() public {
        meme = new MockBurnableToken("Meme", "MEME");
        stax = new MockSenderTaxQuote();
        escrow = new MockFeeEscrowFull();
        hook = new MockHookPolicy();
        router = new MockSwapVM(makeAddr("weth"));
        vault = new WeirV2StakingReward(address(hook), IERC20(address(meme)), address(stax), escrow);

        meme.mint(alice, 10_000e18);
        meme.mint(maker, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(maker);
        meme.approve(address(router), type(uint256).max);

        stax.mint(address(hook), 10_000_000e6 + 100);
        vm.prank(address(hook));
        stax.approve(address(vault), type(uint256).max);
        vm.prank(address(hook));
        vault.setCompoundRouter(ISwapVM(address(router)), makeAddr("weth"));
    }

    function test_compound_overspent() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(alice);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward(10_000e6);
        vm.prank(alice);
        vault.harvest();
        uint256 budget = vault.compoundable(alice);
        assertEq(budget, 10_000e6);
        // Dust so the sender-tax burn can land on top of the approved pull.
        stax.mint(address(vault), 1);

        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(address(stax), address(meme));
        ISwapVM.Order memory order = SwapVMOrderLib.buildOrder(
            maker, tokenA, tokenB, SwapVMOrderLib.limitOrderProgram(1, 0, budget, 50e18, true), false
        );
        router.planFill(router.hash(order), address(stax), address(meme), 0, 50e18);

        // The sender-tax debits 1 wei beyond the approved pull.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WeirV2StakingReward.CompoundOverspent.selector, budget + 1, budget));
        vault.compound(alice, order, bytes(""), 0);
    }
}
