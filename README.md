# ClaimRegistry: a non-paying Merkle claim registry

`ClaimRegistry` records that an allow-listed account has claimed its slot in a Merkle tree, and
records the amount that slot carried. It moves no funds, mints nothing, and has no owner. The
Merkle root is immutable and is the single constructor argument.

This is a standalone Foundry project. It builds and tests offline; the only dependency is a
vendored copy of `forge-std` under `lib/` (ordinary files, not a submodule).

| Item | Value |
| --- | --- |
| Contract | `src/ClaimRegistry.sol` (library `src/MerkleProofLib.sol`) |
| Source language | Solidity `^0.8.24` (compiled with pinned solc 0.8.26, see Assumptions) |
| EVM target | `paris`, optimizer on, 200 runs, no metadata hash |
| Runtime size | 1,557 bytes; no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` |
| Constructor | `constructor(bytes32 merkleRoot_)` |
| Target network | Sepolia, chain id 11155111 (mainnet is refused by the deploy script) |
| Demo root | `0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3` |
| ABI | `docs/abi/ClaimRegistry.json` |

## Exact behavior

### Leaf format

```
leaf = keccak256( bytes.concat( keccak256( abi.encode(uint256 index, address account, uint256 amount) ) ) )
```

The inner `abi.encode` is the 96-byte head-only encoding: index, then the address left-padded to 32
bytes, then the amount. The outer hash is over the 32-byte inner digest. Double hashing puts leaves
in a different preimage domain from internal nodes (whose preimage is always 64 bytes), so an
internal node can never be presented as a leaf.

### Tree shape and proofs

- Level 0 is the list of leaves in index order.
- Each level pairs positions `(2k, 2k+1)`. The pair is **sorted numerically** before hashing:
  `parent = keccak256(min(a,b) || max(a,b))`. Proofs therefore carry no position bits.
- An odd trailing node is **carried up unchanged** to the next level (not duplicated). Its proof
  has no sibling at that level. A single-leaf tree has the leaf itself as root and an empty proof.
- Verification folds the leaf through the proof elements in order and compares with the root.

Both builders in this repository implement exactly this shape:

- `test/utils/MerkleTree.sol`: pure Solidity, used by the tests.
- `script/merkle.mjs`: plain Node.js with an inline keccak-256 (no packages).

### `claim(uint256 index, uint256 amount, bytes32[] proof)`

1. If `isClaimed(index)` is already true, revert `AlreadyClaimed(index)`. The proof is not examined.
2. Compute `leafOf(index, msg.sender, amount)` and verify it against `merkleRoot`. On failure revert
   `InvalidProof()`.
3. Otherwise, atomically: set the bit for `index` in the claimed bitmap, set `claimedAmount[index]`,
   set `claimedBy[index] = msg.sender`, add `amount` to `totalClaimedOf[msg.sender]`, increment
   `claimCount`, emit `Claimed(index, msg.sender, amount)`.

Consequences:

- **Only the bound account can consume its index.** The account is always `msg.sender`; a third
  party holding a valid proof cannot spend it, and no relayer or `claimFor` path exists.
- **A failed claim never consumes anything.** Every failure path is a revert before the first
  storage write, so a wrong amount, wrong sender, wrong index or malformed proof leaves the slot
  available for the genuine claim later. `test_failedProofDoesNotConsumeClaim` exercises this at
  indices 0, 255, 256 and 257.
- **Amount is recorded, not paid.** The contract holds no tokens and no ETH, has no `receive` or
  `fallback`, and makes no external calls. What downstream systems do with the recorded amount is
  outside this contract.
- **Indices are arbitrary `uint256` values.** The bitmap is `mapping(uint256 => uint256)` keyed by
  `index >> 8`, so indices 255/256/257 sit at a word boundary and are tested explicitly.
- A **zero-amount leaf** is claimable: `isClaimed` becomes true while `claimedAmount` stays zero.
- A **zero root** deploys, but no claim can ever succeed on it. The deploy script refuses a zero
  root so this cannot happen by accident.

### Views

| Function | Meaning |
| --- | --- |
| `merkleRoot()` | Immutable root |
| `isClaimed(index)` | Whether the index was consumed |
| `claimedAmount(index)` | Amount recorded for a consumed index (0 otherwise) |
| `claimedBy(index)` | Account that consumed the index (zero address otherwise) |
| `totalClaimedOf(account)` | Sum of amounts an account has recorded across its indices |
| `claimCount()` | Number of successful claims |
| `verifyProof(index, account, amount, proof)` | Pure proof check against the root, ignores the bitmap |
| `leafOf(index, account, amount)` | The double-hashed leaf |

## Demo parameters and test accounts

The tests and the shipped deployment configuration use one documented tree of **258 leaves**
(indices 0..257), chosen so that indices 256 and 257 pair at level 0 and then ride the carry-up path
to the top (their proofs have 2 elements, index 0 has 9).

```
pk_i      = keccak256(abi.encode("imd-claim-demo", i))       (a uint256 private key)
account_i = address derived from pk_i
amount_i  = (i + 1) * 1e18
```

`docs/demo/leaves.json` lists every `(index, account, amount, privateKey)`; `docs/demo/proofs.json`
lists the root and a proof per leaf. **These private keys are public demo keys and hold nothing of
value.** Anyone can use them to claim on the Sepolia demo deployment, which is the point of a demo.

Example (index 257):

```
account 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD
amount  258000000000000000000
leaf    0x3617563e5304be75935bc9e1119f84a46dea140bf2c87c345acdbbdb6113dc8d
proof   [0xf56f8c97697ce73fd6043e423c06d40ef8af405fa426fb8f781d98c46547dfe3,
         0x9dbf82f9854475b50756efc2127257cf30675116a84725f41b4992a7992bc62e]
root    0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3
```

The root is derived three independent ways and asserted equal in
`test_DemoRootMatchesJavaScriptAndDeployScript`: the Solidity builder over `vm.addr`-derived
accounts, the JavaScript builder over `leaves.json`, and the constant in `script/Deploy.s.sol`.

## Reproduction commands

Everything below runs with no network access.

```sh
# Build, test, format check, deploy dry-run (exactly what the verifier runs)
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline

# Regenerate the demo leaf list (needs only `cast`)
{
  echo "["
  for i in $(seq 0 257); do
    PK=$(cast keccak "$(cast abi-encode 'f(string,uint256)' 'imd-claim-demo' $i)")
    ADDR=$(cast wallet address --private-key "$PK")
    AMT=$(( i + 1 ))000000000000000000
    SEP=","; [ "$i" = "257" ] && SEP=""
    printf '  {"index": %d, "account": "%s", "amount": "%s", "privateKey": "%s"}%s\n' "$i" "$ADDR" "$AMT" "$PK" "$SEP"
  done
  echo "]"
} > docs/demo/leaves.json

# Root and proofs with the dependency-free JavaScript builder (Node >= 18)
node script/merkle.mjs root  docs/demo/leaves.json
node script/merkle.mjs proof docs/demo/leaves.json 257
node script/merkle.mjs build docs/demo/leaves.json > docs/demo/proofs.json

# Independent check of one leaf with cast only
cast keccak $(cast keccak $(cast abi-encode 'f(uint256,address,uint256)' \
  257 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD 258000000000000000000))
# -> 0x3617563e5304be75935bc9e1119f84a46dea140bf2c87c345acdbbdb6113dc8d

# Self-check of the inline keccak against cast
node script/merkle.mjs keccak 0xdeadbeef ; cast keccak 0xdeadbeef
```

## Tests

`forge test --offline` runs 51 tests in three suites.

- `test/ClaimRegistry.t.sol` (37): claims at indices 0, 255, 256, 257 individually and together,
  word-boundary isolation, event emission, no value moved, duplicate claims (with valid and garbage
  proofs), modified amount / account / index, empty, truncated, extended, reordered, tampered and
  foreign proofs, internal-node replay, failed proof never consumes the claim, `verifyProof`,
  single-leaf, two-leaf, zero-amount, zero-root and multi-index trees. Fuzz: any demo leaf claims
  exactly once; modified amount / index / account never verifies; random proofs never verify;
  arbitrary trees of 1..40 leaves with indices spanning several bitmap words.
- `test/MerkleTree.t.sol` (7): the builder itself: single, sorted pair, carry-up, fixed leaf
  vector, parity with the contract's `hashPair`, fuzz "every proof reproduces the root and rejects a
  neighbour" for 1..300 leaves.
- `test/Deploy.t.sol` (7): deploy path with demo root, dry-run semantics, Sepolia accepted, mainnet
  and other chains refused, chain mismatch refused, zero root refused.

## Deployment

Deployment is **ON** for Sepolia. This worker holds no keys and does not broadcast; the network's
deployer performs the transaction after review. `DEPLOYMENT.md` holds the deployment record
(constructor arguments, creation-code hash, and the fields the deployer fills in: address,
transaction hash, explorer link).

Operator command (the signer and RPC are supplied by the operator on the command line, never stored
in this repository):

```sh
EXPECTED_CHAIN_ID=11155111 MERKLE_ROOT=0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3 \
forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL" --broadcast <signer flags>
```

The script deploys exactly one contract, refuses any chain other than 31337 or 11155111, refuses a
mismatch between `EXPECTED_CHAIN_ID` and the connected chain, and refuses a zero root. `MERKLE_ROOT`
defaults to the demo root when unset.

Constructor arguments for verification:

| Parameter | Type | Value |
| --- | --- | --- |
| `merkleRoot_` | `bytes32` | `0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3` |

If the contract is deployed through a launch factory instead, the constructor is nonpayable, takes
one `bytes32`, and needs no initialization call; `bytes32` is a supported factory argument type.

## Assumptions and incomplete checks

- **Compiler pin.** The task asks for Solidity 0.8.24. The offline toolchain on the build machines
  has solc 0.8.17, 0.8.26, 0.8.28 and 0.8.30 only, and the protected launch floor is
  `pragma solidity 0.8.26`. The contract is therefore written to `^0.8.24` (it uses no feature newer
  than 0.8.24) and `foundry.toml` pins 0.8.26 so that it builds offline and the floor compiles
  alongside it. Changing the pin to `0.8.24` on a machine that has it requires no source change.
- **No token, no funds.** The task explicitly forbids creating a token. This project ships only the
  registry. The launch-floor test that expects a token creation code cannot be satisfied from this
  repository; that is a policy decision for the manifest node, not something this project resolves.
- **Tree construction is off-chain and trusted.** The contract cannot tell whether the root encodes
  duplicate indices with different accounts or amounts. If a tree contains two leaves with the same
  index, whichever account claims first wins the index; the other one is locked out. Builders must
  use unique indices. `script/merkle.mjs` enforces "sorted by index, no gaps" for its input file.
- **Amounts are informational.** Nothing checks that amounts sum to any budget.
- **Demo keys are public.** The Sepolia deployment with the demo root is claimable by anyone who
  reads `docs/demo/leaves.json`. It exists to demonstrate behavior, not to gate anything.
- **Not audited.** Tests passing is not a security review. `REVIEW.md` records the self-review and
  the edges that were considered; an independent adversarial review is still required before this
  pattern is used in front of real value.
- **Not covered by tests:** gas limits for extremely deep proofs (a proof of 256 elements would
  still verify but is not tested), and behavior under EVM versions other than `paris`.

## Operational responsibilities

- The party that builds the tree owns index uniqueness and account correctness. There is no
  correction path after deployment other than deploying a new registry with a new root.
- The deployer must confirm the printed constructor argument matches the intended root before
  broadcasting, and record the address and transaction hash in `DEPLOYMENT.md`.
- Nobody holds an administrative role. There is nothing to rotate, pause or upgrade.

## Layout

```
src/ClaimRegistry.sol        the contract
src/MerkleProofLib.sol       sorted-pair proof verification
script/Deploy.s.sol          deployment script (env: EXPECTED_CHAIN_ID, MERKLE_ROOT)
script/merkle.mjs            dependency-free JavaScript tree/proof builder
test/ClaimRegistry.t.sol     behavior tests (unit + fuzz)
test/MerkleTree.t.sol        builder tests
test/Deploy.t.sol            deploy configuration tests
test/utils/MerkleTree.sol    pure-Solidity tree/proof builder
test/utils/DemoFixture.sol   demo parameters derived in Solidity
docs/abi/ClaimRegistry.json  ABI
docs/demo/leaves.json        258 demo leaves with public demo keys
docs/demo/proofs.json        root and per-leaf proofs
lib/forge-std                vendored test library (ordinary files)
DEPLOYMENT.md                deployment record
REVIEW.md                    self-review
```
