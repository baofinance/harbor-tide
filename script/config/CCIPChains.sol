// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title CCIPChains
/// @notice Per-network Chainlink CCIP configuration for the chains Harbor Tide targets:
///         Ethereum mainnet (home), Arbitrum One, Base, MegaETH.
/// @dev Addresses and selectors come from the Chainlink CCIP mainnet directory
///      (https://docs.chain.link/ccip/directory/mainnet). Verify before any production deploy.
library CCIPChains {
    error UnsupportedChain(uint256 chainId);

    struct Config {
        uint64 chainSelector; // CCIP chain selector
        address router; // CCIP Router
        address rmnProxy; // RMN (Risk Management Network) proxy
        address tokenAdminRegistry; // TokenAdminRegistry
        address registryModuleOwnerCustom; // RegistryModuleOwnerCustom (admin registration)
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant ARBITRUM = 42161;
    uint256 internal constant BASE = 8453;
    uint256 internal constant MEGAETH = 4326;

    function configFor(uint256 chainId) internal pure returns (Config memory) {
        if (chainId == ETHEREUM) {
            return Config({
                chainSelector: 5009297550715157269,
                router: 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D,
                rmnProxy: 0x411dE17f12D1A34ecC7F45f49844626267c75e81,
                tokenAdminRegistry: 0xb22764f98dD05c789929716D677382Df22C05Cb6,
                registryModuleOwnerCustom: 0x4855174E9479E211337832E109E7721d43A4CA64
            });
        }
        if (chainId == ARBITRUM) {
            return Config({
                chainSelector: 4949039107694359620,
                router: 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8,
                rmnProxy: 0xC311a21e6fEf769344EB1515588B9d535662a145,
                tokenAdminRegistry: 0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E,
                registryModuleOwnerCustom: 0x1f1df9f7fc939E71819F766978d8F900B816761b
            });
        }
        if (chainId == BASE) {
            return Config({
                chainSelector: 15971525489660198786,
                router: 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD,
                rmnProxy: 0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8,
                tokenAdminRegistry: 0x6f6C373d09C07425BaAE72317863d7F6bb731e37,
                registryModuleOwnerCustom: 0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f
            });
        }
        if (chainId == MEGAETH) {
            return Config({
                chainSelector: 6093540873831549674,
                router: 0xfa546248C54939AA6C48279CdC1EAf9A1125c411,
                rmnProxy: 0xA27056438FfA1f286AB197488808692F0db93F8B,
                tokenAdminRegistry: 0xf4a170A36D4C656F614d44453f73308Bdb275196,
                registryModuleOwnerCustom: 0x1E11bAB3f07fa72312182fFDc460AE45400E6e7b
            });
        }
        revert UnsupportedChain(chainId);
    }
}
