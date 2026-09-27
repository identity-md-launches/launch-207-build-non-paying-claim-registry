// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleTree} from "./MerkleTree.sol";

/// @notice The documented demo parameters, derived in Solidity so the tests do not read any file.
/// Must stay in lock-step with `docs/demo/leaves.json`, which was produced by:
///   pk_i      = keccak256(abi.encode("imd-claim-demo", i))        (cast keccak $(cast abi-encode 'f(string,uint256)' imd-claim-demo i))
///   account_i = address(pk_i)                                      (cast wallet address --private-key pk_i)
///   amount_i  = (i + 1) * 1e18
/// for i in 0..257 (258 leaves). These keys are public demo keys and hold nothing of value.
abstract contract DemoFixture is Test {
    uint256 internal constant DEMO_LEAF_COUNT = 258;

    /// @dev Expected root, computed independently by `script/merkle.mjs` over `docs/demo/leaves.json`.
    bytes32 internal constant DEMO_ROOT_FROM_JS = 0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3;

    bytes32[] internal demoLeaves;
    address[] internal demoAccounts;
    uint256[] internal demoAmounts;
    uint256[] internal demoKeys;

    function _buildDemo() internal {
        for (uint256 i = 0; i < DEMO_LEAF_COUNT; ++i) {
            uint256 pk = demoPrivateKey(i);
            address account = vm.addr(pk);
            uint256 amount = demoAmount(i);
            demoKeys.push(pk);
            demoAccounts.push(account);
            demoAmounts.push(amount);
            demoLeaves.push(MerkleTree.leaf(i, account, amount));
        }
    }

    function demoPrivateKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("imd-claim-demo", i)));
    }

    function demoAmount(uint256 i) internal pure returns (uint256) {
        return (i + 1) * 1e18;
    }

    function demoProof(uint256 i) internal view returns (bytes32[] memory) {
        return MerkleTree.proof(demoLeaves, i);
    }
}
