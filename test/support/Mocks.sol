// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "../../src/interfaces/ISwapVM.sol";
import {FeePolicySnapshot, IWeirV2FeeEscrow, IWeirV2FeePolicy} from "../../src/interfaces/ILaunchpadV2.sol";

/// @dev 6-decimal ERC-20 quote standing in for USDC (TestCase shared fixture).
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burnable launch-token stand-in with open minting. Behaves like
/// WeirV2LauncherToken for the registry (which calls `burn()` on the tranche
/// it holds) and the staking vault (burnAndExit).
contract MockBurnableToken is ERC20, ERC20Burnable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer quote token: the recipient gets 1 wei less than the
/// nominal amount (burned). Used to prove delta-based accounting rejects
/// short delivery (bond receipt, TestCase 3.2.12).
contract MockTaxQuote is ERC20 {
    constructor() ERC20("Tax Quote", "TAXQ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            super._update(from, to, value - 1);
            _burn(from, 1);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Sender-tax quote token: the recipient gets the nominal amount but
/// the sender loses 1 wei extra (burned), so balance deltas exceed the
/// approved pull. Used for the CompoundOverspent guard (TestCase 6.13).
contract MockSenderTaxQuote is ERC20 {
    constructor() ERC20("Sender Tax Quote", "STAXQ") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            _burn(from, 1);
        }
    }
}

/// @dev Records every credit call so tests assert payouts without the full
/// escrow machinery. Mirrors the mocks already used in the pre-existing
/// staking/futarchy suites.
contract MockFeeEscrowFull is IWeirV2FeeEscrow {
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

/// @dev Minimal IWeirV2FeePolicy for bonding-curve tests: the curve only
/// reads `isFeeSweepOperator` (sweep gating).
contract MockFeePolicy is IWeirV2FeePolicy {
    mapping(address => bool) public operators;
    FeePolicySnapshot public policy;

    constructor() {
        policy = FeePolicySnapshot({
            protocolFeeRecipient: makeAddr_policy(),
            protocolFeeShareBps: 3000,
            buybackBurnBps: 5000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300,
            stakerFeeShareBps: 4000
        });
    }

    function makeAddr_policy() internal pure returns (address) {
        return address(0x00000000000000000000000000000000feeC9111);
    }

    function setOperator(address who, bool ok) external {
        operators[who] = ok;
    }

    function protocolFeeShareBps() external view returns (uint256) {
        return policy.protocolFeeShareBps;
    }

    function buybackBurnBps() external view returns (uint256) {
        return policy.buybackBurnBps;
    }

    function protocolFeeRecipient() external view returns (address) {
        return policy.protocolFeeRecipient;
    }

    function feeEscrow() external view returns (IWeirV2FeeEscrow) {
        return IWeirV2FeeEscrow(address(0));
    }

    function maxInternalPriceImpactBps() external view returns (uint256) {
        return policy.maxInternalPriceImpactBps;
    }

    function feeSweepOperator() external view returns (address) {
        return address(0);
    }

    function isFeeSweepOperator(address account) external view returns (bool) {
        return operators[account];
    }

    function currentFeePolicy() external view returns (FeePolicySnapshot memory) {
        return policy;
    }
}

/// @dev Minimal buyback-vault stand-in for bonding-curve tests: pulls the
/// bought tokens via transferFrom and records the call.
contract MockBuybackVault {
    uint256 public totalLocked;
    mapping(address => uint256) public lockedPerToken;

    function lock(address token, uint256 amount, address, address, uint16) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        totalLocked += amount;
        lockedPerToken[token] += amount;
    }
}

/// @dev Hook stand-in for staking-vault tests: acts as `onlyHook` caller and
/// as the fee-sweep-operator policy the vault queries in `compound`.
contract MockHookPolicy is IWeirV2FeePolicy {
    mapping(address => bool) public operators;
    FeePolicySnapshot public policy;

    function setOperator(address who, bool ok) external {
        operators[who] = ok;
    }

    function protocolFeeShareBps() external view returns (uint256) {
        return 3000;
    }

    function buybackBurnBps() external view returns (uint256) {
        return 5000;
    }

    function protocolFeeRecipient() external view returns (address) {
        return address(this);
    }

    function feeEscrow() external view returns (IWeirV2FeeEscrow) {
        return IWeirV2FeeEscrow(address(0));
    }

    function maxInternalPriceImpactBps() external view returns (uint256) {
        return 300;
    }

    function feeSweepOperator() external view returns (address) {
        return address(0);
    }

    function isFeeSweepOperator(address account) external view returns (bool) {
        return operators[account];
    }

    function currentFeePolicy() external view returns (FeePolicySnapshot memory) {
        return policy;
    }
}
