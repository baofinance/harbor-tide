// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Local, version-agnostic interfaces + structs for the Chainlink CCIP contracts we call.
/// @dev Struct layouts mirror the Chainlink CCIP 1.5.0 `TokenPool.ChainUpdate` and `RateLimiter.Config`
///      so ABI-encoded external calls match. We declare them locally to avoid importing 0.8.24 sources
///      into our 0.8.30 scripts.

/// @notice Mirror of Chainlink `RateLimiter.Config`.
struct RateLimiterConfig {
    bool isEnabled;
    uint128 capacity;
    uint128 rate;
}

/// @notice Mirror of Chainlink `TokenPool.ChainUpdate` (1.5.0).
struct ChainUpdate {
    uint64 remoteChainSelector;
    bool allowed;
    bytes remotePoolAddress;
    bytes remoteTokenAddress;
    RateLimiterConfig outboundRateLimiterConfig;
    RateLimiterConfig inboundRateLimiterConfig;
}

/// @notice Subset of the CCIP `BurnMintTokenPool` / `TokenPool` we use.
interface ITokenPool {
    function applyChainUpdates(ChainUpdate[] calldata chains) external;
    function owner() external view returns (address);
    function transferOwnership(address to) external;
    function acceptOwnership() external;
    function getToken() external view returns (address);
    function getRouter() external view returns (address);
    function getRmnProxy() external view returns (address);
    function isSupportedChain(uint64 remoteChainSelector) external view returns (bool);
}

/// @notice Subset of CCIP `RegistryModuleOwnerCustom`.
interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(address token) external;
}

/// @notice Subset of CCIP `TokenAdminRegistry`.
interface ITokenAdminRegistry {
    function acceptAdminRole(address localToken) external;
    function setPool(address localToken, address pool) external;
    function getPool(address localToken) external view returns (address);
}
