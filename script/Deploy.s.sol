// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";

/// @notice Deploys one KeyValueRegistry. Reads no keys and no RPC secrets: the only input is the
///         EXPECTED_CHAIN_ID environment variable, which must name the chain the operator intends
///         to broadcast to. The signer and RPC endpoint are supplied by the operator on the command
///         line, never by this script.
///
/// @dev `run()` reads the environment and hands a config to `deploy`, which tests call directly.
///      EXPECTED_CHAIN_ID=0 is the offline dry-run convention: it is treated as the local anvil
///      chain (31337), which is what `forge script --offline` simulates against.
contract Deploy is Script {
    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;

    struct Config {
        uint256 expectedChainId;
    }

    error UnsupportedChainId(uint256 chainId);
    error ChainIdMismatch(uint256 actual, uint256 expected);

    function run() external returns (KeyValueRegistry registry) {
        Config memory cfg = Config({expectedChainId: vm.envUint("EXPECTED_CHAIN_ID")});
        registry = deploy(cfg);
    }

    function deploy(Config memory cfg) public returns (KeyValueRegistry registry) {
        uint256 expected = cfg.expectedChainId == 0 ? ANVIL_CHAIN_ID : cfg.expectedChainId;
        if (expected != ANVIL_CHAIN_ID && expected != SEPOLIA_CHAIN_ID) revert UnsupportedChainId(expected);
        if (block.chainid != expected) revert ChainIdMismatch(block.chainid, expected);

        vm.startBroadcast();
        registry = new KeyValueRegistry();
        vm.stopBroadcast();
    }
}
