// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WeirV2StakingReward} from "./WeirV2StakingReward.sol";
import {IWeirV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title WeirV2StakingVaultDeployer
 * @notice Deploys the per-pool WeirV2StakingReward vault on WeirV2MemeHook's
 * behalf. Split out purely so the hook's own bytecode stays under EIP-170's
 * 24576-byte deployed-code limit: embedding the vault's creation code via
 * `new` inside the hook was what pushed it over once the vault gained its
 * SwapVM auto-compound path. Same reasoning as WeirV2LaunchDeployer and
 * WeirV2GraduationExecutor for the factory. The vault still records the
 * real hook (never this deployer) as its privileged caller.
 */
contract WeirV2StakingVaultDeployer {
    error NotHook();
    error ZeroAddress();

    address public immutable hook;

    constructor(address hook_) {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
    }

    /**
     * @notice Deploys a fresh vault bound to `hook` for one pool's memecoin
     * and quote currency. Only the hook may call this, from `registerPool`.
     */
    function deployVault(IERC20 memecoin, address quoteToken, IWeirV2FeeEscrow feeEscrow)
        external
        returns (WeirV2StakingReward vault)
    {
        if (msg.sender != hook) revert NotHook();
        vault = new WeirV2StakingReward(hook, memecoin, quoteToken, feeEscrow);
    }
}
