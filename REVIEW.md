# Review: KeyValueRegistry

Scope: `src/KeyValueRegistry.sol`, `script/Deploy.s.sol`, the test suite and `foundry.toml`.
Method: read the contract as an attacker along the usual questions (who can call what, value in
and out, arithmetic and limits, ordering, external dependencies), then re-ran every check offline.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Info | The task asks for solc 0.8.24; the project pins 0.8.26. | Accepted. The offline verifier has no 0.8.24 binary and the protected floor tests are `pragma solidity 0.8.26` exactly. Source stays at the 0.8.24 language level. Documented in README. |
| 2 | Info | `remove` ignores the `value` field of an `Op`. | Accepted and documented. A stricter "value must be zero" rule would add a fourth refusal status without protecting anything. Covered by `test_remove_ignoresValueField`. |
| 3 | Info | An out-of-range `kind` is a per-item `InvalidKind` rather than an ABI decoding failure. | Intended: `kind` is `uint8` precisely so that the best-effort API can report it. Covered by the refusal-order test and the fuzz generators, which emit kind 3. |
| 4 | Info | No token is shipped although the launch floor's project test expects one. | The task forbids creating a token. Left to the manifest node; called out in README. |
| 5 | Low | `size` is a counter, not derived from storage; a bug in `_apply` could desynchronise it. | Mitigated by the invariant `size == number of present keys` over the handler's pool and by the model comparison after every batch. |

No finding changes the requested behaviour.

## Attack surface walked

- **Authorisation.** No privileged role exists. Every write is scoped to `msg.sender`; reads take
  the owner explicitly. There is no fallback or receive function, so no ETH can enter.
- **Value.** No external calls, no token transfers, no `payable`. Reentrancy is impossible.
- **Arithmetic.** The only arithmetic is the `size` counter, incremented on `add` and decremented
  on `remove`, both guarded by the presence check that precedes them. Underflow would revert in
  0.8 and the invariant suite never observed a revert in 2 048 calls per run.
- **Limits.** Batches are bounded to 16 items; the loop cost is linear and bounded. 16 fresh adds
  cost about 0.9M gas in tests, far below any block limit.
- **Ordering.** Operations are evaluated sequentially with state visible to later items. The
  atomic API relies on the EVM revert to roll back, which is the only correct way to do it without
  a two-pass simulation. The differential tests compare it with a snapshot-and-restore model.
- **Front-running.** A registry write can be front-run by another writer only within the same
  namespace, and the namespace is the caller. There is nothing to sandwich.
- **Deployment.** The script reads `EXPECTED_CHAIN_ID` only, allows 31337 / 11155111 / 0 (dry
  run), refuses mainnet, and performs exactly one deployment between the broadcast markers. The
  runtime scan in `test/Deploy.t.sol` mirrors the protected floor's forbidden-opcode scan.

## What the tests do not cover

- The invariant handler uses a 6-key pool; the mapping itself is uniform so this is representative,
  but keys outside the pool are only reached through the fuzz tests.
- No explicit gas-limit test; the 16-item bound makes it moot.
- No contract-caller test; contracts are ordinary callers here.
- The protected floor tests were compiled under this configuration (they build) but were not run:
  they require the verifier's environment (factory address, creation codes, expected supply).

## Re-run record

All offline, on the seat's toolchain (forge 1.7.1, solc 0.8.26):

```
forge build --offline                                   -> Compiler run successful (lint warnings only, in tests)
forge test --offline                                    -> 45 passed, 0 failed, 0 skipped
forge fmt --check                                       -> clean
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
                                                        -> Script ran successfully, one deployment
```

The protected floor sources (`Project.protected.t.sol`, `Token.protected.t.sol`) were copied into
`test/scratch/` and compiled with this `foundry.toml` to confirm the compiler pin and the
`forge-std` remapping satisfy them; they were removed again afterwards.
