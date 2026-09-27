// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProofLib} from "./MerkleProofLib.sol";

/// @title ClaimRegistry
/// @notice A non-paying Merkle claim registry. It records that an allow-listed account has claimed
/// its slot and the amount that slot carried, and moves no funds of any kind.
/// @dev Design summary (see README.md for the full specification):
///  - The Merkle root is immutable and set once in the constructor. There is no owner, no pause,
///    no upgrade path, and no way to change or extend the allow list after deployment.
///  - A leaf is `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`.
///    Sibling pairs are sorted numerically before hashing (`MerkleProofLib.hashPair`).
///  - Only the account bound in the leaf can consume its index: `account` is always `msg.sender`.
///  - A claim either fully succeeds (index marked, amount recorded, event emitted) or reverts with
///    no state change. A failed proof therefore never consumes the claim.
///  - Claimed indices live in a packed bitmap; indices 255/256/257 straddle a word boundary.
contract ClaimRegistry {
    /// @notice Emitted once per successful claim.
    event Claimed(uint256 indexed index, address indexed account, uint256 amount);

    /// @notice The index was already consumed.
    error AlreadyClaimed(uint256 index);
    /// @notice `(index, msg.sender, amount)` is not a leaf of the tree under `merkleRoot`, or the proof is malformed.
    error InvalidProof();

    /// @notice The immutable root of the allow-list Merkle tree.
    bytes32 public immutable merkleRoot;

    /// @dev Bit `index % 256` of word `index / 256` is set once `index` has been claimed.
    mapping(uint256 => uint256) private _claimedBitMap;

    /// @notice The amount recorded for a claimed index (zero until claimed, and zero for a zero-amount leaf;
    /// use `isClaimed` to distinguish).
    mapping(uint256 => uint256) public claimedAmount;

    /// @notice The account that consumed an index (zero address until claimed).
    mapping(uint256 => address) public claimedBy;

    /// @notice Running total of amounts recorded for an account across all of its claimed indices.
    mapping(address => uint256) public totalClaimedOf;

    /// @notice Number of successful claims so far.
    uint256 public claimCount;

    /// @param merkleRoot_ Root of the allow-list tree. A zero root is accepted and yields a registry
    /// on which no claim can ever succeed (documented as a deliberate "empty" deployment).
    constructor(bytes32 merkleRoot_) {
        merkleRoot = merkleRoot_;
    }

    /// @notice Marks `index` as claimed by the caller and records `amount`. Moves no funds.
    /// @dev Reverts with `AlreadyClaimed` before looking at the proof, and with `InvalidProof` when the
    /// leaf `(index, msg.sender, amount)` does not verify. Both reverts leave storage untouched.
    /// @param index The leaf index being consumed.
    /// @param amount The amount bound to the leaf; recorded verbatim.
    /// @param proof Sibling hashes from the leaf upward (sorted-pair convention, no position bits).
    function claim(uint256 index, uint256 amount, bytes32[] calldata proof) external {
        if (isClaimed(index)) revert AlreadyClaimed(index);
        if (!MerkleProofLib.verify(proof, merkleRoot, leafOf(index, msg.sender, amount))) revert InvalidProof();

        _setClaimed(index);
        claimedAmount[index] = amount;
        claimedBy[index] = msg.sender;
        totalClaimedOf[msg.sender] += amount;
        unchecked {
            // Bounded by the number of distinct indices; cannot realistically overflow.
            ++claimCount;
        }

        emit Claimed(index, msg.sender, amount);
    }

    /// @notice True once `index` has been consumed.
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 word = _claimedBitMap[index >> 8];
        uint256 mask = uint256(1) << (index & 0xff);
        return word & mask == mask;
    }

    /// @notice Pure view of whether `(index, account, amount, proof)` would verify against the root.
    /// @dev Does not consult the claimed bitmap; combine with `isClaimed` for a full precheck.
    function verifyProof(uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return MerkleProofLib.verify(proof, merkleRoot, leafOf(index, account, amount));
    }

    /// @notice The double-hashed leaf for `(index, account, amount)`.
    /// @dev `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`. The inner
    /// `abi.encode` is the 96-byte head-only ABI encoding of `(uint256, address, uint256)`.
    function leafOf(uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _setClaimed(uint256 index) private {
        _claimedBitMap[index >> 8] |= uint256(1) << (index & 0xff);
    }
}
