// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev EIP-1271 contract wallet returning the magic value, so the registry's
/// SignatureChecker path can be exercised (TestCase 3.2.4).
contract MockSmartWallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function commitTo(address registry, address token, uint256 pledge, bool useAqua, bytes calldata sig) external {
        bytes32[] memory proof;
        WeirV2CommitmentRegistryLike(registry).commit(token, pledge, useAqua, sig, proof);
    }

    function claimFrom(address registry, address token) external returns (uint256) {
        return WeirV2CommitmentRegistryLike(registry).claimBond(token);
    }
}

interface WeirV2CommitmentRegistryLike {
    function commit(address token, uint256 pledgeQuote, bool useAqua, bytes calldata signature, bytes32[] calldata proof)
        external;
    function claimBond(address token) external returns (uint256 amount);
}

/// @dev ERC-20 quote that attempts to re-enter the registry during a fill
/// transfer, proving `nonReentrant` blocks it (TestCase 3.3.12). The inner
/// call's revert is swallowed so the outer fill can complete; the attempt
/// and its outcome are recorded.
contract MockReentrantQuote is ERC20 {
    address public registry;
    address public token;
    bool public attempted;
    bool public innerReverted;

    constructor() ERC20("Reentrant Quote", "rUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address registry_, address token_) external {
        registry = registry_;
        token = token_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (registry != address(0) && !attempted && from != address(0)) {
            attempted = true;
            (bool ok,) = registry.call(abi.encodeWithSignature("settle(address)", token));
            innerReverted = !ok;
        }
    }
}
