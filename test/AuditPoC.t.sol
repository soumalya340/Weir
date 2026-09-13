// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {WeirV2FeeEscrow} from "../src/WeirV2FeeEscrow.sol";
import {WeirV2BondingCurve} from "../src/WeirV2BondingCurve.sol";
import {WeirV2BuybackVault} from "../src/WeirV2BuybackVault.sol";
import {WeirV2LaunchDeployer, LaunchDeployment} from "../src/WeirV2LaunchDeployer.sol";
import {WeirV2LauncherToken} from "../src/WeirV2LauncherToken.sol";
import {WeirV2MemeHook} from "../src/hooks/WeirV2MemeHook.sol";
import {FeePolicySnapshot, IWeirV2FeeEscrow, IWeirV2FeePolicy} from "../src/interfaces/ILaunchpadV2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

contract PoCMemecoin is ERC20, ERC20Burnable {
    constructor() ERC20("Meme", "MEME") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal fee policy for bonding-curve PoCs.
contract PoCFeePolicy is IWeirV2FeePolicy {
    address public override feeSweepOperator;
    mapping(address => bool) internal _operators;

    constructor(address operator_) {
        feeSweepOperator = operator_;
        _operators[operator_] = true;
    }

    function setOperator(address account, bool authorized) external {
        _operators[account] = authorized;
        if (authorized) feeSweepOperator = account;
    }

    function isFeeSweepOperator(address account) external view override returns (bool) {
        return _operators[account] || account == feeSweepOperator;
    }

    function protocolFeeShareBps() external pure override returns (uint256) {
        return 3000;
    }

    function buybackBurnBps() external pure override returns (uint256) {
        return 5000;
    }

    function protocolFeeRecipient() external pure override returns (address) {
        return address(0xBEEF);
    }

    function feeEscrow() external pure override returns (IWeirV2FeeEscrow) {
        return IWeirV2FeeEscrow(address(0));
    }

    function maxInternalPriceImpactBps() external pure override returns (uint256) {
        return 300;
    }

    function currentFeePolicy() external pure override returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: address(0xBEEF),
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300
        });
    }
}

/// Regression tests for AUDIT.md Critical→Medium fixes.
contract AuditPoC is Test {
    WeirV2StakingReward internal vault;
    PoCMemecoin internal memecoin;
    WeirV2FeeEscrow internal escrow;

    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        memecoin = new PoCMemecoin();
        escrow = new WeirV2FeeEscrow();
        vault = new WeirV2StakingReward(hook, IERC20(address(memecoin)), address(0), escrow);

        memecoin.mint(alice, 1_000e18);
        vm.prank(alice);
        memecoin.approve(address(vault), type(uint256).max);
        vm.deal(hook, 100 ether);
    }

    /// FINDING #1 FIXED: arbitrary EOAs can no longer seize setFutarchyProposal.
    function test_poc_anyoneCanUnlockEarlyExitWithoutDecisionMarket() public {
        vm.prank(alice);
        vault.stake(100e18);

        assertFalse(vault.earlyExitUnlocked(), "precondition: locked");

        vm.prank(attacker);
        vm.expectRevert(WeirV2StakingReward.NotHook.selector);
        vault.setFutarchyProposal(attacker);

        vm.prank(attacker);
        vm.expectRevert(WeirV2StakingReward.NotFutarchyProposal.selector);
        vault.unlockEarlyExit();

        assertFalse(vault.earlyExitUnlocked(), "early exit still locked");
        assertEq(vault.futarchyProposal(), address(0), "proposal slot unset");
    }

    /// FINDING #1 FIXED: squatting the proposal slot is no longer free/permissionless.
    function test_poc_squattingTheProposalSlotBricksFutarchyForever() public {
        vm.prank(attacker);
        vm.expectRevert(WeirV2StakingReward.NotHook.selector);
        vault.setFutarchyProposal(attacker);

        address realProposal = makeAddr("realProposal");
        vm.prank(hook);
        vault.setFutarchyProposal(realProposal);
        assertEq(vault.futarchyProposal(), realProposal);
    }

    /// Reward accounting still holds when the hook legitimately wires a proposal.
    function test_poc_burnAndExitRewardAccounting() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(hook);
        vault.notifyReward{value: 10 ether}(10 ether);

        address proposal = makeAddr("proposal");
        vm.prank(hook);
        vault.setFutarchyProposal(proposal);
        vm.prank(proposal);
        vault.unlockEarlyExit();

        uint256 pendingBefore = vault.pendingReward(alice);
        assertEq(pendingBefore, 10 ether, "full reward accrued to sole staker");

        vm.prank(alice);
        vault.burnAndExit(100e18);

        assertEq(escrow.balanceOf(alice), 10 ether, "reward credited on pre-decrement stake");
        assertEq(vault.pendingReward(alice), 0, "no double pay");
        assertEq(vault.totalStaked(), 0);
    }

    function test_poc_lateStakerCannotClaimHistoricRewards() public {
        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(hook);
        vault.notifyReward{value: 10 ether}(10 ether);

        address late = makeAddr("late");
        memecoin.mint(late, 100e18);
        vm.prank(late);
        memecoin.approve(address(vault), type(uint256).max);
        vm.prank(late);
        vault.stake(100e18);

        assertEq(vault.pendingReward(late), 0, "late staker has no claim on prior rewards");
    }

    /// FINDING #5: anti-snipe tax is charged on buy for non-exempt callers.
    function test_fix_snipeTaxIsChargedOnBuy() public {
        address factory = address(this);
        address creator = makeAddr("creator");
        address sniper = makeAddr("sniper");
        PoCFeePolicy policy = new PoCFeePolicy(factory);
        WeirV2BuybackVault buyback = new WeirV2BuybackVault(factory, IWeirV2FeePolicy(address(policy)), escrow);

        FeePolicySnapshot memory snap = policy.currentFeePolicy();
        WeirV2BondingCurve curve = new WeirV2BondingCurve(
            address(0),
            creator,
            factory,
            policy,
            snap,
            escrow,
            buyback,
            10 ether,
            100, // 1% fee
            0,
            false,
            5 ether,
            9_900, // 99% snipe start
            15
        );
        PoCMemecoin token = new PoCMemecoin();
        // Mint supply to curve then initialize as factory would.
        token.mint(address(curve), 1_000_000e18);
        curve.initialize(address(token));
        curve.exemptFromSnipeTax(creator);

        uint256 quoteIn = 1 ether;
        vm.deal(sniper, quoteIn);

        uint256 snipeBps = curve.currentSnipeTaxBps(sniper);
        assertEq(snipeBps, 9_900, "full snipe tax at t0");

        vm.prank(sniper);
        uint256 tokensOut = curve.buy{value: quoteIn}(quoteIn, 0, sniper);
        assertGt(tokensOut, 0);

        // Creator tax ledger should include the snipe take (~99% of input).
        assertGe(curve.creatorTaxBalance(), (quoteIn * 9_000) / 10_000);

        // Exempt creator pays no snipe tax.
        assertEq(curve.currentSnipeTaxBps(creator), 0);
    }

    /// FINDING #6: CREATE2 predict matches deploy.
    function test_fix_create2PredictMatchesDeploy() public {
        address factoryAddr = address(this);
        WeirV2LaunchDeployer deployer = new WeirV2LaunchDeployer(factoryAddr);
        PoCFeePolicy policy = new PoCFeePolicy(factoryAddr);
        WeirV2BuybackVault buyback = new WeirV2BuybackVault(factoryAddr, IWeirV2FeePolicy(address(policy)), escrow);

        LaunchDeployment memory params = LaunchDeployment({
            pairToken: address(0),
            creatorFeeRecipient: makeAddr("creator"),
            originalDeployer: makeAddr("creator"),
            feePolicy: policy,
            policy: policy.currentFeePolicy(),
            feeEscrow: escrow,
            buybackVault: buyback,
            phantomQuote: 10 ether,
            curveFeeBps: 100,
            creatorTaxBps: 0,
            buybackEnabled: false,
            graduationThreshold: 5 ether,
            supply: 1_000_000e18,
            salt: keccak256("vanity"),
            snipeTaxStartBps: 0,
            snipeTaxSeconds: 15,
            name: "Test",
            symbol: "TST",
            logo: "",
            description: "",
            socials: WeirV2LauncherToken.Socials("", "", "", "", "")
        });

        (address predictedToken, address predictedCurve) = deployer.predictLaunchAddresses(params);
        (address token, address curve) = deployer.deployLaunch(params);
        assertEq(token, predictedToken, "token address matches prediction");
        assertEq(curve, predictedCurve, "curve address matches prediction");
    }

    /// FINDING #7: secondary fee-sweep operators are authorized on the real hook.
    function test_fix_multiFeeSweepOperator() public {
        address owner = makeAddr("owner");
        address secondary = makeAddr("secondary");
        address protocol = makeAddr("protocol");
        IPoolManager pm = IPoolManager(makeAddr("pm"));

        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory ctorArgs = abi.encode(pm, escrow, protocol, owner);
        // CREATE2 deployer used by HookMiner when salt is mined against address(this).
        address deployer = address(this);
        (, bytes32 salt) = HookMiner.find(deployer, flags, type(WeirV2MemeHook).creationCode, ctorArgs);
        WeirV2MemeHook memeHook = new WeirV2MemeHook{salt: salt}(pm, escrow, protocol, owner);

        assertTrue(memeHook.isFeeSweepOperator(owner), "owner is primary operator");
        assertFalse(memeHook.isFeeSweepOperator(secondary));

        vm.prank(owner);
        memeHook.setFeeSweepOperatorAuthorization(secondary, true);
        assertTrue(memeHook.isFeeSweepOperator(secondary), "secondary authorized");

        vm.prank(owner);
        memeHook.setFeeSweepOperatorAuthorization(secondary, false);
        assertFalse(memeHook.isFeeSweepOperator(secondary), "secondary revoked");
    }

    /// FINDING #2: registerPool path deploys a staking vault (source + hook API).
    function test_fix_registerPoolDeploysStakingVault_source() public {
        string memory src = vm.readFile("src/hooks/WeirV2MemeHook.sol");
        assertTrue(
            _contains(src, "new WeirV2StakingReward(address(this), IERC20(memecoin), quoteToken, feeEscrow)"),
            "registerPool must deploy staking vault"
        );
        assertTrue(_contains(src, "stakingVaults[poolId] = vault"), "vault must be stored");
    }

    /// FINDING #4: creator transfer cancels pending owner override.
    function test_fix_creatorTransferCancelsPendingOverride_source() public {
        string memory src = vm.readFile("src/WeirV2LaunchFactory.sol");
        // Ensure the cancel happens inside transferCreatorFeeRecipient before set.
        uint256 transferPos = _indexOf(src, "function transferCreatorFeeRecipient");
        uint256 cancelPos = _indexOf(src, "_cancelPendingCreatorFeeRecipientChange(token);");
        uint256 setPos = _indexOf(src, "_setCreatorFeeRecipient(token, launch, newRecipient);");
        assertTrue(transferPos != type(uint256).max, "transfer fn exists");
        assertTrue(cancelPos > transferPos && cancelPos < setPos, "cancel before set in transfer");
    }

    /// FINDING #3: BinaryMarket is vendored in-repo (not gitignored-only).
    function test_fix_binaryMarketVendoredInRepo() public {
        string memory src = vm.readFile("deps/degencalls_smartcontracts/src/Binary.sol");
        assertTrue(_contains(src, "contract BinaryMarket"), "BinaryMarket source present");
        string memory gi = vm.readFile(".gitignore");
        // A standalone `deps` ignore would hide the vendored dependency again.
        assertFalse(_hasStandaloneDepsIgnore(gi), "deps must not be gitignored wholesale");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return _indexOf(haystack, needle) != type(uint256).max;
    }

    function _indexOf(string memory haystack, string memory needle) internal pure returns (uint256) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return type(uint256).max;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _hasStandaloneDepsIgnore(string memory gi) internal pure returns (bool) {
        bytes memory b = bytes(gi);
        // Match a line that is exactly "deps" (optional surrounding whitespace).
        uint256 lineStart = 0;
        for (uint256 i = 0; i <= b.length; ++i) {
            if (i == b.length || b[i] == bytes1("\n")) {
                // trim spaces/tabs on [lineStart, i)
                uint256 a = lineStart;
                uint256 c = i;
                while (a < c && (b[a] == " " || b[a] == "\t" || b[a] == bytes1("\r"))) a++;
                while (c > a && (b[c - 1] == " " || b[c - 1] == "\t" || b[c - 1] == bytes1("\r"))) c--;
                if (c == a + 4 && b[a] == "d" && b[a + 1] == "e" && b[a + 2] == "p" && b[a + 3] == "s") {
                    return true;
                }
                lineStart = i + 1;
            }
        }
        return false;
    }
}
