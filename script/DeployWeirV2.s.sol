// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {WeirV2FeeEscrow} from "../src/WeirV2FeeEscrow.sol";
import {WeirV2MemeHook} from "../src/hooks/WeirV2MemeHook.sol";
import {WeirV2BuybackVault} from "../src/WeirV2BuybackVault.sol";
import {WeirV2LaunchLocker} from "../src/WeirV2LaunchLocker.sol";
import {WeirV2LaunchFactory} from "../src/WeirV2LaunchFactory.sol";
import {WeirV2LaunchDeployer} from "../src/WeirV2LaunchDeployer.sol";
import {WeirV2GraduationExecutor} from "../src/WeirV2GraduationExecutor.sol";
import {WeirV2StakingVaultDeployer} from "../src/WeirV2StakingVaultDeployer.sol";
import {WeirV2CommitmentRegistry} from "../src/WeirV2CommitmentRegistry.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";

/**
 * @title DeployWeirV2
 * @notice Deploys and wires the full weir v2 launchpad: fee escrow, meme
 * hook (CREATE2-mined for its permission flags), buyback vault, launch
 * locker, launch factory, launch deployer, and graduation executor.
 *
 * Required env vars:
 *   PRIVATE_KEY            deployer key; becomes the owner of every
 *                           ownable contract and the protocol fee recipient
 *                           unless PROTOCOL_FEE_RECIPIENT is also set
 *   POOL_MANAGER            canonical IPoolManager for the target chain
 *   POSITION_MANAGER        canonical IPositionManager for the target chain
 *   PERMIT2                 canonical Permit2 deployment for the target chain
 *
 * Optional env vars:
 *   PROTOCOL_FEE_RECIPIENT  defaults to the deployer address
 *   INITIAL_LAUNCH_FEE      wei, defaults to 0
 *   CREATE2_DEPLOYER        defaults to the canonical
 *                           0x4e59b44847b379578588920cA78FbF26c0B4956C proxy
 *   SWAP_VM_ROUTER          official 1inch SwapVM router (SwapVMRouter /
 *                           LimitSwapVMRouter, or a local-fork redeploy).
 *                           When set, deploys and wires the commitment
 *                           registry and enables staking-vault auto-compound
 *                           through it; when unset both stay off.
 *
 * This script only deploys and wires the core system; it does not call
 * `addLaunchConfig`, since curve economics (supply, phantom quote,
 * graduation threshold) are per-launch operational decisions, not part of
 * bringing the protocol up.
 */
contract DeployWeirV2 is Script {
    // Canonical CREATE2 deployer proxy (Arachnid's proxy), present on every
    // chain forge and most public networks share it with.
    address internal constant DEFAULT_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run()
        external
        returns (
            WeirV2FeeEscrow feeEscrow,
            WeirV2MemeHook memeHook,
            WeirV2BuybackVault buybackVault,
            WeirV2LaunchLocker locker,
            WeirV2LaunchFactory factory,
            WeirV2LaunchDeployer launchDeployer,
            WeirV2GraduationExecutor graduationExecutor,
            WeirV2StakingVaultDeployer stakingVaultDeployer,
            WeirV2CommitmentRegistry commitmentRegistry
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IPositionManager positionManager = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        IAllowanceTransfer permit2 = IAllowanceTransfer(vm.envAddress("PERMIT2"));

        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", deployer);
        uint256 initialLaunchFee = vm.envOr("INITIAL_LAUNCH_FEE", uint256(0));
        address create2Deployer = vm.envOr("CREATE2_DEPLOYER", DEFAULT_CREATE2_DEPLOYER);

        vm.startBroadcast(deployerKey);

        feeEscrow = new WeirV2FeeEscrow();
        console2.log("WeirV2FeeEscrow:", address(feeEscrow));

        memeHook = _deployMemeHook(create2Deployer, poolManager, feeEscrow, protocolFeeRecipient, deployer);
        console2.log("WeirV2MemeHook:", address(memeHook));

        buybackVault = new WeirV2BuybackVault(deployer, memeHook, feeEscrow);
        console2.log("WeirV2BuybackVault:", address(buybackVault));

        locker = new WeirV2LaunchLocker(deployer, address(positionManager));
        console2.log("WeirV2LaunchLocker:", address(locker));

        factory = new WeirV2LaunchFactory(
            deployer, poolManager, positionManager, permit2, locker, memeHook, feeEscrow, buybackVault, initialLaunchFee
        );
        console2.log("WeirV2LaunchFactory:", address(factory));

        launchDeployer = new WeirV2LaunchDeployer(address(factory));
        console2.log("WeirV2LaunchDeployer:", address(launchDeployer));

        graduationExecutor = new WeirV2GraduationExecutor(positionManager, permit2, locker, address(factory));
        console2.log("WeirV2GraduationExecutor:", address(graduationExecutor));

        stakingVaultDeployer = new WeirV2StakingVaultDeployer(address(memeHook));
        console2.log("WeirV2StakingVaultDeployer:", address(stakingVaultDeployer));

        // One-time wiring. Each of these reverts on a second call, so this
        // script is only safe to run once per set of freshly deployed
        // contracts.
        memeHook.setFactory(address(factory));
        memeHook.setBuybackVault(buybackVault);
        memeHook.setStakingVaultDeployer(stakingVaultDeployer);
        buybackVault.setFactory(address(factory));
        locker.setFactory(address(factory));
        factory.setLaunchDeployer(launchDeployer);
        factory.setGraduationExecutor(graduationExecutor);

        // SwapVM-backed features (Ideas/Idea1.md, Ideas/Idea2.md). Both hang
        // off the official router, so both are skipped when none is given.
        address swapVMRouter = vm.envOr("SWAP_VM_ROUTER", address(0));
        if (swapVMRouter != address(0)) {
            commitmentRegistry = new WeirV2CommitmentRegistry(address(factory), ISwapVM(swapVMRouter));
            console2.log("WeirV2CommitmentRegistry:", address(commitmentRegistry));
            factory.setCommitmentRegistry(commitmentRegistry);
            memeHook.setCompoundRouter(swapVMRouter, ISwapVM(swapVMRouter).WETH());
        }

        vm.stopBroadcast();
    }

    /**
     * @dev Mines a CREATE2 salt so the hook's deployed address encodes its
     * permission flags (`beforeInitialize` + `afterSwap`, matching
     * `getHookPermissions()`), then deploys through the canonical CREATE2
     * deployer proxy so the mined address is the one that actually gets used.
     */
    function _deployMemeHook(
        address create2Deployer,
        IPoolManager poolManager,
        WeirV2FeeEscrow feeEscrow,
        address protocolFeeRecipient,
        address initialOwner
    ) internal returns (WeirV2MemeHook memeHook) {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        bytes memory creationCode = type(WeirV2MemeHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager, feeEscrow, protocolFeeRecipient, initialOwner);

        (address predictedAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, creationCode, constructorArgs);

        memeHook = new WeirV2MemeHook{salt: salt}(poolManager, feeEscrow, protocolFeeRecipient, initialOwner);
        require(address(memeHook) == predictedAddress, "DeployWeirV2: hook address mismatch");
    }
}
