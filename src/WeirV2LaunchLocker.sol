// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IERC721ReceiverLike} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title WeirV2LaunchLocker
 * @notice Holds the graduated Uniswap V4 position NFT for every weir v2
 * launch. Unlike v1's locker, there is no `collectFees()` here: fee
 * collection and distribution belong entirely to WeirV2MemeHook and
 * WeirV2FeeEscrow, since a V4 position accrues fees inside the singleton
 * PoolManager rather than on the NFT itself.
 *
 * There is no administrative withdrawal. The single path that can remove
 * liquidity is `redeemLiquidity`, callable only by WeirV2PoolRedemption,
 * which itself only acts after a pool's futarchy market has resolved PASS,
 * only for launch members burning their own tokens, and only up to 40% of
 * the position's liquidity. The other 60% can never leave.
 */
contract WeirV2LaunchLocker is Ownable2Step, IERC721ReceiverLike {
    using SafeERC20 for IERC20;

    uint256 private constant MODIFY_DEADLINE_WINDOW = 300;

    error NotFactory();
    error NotRedemption();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionAlreadyLocked();
    error PositionNotHeld();
    error PositionNotLocked();
    error NotPositionManager();
    error OwnershipCannotBeRenounced();

    event FactorySet(address factory);
    event RedemptionSet(address redemption);
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event TokenSupplyLocked(address indexed token, uint256 amount);
    event LiquidityRedeemed(address indexed token, uint256 indexed tokenId, uint256 liquidity, address recipient);

    address public immutable positionManager;
    address public factory;
    // The only contract allowed to take liquidity out, set once.
    address public redemption;

    mapping(address token => uint256 tokenId) public lockedPositions;
    mapping(address token => uint256 amount) public lockedTokenSupply;
    mapping(address token => bool locked) private _locked;

    /**
     * @param initialOwner Administrative owner; only used to wire the factory once.
     * @param positionManager_ The canonical Uniswap V4 PositionManager for this chain.
     */
    constructor(address initialOwner, address positionManager_) Ownable(initialOwner) {
        if (positionManager_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /**
     * @notice One-time wiring of the v2 factory, set after both are deployed.
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /**
     * @notice One-time wiring of the redemption contract, the only caller of
     * `redeemLiquidity`.
     */
    function setRedemption(address redemption_) external onlyOwner {
        if (redemption != address(0)) revert AlreadyInitialized();
        if (redemption_ == address(0)) revert ZeroAddress();
        redemption = redemption_;
        emit RedemptionSet(redemption_);
    }

    /**
     * @notice Removes `liquidity` from a launch's locked position and sends
     * both currencies to `recipient`. Restricted to WeirV2PoolRedemption,
     * which enforces the futarchy unlock, membership and the 40% ceiling
     * before ever calling this. Minimum amounts are zero here because the
     * redemption contract checks the caller's own quote floor on what it
     * actually receives.
     */
    function redeemLiquidity(address token, uint256 liquidity, address recipient) external {
        if (msg.sender != redemption) revert NotRedemption();
        if (!_locked[token]) revert PositionNotLocked();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 tokenId = lockedPositions[token];
        (PoolKey memory key,) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        IPositionManager(positionManager).modifyLiquidities(
            abi.encode(actions, params), block.timestamp + MODIFY_DEADLINE_WINDOW
        );

        emit LiquidityRedeemed(token, tokenId, liquidity, recipient);
    }

    /**
     * @notice Permanently disabled. Ownership here exists only to perform the
     * one-time factory wiring, and renouncing before that wiring would leave
     * the locker unable to ever accept a graduated position.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /**
     * @notice Rejects safe transfers of anything but a canonical position NFT.
     * @dev Not part of the graduation path. Graduation names this locker as
     * the `MINT_POSITION` owner, and the PositionManager mints with a plain
     * `_mint`, which fires no receiver callback. Custody is established by
     * the `ownerOf` check in `lockPosition` instead. This exists so the
     * locker still behaves correctly under an explicit `safeTransferFrom`,
     * and so such a transfer can only ever originate from the canonical
     * PositionManager.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Registers and verifies permanent custody of a graduated position.
     * @dev Called once per launch by the factory, immediately after minting
     * the full-range position directly to this locker's address.
     */
    function lockPosition(address token, uint256 tokenId) external onlyFactory {
        if (_locked[token]) revert PositionAlreadyLocked();
        if (IERC721(positionManager).ownerOf(tokenId) != address(this)) revert PositionNotHeld();

        _locked[token] = true;
        lockedPositions[token] = tokenId;
        emit PositionLocked(token, tokenId);
    }

    /**
     * @notice Permanently locks the virtual-reserve token remainder that
     * cannot enter the graduated pool without lowering its opening price.
     */
    function lockTokenSupply(address token, uint256 amount) external onlyFactory {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lockedTokenSupply[token] += amount;
        emit TokenSupplyLocked(token, amount);
    }

    /**
     * @notice Returns whether a launch's position has been locked here.
     */
    function isLocked(address token) external view returns (bool) {
        return _locked[token];
    }
}
