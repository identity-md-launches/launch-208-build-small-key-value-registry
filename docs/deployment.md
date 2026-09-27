# Deployment record: KeyValueRegistry on Sepolia

Deployment is ON for this project. This seat holds no keys and broadcasts nothing; the network's
deployer performs the transaction after review and fills in the record below.

| Field | Value |
| --- | --- |
| Network | Sepolia (chain id 11155111) |
| Contract | `src/KeyValueRegistry.sol:KeyValueRegistry` |
| Constructor arguments | none (the constructor takes no parameters; `MAX_BATCH = 16` is a constant) |
| Value sent with deployment | 0 |
| Contract address | _to be filled by the deployer_ |
| Deployment transaction hash | _to be filled by the deployer_ |
| Explorer (address) | `https://sepolia.etherscan.io/address/<contract-address>` |
| Explorer (transaction) | `https://sepolia.etherscan.io/tx/<transaction-hash>` |
| Compiler | solc 0.8.26, optimizer on, 200 runs, EVM `paris`, `bytecode_hash = "none"` |
| Deploy script | `script/Deploy.s.sol:Deploy`, `EXPECTED_CHAIN_ID=11155111` |

## Deployer checklist

1. `forge build --offline && forge test --offline && forge fmt --check` on the reviewed commit.
2. `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` (dry run, no RPC).
3. Broadcast with `EXPECTED_CHAIN_ID=11155111`, an operator-supplied RPC URL and signer. The script
   refuses any other chain id, including mainnet.
4. Record address and transaction hash above, then verify the source on the explorer with the
   compiler settings in the table (no constructor arguments to encode).
5. Smoke test from any account: `add(keccak256("demo"), 0x…01)` then `get(<account>, keccak256("demo"))`.

## Launch-manifest notes

- Application contract with no constructor arguments; no `$owner`, `$token` or `$contract:` reference
  is needed.
- The contract is fully configured in its constructor and has no initialisation call.
- The task forbids creating a token, so no launch token is shipped in this repository.
