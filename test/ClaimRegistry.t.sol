// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimRegistry} from "../src/ClaimRegistry.sol";
import {MerkleTree} from "./utils/MerkleTree.sol";
import {DemoFixture} from "./utils/DemoFixture.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract ClaimRegistryTest is DemoFixture {
    ClaimRegistry internal registry;
    bytes32 internal root;

    function setUp() public {
        _buildDemo();
        root = MerkleTree.root(demoLeaves);
        registry = new ClaimRegistry(root);
    }

    // ------------------------------------------------------------------------------------------
    // Construction and fixed vectors
    // ------------------------------------------------------------------------------------------

    function test_constructorSetsImmutableRoot() public view {
        assertEq(registry.merkleRoot(), root);
        assertEq(registry.claimCount(), 0);
    }

    /// @dev Three independent derivations of the same root: the Solidity builder over vm.addr-derived
    /// accounts, the JavaScript builder over docs/demo/leaves.json, and the constant the deploy script ships.
    function test_DemoRootMatchesJavaScriptAndDeployScript() public {
        assertEq(root, DEMO_ROOT_FROM_JS, "solidity builder disagrees with script/merkle.mjs");
        assertEq(root, new Deploy().DEMO_ROOT(), "deploy script ships a different root");
    }

    /// @dev Fixed vector for index 257 taken from `node script/merkle.mjs proof docs/demo/leaves.json 257`.
    function test_FixedVector_index257() public view {
        assertEq(demoAccounts[257], 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD);
        assertEq(demoAmounts[257], 258e18);
        assertEq(demoLeaves[257], 0x3617563e5304be75935bc9e1119f84a46dea140bf2c87c345acdbbdb6113dc8d);
        bytes32[] memory p = demoProof(257);
        assertEq(p.length, 2, "index 257 rides the carry-up path and has a 2-element proof");
        assertEq(p[0], 0xf56f8c97697ce73fd6043e423c06d40ef8af405fa426fb8f781d98c46547dfe3);
        assertEq(p[1], 0x9dbf82f9854475b50756efc2127257cf30675116a84725f41b4992a7992bc62e);
    }

    function test_leafOfMatchesSpecification() public view {
        uint256 index = 42;
        address account = address(0xA11CE);
        uint256 amount = 7e18;
        bytes32 expected = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        assertEq(registry.leafOf(index, account, amount), expected);
        assertEq(MerkleTree.leaf(index, account, amount), expected);
        // Sanity: the single hash is not accepted as the leaf (double hashing is part of the format).
        assertTrue(expected != keccak256(abi.encode(index, account, amount)));
    }

    // ------------------------------------------------------------------------------------------
    // Successful claims at the required indices
    // ------------------------------------------------------------------------------------------

    function test_claim_index0() public {
        _claimAndAssert(0);
    }

    function test_claim_index255() public {
        _claimAndAssert(255);
        assertFalse(registry.isClaimed(256), "bit 255 must not leak into the next word");
        assertFalse(registry.isClaimed(254));
    }

    function test_claim_index256() public {
        _claimAndAssert(256);
        assertFalse(registry.isClaimed(255), "bit 0 of word 1 must not leak into word 0");
        assertFalse(registry.isClaimed(257));
        assertFalse(registry.isClaimed(0), "index 0 and 256 share a bit position in different words");
    }

    function test_claim_index257() public {
        _claimAndAssert(257);
        assertFalse(registry.isClaimed(1));
        assertFalse(registry.isClaimed(256));
    }

    function test_claim_allBoundaryIndicesTogether() public {
        uint256[4] memory idx = [uint256(0), 255, 256, 257];
        for (uint256 i = 0; i < idx.length; ++i) {
            _claimAndAssert(idx[i]);
        }
        assertEq(registry.claimCount(), 4);
        for (uint256 i = 0; i < idx.length; ++i) {
            assertTrue(registry.isClaimed(idx[i]));
        }
        // Everything else is still unclaimed.
        for (uint256 i = 1; i < 255; ++i) {
            assertFalse(registry.isClaimed(i));
        }
    }

    function test_claim_emitsEvent() public {
        uint256 i = 7;
        bytes32[] memory p = demoProof(i);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ClaimRegistry.Claimed(i, demoAccounts[i], demoAmounts[i]);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], p);
    }

    function test_claim_movesNoValue() public {
        uint256 i = 3;
        vm.deal(demoAccounts[i], 1 ether);
        uint256 balBefore = demoAccounts[i].balance;
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], demoProof(i));
        assertEq(demoAccounts[i].balance, balBefore);
        assertEq(address(registry).balance, 0);
        // The registry has no receive/fallback: value transfers to it fail.
        (bool ok,) = address(registry).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------------------------------
    // Duplicate claims
    // ------------------------------------------------------------------------------------------

    function test_claim_duplicateReverts() public {
        uint256 i = 256;
        _claimAndAssert(i);
        bytes32[] memory p = demoProof(i);

        vm.expectRevert(abi.encodeWithSelector(ClaimRegistry.AlreadyClaimed.selector, i));
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], p);

        assertEq(registry.claimCount(), 1);
        assertEq(registry.claimedAmount(i), demoAmounts[i]);
        assertEq(registry.totalClaimedOf(demoAccounts[i]), demoAmounts[i], "duplicate must not double count");
    }

    function test_claim_duplicateRevertsEvenWithGarbageProof() public {
        uint256 i = 0;
        _claimAndAssert(i);
        bytes32[] memory garbage = new bytes32[](1);
        // AlreadyClaimed takes precedence over InvalidProof: the index is spent regardless of the proof.
        vm.expectRevert(abi.encodeWithSelector(ClaimRegistry.AlreadyClaimed.selector, i));
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], garbage);
    }

    // ------------------------------------------------------------------------------------------
    // Modified amount / account / index
    // ------------------------------------------------------------------------------------------

    function test_claim_modifiedAmountReverts() public {
        uint256 i = 255;
        bytes32[] memory p = demoProof(i);
        uint256[3] memory bad = [demoAmounts[i] + 1, demoAmounts[i] - 1, demoAmounts[i] * 2];
        for (uint256 k = 0; k < bad.length; ++k) {
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(i, bad[k], p);
        }
        _assertUnclaimed(i);
    }

    function test_claim_modifiedAccountReverts() public {
        uint256 i = 256;
        bytes32[] memory p = demoProof(i);

        // A stranger front-running with the real proof.
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(address(0xBAD));
        registry.claim(i, demoAmounts[i], p);

        // Another allow-listed account using someone else's slot.
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i + 1]);
        registry.claim(i, demoAmounts[i], p);

        _assertUnclaimed(i);
        _assertUnclaimed(i + 1);
    }

    function test_claim_modifiedIndexReverts() public {
        uint256 i = 257;
        bytes32[] memory p = demoProof(i);
        uint256[3] memory bad = [uint256(256), 0, 258];
        for (uint256 k = 0; k < bad.length; ++k) {
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(bad[k], demoAmounts[i], p);
            _assertUnclaimed(bad[k]);
        }
        _assertUnclaimed(i);
    }

    function test_claim_ownProofCannotBeReusedForAnotherIndex() public {
        // Account 5 legitimately holds index 5. It tries to also take index 6 (owned by account 6) with
        // its own proof and amount, and with account 6's proof: both fail.
        uint256 i = 5;
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i + 1, demoAmounts[i], demoProof(i));

        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i + 1, demoAmounts[i + 1], demoProof(i + 1));
        _assertUnclaimed(i + 1);
    }

    // ------------------------------------------------------------------------------------------
    // Invalid proofs
    // ------------------------------------------------------------------------------------------

    function test_claim_emptyProofReverts() public {
        uint256 i = 0;
        bytes32[] memory empty;
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], empty);
        _assertUnclaimed(i);
    }

    function test_claim_truncatedProofReverts() public {
        uint256 i = 0;
        bytes32[] memory p = demoProof(i);
        bytes32[] memory truncated = new bytes32[](p.length - 1);
        for (uint256 k = 0; k < truncated.length; ++k) {
            truncated[k] = p[k];
        }
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], truncated);
        _assertUnclaimed(i);
    }

    function test_claim_extendedProofReverts() public {
        uint256 i = 257;
        bytes32[] memory p = demoProof(i);
        bytes32[] memory extended = new bytes32[](p.length + 1);
        for (uint256 k = 0; k < p.length; ++k) {
            extended[k] = p[k];
        }
        extended[p.length] = bytes32(uint256(1));
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], extended);
        _assertUnclaimed(i);
    }

    function test_claim_reorderedProofReverts() public {
        uint256 i = 0;
        bytes32[] memory p = demoProof(i);
        (p[0], p[1]) = (p[1], p[0]);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], p);
        _assertUnclaimed(i);
    }

    function test_claim_tamperedProofElementReverts() public {
        uint256 i = 255;
        bytes32[] memory p = demoProof(i);
        for (uint256 k = 0; k < p.length; ++k) {
            bytes32[] memory tampered = demoProof(i);
            tampered[k] = bytes32(uint256(tampered[k]) ^ 1);
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(i, demoAmounts[i], tampered);
        }
        _assertUnclaimed(i);
    }

    function test_claim_proofOfAnotherLeafReverts() public {
        uint256 i = 256;
        bytes32[] memory other = demoProof(0);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], other);
        _assertUnclaimed(i);
    }

    function test_claim_internalNodeCannotBeReplayedAsLeaf() public {
        // Pretend the internal node hash(leaf0, leaf1) is a leaf: no (index, account, amount) hashes to it,
        // so the attacker's best attempt is to submit leaf 0's proof minus its first sibling. It fails.
        uint256 i = 0;
        bytes32[] memory p = demoProof(i);
        bytes32[] memory shifted = new bytes32[](p.length - 1);
        for (uint256 k = 0; k < shifted.length; ++k) {
            shifted[k] = p[k + 1];
        }
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], shifted);
        _assertUnclaimed(i);
    }

    // ------------------------------------------------------------------------------------------
    // A failed proof never consumes the claim
    // ------------------------------------------------------------------------------------------

    function test_failedProofDoesNotConsumeClaim() public {
        uint256[4] memory idx = [uint256(0), 255, 256, 257];
        for (uint256 n = 0; n < idx.length; ++n) {
            uint256 i = idx[n];
            bytes32[] memory p = demoProof(i);

            // 1. wrong amount
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(i, demoAmounts[i] + 1, p);
            // 2. wrong sender
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(address(0xDEAD));
            registry.claim(i, demoAmounts[i], p);
            // 3. wrong proof
            bytes32[] memory bad = demoProof((i + 1) % DEMO_LEAF_COUNT);
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(i, demoAmounts[i], bad);

            _assertUnclaimed(i);
            assertEq(registry.claimCount(), n, "a failed attempt must not count");

            // The genuine claim still goes through afterwards.
            _claimAndAssert(i);
        }
    }

    function test_verifyProofViewMatchesClaimOutcome() public view {
        uint256 i = 256;
        bytes32[] memory p = demoProof(i);
        assertTrue(registry.verifyProof(i, demoAccounts[i], demoAmounts[i], p));
        assertFalse(registry.verifyProof(i, demoAccounts[i], demoAmounts[i] + 1, p));
        assertFalse(registry.verifyProof(i, address(0xBAD), demoAmounts[i], p));
        assertFalse(registry.verifyProof(i + 1, demoAccounts[i], demoAmounts[i], p));
    }

    // ------------------------------------------------------------------------------------------
    // Small and degenerate trees
    // ------------------------------------------------------------------------------------------

    function test_singleLeafTree_emptyProofClaims() public {
        address account = address(0x1111);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leaf(0, account, 5);
        ClaimRegistry single = new ClaimRegistry(MerkleTree.root(leaves));
        assertEq(single.merkleRoot(), leaves[0], "single-leaf root is the leaf");

        bytes32[] memory empty;
        vm.prank(account);
        single.claim(0, 5, empty);
        assertTrue(single.isClaimed(0));

        vm.expectRevert(abi.encodeWithSelector(ClaimRegistry.AlreadyClaimed.selector, 0));
        vm.prank(account);
        single.claim(0, 5, empty);
    }

    function test_twoLeafTree_bothClaim() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleTree.leaf(0, address(0xA), 1);
        leaves[1] = MerkleTree.leaf(1, address(0xB), 2);
        ClaimRegistry two = new ClaimRegistry(MerkleTree.root(leaves));

        vm.prank(address(0xA));
        two.claim(0, 1, MerkleTree.proof(leaves, 0));
        vm.prank(address(0xB));
        two.claim(1, 2, MerkleTree.proof(leaves, 1));
        assertEq(two.claimCount(), 2);
        assertEq(two.totalClaimedOf(address(0xA)), 1);
        assertEq(two.totalClaimedOf(address(0xB)), 2);
    }

    function test_zeroAmountLeafIsClaimable() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleTree.leaf(0, address(0xA), 0);
        leaves[1] = MerkleTree.leaf(1, address(0xB), 9);
        ClaimRegistry r = new ClaimRegistry(MerkleTree.root(leaves));
        vm.prank(address(0xA));
        r.claim(0, 0, MerkleTree.proof(leaves, 0));
        assertTrue(r.isClaimed(0));
        assertEq(r.claimedAmount(0), 0);
        assertEq(r.claimedBy(0), address(0xA));
    }

    function test_zeroRootRegistryNeverClaims() public {
        ClaimRegistry empty = new ClaimRegistry(bytes32(0));
        bytes32[] memory p;
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        empty.claim(0, 0, p);
        bytes32[] memory p1 = new bytes32[](1);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        empty.claim(0, 0, p1);
    }

    function test_sameAccountMultipleIndicesAccumulates() public {
        address account = address(0xC0FFEE);
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = MerkleTree.leaf(0, account, 10);
        leaves[1] = MerkleTree.leaf(1, account, 20);
        leaves[2] = MerkleTree.leaf(2, address(0xD), 1);
        ClaimRegistry r = new ClaimRegistry(MerkleTree.root(leaves));
        vm.startPrank(account);
        r.claim(0, 10, MerkleTree.proof(leaves, 0));
        r.claim(1, 20, MerkleTree.proof(leaves, 1));
        vm.stopPrank();
        assertEq(r.totalClaimedOf(account), 30);
        assertEq(r.claimCount(), 2);
        assertFalse(r.isClaimed(2));
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------

    function testFuzz_anyDemoLeafClaimsExactlyOnce(uint16 seed) public {
        uint256 i = uint256(seed) % DEMO_LEAF_COUNT;
        _claimAndAssert(i);
        bytes32[] memory p = demoProof(i);
        vm.expectRevert(abi.encodeWithSelector(ClaimRegistry.AlreadyClaimed.selector, i));
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], p);
    }

    function testFuzz_modifiedAmountNeverVerifies(uint16 seed, uint256 delta) public {
        vm.assume(delta != 0);
        uint256 i = uint256(seed) % DEMO_LEAF_COUNT;
        bytes32[] memory p = demoProof(i);
        unchecked {
            vm.expectRevert(ClaimRegistry.InvalidProof.selector);
            vm.prank(demoAccounts[i]);
            registry.claim(i, demoAmounts[i] + delta, p);
        }
        _assertUnclaimed(i);
    }

    function testFuzz_modifiedIndexNeverVerifies(uint16 seed, uint256 otherIndex) public {
        uint256 i = uint256(seed) % DEMO_LEAF_COUNT;
        vm.assume(otherIndex != i);
        bytes32[] memory p = demoProof(i);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(demoAccounts[i]);
        registry.claim(otherIndex, demoAmounts[i], p);
        _assertUnclaimed(i);
        _assertUnclaimed(otherIndex);
    }

    function testFuzz_modifiedAccountNeverVerifies(uint16 seed, address other) public {
        uint256 i = uint256(seed) % DEMO_LEAF_COUNT;
        vm.assume(other != demoAccounts[i]);
        bytes32[] memory p = demoProof(i);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(other);
        registry.claim(i, demoAmounts[i], p);
        _assertUnclaimed(i);
    }

    function testFuzz_randomProofNeverVerifies(uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        public
    {
        vm.assume(proof.length < 64);
        vm.expectRevert(ClaimRegistry.InvalidProof.selector);
        vm.prank(account);
        registry.claim(index, amount, proof);
        assertFalse(registry.isClaimed(index));
        assertEq(registry.claimCount(), 0);
    }

    /// @dev Builds a fresh tree of `n` random leaves and checks that every leaf claims exactly once and
    /// that bits never leak between indices, for sizes that cover single, even, odd and carry-up shapes.
    function testFuzz_arbitraryTreeEveryLeafClaimsOnce(bytes32 seed, uint8 nRaw) public {
        uint256 n = bound(uint256(nRaw), 1, 40);
        bytes32[] memory leaves = new bytes32[](n);
        address[] memory accounts = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256[] memory indices = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            bytes32 h = keccak256(abi.encode(seed, k));
            // Spread indices across word boundaries: k, 255-ish and 256-ish regions.
            indices[k] = k * 129; // distinct, crosses 256 for k >= 2
            accounts[k] = address(uint160(uint256(h)));
            amounts[k] = uint256(keccak256(abi.encode(h, "amt")));
            leaves[k] = MerkleTree.leaf(indices[k], accounts[k], amounts[k]);
        }
        ClaimRegistry r = new ClaimRegistry(MerkleTree.root(leaves));

        for (uint256 k = 0; k < n; ++k) {
            bytes32[] memory p = MerkleTree.proof(leaves, k);
            vm.prank(accounts[k]);
            r.claim(indices[k], amounts[k], p);
            assertTrue(r.isClaimed(indices[k]));
            assertEq(r.claimedAmount(indices[k]), amounts[k]);
            assertEq(r.claimedBy(indices[k]), accounts[k]);
            for (uint256 j = k + 1; j < n; ++j) {
                assertFalse(r.isClaimed(indices[j]), "bit leaked into an unclaimed index");
            }
        }
        assertEq(r.claimCount(), n);
        for (uint256 k = 0; k < n; ++k) {
            vm.expectRevert(abi.encodeWithSelector(ClaimRegistry.AlreadyClaimed.selector, indices[k]));
            vm.prank(accounts[k]);
            r.claim(indices[k], amounts[k], MerkleTree.proof(leaves, k));
        }
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _claimAndAssert(uint256 i) internal {
        uint256 countBefore = registry.claimCount();
        uint256 totalBefore = registry.totalClaimedOf(demoAccounts[i]);
        assertFalse(registry.isClaimed(i));

        bytes32[] memory p = demoProof(i);
        vm.prank(demoAccounts[i]);
        registry.claim(i, demoAmounts[i], p);

        assertTrue(registry.isClaimed(i), "index not marked");
        assertEq(registry.claimedAmount(i), demoAmounts[i], "amount not recorded");
        assertEq(registry.claimedBy(i), demoAccounts[i], "claimer not recorded");
        assertEq(registry.totalClaimedOf(demoAccounts[i]), totalBefore + demoAmounts[i]);
        assertEq(registry.claimCount(), countBefore + 1);
    }

    function _assertUnclaimed(uint256 i) internal view {
        assertFalse(registry.isClaimed(i), "index consumed by a failed claim");
        assertEq(registry.claimedAmount(i), 0);
        assertEq(registry.claimedBy(i), address(0));
    }
}
