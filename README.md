# KeyValueRegistry

A small `bytes32 -> bytes32` registry with per-caller namespaces and two clearly distinct batch
APIs:

| API | On the first invalid operation | Return |
| --- | --- | --- |
| `batchAtomic(Op[])` | reverts with `AtomicBatchRejected(index, status)`; nothing is kept | none |
| `batchBestEffort(Op[])` | skips it, emits `OperationSkipped`, continues | `Status[]`, one per item |

Both batches accept 1 to 16 operations and evaluate them strictly in order, so every operation sees
the effect of the earlier operations in the same batch.

Standalone Foundry project. No network access is needed to build, test or dry-run the deploy script.

## Exact behaviour

### Namespaces

Every caller owns an independent namespace keyed by `msg.sender`. Reads take the owner explicitly
(`get(owner, key)`, `contains(owner, key)`, `size(owner)`). There is no administrator, no shared
namespace, no pause, no upgrade path and no way to write into another account's namespace.

### Keys and values

- A key is a nonzero `bytes32`. Key zero is refused by every operation.
- A stored value is a nonzero `bytes32`. Zero means "absent", so `add` and `update` refuse a zero
  value. A removal is only ever done through `remove`, never by writing zero.

### Operations

| Kind | Code | Precondition | Effect |
| --- | --- | --- | --- |
| add | `0` | key absent, value nonzero | stores the value, `size` grows by one, emits `Added` |
| update | `1` | key present, value nonzero | replaces the value, `size` unchanged, emits `Updated(old, new)` |
| remove | `2` | key present | clears the slot, `size` shrinks by one, emits `Removed(old)`; the `value` field is ignored |

Single-operation entry points `add(key, value)`, `update(key, value)` and `remove(key)` apply exactly
the same rules and revert with `OperationRejected(status)`.

### Refusal order

Each operation is checked in this order and the first failing rule is the reported status:

1. `InvalidKind` : `kind` is not 0, 1 or 2
2. `ZeroKey` : `key == 0`
3. `ZeroValue` : `value == 0` (add and update only; remove never reports this)
4. `KeyExists` : add on a present key
   `KeyMissing` : update or remove on an absent key

Shape problems are therefore reported before state problems: an `add` of value zero on a key that
already exists reports `ZeroValue`, not `KeyExists`. `check(owner, op)` is a view that returns the
status an operation would get right now, in isolation.

`Status` is the enum `{ Ok = 0, InvalidKind = 1, ZeroKey = 2, ZeroValue = 3, KeyExists = 4, KeyMissing = 5 }`.

### Batch rules

- `EmptyBatch()` : zero operations, both APIs.
- `BatchTooLarge(length, 16)` : more than `MAX_BATCH = 16` operations, both APIs. An oversized batch
  applies nothing, not even a valid prefix.
- Repeated keys inside a batch are allowed and follow the rules above against the state left by the
  earlier items: `add K; update K` succeeds in both APIs, `add K; add K` refuses the second item
  (`KeyExists`), `add K; remove K; add K` succeeds.
- `batchAtomic` : on the first refused item the whole call reverts with
  `AtomicBatchRejected(index, status)`. The revert rolls back every earlier write of the call.
- `batchBestEffort` : refused items are skipped and reported in the returned array at their index,
  and an `OperationSkipped(owner, index, status)` event is emitted for each. A refused item never
  changes state. The batch is observably identical to calling each operation as its own batch in
  order, which is what the property tests check.

`Op` is `struct { uint8 kind; bytes32 key; bytes32 value; }`. `kind` is a `uint8` rather than an
enum on purpose: an out-of-range enum would abort ABI decoding for the whole call, whereas the
best-effort API is meant to report `InvalidKind` per item.

### Non-item reverts

Malformed calldata (for example a truncated array) reverts at ABI decoding for both APIs. That is
the only way `batchBestEffort` reverts besides the two batch-size errors.

## Interface

```solidity
uint256 constant MAX_BATCH = 16;
uint8 constant KIND_ADD = 0;  uint8 constant KIND_UPDATE = 1;  uint8 constant KIND_REMOVE = 2;

function get(address owner, bytes32 key) external view returns (bytes32);
function contains(address owner, bytes32 key) external view returns (bool);
function size(address owner) external view returns (uint256);
function check(address owner, Op calldata op) external view returns (Status);

function add(bytes32 key, bytes32 value) external;
function update(bytes32 key, bytes32 value) external;
function remove(bytes32 key) external;

function batchAtomic(Op[] calldata ops) external;
function batchBestEffort(Op[] calldata ops) external returns (Status[] memory);
```

Errors: `OperationRejected(Status)`, `AtomicBatchRejected(uint256,Status)`, `EmptyBatch()`,
`BatchTooLarge(uint256,uint256)`.
Events: `Added`, `Updated`, `Removed`, `OperationSkipped`.
ABI: `docs/abi/KeyValueRegistry.json`.

## Reproduction (offline)

Toolchain: Foundry (forge 1.7.x) with solc 0.8.26 cached locally. `forge-std` is vendored as plain
files under `lib/forge-std` (v1.16.2), so no dependency is fetched.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # local dry run, no RPC
```

Verbose run with the fuzz seeds shown: `forge test --offline -vvv`.

## Tests

45 tests in four suites (`forge test --offline`), all passing:

- `test/KeyValueRegistry.t.sol` : single operations and their refusals; the refusal order
  (kind before key before value before state); batch bounds (0 reverts, 16 accepted, 17 reverts in
  both APIs); atomic failure at the first, middle and last position leaves the namespace byte-for-byte
  unchanged; best-effort failure at the first, middle and last position applies every other item and
  leaves the failed one's key untouched; repeated keys inside a batch (add+update, add+add, add+remove+add,
  remove+remove); namespace isolation; a fuzzed failure position 0..15.
- `test/ModelEquivalence.t.sol` : differential fuzzing against `test/NaiveModel.sol`, an
  independently written array-backed model whose atomic batch works by snapshot-and-restore.
  Operations are drawn from a 4-key / 3-value pool including key zero, value zero and an invalid
  kind so batches are dense in collisions. Two structural properties are also fuzzed: best-effort
  equals sequential single calls (and a refused item changes nothing), and atomic is either
  best-effort with all-Ok statuses or a no-op that reports exactly the first non-Ok index and status.
- `test/Invariant.t.sol` : a handler drives one namespace through random singles and batches;
  invariants are `size == number of present keys`, key zero is never present, and other namespaces
  stay empty.
- `test/Deploy.t.sol` : the deploy script through its config entry point (no `vm.setEnv`): local,
  dry-run and Sepolia chain ids accepted, mismatch and unsupported chains refused, and the deployed
  runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

Demo test accounts are deterministic labels (`makeAddr("alice")`, `makeAddr("bob")`) with no real
keys. Demo parameters: `MAX_BATCH = 16`, keys `keccak256("key-1..3")`, values `0x11`, `0x22`, `0x33`.

## Deployment (Sepolia, chain id 11155111)

Deployment is ON. The contract has **no constructor arguments** and needs no initialisation call.
`script/Deploy.s.sol` performs exactly one `new KeyValueRegistry()` between the broadcast markers,
reads only `EXPECTED_CHAIN_ID` (must be `31337`, `11155111`, or `0` for an offline dry run) and
refuses every other chain, including mainnet. It reads no key and no RPC URL.

Operator-only command (signer and RPC are supplied by the operator's tooling, never by the repo):

```sh
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast --sender <deployer> [--ledger | --account <keystore-name>]
```

The deployment record (address, transaction hash, explorer link, constructor arguments) lives in
`docs/deployment.md`. This contributor seat holds no keys and does not broadcast; the network's
deployer fills the record after review. The explorer link pattern is
`https://sepolia.etherscan.io/address/<address>` and
`https://sepolia.etherscan.io/tx/<transaction-hash>`.

Expected deployment parameters:

| Parameter | Value |
| --- | --- |
| Chain | Sepolia, id 11155111 |
| Contract | `src/KeyValueRegistry.sol:KeyValueRegistry` |
| Constructor arguments | none |
| Value sent | 0 |
| Compiler | solc 0.8.26, optimizer on, 200 runs, EVM `paris`, `bytecode_hash = none` |
| Init-code size | about 2.6 KB; runtime well under the 24 576-byte limit |

## Assumptions

- **Compiler pin.** The task asks for Solidity 0.8.24. The source is written against the 0.8.24
  language level (`pragma solidity ^0.8.24`, no feature newer than 0.8.24 is used), but
  `foundry.toml` pins the compiler to **0.8.26**. Two facts force this: the offline verifier does
  not carry a 0.8.24 binary (the previous attempt failed with "can't install missing solc 0.8.24 in
  offline mode"), and the protected launch-floor tests the verifier adds carry an exact
  `pragma solidity 0.8.26`, which can never compile under a 0.8.24 pin. Pinning a path to a
  committed binary was rejected earlier and is not done here.
- **No token.** The task says not to create a token, so this repository ships only the registry.
  The launch-floor test `Project.protected.t.sol` requires a token creation code in its environment;
  supplying it, or launching the registry as a contracts-only project, is the manifest node's and
  deployer's decision, not this seat's.
- **EVM version `paris`.** Chosen for Sepolia compatibility per the accepted-job conventions; the
  contract uses no transient storage or `PUSH0`-dependent constructs anyway.
- **Namespace model.** "Registry" is interpreted as per-caller namespaces, which needs no owner and
  no privileged role. A shared namespace with an allowlisted writer would be a different contract.
- **`remove` ignores `value`.** Documented rather than refused, so that callers can reuse an `Op`
  builder without special-casing removals.
- **Empty batch is refused** in both APIs, so that "1 to 16" is the single batch rule.

## Incomplete checks and operational responsibilities

- Tests passing is not a security audit. The contract holds no funds and has no privileged role,
  which removes most of the usual attack surface, but an independent adversarial review is still
  expected before anything depends on it.
- The invariant handler explores a 6-key pool; keys outside the pool are only exercised by the
  unit and fuzz tests. Gas at 16 items is bounded by construction (about 0.9M gas for 16 fresh
  adds) but no gas-limit test is included.
- Not tested: reentrancy (no external calls exist), ETH handling (no `payable` function exists),
  behaviour with contract callers (namespaces are by address, contracts are ordinary callers).
- The Sepolia deployment itself is performed by the network deployer. Anyone who deploys must
  confirm `EXPECTED_CHAIN_ID=11155111`, record the address and transaction hash in
  `docs/deployment.md`, and verify the source on the explorer with the compiler settings above.
- Once deployed the contract has no operator duties: nothing to fund, pause, upgrade or rotate.
