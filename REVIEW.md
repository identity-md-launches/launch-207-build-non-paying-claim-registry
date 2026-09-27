# Review: ClaimRegistry

Self-review by the implementing seat, written as an attacker would read the code. It is not an
independent audit; an independent adversarial review is still required before this pattern guards
real value.

## Scope

- `src/ClaimRegistry.sol`, `src/MerkleProofLib.sol`
- `script/Deploy.s.sol`, `script/merkle.mjs`
- `test/**`

## Who can call what

| Function | Caller | Effect |
| --- | --- | --- |
| `constructor(bytes32)` | deployer / factory | sets the immutable root; nothing else |
| `claim(uint256,uint256,bytes32[])` | anyone | only succeeds for the account bound in the leaf (`msg.sender`) |
| all other functions | anyone | views, no state change |

There is no owner, no pause, no upgrade, no sweep, no fee, no `receive`/`fallback`, no external call
of any kind. The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (scanned with the
same PUSH-skipping loop the launch floor uses). Constructor runs with the factory as `msg.sender`
and does not read `msg.sender` at all.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Info | Duplicate indices in the *tree* (two leaves sharing an index with different accounts) let the first claimer lock out the second. The contract cannot detect this. | Documented as an off-chain responsibility in README. `script/merkle.mjs` rejects an input file that is not `0..n-1` in order. Not fixable on-chain without changing the requested leaf format. |
| 2 | Info | A zero root is a valid constructor argument and yields a registry where nothing can be claimed. | Deploy script refuses a zero root (`EmptyRoot`); contract left permissive so a deliberate empty registry remains possible. Tested. |
| 3 | Info | `claimCount` is incremented in an `unchecked` block. | Bounded by the number of distinct indices ever claimed, each costing a storage write; overflow is unreachable. |
| 4 | Info | The launch floor (`Project.protected.t.sol`) requires a token creation code; the task forbids creating a token. | Out of this project's control. Documented in README under Assumptions. |
| 5 | None | Reentrancy | No external calls; nothing to re-enter. |
| 6 | None | Front-running of claims | The proof is only valid for `msg.sender`; observing a pending claim gives an attacker nothing. Tested (`test_claim_modifiedAccountReverts`). |
| 7 | None | Second-preimage / internal-node-as-leaf | Leaves are double hashed (32-byte outer preimage) and internal nodes are 64-byte preimages; domains cannot collide. Tested by presenting a shifted proof (`test_claim_internalNodeCannotBeReplayedAsLeaf`). |
| 8 | None | Bitmap bit leakage across words | Indices 0/255/256/257 tested individually and together; fuzz covers indices `k*129` for up to 40 leaves. |
| 9 | None | Partial state on failed claim | Both reverts happen before any write. `test_failedProofDoesNotConsumeClaim` fails three ways then succeeds at each boundary index. |
| 10 | None | Deep or huge proofs | Loop is linear in `proof.length`; the caller pays the gas. A wrong-length proof can never verify against a fixed root. |

No high, medium or low findings.

## What was re-run

```
forge build --offline                                        ok, solc 0.8.26
forge test --offline                                         51 passed, 0 failed (256 fuzz runs each)
forge fmt --check                                            ok
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
                                                             ok, deploys with demo root on 31337
EXPECTED_CHAIN_ID=11155111 forge script ... --offline        reverts ChainIdMismatch(11155111, 31337) as intended
node script/merkle.mjs keccak <x> vs cast keccak <x>         identical on empty, 4-byte and 300-byte inputs
node script/merkle.mjs root docs/demo/leaves.json            0x93f0e0…5cf3, equal to the Solidity builder and Deploy.DEMO_ROOT
cast keccak(cast keccak(abi-encode leaf 257))                0x361756…dc8d, equal to both builders
runtime opcode scan                                          1,557 bytes, no 0xF2/0xF4/0xFF
```

## Test coverage read as an attacker

Covered: every requested index; duplicate claims with valid and garbage proofs; modified amount,
account and index (unit + fuzz); empty, truncated, extended, reordered, tampered, foreign and shifted
proofs; random proofs; single-, two-, three-leaf and 1..300-leaf trees; zero amount; zero root; same
account across several indices; chain gating in the deploy script.

Not covered, stated as gaps: proofs longer than ~9 elements in the contract tests (the builder test
goes to 300 leaves, i.e. depth 9), the exact gas ceiling of `claim` for very deep trees, and EVM
versions other than `paris`. None of these change the security argument above.
