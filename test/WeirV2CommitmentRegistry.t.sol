// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeirV2CommitmentRegistry} from "../src/WeirV2CommitmentRegistry.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";
import {MockUSDC, MockBurnableToken, MockTaxQuote} from "./support/Mocks.sol";
import {MockSwapVM} from "./support/MockSwapVM.sol";
import {MockSmartWallet, MockReentrantQuote, ReenteringFactory} from "./support/WalletMocks.sol";
import {SwapVMOrderLib} from "../src/libraries/SwapVMOrderLib.sol";

/// @notice TestCase §3: WeirV2CommitmentRegistry.
/// The factory is an EOA (or a forwarder contract where noted); the router
/// is the programmable MockSwapVM shared fixture.
contract WeirV2CommitmentRegistryTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant PHANTOM = 10_000e6;
    uint256 internal constant TARGET = 1_000e6; // 1000 USDC
    uint16 internal constant DISCOUNT = 3000;

    address internal factory = makeAddr("factory");
    address internal creator = makeAddr("creator");
    address internal sink = makeAddr("sink");

    MockUSDC internal quote;
    MockBurnableToken internal token;
    MockSwapVM internal router;
    WeirV2CommitmentRegistry internal reg;

    event CampaignOpened(
        address indexed token,
        address indexed creator,
        address quoteToken,
        uint16 discountBps,
        uint256 targetQuote,
        uint256 committedTokens,
        uint256 opensAt,
        uint256 closesAt,
        bytes32 allowlistRoot
    );
    event Committed(address indexed token, address indexed backer, uint256 pledge, uint256 bond, bytes32 orderHash);
    event CommitmentFilled(address indexed token, address indexed backer, uint256 quoteIn, uint256 tokensOut);
    event CommitmentDefected(address indexed token, address indexed backer, uint256 pledge, uint256 bondForfeited);
    event CommitmentUnfilled(address indexed token, address indexed backer, uint256 pledge);
    event CampaignSettled(
        address indexed token,
        uint256 settledQuote,
        uint256 deliveredTokens,
        uint256 burnedTokens,
        uint256 forfeitedBonds,
        uint256 quoteForwarded
    );
    event CampaignExpired(address indexed token);
    event BondClaimed(address indexed token, address indexed backer, uint256 amount);

    function setUp() public {
        quote = new MockUSDC();
        token = new MockBurnableToken("Weir", "WEIR");
        router = new MockSwapVM(address(0));
        reg = new WeirV2CommitmentRegistry(factory, ISwapVM(address(router)));
    }

    // -- helpers ---------------------------------------------------------

    function _params(uint16 discount, uint256 target, uint256 oversub, uint256 opensAt, bytes32 root)
        internal
        pure
        returns (WeirV2CommitmentRegistry.CampaignParams memory)
    {
        return WeirV2CommitmentRegistry.CampaignParams({
            discountBps: discount,
            targetQuote: target,
            oversubscriptionBps: oversub,
            tradingOpensAt: opensAt,
            allowlistRoot: root
        });
    }

    function _defaultOpensAt() internal view returns (uint256) {
        return block.timestamp + 24 hours + 1;
    }

    /// @dev Opens a campaign for `token_` (pranked as factory), returns tranche.
    function _open(
        address token_,
        address quote_,
        uint256 phantom,
        uint256 supply,
        WeirV2CommitmentRegistry.CampaignParams memory p
    ) internal returns (uint256 committed) {
        vm.prank(factory);
        committed = reg.openCampaign(token_, address(0xC0C0), creator, quote_, phantom, supply, p);
    }

    function _openDefault() internal returns (uint256 committed) {
        return _open(
            address(token), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
    }

    /// @dev Campaign whose tranche divides evenly: TARGET_R x BPS x SUPPLY /
    /// (PHANTOM x (BPS - 3000)) == 1e23 exactly, so full-pledge fills deliver
    /// with no flooring dust and the spec's exact equalities hold literally.
    uint256 internal constant TARGET_R = 700e6;

    function _openRound() internal returns (uint256 committed) {
        committed = _open(
            address(token),
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET_R, 0, _defaultOpensAt(), bytes32(0))
        );
        assertEq(committed, 1e23);
    }

    function _backer(uint256 i) internal pure returns (uint256 key, address who) {
        key = uint256(keccak256(abi.encode("backer", i)));
        who = vm.addr(key);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Funds a backer, approves the bond, signs and commits.
    function _commit(uint256 key, address token_, uint256 pledge, bool useAqua) internal returns (bytes32 orderHash) {
        address who = vm.addr(key);
        ISwapVM.Order memory order;
        (order, orderHash) = reg.previewCommitmentOrder(token_, who, pledge, useAqua);
        bytes memory sig = useAqua ? bytes("") : _sign(key, orderHash);
        uint256 bond = (pledge * 2_000) / BPS;
        // Funded for the pledge plus the full fill at settle time.
        quote.mint(who, 2 * pledge + bond);
        vm.startPrank(who);
        quote.approve(address(reg), bond);
        quote.approve(address(router), type(uint256).max);
        reg.commit(token_, pledge, useAqua, sig, new bytes32[](0));
        vm.stopPrank();
    }

    /// @dev Plans a full honoured fill for a backer's pledge.
    function _planHonour(address token_, address quote_, uint256 key, uint256 pledge, uint256 quoteOut) internal {
        address who = vm.addr(key);
        (, bytes32 h) = reg.previewCommitmentOrder(token_, who, pledge, false);
        router.planFill(h, token_, quote_, 0, quoteOut);
    }

    /// @dev Tranche release + settle through the factory EOA.
    function _releaseAndSettle(address token_, uint256 committed) internal returns (uint256 forwarded) {
        MockBurnableToken(token_).mint(address(reg), committed);
        vm.warp(reg.getCampaign(token_).closesAt + 1);
        vm.prank(factory);
        forwarded = reg.settle(token_);
    }

    // -- 3.1 openCampaign --------------------------------------------------

    // 3.1.1: only the factory opens campaigns.
    function test_open_onlyFactory() public {
        vm.expectRevert(WeirV2CommitmentRegistry.NotFactory.selector);
        reg.openCampaign(
            address(token),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
    }

    // 3.1.2: native quote unsupported.
    function test_open_nativeQuoteUnsupported() public {
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.NativeQuoteUnsupported.selector);
        reg.openCampaign(
            address(token),
            address(0xC0C0),
            creator,
            address(0),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
    }

    // 3.1.3: discount bounds 2000..4000 inclusive.
    function test_open_discountBounds() public {
        MockBurnableToken t1 = new MockBurnableToken("A", "A");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidDiscount.selector);
        reg.openCampaign(
            address(t1),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(1999, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );

        MockBurnableToken t2 = new MockBurnableToken("B", "B");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidDiscount.selector);
        reg.openCampaign(
            address(t2),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(4001, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );

        MockBurnableToken t3 = new MockBurnableToken("C", "C");
        _open(address(t3), address(quote), PHANTOM, SUPPLY, _params(2000, TARGET, 0, _defaultOpensAt(), bytes32(0)));
        MockBurnableToken t4 = new MockBurnableToken("D", "D");
        _open(address(t4), address(quote), PHANTOM, SUPPLY, _params(4000, TARGET, 0, _defaultOpensAt(), bytes32(0)));
    }

    // 3.1.4: oversubscription bounds; 0 selects the 14000 default.
    function test_open_oversubscriptionBounds() public {
        MockBurnableToken t1 = new MockBurnableToken("A", "A");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidOversubscription.selector);
        reg.openCampaign(
            address(t1),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 9999, _defaultOpensAt(), bytes32(0))
        );

        MockBurnableToken t2 = new MockBurnableToken("B", "B");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidOversubscription.selector);
        reg.openCampaign(
            address(t2),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 20001, _defaultOpensAt(), bytes32(0))
        );

        MockBurnableToken t3 = new MockBurnableToken("C", "C");
        _open(address(t3), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0)));
        assertEq(reg.getCampaign(address(t3)).maxPledged, (TARGET * 14_000) / BPS);

        MockBurnableToken t4 = new MockBurnableToken("D", "D");
        _open(
            address(t4),
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 10_000, _defaultOpensAt(), bytes32(0))
        );
        assertEq(reg.getCampaign(address(t4)).maxPledged, TARGET);

        MockBurnableToken t5 = new MockBurnableToken("E", "E");
        _open(
            address(t5),
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 20_000, _defaultOpensAt(), bytes32(0))
        );
        assertEq(reg.getCampaign(address(t5)).maxPledged, TARGET * 2);
    }

    // 3.1.5: 24h floor, exactly 24h accepted.
    function test_open_campaignTooShort() public {
        MockBurnableToken t1 = new MockBurnableToken("A", "A");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignTooShort.selector);
        reg.openCampaign(
            address(t1),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, block.timestamp + 24 hours - 1, bytes32(0))
        );

        MockBurnableToken t2 = new MockBurnableToken("B", "B");
        _open(
            address(t2),
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, block.timestamp + 24 hours, bytes32(0))
        );
    }

    // 3.1.6: derived tranche matches Q*supply*1e4/(phantom*(1e4-d)).
    function test_open_derivedTrancheTable() public {
        uint256[3] memory targets = [uint256(1000e6), uint256(2000e6), uint256(5000e6)];
        uint16[3] memory discounts = [uint16(3000), uint16(2000), uint16(4000)];
        uint256[3] memory phantoms = [uint256(10_000e6), uint256(20_000e6), uint256(100_000e6)];
        uint256[3] memory supplies = [uint256(1_000_000e18), uint256(2_000_000e18), uint256(1_000_000e18)];
        for (uint256 i = 0; i < 3; ++i) {
            MockBurnableToken t = new MockBurnableToken("T", "T");
            uint256 committed = _open(
                address(t),
                address(quote),
                phantoms[i],
                supplies[i],
                _params(discounts[i], targets[i], 0, _defaultOpensAt(), bytes32(0))
            );
            uint256 expected = Math.mulDiv(targets[i] * BPS, supplies[i], phantoms[i] * (BPS - discounts[i]));
            assertEq(committed, expected);
        }
    }

    // 3.1.6b: tranche above 50% of supply, and rounding to zero, revert.
    function test_open_trancheTooLargeAndZero() public {
        MockBurnableToken t1 = new MockBurnableToken("A", "A");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.TrancheTooLarge.selector);
        reg.openCampaign(
            address(t1),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(4000, 400_000e6, 0, _defaultOpensAt(), bytes32(0))
        );

        MockBurnableToken t2 = new MockBurnableToken("B", "B");
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.ZeroAmount.selector);
        reg.openCampaign(
            address(t2),
            address(0xC0C0),
            creator,
            address(quote),
            1e40,
            SUPPLY,
            _params(DISCOUNT, 100e6, 0, _defaultOpensAt(), bytes32(0))
        );
    }

    // 3.1.7: double open reverts.
    function test_open_doubleOpen() public {
        _openDefault();
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignExists.selector);
        reg.openCampaign(
            address(token),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
    }

    // 3.1.8: stored fields and event.
    function test_open_storedFieldsAndEvent() public {
        uint256 opensAt = _defaultOpensAt();
        bytes32 root = keccak256("root");
        uint256 expectedCommitted = Math.mulDiv(TARGET * BPS, SUPPLY, PHANTOM * (BPS - DISCOUNT));

        vm.prank(factory);
        vm.expectEmit(true, true, false, true);
        emit CampaignOpened(
            address(token), creator, address(quote), DISCOUNT, TARGET, expectedCommitted, block.timestamp, opensAt, root
        );
        uint256 committed = reg.openCampaign(
            address(token),
            address(0xC0C0),
            creator,
            address(quote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, opensAt, root)
        );
        assertEq(committed, expectedCommitted);

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(uint8(c.status), uint8(WeirV2CommitmentRegistry.CampaignStatus.Open));
        assertEq(c.maxPledged, (TARGET * 14_000) / BPS);
        assertEq(c.closesAt, opensAt);
        assertEq(c.orderDeadline, uint40(opensAt + 30 days));
        assertEq(c.nonceBit, uint32(uint256(keccak256(abi.encode(address(reg), address(token))))));
        assertEq(c.committedTokens, expectedCommitted);
        assertTrue(reg.hasCampaign(address(token)));
    }

    // -- 3.2 commit ----------------------------------------------------------

    // 3.2.1: happy path — bond pulled, state stored, event with router hash.
    function test_commit_happyPathSignature() public {
        uint256 committed = _openDefault();
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        (uint256 key, address who) = _backer(1);

        (, bytes32 h) = reg.previewCommitmentOrder(address(token), who, pledge, false);
        bytes memory sig = _sign(key, h);
        quote.mint(who, pledge + bond);
        vm.startPrank(who);
        quote.approve(address(reg), bond);
        quote.approve(address(router), type(uint256).max);
        vm.expectEmit(true, true, false, true);
        emit Committed(address(token), who, pledge, bond, h);
        reg.commit(address(token), pledge, false, sig, new bytes32[](0));
        vm.stopPrank();

        WeirV2CommitmentRegistry.Commitment memory cm = reg.getCommitment(address(token), who);
        assertEq(cm.pledge, pledge);
        assertEq(cm.bond, bond);
        assertEq(cm.signature, sig);
        assertEq(uint8(cm.outcome), uint8(WeirV2CommitmentRegistry.Outcome.Pending));
        address[] memory backers = reg.backersOf(address(token));
        assertEq(backers.length, 1);
        assertEq(backers[0], who);

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(c.totalPledged, pledge);
        assertEq(c.totalBonded, bond);
        assertEq(reg.outstandingPledge(who), pledge);
        assertEq(quote.balanceOf(address(reg)), bond);
        assertGt(committed, 0);
    }

    // 3.2.2: Aqua mode — empty signature, bit 254 set in preview order.
    function test_commit_happyPathAqua() public {
        _openDefault();
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        (, address who) = _backer(2);
        quote.mint(who, pledge + bond);
        vm.startPrank(who);
        quote.approve(address(reg), bond);
        reg.commit(address(token), pledge, true, bytes(""), new bytes32[](0));
        vm.stopPrank();

        WeirV2CommitmentRegistry.Commitment memory cm = reg.getCommitment(address(token), who);
        assertTrue(cm.useAqua);
        (ISwapVM.Order memory order,) = reg.previewCommitmentOrder(address(token), who, pledge, true);
        assertEq((order.traits >> 254) & 1, 1);
        (ISwapVM.Order memory sigOrder,) = reg.previewCommitmentOrder(address(token), who, pledge, false);
        assertEq((sigOrder.traits >> 254) & 1, 0);
    }

    // 3.2.3: wrong signer or wrong amount fails signature check.
    function test_commit_badSignature() public {
        _openDefault();
        uint256 pledge = 100e6;
        (uint256 key, address who) = _backer(3);
        (uint256 otherKey,) = _backer(99);
        quote.mint(who, pledge * 3);
        vm.startPrank(who);
        quote.approve(address(reg), type(uint256).max);

        (, bytes32 h) = reg.previewCommitmentOrder(address(token), who, pledge, false);
        bytes memory wrongSigner = _sign(otherKey, h);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidSignature.selector);
        reg.commit(address(token), pledge, false, wrongSigner, new bytes32[](0));

        // Signed for pledge P, submitted for 2P: hash mismatch.
        (, bytes32 h2) = reg.previewCommitmentOrder(address(token), who, pledge * 2, false);
        h2;
        bytes memory wrongAmount = _sign(key, h);
        vm.expectRevert(WeirV2CommitmentRegistry.InvalidSignature.selector);
        reg.commit(address(token), pledge * 2, false, wrongAmount, new bytes32[](0));
        vm.stopPrank();
    }

    // 3.2.4: EIP-1271 contract wallet can commit.
    function test_commit_smartWalletBacker() public {
        _openDefault();
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        MockSmartWallet wallet = new MockSmartWallet();
        quote.mint(address(wallet), pledge + bond);
        wallet.approveToken(address(quote), address(reg), bond);
        wallet.approveToken(address(quote), address(router), type(uint256).max);
        wallet.commitTo(address(reg), address(token), pledge, false, bytes(""));

        WeirV2CommitmentRegistry.Commitment memory cm = reg.getCommitment(address(token), address(wallet));
        assertEq(cm.pledge, pledge);
        assertEq(cm.bond, bond);
    }

    // 3.2.5: closed campaign and unknown token.
    function test_commit_closedAndUnknown() public {
        _openDefault();
        (uint256 key,) = _backer(4);
        uint256 pledge = 100e6;
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), vm.addr(key), pledge, false);
        bytes memory sig = _sign(key, h);
        quote.mint(vm.addr(key), pledge * 2);
        vm.prank(vm.addr(key));
        quote.approve(address(reg), type(uint256).max);

        vm.warp(reg.getCampaign(address(token)).closesAt);
        vm.prank(vm.addr(key));
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignClosed.selector);
        reg.commit(address(token), pledge, false, sig, new bytes32[](0));

        address unknown = address(new MockBurnableToken("U", "U"));
        vm.prank(vm.addr(key));
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignNotOpen.selector);
        reg.commit(unknown, pledge, false, sig, new bytes32[](0));
    }

    // 3.2.6: duplicate backer reverts.
    function test_commit_duplicateBacker() public {
        _openDefault();
        (uint256 key,) = _backer(5);
        _commit(key, address(token), 100e6, false);
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), vm.addr(key), 100e6, false);
        vm.prank(vm.addr(key));
        vm.expectRevert(WeirV2CommitmentRegistry.AlreadyCommitted.selector);
        reg.commit(address(token), 100e6, false, _sign(key, h), new bytes32[](0));
    }

    // 3.2.7: pledges up to 1.4Q pass; the one crossing it reverts.
    function test_commit_oversubscriptionCeiling() public {
        _openDefault();
        uint256 leg = TARGET / 10; // 0.1 Q
        for (uint256 i = 0; i < 14; ++i) {
            (uint256 key,) = _backer(100 + i);
            _commit(key, address(token), leg, false);
        }
        assertEq(reg.getCampaign(address(token)).totalPledged, (TARGET * 14_000) / BPS);

        (uint256 key15,) = _backer(200);
        address who15 = vm.addr(key15);
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), who15, 1e6, false);
        quote.mint(who15, 1e6 * 2);
        vm.startPrank(who15);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.OverSubscribed.selector);
        reg.commit(address(token), 1e6, false, _sign(key15, h), new bytes32[](0));
        vm.stopPrank();
    }

    // 3.2.8: 65th backer reverts (64 x 20e6 fits inside 1.4Q so the cap,
    // not oversubscription, is what trips).
    function test_commit_tooManyCommitments() public {
        _openDefault();
        for (uint256 i = 0; i < 64; ++i) {
            (uint256 key,) = _backer(300 + i);
            _commit(key, address(token), 20e6, false);
        }
        assertEq(reg.getCampaign(address(token)).totalPledged, 64 * 20e6);
        (uint256 key65,) = _backer(400);
        address who65 = vm.addr(key65);
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), who65, 20e6, false);
        quote.mint(who65, 20e6 * 2);
        vm.startPrank(who65);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.TooManyCommitments.selector);
        reg.commit(address(token), 20e6, false, _sign(key65, h), new bytes32[](0));
        vm.stopPrank();
    }

    // 3.2.9: allowlisted campaign enforces proofs; open campaigns ignore them.
    function test_commit_allowlist() public {
        (uint256 keyA,) = _backer(501);
        (uint256 keyB,) = _backer(502);
        address a = vm.addr(keyA);
        address b = vm.addr(keyB);
        bytes32 leafA = keccak256(abi.encodePacked(a));
        bytes32 leafB = keccak256(abi.encodePacked(b));
        bytes32 root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));

        MockBurnableToken gated = new MockBurnableToken("G", "G");
        _open(address(gated), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), root));

        uint256 pledge = 100e6;
        // Valid proof passes.
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        (, bytes32 hA) = reg.previewCommitmentOrder(address(gated), a, pledge, false);
        quote.mint(a, pledge * 2);
        vm.startPrank(a);
        quote.approve(address(reg), type(uint256).max);
        reg.commit(address(gated), pledge, false, _sign(keyA, hA), proofA);
        vm.stopPrank();

        // Empty proof reverts.
        (, bytes32 hB) = reg.previewCommitmentOrder(address(gated), b, pledge, false);
        quote.mint(b, pledge * 2);
        vm.startPrank(b);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.NotAllowlisted.selector);
        reg.commit(address(gated), pledge, false, _sign(keyB, hB), new bytes32[](0));

        // Someone else's proof reverts.
        (uint256 keyS,) = _backer(503);
        address s = vm.addr(keyS);
        (, bytes32 hS) = reg.previewCommitmentOrder(address(gated), s, pledge, false);
        quote.mint(s, pledge * 2);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.NotAllowlisted.selector);
        reg.commit(address(gated), pledge, false, _sign(keyS, hS), proofA);
        vm.stopPrank();

        // Open campaign ignores even garbage proofs.
        _openDefault();
        bytes32[] memory junk = new bytes32[](1);
        junk[0] = keccak256("junk");
        (uint256 keyO,) = _backer(504);
        address o = vm.addr(keyO);
        (, bytes32 hO) = reg.previewCommitmentOrder(address(token), o, pledge, false);
        quote.mint(o, pledge * 2);
        vm.startPrank(o);
        quote.approve(address(reg), type(uint256).max);
        reg.commit(address(token), pledge, false, _sign(keyO, hO), junk);
        vm.stopPrank();
    }

    // 3.2.10: single-campaign exposure cap is exact at 1.2x pledge.
    function test_commit_exposureCapSingle() public {
        _openDefault();
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS; // 20e6
        (uint256 key,) = _backer(505);
        address who = vm.addr(key);
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), who, pledge, false);
        bytes memory sig = _sign(key, h);

        quote.mint(who, pledge + bond - 1);
        vm.startPrank(who);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                WeirV2CommitmentRegistry.ExposureCapExceeded.selector, pledge + bond - 1, pledge + bond
            )
        );
        reg.commit(address(token), pledge, false, sig, new bytes32[](0));
        vm.stopPrank();

        quote.mint(who, 1);
        vm.prank(who);
        reg.commit(address(token), pledge, false, sig, new bytes32[](0));
        assertEq(reg.getCommitment(address(token), who).pledge, pledge);
    }

    // 3.2.11: exposure aggregates across campaigns until one settles out.
    function test_commit_exposureCapAcrossCampaigns() public {
        MockBurnableToken tokenB = new MockBurnableToken("BB", "BB");
        uint256 farOut = block.timestamp + 60 days;
        _open(
            address(token), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
        uint256 committedB =
            _open(address(tokenB), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, farOut, bytes32(0)));
        assertGt(committedB, 0);

        (uint256 key,) = _backer(506);
        address who = vm.addr(key);
        quote.mint(who, 100e6);
        // 80e6 pledge needs 96e6: passes with 100e6.
        _commitTo(who, key, address(token), 80e6);
        assertEq(reg.outstandingPledge(who), 80e6);

        // Second 80e6 pledge needs 80 + 80 + 16 = 176e6: reverts.
        (, bytes32 hB) = reg.previewCommitmentOrder(address(tokenB), who, 80e6, false);
        vm.prank(who);
        quote.approve(address(reg), type(uint256).max);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(WeirV2CommitmentRegistry.ExposureCapExceeded.selector, 100e6 - 16e6, 176e6)
        );
        reg.commit(address(tokenB), 80e6, false, _sign(key, hB), new bytes32[](0));

        // After campaign A expires the pledge clears; reclaiming the bond
        // restores the balance so B accepts.
        vm.warp(reg.getCampaign(address(token)).orderDeadline + 1);
        reg.expire(address(token));
        assertEq(reg.outstandingPledge(who), 0);
        vm.prank(who);
        uint256 reclaimed = reg.claimBond(address(token));
        assertEq(reclaimed, 16e6);
        vm.prank(who);
        reg.commit(address(tokenB), 80e6, false, _sign(key, hB), new bytes32[](0));
        assertEq(reg.getCommitment(address(tokenB), who).pledge, 80e6);
    }

    /// @dev Commit helper when funding/approvals are managed by the caller.
    function _commitTo(address who, uint256 key, address token_, uint256 pledge) internal {
        (, bytes32 h) = reg.previewCommitmentOrder(token_, who, pledge, false);
        vm.startPrank(who);
        quote.approve(address(reg), type(uint256).max);
        reg.commit(token_, pledge, false, _sign(key, h), new bytes32[](0));
        vm.stopPrank();
    }

    // 3.2.12: fee-on-transfer bond token — received != bond reverts.
    function test_commit_feeOnTransferBondReverts() public {
        MockTaxQuote taxQuote = new MockTaxQuote();
        MockBurnableToken t = new MockBurnableToken("T", "T");
        WeirV2CommitmentRegistry regTax = new WeirV2CommitmentRegistry(factory, ISwapVM(address(router)));
        vm.prank(factory);
        regTax.openCampaign(
            address(t),
            address(0xC0C0),
            creator,
            address(taxQuote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );

        uint256 pledge = 100e6;
        (uint256 key,) = _backer(507);
        address who = vm.addr(key);
        (, bytes32 h) = regTax.previewCommitmentOrder(address(t), who, pledge, false);
        taxQuote.mint(who, pledge * 2);
        vm.startPrank(who);
        taxQuote.approve(address(regTax), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.ZeroAmount.selector);
        regTax.commit(address(t), pledge, false, _sign(key, h), new bytes32[](0));
        vm.stopPrank();
    }

    // 3.2.13: zero and dust pledges revert.
    function test_commit_zeroAndDustPledge() public {
        _openDefault();
        (uint256 key,) = _backer(508);
        address who = vm.addr(key);
        (, bytes32 h0) = reg.previewCommitmentOrder(address(token), who, 0, false);
        vm.prank(who);
        vm.expectRevert(WeirV2CommitmentRegistry.ZeroAmount.selector);
        reg.commit(address(token), 0, false, _sign(key, h0), new bytes32[](0));

        // bond = 4 * 2000 / 10000 = 0.
        (, bytes32 h1) = reg.previewCommitmentOrder(address(token), who, 4, false);
        quote.mint(who, 100);
        vm.startPrank(who);
        quote.approve(address(reg), type(uint256).max);
        vm.expectRevert(WeirV2CommitmentRegistry.ZeroAmount.selector);
        reg.commit(address(token), 4, false, _sign(key, h1), new bytes32[](0));
        vm.stopPrank();
    }

    // -- 3.3 settle ----------------------------------------------------------

    /// @dev Drains a backer's quote so their fill fails (defection).
    /// Reads the balance BEFORE pranking: even a view staticcall would
    /// consume the prank and leave the transfer unauthenticated.
    function _defect(address who) internal {
        uint256 bal = quote.balanceOf(who);
        vm.prank(who);
        quote.transfer(sink, bal);
    }

    // 3.3.1: settle gating — factory-only, tranche-first, closed, once.
    function test_settle_gating() public {
        uint256 committed = _openDefault();
        (uint256 key,) = _backer(601);
        _commit(key, address(token), 100e6, false);

        vm.expectRevert(WeirV2CommitmentRegistry.NotFactory.selector);
        reg.settle(address(token));

        // No tranche released yet.
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(WeirV2CommitmentRegistry.TrancheNotReceived.selector, committed, 0));
        reg.settle(address(token));

        // Tranche present but campaign still open.
        MockBurnableToken(token).mint(address(reg), committed);
        uint256 closesAt = reg.getCampaign(address(token)).closesAt;
        vm.warp(closesAt - 1);
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignNotClosed.selector);
        reg.settle(address(token));

        // Settles once; the second call is closed.
        _planHonour(address(token), address(quote), key, 100e6, 100e6);
        vm.warp(closesAt + 1);
        vm.prank(factory);
        reg.settle(address(token));
        vm.prank(factory);
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignClosed.selector);
        reg.settle(address(token));
    }

    // 3.3.2: all honour — fills deliver the whole tranche, supply intact.
    function test_settle_allHonour() public {
        uint256 committed = _openRound();
        uint256 n = 10;
        uint256 pledge = TARGET_R / n;
        uint256[] memory keys = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            (uint256 key,) = _backer(610 + i);
            keys[i] = key;
            _commit(key, address(token), pledge, false);
            _planHonour(address(token), address(quote), key, pledge, pledge);
        }

        // Fund the tranche exactly: totalSupply == committed.
        token.mint(address(reg), committed);
        uint256 supplyBefore = token.totalSupply();

        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        vm.expectEmit(true, false, false, true);
        emit CampaignSettled(address(token), TARGET_R, committed, 0, 0, TARGET_R);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(forwarded, TARGET_R);
        assertEq(c.settledQuote, TARGET_R);
        assertEq(c.deliveredTokens, committed);
        assertEq(c.burnedTokens, 0);
        assertEq(c.forfeitedBonds, 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(quote.balanceOf(factory), TARGET_R);
        for (uint256 i = 0; i < n; ++i) {
            address who = vm.addr(keys[i]);
            assertEq(
                uint8(reg.getCommitment(address(token), who).outcome), uint8(WeirV2CommitmentRegistry.Outcome.Filled)
            );
            assertEq(reg.outstandingPledge(who), 0);
        }
        // Router allowance reset.
        assertEq(token.allowance(address(reg), address(router)), 0);
    }

    // 3.3.3: all defect — tranche burns, bonds forward to the factory.
    function test_settle_allDefect() public {
        uint256 committed = _openDefault();
        uint256 n = 3;
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        for (uint256 i = 0; i < n; ++i) {
            (uint256 key,) = _backer(630 + i);
            _commit(key, address(token), pledge, false);
            _planHonour(address(token), address(quote), key, pledge, pledge);
            _defect(vm.addr(key));
        }

        token.mint(address(reg), committed);
        uint256 supplyBefore = token.totalSupply();

        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(c.settledQuote, 0);
        assertEq(c.deliveredTokens, 0);
        assertEq(c.burnedTokens, committed);
        assertEq(c.forfeitedBonds, n * bond);
        assertEq(token.totalSupply(), supplyBefore - committed);
        assertEq(forwarded, n * bond);
        assertEq(quote.balanceOf(factory), n * bond);
        for (uint256 i = 0; i < n; ++i) {
            assertEq(
                uint8(reg.getCommitment(address(token), vm.addr(_backerKey(i))).outcome),
                uint8(WeirV2CommitmentRegistry.Outcome.Defected)
            );
        }
    }

    function _backerKey(uint256 i) internal pure returns (uint256) {
        (uint256 key,) = _backer(630 + i);
        return key;
    }

    // 3.3.4: partial honour — 6 of 10 fill; bonds stay for the fillers.
    function test_settle_partialHonour() public {
        uint256 committed = _openRound();
        uint256 n = 10;
        uint256 pledge = TARGET_R / n;
        uint256 bond = (pledge * 2_000) / BPS;
        for (uint256 i = 0; i < n; ++i) {
            (uint256 key,) = _backer(640 + i);
            _commit(key, address(token), pledge, false);
            _planHonour(address(token), address(quote), key, pledge, pledge);
            if (i >= 6) _defect(vm.addr(key));
        }

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(c.settledQuote, 6 * pledge);
        assertEq(c.deliveredTokens, (committed * 6) / 10);
        assertEq(c.burnedTokens, (committed * 4) / 10);
        assertEq(c.forfeitedBonds, 4 * bond);
        // Only settled quote forwards; all ten bonds stay in the registry
        // (fillers claim theirs plus a forfeit share later).
        assertEq(forwarded, 6 * pledge);
        assertEq(quote.balanceOf(factory), 6 * pledge);
        assertEq(quote.balanceOf(address(reg)), 10 * bond);
    }

    // 3.3.5: over-subscribed with defectors — target fills exactly, the tail
    // stays Unfilled with refundable bonds.
    function test_settle_oversubscribedDefectorsSkipped() public {
        uint256 committed = _openRound();
        uint256 leg = TARGET_R / 10;
        uint256 bond = (leg * 2_000) / BPS;
        uint256 n = 14;
        uint256[] memory keys = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            (uint256 key,) = _backer(650 + i);
            keys[i] = key;
            _commit(key, address(token), leg, false);
            _planHonour(address(token), address(quote), key, leg, leg);
        }
        // Backers #3 and #7 (1-based) defect.
        _defect(vm.addr(keys[2]));
        _defect(vm.addr(keys[6]));

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(c.settledQuote, TARGET_R);
        assertEq(forwarded, TARGET_R);
        assertEq(c.forfeitedBonds, 2 * bond);
        // Ten honest fills deliver the whole tranche exactly.
        assertEq(c.deliveredTokens, committed);
        assertEq(c.burnedTokens, 0);
        // Fillers 1,2,4,5,6,8,9,10,11,12 (1-based) Filled...
        uint256 filled = 0;
        for (uint256 i = 0; i < 12; ++i) {
            if (i == 2 || i == 6) {
                assertEq(
                    uint8(reg.getCommitment(address(token), vm.addr(keys[i])).outcome),
                    uint8(WeirV2CommitmentRegistry.Outcome.Defected)
                );
            } else {
                assertEq(
                    uint8(reg.getCommitment(address(token), vm.addr(keys[i])).outcome),
                    uint8(WeirV2CommitmentRegistry.Outcome.Filled)
                );
                filled++;
            }
        }
        assertEq(filled, 10);
        // ...the tail never attempted: Unfilled with refundable bonds.
        for (uint256 i = 12; i < 14; ++i) {
            WeirV2CommitmentRegistry.Commitment memory cm = reg.getCommitment(address(token), vm.addr(keys[i]));
            assertEq(uint8(cm.outcome), uint8(WeirV2CommitmentRegistry.Outcome.Unfilled));
            vm.prank(vm.addr(keys[i]));
            uint256 claimed = reg.claimBond(address(token));
            assertEq(claimed, bond);
        }
    }

    // 3.3.6: the last fill scales pro rata when the remainder is short.
    function test_settle_lastFillPartial() public {
        uint256 committed = _openDefault();
        (uint256 key1,) = _backer(660);
        (uint256 key2,) = _backer(661);
        _commit(key1, address(token), 600e6, false);
        _commit(key2, address(token), 600e6, false);
        _planHonour(address(token), address(quote), key1, 600e6, 600e6);
        // Remainder after backer 1 is 400e6 < 600e6 pledge.
        _planHonour(address(token), address(quote), key2, 600e6, 400e6);

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        reg.settle(address(token));

        WeirV2CommitmentRegistry.Commitment memory cm2 = reg.getCommitment(address(token), vm.addr(key2));
        assertEq(uint8(cm2.outcome), uint8(WeirV2CommitmentRegistry.Outcome.Filled));
        assertEq(cm2.filledQuote, 400e6);
        uint256 allocation2 = Math.mulDiv(600e6, committed, TARGET);
        uint256 fillTokens = Math.mulDiv(400e6, allocation2, 600e6);
        assertEq(cm2.filledTokens, fillTokens);
        assertEq(reg.getCampaign(address(token)).settledQuote, TARGET);
    }

    // 3.3.7: router "success" without quote movement is a defection.
    function test_settle_routerSuccessWrongDelta() public {
        uint256 committed = _openDefault();
        (uint256 key,) = _backer(662);
        _commit(key, address(token), 100e6, false);
        (, bytes32 h) = reg.previewCommitmentOrder(address(token), vm.addr(key), 100e6, false);
        router.planFill(h, address(token), address(quote), 0, 100e6);
        router.planMode(h, MockSwapVM.Mode.Underdeliver);

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        reg.settle(address(token));

        WeirV2CommitmentRegistry.Commitment memory cm = reg.getCommitment(address(token), vm.addr(key));
        assertEq(uint8(cm.outcome), uint8(WeirV2CommitmentRegistry.Outcome.Defected));
        assertEq(reg.getCampaign(address(token)).settledQuote, 0);
    }

    // 3.3.9: expired first, then settle — whole tranche burns, nothing fills.
    function test_settle_expiredThenGraduated() public {
        uint256 committed = _openDefault();
        (uint256 key,) = _backer(663);
        _commit(key, address(token), 100e6, false);
        _planHonour(address(token), address(quote), key, 100e6, 100e6);

        vm.warp(reg.getCampaign(address(token)).orderDeadline + 1);
        reg.expire(address(token));

        token.mint(address(reg), committed);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(forwarded, 0);
        assertEq(c.settledQuote, 0);
        assertEq(c.deliveredTokens, 0);
        assertEq(c.burnedTokens, committed);
        assertEq(
            uint8(reg.getCommitment(address(token), vm.addr(key)).outcome),
            uint8(WeirV2CommitmentRegistry.Outcome.Unfilled)
        );
        assertEq(router.callCount(), 0);
    }

    // 3.3.10: past orderDeadline without expire takes the same branch.
    function test_settle_pastDeadlineWithoutExpire() public {
        uint256 committed = _openDefault();
        (uint256 key,) = _backer(664);
        _commit(key, address(token), 100e6, false);
        _planHonour(address(token), address(quote), key, 100e6, 100e6);

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).orderDeadline + 1);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(token));

        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(forwarded, 0);
        assertEq(c.burnedTokens, committed);
        assertEq(
            uint8(reg.getCommitment(address(token), vm.addr(key)).outcome),
            uint8(WeirV2CommitmentRegistry.Outcome.Unfilled)
        );
        assertEq(router.callCount(), 0);
    }

    // 3.3.11: 64 backers settle within the block gas limit.
    function test_settle_gasBound64Backers() public {
        _openDefault();
        for (uint256 i = 0; i < 64; ++i) {
            (uint256 key,) = _backer(700 + i);
            _commit(key, address(token), 20e6, false);
            _planHonour(address(token), address(quote), key, 20e6, 20e6);
        }
        uint256 committed = reg.getCampaign(address(token)).committedTokens;
        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);

        uint256 gasBefore = gasleft();
        vm.prank(factory);
        reg.settle(address(token));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("settle-64 gas", gasUsed);
        assertLt(gasUsed, 30_000_000);
        assertEq(uint8(reg.getCampaign(address(token)).status), uint8(WeirV2CommitmentRegistry.CampaignStatus.Settled));
    }

    // 3.3.12: a quote token re-entering settle() mid-fill is blocked by
    // nonReentrant (reached through the factory so onlyFactory passes).
    function test_settle_reentrancyBlocked() public {
        ReenteringFactory factoryC = new ReenteringFactory();
        WeirV2CommitmentRegistry regR = new WeirV2CommitmentRegistry(address(factoryC), ISwapVM(address(router)));
        factoryC.setReg(address(regR));
        MockReentrantQuote rquote = new MockReentrantQuote();
        MockBurnableToken t = new MockBurnableToken("T", "T");

        vm.prank(address(factoryC));
        uint256 committed = regR.openCampaign(
            address(t),
            address(0xC0C0),
            creator,
            address(rquote),
            PHANTOM,
            SUPPLY,
            _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );

        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        (uint256 key,) = _backer(764);
        address who = vm.addr(key);
        (, bytes32 h) = regR.previewCommitmentOrder(address(t), who, pledge, false);
        rquote.mint(who, 2 * pledge + bond);
        vm.startPrank(who);
        rquote.approve(address(regR), bond);
        rquote.approve(address(router), type(uint256).max);
        regR.commit(address(t), pledge, false, _sign(key, h), new bytes32[](0));
        vm.stopPrank();
        router.planFill(h, address(t), address(rquote), 0, pledge);

        // Arm only now: the bond pull above must not trigger the attempt.
        rquote.armViaFactory(address(factoryC), address(t));
        t.mint(address(regR), committed);
        vm.warp(regR.getCampaign(address(t)).closesAt + 1);

        factoryC.settleThrough(address(t));

        assertTrue(rquote.attempted());
        assertTrue(factoryC.guardTripped());
        WeirV2CommitmentRegistry.Commitment memory cm = regR.getCommitment(address(t), who);
        assertEq(uint8(cm.outcome), uint8(WeirV2CommitmentRegistry.Outcome.Filled));
        assertEq(regR.getCampaign(address(t)).settledQuote, pledge);
    }

    // -- 3.4 claimBond / expire ------------------------------------------------

    /// @dev Two fillers (420/280) + one defector (100, committed second):
    /// settled 700 == TARGET_R, forfeited == one bond.
    function _settledWithForfeit() internal returns (uint256 bondA, uint256 bondB, address a, address b, address d) {
        uint256 committed = _openRound();
        (uint256 keyA,) = _backer(770);
        (uint256 keyB,) = _backer(771);
        (uint256 keyD,) = _backer(772);
        a = vm.addr(keyA);
        b = vm.addr(keyB);
        d = vm.addr(keyD);
        _commit(keyA, address(token), 420e6, false);
        _commit(keyD, address(token), 100e6, false);
        _commit(keyB, address(token), 280e6, false);
        _planHonour(address(token), address(quote), keyA, 420e6, 420e6);
        _planHonour(address(token), address(quote), keyD, 100e6, 100e6);
        _planHonour(address(token), address(quote), keyB, 280e6, 280e6);
        _defect(d);
        bondA = (420e6 * 2_000) / BPS;
        bondB = (280e6 * 2_000) / BPS;

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        reg.settle(address(token));
    }

    // 3.4.1: filled backers get bond + pro-rata forfeits.
    function test_claimBond_filledSharesForfeit() public {
        (uint256 bondA, uint256 bondB, address a, address b, address dFiller) = _settledWithForfeit();
        assertTrue(dFiller != address(0));
        uint256 forfeited = (100e6 * 2_000) / BPS; // 20e6

        vm.prank(a);
        vm.expectEmit(true, true, false, true);
        emit BondClaimed(address(token), a, bondA + (forfeited * 420e6) / 700e6);
        uint256 claimedA = reg.claimBond(address(token));
        assertEq(claimedA, bondA + 12e6);

        vm.prank(b);
        uint256 claimedB = reg.claimBond(address(token));
        assertEq(claimedB, bondB + 8e6);

        // Filler shares exhaust the forfeit exactly (no dust here).
        assertEq((claimedA - bondA) + (claimedB - bondB), forfeited);
    }

    // 3.4.2: unfilled backers get exactly their bond.
    function test_claimBond_unfilledGetsBond() public {
        _openDefault();
        uint256 pledge = 100e6;
        uint256 bond = (pledge * 2_000) / BPS;
        (uint256 key,) = _backer(773);
        address who = vm.addr(key);
        _commit(key, address(token), pledge, false);

        vm.warp(reg.getCampaign(address(token)).orderDeadline + 1);
        reg.expire(address(token));

        vm.prank(who);
        uint256 claimed = reg.claimBond(address(token));
        assertEq(claimed, bond);
    }

    // 3.4.3/3.4.4: defectors, double claims, strangers and early claims.
    function test_claimBond_defectorDoubleStrangerEarly() public {
        _settledWithForfeit();
        (uint256 keyD,) = _backer(772);
        address d = vm.addr(keyD);

        vm.prank(d);
        vm.expectRevert(WeirV2CommitmentRegistry.NothingToClaim.selector);
        reg.claimBond(address(token));

        // Double claim by a filler.
        (uint256 keyA,) = _backer(770);
        vm.prank(vm.addr(keyA));
        reg.claimBond(address(token));
        vm.prank(vm.addr(keyA));
        vm.expectRevert(WeirV2CommitmentRegistry.NothingToClaim.selector);
        reg.claimBond(address(token));

        // Never committed.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(WeirV2CommitmentRegistry.NothingToClaim.selector);
        reg.claimBond(address(token));

        // Before settlement.
        MockBurnableToken t2 = new MockBurnableToken("T2", "T2");
        _open(address(t2), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0)));
        (uint256 keyE,) = _backer(774);
        _commit(keyE, address(t2), 100e6, false);
        vm.prank(vm.addr(keyE));
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignNotClosed.selector);
        reg.claimBond(address(t2));
    }

    // 3.4.5: conservation — claims + bondsToPool == totalBonded.
    function test_claimBond_conservation() public {
        (uint256 bondA, uint256 bondB, address a, address b, address dCons) = _settledWithForfeit();
        assertTrue(dCons != address(0));
        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        uint256 totalBonded = c.totalBonded;
        assertEq(totalBonded, bondA + bondB + (100e6 * 2_000) / BPS);

        vm.prank(a);
        uint256 claimedA = reg.claimBond(address(token));
        vm.prank(b);
        uint256 claimedB = reg.claimBond(address(token));
        // Settled non-zero: no bonds to the pool; fillers got everything.
        assertEq(claimedA + claimedB, totalBonded);

        // All-defect variant: nothing claimable, everything pools.
        MockBurnableToken t2 = new MockBurnableToken("T2", "T2");
        uint256 committed2 = _open(
            address(t2), address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
        );
        (uint256 keyD,) = _backer(775);
        _commit(keyD, address(t2), 100e6, false);
        _planHonour(address(t2), address(quote), keyD, 100e6, 100e6);
        _defect(vm.addr(keyD));
        t2.mint(address(reg), committed2);
        vm.warp(reg.getCampaign(address(t2)).closesAt + 1);
        vm.prank(factory);
        uint256 forwarded = reg.settle(address(t2));
        WeirV2CommitmentRegistry.Campaign memory c2 = reg.getCampaign(address(t2));
        assertEq(forwarded, c2.totalBonded); // bondsToPool == totalBonded
        assertEq(forwarded, c2.forfeitedBonds);
    }

    // 3.4.6: expire timing — at deadline it refuses, one second later it clears.
    function test_expire_timing() public {
        _openDefault();
        (uint256 key1,) = _backer(776);
        (uint256 key2,) = _backer(777);
        _commit(key1, address(token), 100e6, false);
        _commit(key2, address(token), 100e6, false);

        uint256 deadline = reg.getCampaign(address(token)).orderDeadline;
        vm.warp(deadline);
        vm.expectRevert(WeirV2CommitmentRegistry.CampaignNotExpired.selector);
        reg.expire(address(token));

        vm.warp(deadline + 1);
        vm.expectEmit(true, false, false, false);
        emit CampaignExpired(address(token));
        reg.expire(address(token));
        assertEq(reg.outstandingPledge(vm.addr(key1)), 0);
        assertEq(reg.outstandingPledge(vm.addr(key2)), 0);

        vm.expectRevert(WeirV2CommitmentRegistry.CampaignNotOpen.selector);
        reg.expire(address(token));
    }

    // -- 3.5 views -------------------------------------------------------------

    // 3.5.1: allocationFor is linear and matches pledge/(P0 x (1-d)).
    function test_allocationFor_linearity() public {
        _openRound();
        uint256 p = 70e6;
        uint256 a1 = reg.allocationFor(address(token), p);
        uint256 a2 = reg.allocationFor(address(token), 2 * p);
        assertEq(a2, 2 * a1);
        // pledge x committed / target == pledge / (P0 x (1-d)).
        WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(address(token));
        assertEq(a1, Math.mulDiv(p, c.committedTokens, c.targetQuote));
        uint256 viaPrice = Math.mulDiv(p * BPS, SUPPLY, PHANTOM * (BPS - DISCOUNT));
        assertEq(a1, viaPrice);
    }

    // 3.5.2: preview is deterministic; commit emits the previewed hash.
    function test_previewCommitmentOrder_determinism() public {
        _openDefault();
        (uint256 key,) = _backer(778);
        address who = vm.addr(key);
        (ISwapVM.Order memory o1, bytes32 h1) = reg.previewCommitmentOrder(address(token), who, 100e6, false);
        (ISwapVM.Order memory o2, bytes32 h2) = reg.previewCommitmentOrder(address(token), who, 100e6, false);
        assertEq(h1, h2);
        assertEq(keccak256(o1.data), keccak256(o2.data));
        assertEq(o1.traits, o2.traits);

        // Different pledge / aqua flag -> different hash.
        (, bytes32 hOther) = reg.previewCommitmentOrder(address(token), who, 200e6, false);
        assertTrue(hOther != h1);
        (, bytes32 hAqua) = reg.previewCommitmentOrder(address(token), who, 100e6, true);
        assertTrue(hAqua != h1);

        // commit emits exactly the previewed hash (bond pre-approved below).
        quote.mint(who, 100e6 * 3);
        vm.startPrank(who);
        quote.approve(address(reg), type(uint256).max);
        vm.expectEmit(true, true, false, true);
        emit Committed(address(token), who, 100e6, (100e6 * 2_000) / BPS, h1);
        reg.commit(address(token), 100e6, false, _sign(key, h1), new bytes32[](0));
        vm.stopPrank();
    }

    // 3.3.8: the router allowance for the token is zero after settle.
    function test_settle_approvalHygiene() public {
        uint256 committed = _openDefault();
        (uint256 key,) = _backer(779);
        _commit(key, address(token), 100e6, false);
        _planHonour(address(token), address(quote), key, 100e6, 100e6);

        token.mint(address(reg), committed);
        vm.warp(reg.getCampaign(address(token)).closesAt + 1);
        vm.prank(factory);
        reg.settle(address(token));

        assertEq(token.allowance(address(reg), address(router)), 0);
    }

    /// @dev Deploys burnable tokens until one lands on the wanted side of
    /// the quote address (bounded; addresses are nonce-uniform).
    function _tokenOnSide(bool wantBelow) internal returns (MockBurnableToken t) {
        for (uint256 i = 0; i < 200; ++i) {
            t = new MockBurnableToken("S", "S");
            if ((address(t) < address(quote)) == wantBelow) return t;
        }
        revert("no token on wanted side");
    }

    /// @dev 20-byte big-endian address at `offset` in a memory byte array.
    function _addr(bytes memory data, uint256 offset) internal pure returns (address result) {
        assembly {
            result := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    // 3.5.3: token<quote and token>quote campaigns both encode StaticBalances
    // with (allocation, pledge) on the correct sides, matching LimitSwap
    // direction, and both fill through settle.
    function test_sortedTokenSymmetry() public {
        MockBurnableToken below = _tokenOnSide(true);
        MockBurnableToken above = _tokenOnSide(false);
        uint256 pledge = 100e6;

        MockBurnableToken[2] memory tokens = [below, above];
        for (uint256 i = 0; i < 2; ++i) {
            address token_ = address(tokens[i]);
            uint256 committed = _open(
                token_, address(quote), PHANTOM, SUPPLY, _params(DISCOUNT, TARGET, 0, _defaultOpensAt(), bytes32(0))
            );

            (uint256 key,) = _backer(780 + i);
            address who = vm.addr(key);
            _commit(key, token_, pledge, false);
            _planHonour(token_, address(quote), key, pledge, pledge);

            // StaticBalances sides + LimitSwap direction from first principles.
            (ISwapVM.Order memory order,) = reg.previewCommitmentOrder(token_, who, pledge, false);
            (address tokenA, address tokenB, bool tokenIsA) = SwapVMOrderLib.sortTokens(token_, address(quote));
            assertEq(_addr(order.data, 0), tokenA);
            assertEq(_addr(order.data, 20), tokenB);
            uint256 allocation = Math.mulDiv(pledge, committed, TARGET);
            (uint256 balA, uint256 balB) = tokenIsA ? (allocation, pledge) : (pledge, allocation);
            WeirV2CommitmentRegistry.Campaign memory c = reg.getCampaign(token_);
            bytes memory expectedProgram =
                SwapVMOrderLib.limitOrderProgram(c.nonceBit, c.orderDeadline, balA, balB, tokenIsA);
            assertEq(order.data, bytes.concat(abi.encodePacked(tokenA, tokenB), expectedProgram));
            assertEq(order.data[order.data.length - 1], tokenIsA ? bytes1(uint8(0x80)) : bytes1(uint8(0)));

            tokens[i].mint(address(reg), committed);
            vm.warp(reg.getCampaign(token_).closesAt + 1);
            vm.prank(factory);
            reg.settle(token_);
            assertEq(uint8(reg.getCommitment(token_, who).outcome), uint8(WeirV2CommitmentRegistry.Outcome.Filled));
        }
    }
}
