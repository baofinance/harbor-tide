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

/// @notice End-to-end fork test against the *real* Chainlink CCIP contracts on Ethereum mainnet,
///         mirroring `Deploy.s.sol`: mints the home-chain 1bn to the multisig, deploys the governance
///         TimelockController and grants it MINTER_ROLE, deploys the BurnMintTokenPool, registers the
///         token admin via `getCCIPAdmin`, sets the pool, and adds an Arbitrum lane.
///         Skips when MAINNET_RPC_URL is unset.
contract CCIPForkTest is Test {
    uint256 internal constant TIMELOCK_MIN_DELAY = 24 hours;

    HarborTideToken_v1 internal token;

    address internal multisig = makeAddr("multisig");

    function _deployToken(address mintTo, uint256 mintAmount) internal returns (HarborTideToken_v1) {
        address impl = address(new HarborTideToken_v1());
        bytes memory initData =
            abi.encodeCall(HarborTideToken_v1.initialize, (address(this), "Harbor Tide", "TIDE", mintTo, mintAmount));
        return HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));
    }

    function test_fork_poolWiringOnMainnet() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        CCIPChains.Config memory cfg = CCIPChains.configFor(CCIPChains.ETHEREUM);

        // --- Initial supply: home chain mints the full 1bn to the multisig ---------------------
        uint256 cap = HarborTideToken_v1(address(new HarborTideToken_v1())).MAX_SUPPLY();
        token = _deployToken(multisig, cap);
        assertEq(token.totalSupply(), cap);
        assertEq(token.balanceOf(multisig), cap);
        console.log("Initial TIDE minted: %s wei", token.totalSupply());
        console.log("Initial TIDE minted: %s TIDE to multisig %s", token.totalSupply() / 1e18, multisig);

        // --- Governance: TimelockController holds MINTER_ROLE, multisig operates it -------------
        address[] memory controllers = new address[](1);
        controllers[0] = multisig;
        TimelockController timelock = new TimelockController(TIMELOCK_MIN_DELAY, controllers, controllers, multisig);
        token.grantRoles(address(timelock), token.MINTER_ROLE());
        assertTrue(token.hasAllRoles(address(timelock), token.MINTER_ROLE()));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), multisig));
        console.log("Timelock %s holds MINTER_ROLE (minDelay %s s)", address(timelock), TIMELOCK_MIN_DELAY);
        console.log("  multisig %s is proposer/executor of the timelock", multisig);

        // --- CCIP pool (immutable) bound to the token ------------------------------------------
        address[] memory allowlist = new address[](0);
        address pool = vm.deployCode(
            "out/BurnMintTokenPool.sol/BurnMintTokenPool.json",
            abi.encode(address(token), allowlist, cfg.rmnProxy, cfg.router)
        );
        assertEq(ITokenPool(pool).getToken(), address(token));
        assertEq(ITokenPool(pool).getRouter(), cfg.router);
        assertEq(ITokenPool(pool).getRmnProxy(), cfg.rmnProxy);

        // The pool needs mint/burn rights on the token.
        token.grantRoles(pool, token.CCIP_MINTER_ROLE() | token.BURNER_ROLE());

        // Register the token admin (= getCCIPAdmin() = this test) and bind the pool in the registry.
        IRegistryModuleOwnerCustom(cfg.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).setPool(address(token), pool);
        assertEq(ITokenAdminRegistry(cfg.tokenAdminRegistry).getPool(address(token)), pool);
        console.log("Pool %s registered in TokenAdminRegistry", pool);

        // Add an Arbitrum lane (token address is identical cross-chain via CREATE3; pool is per-chain).
        CCIPChains.Config memory arb = CCIPChains.configFor(CCIPChains.ARBITRUM);
        ChainUpdate[] memory updates = new ChainUpdate[](1);
        updates[0] = ChainUpdate({
            remoteChainSelector: arb.chainSelector,
            allowed: true,
            remotePoolAddress: abi.encode(makeAddr("arbPool")),
            remoteTokenAddress: abi.encode(address(token)),
            outboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0})
        });
        ITokenPool(pool).applyChainUpdates(updates);
        assertTrue(ITokenPool(pool).isSupportedChain(arb.chainSelector));
        console.log("Arbitrum lane wired (selector %s)", arb.chainSelector);
    }
}
