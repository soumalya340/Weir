// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapVM} from "../interfaces/ISwapVM.sol";

/**
 * @title SwapVMOrderLib
 * @notice Byte-level builders for the two SwapVM artefacts Weir needs to
 * produce on-chain: a canonical one-shot limit-order program (maker side) and
 * packed taker traits (taker side). Both mirror the encoding in
 * deps/swap-vm exactly (InstructionBuilder, MakerTraitsLib.build,
 * TakerTraitsLib.build) so the result is accepted by the *official* routers
 * unchanged. No opcode is added or modified: every instruction emitted here
 * already ships in `Opcodes` and `LimitOpcodes`.
 *
 * Instruction wire format is `[opcode u8][argsLength u8][args]`.
 */
library SwapVMOrderLib {
    // Opcode numbers from deps/swap-vm/src/libs/OpcodeList.sol (hex indices).
    uint8 internal constant OP_DEADLINE = 0x20;
    uint8 internal constant OP_INVALIDATE_BIT = 0x40;
    uint8 internal constant OP_LIMIT_SWAP = 0x53;
    uint8 internal constant OP_STATIC_BALANCES = 0x90;

    // MakerTraits bit flags (MakerTraitsLib).
    uint256 internal constant MAKER_USE_AQUA_INSTEAD_OF_SIGNATURE = 1 << 254;
    uint256 internal constant MAKER_DATA_SLICES_BIT_OFFSET = 160;
    // Four hook slices, all empty: each boundary sits right after the two
    // 20-byte token addresses, so index0..index3 are all 40 (0x28).
    uint64 internal constant MAKER_NO_HOOK_SLICES = 0x0028002800280028;

    // TakerTraits bit flags (TakerTraitsLib).
    uint16 internal constant TAKER_IS_EXACT_IN = 0x0001;
    uint16 internal constant TAKER_IS_STRICT_THRESHOLD = 0x0010;
    uint16 internal constant TAKER_IS_A_TO_B = 0x0080;
    uint16 internal constant TAKER_ALLOW_PARTIAL_FILL = 0x0100;

    error TokensNotSorted();

    /**
     * @notice Builds the program `InvalidateBit(nonce) · [Deadline(deadline)] ·
     * StaticBalances(balanceA, balanceB) · LimitSwap(direction)`.
     * @dev `InvalidateBit` makes the order fill at most once per maker
     * (SwapVM flips the bit in the maker's bitmap on execution), which is what
     * stops a settled or abandoned commitment from being replayed against the
     * backer later. `Deadline` (skipped when zero) bounds how long the resting
     * order stays fillable at all. `direction` is `tokenIn < tokenOut` from the
     * taker's point of view and must match the fill or LimitSwap reverts.
     */
    function limitOrderProgram(uint32 nonceBit, uint40 deadline, uint256 balanceA, uint256 balanceB, bool direction)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory deadlineIx = deadline == 0 ? bytes("") : abi.encodePacked(OP_DEADLINE, uint8(5), deadline);
        return bytes.concat(
            abi.encodePacked(OP_INVALIDATE_BIT, uint8(4), nonceBit),
            deadlineIx,
            abi.encodePacked(OP_STATIC_BALANCES, uint8(64), balanceA, balanceB),
            // InstructionBuilder.encodeBool(direction, bit 0) => 0x80 when true.
            abi.encodePacked(OP_LIMIT_SWAP, uint8(1), direction ? uint8(0x80) : uint8(0))
        );
    }

    /**
     * @notice Wraps a program into an order with no maker hooks, no custom
     * receiver and no WETH unwrapping, exactly as `MakerTraitsLib.build`
     * would with those fields left empty.
     * @param useAqua Set the `useAquaInsteadOfSignature` flag: the router then
     * skips signature recovery and sources/settles the maker's balance through
     * Aqua (the maker must have `ship()`ed this exact order there first).
     */
    function buildOrder(address maker, address tokenA, address tokenB, bytes memory program, bool useAqua)
        internal
        pure
        returns (ISwapVM.Order memory order)
    {
        if (tokenA >= tokenB) revert TokensNotSorted();
        uint256 traits = (uint256(MAKER_NO_HOOK_SLICES) << MAKER_DATA_SLICES_BIT_OFFSET)
            | (useAqua ? MAKER_USE_AQUA_INSTEAD_OF_SIGNATURE : 0);
        order = ISwapVM.Order({maker: maker, traits: traits, data: bytes.concat(abi.encodePacked(tokenA, tokenB), program)});
    }

    /**
     * @notice Packs taker traits + data the way `TakerTraitsLib.build` does
     * for a taker that sets a threshold, optionally a deadline, and (in
     * signature mode) the maker's signature, with no hooks, callbacks,
     * custom recipient, WETH unwrap, or instruction args.
     * @param isExactIn `amount` passed to `swap` is the input amount.
     * @param isAToB The taker pays `tokenA` and receives `tokenB`.
     * @param allowPartialFill Accept a fill smaller than `amount`; the
     * threshold is then scaled pro rata by the router.
     * @param strictThreshold Require the counter-amount to equal `threshold`
     * exactly instead of treating it as a minimum output / maximum input.
     */
    function buildTakerTraits(
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill,
        bool strictThreshold,
        uint256 threshold,
        uint40 deadline,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        uint16 index0 = 32; // threshold slice, always present
        uint16 index1 = index0; // no custom `to`
        uint16 index2 = index1 + (deadline != 0 ? 5 : 0);
        // index3 .. index9 all equal index2: no hook data, no callback data,
        // no instruction args. Whatever follows is the signature slice.
        uint16 flags = (isExactIn ? TAKER_IS_EXACT_IN : 0) | (strictThreshold ? TAKER_IS_STRICT_THRESHOLD : 0)
            | (isAToB ? TAKER_IS_A_TO_B : 0) | (allowPartialFill ? TAKER_ALLOW_PARTIAL_FILL : 0);
        return abi.encodePacked(
            index2, // index9
            index2, // index8
            index2, // index7
            index2, // index6
            index2, // index5
            index2, // index4
            index2, // index3
            index2,
            index1,
            index0,
            flags,
            threshold,
            deadline != 0 ? abi.encodePacked(deadline) : bytes(""),
            signature
        );
    }

    /**
     * @notice Sorted token pair plus whether `first` sorts lowest.
     */
    function sortTokens(address first, address second)
        internal
        pure
        returns (address tokenA, address tokenB, bool firstIsA)
    {
        firstIsA = first < second;
        (tokenA, tokenB) = firstIsA ? (first, second) : (second, first);
    }
}
