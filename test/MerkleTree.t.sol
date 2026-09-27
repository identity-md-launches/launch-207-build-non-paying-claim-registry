// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleTree} from "./utils/MerkleTree.sol";
import {MerkleProofLib} from "../src/MerkleProofLib.sol";

/// @notice Tests of the test-side proof builder itself, so the registry tests stand on a verified tool.
contract MerkleTreeTest is Test {
    function test_singleLeafRootIsLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("only");
        assertEq(MerkleTree.root(leaves), leaves[0]);
        assertEq(MerkleTree.proof(leaves, 0).length, 0);
    }

    function test_twoLeavesSortedPair() public pure {
        bytes32 a = bytes32(uint256(1));
        bytes32 b = bytes32(uint256(2));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = b; // deliberately unsorted in position
        leaves[1] = a;
        bytes32 expected = keccak256(abi.encodePacked(a, b)); // min || max regardless of position
        assertEq(MerkleTree.root(leaves), expected);
        assertEq(MerkleTree.proof(leaves, 0)[0], a);
        assertEq(MerkleTree.proof(leaves, 1)[0], b);
    }

    function test_threeLeavesCarryUpOddNode() public pure {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = keccak256("a");
        leaves[1] = keccak256("b");
        leaves[2] = keccak256("c");
        bytes32 ab = MerkleTree.hashPair(leaves[0], leaves[1]);
        bytes32 expected = MerkleTree.hashPair(ab, leaves[2]);
        assertEq(MerkleTree.root(leaves), expected);

        bytes32[] memory p2 = MerkleTree.proof(leaves, 2);
        assertEq(p2.length, 1, "carried-up node has no sibling at level 0");
        assertEq(p2[0], ab);

        bytes32[] memory p0 = MerkleTree.proof(leaves, 0);
        assertEq(p0.length, 2);
        assertEq(p0[0], leaves[1]);
        assertEq(p0[1], leaves[2]);
    }

    /// @dev Fixed vector cross-checked with `node script/merkle.mjs leaf 257 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD 258000000000000000000`
    /// and with `cast keccak $(cast keccak $(cast abi-encode 'f(uint256,address,uint256)' 257 0x5dA3… 258000000000000000000))`.
    function test_leafFixedVector() public pure {
        assertEq(
            MerkleTree.leaf(257, 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD, 258e18),
            0x3617563e5304be75935bc9e1119f84a46dea140bf2c87c345acdbbdb6113dc8d
        );
    }

    function test_hashPairMatchesLibrary() public pure {
        bytes32 a = keccak256("x");
        bytes32 b = keccak256("y");
        assertEq(MerkleTree.hashPair(a, b), MerkleProofLib.hashPair(a, b));
        assertEq(MerkleTree.hashPair(b, a), MerkleProofLib.hashPair(a, b));
    }

    function testFuzz_everyProofReproducesRoot(bytes32 seed, uint16 nRaw) public pure {
        uint256 n = bound(uint256(nRaw), 1, 300);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(seed, i));
        }
        bytes32 root = MerkleTree.root(leaves);
        // Check a spread of positions rather than all 300 to keep the fuzz run fast.
        uint256[5] memory picks = [uint256(0), n / 3, n / 2, n > 1 ? n - 2 : 0, n - 1];
        for (uint256 k = 0; k < picks.length; ++k) {
            uint256 pos = picks[k] % n;
            bytes32[] memory p = MerkleTree.proof(leaves, pos);
            assertEq(MerkleTree.processProof(p, leaves[pos]), root);
            if (n > 1) {
                bytes32 other = leaves[(pos + 1) % n];
                assertTrue(MerkleTree.processProof(p, other) != root, "proof verified a different leaf");
            }
        }
    }

    function test_proofRejectsOutOfRangePosition() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("a");
        leaves[1] = keccak256("b");
        vm.expectRevert(bytes("MerkleTree: position out of range"));
        this.proofExternal(leaves, 2);
    }

    function proofExternal(bytes32[] memory leaves, uint256 pos) external pure returns (bytes32[] memory) {
        return MerkleTree.proof(leaves, pos);
    }
}
