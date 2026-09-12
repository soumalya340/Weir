// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {WeirV2FutarchyProposal} from "../src/WeirV2FutarchyProposal.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {IWeirV2FeeEscrow} from "../src/interfaces/ILaunchpadV2.sol";
import {BinaryMarket} from "../deps/degencalls_smartcontracts/src/Binary.sol";

contract MockMemecoin is ERC20, ERC20Burnable {
    constructor() ERC20("Mock Meme", "MEME") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

contract WeirV2FutarchyProposalTest is Test {
    WeirV2StakingReward internal vault;
    MockMemecoin internal memecoin;
    MockFeeEscrow internal escrow;

    address internal hook = makeAddr("hook");
    address internal proposerAddr = makeAddr("proposer");
    address internal yesBeliever = makeAddr("yesBeliever");
    address internal noBeliever = makeAddr("noBeliever");

    function setUp() public {
        memecoin = new MockMemecoin();
        escrow = new MockFeeEscrow();
        vault = new WeirV2StakingReward(hook, IERC20(address(memecoin)), address(0), escrow);

        vm.deal(proposerAddr, 10 ether);
        vm.deal(yesBeliever, 10 ether);
        vm.deal(noBeliever, 10 ether);
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(WeirV2FutarchyProposal.ZeroAddress.selector);
        new WeirV2FutarchyProposal{value: 0.01 ether}(address(0));
    }

    function test_constructor_revertsOnInsufficientBond() public {
        vm.expectRevert(WeirV2FutarchyProposal.InsufficientBond.selector);
        new WeirV2FutarchyProposal{value: 0.001 ether}(address(vault));
    }

    function test_constructor_deploysMarketsAndWiresVault() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));

        assertEq(vault.futarchyProposal(), address(proposal));
        assertTrue(address(proposal.passMarket()) != address(0));
        assertTrue(address(proposal.failMarket()) != address(0));
        assertTrue(address(proposal.passMarket()) != address(proposal.failMarket()));
        assertEq(proposal.closesAt(), block.timestamp + proposal.TRADING_WINDOW());
    }

    function test_constructor_revertsIfVaultAlreadyHasProposal() public {
        new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));

        vm.expectRevert(WeirV2StakingReward.FutarchyProposalAlreadySet.selector);
        new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
    }

    function test_finalize_revertsBeforeTradingWindowCloses() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));

        vm.expectRevert(WeirV2FutarchyProposal.TradingStillOpen.selector);
        proposal.finalize();
    }

    function test_finalize_revertsIfCalledTwice() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
        vm.warp(proposal.closesAt());
        proposal.finalize();

        vm.expectRevert(WeirV2FutarchyProposal.AlreadyFinalized.selector);
        proposal.finalize();
    }

    /// @dev Both markets start at 50/50 (qYes == qNo == 0), so with no
    /// trading at all neither price is strictly greater and the proposal
    /// must fail closed rather than unlock early exit by default.
    function test_finalize_noTrading_failsClosed() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
        vm.warp(proposal.closesAt());

        proposal.finalize();

        assertTrue(proposal.finalized());
        assertFalse(proposal.passed());
        assertFalse(vault.earlyExitUnlocked());
    }

    function test_finalize_passMarketPricedHigher_unlocksEarlyExit() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
        BinaryMarket passMarket = proposal.passMarket();

        // Buy YES on the pass market only, pushing its implied YES price
        // above the untouched fail market's 50/50 price.
        vm.prank(yesBeliever);
        passMarket.swapIn{value: 0.1 ether}(passMarket.OUTCOME_YES(), 1e16, 0.1 ether);

        vm.warp(proposal.closesAt());
        proposal.finalize();

        assertTrue(proposal.finalized());
        assertTrue(proposal.passed());
        assertTrue(vault.earlyExitUnlocked());
        assertTrue(passMarket.isResolved());
        assertTrue(proposal.failMarket().isResolved());
    }

    function test_finalize_failMarketPricedHigher_leavesVaultLocked() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
        BinaryMarket failMarket = proposal.failMarket();

        vm.prank(noBeliever);
        failMarket.swapIn{value: 0.1 ether}(failMarket.OUTCOME_YES(), 1e16, 0.1 ether);

        vm.warp(proposal.closesAt());
        proposal.finalize();

        assertFalse(proposal.passed());
        assertFalse(vault.earlyExitUnlocked());
    }

    function test_returnBond_revertsBeforeTradingCloses() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));

        vm.expectRevert(WeirV2FutarchyProposal.TradingStillOpen.selector);
        proposal.returnBond();
    }

    function test_returnBond_paysProposerOnceAfterClose() public {
        vm.prank(proposerAddr);
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));

        vm.warp(proposal.closesAt());
        uint256 balanceBefore = proposerAddr.balance;
        proposal.returnBond();
        assertEq(proposerAddr.balance, balanceBefore + 0.01 ether);

        vm.expectRevert(WeirV2FutarchyProposal.BondAlreadyReturned.selector);
        proposal.returnBond();
    }

    function test_burnAndExit_worksEndToEndAfterPassResolution() public {
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault));
        BinaryMarket passMarket = proposal.passMarket();

        memecoin.mint(yesBeliever, 100e18);
        vm.prank(yesBeliever);
        memecoin.approve(address(vault), type(uint256).max);
        vm.prank(yesBeliever);
        vault.stake(100e18);

        vm.prank(yesBeliever);
        passMarket.swapIn{value: 0.1 ether}(passMarket.OUTCOME_YES(), 1e16, 0.1 ether);

        vm.warp(proposal.closesAt());
        proposal.finalize();
        assertTrue(vault.earlyExitUnlocked());

        uint256 supplyBefore = memecoin.totalSupply();
        vm.prank(yesBeliever);
        vault.burnAndExit(100e18);

        assertEq(memecoin.totalSupply(), supplyBefore - 100e18);
        assertEq(vault.totalStaked(), 0);
    }
}
