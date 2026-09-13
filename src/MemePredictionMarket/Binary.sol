// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BinaryMarket
 * @notice Binary YES/NO market compatible with WeirV2FutarchyProposal.
 * @dev Vendored stand-in for the degencalls `BinaryMarket` that previously
 * lived only under a gitignored `deps/` path. Pricing uses a liquidity-
 * parameterised soft-max style weight (q_i + b) so that:
 *   - an untouched market prices YES at 50%, and
 *   - buying YES raises the YES price (and symmetrically for NO),
 * which is the only behaviour WeirV2FutarchyProposal and its tests rely on.
 */
contract BinaryMarket is ReentrancyGuard {
    uint256 public constant OUTCOME_YES = 0;
    uint256 public constant OUTCOME_NO = 1;
    uint256 public constant OUTCOME_COUNT = 2;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant B_SCALING_FACTOR = 1e18;

    error Unauthorized();
    error InvalidOutcome();
    error MarketAlreadyResolved();
    error MarketIsResolved();
    error MarketCancelledError();
    error SlippageExceeded();
    error TransferFailed();
    error ZeroAmount();
    error ExpInputTooLarge();
    error LnNonPositive();

    event SharesPurchased(
        address indexed buyer,
        bool isYes,
        uint256 shares,
        uint256 cost
    );
    event SharesSold(
        address indexed seller,
        bool isYes,
        uint256 shares,
        uint256 refund
    );
    event MarketResolved(uint256 winningOutcome, uint256 payoutPerShare);
    event MarketCancelled(address indexed by);
    event MarketPaused(address indexed by);
    event MarketUnpaused(address indexed by);
    event WinningsClaimed(address indexed user, uint256 payout);
    event RefundClaimed(address indexed user, uint256 amount);
    event AdaptiveBUpdated(uint256 newB);

    uint256 public marketId;
    string public question;
    string[2] private _outcomeNames;
    uint256 public resolutionTime;
    uint256 public initialB;
    uint256 public b;
    address public settlementContract;
    address public creator;
    address public admin;
    address public prizeDistributor;

    uint256 public qYes;
    uint256 public qNo;
    uint256 public settlementPool;
    bool public isResolved;
    bool public isCancelled;
    bool public paused;
    uint256 public winningOutcome;
    uint256 public payoutPerShareSnapshot;
    bool public payoutSnapshotted;

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    mapping(address => uint256) public yesCostBasis;
    mapping(address => uint256) public noCostBasis;
    mapping(address => bool) public hasClaimed;
    mapping(address => bool) public hasClaimedRefund;
    uint256 public totalYesShares;
    uint256 public totalNoShares;
    uint256 public totalCostBasis;

    modifier onlyAdmin() {
        if (msg.sender != admin && msg.sender != settlementContract)
            revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(
        uint256 _marketId,
        string memory _question,
        string[2] memory outcomeNames_,
        uint256 _resolutionTime,
        uint256 _initialB,
        address _settlementContract,
        address _creator,
        address _admin
    ) {
        require(_initialB > 0, "b=0");
        require(
            _settlementContract != address(0) && _admin != address(0),
            "zero"
        );
        marketId = _marketId;
        question = _question;
        _outcomeNames = outcomeNames_;
        resolutionTime = _resolutionTime;
        initialB = _initialB;
        b = _initialB;
        settlementContract = _settlementContract;
        creator = _creator;
        admin = _admin;
    }

    function outcomeCount() external pure returns (uint256) {
        return OUTCOME_COUNT;
    }

    function outcomeNames(uint256 index) external view returns (string memory) {
        return _outcomeNames[index];
    }

    /// @notice Implied probability of `outcome` in WAD (1e18 = 100%).
    function getPrice(uint256 outcome) public view returns (uint256) {
        if (outcome > OUTCOME_NO) revert InvalidOutcome();
        uint256 yesW = qYes + b;
        uint256 noW = qNo + b;
        uint256 sum = yesW + noW;
        if (outcome == OUTCOME_YES) return (yesW * PRECISION) / sum;
        return (noW * PRECISION) / sum;
    }

    function calculateCost(
        uint256 _qYes,
        uint256 _qNo
    ) public view returns (uint256) {
        // Cost proxy: b * ln(yesW + noW) approximated via the product form used
        // by getBuyCost; exposed for ABI parity with the original market.
        uint256 yesW = _qYes + b;
        uint256 noW = _qNo + b;
        return yesW + noW;
    }

    function getBuyCost(
        uint256 outcome,
        uint256 shareAmount
    ) public view returns (uint256) {
        if (shareAmount == 0) return 0;
        uint256 yesW = qYes + b;
        uint256 noW = qNo + b;
        if (outcome == OUTCOME_YES) {
            // Integral of soft price: share * noW / (yesW + share/2) style impact.
            return (shareAmount * noW) / (yesW + shareAmount / 2 + 1);
        }
        if (outcome == OUTCOME_NO) {
            return (shareAmount * yesW) / (noW + shareAmount / 2 + 1);
        }
        revert InvalidOutcome();
    }

    function getSellRefund(
        uint256 outcome,
        uint256 shareAmount
    ) public view returns (uint256) {
        if (shareAmount == 0) return 0;
        uint256 yesW = qYes + b;
        uint256 noW = qNo + b;
        if (outcome == OUTCOME_YES) {
            if (shareAmount > qYes) revert InvalidOutcome();
            return (shareAmount * noW) / (yesW + 1);
        }
        if (outcome == OUTCOME_NO) {
            if (shareAmount > qNo) revert InvalidOutcome();
            return (shareAmount * yesW) / (noW + 1);
        }
        revert InvalidOutcome();
    }

    function swapIn(
        uint256 outcome,
        uint256 shareAmount,
        uint256 maxCost
    ) external payable nonReentrant whenNotPaused {
        if (isResolved || isCancelled) revert MarketIsResolved();
        if (shareAmount == 0) revert ZeroAmount();
        uint256 cost = getBuyCost(outcome, shareAmount);
        if (cost > maxCost || msg.value < cost) revert SlippageExceeded();

        if (outcome == OUTCOME_YES) {
            qYes += shareAmount;
            yesShares[msg.sender] += shareAmount;
            yesCostBasis[msg.sender] += cost;
            totalYesShares += shareAmount;
        } else if (outcome == OUTCOME_NO) {
            qNo += shareAmount;
            noShares[msg.sender] += shareAmount;
            noCostBasis[msg.sender] += cost;
            totalNoShares += shareAmount;
        } else {
            revert InvalidOutcome();
        }

        totalCostBasis += cost;
        settlementPool += cost;

        uint256 refund = msg.value - cost;
        if (refund != 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert TransferFailed();
        }

        emit SharesPurchased(
            msg.sender,
            outcome == OUTCOME_YES,
            shareAmount,
            cost
        );
        _adaptB();
    }

    function swapOut(
        uint256 outcome,
        uint256 shareAmount,
        uint256 minRefund
    ) external nonReentrant whenNotPaused {
        if (isResolved || isCancelled) revert MarketIsResolved();
        if (shareAmount == 0) revert ZeroAmount();
        uint256 refund = getSellRefund(outcome, shareAmount);
        if (refund < minRefund) revert SlippageExceeded();

        if (outcome == OUTCOME_YES) {
            if (yesShares[msg.sender] < shareAmount) revert SlippageExceeded();
            yesShares[msg.sender] -= shareAmount;
            qYes -= shareAmount;
            totalYesShares -= shareAmount;
        } else if (outcome == OUTCOME_NO) {
            if (noShares[msg.sender] < shareAmount) revert SlippageExceeded();
            noShares[msg.sender] -= shareAmount;
            qNo -= shareAmount;
            totalNoShares -= shareAmount;
        } else {
            revert InvalidOutcome();
        }

        if (refund > settlementPool) refund = settlementPool;
        settlementPool -= refund;
        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        if (!ok) revert TransferFailed();
        emit SharesSold(
            msg.sender,
            outcome == OUTCOME_YES,
            shareAmount,
            refund
        );
        _adaptB();
    }

    function resolve(uint256 _winningOutcome) external onlyAdmin {
        if (isResolved || isCancelled) revert MarketAlreadyResolved();
        if (_winningOutcome > OUTCOME_NO) revert InvalidOutcome();
        isResolved = true;
        winningOutcome = _winningOutcome;
        uint256 totalWinning = _winningOutcome == OUTCOME_YES
            ? totalYesShares
            : totalNoShares;
        payoutPerShareSnapshot = totalWinning == 0
            ? 0
            : settlementPool / totalWinning;
        payoutSnapshotted = true;
        emit MarketResolved(_winningOutcome, payoutPerShareSnapshot);
    }

    function cancelMarket() external onlyAdmin {
        if (isResolved || isCancelled) revert MarketAlreadyResolved();
        isCancelled = true;
        emit MarketCancelled(msg.sender);
    }

    function pause() external onlyAdmin {
        paused = true;
        emit MarketPaused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit MarketUnpaused(msg.sender);
    }

    function setOwner(address newOwner) external onlyAdmin {
        if (newOwner == address(0)) revert Unauthorized();
        admin = newOwner;
    }

    function setPrizeDistributor(address distributor) external onlyAdmin {
        prizeDistributor = distributor;
    }

    function claimWinnings() external nonReentrant returns (uint256 payout) {
        if (!isResolved) revert MarketIsResolved();
        if (hasClaimed[msg.sender]) revert Unauthorized();
        hasClaimed[msg.sender] = true;
        uint256 shares = winningOutcome == OUTCOME_YES
            ? yesShares[msg.sender]
            : noShares[msg.sender];
        payout = shares * payoutPerShareSnapshot;
        if (payout > settlementPool) payout = settlementPool;
        settlementPool -= payout;
        (bool ok, ) = payable(msg.sender).call{value: payout}("");
        if (!ok) revert TransferFailed();
        emit WinningsClaimed(msg.sender, payout);
    }

    function claimRefund() external nonReentrant returns (uint256 amount) {
        if (!isCancelled) revert MarketCancelledError();
        if (hasClaimedRefund[msg.sender]) revert Unauthorized();
        hasClaimedRefund[msg.sender] = true;
        amount = yesCostBasis[msg.sender] + noCostBasis[msg.sender];
        if (amount > settlementPool) amount = settlementPool;
        settlementPool -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RefundClaimed(msg.sender, amount);
    }

    function previewClaim(address user) external view returns (uint256) {
        if (!isResolved) return 0;
        uint256 shares = winningOutcome == OUTCOME_YES
            ? yesShares[user]
            : noShares[user];
        return shares * payoutPerShareSnapshot;
    }

    function getPayoutPerShare() external view returns (uint256) {
        return payoutPerShareSnapshot;
    }

    function getMarketInfo()
        external
        view
        returns (
            uint256 _marketId,
            string memory _question,
            uint256 _qYes,
            uint256 _qNo,
            uint256 _b,
            uint256 _settlementPool,
            bool _isResolved,
            uint256 _winningOutcome
        )
    {
        return (
            marketId,
            question,
            qYes,
            qNo,
            b,
            settlementPool,
            isResolved,
            winningOutcome
        );
    }

    function userShares(
        address user,
        uint256 outcome
    ) external view returns (uint256) {
        if (outcome == OUTCOME_YES) return yesShares[user];
        if (outcome == OUTCOME_NO) return noShares[user];
        revert InvalidOutcome();
    }

    function totalSharesPerOutcome(
        uint256 outcome
    ) external view returns (uint256) {
        if (outcome == OUTCOME_YES) return totalYesShares;
        if (outcome == OUTCOME_NO) return totalNoShares;
        revert InvalidOutcome();
    }

    function transferSettlementPool() external onlyAdmin {
        uint256 amount = settlementPool;
        settlementPool = 0;
        address to = prizeDistributor == address(0) ? admin : prizeDistributor;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _adaptB() private {
        uint256 openInterest = totalYesShares + totalNoShares;
        uint256 newB = initialB + openInterest / 10;
        if (newB != b) {
            b = newB;
            emit AdaptiveBUpdated(newB);
        }
    }

    receive() external payable {
        settlementPool += msg.value;
    }
}
