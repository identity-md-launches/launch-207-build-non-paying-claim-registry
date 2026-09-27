// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ClaimRegistry} from "../src/ClaimRegistry.sol";

/// @title Deploy
/// @notice Deploys `ClaimRegistry` with an immutable Merkle root. Reads no keys and no RPC secrets:
/// the operator supplies the signer and RPC on the command line (see README.md, "Deployment").
///
/// Environment:
///  - `EXPECTED_CHAIN_ID` (uint, optional): 11155111 (Sepolia) or 31337 (local). `0` or unset means a
///    local dry-run and is checked against 31337. Any other value reverts before anything is deployed.
///  - `MERKLE_ROOT` (bytes32, optional): the allow-list root. Defaults to `DEMO_ROOT`, the root of the
///    258-leaf demo tree in `docs/demo/leaves.json`. A zero root is refused by this script.
contract Deploy is Script {
    /// @notice Root of the documented demo tree (`docs/demo/leaves.json`, 258 leaves, indices 0..257).
    /// Reproduce with `node script/merkle.mjs root docs/demo/leaves.json` or `forge test --match-test DemoRoot`.
    bytes32 public constant DEMO_ROOT = 0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3;

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant LOCAL_CHAIN_ID = 31_337;

    struct Config {
        uint256 expectedChainId;
        bytes32 merkleRoot;
    }

    error UnsupportedChain(uint256 expected);
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error EmptyRoot();

    /// @notice Entry point for `forge script`. Reads the environment, then deploys exactly one contract.
    function run() external returns (ClaimRegistry registry) {
        Config memory cfg = configFromEnv();
        checkChain(cfg.expectedChainId, block.chainid);
        if (cfg.merkleRoot == bytes32(0)) revert EmptyRoot();

        vm.startBroadcast();
        registry = new ClaimRegistry(cfg.merkleRoot);
        vm.stopBroadcast();

        console2.log("ClaimRegistry deployed at", address(registry));
        console2.log("chain id", block.chainid);
        console2.log("constructor arg merkleRoot_ (bytes32):");
        console2.logBytes32(cfg.merkleRoot);
    }

    /// @notice Builds the configuration from the environment. Tests never call this; they pass a `Config`.
    function configFromEnv() public view returns (Config memory cfg) {
        cfg.expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        cfg.merkleRoot = vm.envOr("MERKLE_ROOT", DEMO_ROOT);
    }

    /// @notice Deploys without broadcasting; used by the test-suite to exercise the same code path.
    function deployRegistry(Config memory cfg) public returns (ClaimRegistry registry) {
        checkChain(cfg.expectedChainId, block.chainid);
        if (cfg.merkleRoot == bytes32(0)) revert EmptyRoot();
        registry = new ClaimRegistry(cfg.merkleRoot);
    }

    /// @notice `expected` must be 0 (dry-run, treated as local), 31337 or 11155111, and must equal `actual`.
    function checkChain(uint256 expected, uint256 actual) public pure {
        if (expected == 0) expected = LOCAL_CHAIN_ID;
        if (expected != LOCAL_CHAIN_ID && expected != SEPOLIA_CHAIN_ID) revert UnsupportedChain(expected);
        if (actual != expected) revert ChainIdMismatch(expected, actual);
    }
}
