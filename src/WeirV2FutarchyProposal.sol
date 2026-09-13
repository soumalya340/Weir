// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BinaryMarket} from "./MemePredictionMarket/Binary.sol";

interface IWeirV2EarlyExitVault {
    function setFutarchyProposal(address proposal) external;

    function unlockEarlyExit() external;

    function stakeToken() external view returns (address);

    function hook() external view returns (address);
}

interface IWeirV2RedemptionUnlock {
    function unlockRedemption(address token) external;

    function isMember(address token, address account) external view returns (bool);
}

/**
 * @title WeirV2FutarchyProposal
 * @notice MetaDAO-style decision market narrowed to one question per
 * instance: should this launch's pool be treated as dead and opened for
 * redemption, letting the people who built it burn their tokens and take
 * their share of the locked Uniswap v4 liquidity (up to 40% of it), and
 * letting stakers leave the 7-day lock early to do so? Two independent
 * BinaryMarket LMSR markets are deployed, one for PASS and one for FAIL,
 * mirroring MetaDAO's pass/fail conditional markets. Each market prices its
 * own YES share through its own LMSR curve.
 *
 * Voting is restricted to pool members: buying shares on either market goes
 * through this contract's `canTrade`, which asks WeirV2PoolRedemption
 * whether the trader bought on the bonding curve or had a commitment
 * filled. Outsiders cannot vote a pool dead.
 *
 * The only executable actions are `unlockEarlyExit()` on one fixed staking
 * vault and `unlockRedemption()` on the pool's redemption contract, decided
 * once, permanently. There is no on-chain TWAP oracle: resolution reads
 * each market's final YES price at the close of a fixed trading window,
 * which is the same manipulation surface every non-TWAP LMSR market has
 * and is accepted here for this narrow, member-gated use.
 */
contract WeirV2FutarchyProposal is ReentrancyGuard {
    uint256 public constant TRADING_WINDOW = 3 days;
    uint256 public constant PROPOSE_BOND = 0.01 ether;
    uint256 private constant INITIAL_B = 0.01 ether;

    error ZeroAddress();
    error InsufficientBond();
    error AlreadyFinalized();
    error TradingStillOpen();
    error BondAlreadyReturned();

    event ProposalCreated(
        address indexed vault, address indexed proposer, address passMarket, address failMarket, uint256 closesAt
    );
    event ProposalFinalized(bool passed, uint256 passPrice, uint256 failPrice);
    event BondReturned(address indexed proposer, uint256 amount);

    address public immutable vault;
    address public immutable token;
    // Resolved from the vault's hook at construction. Zero when the hook
    // has no redemption contract wired (or is not a contract), in which case
    // the markets are ungated and PASS only unlocks early exit.
    address public immutable redemption;
    address public immutable proposer;
    uint256 public immutable closesAt;
    BinaryMarket public immutable passMarket;
    BinaryMarket public immutable failMarket;

    bool public finalized;
    bool public passed;
    bool public bondReturned;

    /**
     * @param vault_ The WeirV2StakingReward vault this proposal decides for.
     * Must not already have a futarchy proposal wired (see
     * WeirV2StakingReward.setFutarchyProposal), so at most one decision
     * market can ever be live per vault.
     * @param proposer_ Bond recipient for `returnBond`. Passed explicitly so
     * factory-path deployment (`createFutarchyProposal`) can name the EOA who
     * paid `msg.value` rather than the factory itself.
     */
    constructor(address vault_, address proposer_) payable {
        if (vault_ == address(0) || proposer_ == address(0)) revert ZeroAddress();
        if (msg.value < PROPOSE_BOND) revert InsufficientBond();

        vault = vault_;
        proposer = proposer_;
        token = IWeirV2EarlyExitVault(vault_).stakeToken();
        address redemption_ = _resolveRedemption(IWeirV2EarlyExitVault(vault_).hook());
        redemption = redemption_;
        uint256 closes = block.timestamp + TRADING_WINDOW;
        closesAt = closes;

        string[2] memory outcomeNames = ["Yes", "No"];
        BinaryMarket pass = new BinaryMarket(
            0,
            "Open this pool for member redemption (burn tokens for up to 40% of locked liquidity)?",
            outcomeNames,
            closes,
            INITIAL_B,
            address(this),
            proposer_,
            address(this)
        );
        BinaryMarket fail = new BinaryMarket(
            0,
            "Keep this pool's liquidity fully locked and the staking schedule unchanged?",
            outcomeNames,
            closes,
            INITIAL_B,
            address(this),
            proposer_,
            address(this)
        );
        passMarket = pass;
        failMarket = fail;

        // Member-only voting: both markets consult canTrade() below.
        if (redemption_ != address(0)) {
            pass.setTradeGate(address(this));
            fail.setTradeGate(address(this));
        }

        // Wiring into the vault is done by WeirV2LaunchFactory.createFutarchyProposal,
        // the only deployer of this contract into a vault's proposal slot
        // (AUDIT.md #1). Self-wiring here would re-open permissionless seizure.

        emit ProposalCreated(vault_, proposer_, address(pass), address(fail), closes);
    }

    /**
     * @notice Trade gate for both markets: only accounts that bought on this
     * launch's bonding curve or had a commitment filled may buy shares.
     */
    function canTrade(address trader) external view returns (bool) {
        if (redemption == address(0)) return true;
        return IWeirV2RedemptionUnlock(redemption).isMember(token, trader);
    }

    /**
     * @notice Closes trading, reads each market's final YES price, resolves
     * both underlying BinaryMarkets so traders can claim through them
     * normally, and, if PASS priced higher than FAIL, unlocks early exit on
     * the vault and member redemption on the pool. Callable once, by anyone,
     * only after the trading window.
     * @dev A strict `>` rather than a MetaDAO-style asymmetric threshold: no
     * team-vs-external distinction exists in this narrow single-question
     * design, so a plain majority decides.
     */
    function finalize() external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (block.timestamp < closesAt) revert TradingStillOpen();

        uint256 passPrice = passMarket.getPrice(passMarket.OUTCOME_YES());
        uint256 failPrice = failMarket.getPrice(failMarket.OUTCOME_YES());
        bool result = passPrice > failPrice;

        finalized = true;
        passed = result;

        passMarket.resolve(result ? passMarket.OUTCOME_YES() : passMarket.OUTCOME_NO());
        failMarket.resolve(result ? failMarket.OUTCOME_NO() : failMarket.OUTCOME_YES());

        if (result) {
            IWeirV2EarlyExitVault(vault).unlockEarlyExit();
            if (redemption != address(0)) IWeirV2RedemptionUnlock(redemption).unlockRedemption(token);
        }

        emit ProposalFinalized(result, passPrice, failPrice);
    }

    /**
     * @notice Returns the proposer's spam-prevention bond once trading has
     * closed. The bond is never slashed by outcome: this proposal resolves by
     * market price alone, so there is no dispute to stake against and the
     * bond exists solely to price out spam proposals.
     */
    function returnBond() external nonReentrant {
        if (block.timestamp < closesAt) revert TradingStillOpen();
        if (bondReturned) revert BondAlreadyReturned();
        bondReturned = true;

        uint256 amount = address(this).balance < PROPOSE_BOND ? address(this).balance : PROPOSE_BOND;
        (bool ok,) = payable(proposer).call{value: amount}("");
        require(ok, "Bond transfer failed");

        emit BondReturned(proposer, amount);
    }

    /**
     * @dev Reads `poolRedemption()` off the vault's hook without reverting
     * when the hook is not a contract (unit-test vaults) or has none wired.
     */
    function _resolveRedemption(address hook) private view returns (address) {
        if (hook.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSignature("poolRedemption()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    receive() external payable {}
}
