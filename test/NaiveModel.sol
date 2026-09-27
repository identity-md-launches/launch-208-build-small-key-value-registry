// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";

/// @notice A deliberately naive reference model of ONE namespace of the registry.
///
/// @dev It shares nothing with the production contract except the `Status` enum and the kind codes:
///      entries live in an unsorted array searched linearly, and atomicity is implemented by taking a
///      full snapshot of that array before the batch and restoring it on failure. The tests compare
///      the registry's observable state against this model after every batch so that a divergence in
///      either implementation shows up as a failing property rather than as two suites that happen to
///      agree with their own author.
contract NaiveModel {
    struct Entry {
        bytes32 key;
        bytes32 value;
    }

    Entry[] private entries;

    // ------------------------------------------------------------------ views

    function get(bytes32 key) public view returns (bytes32) {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].key == key) return entries[i].value;
        }
        return bytes32(0);
    }

    function size() external view returns (uint256) {
        return entries.length;
    }

    // ------------------------------------------------------------------ rules

    /// @dev The refusal order, restated independently of the production code.
    function check(KeyValueRegistry.Op memory op) public view returns (KeyValueRegistry.Status) {
        if (op.kind != 0 && op.kind != 1 && op.kind != 2) return KeyValueRegistry.Status.InvalidKind;
        if (op.key == bytes32(0)) return KeyValueRegistry.Status.ZeroKey;
        if ((op.kind == 0 || op.kind == 1) && op.value == bytes32(0)) return KeyValueRegistry.Status.ZeroValue;
        bool present = get(op.key) != bytes32(0);
        if (op.kind == 0 && present) return KeyValueRegistry.Status.KeyExists;
        if (op.kind != 0 && !present) return KeyValueRegistry.Status.KeyMissing;
        return KeyValueRegistry.Status.Ok;
    }

    function single(KeyValueRegistry.Op memory op) public returns (KeyValueRegistry.Status status) {
        status = check(op);
        if (status == KeyValueRegistry.Status.Ok) _apply(op);
    }

    /// @notice Naive atomic batch: snapshot, apply sequentially, restore the snapshot on failure.
    /// @return ok whether every operation was accepted
    /// @return failIndex index of the first refused operation (only meaningful when !ok)
    /// @return failStatus status of the first refused operation (only meaningful when !ok)
    function atomic(KeyValueRegistry.Op[] memory ops)
        external
        returns (bool ok, uint256 failIndex, KeyValueRegistry.Status failStatus)
    {
        Entry[] memory snapshot = entries;
        for (uint256 i = 0; i < ops.length; ++i) {
            KeyValueRegistry.Status status = check(ops[i]);
            if (status != KeyValueRegistry.Status.Ok) {
                delete entries;
                for (uint256 j = 0; j < snapshot.length; ++j) {
                    entries.push(snapshot[j]);
                }
                return (false, i, status);
            }
            _apply(ops[i]);
        }
        return (true, 0, KeyValueRegistry.Status.Ok);
    }

    /// @notice Naive best-effort batch: one `single` per operation, in order.
    function bestEffort(KeyValueRegistry.Op[] memory ops) external returns (KeyValueRegistry.Status[] memory statuses) {
        statuses = new KeyValueRegistry.Status[](ops.length);
        for (uint256 i = 0; i < ops.length; ++i) {
            statuses[i] = single(ops[i]);
        }
    }

    // ------------------------------------------------------------------ internals

    function _apply(KeyValueRegistry.Op memory op) private {
        if (op.kind == 0) {
            entries.push(Entry({key: op.key, value: op.value}));
            return;
        }
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].key != op.key) continue;
            if (op.kind == 1) {
                entries[i].value = op.value;
            } else {
                entries[i] = entries[entries.length - 1];
                entries.pop();
            }
            return;
        }
    }
}
