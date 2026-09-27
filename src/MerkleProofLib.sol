// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MerkleProofLib
/// @notice Minimal, dependency-free Merkle proof verification with sorted-pair hashing.
/// @dev Semantics match the widely used "sorted pairs" convention: at every level the two
/// children are ordered numerically before hashing, so a proof carries no position bits.
/// Leaves are expected to be *double hashed* by the caller (see `ClaimRegistry.leafOf`), which
/// keeps a 64-byte internal node preimage from ever colliding with a leaf preimage.
library MerkleProofLib {
    /// @notice Returns true when `proof` connects `leaf` to `root`.
    /// @param proof Sibling hashes ordered from the leaf's level up to the root's children.
    /// @param root The expected Merkle root.
    /// @param leaf The (already hashed) leaf value.
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /// @notice Folds `leaf` up through `proof` and returns the resulting root candidate.
    function processProof(bytes32[] calldata proof, bytes32 leaf) internal pure returns (bytes32 computed) {
        computed = leaf;
        uint256 length = proof.length;
        for (uint256 i = 0; i < length; ++i) {
            computed = hashPair(computed, proof[i]);
        }
    }

    /// @notice Hashes two nodes in numeric order: `keccak256(min || max)`.
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
