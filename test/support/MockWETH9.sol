// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @dev Minimal WETH9 for PositionManager/PositionDescriptor construction.
contract MockWETH9 is ERC20, IWETH9 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
