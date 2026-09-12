// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWeirV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title WeirV2FeeEscrow
 * @notice Single shared claimable-balance ledger for every weir v2 launch.
 * Crediting is permissionless by design (see IWeirV2FeeEscrow): native ETH
 * crediting requires the caller to attach the exact ETH being credited, and
 * token crediting requires the caller to hold and approve the tokens
 * themselves, pulled via `transferFrom`. Claiming only ever moves a caller's
 * own balance to themselves, so no access control is needed there either.
 */
contract WeirV2FeeEscrow is IWeirV2FeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InsufficientBalance();
    error NativeTransferFailed();

    mapping(address recipient => uint256 amount) private _balances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;

    /// @inheritdoc IWeirV2FeeEscrow
    function credit(address recipient) external payable override {
        if (recipient == address(0)) revert ZeroAddress();
        _balances[recipient] += msg.value;
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function creditToken(address recipient, address token, uint256 amount) external override {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _tokenBalances[recipient][token] += amount;
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function claim() external override nonReentrant returns (uint256 amount) {
        amount = _balances[msg.sender];
        _balances[msg.sender] = 0;
        _sendNative(msg.sender, amount);
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function claim(uint256 amount) external override nonReentrant returns (uint256) {
        uint256 balance = _balances[msg.sender];
        if (amount > balance) revert InsufficientBalance();
        _balances[msg.sender] = balance - amount;
        _sendNative(msg.sender, amount);
        return amount;
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function claimToken(address token) external override nonReentrant returns (uint256 amount) {
        amount = _tokenBalances[msg.sender][token];
        _tokenBalances[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function claimToken(address token, uint256 amount) external override nonReentrant returns (uint256) {
        uint256 balance = _tokenBalances[msg.sender][token];
        if (amount > balance) revert InsufficientBalance();
        _tokenBalances[msg.sender][token] = balance - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        return amount;
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function balanceOf(address recipient) external view override returns (uint256) {
        return _balances[recipient];
    }

    /// @inheritdoc IWeirV2FeeEscrow
    function balanceOfToken(address recipient, address token) external view override returns (uint256) {
        return _tokenBalances[recipient][token];
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }
}
