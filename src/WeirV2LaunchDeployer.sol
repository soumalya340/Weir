// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WeirV2LauncherToken} from "./WeirV2LauncherToken.sol";
import {WeirV2BondingCurve} from "./WeirV2BondingCurve.sol";
import {WeirV2BuybackVault} from "./WeirV2BuybackVault.sol";
import {FeePolicySnapshot, IWeirV2FeeEscrow, IWeirV2FeePolicy} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice Every input WeirV2LaunchFactory hands the deployer to stand up one
 * launch. Grouped into a single calldata struct rather than a flat parameter
 * list so the deployer stays inside the EVM's 16-slot stack window when
 * compiled without the IR pipeline, which is the mode `forge coverage` uses.
 */
struct LaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    IWeirV2FeePolicy feePolicy;
    FeePolicySnapshot policy;
    IWeirV2FeeEscrow feeEscrow;
    WeirV2BuybackVault buybackVault;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 creatorTaxBps;
    bool buybackEnabled;
    uint256 graduationThreshold;
    uint256 supply;
    // Carried through from TokenParams.salt. Not yet consumed here: curve and
    // token deployment below still use plain `new`, not CREATE2, so
    // deterministic/vanity addresses and predictLaunchAddresses remain
    // unimplemented.
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    WeirV2LauncherToken.Socials socials;
}

/**
 * @title WeirV2LaunchDeployer
 * @notice Deploys the bonding curve and launch token pair for one weir v2
 * launch on WeirV2LaunchFactory's behalf. Split out into its own contract
 * purely so WeirV2LaunchFactory's own bytecode stays under EIP-170's
 * 24576-byte deployed-code limit: embedding two full contracts' creation
 * code via `new` inside the factory itself was the single largest
 * contributor to its size. Both new contracts still record the real
 * factory's address explicitly (never this deployer's), since they gate
 * privileged calls on it.
 */
contract WeirV2LaunchDeployer {
    // Metadata is stored on the token and read back by unbounded-return view
    // functions, so an unbounded write here becomes a permanently unreadable
    // token: `socials()` returns all five strings at once and would run out
    // of gas or time out an RPC node. Bounding the write is the only place
    // the limit can be enforced, since the strings are immutable afterwards.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Deploys a fresh curve/token pair and returns both addresses.
     * Both contracts are told `factory` (not this deployer) is their
     * privileged caller. Wiring the curve to its token via `initialize()` is
     * left to the factory itself, since that call is `onlyFactory`-gated.
     */
    function deployLaunch(LaunchDeployment calldata params)
        external
        onlyFactory
        returns (address token, address curve)
    {
        _requireMetadataWithinLimits(params);

        curve = address(
            new WeirV2BondingCurve(
                params.pairToken,
                params.creatorFeeRecipient,
                factory,
                params.feePolicy,
                params.policy,
                params.feeEscrow,
                params.buybackVault,
                params.phantomQuote,
                params.curveFeeBps,
                params.creatorTaxBps,
                params.buybackEnabled,
                params.graduationThreshold
            )
        );
        token = address(
            new WeirV2LauncherToken(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                curve,
                factory,
                params.supply
            )
        );
    }

    /**
     * @notice Reverts unless every metadata string fits its length cap.
     * @dev The factory already rejects an empty name or symbol, so only the
     * upper bound is checked here.
     */
    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
