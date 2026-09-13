// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapVMOrderLib} from "../src/libraries/SwapVMOrderLib.sol";
import {ISwapVM} from "../src/interfaces/ISwapVM.sol";

/// @notice TestCase §1: SwapVMOrderLib byte-exact encoding.
/// Every assertion here pins the wire format the official SwapVM routers
/// accept; any drift breaks settlement and compounding.
contract SwapVMOrderLibTest is Test {
    address internal constant TOKEN_A = address(1111);
    address internal constant TOKEN_B = address(2222);
    address internal constant MAKER = address(3333);

    // 1.1: limitOrderProgram layout with a deadline.
    function test_limitOrderProgram_layoutWithDeadline() public pure {
        uint32 nonce = 7;
        uint40 deadline = 1_800_000_000;
        uint256 balA = 1_000_000;
        uint256 balB = 2_000_000;

        bytes memory program = SwapVMOrderLib.limitOrderProgram(nonce, deadline, balA, balB, true);

        bytes memory expected = bytes.concat(
            abi.encodePacked(uint8(0x40), uint8(4), nonce),
            abi.encodePacked(uint8(0x20), uint8(5), deadline),
            abi.encodePacked(uint8(0x90), uint8(64), balA, balB),
            abi.encodePacked(uint8(0x53), uint8(1), uint8(0x80))
        );
        assertEq(program, expected);
        // [0x40,4,nonce][0x20,5,deadline][0x90,64,balA,balB][0x53,1,dir]
        assertEq(program.length, 6 + 7 + 66 + 3);
    }

    // 1.1: direction byte false, and Deadline omitted when deadline == 0.
    function test_limitOrderProgram_directionFalseAndNoDeadline() public pure {
        bytes memory withDir = SwapVMOrderLib.limitOrderProgram(1, 99, 5, 6, false);
        assertEq(withDir[withDir.length - 1], bytes1(uint8(0x00)));

        bytes memory noDeadline = SwapVMOrderLib.limitOrderProgram(1, 0, 5, 6, true);
        bytes memory expected = bytes.concat(
            abi.encodePacked(uint8(0x40), uint8(4), uint32(1)),
            abi.encodePacked(uint8(0x90), uint8(64), uint256(5), uint256(6)),
            abi.encodePacked(uint8(0x53), uint8(1), uint8(0x80))
        );
        assertEq(noDeadline, expected);
        assertEq(noDeadline.length, 6 + 66 + 3);
    }

    // 1.2: buildOrder traits — slices, aqua flag, receiver, token layout.
    function test_buildOrder_traitsAndLayout() public pure {
        bytes memory program = hex"1234";
        ISwapVM.Order memory plain = SwapVMOrderLib.buildOrder(MAKER, TOKEN_A, TOKEN_B, program, false);
        ISwapVM.Order memory aqua = SwapVMOrderLib.buildOrder(MAKER, TOKEN_A, TOKEN_B, program, true);

        // Four hook slice indexes (bits 160/176/192/208) all equal 40.
        assertEq(uint16(uint256(plain.traits >> 160) & 0xFFFF), 40);
        assertEq(uint16(uint256(plain.traits >> 176) & 0xFFFF), 40);
        assertEq(uint16(uint256(plain.traits >> 192) & 0xFFFF), 40);
        assertEq(uint16(uint256(plain.traits >> 208) & 0xFFFF), 40);

        // Bit 254 set iff useAqua; receiver (low 160 bits) zero either way.
        assertEq((plain.traits >> 254) & 1, 0);
        assertEq((aqua.traits >> 254) & 1, 1);
        assertEq(plain.traits & ((uint256(1) << 160) - 1), 0);
        assertEq(aqua.traits & ((uint256(1) << 160) - 1), 0);

        // data[0:20] == tokenA, data[20:40] == tokenB, then the program.
        assertEq(_addr(plain.data, 0), TOKEN_A);
        assertEq(_addr(plain.data, 20), TOKEN_B);
        assertEq(plain.data.length, 40 + program.length);
        assertEq(plain.maker, MAKER);
    }

    // 1.2: unsorted tokens revert (via external wrapper: internal library
    // calls inline, so expectRevert needs a call boundary).
    function test_buildOrder_revertsTokensNotSorted() public {
        OrderBuilderWrapper wrapper = new OrderBuilderWrapper();

        vm.expectRevert(SwapVMOrderLib.TokensNotSorted.selector);
        wrapper.buildOrder(MAKER, TOKEN_B, TOKEN_A, hex"00", false);

        vm.expectRevert(SwapVMOrderLib.TokensNotSorted.selector);
        wrapper.buildOrder(MAKER, TOKEN_A, TOKEN_A, hex"00", false);
    }

    // 1.3: buildTakerTraits layout — full flags + deadline + signature.
    function test_buildTakerTraits_fullLayout() public pure {
        bytes memory sig = hex"deadbeef";
        uint256 threshold = 777_000;
        uint40 deadline = 1_234_567;
        bytes memory traits = SwapVMOrderLib.buildTakerTraits(true, true, true, true, threshold, deadline, sig);

        // index0 == 32; with a 5-byte deadline index1 == 32, index2..9 == 37.
        // First 20 bytes are ten uint16 in index9..index0 order.
        bytes memory expectedHead = abi.encodePacked(
            uint16(37), // index9
            uint16(37), // index8
            uint16(37), // index7
            uint16(37), // index6
            uint16(37), // index5
            uint16(37), // index4
            uint16(37), // index3
            uint16(37), // index2
            uint16(32), // index1
            uint16(32), // index0
            uint16(0x0001 | 0x0010 | 0x0080 | 0x0100) // exactIn|strict|AToB|partial
        );
        bytes memory expected = bytes.concat(expectedHead, abi.encodePacked(threshold, deadline, sig));
        assertEq(traits, expected);
    }

    // 1.3: individual flag bits and deadline omission.
    function test_buildTakerTraits_flagBitsAndNoDeadline() public pure {
        bytes memory base = SwapVMOrderLib.buildTakerTraits(false, false, false, false, 1, 0, bytes(""));
        // No deadline: index2..9 collapse to 32; flags word is zero.
        assertEq(base.length, 20 + 2 + 32);
        assertEq(_flags(base), uint16(0));

        bytes memory exact = SwapVMOrderLib.buildTakerTraits(true, false, false, false, 1, 0, bytes(""));
        assertEq(_flags(exact) & 0x0001, 0x0001);

        bytes memory strict = SwapVMOrderLib.buildTakerTraits(false, false, false, true, 1, 0, bytes(""));
        assertEq(_flags(strict) & 0x0010, 0x0010);

        bytes memory atob = SwapVMOrderLib.buildTakerTraits(false, true, false, false, 1, 0, bytes(""));
        assertEq(_flags(atob) & 0x0080, 0x0080);

        bytes memory part = SwapVMOrderLib.buildTakerTraits(false, false, true, false, 1, 0, bytes(""));
        assertEq(_flags(part) & 0x0100, 0x0100);
    }

    /// @dev Flags word lives at bytes [20:22] (big-endian uint16).
    function _flags(bytes memory traits) internal pure returns (uint16) {
        return (uint16(uint8(traits[20])) << 8) | uint16(uint8(traits[21]));
    }

    /// @dev 20-byte big-endian address at `offset` in a memory byte array.
    function _addr(bytes memory data, uint256 offset) internal pure returns (address result) {
        require(data.length >= offset + 20, "oob");
        assembly {
            result := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    // 1.4: fork parity against the official router + upstream trait helpers.
    // Requires FORK_RPC_URL plus a 0.8.30 harness around deps/swap-vm's
    // MakerTraitsLib/TakerTraitsLib (which this repo does not vendor-build),
    // so it is recorded here as a gated placeholder, not silently dropped.
    function test_fork_parityWithUpstreamHelpers() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP 1.4: no FORK_RPC_URL; needs official SwapVMRouter + 0.8.30 upstream-helper harness");
            vm.skip(true);
        }
        // When wired: build an order here, rebuild it with
        // MakerTraitsLib.build/TakerTraitsLib.build, and assert
        // router.quote returns identical (amountIn, amountOut) for both.
        vm.skip(true);
    }

    // 1.5: sortTokens orderings and adjacent-address edge.
    function test_sortTokens_orderingsAndEdge() public pure {
        (address a, address b, bool firstIsA) = SwapVMOrderLib.sortTokens(TOKEN_A, TOKEN_B);
        assertEq(a, TOKEN_A);
        assertEq(b, TOKEN_B);
        assertTrue(firstIsA);

        (a, b, firstIsA) = SwapVMOrderLib.sortTokens(TOKEN_B, TOKEN_A);
        assertEq(a, TOKEN_A);
        assertEq(b, TOKEN_B);
        assertFalse(firstIsA);

        address low = address(1000);
        address high = address(1001);
        (a, b, firstIsA) = SwapVMOrderLib.sortTokens(high, low);
        assertEq(a, low);
        assertEq(b, high);
        assertFalse(firstIsA);
    }
}

/// @dev External boundary so expectRevert can catch the library's revert
/// (internal library calls inline into the test otherwise).
contract OrderBuilderWrapper {
    function buildOrder(address maker, address tokenA, address tokenB, bytes memory program, bool useAqua)
        external
        pure
        returns (ISwapVM.Order memory)
    {
        return SwapVMOrderLib.buildOrder(maker, tokenA, tokenB, program, useAqua);
    }
}
