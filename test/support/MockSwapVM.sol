// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "../../src/interfaces/ISwapVM.sol";

/// @dev Programmable ISwapVM stand-in (TestCase shared "Mock SwapVM router"
/// fixture). Records every (order, amount, takerData) call and fills per a
/// per-order plan: Succeed pulls `amountIn` of tokenIn from the taker and
/// pushes `amountOut` of tokenOut from the maker; Revert reverts;
/// Underdeliver moves nothing but reports success, which counterparty delta
/// checks treat as a failed fill (a taker-side token pull here would strand
/// the registry's burn accounting, so the mode is pure short delivery).
/// Native fills (msg.value) refund any unspent value to the caller, like
/// the real router.
contract MockSwapVM is ISwapVM {
    enum Mode {
        Succeed,
        Revert,
        Underdeliver
    }

    struct FillPlan {
        address tokenIn;
        address tokenOut;
        uint256 amountIn; // 0 => use the swap() amount param
        uint256 amountOut;
        Mode mode;
        bool planned;
    }

    address public immutable weth;
    mapping(bytes32 => FillPlan) public plans;

    struct Call {
        ISwapVM.Order order;
        uint256 amount;
        bytes takerData;
    }

    Call[] public calls;

    error MockSwapRevert();

    constructor(address weth_) {
        weth = weth_;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function hash(ISwapVM.Order calldata order) external pure returns (bytes32) {
        return keccak256(abi.encode(order.maker, order.traits, order.data));
    }

    function planFill(bytes32 orderHash, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        external
    {
        plans[orderHash] = FillPlan({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            mode: Mode.Succeed,
            planned: true
        });
    }

    function planMode(bytes32 orderHash, Mode mode) external {
        plans[orderHash].mode = mode;
        plans[orderHash].planned = true;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function quote(ISwapVM.Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)
    {
        orderHash = keccak256(abi.encode(order.maker, order.traits, order.data));
        FillPlan storage plan = plans[orderHash];
        amountIn = plan.planned && plan.amountIn != 0 ? plan.amountIn : amount;
        amountOut = plan.planned ? plan.amountOut : 0;
        takerTraitsAndData;
    }

    function swap(ISwapVM.Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)
    {
        calls.push(Call({order: order, amount: amount, takerData: takerTraitsAndData}));
        orderHash = keccak256(abi.encode(order.maker, order.traits, order.data));
        FillPlan storage plan = plans[orderHash];
        require(plan.planned, "MockSwapVM: no plan");
        if (plan.mode == Mode.Revert) revert MockSwapRevert();

        amountIn = plan.amountIn != 0 ? plan.amountIn : amount;
        require(amountIn <= amount, "MockSwapVM: amountIn exceeds amount");

        if (plan.mode == Mode.Underdeliver) {
            return (amountIn, 0, orderHash);
        }

        if (msg.value != 0) {
            require(amountIn <= msg.value, "MockSwapVM: amountIn exceeds value");
            if (plan.tokenIn != address(0)) {
                IERC20(plan.tokenIn).transferFrom(msg.sender, order.maker, amountIn);
            }
            uint256 refund = msg.value - amountIn;
            if (refund != 0) {
                (bool ok,) = payable(msg.sender).call{value: refund}("");
                require(ok, "MockSwapVM: refund failed");
            }
        } else {
            IERC20(plan.tokenIn).transferFrom(msg.sender, order.maker, amountIn);
        }

        amountOut = plan.amountOut;
        if (amountOut != 0) {
            IERC20(plan.tokenOut).transferFrom(order.maker, msg.sender, amountOut);
        }
    }

    receive() external payable {}
}
