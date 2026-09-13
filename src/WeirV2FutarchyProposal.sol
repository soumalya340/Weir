// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BinaryMarket} from "../deps/degencalls_smartcontracts/src/Binary.sol";

interface IWeirV2EarlyExitVault {
    function setFutarchyProposal(address proposal) external;
    function unlockEarlyExit() external;
}

/**
 * @title WeirV2FutarchyProposal
 * @notice MetaDAO-style decision market narrowed to one question per
 * instance: should a WeirV2StakingReward vault's 40% trading-fee pool become
 * withdrawable early, by burning the staked memecoin instead of waiting out
 * the ordinary 7-day unlock? Two independent BinaryMarket LMSR markets
 * (unmodified degencalls code) are deployed, one for PASS and one for FAIL,
 * exactly mirroring MetaDAO's own pass/fail conditional markets. Traders buy
 * into whichever side they believe, and each market prices its own YES
 * share independently through its own LMSR curve.
 *
 * Unlike a generic MetaDAO proposal (an arbitrary executable instruction),
 * the only possible executed action here is `unlockEarlyExit()` on one
 * fixed vault, decided once, permanently. There is no on-chain TWAP oracle:
 * resolution reads each market's final YES price at the close of a fixed
 * trading window, which is the same manipulation surface every non-TWAP
 * LMSR market has and is accepted here as out of scope for this narrow use.
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
    address public immutable proposer;
    uint256 public immutable closesAt;
    BinaryMarket public immutable passMarket;
    BinaryMarket public immutable failMarket;

    bool public finalized;
    bool public passed;
    bool public bondReturned;

    /**
     * @param vault_ The WeirV2StakingReward vault this proposal decides
     * early exit for. Must not already have a futarchy proposal wired (see
     * WeirV2StakingReward.setFutarchyProposal), so at most one decision
     * market can ever be live per vault.
     */
    constructor(address vault_) payable {
        if (vault_ == address(0)) revert ZeroAddress();
        if (msg.value < PROPOSE_BOND) revert InsufficientBond();

        vault = vault_;
        proposer = msg.sender;
        uint256 closes = block.timestamp + TRADING_WINDOW;
        closesAt = closes;

        string[2] memory outcomeNames = ["Yes", "No"];
        passMarket = new BinaryMarket(
            0,
            "Unlock early exit for this staking vault?",
            outcomeNames,
            closes,
            INITIAL_B,
            address(this),
            msg.sender,
            address(this)
        );
        failMarket = new BinaryMarket(
            0,
            "Keep the staking vault's normal unlock schedule?",
            outcomeNames,
            closes,
            INITIAL_B,
            address(this),
            msg.sender,
            address(this)
        );

        // Wiring is no longer done here: WeirV2StakingReward.setFutarchyProposal
        // is hook-gated (AUDIT.md #1). The factory/hook must call
        // registerFutarchyProposal after deployment, which also prevents an
        // arbitrary contract with a matching vault() getter from self-wiring.

        emit ProposalCreated(vault_, msg.sender, address(passMarket), address(failMarket), closes);
    }

    /**
     * @notice Closes trading, reads each market's final YES price, resolves
     * both underlying BinaryMarkets so traders can claim through them
     * normally, and — if PASS priced higher than FAIL — unlocks early exit
     * on the vault. Callable once, by anyone, only after the trading window.
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
        }

        emit ProposalFinalized(result, passPrice, failPrice);
    }

    /**
     * @notice Returns the proposer's spam-prevention bond once trading has
     * closed. The bond is never slashed by outcome: unlike
     * SettlementResolverManual's creator/challenger stakes, this proposal
     * resolves by market price alone, so there is no dispute to stake
     * against and the bond exists solely to price out spam proposals.
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

    receive() external payable {}
}
