// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {HarborTideFactoryDeployer} from "@tide-script/src/HarborTideFactoryDeployer.sol";
import {ITokenPool} from "@tide-script/ccip/ICCIP.sol";

/// @notice Accept ownership of the Chainlink BurnMintTokenPool from the Harbor multisig.
/// @dev The pool is `Ownable2Step`: `Deploy.s.sol` calls `transferOwnership(multisig)` from the
///      deployer, which only sets the multisig as the pending owner. The multisig must then call
///      `acceptOwnership()` (this script) before it can run `Configure_CCIP.s.sol`.
///
/// @dev The pool address is read from `deployments/aux-<chainId>.json` (written by Deploy.s.sol);
///      override with the POOL env var if needed.
///
/// Usage (run as the multisig):
///   forge script script/AcceptPoolOwnership.s.sol:AcceptPoolOwnership \
///     --rpc-url <network> --broadcast --account multisig --sender 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2
contract AcceptPoolOwnership is HarborTideFactoryDeployer, Script {
    function run() external {
        address pool = vm.envOr("POOL", address(0));
        if (pool == address(0)) pool = _readDeployedPool(block.chainid);

        vm.startBroadcast();
        ITokenPool(pool).acceptOwnership();
        vm.stopBroadcast();

        address newOwner = ITokenPool(pool).owner();
        require(newOwner == owner(), "AcceptPoolOwnership: owner != Harbor multisig");
        console.log("Pool %s ownership accepted by %s", pool, newOwner);
    }
}
