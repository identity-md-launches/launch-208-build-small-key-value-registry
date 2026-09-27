// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";
import {NaiveModel} from "./NaiveModel.sol";

/// @notice Differential fuzzing against the naive model, plus two structural properties:
///         - best-effort(batch) is observably identical to running each op as its own batch, in order;
///         - atomic(batch) is either identical to best-effort(batch) with all-Ok statuses, or a no-op
///           that reports exactly the first non-Ok index and status.
///
/// @dev Operations are drawn from a tiny key/value pool so that batches are dense with repeated keys,
///      zero keys, zero values and invalid kinds. Each test runs several batches back to back so the
///      pre-state of later batches is itself fuzzed.
contract ModelEquivalenceTest is Test {
    KeyValueRegistry internal registry;
    KeyValueRegistry internal sequential;
    NaiveModel internal model;

    address internal alice = makeAddr("alice");

    bytes32[4] internal keyPool;
    bytes32[3] internal valuePool;

    function setUp() public {
        registry = new KeyValueRegistry();
        sequential = new KeyValueRegistry();
        model = new NaiveModel();
        keyPool = [bytes32(0), keccak256("a"), keccak256("b"), keccak256("c")];
        valuePool = [bytes32(0), bytes32(uint256(1)), bytes32(uint256(2))];
    }

    // ------------------------------------------------------------------ generators

    function genOps(uint256 seed, uint256 n) internal view returns (KeyValueRegistry.Op[] memory list) {
        list = new KeyValueRegistry.Op[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            list[i] = KeyValueRegistry.Op({
                kind: uint8(r % 4), // 0..2 valid, 3 invalid
                key: keyPool[(r >> 8) % 4],
                value: valuePool[(r >> 16) % 3]
            });
        }
    }

    function assertStateMatchesModel(string memory where) internal view {
        for (uint256 i = 0; i < keyPool.length; ++i) {
            assertEq(registry.get(alice, keyPool[i]), model.get(keyPool[i]), string.concat(where, ": value"));
        }
        assertEq(registry.size(alice), model.size(), string.concat(where, ": size"));
    }

    function assertRegistriesEqual(KeyValueRegistry a, KeyValueRegistry b, string memory where) internal view {
        for (uint256 i = 0; i < keyPool.length; ++i) {
            assertEq(a.get(alice, keyPool[i]), b.get(alice, keyPool[i]), string.concat(where, ": value"));
        }
        assertEq(a.size(alice), b.size(alice), string.concat(where, ": size"));
    }

    function snapshot(KeyValueRegistry r) internal view returns (bytes32[5] memory s) {
        for (uint256 i = 0; i < keyPool.length; ++i) {
            s[i] = r.get(alice, keyPool[i]);
        }
        s[4] = bytes32(r.size(alice));
    }

    // ------------------------------------------------------------------ best-effort vs model

    function testFuzz_bestEffortMatchesNaiveModel(uint256 seed, uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 6));
        for (uint256 round = 0; round < rounds; ++round) {
            uint256 roundSeed = uint256(keccak256(abi.encode(seed, round)));
            uint256 n = 1 + (roundSeed % 16);
            KeyValueRegistry.Op[] memory list = genOps(roundSeed, n);

            KeyValueRegistry.Status[] memory expected = model.bestEffort(list);
            vm.prank(alice);
            KeyValueRegistry.Status[] memory actual = registry.batchBestEffort(list);

            assertEq(actual.length, expected.length, "status length");
            for (uint256 i = 0; i < n; ++i) {
                assertEq(uint256(actual[i]), uint256(expected[i]), "status mismatch vs model");
            }
            assertStateMatchesModel("best-effort");
        }
    }

    // ------------------------------------------------------------------ atomic vs model

    function testFuzz_atomicMatchesNaiveModel(uint256 seed, uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 6));
        for (uint256 round = 0; round < rounds; ++round) {
            uint256 roundSeed = uint256(keccak256(abi.encode(seed, round)));
            uint256 n = 1 + (roundSeed % 16);
            KeyValueRegistry.Op[] memory list = genOps(roundSeed, n);

            (bool ok, uint256 failIndex, KeyValueRegistry.Status failStatus) = model.atomic(list);
            if (!ok) {
                vm.expectRevert(
                    abi.encodeWithSelector(KeyValueRegistry.AtomicBatchRejected.selector, failIndex, failStatus)
                );
            }
            vm.prank(alice);
            registry.batchAtomic(list);
            assertStateMatchesModel("atomic");

            // Keep the pre-state moving between rounds even when atomic batches keep failing:
            // every other round also runs a best-effort batch on both sides.
            if (round % 2 == 1) {
                KeyValueRegistry.Op[] memory filler = genOps(roundSeed ^ 1, 1 + (roundSeed >> 32) % 16);
                model.bestEffort(filler);
                vm.prank(alice);
                registry.batchBestEffort(filler);
                assertStateMatchesModel("atomic/filler");
            }
        }
    }

    // ------------------------------------------------------------------ structural properties

    /// @dev Best-effort is exactly "apply each op as its own batch, in order". This is the property
    ///      that makes "failed-operation state preservation" precise: a refused op in the middle of a
    ///      batch leaves the registry exactly as a refused single call would.
    function testFuzz_bestEffortEqualsSequentialSingles(uint256 seed) public {
        // Shared, fuzzed pre-state on both registries.
        KeyValueRegistry.Op[] memory pre = genOps(seed ^ 0xABCD, 1 + (seed % 16));
        vm.prank(alice);
        registry.batchBestEffort(pre);
        vm.prank(alice);
        sequential.batchBestEffort(pre);

        uint256 n = 1 + ((seed >> 40) % 16);
        KeyValueRegistry.Op[] memory list = genOps(seed, n);

        vm.prank(alice);
        KeyValueRegistry.Status[] memory batched = registry.batchBestEffort(list);

        for (uint256 i = 0; i < n; ++i) {
            KeyValueRegistry.Op[] memory one = new KeyValueRegistry.Op[](1);
            one[0] = list[i];
            bytes32[5] memory before = snapshot(sequential);
            vm.prank(alice);
            KeyValueRegistry.Status[] memory st = sequential.batchBestEffort(one);
            assertEq(uint256(st[0]), uint256(batched[i]), "per-item status differs from single call");
            if (st[0] != KeyValueRegistry.Status.Ok) {
                bytes32[5] memory post = snapshot(sequential);
                for (uint256 j = 0; j < 5; ++j) {
                    assertEq(post[j], before[j], "a refused op changed state");
                }
            }
        }
        assertRegistriesEqual(registry, sequential, "best-effort vs sequential");
    }

    /// @dev Atomic is best-effort with the "all Ok" precondition, otherwise a no-op reporting the
    ///      first failure.
    function testFuzz_atomicIsAllOrNothingRelativeToBestEffort(uint256 seed) public {
        KeyValueRegistry.Op[] memory pre = genOps(seed ^ 0x1234, 1 + (seed % 16));
        vm.prank(alice);
        registry.batchBestEffort(pre);
        vm.prank(alice);
        sequential.batchBestEffort(pre);

        uint256 n = 1 + ((seed >> 40) % 16);
        KeyValueRegistry.Op[] memory list = genOps(seed, n);

        vm.prank(alice);
        KeyValueRegistry.Status[] memory statuses = sequential.batchBestEffort(list);
        uint256 firstBad = n;
        for (uint256 i = 0; i < n; ++i) {
            if (statuses[i] != KeyValueRegistry.Status.Ok) {
                firstBad = i;
                break;
            }
        }

        bytes32[5] memory before = snapshot(registry);
        if (firstBad < n) {
            vm.expectRevert(
                abi.encodeWithSelector(KeyValueRegistry.AtomicBatchRejected.selector, firstBad, statuses[firstBad])
            );
        }
        vm.prank(alice);
        registry.batchAtomic(list);

        if (firstBad < n) {
            bytes32[5] memory post = snapshot(registry);
            for (uint256 j = 0; j < 5; ++j) {
                assertEq(post[j], before[j], "rejected atomic batch changed state");
            }
        } else {
            assertRegistriesEqual(registry, sequential, "accepted atomic equals best-effort");
        }
    }
}
