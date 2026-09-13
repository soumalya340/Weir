// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ABI-compatible mirror of 1inch SwapVM's `ISwapVM` (deps/swap-vm/src/
// interfaces/ISwapVM.sol). Declared locally rather than imported because the
// vendored SwapVM sources pin `pragma solidity 0.8.30` and depend on the
// 1inch solidity-utils and aqua npm packages this Foundry project does not
// vendor. Weir never deploys or modifies SwapVM; it only calls the official
// router (`SwapVMRouter` / `LimitSwapVMRouter`, or a local-fork redeploy of
// it for demos) through this surface.
//
// `Order.traits` is `MakerTraits` upstream, a user-defined value type over
// `uint256`, so the ABI encoding is identical.
interface ISwapVM {
    /// @param maker Address of the liquidity provider (the backer / market maker).
    /// @param traits Packed MakerTraits flags, hook slice offsets and receiver.
    /// @param data `tokenA ++ tokenB ++ [hook data] ++ program` (tokenA < tokenB).
    struct Order {
        address maker;
        uint256 traits;
        bytes data;
    }

    /// @notice EIP-712 hash for signature-mode orders, `keccak256(abi.encode(order))` for Aqua-mode orders.
    function hash(Order calldata order) external view returns (bytes32);

    /// @notice Preview a fill without executing (call via staticcall).
    function quote(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    /// @notice Execute a fill against a maker's order. `msg.value` is only
    /// accepted when `tokenIn` is the router's WETH.
    function swap(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    /// @notice The router's wrapped-native token, used to pay native ETH into a fill.
    function WETH() external view returns (address);
}
