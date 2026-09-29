// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";
import {CCIPChains} from "@tide-script/config/CCIPChains.sol";
import {
    ITokenPool,
    ITokenAdminRegistry,
    IRegistryModuleOwnerCustom,
    ChainUpdate,
    RateLimiterConfig
} from "@tide-script/ccip/ICCIP.sol";

/// @notice End-to-end fork test against the *real* Chainlink CCIP contracts, parametrized over every
///         target chain (Ethereum, Arbitrum, Base, MegaETH, Robinhood). For each chain it mirrors
///         `Deploy.s.sol` + `Configure_CCIP.s.sol`: deploys the token (home mints 1bn, remotes mint 0),
///         the governance timelock (home only), and the BurnMintTokenPool; then registers the token
///         admin via `getCCIPAdmin`, sets the pool, and wires lanes to the other target chains.
/// @dev Each chain's test skips when its RPC env var is unset, so the suite stays green locally.
///      Exercising each chain's live TokenAdminRegistry / RegistryModuleOwnerCustom directly is stronger
///      than inferring compatibility from `typeAndVersion`.
contract CCIPForkTest is Test {
    uint256 internal constant TIMELOCK_MIN_DELAY = 24 hours;

    address internal multisig = makeAddr("multisig");

    function test_fork_wiring_ethereum() public {
        _runChainWiring(CCIPChains.ETHEREUM, "MAINNET_RPC_URL");
    }

    function test_fork_wiring_arbitrum() public {
        _runChainWiring(CCIPChains.ARBITRUM, "ARBITRUM_RPC_URL");
    }

    function test_fork_wiring_base() public {
        _runChainWiring(CCIPChains.BASE, "BASE_RPC_URL");
    }

    function test_fork_wiring_megaeth() public {
        _runChainWiring(CCIPChains.MEGAETH, "MEGAETH_RPC_URL");
    }

    function test_fork_wiring_robinhood() public {
        _runChainWiring(CCIPChains.ROBINHOOD, "ROBINHOOD_RPC_URL");
    }

    /// @notice Deploy + wire the full Harbor Tide CCIP stack on one chain's fork.
    function _runChainWiring(uint256 chainId, string memory rpcEnv) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == chainId, "fork chainId != expected");

        bool isHome = chainId == CCIPChains.ETHEREUM;
        CCIPChains.Config memory cfg = CCIPChains.configFor(chainId);

        // --- Initial supply: home mints the full 1bn to the multisig; remotes mint nothing. -------
        uint256 cap = HarborTideToken_v1(address(new HarborTideToken_v1())).MAX_SUPPLY();
        uint256 initialMint = isHome ? cap : 0;
        HarborTideToken_v1 token = _deployToken(multisig, initialMint);
        assertEq(token.totalSupply(), initialMint, "unexpected initial supply");
        assertEq(token.balanceOf(multisig), initialMint, "unexpected multisig balance");
        console.log("[chain %s] initial supply %s TIDE", chainId, token.totalSupply() / 1e18);

        // --- Governance: TimelockController holds MINTER_ROLE (home chain only). -------------------
        if (isHome) {
            address[] memory controllers = new address[](1);
            controllers[0] = multisig;
            TimelockController timelock =
                new TimelockController(TIMELOCK_MIN_DELAY, controllers, controllers, multisig);
            token.grantRoles(address(timelock), token.MINTER_ROLE());
            assertTrue(token.hasAllRoles(address(timelock), token.MINTER_ROLE()), "timelock missing MINTER_ROLE");
            console.log("  timelock %s holds MINTER_ROLE", address(timelock));
        }

        // --- CCIP pool (immutable) bound to the token. --------------------------------------------
        address[] memory allowlist = new address[](0);
        address pool = vm.deployCode(
            "out/BurnMintTokenPool.sol/BurnMintTokenPool.json",
            abi.encode(address(token), allowlist, cfg.rmnProxy, cfg.router)
        );
        assertEq(ITokenPool(pool).getToken(), address(token), "pool token mismatch");
        assertEq(ITokenPool(pool).getRouter(), cfg.router, "pool router mismatch");
        assertEq(ITokenPool(pool).getRmnProxy(), cfg.rmnProxy, "pool rmn mismatch");
        token.grantRoles(pool, token.CCIP_MINTER_ROLE() | token.BURNER_ROLE());

        // --- Register admin (= getCCIPAdmin = this test) and bind the pool in the live registry. --
        IRegistryModuleOwnerCustom(cfg.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).setPool(address(token), pool);
        assertEq(ITokenAdminRegistry(cfg.tokenAdminRegistry).getPool(address(token)), pool, "pool not registered");
        console.log("  pool %s registered in live TokenAdminRegistry", pool);

        // --- Wire lanes to the other target chains. -----------------------------------------------
        uint256[5] memory all = [
            CCIPChains.ETHEREUM,
            CCIPChains.ARBITRUM,
            CCIPChains.BASE,
            CCIPChains.MEGAETH,
            CCIPChains.ROBINHOOD
        ];
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] == chainId) continue;
            CCIPChains.Config memory remote = CCIPChains.configFor(all[i]);
            ChainUpdate[] memory updates = new ChainUpdate[](1);
            updates[0] = ChainUpdate({
                remoteChainSelector: remote.chainSelector,
                allowed: true,
                remotePoolAddress: abi.encode(makeAddr("remotePool")),
                remoteTokenAddress: abi.encode(address(token)),
                outboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0}),
                inboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0})
            });
            ITokenPool(pool).applyChainUpdates(updates);
            assertTrue(ITokenPool(pool).isSupportedChain(remote.chainSelector), "lane not supported");
            console.log("  lane wired -> chainId %s selector %s", all[i], remote.chainSelector);
        }
    }

    function _deployToken(address mintTo, uint256 mintAmount) internal returns (HarborTideToken_v1) {
        address impl = address(new HarborTideToken_v1());
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (address(this), address(this), "Harbor Tide", "TIDE", mintTo, mintAmount)
        );
        return HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));
    }
}
