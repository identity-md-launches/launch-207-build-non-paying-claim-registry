#!/usr/bin/env node
// Dependency-free Merkle proof builder for ClaimRegistry.
//
// Usage:
//   node script/merkle.mjs build <leaves.json>              -> prints {root, leaves:[{index,account,amount,leaf,proof}]}
//   node script/merkle.mjs root  <leaves.json>              -> prints the root only
//   node script/merkle.mjs proof <leaves.json> <index>      -> prints the proof for one index
//   node script/merkle.mjs leaf  <index> <account> <amount> -> prints the double-hashed leaf
//   node script/merkle.mjs keccak <0xhex>                   -> keccak256 of raw bytes (self-check vs `cast keccak`)
//
// <leaves.json> is an array of {"index": <uint>, "account": "0x…", "amount": <uint as string>}.
// Requires Node >= 18 (BigInt). No packages: keccak-256 is implemented below.
//
// Tree shape (identical to test/utils/MerkleTree.sol):
//   leaf  = keccak256(keccak256(abi.encode(uint256 index, address account, uint256 amount)))
//   level n+1[k] = keccak256(sorted(level n[2k], level n[2k+1])); an odd trailing node is carried up unchanged.

// ---------------------------------------------------------------------------------------------
// keccak-256 (original Keccak padding 0x01, NOT NIST SHA3 0x06) over BigInt lanes.
// ---------------------------------------------------------------------------------------------
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
// Rotation offsets r[x][y].
const ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];
const MASK64 = (1n << 64n) - 1n;
const rotl = (v, n) => n === 0 ? v : (((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK64);

function keccakF(A) {
  // A is an array of 25 BigInt lanes, index = x + 5*y.
  for (let round = 0; round < 24; round++) {
    // theta
    const C = new Array(5);
    for (let x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
      for (let y = 0; y < 5; y++) A[x + 5 * y] ^= D;
    }
    // rho + pi
    const B = new Array(25).fill(0n);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(A[x + 5 * y], ROT[x][y]);
      }
    }
    // chi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        A[x + 5 * y] = B[x + 5 * y] ^ ((~B[((x + 1) % 5) + 5 * y] & MASK64) & B[((x + 2) % 5) + 5 * y]);
      }
    }
    // iota
    A[0] ^= RC[round];
  }
}

export function keccak256(bytes) {
  const rate = 136;
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;

  const A = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      A[i] ^= lane;
    }
    keccakF(A);
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i];
    for (let b = 0; b < 8; b++) {
      out[i * 8 + b] = Number(lane & 0xffn);
      lane >>= 8n;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------------------------
const hex = (u8) => "0x" + Array.from(u8, (b) => b.toString(16).padStart(2, "0")).join("");
function fromHex(h) {
  const s = h.startsWith("0x") ? h.slice(2) : h;
  if (s.length % 2 !== 0) throw new Error("odd-length hex");
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(2 * i, 2 * i + 2), 16);
  return out;
}
function word(value) {
  let v = BigInt(value);
  if (v < 0n || v >= 1n << 256n) throw new Error("value out of uint256 range");
  const out = new Uint8Array(32);
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}
function concat(...parts) {
  const len = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}
const cmp = (a, b) => {
  for (let i = 0; i < 32; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
};

// ---------------------------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------------------------
export function leafOf(index, account, amount) {
  const acct = fromHex(account);
  if (acct.length !== 20) throw new Error(`bad address ${account}`);
  const encoded = concat(word(index), word(hex(acct)), word(amount)); // abi.encode(uint256,address,uint256)
  return keccak256(keccak256(encoded));
}
export const hashPair = (a, b) => (cmp(a, b) <= 0 ? keccak256(concat(a, b)) : keccak256(concat(b, a)));

function nextLevel(level) {
  const next = [];
  for (let i = 0; i + 1 < level.length; i += 2) next.push(hashPair(level[i], level[i + 1]));
  if (level.length % 2 === 1) next.push(level[level.length - 1]);
  return next;
}
export function buildTree(leaves) {
  if (leaves.length === 0) throw new Error("empty tree");
  const levels = [leaves];
  while (levels[levels.length - 1].length > 1) levels.push(nextLevel(levels[levels.length - 1]));
  return levels;
}
export function proofFor(levels, position) {
  const out = [];
  let pos = position;
  for (let d = 0; d < levels.length - 1; d++) {
    const sib = pos ^ 1;
    if (sib < levels[d].length) out.push(levels[d][sib]);
    pos >>= 1;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------
async function loadLeaves(path) {
  const { readFile } = await import("node:fs/promises");
  const entries = JSON.parse(await readFile(path, "utf8"));
  entries.forEach((e, i) => {
    if (BigInt(e.index) !== BigInt(i)) throw new Error(`leaves.json must be sorted by index; entry ${i} has index ${e.index}`);
  });
  return entries;
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === "keccak") {
    console.log(hex(keccak256(fromHex(rest[0] ?? "0x"))));
    return;
  }
  if (cmd === "leaf") {
    console.log(hex(leafOf(rest[0], rest[1], rest[2])));
    return;
  }
  if (cmd === "root" || cmd === "build" || cmd === "proof") {
    const entries = await loadLeaves(rest[0]);
    const leaves = entries.map((e) => leafOf(e.index, e.account, e.amount));
    const levels = buildTree(leaves);
    const root = hex(levels[levels.length - 1][0]);
    if (cmd === "root") {
      console.log(root);
    } else if (cmd === "proof") {
      const idx = Number(rest[1]);
      console.log(JSON.stringify({ root, index: idx, account: entries[idx].account, amount: String(entries[idx].amount), leaf: hex(leaves[idx]), proof: proofFor(levels, idx).map(hex) }, null, 2));
    } else {
      const out = {
        root,
        leafCount: leaves.length,
        leaves: entries.map((e, i) => ({
          index: Number(e.index),
          account: e.account,
          amount: String(e.amount),
          leaf: hex(leaves[i]),
          proof: proofFor(levels, i).map(hex),
        })),
      };
      console.log(JSON.stringify(out, null, 2));
    }
    return;
  }
  console.error("usage: merkle.mjs build|root|proof <leaves.json> [index] | leaf <index> <account> <amount> | keccak <0xhex>");
  process.exit(2);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
