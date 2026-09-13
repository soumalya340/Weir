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
import {WeirV2LaunchFactory} from "../src/WeirV2LaunchFactory.sol";
import {WeirV2LaunchLocker} from "../src/WeirV2LaunchLocker.sol";
import {WeirV2FutarchyProposal} from "../src/WeirV2FutarchyProposal.sol";
import {
    FeePolicySnapshot,
    GraduationPhase,
    IWeirV2FeeEscrow,
    IWeirV2FeePolicy,
    IWeirV2LaunchFactory
} from "../src/interfaces/ILaunchpadV2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

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

/// @dev Malicious "proposal" that only exposes vault() — the attack AUDIT.md #1 warned about.
contract FakeFutarchyProposal {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function unlockEarlyExit() external {
        WeirV2StakingReward(payable(vault)).unlockEarlyExit();
    }
}

contract MockPosManager {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }
}

/// @dev Seeds `_launchedTokens` for creator-fee / futarchy factory-path tests.
contract FactoryHarness is WeirV2LaunchFactory {
    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        WeirV2LaunchLocker locker_,
        WeirV2MemeHook memeHook_,
        IWeirV2FeeEscrow feeEscrow_,
        WeirV2BuybackVault buybackVault_,
        uint256 initialLaunchFee
    )
        WeirV2LaunchFactory(
            initialOwner,
            poolManager_,
            positionManager_,
            permit2_,
            locker_,
            memeHook_,
            feeEscrow_,
            buybackVault_,
            initialLaunchFee
        )
    {}

    function seedLaunch(address token, IWeirV2LaunchFactory.LaunchedToken memory launch) external {
        _launchedTokens[token] = launch;
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

    /// FINDING #1 FIXED: vault()-matching fake cannot be registered or unlock via factory path.
    function test_poc_fakeVaultMatchingProposalCannotUnlockViaFactory() public {
        (FactoryHarness factory, WeirV2MemeHook memeHook, address token, PoolId poolId, address stakingVault) =
            _seedGraduatedLaunch();

        FakeFutarchyProposal fake = new FakeFutarchyProposal(stakingVault);
        assertEq(fake.vault(), stakingVault, "precondition: fake matches vault()");

        // Legacy permissionless register(token, proposal) must not exist.
        (bool ok,) = address(factory).call(
            abi.encodeWithSignature("registerFutarchyProposal(address,address)", token, address(fake))
        );
        assertFalse(ok, "arbitrary-address register path must be gone");

        // Direct vault seizure still blocked.
        vm.prank(attacker);
        vm.expectRevert(WeirV2StakingReward.NotHook.selector);
        WeirV2StakingReward(payable(stakingVault)).setFutarchyProposal(address(fake));

        // Factory deploys a real WeirV2FutarchyProposal and wires only that.
        // The EOA who paid the bond must be recorded as proposer (not the factory).
        vm.deal(attacker, 1 ether);
        uint256 attackerBalBefore = attacker.balance;
        vm.prank(attacker);
        address realProposal = factory.createFutarchyProposal{value: 0.01 ether}(token);
        assertEq(attacker.balance, attackerBalBefore - 0.01 ether, "caller paid the bond");
        assertEq(WeirV2StakingReward(payable(stakingVault)).futarchyProposal(), realProposal);
        assertTrue(realProposal.code.length > 0);
        assertEq(WeirV2FutarchyProposal(payable(realProposal)).vault(), stakingVault);
        assertEq(WeirV2FutarchyProposal(payable(realProposal)).proposer(), attacker, "proposer is paying EOA");
        assertTrue(realProposal != address(fake));
        assertTrue(WeirV2FutarchyProposal(payable(realProposal)).proposer() != address(factory));

        // Bond refunds to the paying EOA after the trading window, not the factory.
        vm.warp(WeirV2FutarchyProposal(payable(realProposal)).closesAt());
        uint256 balBeforeRefund = attacker.balance;
        uint256 factoryBalBefore = address(factory).balance;
        WeirV2FutarchyProposal(payable(realProposal)).returnBond();
        assertEq(attacker.balance, balBeforeRefund + 0.01 ether, "returnBond credits paying EOA");
        assertEq(address(factory).balance, factoryBalBefore, "factory must not keep the bond");

        // Fake still cannot unlock.
        vm.prank(address(fake));
        vm.expectRevert(WeirV2StakingReward.NotFutarchyProposal.selector);
        WeirV2StakingReward(payable(stakingVault)).unlockEarlyExit();
        assertFalse(WeirV2StakingReward(payable(stakingVault)).earlyExitUnlocked());
        assertEq(address(memeHook.stakingVaults(poolId)), stakingVault);
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

    /// FINDING #2: registerPool deploys a live staking vault for the pool.
    function test_fix_registerPoolDeploysStakingVault() public {
        address owner = makeAddr("owner");
        address creator = makeAddr("creator");
        address protocol = makeAddr("protocol");
        IPoolManager pm = IPoolManager(makeAddr("pm"));

        WeirV2MemeHook memeHook = _mineHook(pm, escrow, protocol, owner);
        vm.prank(owner);
        memeHook.setFactory(address(this));

        PoCMemecoin launchToken = new PoCMemecoin();
        // Native quote: currency0 = address(0), currency1 = memecoin when memecoin > 0.
        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(address(launchToken));
        if (uint160(address(launchToken)) < uint160(address(0))) {
            // unreachable for address(0) quote; keep sort explicit
            (c0, c1) = (c1, c0);
        }
        // Sort properly: native ETH (address(0)) is always currency0 when paired.
        c0 = Currency.wrap(address(0));
        c1 = Currency.wrap(address(launchToken));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(memeHook))
        });
        PoolId poolId = key.toId();

        assertEq(address(memeHook.stakingVaults(poolId)), address(0), "precondition: no vault");

        FeePolicySnapshot memory policy = FeePolicySnapshot({
            protocolFeeRecipient: protocol,
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300
        });
        memeHook.registerPool(key, address(launchToken), creator, creator, 0, false, policy);

        address stakingVault = address(memeHook.stakingVaults(poolId));
        assertTrue(stakingVault != address(0), "registerPool must deploy staking vault");
        assertEq(WeirV2StakingReward(payable(stakingVault)).hook(), address(memeHook));
        assertEq(address(WeirV2StakingReward(payable(stakingVault)).stakeToken()), address(launchToken));
        assertEq(WeirV2StakingReward(payable(stakingVault)).quoteToken(), address(0));
    }

    /// FINDING #4: creator transfer cancels pending owner override on the live factory.
    function test_fix_creatorTransferCancelsPendingOverride() public {
        address owner = makeAddr("owner");
        address creator = makeAddr("creator");
        address ownerOverride = makeAddr("ownerOverride");
        address creatorSafe = makeAddr("creatorSafe");
        address protocol = makeAddr("protocol");
        IPoolManager pm = IPoolManager(makeAddr("pm"));

        MockPosManager pos = new MockPosManager(pm);
        WeirV2LaunchLocker locker = new WeirV2LaunchLocker(owner, address(pos));
        WeirV2MemeHook memeHook = _mineHook(pm, escrow, protocol, owner);
        WeirV2BuybackVault buyback = new WeirV2BuybackVault(owner, IWeirV2FeePolicy(address(memeHook)), escrow);

        FactoryHarness factory = new FactoryHarness(
            owner,
            pm,
            IPositionManager(address(pos)),
            IAllowanceTransfer(makeAddr("permit2")),
            locker,
            memeHook,
            escrow,
            buyback,
            0
        );
        vm.prank(owner);
        memeHook.setFactory(address(factory));
        vm.prank(owner);
        memeHook.setBuybackVault(buyback);
        vm.prank(owner);
        buyback.setFactory(address(factory));
        vm.prank(owner);
        locker.setFactory(address(factory));

        // Deploy a real curve owned by this factory so _setCreatorFeeRecipient can forward.
        PoCFeePolicy policy = new PoCFeePolicy(address(factory));
        FeePolicySnapshot memory snap = policy.currentFeePolicy();
        WeirV2BondingCurve curve = new WeirV2BondingCurve(
            address(0),
            creator,
            address(factory),
            policy,
            snap,
            escrow,
            buyback,
            10 ether,
            100,
            0,
            false,
            5 ether,
            0,
            15
        );
        PoCMemecoin launchToken = new PoCMemecoin();
        launchToken.mint(address(curve), 1_000_000e18);
        vm.prank(address(factory));
        curve.initialize(address(launchToken));

        factory.seedLaunch(
            address(launchToken),
            IWeirV2LaunchFactory.LaunchedToken({
                token: address(launchToken),
                curve: address(curve),
                deployer: creator,
                creatorFeeRecipient: creator,
                pairToken: address(0),
                graduationThreshold: 5 ether,
                poolFee: 3000,
                tickSpacing: 60,
                creatorTaxBps: 0,
                buybackEnabled: false,
                phase: GraduationPhase.NotGraduated,
                sweptQuote: 0,
                sweptTokens: 0,
                sweptAt: 0,
                exists: true
            })
        );

        vm.prank(owner);
        factory.setCreatorFeeRecipient(address(launchToken), ownerOverride);
        (address pendingRecipient,,) = factory.pendingCreatorFeeRecipient(address(launchToken));
        assertEq(pendingRecipient, ownerOverride, "precondition: override pending");

        vm.prank(creator);
        factory.transferCreatorFeeRecipient(address(launchToken), creatorSafe);

        (pendingRecipient,,) = factory.pendingCreatorFeeRecipient(address(launchToken));
        assertEq(pendingRecipient, address(0), "creator transfer must clear pending override");
        assertEq(factory.getLaunchedToken(address(launchToken)).creatorFeeRecipient, creatorSafe);

        vm.expectRevert(WeirV2LaunchFactory.NoPendingChange.selector);
        factory.executeCreatorFeeRecipientChange(address(launchToken));
    }

    /// FINDING #3: BinaryMarket is vendored and the project builds futarchy.
    function test_fix_binaryMarketVendoredInRepo() public {
        // Driving the real constructor proves the vendored dependency compiles and links.
        WeirV2FutarchyProposal proposal = new WeirV2FutarchyProposal{value: 0.01 ether}(address(vault), address(this));
        assertTrue(address(proposal.passMarket()) != address(0));
        assertTrue(address(proposal.failMarket()) != address(0));
        assertEq(proposal.vault(), address(vault));
    }

    function _mineHook(IPoolManager pm, IWeirV2FeeEscrow feeEscrow_, address protocol, address owner)
        internal
        returns (WeirV2MemeHook memeHook)
    {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory ctorArgs = abi.encode(pm, feeEscrow_, protocol, owner);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(WeirV2MemeHook).creationCode, ctorArgs);
        memeHook = new WeirV2MemeHook{salt: salt}(pm, feeEscrow_, protocol, owner);
    }

    function _seedGraduatedLaunch()
        internal
        returns (FactoryHarness factory, WeirV2MemeHook memeHook, address token, PoolId poolId, address stakingVault)
    {
        address owner = makeAddr("owner");
        address creator = makeAddr("creator");
        address protocol = makeAddr("protocol");
        IPoolManager pm = IPoolManager(makeAddr("pm"));

        MockPosManager pos = new MockPosManager(pm);
        WeirV2LaunchLocker locker = new WeirV2LaunchLocker(owner, address(pos));
        memeHook = _mineHook(pm, escrow, protocol, owner);
        WeirV2BuybackVault buyback = new WeirV2BuybackVault(owner, IWeirV2FeePolicy(address(memeHook)), escrow);

        factory = new FactoryHarness(
            owner,
            pm,
            IPositionManager(address(pos)),
            IAllowanceTransfer(makeAddr("permit2")),
            locker,
            memeHook,
            escrow,
            buyback,
            0
        );
        vm.prank(owner);
        memeHook.setFactory(address(factory));
        vm.prank(owner);
        memeHook.setBuybackVault(buyback);
        vm.prank(owner);
        buyback.setFactory(address(factory));
        vm.prank(owner);
        locker.setFactory(address(factory));

        PoCMemecoin launchToken = new PoCMemecoin();
        token = address(launchToken);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(memeHook))
        });
        poolId = key.toId();

        FeePolicySnapshot memory policy = FeePolicySnapshot({
            protocolFeeRecipient: protocol,
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300
        });
        vm.prank(address(factory));
        memeHook.registerPool(key, token, creator, creator, 0, false, policy);
        stakingVault = address(memeHook.stakingVaults(poolId));
        assertTrue(stakingVault != address(0));

        factory.seedLaunch(
            token,
            IWeirV2LaunchFactory.LaunchedToken({
                token: token,
                curve: makeAddr("curve"),
                deployer: creator,
                creatorFeeRecipient: creator,
                pairToken: address(0),
                graduationThreshold: 5 ether,
                poolFee: 3000,
                tickSpacing: 60,
                creatorTaxBps: 0,
                buybackEnabled: false,
                phase: GraduationPhase.PoolCreated,
                sweptQuote: 0,
                sweptTokens: 0,
                sweptAt: 0,
                exists: true
            })
        );
    }
}
