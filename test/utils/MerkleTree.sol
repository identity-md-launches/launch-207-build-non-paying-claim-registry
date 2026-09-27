// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MerkleTree (test-side proof builder)
/// @notice A dependency-free, pure-Solidity Merkle tree builder used by the test-suite to produce
/// roots and proofs for arbitrary leaf sets. It is the reference implementation of the tree shape
/// the registry expects; `script/merkle.mjs` implements the identical algorithm in JavaScript so the
/// two can be cross-checked against each other and against the fixed vectors in `docs/demo/`.
///
/// Tree shape:
///  - Level 0 is the list of leaf hashes in index order (leaf `i` sits at position `i`).
///  - Each higher level pairs positions `(2k, 2k+1)` and stores `hashPair(a, b)` with the pair
///    sorted numerically before hashing.
///  - When a level has an odd number of nodes the last node is *carried up unchanged* (it is not
///    duplicated). A proof for that node therefore contains no sibling at that level.
///  - A single-leaf tree has the leaf as its root and an empty proof.
library MerkleTree {
    /// @dev Same leaf definition as `ClaimRegistry.leafOf`.
    function leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice Computes the root over `leaves` (must be non-empty).
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "MerkleTree: empty");
        bytes32[] memory level = _copy(leaves);
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    /// @notice Builds the proof for the leaf at `position` in `leaves`.
    function proof(bytes32[] memory leaves, uint256 position) internal pure returns (bytes32[] memory out) {
        require(leaves.length > 0, "MerkleTree: empty");
        require(position < leaves.length, "MerkleTree: position out of range");

        // Upper bound on depth: ceil(log2(n)); collect then trim.
        bytes32[] memory buffer = new bytes32[](256);
        uint256 count;

        bytes32[] memory level = _copy(leaves);
        uint256 pos = position;
        while (level.length > 1) {
            uint256 sibling = pos ^ 1;
            if (sibling < level.length) {
                buffer[count++] = level[sibling];
            }
            level = _nextLevel(level);
            pos >>= 1;
        }

        out = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = buffer[i];
        }
    }

    /// @notice Folds a leaf through a proof exactly as the registry does; handy for expected-value checks.
    function processProof(bytes32[] memory p, bytes32 l) internal pure returns (bytes32 computed) {
        computed = l;
        for (uint256 i = 0; i < p.length; ++i) {
            computed = hashPair(computed, p[i]);
        }
    }

    function _nextLevel(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        uint256 n = level.length;
        next = new bytes32[]((n + 1) / 2);
        for (uint256 i = 0; i < n / 2; ++i) {
            next[i] = hashPair(level[2 * i], level[2 * i + 1]);
        }
        if (n % 2 == 1) {
            next[n / 2] = level[n - 1];
        }
    }

    function _copy(bytes32[] memory a) private pure returns (bytes32[] memory b) {
        b = new bytes32[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            b[i] = a[i];
        }
    }
}
