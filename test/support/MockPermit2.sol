// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Address placeholder for Uniswap's Permit2 in factory-stack tests.
/// Wiring checks compare permit2 by address only; nothing before pool
/// seeding (TestCase 4.12/§8) calls into it, and the concrete Permit2
/// contract pins solc =0.8.17, which cannot join this project's import
/// closure. Pool-seeding tests must supply the real deployment.
contract MockPermit2Placeholder {}
