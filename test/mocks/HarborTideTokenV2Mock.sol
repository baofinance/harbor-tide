// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";

/// @notice Mock V2 implementation used to test that UUPS upgrades preserve state and ownership.
// solhint-disable-next-line contract-name-capwords
contract HarborTideTokenV2Mock is HarborTideToken_v1 {
    function version() external pure returns (uint256) {
        return 2;
    }
}
