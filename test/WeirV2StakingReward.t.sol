// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {IWeirV2FeeEscrow} from "../src/interfaces/ILaunchpadV2.sol";

/// @dev Minimal burnable ERC-20 standing in for WeirV2LauncherToken, which
/// already carries the exact ERC20Burnable surface burnAndExit depends on.
contract MockMemecoin is ERC20, ERC20Burnable {
    constructor() ERC20("Mock Meme", "MEME") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal ERC-20 standing in for a pool's ERC-20 quote currency.
contract MockQuoteToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Records every credit call instead of implementing real claimable
/// balances, so tests can assert exactly what the vault tried to pay out
/// without needing the full escrow's claim/withdraw machinery.
contract MockFeeEscrow is IWeirV2FeeEscrow {
    mapping(address => uint256) public nativeCredited;
    mapping(address => mapping(address => uint256)) public tokenCredited;

    function credit(address recipient) external payable override {
        nativeCredited[recipient] += msg.value;
    }

    function creditToken(address recipient, address token, uint256 amount) external override {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenCredited[recipient][token] += amount;
    }

    function claim() external pure override returns (uint256) {
        return 0;
    }

    function claim(uint256) external pure override returns (uint256) {
        return 0;
    }

    function claimToken(address) external pure override returns (uint256) {
        return 0;
    }

    function claimToken(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address recipient) external view override returns (uint256) {
        return nativeCredited[recipient];
    }

    function balanceOfToken(address recipient, address token) external view override returns (uint256) {
        return tokenCredited[recipient][token];
    }
}

/// @notice Native-ETH quote currency variant: WeirV2StakingReward.notifyReward
/// takes msg.value, and _settle pays out through IWeirV2FeeEscrow.credit.
contract WeirV2StakingRewardNativeTest is Test {
    WeirV2StakingReward internal vault;
    MockMemecoin internal memecoin;
    MockFeeEscrow internal escrow;

    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        memecoin = new MockMemecoin();
        escrow = new MockFeeEscrow();
        vault = new WeirV2StakingReward(hook, IERC20(address(memecoin)), address(0), escrow);

        memecoin.mint(alice, 1_000e18);
        memecoin.mint(bob, 1_000e18);
        vm.prank(alice);
        memecoin.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        memecoin.approve(address(vault), type(uint256).max);

        vm.deal(hook, 100 ether);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(WeirV2StakingReward.ZeroAddress.selector);
        new WeirV2StakingReward(address(0), IERC20(address(memecoin)), address(0), escrow);

        vm.expectRevert(WeirV2StakingReward.ZeroAddress.selector);
        new WeirV2StakingReward(hook, IERC20(address(0)), address(0), escrow);

        vm.expectRevert(WeirV2StakingReward.ZeroAddress.selector);
        new WeirV2StakingReward(hook, IERC20(address(memecoin)), address(0), IWeirV2FeeEscrow(address(0)));
    }

    function test_stake_transfersInAndSetsUnlock() public {
        vm.prank(alice);
        vault.stake(100e18);

        (uint256 amount, uint256 rewardDebt, uint256 unlockTime) = vault.users(alice);
        assertEq(amount, 100e18);
        assertEq(rewardDebt, 0);
        assertEq(unlockTime, block.timestamp + vault.UNLOCK_PERIOD());
        assertEq(vault.totalStaked(), 100e18);
        assertEq(memecoin.balanceOf(address(vault)), 100e18);
        assertEq(memecoin.balanceOf(alice), 900e18);
    }

    function test_stake_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_stake_topUp_rearmsUnlockAndKeepsAccrual() public {
        vm.prank(alice);
        vault.stake(100e18);

        // Fund a reward while only alice is staked, then let time pass
        // partway through the lock before she tops up.
        vm.prank(hook);
        vault.notifyReward{value: 10 ether}(10 ether);

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vault.stake(50e18);

        // Top-up settles the first reward into the escrow immediately.
        assertEq(escrow.nativeCredited(alice), 10 ether);

        (uint256 amount,, uint256 unlockTime) = vault.users(alice);
        assertEq(amount, 150e18);
        assertEq(unlockTime, block.timestamp + vault.UNLOCK_PERIOD());
    }

    function test_unstake_revertsBeforeUnlock() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.TooEarlyToUnstake.selector);
        vault.unstake(50e18);
    }

    function test_unstake_succeedsAfterUnlockAndReturnsStake() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.unstake(40e18);

        (uint256 amount,,) = vault.users(alice);
        assertEq(amount, 60e18);
        assertEq(vault.totalStaked(), 60e18);
        assertEq(memecoin.balanceOf(alice), 940e18);
    }

    function test_unstake_revertsOnInsufficientStake() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.InsufficientStake.selector);
        vault.unstake(101e18);
    }

    function test_unstake_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.ZeroAmount.selector);
        vault.unstake(0);
    }

    function test_notifyReward_onlyHook() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.expectRevert(WeirV2StakingReward.NotHook.selector);
        vault.notifyReward{value: 1 ether}(1 ether);
    }

    function test_notifyReward_revertsOnValueMismatch() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(hook);
        vm.expectRevert(WeirV2StakingReward.NativeValueMismatch.selector);
        vault.notifyReward{value: 1 ether}(2 ether);
    }

    function test_notifyReward_noOpWhenNobodyStaked() public {
        vm.prank(hook);
        bool distributed = vault.notifyReward{value: 5 ether}(5 ether);
        assertFalse(distributed);
        assertEq(vault.accRewardPerShare(), 0);
    }

    function test_notifyReward_distributesProportionally() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(300e18);

        vm.prank(hook);
        bool distributed = vault.notifyReward{value: 8 ether}(8 ether);
        assertTrue(distributed);

        // alice: 100/400 * 8 = 2 ether, bob: 300/400 * 8 = 6 ether
        assertApproxEqAbs(vault.pendingReward(alice), 2 ether, 1);
        assertApproxEqAbs(vault.pendingReward(bob), 6 ether, 1);
    }

    function test_harvest_paysAccruedRewardViaEscrow() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(hook);
        vault.notifyReward{value: 4 ether}(4 ether);

        vm.prank(alice);
        vault.harvest();

        assertEq(escrow.nativeCredited(alice), 4 ether);
        assertEq(vault.pendingReward(alice), 0);
    }

    function test_harvest_noOpWhenNothingAccrued() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.harvest();
        assertEq(escrow.nativeCredited(alice), 0);
    }

    function test_setFutarchyProposal_onlyOnce() public {
        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);
        assertEq(vault.futarchyProposal(), proposal);

        vm.expectRevert(WeirV2StakingReward.FutarchyProposalAlreadySet.selector);
        vault.setFutarchyProposal(makeAddr("other"));
    }

    function test_setFutarchyProposal_revertsOnZeroAddress() public {
        vm.expectRevert(WeirV2StakingReward.ZeroAddress.selector);
        vault.setFutarchyProposal(address(0));
    }

    function test_unlockEarlyExit_onlyFutarchyProposal() public {
        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);

        vm.expectRevert(WeirV2StakingReward.NotFutarchyProposal.selector);
        vault.unlockEarlyExit();

        vm.prank(proposal);
        vault.unlockEarlyExit();
        assertTrue(vault.earlyExitUnlocked());
    }

    function test_burnAndExit_revertsBeforeUnlock() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.EarlyExitNotUnlocked.selector);
        vault.burnAndExit(50e18);
    }

    function test_burnAndExit_burnsTokensAndPaysRewardWithoutWaitingForLock() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(hook);
        vault.notifyReward{value: 5 ether}(5 ether);

        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);
        vm.prank(proposal);
        vault.unlockEarlyExit();

        uint256 supplyBefore = memecoin.totalSupply();

        // Still inside the 7-day lock: burnAndExit must not require it.
        vm.prank(alice);
        vault.burnAndExit(60e18);

        assertEq(memecoin.totalSupply(), supplyBefore - 60e18);
        assertEq(memecoin.balanceOf(address(vault)), 40e18);
        (uint256 amount,,) = vault.users(alice);
        assertEq(amount, 40e18);
        assertEq(vault.totalStaked(), 40e18);
        assertEq(escrow.nativeCredited(alice), 5 ether);
    }

    function test_burnAndExit_revertsOnInsufficientStake() public {
        vm.prank(alice);
        vault.stake(100e18);

        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);
        vm.prank(proposal);
        vault.unlockEarlyExit();

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.InsufficientStake.selector);
        vault.burnAndExit(101e18);
    }

    function test_burnAndExit_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.stake(100e18);
        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);
        vm.prank(proposal);
        vault.unlockEarlyExit();

        vm.prank(alice);
        vm.expectRevert(WeirV2StakingReward.ZeroAmount.selector);
        vault.burnAndExit(0);
    }

    function test_pendingReward_zeroWithNoStakeOrReward() public {
        assertEq(vault.pendingReward(alice), 0);
    }
}

/// @notice ERC-20 quote currency variant: notifyReward pulls via
/// safeTransferFrom and _settle pays out through creditToken instead of
/// native credit.
contract WeirV2StakingRewardErc20QuoteTest is Test {
    WeirV2StakingReward internal vault;
    MockMemecoin internal memecoin;
    MockQuoteToken internal quote;
    MockFeeEscrow internal escrow;

    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");

    function setUp() public {
        memecoin = new MockMemecoin();
        quote = new MockQuoteToken();
        escrow = new MockFeeEscrow();
        vault = new WeirV2StakingReward(hook, IERC20(address(memecoin)), address(quote), escrow);

        memecoin.mint(alice, 1_000e18);
        vm.prank(alice);
        memecoin.approve(address(vault), type(uint256).max);

        quote.mint(hook, 1_000e18);
        vm.prank(hook);
        quote.approve(address(vault), type(uint256).max);
    }

    function test_notifyReward_pullsErc20FromHook() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(hook);
        bool distributed = vault.notifyReward(10e18);
        assertTrue(distributed);
        assertEq(quote.balanceOf(address(vault)), 10e18);
    }

    function test_harvest_paysErc20RewardViaCreditToken() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(hook);
        vault.notifyReward(10e18);

        vm.prank(alice);
        vault.harvest();

        assertEq(escrow.tokenCredited(alice, address(quote)), 10e18);
        assertEq(quote.balanceOf(address(escrow)), 10e18);
    }

    function test_burnAndExit_paysErc20Reward() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(hook);
        vault.notifyReward(10e18);

        address proposal = makeAddr("proposal");
        vault.setFutarchyProposal(proposal);
        vm.prank(proposal);
        vault.unlockEarlyExit();

        vm.prank(alice);
        vault.burnAndExit(100e18);

        assertEq(escrow.tokenCredited(alice, address(quote)), 10e18);
        assertEq(memecoin.balanceOf(address(vault)), 0);
        assertEq(vault.totalStaked(), 0);
    }
}
