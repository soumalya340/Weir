// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeirV2BuybackVault} from "../src/WeirV2BuybackVault.sol";
import {
    FeePolicySnapshot,
    IWeirV2FeeEscrow,
    IWeirV2FeePolicy,
    IWeirV2LaunchFactory
} from "../src/interfaces/ILaunchpadV2.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Launch Token", "MLT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for WeirV2MemeHook, the vault's IWeirV2FeePolicy.
/// `_isAuthorizedLocker` treats `caller == address(feePolicy)` as always
/// authorized, so this mock's own address is one legitimate locker path;
/// the other (a launch's own curve, looked up from the factory) is
/// exercised through MockFactory below.
contract MockFeePolicy is IWeirV2FeePolicy {
    uint256 public protocolFeeShareBps_;
    address public protocolFeeRecipient_;
    IWeirV2FeeEscrow public feeEscrow_;

    constructor(uint256 protocolFeeShareBps__, address protocolFeeRecipient__, IWeirV2FeeEscrow feeEscrow__) {
        protocolFeeShareBps_ = protocolFeeShareBps__;
        protocolFeeRecipient_ = protocolFeeRecipient__;
        feeEscrow_ = feeEscrow__;
    }

    function protocolFeeShareBps() external view override returns (uint256) {
        return protocolFeeShareBps_;
    }

    function buybackBurnBps() external pure override returns (uint256) {
        return 5_000;
    }

    function protocolFeeRecipient() external view override returns (address) {
        return protocolFeeRecipient_;
    }

    function feeEscrow() external view override returns (IWeirV2FeeEscrow) {
        return feeEscrow_;
    }

    function maxInternalPriceImpactBps() external pure override returns (uint256) {
        return 300;
    }

    function feeSweepOperator() external view override returns (address) {
        return address(this);
    }

    function isFeeSweepOperator(address account) external view override returns (bool) {
        return account == address(this);
    }

    function currentFeePolicy() external view override returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: protocolFeeRecipient_,
            protocolFeeShareBps: uint16(protocolFeeShareBps_),
            buybackBurnBps: 5_000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 300,
            stakerFeeShareBps: 4_000
        });
    }
}

contract MockFactory is IWeirV2LaunchFactory {
    mapping(address => LaunchedToken) private _launches;

    function setCurve(address token, address curve) external {
        LaunchedToken storage l = _launches[token];
        l.token = token;
        l.curve = curve;
        l.exists = true;
    }

    function getLaunchedToken(address token) external view override returns (LaunchedToken memory) {
        return _launches[token];
    }
}

/// @dev Records creditToken calls the same way the staking-reward tests'
/// mock escrow does, so release() splits can be asserted directly.
contract MockFeeEscrow is IWeirV2FeeEscrow {
    mapping(address => mapping(address => uint256)) public tokenCredited;

    function credit(address) external payable override {}

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

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function balanceOfToken(address recipient, address token) external view override returns (uint256) {
        return tokenCredited[recipient][token];
    }
}

contract WeirV2BuybackVaultTest is Test {
    WeirV2BuybackVault internal vaultContract;
    MockToken internal token;
    MockFeePolicy internal feePolicy;
    MockFeeEscrow internal escrow;
    MockFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal protocolRecipient = makeAddr("protocolRecipient");
    address internal curve = makeAddr("curve");

    function setUp() public {
        token = new MockToken();
        escrow = new MockFeeEscrow();
        feePolicy = new MockFeePolicy(3_000, protocolRecipient, escrow);
        factory = new MockFactory();

        vaultContract = new WeirV2BuybackVault(owner, feePolicy, escrow);

        vm.prank(owner);
        vaultContract.setFactory(address(factory));

        factory.setCurve(address(token), curve);
        token.mint(address(feePolicy), 1_000_000e18);
        token.mint(curve, 1_000_000e18);

        vm.prank(address(feePolicy));
        token.approve(address(vaultContract), type(uint256).max);
        vm.prank(curve);
        token.approve(address(vaultContract), type(uint256).max);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(WeirV2BuybackVault.ZeroAddress.selector);
        new WeirV2BuybackVault(owner, IWeirV2FeePolicy(address(0)), escrow);

        vm.expectRevert(WeirV2BuybackVault.ZeroAddress.selector);
        new WeirV2BuybackVault(owner, feePolicy, IWeirV2FeeEscrow(address(0)));
    }

    function test_setFactory_onlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(WeirV2BuybackVault.AlreadyInitialized.selector);
        vaultContract.setFactory(address(0x1234));
    }

    function test_setFactory_onlyOwner() public {
        WeirV2BuybackVault fresh = new WeirV2BuybackVault(owner, feePolicy, escrow);

        vm.expectRevert();
        fresh.setFactory(address(factory));
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(WeirV2BuybackVault.OwnershipCannotBeRenounced.selector);
        vaultContract.renounceOwnership();
    }

    function test_lock_revertsForUnauthorizedCaller() public {
        vm.expectRevert(WeirV2BuybackVault.NotAuthorizedLocker.selector);
        vaultContract.lock(address(token), 100e18, creator, protocolRecipient, 3_000);
    }

    function test_lock_allowsFeePolicyCaller() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        assertEq(vaultContract.totalLocked(address(token)), 1_000e18);
        assertEq(token.balanceOf(address(vaultContract)), 1_000e18);
    }

    function test_lock_allowsLaunchsOwnCurve() public {
        vm.prank(curve);
        vaultContract.lock(address(token), 500e18, creator, protocolRecipient, 3_000);

        assertEq(vaultContract.totalLocked(address(token)), 500e18);
    }

    function test_lock_revertsOnZeroToken() public {
        vm.prank(address(feePolicy));
        vm.expectRevert(WeirV2BuybackVault.ZeroAddress.selector);
        vaultContract.lock(address(0), 100e18, creator, protocolRecipient, 3_000);
    }

    function test_lock_revertsOnInvalidVestingTerms() public {
        vm.prank(address(feePolicy));
        vm.expectRevert(WeirV2BuybackVault.InvalidVestingTerms.selector);
        vaultContract.lock(address(token), 100e18, address(0), protocolRecipient, 3_000);
    }

    function test_lock_noOpOnZeroAmount() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 0, creator, protocolRecipient, 3_000);
        assertEq(vaultContract.totalLocked(address(token)), 0);
    }

    function test_lock_revertsOnTermsMismatchWithinSameEpoch() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 100e18, creator, protocolRecipient, 3_000);

        address otherProtocolRecipient = makeAddr("otherProtocolRecipient");
        vm.prank(address(feePolicy));
        vm.expectRevert(WeirV2BuybackVault.VestingTermsMismatch.selector);
        vaultContract.lock(address(token), 100e18, creator, otherProtocolRecipient, 3_000);
    }

    function test_vestedAmount_growsLinearlyOverFiveYears() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        assertEq(vaultContract.vestedAmount(address(token)), 0);

        vm.warp(block.timestamp + vaultContract.VESTING_DURATION() / 2);
        assertApproxEqAbs(vaultContract.vestedAmount(address(token)), 500e18, 1e12);

        vm.warp(block.timestamp + vaultContract.VESTING_DURATION());
        assertEq(vaultContract.vestedAmount(address(token)), 1_000e18);
    }

    function test_release_revertsForNonBeneficiary() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);
        vm.warp(block.timestamp + vaultContract.VESTING_DURATION());

        vm.expectRevert(WeirV2BuybackVault.NotVestBeneficiary.selector);
        vaultContract.release(address(token));
    }

    function test_release_splitsBetweenCreatorAndProtocol() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);
        vm.warp(block.timestamp + vaultContract.VESTING_DURATION());

        vm.prank(creator);
        uint256 released = vaultContract.release(address(token));

        assertEq(released, 1_000e18);
        assertEq(escrow.tokenCredited(protocolRecipient, address(token)), 300e18);
        assertEq(escrow.tokenCredited(creator, address(token)), 700e18);
    }

    function test_release_returnsZeroWhenNothingVested() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        vm.prank(creator);
        uint256 released = vaultContract.release(address(token));
        assertEq(released, 0);
    }

    function test_updateCreatorRecipient_onlyFactory() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        address newRecipient = makeAddr("newRecipient");
        vm.expectRevert(WeirV2BuybackVault.NotFactory.selector);
        vaultContract.updateCreatorRecipient(address(token), newRecipient);

        vm.prank(address(factory));
        vaultContract.updateCreatorRecipient(address(token), newRecipient);

        (address creatorRecipient,,) = vaultContract.vestingTerms(address(token));
        assertEq(creatorRecipient, newRecipient);
    }

    function test_lockingAgainMidVest_shiftsWeightedAverageStart() public {
        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        vm.warp(block.timestamp + vaultContract.VESTING_DURATION() / 2);

        vm.prank(address(feePolicy));
        vaultContract.lock(address(token), 1_000e18, creator, protocolRecipient, 3_000);

        assertEq(vaultContract.totalLocked(address(token)), 2_000e18);
        // Before the top-up, 500e18 had linearly vested (half of a 1000e18,
        // five-year lock). A fresh equal-size deposit blends in a brand new
        // five-year schedule, pulling the combined vest's remaining duration
        // back out to 3.75 years — so immediately after, no more than that
        // same 500e18 can show as vested; it must not have grown.
        assertLe(vaultContract.vestedAmount(address(token)), 500e18);
    }
}
