// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title TideDeployProxy
/// @notice ERC1967 proxy that may be constructed *uninitialized* (empty `_data`), for the via-stub
///         CREATE3 deploy pattern.
/// @dev OpenZeppelin v5.6.0 made `ERC1967Proxy` revert (`ERC1967ProxyUninitialized`) when constructed
///      with empty `_data`. The via-stub pattern intentionally deploys the proxy pointing at the
///      `UUPSProxyDeployStub` with *no* init data, then `upgradeToAndCall`s into the real implementation
///      from the deployer EOA (so `BaoOwnable`'s temporary owner is the deployer, not the CREATE3
///      transient deployer). Overriding `_unsafeAllowUninitialized()` re-enables that. This is safe here
///      because the very next call in the same deploy upgrades + initializes the proxy; it is never left
///      uninitialized on-chain.
contract TideDeployProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory _data) ERC1967Proxy(implementation, _data) {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
