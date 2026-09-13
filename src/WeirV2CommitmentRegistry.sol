// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ISwapVM} from "./interfaces/ISwapVM.sol";
import {SwapVMOrderLib} from "./libraries/SwapVMOrderLib.sol";

/**
 * @notice Narrow ERC20Burnable surface of WeirV2LauncherToken, the only token
 * a commitment campaign is ever opened for.
 */
interface IERC20BurnableLike {
    function burn(uint256 amount) external;
}

/**
 * @title WeirV2CommitmentRegistry
 * @notice Bonded zero-custody pre-launch commitments (Ideas/Idea2.md,
 * Ideas/Plan.md §1-§2), settled through official 1inch SwapVM `LimitSwap`.
 *
 * A backer pledges quote (USDC) that never leaves their wallet: the pledge is
 * a resting SwapVM limit order, signed EIP-712 (or shipped to Aqua), that
 * sells the pledge for a fixed allocation of the launch token at
 * `P₀ × (1 − d)`. The only custody here is the 20% bond, escrowed at commit.
 *
 * At graduation the factory releases the fenced-off commitment tranche to
 * this registry, which fills every commitment in signature order against the
 * router until the target is met. A fill that fails (quote moved, allowance
 * revoked, order invalidated) marks its backer a defector: their bond is
 * forfeited and the tokens they would have received are burned with
 * `burn()`, so supply falls and every circulating token stays backed by
 * quote that was actually paid. Settled quote (plus forfeited bonds when no
 * one honoured) is forwarded to the factory and seeds the Uniswap v4 pool.
 *
 * Per-launch parameters are frozen when the campaign opens. The bond ratio
 * is a protocol constant, never a creator or governance parameter (Plan §2).
 */
contract WeirV2CommitmentRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    /// @notice Bond posted with every pledge: 20%, hardcoded, not configurable.
    uint256 public constant COMMITMENT_BOND_BPS = 2_000;
    /// @notice A campaign must run at least this long before the curve opens.
    uint256 public constant MIN_CAMPAIGN_DURATION = 24 hours;
    /// @notice Discount `d` range the creator may choose from (Idea2 §5).
    uint256 public constant MIN_DISCOUNT_BPS = 2_000;
    uint256 public constant MAX_DISCOUNT_BPS = 4_000;
    /// @notice Accept up to this multiple of the target in pledges (Idea2 §10).
    uint256 public constant DEFAULT_OVERSUBSCRIPTION_BPS = 14_000;
    uint256 public constant MAX_OVERSUBSCRIPTION_BPS = 20_000;
    /// @notice Largest share of supply a tranche may fence off.
    uint256 public constant MAX_TRANCHE_BPS = 5_000;
    /// @notice Settlement is one loop of external fills; bound it.
    uint256 public constant MAX_COMMITMENTS = 64;
    /// @notice Signed orders stay fillable this long after the curve opens.
    /// Past it a campaign that never graduated can be expired and bonds
    /// reclaimed, so no backer is ever locked in by a launch that stalls.
    uint256 public constant ORDER_LIFETIME = 30 days;

    enum CampaignStatus {
        None,
        Open,
        Settled,
        Expired
    }

    enum Outcome {
        Pending, // not yet settled
        Filled, // honoured, tokens delivered, bond returned
        Defected, // fill failed, tokens burned, bond forfeited
        Unfilled // never attempted: target already met, or campaign expired
    }

    /// @notice What a creator supplies to open a campaign at launch.
    /// `targetQuote == 0` means "no campaign" on the factory's launch path.
    struct CampaignParams {
        uint16 discountBps;
        uint256 targetQuote;
        uint256 oversubscriptionBps; // 0 => DEFAULT_OVERSUBSCRIPTION_BPS
        uint256 tradingOpensAt; // curve go-live; campaign closes here
        bytes32 allowlistRoot; // 0 => open mode
    }

    struct Campaign {
        CampaignStatus status;
        address curve;
        address quoteToken;
        address creator;
        uint16 discountBps;
        uint256 targetQuote;
        uint256 maxPledged;
        uint256 committedTokens;
        uint256 opensAt;
        uint256 closesAt;
        uint40 orderDeadline;
        bytes32 allowlistRoot;
        uint32 nonceBit;
        uint256 totalPledged;
        uint256 totalBonded;
        // Settlement results.
        uint256 settledQuote;
        uint256 deliveredTokens;
        uint256 burnedTokens;
        uint256 forfeitedBonds;
        address[] backers;
    }

    struct Commitment {
        uint256 pledge;
        uint256 bond;
        bool useAqua;
        bytes signature;
        Outcome outcome;
        uint256 filledQuote;
        uint256 filledTokens;
        bool bondClaimed;
    }

    error NotFactory();
    error ZeroAddress();
    error ZeroAmount();
    error NativeQuoteUnsupported();
    error CampaignExists();
    error UnknownCampaign();
    error CampaignNotOpen();
    error CampaignClosed();
    error CampaignNotClosed();
    error CampaignNotExpired();
    error InvalidDiscount();
    error InvalidOversubscription();
    error CampaignTooShort();
    error TrancheTooLarge();
    error AlreadyCommitted();
    error NotAllowlisted();
    error OverSubscribed();
    error TooManyCommitments();
    error ExposureCapExceeded(uint256 balance, uint256 required);
    error InvalidSignature();
    error TrancheNotReceived(uint256 expected, uint256 held);
    error NothingToClaim();

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

    address public immutable factory;
    ISwapVM public immutable swapVM;

    mapping(address token => Campaign) private _campaigns;
    mapping(address token => mapping(address backer => Commitment)) private _commitments;
    // Aggregate exposure cap (Idea2 §8): every pledge a backer has resting
    // across all open campaigns. A new pledge is refused unless the backer's
    // wallet can cover this total plus the new bond right now, so pledging
    // 5,000 against 100 of capital is impossible at the source. The 20% bond
    // then prices the *residual* free option a backer still has over one
    // wallet balance.
    mapping(address backer => uint256) public outstandingPledge;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /**
     * @param factory_ WeirV2LaunchFactory; the only caller allowed to open
     * campaigns (it has just deployed the token and curve) and to settle them
     * (from inside its own graduation path).
     * @param swapVM_ Official 1inch SwapVM router (`SwapVMRouter` or
     * `LimitSwapVMRouter`, or a local-fork redeploy) that settles fills.
     */
    constructor(address factory_, ISwapVM swapVM_) {
        if (factory_ == address(0) || address(swapVM_) == address(0)) revert ZeroAddress();
        factory = factory_;
        swapVM = swapVM_;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function hasCampaign(address token) external view returns (bool) {
        return _campaigns[token].status != CampaignStatus.None;
    }

    function getCampaign(address token) external view returns (Campaign memory) {
        return _campaigns[token];
    }

    function getCommitment(address token, address backer) external view returns (Commitment memory) {
        return _commitments[token][backer];
    }

    function backersOf(address token) external view returns (address[] memory) {
        return _campaigns[token].backers;
    }

    /**
     * @notice Tokens a pledge of `pledgeQuote` buys at this campaign's fixed
     * committer price. Linear in the pledge: `committedTokens / targetQuote`
     * is exactly `1 / (P₀ × (1 − d))`.
     */
    function allocationFor(address token, uint256 pledgeQuote) public view returns (uint256) {
        Campaign storage c = _campaigns[token];
        if (c.status == CampaignStatus.None) revert UnknownCampaign();
        return Math.mulDiv(pledgeQuote, c.committedTokens, c.targetQuote);
    }

    /**
     * @notice The exact SwapVM order a backer must sign (EIP-712 over
     * `swapVM.hash(order)`) or ship to Aqua for a pledge of `pledgeQuote`.
     * Deterministic in (campaign, backer, pledge), so the registry rebuilds
     * it at commit and at settlement rather than storing bytecode.
     */
    function previewCommitmentOrder(address token, address backer, uint256 pledgeQuote, bool useAqua)
        public
        view
        returns (ISwapVM.Order memory order, bytes32 orderHash)
    {
        Campaign storage c = _campaigns[token];
        if (c.status == CampaignStatus.None) revert UnknownCampaign();
        order = _buildOrder(token, c, backer, pledgeQuote, useAqua);
        orderHash = swapVM.hash(order);
    }

    // ---------------------------------------------------------------------
    // Campaign lifecycle (factory-driven)
    // ---------------------------------------------------------------------

    /**
     * @notice Opens a campaign for a launch the factory has just deployed.
     * Returns the tranche size the curve must fence off.
     * @dev Pricing is derived, never asserted (Plan §1b): the creator picks
     * `d` and `Q`, `P₀ = phantomQuote / supply` is read off the curve terms,
     * and `committedTokens = Q / (P₀ × (1 − d))` falls out.
     */
    function openCampaign(
        address token,
        address curve,
        address creator,
        address quoteToken,
        uint256 phantomQuote,
        uint256 supply,
        CampaignParams calldata params
    ) external onlyFactory returns (uint256 committedTokens) {
        if (_campaigns[token].status != CampaignStatus.None) revert CampaignExists();
        if (token == address(0) || curve == address(0) || creator == address(0)) revert ZeroAddress();
        // Bonds and fills are ERC-20 transfers; a native-quote launch would
        // need WETH wrapping on both sides and is out of scope for v1.
        if (quoteToken == address(0)) revert NativeQuoteUnsupported();
        if (params.targetQuote == 0) revert ZeroAmount();
        if (params.discountBps < MIN_DISCOUNT_BPS || params.discountBps > MAX_DISCOUNT_BPS) revert InvalidDiscount();
        uint256 oversub = params.oversubscriptionBps == 0 ? DEFAULT_OVERSUBSCRIPTION_BPS : params.oversubscriptionBps;
        if (oversub < BASIS_POINTS || oversub > MAX_OVERSUBSCRIPTION_BPS) revert InvalidOversubscription();
        if (params.tradingOpensAt < block.timestamp + MIN_CAMPAIGN_DURATION) revert CampaignTooShort();

        // committedTokens = Q × supply × BPS / (phantomQuote × (BPS − d))
        committedTokens =
            Math.mulDiv(params.targetQuote * BASIS_POINTS, supply, phantomQuote * (BASIS_POINTS - params.discountBps));
        if (committedTokens == 0) revert ZeroAmount();
        if (committedTokens > (supply * MAX_TRANCHE_BPS) / BASIS_POINTS) revert TrancheTooLarge();

        Campaign storage c = _campaigns[token];
        c.status = CampaignStatus.Open;
        c.curve = curve;
        c.quoteToken = quoteToken;
        c.creator = creator;
        c.discountBps = params.discountBps;
        c.targetQuote = params.targetQuote;
        c.maxPledged = (params.targetQuote * oversub) / BASIS_POINTS;
        c.committedTokens = committedTokens;
        c.opensAt = block.timestamp;
        c.closesAt = params.tradingOpensAt;
        c.orderDeadline = uint40(params.tradingOpensAt + ORDER_LIFETIME);
        c.allowlistRoot = params.allowlistRoot;
        // One InvalidateBit slot per (registry, launch) in each backer's
        // bitmap on the router. Hashed so campaigns on the same router do not
        // collide with each other or with a backer's unrelated orders.
        c.nonceBit = uint32(uint256(keccak256(abi.encode(address(this), token))));

        emit CampaignOpened(
            token,
            creator,
            quoteToken,
            params.discountBps,
            params.targetQuote,
            committedTokens,
            block.timestamp,
            params.tradingOpensAt,
            params.allowlistRoot
        );
    }

    /**
     * @notice Fills every commitment through SwapVM, burns what did not
     * settle, and forwards the settled quote to the factory. Called by the
     * factory from inside `graduate` after the curve has released the tranche
     * here and before the pool is seeded (Idea2 §7 ordering).
     * @return quoteForwarded Quote transferred to the factory for the seed.
     */
    function settle(address token) external onlyFactory nonReentrant returns (uint256 quoteForwarded) {
        Campaign storage c = _campaigns[token];
        if (c.status == CampaignStatus.None) revert UnknownCampaign();
        if (c.status == CampaignStatus.Settled) revert CampaignClosed();
        if (block.timestamp < c.closesAt) revert CampaignNotClosed();

        uint256 held = IERC20(token).balanceOf(address(this));
        if (held < c.committedTokens) revert TrancheNotReceived(c.committedTokens, held);

        // Expired (or past its order lifetime) campaigns cannot fill anyone:
        // the resting orders have hit their Deadline. Burn the tranche whole,
        // leave every bond reclaimable, and seed nothing extra.
        bool expired = c.status == CampaignStatus.Expired || block.timestamp > c.orderDeadline;

        IERC20 quote = IERC20(c.quoteToken);
        if (!expired) IERC20(token).forceApprove(address(swapVM), c.committedTokens);

        uint256 backerCount = c.backers.length;
        for (uint256 i = 0; i < backerCount; ++i) {
            address backer = c.backers[i];
            Commitment storage cm = _commitments[token][backer];
            if (cm.outcome != Outcome.Pending) continue; // already cleared by expire()
            outstandingPledge[backer] -= cm.pledge;

            uint256 remaining = c.targetQuote - c.settledQuote;
            if (expired || remaining == 0) {
                cm.outcome = Outcome.Unfilled;
                emit CommitmentUnfilled(token, backer, cm.pledge);
                continue;
            }

            uint256 fillQuote = Math.min(cm.pledge, remaining);
            (bool ok, uint256 quoteIn, uint256 tokensOut) = _fill(token, c, backer, cm, fillQuote, quote);
            if (ok) {
                cm.outcome = Outcome.Filled;
                cm.filledQuote = quoteIn;
                cm.filledTokens = tokensOut;
                c.settledQuote += quoteIn;
                c.deliveredTokens += tokensOut;
                emit CommitmentFilled(token, backer, quoteIn, tokensOut);
            } else {
                cm.outcome = Outcome.Defected;
                c.forfeitedBonds += cm.bond;
                emit CommitmentDefected(token, backer, cm.pledge, cm.bond);
            }
        }
        if (!expired) IERC20(token).forceApprove(address(swapVM), 0);

        // Everything not delivered burns: `burn()` decrements totalSupply,
        // unlike a transfer to address(0) which OpenZeppelin refuses anyway.
        uint256 toBurn = c.committedTokens - c.deliveredTokens;
        if (toBurn != 0) IERC20BurnableLike(token).burn(toBurn);
        c.burnedTokens = toBurn;

        // Forfeited bonds go first to the committers who honoured (mutual
        // insurance, Idea2 §9). Only when nobody filled do they enter the
        // pool as unbacked quote (the §6 all-defect example).
        uint256 bondsToPool = c.settledQuote == 0 ? c.forfeitedBonds : 0;
        quoteForwarded = c.settledQuote + bondsToPool;
        c.status = CampaignStatus.Settled;

        if (quoteForwarded != 0) quote.safeTransfer(factory, quoteForwarded);

        emit CampaignSettled(token, c.settledQuote, c.deliveredTokens, toBurn, c.forfeitedBonds, quoteForwarded);
    }

    /**
     * @notice Marks a campaign whose launch never graduated within
     * ORDER_LIFETIME as expired, releasing every bond. Permissionless.
     * A later graduation still burns the tranche through `settle`.
     */
    function expire(address token) external nonReentrant {
        Campaign storage c = _campaigns[token];
        if (c.status != CampaignStatus.Open) revert CampaignNotOpen();
        if (block.timestamp <= c.orderDeadline) revert CampaignNotExpired();

        uint256 backerCount = c.backers.length;
        for (uint256 i = 0; i < backerCount; ++i) {
            address backer = c.backers[i];
            Commitment storage cm = _commitments[token][backer];
            if (cm.outcome != Outcome.Pending) continue;
            cm.outcome = Outcome.Unfilled;
            outstandingPledge[backer] -= cm.pledge;
            emit CommitmentUnfilled(token, backer, cm.pledge);
        }
        c.status = CampaignStatus.Expired;
        emit CampaignExpired(token);
    }

    // ---------------------------------------------------------------------
    // Backer side
    // ---------------------------------------------------------------------

    /**
     * @notice Pledges `pledgeQuote` to a campaign. Pulls only the 20% bond;
     * the pledge itself stays in the wallet as a resting SwapVM order.
     * @param signature EIP-712 signature by `msg.sender` over
     * `swapVM.hash(previewCommitmentOrder(...))`. Ignored (may be empty) when
     * `useAqua` is set, in which case the backer must have shipped that exact
     * order to Aqua before settlement.
     * @param proof Merkle proof of `keccak256(abi.encodePacked(msg.sender))`
     * against the allowlist root; unused in open mode.
     */
    function commit(address token, uint256 pledgeQuote, bool useAqua, bytes calldata signature, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Campaign storage c = _campaigns[token];
        if (c.status != CampaignStatus.Open) revert CampaignNotOpen();
        if (block.timestamp >= c.closesAt) revert CampaignClosed();
        if (pledgeQuote == 0) revert ZeroAmount();
        Commitment storage cm = _commitments[token][msg.sender];
        if (cm.pledge != 0) revert AlreadyCommitted();
        if (c.backers.length >= MAX_COMMITMENTS) revert TooManyCommitments();
        if (c.totalPledged + pledgeQuote > c.maxPledged) revert OverSubscribed();
        if (
            c.allowlistRoot != bytes32(0)
                && !MerkleProof.verify(proof, c.allowlistRoot, keccak256(abi.encodePacked(msg.sender)))
        ) {
            revert NotAllowlisted();
        }

        uint256 bond = (pledgeQuote * COMMITMENT_BOND_BPS) / BASIS_POINTS;
        if (bond == 0) revert ZeroAmount();

        // Aggregate exposure cap: the wallet must cover every resting pledge
        // plus this one plus the bond it is about to post, right now.
        IERC20 quote = IERC20(c.quoteToken);
        uint256 required = outstandingPledge[msg.sender] + pledgeQuote + bond;
        uint256 balance = quote.balanceOf(msg.sender);
        if (balance < required) revert ExposureCapExceeded(balance, required);

        ISwapVM.Order memory order = _buildOrder(token, c, msg.sender, pledgeQuote, useAqua);
        bytes32 orderHash = swapVM.hash(order);
        if (!useAqua && !SignatureChecker.isValidSignatureNow(msg.sender, orderHash, signature)) {
            revert InvalidSignature();
        }

        uint256 before = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), bond);
        uint256 received = quote.balanceOf(address(this)) - before;
        if (received != bond) revert ZeroAmount();

        cm.pledge = pledgeQuote;
        cm.bond = bond;
        cm.useAqua = useAqua;
        cm.signature = signature;
        c.backers.push(msg.sender);
        c.totalPledged += pledgeQuote;
        c.totalBonded += bond;
        outstandingPledge[msg.sender] += pledgeQuote;

        emit Committed(token, msg.sender, pledgeQuote, bond, orderHash);
    }

    /**
     * @notice Returns a backer's bond after settlement or expiry, plus their
     * pro-rata share of forfeited bonds if they honoured their pledge.
     * Defectors have nothing to claim.
     */
    function claimBond(address token) external nonReentrant returns (uint256 amount) {
        Campaign storage c = _campaigns[token];
        if (c.status != CampaignStatus.Settled && c.status != CampaignStatus.Expired) revert CampaignNotClosed();
        Commitment storage cm = _commitments[token][msg.sender];
        if (cm.bondClaimed || cm.pledge == 0) revert NothingToClaim();
        cm.bondClaimed = true;

        if (cm.outcome == Outcome.Filled) {
            amount = cm.bond;
            if (c.forfeitedBonds != 0 && c.settledQuote != 0) {
                amount += Math.mulDiv(c.forfeitedBonds, cm.filledQuote, c.settledQuote);
            }
        } else if (cm.outcome == Outcome.Unfilled) {
            amount = cm.bond;
        }
        if (amount == 0) revert NothingToClaim();

        IERC20(c.quoteToken).safeTransfer(msg.sender, amount);
        emit BondClaimed(token, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /**
     * @dev The canonical commitment order: maker = backer, static balances
     * = (allocation tokens, pledge quote) in sorted-token order, one-shot
     * via InvalidateBit, bounded by the campaign's order deadline.
     */
    function _buildOrder(address token, Campaign storage c, address backer, uint256 pledgeQuote, bool useAqua)
        private
        view
        returns (ISwapVM.Order memory)
    {
        uint256 allocation = Math.mulDiv(pledgeQuote, c.committedTokens, c.targetQuote);
        (address tokenA, address tokenB, bool tokenIsA) = SwapVMOrderLib.sortTokens(token, c.quoteToken);
        // From the taker's (this registry's) view: tokenIn = launch token,
        // tokenOut = quote. StaticBalances are given per sorted token.
        (uint256 balanceA, uint256 balanceB) = tokenIsA ? (allocation, pledgeQuote) : (pledgeQuote, allocation);
        bytes memory program = SwapVMOrderLib.limitOrderProgram(c.nonceBit, c.orderDeadline, balanceA, balanceB, tokenIsA);
        return SwapVMOrderLib.buildOrder(backer, tokenA, tokenB, program, useAqua);
    }

    /**
     * @dev Attempts one exact-in fill of `fillQuote` worth of tokens against
     * the backer's resting order. Any revert inside the router (moved quote,
     * revoked allowance, already-flipped invalidator, deadline) is caught and
     * reported as a failed fill; the router's own state changes roll back
     * with it. Success is measured by the quote that actually arrived.
     */
    function _fill(
        address token,
        Campaign storage c,
        address backer,
        Commitment storage cm,
        uint256 fillQuote,
        IERC20 quote
    ) private returns (bool ok, uint256 quoteIn, uint256 tokensOut) {
        uint256 allocation = Math.mulDiv(cm.pledge, c.committedTokens, c.targetQuote);
        uint256 fillTokens = fillQuote == cm.pledge ? allocation : Math.mulDiv(fillQuote, allocation, cm.pledge);
        if (fillTokens == 0) return (false, 0, 0);
        // LimitSwap prices an exact-in fill as amountIn × balanceOut / balanceIn
        // (floor), clamping to the full balances when amountIn covers them.
        uint256 expectedQuote = fillTokens >= allocation ? cm.pledge : Math.mulDiv(fillTokens, cm.pledge, allocation);

        ISwapVM.Order memory order = _buildOrder(token, c, backer, cm.pledge, cm.useAqua);
        bool tokenIsA = token < c.quoteToken;
        bytes memory takerData = SwapVMOrderLib.buildTakerTraits({
            isExactIn: true,
            isAToB: tokenIsA,
            allowPartialFill: false,
            strictThreshold: false,
            threshold: expectedQuote,
            deadline: 0,
            signature: cm.useAqua ? bytes("") : cm.signature
        });

        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        try swapVM.swap(order, fillTokens, takerData) returns (uint256, uint256, bytes32) {
            quoteIn = quote.balanceOf(address(this)) - quoteBefore;
            tokensOut = tokenBefore - IERC20(token).balanceOf(address(this));
            // The router already enforced the threshold; this only guards
            // against a fill that somehow paid tokens without pulling quote.
            ok = quoteIn >= expectedQuote && tokensOut == fillTokens;
        } catch {
            ok = false;
        }
    }
}
