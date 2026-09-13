// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {WeirV2MemeHook} from "../src/hooks/WeirV2MemeHook.sol";
import {WeirV2StakingVaultDeployer} from "../src/WeirV2StakingVaultDeployer.sol";
import {WeirV2StakingReward} from "../src/WeirV2StakingReward.sol";
import {WeirV2FeeEscrow} from "../src/WeirV2FeeEscrow.sol";
import {FeePolicySnapshot} from "../src/interfaces/ILaunchpadV2.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";
import {MockBurnableToken, MockUSDC} from "./support/Mocks.sol";
import {MockSwapVM} from "./support/MockSwapVM.sol";

/// @notice TestCase §5: WeirV2MemeHook — frozen staker share, vault
/// deployer, compound router. No live pool swaps here: registration-level
/// behaviour is asserted directly, and fee-sweep end-to-end runs live in §8.
contract WeirV2MemeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal pm;
    WeirV2FeeEscrow internal escrow;
    WeirV2MemeHook internal hook;
    WeirV2StakingVaultDeployer internal deployer;

    address internal factory = makeAddr("factory");
    address internal creator = makeAddr("creator");
    address internal protocolRecipient = makeAddr("protocol");

    function setUp() public {
        pm = new PoolManager(address(this));
        escrow = new WeirV2FeeEscrow();
        hook = _mineHook(address(this));
        hook.setFactory(factory);
        // Construct the deployer into a local first, then wire it: a prank
        // placed on the deployment expression would be consumed by the
        // constructor instead of the wiring call.
        deployer = new WeirV2StakingVaultDeployer(address(hook));
        hook.setStakingVaultDeployer(deployer);
    }

    function _mineHook(address hookOwner) internal returns (WeirV2MemeHook mined) {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(IPoolManager(address(pm)), escrow, protocolRecipient, hookOwner);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(WeirV2MemeHook).creationCode, args);
        mined = new WeirV2MemeHook{salt: salt}(IPoolManager(address(pm)), escrow, protocolRecipient, hookOwner);
    }

    function _policy(uint16 stakerBps) internal view returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: protocolRecipient,
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300,
            stakerFeeShareBps: stakerBps
        });
    }

    function _register(address memecoin, address quoteTok, uint16 stakerBps) internal returns (PoolId pid) {
        (Currency c0, Currency c1) = quoteTok < memecoin
            ? (Currency.wrap(quoteTok), Currency.wrap(memecoin))
            : (Currency.wrap(memecoin), Currency.wrap(quoteTok));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        vm.prank(factory);
        hook.registerPool(key, memecoin, creator, creator, 0, true, _policy(stakerBps));
        pid = key.toId();
    }

    // 5.1: registration snapshots the staker share; > 5000 is rejected.
    function test_registerPool_snapshotsStakerShare() public {
        MockBurnableToken meme = new MockBurnableToken("M", "M");
        PoolId pid = _register(address(meme), address(0), 4000);

        (bool registered,,,,,,,,,,,, uint16 frozen,) = hook.launches(pid);
        assertTrue(registered);
        assertEq(frozen, 4000);

        MockBurnableToken bad = new MockBurnableToken("B", "B");
        (Currency c0, Currency c1) = (Currency.wrap(address(0)), Currency.wrap(address(bad)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        vm.prank(factory);
        vm.expectRevert(WeirV2MemeHook.InvalidBps.selector);
        hook.registerPool(key, address(bad), creator, creator, 0, true, _policy(5001));
    }

    // 5.2: the owner cannot reprice a registered pool — the sweep path reads
    // the frozen LaunchInfo share, so changing the global leaves the pool's
    // stored terms untouched. (Live sweep-amount comparison runs in §8,
    // which drives real swaps; the freeze below is the mechanism it rests on.)
    function test_ownerCannotRepriceRegisteredPool() public {
        MockBurnableToken meme = new MockBurnableToken("M", "M");
        PoolId pid = _register(address(meme), address(0), 4000);

        hook.setStakerFeeShareBps(1000);
        assertEq(hook.stakerFeeShareBps(), 1000);

        (,,,,,,,,,,,, uint16 frozen,) = hook.launches(pid);
        assertEq(frozen, 4000);
    }

    // 5.3: currentFeePolicy carries the staker share.
    function test_currentFeePolicy_hasStakerShare() public {
        hook.setStakerFeeShareBps(2500);
        assertEq(hook.currentFeePolicy().stakerFeeShareBps, 2500);
    }

    // 5.4: deployer wiring — once only, non-zero, hook must match.
    function test_setStakingVaultDeployer_gating() public {
        address owner2 = makeAddr("owner2");
        WeirV2MemeHook hook2 = _mineHook(owner2);

        vm.prank(owner2);
        vm.expectRevert(WeirV2MemeHook.ZeroAddress.selector);
        hook2.setStakingVaultDeployer(WeirV2StakingVaultDeployer(address(0)));

        // Deployer bound to a different hook.
        WeirV2StakingVaultDeployer foreign = new WeirV2StakingVaultDeployer(address(hook));
        vm.prank(owner2);
        vm.expectRevert(WeirV2MemeHook.StakingVaultDeployerMismatch.selector);
        hook2.setStakingVaultDeployer(foreign);

        WeirV2StakingVaultDeployer own = new WeirV2StakingVaultDeployer(address(hook2));
        vm.prank(owner2);
        hook2.setStakingVaultDeployer(own);
        assertEq(address(hook2.stakingVaultDeployer()), address(own));

        vm.prank(owner2);
        vm.expectRevert(WeirV2MemeHook.AlreadySet.selector);
        hook2.setStakingVaultDeployer(own);
    }

    // 5.5: registration without a deployer reverts.
    function test_registerPool_withoutDeployer() public {
        WeirV2MemeHook bare = _mineHook(makeAddr("owner3"));
        vm.prank(makeAddr("owner3"));
        bare.setFactory(factory);

        MockBurnableToken meme = new MockBurnableToken("M", "M");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(meme)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(bare))
        });
        vm.prank(factory);
        vm.expectRevert(WeirV2MemeHook.StakingVaultDeployerNotSet.selector);
        bare.registerPool(key, address(meme), creator, creator, 0, true, _policy(4000));
    }

    // 5.6: the vault comes from the deployer bound to the hook itself.
    function test_vaultViaDeployer_bindings() public {
        MockUSDC usdc = new MockUSDC();
        MockBurnableToken meme = new MockBurnableToken("M", "M");
        PoolId pid = _register(address(meme), address(usdc), 4000);

        WeirV2StakingReward vault = hook.stakingVaults(pid);
        assertTrue(address(vault) != address(0));
        assertEq(vault.hook(), address(hook));
        assertEq(address(vault.stakeToken()), address(meme));
        assertEq(vault.quoteToken(), address(usdc));
        assertEq(address(vault.feeEscrow()), address(escrow));

        // deployVault straight from anyone but the hook reverts.
        vm.expectRevert(WeirV2StakingVaultDeployer.NotHook.selector);
        deployer.deployVault(IERC20(address(meme)), address(usdc), escrow);
    }

    // 5.7: compound router propagation — at registration, or wired later.
    function test_compoundRouter_propagation() public {
        MockSwapVM swapRouter = new MockSwapVM(makeAddr("weth7"));
        address weth = makeAddr("weth7");
        hook.setCompoundRouter(address(swapRouter), weth);

        // Pool registered after the router is set inherits it.
        MockBurnableToken early = new MockBurnableToken("E", "E");
        PoolId pidEarly = _register(address(early), address(0), 4000);
        WeirV2StakingReward earlyVault = hook.stakingVaults(pidEarly);
        assertEq(address(earlyVault.swapVM()), address(swapRouter));
        assertEq(earlyVault.weth(), weth);

        // Pool registered before any router stays unwired until configured.
        // (Fresh hook without a router for the "before" leg.)
        address owner4 = makeAddr("owner4");
        WeirV2MemeHook bare = _mineHook(owner4);
        vm.prank(owner4);
        bare.setFactory(factory);
        WeirV2StakingVaultDeployer bareDeployer = new WeirV2StakingVaultDeployer(address(bare));
        vm.prank(owner4);
        bare.setStakingVaultDeployer(bareDeployer);
        MockBurnableToken late = new MockBurnableToken("L", "L");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(late)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(bare))
        });
        vm.prank(factory);
        bare.registerPool(key, address(late), creator, creator, 0, true, _policy(4000));
        PoolId pidLate = key.toId();
        assertEq(address(bare.stakingVaults(pidLate).swapVM()), address(0));

        vm.prank(owner4);
        bare.setCompoundRouter(address(swapRouter), weth);
        vm.prank(owner4);
        bare.configureStakingVaultCompounding(pidLate);
        assertEq(address(bare.stakingVaults(pidLate).swapVM()), address(swapRouter));

        vm.prank(owner4);
        vm.expectRevert(WeirV2StakingReward.CompoundRouterAlreadySet.selector);
        bare.configureStakingVaultCompounding(pidLate);
    }

    // 5.8: the hook stays under the EIP-170 runtime size ceiling in the
    // deployment (optimizer) profile — the profile DeployWeirV2 uses.
    // Enforced under FOUNDRY_PROFILE=deploy; under the default profile the
    // unoptimized bytecode is legitimately larger, so the test records the
    // size and skips instead of failing a true property.
    function test_hookBytecodeSize() public {
        uint256 size = address(hook).code.length;
        emit log_named_uint("hook runtime bytes", size);
        string memory profile = vm.envOr("FOUNDRY_PROFILE", string("default"));
        if (keccak256(bytes(profile)) != keccak256(bytes("deploy"))) {
            emit log("SKIP 5.8: rerun with FOUNDRY_PROFILE=deploy to enforce the size gate");
            vm.skip(true);
        }
        assertLt(size, 24_576);
    }
}
