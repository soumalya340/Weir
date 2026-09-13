// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockPermit2Placeholder} from "./support/MockPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {WeirV2FeeEscrow} from "../src/WeirV2FeeEscrow.sol";
import {WeirV2MemeHook} from "../src/hooks/WeirV2MemeHook.sol";
import {WeirV2BuybackVault} from "../src/WeirV2BuybackVault.sol";
import {WeirV2LaunchLocker} from "../src/WeirV2LaunchLocker.sol";
import {WeirV2LaunchFactory} from "../src/WeirV2LaunchFactory.sol";
import {WeirV2LaunchDeployer} from "../src/WeirV2LaunchDeployer.sol";
import {WeirV2GraduationExecutor} from "../src/WeirV2GraduationExecutor.sol";
import {WeirV2StakingVaultDeployer} from "../src/WeirV2StakingVaultDeployer.sol";
import {WeirV2CommitmentRegistry} from "../src/WeirV2CommitmentRegistry.sol";
import {WeirV2BondingCurve} from "../src/WeirV2BondingCurve.sol";
import {WeirV2LauncherToken} from "../src/WeirV2LauncherToken.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";
import {MockUSDC} from "./support/Mocks.sol";
import {MockSwapVM} from "./support/MockSwapVM.sol";
import {MockWETH9} from "./support/MockWETH9.sol";

/// @notice Shared full-stack fixture for factory/graduation tests: the real
/// periphery (PoolManager, PositionManager), the mined hook, and every wired
/// helper, with the commitment registry on the mock router. Permit2 is an
/// address placeholder: wiring compares it by address only, and the concrete
/// Permit2 contract pins solc =0.8.17, which cannot join this import closure.
contract WeirV2FactoryFixture is Test {
    PoolManager internal pm;
    IAllowanceTransfer internal permit2;
    PositionManager internal posm;
    MockWETH9 internal weth;
    WeirV2FeeEscrow internal escrow;
    WeirV2MemeHook internal hook;
    WeirV2BuybackVault internal buybackVault;
    WeirV2LaunchLocker internal locker;
    WeirV2LaunchFactory internal factory;
    WeirV2LaunchDeployer internal launchDeployer;
    WeirV2GraduationExecutor internal graduationExecutor;
    WeirV2StakingVaultDeployer internal stakingDeployer;
    WeirV2CommitmentRegistry internal registry;
    MockSwapVM internal router;
    MockUSDC internal usdc;

    address internal owner;
    address internal creator = makeAddr("creatorF");
    address internal buyer = makeAddr("buyerF");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant PHANTOM = 10_000e6;
    uint256 internal constant THRESHOLD = 40_000e6;
    // Native-quote (wei) figures for the launch config itself. Launches in
    // these tests quote in USDC and take live terms from PairTokenEconomics,
    // but addLaunchConfig still validates the config's own triple, so these
    // must be genuinely quotable native terms rather than placeholders.
    uint256 internal constant NATIVE_PHANTOM = 10_000e18;
    uint256 internal constant NATIVE_THRESHOLD = 40_000e18;
    uint256 internal constant TARGET_Q = 1_000e6;
    uint16 internal constant DISCOUNT = 3000;
    uint256 internal configId;

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );

    function setUp() public virtual {
        owner = address(this);
        pm = new PoolManager(owner);
        permit2 = IAllowanceTransfer(address(new MockPermit2Placeholder()));
        weth = new MockWETH9();
        PositionDescriptor descriptor = new PositionDescriptor(IPoolManager(address(pm)), address(weth), bytes32("ETH"));
        posm = new PositionManager(
            IPoolManager(address(pm)), IAllowanceTransfer(address(permit2)), 100_000, descriptor, weth
        );

        escrow = new WeirV2FeeEscrow();
        hook = _mineHook(owner);
        buybackVault = new WeirV2BuybackVault(owner, hook, escrow);
        locker = new WeirV2LaunchLocker(owner, address(posm));
        factory = new WeirV2LaunchFactory(
            owner,
            IPoolManager(address(pm)),
            posm,
            IAllowanceTransfer(address(permit2)),
            locker,
            hook,
            escrow,
            buybackVault,
            0
        );
        launchDeployer = new WeirV2LaunchDeployer(address(factory));
        graduationExecutor =
            new WeirV2GraduationExecutor(posm, IAllowanceTransfer(address(permit2)), locker, address(factory));
        stakingDeployer = new WeirV2StakingVaultDeployer(address(hook));

        hook.setFactory(address(factory));
        hook.setBuybackVault(buybackVault);
        hook.setStakingVaultDeployer(stakingDeployer);
        buybackVault.setFactory(address(factory));
        locker.setFactory(address(factory));
        factory.setLaunchDeployer(launchDeployer);
        factory.setGraduationExecutor(graduationExecutor);

        router = new MockSwapVM(address(weth));
        registry = new WeirV2CommitmentRegistry(address(factory), ISwapVM(address(router)));
        factory.setCommitmentRegistry(registry);

        usdc = new MockUSDC();
        factory.setPairTokenEconomics(address(usdc), PHANTOM, THRESHOLD, 6);
        factory.setPairTokenApproved(address(usdc), true);
        factory.addLaunchConfig(
            WeirV2LaunchFactory.LaunchConfig({
                supply: SUPPLY,
                curveFeeBps: 100,
                phantomQuote: NATIVE_PHANTOM,
                graduationThreshold: NATIVE_THRESHOLD,
                poolFee: 0,
                tickSpacing: 60,
                enabled: true
            })
        );
        configId = 0;
        factory.setLaunchEnabled(true);
    }

    function _mineHook(address hookOwner) internal returns (WeirV2MemeHook mined) {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(IPoolManager(address(pm)), escrow, hookOwner, hookOwner);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(WeirV2MemeHook).creationCode, args);
        mined = new WeirV2MemeHook{salt: salt}(IPoolManager(address(pm)), escrow, hookOwner, hookOwner);
    }

    function _tokenParams(bytes32 salt) internal view returns (WeirV2LaunchFactory.TokenParams memory) {
        return WeirV2LaunchFactory.TokenParams({
            name: "Weir",
            symbol: "WEIR",
            logo: "",
            description: "",
            socials: WeirV2LauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            buybackEnabled: false,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _campaign(uint256 opensAt) internal view returns (WeirV2CommitmentRegistry.CampaignParams memory) {
        return WeirV2CommitmentRegistry.CampaignParams({
            discountBps: DISCOUNT,
            targetQuote: TARGET_Q,
            oversubscriptionBps: 0,
            tradingOpensAt: opensAt,
            allowlistRoot: bytes32(0)
        });
    }

    /// @dev Launches with a campaign as the creator; returns token + curve.
    function _launchCampaign(bytes32 salt, uint256 opensAt) internal returns (address token, address curve) {
        address[] memory exemptions = new address[](0);
        vm.prank(creator);
        (token, curve) = factory.launchTokenWithCampaign(
            _tokenParams(salt), configId, address(usdc), _campaign(opensAt), exemptions
        );
    }
}

/// @notice TestCase §4 (launch half): registry wiring, economics digest.
/// Graduation flows live in WeirV2Graduation.t.sol on the same fixture.
contract WeirV2LaunchFactoryTest is WeirV2FactoryFixture {
    // 4.1: setCommitmentRegistry — once only, non-zero, factory must match.
    function test_setCommitmentRegistry_gating() public {
        WeirV2LaunchFactory factory2 = new WeirV2LaunchFactory(
            owner,
            IPoolManager(address(pm)),
            posm,
            IAllowanceTransfer(address(permit2)),
            locker,
            hook,
            escrow,
            buybackVault,
            0
        );

        vm.expectRevert(WeirV2LaunchFactory.ZeroAddress.selector);
        factory2.setCommitmentRegistry(WeirV2CommitmentRegistry(address(0)));

        WeirV2CommitmentRegistry foreign =
            new WeirV2CommitmentRegistry(makeAddr("otherFactory"), ISwapVM(address(router)));
        vm.expectRevert(WeirV2LaunchFactory.CommitmentRegistryMismatch.selector);
        factory2.setCommitmentRegistry(foreign);

        WeirV2CommitmentRegistry registry2 = new WeirV2CommitmentRegistry(address(factory2), ISwapVM(address(router)));
        factory2.setCommitmentRegistry(registry2);
        assertEq(address(factory2.commitmentRegistry()), address(registry2));
        vm.expectRevert(WeirV2LaunchFactory.AlreadySet.selector);
        factory2.setCommitmentRegistry(registry2);

        // The shared fixture's own registry is already set exactly once.
        vm.expectRevert(WeirV2LaunchFactory.AlreadySet.selector);
        factory.setCommitmentRegistry(registry);
    }

    // 4.13: launches refuse until every dependency is wired.
    function test_launch_dependenciesNotWired() public {
        WeirV2LaunchFactory bare = new WeirV2LaunchFactory(
            owner,
            IPoolManager(address(pm)),
            posm,
            IAllowanceTransfer(address(permit2)),
            locker,
            hook,
            escrow,
            buybackVault,
            0
        );
        WeirV2LaunchDeployer onlyDeployer = new WeirV2LaunchDeployer(address(bare));
        bare.setLaunchDeployer(onlyDeployer);

        address[] memory exemptions = new address[](0);
        vm.prank(creator);
        vm.expectRevert(WeirV2LaunchFactory.LaunchDependenciesNotWired.selector);
        bare.launchToken(_tokenParams(bytes32(uint256(1))), configId, address(0), exemptions);
    }

    // 4.2: campaign launch without a registry reverts. Needs a parallel
    // stack wired everywhere except the registry: the deps check runs
    // before the registry check, so a bare factory would trip the wrong one.
    function test_launchCampaign_withoutRegistry() public {
        WeirV2MemeHook hook2 = _mineHook(owner);
        WeirV2BuybackVault vault2 = new WeirV2BuybackVault(owner, hook2, escrow);
        WeirV2LaunchLocker locker2 = new WeirV2LaunchLocker(owner, address(posm));
        WeirV2LaunchFactory noReg = new WeirV2LaunchFactory(
            owner,
            IPoolManager(address(pm)),
            posm,
            IAllowanceTransfer(address(permit2)),
            locker2,
            hook2,
            escrow,
            vault2,
            0
        );
        WeirV2LaunchDeployer ld2 = new WeirV2LaunchDeployer(address(noReg));
        WeirV2GraduationExecutor ge2 =
            new WeirV2GraduationExecutor(posm, IAllowanceTransfer(address(permit2)), locker2, address(noReg));
        WeirV2StakingVaultDeployer sd2 = new WeirV2StakingVaultDeployer(address(hook2));
        hook2.setFactory(address(noReg));
        hook2.setBuybackVault(vault2);
        hook2.setStakingVaultDeployer(sd2);
        vault2.setFactory(address(noReg));
        locker2.setFactory(address(noReg));
        noReg.setLaunchDeployer(ld2);
        noReg.setGraduationExecutor(ge2);
        noReg.setPairTokenEconomics(address(usdc), PHANTOM, THRESHOLD, 6);
        noReg.setPairTokenApproved(address(usdc), true);
        noReg.addLaunchConfig(
            WeirV2LaunchFactory.LaunchConfig({
                supply: SUPPLY,
                curveFeeBps: 100,
                phantomQuote: NATIVE_PHANTOM,
                graduationThreshold: NATIVE_THRESHOLD,
                poolFee: 0,
                tickSpacing: 60,
                enabled: true
            })
        );
        noReg.setLaunchEnabled(true);

        address[] memory exemptions = new address[](0);
        vm.prank(creator);
        vm.expectRevert(WeirV2LaunchFactory.CommitmentRegistryNotSet.selector);
        noReg.launchTokenWithCampaign(
            _tokenParams(bytes32(uint256(2))), 0, address(usdc), _campaign(block.timestamp + 25 hours), exemptions
        );
    }

    // 4.3: zero-target campaigns are not campaigns.
    function test_launchCampaign_zeroTarget() public {
        WeirV2CommitmentRegistry.CampaignParams memory empty = _campaign(block.timestamp + 25 hours);
        empty.targetQuote = 0;
        address[] memory exemptions = new address[](0);
        vm.prank(creator);
        vm.expectRevert(WeirV2LaunchFactory.InvalidTokenParams.selector);
        factory.launchTokenWithCampaign(_tokenParams(bytes32(uint256(3))), configId, address(usdc), empty, exemptions);
    }

    // 4.4: campaign launch wiring — registry, curve, exemptions, event.
    function test_launchCampaign_wiring() public {
        uint256 opensAt = block.timestamp + 25 hours;
        vm.recordLogs();
        (address token, address curve) = _launchCampaign(bytes32(uint256(4)), opensAt);

        // Registry holds the campaign keyed by token...
        assertTrue(registry.hasCampaign(token));
        WeirV2CommitmentRegistry.Campaign memory c = registry.getCampaign(token);
        // ...and the curve fenced off exactly that tranche, opening on time.
        assertEq(WeirV2BondingCurve(curve).committedTokens(), c.committedTokens);
        assertGt(c.committedTokens, 0);
        assertEq(WeirV2BondingCurve(curve).tradingOpensAt(), opensAt);
        assertEq(c.closesAt, opensAt);
        // Creator is snipe-exempt on their own launch.
        assertTrue(WeirV2BondingCurve(curve).snipeTaxExempt(creator));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("TokenLaunched(address,address,address,address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].topics[1] == bytes32(uint256(uint160(token)))) {
                found = true;
            }
        }
        assertTrue(found);
    }

    // 4.5: plain launches never touch the registry and open immediately.
    function test_launch_plainUnaffected() public {
        assertEq(address(factory.commitmentRegistry()), address(registry));
        vm.prank(creator);
        (address token, address curve) = factory.launchToken(_tokenParams(bytes32(uint256(5))), configId, address(usdc));

        assertFalse(registry.hasCampaign(token));
        assertEq(WeirV2BondingCurve(curve).committedTokens(), 0);
        assertEq(WeirV2BondingCurve(curve).tradingOpensAt(), 0);
    }

    // 4.6: the economics digest pins owner-controlled terms, including the
    // staker share: repricing it changes the digest and voids old pins.
    function test_launch_economicsDigest() public {
        bytes32 before = factory.previewLaunchEconomics(configId, address(usdc));
        hook.setStakerFeeShareBps(5000);
        bytes32 afterSlow = factory.previewLaunchEconomics(configId, address(usdc));
        assertTrue(before != afterSlow);

        WeirV2LaunchFactory.TokenParams memory pinned = _tokenParams(bytes32(uint256(6)));
        pinned.expectedEconomics = before;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(WeirV2LaunchFactory.LaunchEconomicsMismatch.selector, before, afterSlow));
        factory.launchToken(pinned, configId, address(usdc));

        // A fresh pin succeeds.
        pinned.expectedEconomics = afterSlow;
        pinned.salt = bytes32(uint256(7));
        vm.prank(creator);
        (address token,) = factory.launchToken(pinned, configId, address(usdc));
        assertTrue(factory.getLaunchedToken(token).exists);
    }
}
