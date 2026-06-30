// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// This file exists only to force Foundry to compile the Chainlink CCIP pool (Solidity 0.8.24) so its
// artifact is available to `deployCode("BurnMintTokenPool.sol:BurnMintTokenPool", ...)` in the deploy
// scripts. It is deliberately isolated at pragma ^0.8.24 and imports no 0.8.30 sources, so it never
// shares a compilation unit with the rest of the repo (which targets 0.8.30).

// solhint-disable-next-line no-unused-import
import {BurnMintTokenPool} from "@chainlink/contracts/ccip/pools/BurnMintTokenPool.sol";
