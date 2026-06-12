// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";
import {CCIPChains} from "@tide-script/config/CCIPChains.sol";
import {ITokenPool} from "@tide-script/ccip/ICCIP.sol";

/// @notice Simulates a `mainnet -> base -> mainnet` CCIP round trip at the token (burn/mint) boundary.
/// @dev A full CCIP message can't run in Foundry (it needs the off-chain DON/executor to relay), and
///      driving the pool's `lockOrBurn`/`releaseOrMint` directly would mean pranking the live on/off
///      ramps + satisfying RMN curse/rate-limit checks (brittle: breaks when Chainlink rotates a ramp).
///      Instead this reproduces exactly what a `BurnMintTokenPool` does to *our* token:
///        - source send: tokens land on the pool, then `pool.lockOrBurn` calls `token.burn(amount)`,
///        - dest receive: `pool.releaseOrMint` calls `token.mint(receiver, amount)`.
///      We prank as the deployed pool (which holds `BURNER_ROLE | CCIP_MINTER_ROLE`) on each fork. This
///      proves the invariant that matters for the token: global supply is conserved across the round
///      trip and the per-chain cap is respected, without depending on live ramp addresses.
contract CCIPRoundTripForkTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal user = makeAddr("user");

    uint256 internal mainnetFork;
    uint256 internal baseFork;

    HarborTideToken_v1 internal mainnetToken;
    HarborTideToken_v1 internal baseToken;
    address internal mainnetPool;
    address internal basePool;

    function test_fork_roundTrip_mainnet_base_mainnet() public {
        string memory mainnetRpc = vm.envOr("MAINNET_RPC_URL", string(""));
        string memory baseRpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(mainnetRpc).length == 0 || bytes(baseRpc).length == 0) {
            vm.skip(true);
            return;
        }

        uint256 cap = HarborTideToken_v1(address(new HarborTideToken_v1())).MAX_SUPPLY();
        uint256 amount = 250_000_000e18; // bridge a quarter of supply mainnet -> base and back

        // --- Deploy token + pool on each chain's fork (home mints 1bn, base mints 0). --------------
        mainnetFork = vm.createSelectFork(mainnetRpc);
        require(block.chainid == CCIPChains.ETHEREUM, "mainnet fork chainId");
        (mainnetToken, mainnetPool) = _deploy(CCIPChains.ETHEREUM, multisig, cap);

        baseFork = vm.createSelectFork(baseRpc);
        require(block.chainid == CCIPChains.BASE, "base fork chainId");
        (baseToken, basePool) = _deploy(CCIPChains.BASE, multisig, 0);

        _logGlobal("initial", cap);
        assertEq(_globalSupply(), cap, "initial global supply != cap");

        // ============================ Leg 1: mainnet -> base ======================================
        // Source (lockOrBurn): tokens are moved onto the pool, then the pool burns them.
        vm.selectFork(mainnetFork);
        vm.prank(multisig);
        mainnetToken.transfer(mainnetPool, amount);
        vm.prank(mainnetPool);
        mainnetToken.burn(amount);
        assertEq(mainnetToken.totalSupply(), cap - amount, "mainnet supply after burn");
        console.log("[leg1] burned %s TIDE on mainnet -> supply %s", amount / 1e18, mainnetToken.totalSupply() / 1e18);

        // Dest (releaseOrMint): the base pool mints the same amount to the user.
        vm.selectFork(baseFork);
        vm.prank(basePool);
        baseToken.mint(user, amount);
        assertEq(baseToken.totalSupply(), amount, "base supply after mint");
        assertEq(baseToken.balanceOf(user), amount, "user base balance");
        console.log("[leg1] minted %s TIDE on base -> user balance %s", amount / 1e18, baseToken.balanceOf(user) / 1e18);

        _logGlobal("after leg1", cap);
        assertEq(_globalSupply(), cap, "global supply changed across leg1");

        // ============================ Leg 2: base -> mainnet ======================================
        vm.selectFork(baseFork);
        vm.prank(user);
        baseToken.transfer(basePool, amount);
        vm.prank(basePool);
        baseToken.burn(amount);
        assertEq(baseToken.totalSupply(), 0, "base supply after burn back");
        console.log("[leg2] burned %s TIDE on base -> supply %s", amount / 1e18, baseToken.totalSupply() / 1e18);

        vm.selectFork(mainnetFork);
        vm.prank(mainnetPool);
        mainnetToken.mint(multisig, amount);
        assertEq(mainnetToken.totalSupply(), cap, "mainnet supply restored");
        assertEq(mainnetToken.balanceOf(multisig), cap, "multisig balance restored");
        console.log("[leg2] minted %s TIDE on mainnet -> supply %s", amount / 1e18, mainnetToken.totalSupply() / 1e18);

        _logGlobal("final", cap);
        assertEq(_globalSupply(), cap, "final global supply != cap");
    }

    /// @notice Deploy the token (UUPS proxy) + a real BurnMintTokenPool, and grant the pool its CCIP roles.
    function _deploy(uint256 chainId, address mintTo, uint256 mintAmount)
        internal
        returns (HarborTideToken_v1 token, address pool)
    {
        CCIPChains.Config memory cfg = CCIPChains.configFor(chainId);

        address impl = address(new HarborTideToken_v1());
        bytes memory initData =
            abi.encodeCall(HarborTideToken_v1.initialize, (address(this), "Harbor Tide", "TIDE", mintTo, mintAmount));
        token = HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));

        address[] memory allowlist = new address[](0);
        pool = vm.deployCode(
            "out/BurnMintTokenPool.sol/BurnMintTokenPool.json",
            abi.encode(address(token), allowlist, cfg.rmnProxy, cfg.router)
        );
        assertEq(ITokenPool(pool).getToken(), address(token), "pool token mismatch");
        token.grantRoles(pool, token.CCIP_MINTER_ROLE() | token.BURNER_ROLE());
    }

    /// @notice Sum of supply across both forks (selecting a fork is side-effect free for the caller's leg).
    function _globalSupply() internal returns (uint256 total) {
        uint256 active = vm.activeFork();
        vm.selectFork(mainnetFork);
        total = mainnetToken.totalSupply();
        vm.selectFork(baseFork);
        total += baseToken.totalSupply();
        vm.selectFork(active);
    }

    function _logGlobal(string memory label, uint256 cap) internal {
        uint256 active = vm.activeFork();
        vm.selectFork(mainnetFork);
        uint256 m = mainnetToken.totalSupply();
        vm.selectFork(baseFork);
        uint256 b = baseToken.totalSupply();
        vm.selectFork(active);
        console.log("[%s] mainnet %s TIDE", label, m / 1e18);
        console.log("[%s] base    %s TIDE", label, b / 1e18);
        console.log("[%s] global  %s TIDE (cap %s)", label, (m + b) / 1e18, cap / 1e18);
    }
}
