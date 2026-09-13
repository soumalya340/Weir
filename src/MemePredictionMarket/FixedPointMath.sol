// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal WAD fixed-point exp/ln helpers used by BinaryMarket.
/// @dev Vendored stand-in for the degencalls FixedPointMath dependency so the
/// repository builds without a gitignored external checkout. Sufficient for
/// WeirV2FutarchyProposal's LMSR pricing and the existing futarchy tests.
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    int256 internal constant WAD_INT = 1e18;

    error ExpInputTooLarge();
    error LnNonPositive();

    /// @dev e^x for signed WAD fixed-point. Domain roughly [-41e18, 135e18].
    function expWad(int256 x) internal pure returns (uint256) {
        unchecked {
            if (x > 135e18) revert ExpInputTooLarge();
            if (x < -41e18) return 0;

            // Convert to base-2 exponent: x / ln(2)
            int256 ln2 = 693147180559945309; // ln(2) * 1e18
            int256 sum = (x * WAD_INT) / ln2 + (x >= 0 ? int256(1) : int256(-1)) / 2;
            int256 k = sum / WAD_INT;
            int256 r = x - (k * ln2);

            // Taylor series for e^r around 0
            uint256 z = uint256(r + WAD_INT);
            uint256 rAbs = uint256(r < 0 ? -r : r);
            uint256 term = WAD;
            uint256 series = WAD;
            for (uint256 i = 1; i < 8; ++i) {
                term = (term * rAbs) / (WAD * i);
                if (r >= 0) series += term;
                else if (series > term) series -= term;
                else {
                    series = 0;
                    break;
                }
            }

            // Apply 2^k via shifting when possible; otherwise scale by e^(k*ln2) ≈ 2^k
            if (k >= 0) {
                if (k > 128) revert ExpInputTooLarge();
                return series << uint256(k);
            } else {
                uint256 shift = uint256(-k);
                if (shift >= 256) return 0;
                return series >> shift;
            }
        }
    }

    /// @dev ln(x) for unsigned WAD fixed-point. x must be > 0.
    function lnWad(uint256 x) internal pure returns (int256) {
        if (x == 0) revert LnNonPositive();

        // Normalize into [1e18, 2e18)
        uint256 n = x;
        int256 k;
        while (n >= 2 * WAD) {
            n >>= 1;
            k += 1;
        }
        while (n < WAD) {
            n <<= 1;
            k -= 1;
        }

        // p = (n - 1) in WAD, series ln(1+p) = p - p^2/2 + p^3/3 - ...
        int256 p = int256(n) - WAD_INT;
        int256 term = p;
        int256 sum = p;
        for (uint256 i = 2; i < 12; ++i) {
            term = (term * p) / WAD_INT;
            int256 delta = term / int256(i);
            if (i % 2 == 0) sum -= delta;
            else sum += delta;
        }

        int256 ln2 = 693147180559945309;
        return sum + k * ln2;
    }
}
