// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {HarborTideFactoryDeployer} from "@tide-script/src/HarborTideFactoryDeployer.sol";
import {CCIPChains} from "@tide-script/config/CCIPChains.sol";
import {
    ITokenPool,
    ITokenAdminRegistry,
    IRegistryModuleOwnerCustom,
    ChainUpdate,
    RateLimiterConfig
} from "@tide-script/ccip/ICCIP.sol";

/// @notice Register the Harbor Tide token in the local CCIP TokenAdminRegistry and wire cross-chain
///         lanes on the local BurnMintTokenPool.
/// @dev Intended to be executed by the Harbor multisig (the CCIP token admin and the pool owner):
///        1. registerAdminViaGetCCIPAdmin(token)  (admin = token.getCCIPAdmin() = multisig)
///        2. acceptAdminRole(token)
///        3. setPool(token, pool)
///        4. applyChainUpdates(...) for each remote chain (token + pool share one address per chain)
///      Rate limits are disabled by default; set them per lane before production as policy dictates.
///
/// @dev The token shares one CREATE3 address on every chain, so `remoteTokenAddress` is the same
///      everywhere. The Chainlink pool is deployed with plain CREATE (its deployer must be its owner),
///      so each chain's pool address differs.
///
/// @dev Pool addresses are read automatically from the deployments/aux-<chainId>.json files written by
///      Deploy.s.sol (run on each chain first). You can override with POOL and REMOTE_POOLS env vars.
///      REMOTE_CHAIN_IDS defaults to the other target chains; override to wire a subset.
///
/// Usage (after deploying on all chains):
///   forge script script/Configure_CCIP.s.sol:Configure_CCIP --rpc-url mainnet --broadcast --account multisig
/// Override example:
///   POOL=0x... REMOTE_CHAIN_IDS=42161,8453 REMOTE_POOLS=0xArb...,0xBase... forge script ...
contract Configure_CCIP is HarborTideFactoryDeployer, Script {
    function run() external {
        address token = _predictAddress("token");

        // Local pool: env override, else the recorded deployment for this chain.
        address pool = vm.envOr("POOL", address(0));
        if (pool == address(0)) pool = _readDeployedPool(block.chainid);

        // Lanes to wire: env override, else the other target chains.
        uint256[] memory remoteChainIds = vm.envOr("REMOTE_CHAIN_IDS", ",", _defaultRemoteChainIds());

        // Remote pools: env override, else read each from its recorded deployment.
        address[] memory remotePools = vm.envOr("REMOTE_POOLS", ",", new address[](0));
        if (remotePools.length == 0) {
            remotePools = new address[](remoteChainIds.length);
            for (uint256 i = 0; i < remoteChainIds.length; i++) {
                remotePools[i] = _readDeployedPool(remoteChainIds[i]);
            }
        }
        require(remotePools.length == remoteChainIds.length, "REMOTE_POOLS/REMOTE_CHAIN_IDS length mismatch");

        CCIPChains.Config memory local = CCIPChains.configFor(block.chainid);

        vm.startBroadcast();

        // 1-3. Register the token admin (via getCCIPAdmin) and point the registry at the local pool.
        IRegistryModuleOwnerCustom(local.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(token);
        ITokenAdminRegistry(local.tokenAdminRegistry).acceptAdminRole(token);
        ITokenAdminRegistry(local.tokenAdminRegistry).setPool(token, pool);

        // 4. Wire each remote lane. Token address is identical cross-chain (CREATE3); pool differs.
        ChainUpdate[] memory updates = new ChainUpdate[](remoteChainIds.length);
        for (uint256 i = 0; i < remoteChainIds.length; i++) {
            CCIPChains.Config memory remote = CCIPChains.configFor(remoteChainIds[i]);
            updates[i] = ChainUpdate({
                remoteChainSelector: remote.chainSelector,
                allowed: true,
                remotePoolAddress: abi.encode(remotePools[i]),
                remoteTokenAddress: abi.encode(token),
                outboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0}),
                inboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0})
            });
            console.log("    lane -> chainId %s selector %s", remoteChainIds[i], remote.chainSelector);
        }
        ITokenPool(pool).applyChainUpdates(updates);

        vm.stopBroadcast();

        console.log("CCIP configured on chainId %s for token %s pool %s", block.chainid, token, pool);
    }

    /// @notice The Harbor Tide target chains other than the current one.
    function _defaultRemoteChainIds() internal view returns (uint256[] memory remotes) {
        uint256[5] memory all = [
            CCIPChains.ETHEREUM,
            CCIPChains.ARBITRUM,
            CCIPChains.BASE,
            CCIPChains.MEGAETH,
            CCIPChains.ROBINHOOD
        ];
        remotes = new uint256[](4);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != block.chainid) remotes[n++] = all[i];
        }
    }
}
