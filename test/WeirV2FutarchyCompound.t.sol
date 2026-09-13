// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {WeirV2StakingVaultDeployer} from "../src/WeirV2StakingVaultDeployer.sol";
import {WeirV2FutarchyProposal} from "../src/WeirV2FutarchyProposal.sol";
import {BinaryMarket} from "../src/MemePredictionMarket/Binary.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";
import {SwapVMOrderLib} from "../src/libraries/SwapVMOrderLib.sol";
import {MockBurnableToken, MockFeeEscrowFull, MockHookPolicy} from "./support/Mocks.sol";
import {MockSwapVM} from "./support/MockSwapVM.sol";

/// @notice TestCase §7: futarchy regression on auto-compounding vaults.
contract WeirV2FutarchyCompoundTest is Test {
    MockBurnableToken internal meme;
    MockFeeEscrowFull internal escrow;
    MockHookPolicy internal hook;
    MockSwapVM internal router;
    WeirV2StakingReward internal vault;

    address internal weth = makeAddr("weth");
    address internal staker = makeAddr("staker");
    address internal maker = makeAddr("maker7");
    address internal believer = makeAddr("believer");

    function setUp() public {
        meme = new MockBurnableToken("Meme", "MEME");
        escrow = new MockFeeEscrowFull();
        hook = new MockHookPolicy();
        router = new MockSwapVM(weth);
        vault = new WeirV2StakingReward(address(hook), IERC20(address(meme)), address(0), escrow);

        meme.mint(staker, 10_000e18);
        meme.mint(maker, 1_000_000e18);
        vm.prank(staker);
        meme.approve(address(vault), type(uint256).max);
        vm.prank(maker);
        meme.approve(address(router), type(uint256).max);

        vm.deal(address(hook), 100 ether);
        vm.deal(address(this), 10 ether);
        vm.deal(believer, 10 ether);
        vm.prank(address(hook));
        vault.setCompoundRouter(ISwapVM(address(router)), weth);
    }

    /// @dev Resolves a PASS verdict for a proposal wired to the vault.
    function _passProposal() internal returns (WeirV2FutarchyProposal proposal) {
        proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault), address(this));
        vm.prank(address(hook));
        vault.setFutarchyProposal(address(proposal));

        BinaryMarket passMarket = proposal.passMarket();
        // Read the outcome BEFORE pranking: even a view staticcall would
        // consume the prank and leave swapIn sender as this contract.
        uint256 yes = passMarket.OUTCOME_YES();
        vm.prank(believer);
        passMarket.swapIn{value: 0.1 ether}(yes, 1e16, 0.1 ether);
        vm.warp(proposal.closesAt());
        proposal.finalize();
        assertTrue(proposal.passed());
        assertTrue(vault.earlyExitUnlocked());
    }

    // 7.1: a staker who compounded exits with the full grown stake on PASS.
    function test_compoundedStake_burnAndExitAfterPass() public {
        vm.prank(staker);
        vault.stake(100e18);
        vm.prank(staker);
        vault.setAutoCompound(true);
        vm.prank(address(hook));
        vault.notifyReward{value: 2 ether}(2 ether);
        vm.prank(staker);
        vault.harvest();

        (address tokenA, address tokenB,) = SwapVMOrderLib.sortTokens(weth, address(meme));
        ISwapVM.Order memory order = SwapVMOrderLib.buildOrder(
            maker, tokenA, tokenB, SwapVMOrderLib.limitOrderProgram(1, 0, 2 ether, 25e18, true), false
        );
        router.planFill(router.hash(order), address(0), address(meme), 0, 25e18);
        vm.prank(staker);
        vault.compound(staker, order, bytes(""), 0);

        (uint256 grown,,) = vault.users(staker);
        assertEq(grown, 125e18);

        _passProposal();

        uint256 supplyBefore = meme.totalSupply();
        vm.prank(staker);
        vault.burnAndExit(grown);

        assertEq(meme.totalSupply(), supplyBefore - grown);
        assertEq(vault.totalStaked(), 0);
    }

    // 7.2: a vault created via the staking-vault deployer (hook recorded,
    // never the deployer) takes a proposal and unlocks early exit.
    function test_deployerVault_takesProposal() public {
        address hookEOA = makeAddr("hookEOA");
        // Construct the deployer into a local first, then prank, then call:
        // a prank placed on the deployment expression would be consumed by
        // the constructor instead of deployVault.
        WeirV2StakingVaultDeployer deployer = new WeirV2StakingVaultDeployer(hookEOA);
        vm.prank(hookEOA);
        WeirV2StakingReward v = deployer.deployVault(IERC20(address(meme)), address(0), escrow);

        assertEq(v.hook(), hookEOA);
        assertTrue(address(v) != address(deployer));

        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(v), address(this));
        vm.prank(hookEOA);
        v.setFutarchyProposal(address(proposal));
        assertEq(v.futarchyProposal(), address(proposal));

        BinaryMarket passMarket = proposal.passMarket();
        uint256 yes = passMarket.OUTCOME_YES();
        vm.prank(believer);
        passMarket.swapIn{value: 0.1 ether}(yes, 1e16, 0.1 ether);
        vm.warp(proposal.closesAt());
        proposal.finalize();
        assertTrue(v.earlyExitUnlocked());
    }
}
