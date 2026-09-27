# Deployment record: ClaimRegistry on Sepolia

Deployment is **ON**. Target: Sepolia, chain id **11155111**. Mainnet is refused by the script.

This worker seat holds no signing key and no RPC secret and cannot broadcast. The network's deployer
executes the command below after review and completes the "Filled in by the deployer" section. Until
then the address, transaction hash and explorer link are pending, not unknown by omission.

## What is deployed

| Field | Value |
| --- | --- |
| Contract | `ClaimRegistry` (`src/ClaimRegistry.sol`) |
| Compiler | solc 0.8.26, optimizer on, 200 runs, `evm_version = paris`, `bytecode_hash = none`, `cbor_metadata = false` |
| Constructor | `constructor(bytes32 merkleRoot_)` |
| Constructor argument `merkleRoot_` | `0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3` |
| ABI-encoded constructor args | `0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3` (a single `bytes32`) |
| keccak256 of creation code (`forge inspect ClaimRegistry bytecode`) | `0xb097b87698246decfedd355b0395f248114c0f2be25cbca5b15116e2b9e7ec25` |
| Runtime size | 1,557 bytes |
| Value sent | 0 |
| Admin roles | none |

The root is that of the documented demo tree (`docs/demo/leaves.json`, 258 leaves). The accounts in
that tree use public demo keys, so anyone can exercise `claim` on this deployment.

## Command for the deployer

```sh
EXPECTED_CHAIN_ID=11155111 \
MERKLE_ROOT=0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3 \
forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL" --broadcast <signer flags>
```

The script:

1. reads `EXPECTED_CHAIN_ID` and `MERKLE_ROOT` (defaults to the demo root),
2. reverts unless the connected chain id equals `EXPECTED_CHAIN_ID` and that is 11155111 or 31337,
3. reverts on a zero root,
4. deploys exactly one `ClaimRegistry` between `vm.startBroadcast()` and `vm.stopBroadcast()`,
5. logs the address, chain id and the constructor argument.

Offline dry-run, which the verifier also performs:

```sh
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

## Post-deployment checks (no key required)

```sh
cast call <ADDRESS> "merkleRoot()(bytes32)" --rpc-url "$SEPOLIA_RPC_URL"
# expect 0x93f0e07174bb25a4a681698dac27ee3397fcae43cce601f4be59c6130c565cf3
cast call <ADDRESS> "claimCount()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
# expect 0 immediately after deployment
cast call <ADDRESS> "verifyProof(uint256,address,uint256,bytes32[])(bool)" \
  257 0x5dA3679fdE47BFa34B2907202F1df4dDB22Cb0cD 258000000000000000000 \
  "[0xf56f8c97697ce73fd6043e423c06d40ef8af405fa426fb8f781d98c46547dfe3,0x9dbf82f9854475b50756efc2127257cf30675116a84725f41b4992a7992bc62e]" \
  --rpc-url "$SEPOLIA_RPC_URL"
# expect true
```

Explorer verification: standard JSON input from `forge verify-contract` with compiler 0.8.26,
optimizer 200 runs, EVM version paris, constructor args as above.

## Filled in by the deployer

| Field | Value |
| --- | --- |
| Contract address | _pending_ |
| Deployment transaction hash | _pending_ |
| Explorer link | `https://sepolia.etherscan.io/address/<ADDRESS>` (_pending_) |
| Deployer address | _pending_ |
| Block number | _pending_ |
