// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";

/// @notice Unit tests for the documented semantics: single operations, the refusal order, batch
///         bounds, atomic rollback at the first/middle/last position, best-effort partial application
///         at the first/middle/last position, repeated keys inside a batch, and namespace isolation.
contract KeyValueRegistryTest is Test {
    KeyValueRegistry internal registry;

    // Demo test accounts (deterministic, derived from labels; no real keys involved).
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant K1 = keccak256("key-1");
    bytes32 internal constant K2 = keccak256("key-2");
    bytes32 internal constant K3 = keccak256("key-3");
    bytes32 internal constant V1 = bytes32(uint256(0x11));
    bytes32 internal constant V2 = bytes32(uint256(0x22));
    bytes32 internal constant V3 = bytes32(uint256(0x33));

    uint8 internal constant ADD = 0;
    uint8 internal constant UPDATE = 1;
    uint8 internal constant REMOVE = 2;

    event Added(address indexed owner, bytes32 indexed key, bytes32 value);
    event Updated(address indexed owner, bytes32 indexed key, bytes32 oldValue, bytes32 newValue);
    event Removed(address indexed owner, bytes32 indexed key, bytes32 oldValue);
    event OperationSkipped(address indexed owner, uint256 index, KeyValueRegistry.Status status);

    function setUp() public {
        registry = new KeyValueRegistry();
    }

    // ------------------------------------------------------------------ helpers

    function op(uint8 kind, bytes32 key, bytes32 value) internal pure returns (KeyValueRegistry.Op memory) {
        return KeyValueRegistry.Op({kind: kind, key: key, value: value});
    }

    function ops3(KeyValueRegistry.Op memory a, KeyValueRegistry.Op memory b, KeyValueRegistry.Op memory c)
        internal
        pure
        returns (KeyValueRegistry.Op[] memory list)
    {
        list = new KeyValueRegistry.Op[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function validOps(uint256 n) internal pure returns (KeyValueRegistry.Op[] memory list) {
        list = new KeyValueRegistry.Op[](n);
        for (uint256 i = 0; i < n; ++i) {
            list[i] = op(ADD, bytes32(uint256(1000 + i)), bytes32(uint256(1)));
        }
    }

    function assertStatus(KeyValueRegistry.Status actual, KeyValueRegistry.Status expected, string memory why)
        internal
        pure
    {
        assertEq(uint256(actual), uint256(expected), why);
    }

    /// @dev Snapshot of alice's namespace over the three demo keys plus her size.
    function snapshotAlice() internal view returns (bytes32[4] memory s) {
        s[0] = registry.get(alice, K1);
        s[1] = registry.get(alice, K2);
        s[2] = registry.get(alice, K3);
        s[3] = bytes32(registry.size(alice));
    }

    function assertSnapshotEq(bytes32[4] memory a, bytes32[4] memory b) internal pure {
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(a[i], b[i], "namespace changed");
        }
    }

    // ------------------------------------------------------------------ single operations

    function test_add_storesValueAndCounts() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(registry));
        emit Added(alice, K1, V1);
        registry.add(K1, V1);

        assertEq(registry.get(alice, K1), V1);
        assertTrue(registry.contains(alice, K1));
        assertEq(registry.size(alice), 1);
    }

    function test_add_refusesZeroKey() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.ZeroKey)
        );
        registry.add(bytes32(0), V1);
    }

    function test_add_refusesZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.ZeroValue)
        );
        registry.add(K1, bytes32(0));
    }

    function test_add_refusesExistingKey() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.KeyExists)
        );
        registry.add(K1, V2);
        vm.stopPrank();
        assertEq(registry.get(alice, K1), V1, "refused add must not overwrite");
        assertEq(registry.size(alice), 1);
    }

    function test_update_replacesValue() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit Updated(alice, K1, V1, V2);
        registry.update(K1, V2);
        vm.stopPrank();
        assertEq(registry.get(alice, K1), V2);
        assertEq(registry.size(alice), 1, "update must not change the count");
    }

    function test_update_refusesMissingKey() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.KeyMissing)
        );
        registry.update(K1, V1);
    }

    function test_update_refusesZeroValue() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.ZeroValue)
        );
        registry.update(K1, bytes32(0));
        vm.stopPrank();
        assertEq(registry.get(alice, K1), V1, "zero value must not be used as a removal");
    }

    function test_remove_deletesAndCounts() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit Removed(alice, K1, V1);
        registry.remove(K1);
        vm.stopPrank();
        assertEq(registry.get(alice, K1), bytes32(0));
        assertFalse(registry.contains(alice, K1));
        assertEq(registry.size(alice), 0);
    }

    function test_remove_refusesMissingKey() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.KeyMissing)
        );
        registry.remove(K1);
    }

    function test_remove_refusesZeroKey() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.ZeroKey)
        );
        registry.remove(bytes32(0));
    }

    function test_remove_ignoresValueField() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        KeyValueRegistry.Op[] memory list = new KeyValueRegistry.Op[](1);
        list[0] = op(REMOVE, K1, V3); // value is not zero and not the stored value: still a plain remove
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        vm.stopPrank();
        assertStatus(st[0], KeyValueRegistry.Status.Ok, "remove ignores value");
        assertFalse(registry.contains(alice, K1));
    }

    // ------------------------------------------------------------------ refusal order

    function test_refusalOrder_kindBeforeKeyBeforeValueBeforeState() public {
        vm.startPrank(alice);
        registry.add(K1, V1);

        // kind wins over an also-invalid key and value
        assertStatus(
            registry.check(alice, op(3, bytes32(0), bytes32(0))), KeyValueRegistry.Status.InvalidKind, "kind first"
        );
        assertStatus(registry.check(alice, op(255, K1, V1)), KeyValueRegistry.Status.InvalidKind, "kind first (255)");
        // key wins over an also-invalid value
        assertStatus(registry.check(alice, op(ADD, bytes32(0), bytes32(0))), KeyValueRegistry.Status.ZeroKey, "key");
        assertStatus(
            registry.check(alice, op(UPDATE, bytes32(0), bytes32(0))), KeyValueRegistry.Status.ZeroKey, "key (upd)"
        );
        // value wins over state: add on an existing key with value zero reports ZeroValue, not KeyExists
        assertStatus(registry.check(alice, op(ADD, K1, bytes32(0))), KeyValueRegistry.Status.ZeroValue, "value>state");
        // value wins over state: update on a missing key with value zero reports ZeroValue, not KeyMissing
        assertStatus(
            registry.check(alice, op(UPDATE, K2, bytes32(0))), KeyValueRegistry.Status.ZeroValue, "value>state upd"
        );
        // state is last
        assertStatus(registry.check(alice, op(ADD, K1, V2)), KeyValueRegistry.Status.KeyExists, "state add");
        assertStatus(registry.check(alice, op(UPDATE, K2, V2)), KeyValueRegistry.Status.KeyMissing, "state update");
        assertStatus(registry.check(alice, op(REMOVE, K2, bytes32(0))), KeyValueRegistry.Status.KeyMissing, "state rm");
        // remove never reports ZeroValue
        assertStatus(registry.check(alice, op(REMOVE, K1, bytes32(0))), KeyValueRegistry.Status.Ok, "rm ok");
        vm.stopPrank();
    }

    function test_check_agreesWithBestEffortStatuses() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K1, V2), op(UPDATE, K2, V2), op(7, K3, V3));
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        vm.stopPrank();
        assertStatus(st[0], KeyValueRegistry.Status.KeyExists, "0");
        assertStatus(st[1], KeyValueRegistry.Status.KeyMissing, "1");
        assertStatus(st[2], KeyValueRegistry.Status.InvalidKind, "2");
    }

    // ------------------------------------------------------------------ batch bounds

    function test_batch_emptyReverts() public {
        KeyValueRegistry.Op[] memory none = new KeyValueRegistry.Op[](0);
        vm.startPrank(alice);
        vm.expectRevert(KeyValueRegistry.EmptyBatch.selector);
        registry.batchAtomic(none);
        vm.expectRevert(KeyValueRegistry.EmptyBatch.selector);
        registry.batchBestEffort(none);
        vm.stopPrank();
    }

    function test_batch_sixteenIsAccepted() public {
        vm.prank(alice);
        registry.batchAtomic(validOps(16));
        assertEq(registry.size(alice), 16);

        vm.prank(bob);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(validOps(16));
        assertEq(st.length, 16);
        assertEq(registry.size(bob), 16);
    }

    function test_batch_seventeenReverts() public {
        KeyValueRegistry.Op[] memory list = validOps(17);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyValueRegistry.BatchTooLarge.selector, 17, 16));
        registry.batchAtomic(list);
        vm.expectRevert(abi.encodeWithSelector(KeyValueRegistry.BatchTooLarge.selector, 17, 16));
        registry.batchBestEffort(list);
        vm.stopPrank();
        assertEq(registry.size(alice), 0, "an oversized batch must apply nothing, even its valid prefix");
    }

    // ------------------------------------------------------------------ atomic: failure position

    function _atomicFailsAt(uint256 position) internal {
        // Pre-state: K1 present. The batch: [add K2, update K1, remove K1] with the op at `position`
        // replaced by an invalid one (add K1 which already exists).
        vm.prank(alice);
        registry.add(K1, V1);
        bytes32[4] memory before = snapshotAlice();

        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K2, V2), op(UPDATE, K1, V3), op(REMOVE, K1, bytes32(0)));
        list[position] = op(ADD, K1, V2);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                KeyValueRegistry.AtomicBatchRejected.selector, position, KeyValueRegistry.Status.KeyExists
            )
        );
        registry.batchAtomic(list);

        assertSnapshotEq(snapshotAlice(), before);
    }

    function test_atomic_failureAtFirstPositionKeepsNothing() public {
        _atomicFailsAt(0);
    }

    function test_atomic_failureAtMiddlePositionKeepsNothing() public {
        _atomicFailsAt(1);
    }

    function test_atomic_failureAtLastPositionKeepsNothing() public {
        _atomicFailsAt(2);
    }

    function test_atomic_allValidAppliesEverythingInOrder() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        registry.batchAtomic(ops3(op(ADD, K2, V2), op(UPDATE, K1, V3), op(REMOVE, K2, bytes32(0))));
        vm.stopPrank();
        assertEq(registry.get(alice, K1), V3);
        assertEq(registry.get(alice, K2), bytes32(0), "K2 was added then removed inside the batch");
        assertEq(registry.size(alice), 1);
    }

    // ------------------------------------------------------------------ best-effort: failure position

    function _bestEffortFailsAt(uint256 position) internal {
        vm.prank(alice);
        registry.add(K1, V1);

        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K2, V2), op(UPDATE, K1, V3), op(ADD, K3, V3));
        list[position] = op(UPDATE, keccak256("absent"), V2); // KeyMissing, touches no demo key

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(registry));
        emit OperationSkipped(alice, position, KeyValueRegistry.Status.KeyMissing);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);

        assertEq(st.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            if (i == position) {
                assertStatus(st[i], KeyValueRegistry.Status.KeyMissing, "failed slot");
            } else {
                assertStatus(st[i], KeyValueRegistry.Status.Ok, "valid slot");
            }
        }
        // Every valid item, whatever its position, has been applied; the failed one changed nothing.
        assertEq(registry.get(alice, K2), position == 0 ? bytes32(0) : V2, "K2");
        assertEq(registry.get(alice, K1), position == 1 ? V1 : V3, "K1");
        assertEq(registry.get(alice, K3), position == 2 ? bytes32(0) : V3, "K3");
        assertEq(registry.get(alice, keccak256("absent")), bytes32(0), "failed update wrote nothing");
        assertEq(registry.size(alice), position == 1 ? 3 : 2, "size");
    }

    function test_bestEffort_failureAtFirstPositionAppliesTheRest() public {
        _bestEffortFailsAt(0);
    }

    function test_bestEffort_failureAtMiddlePositionAppliesTheRest() public {
        _bestEffortFailsAt(1);
    }

    function test_bestEffort_failureAtLastPositionAppliesTheRest() public {
        _bestEffortFailsAt(2);
    }

    function test_bestEffort_allInvalidChangesNothingAndDoesNotRevert() public {
        KeyValueRegistry.Op[] memory list =
            ops3(op(UPDATE, K1, V1), op(REMOVE, K2, bytes32(0)), op(ADD, bytes32(0), V1));
        vm.prank(alice);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        assertStatus(st[0], KeyValueRegistry.Status.KeyMissing, "0");
        assertStatus(st[1], KeyValueRegistry.Status.KeyMissing, "1");
        assertStatus(st[2], KeyValueRegistry.Status.ZeroKey, "2");
        assertEq(registry.size(alice), 0);
    }

    // ------------------------------------------------------------------ repeated keys within a batch

    function test_repeatedKey_addThenUpdateSucceedsInBothApis() public {
        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K1, V1), op(UPDATE, K1, V2), op(UPDATE, K1, V3));

        vm.prank(alice);
        registry.batchAtomic(list);
        assertEq(registry.get(alice, K1), V3, "atomic: later ops see earlier ops");
        assertEq(registry.size(alice), 1);

        vm.prank(bob);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        assertStatus(st[0], KeyValueRegistry.Status.Ok, "0");
        assertStatus(st[1], KeyValueRegistry.Status.Ok, "1");
        assertStatus(st[2], KeyValueRegistry.Status.Ok, "2");
        assertEq(registry.get(bob, K1), V3, "best-effort: later ops see earlier ops");
    }

    function test_repeatedKey_addTwice_atomicRevertsAtSecond() public {
        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K1, V1), op(ADD, K1, V2), op(ADD, K2, V2));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.AtomicBatchRejected.selector, 1, KeyValueRegistry.Status.KeyExists)
        );
        registry.batchAtomic(list);
        assertEq(registry.size(alice), 0, "the first add was rolled back");
        assertEq(registry.get(alice, K1), bytes32(0));
    }

    function test_repeatedKey_addTwice_bestEffortKeepsFirst() public {
        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K1, V1), op(ADD, K1, V2), op(ADD, K2, V2));
        vm.prank(alice);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        assertStatus(st[0], KeyValueRegistry.Status.Ok, "0");
        assertStatus(st[1], KeyValueRegistry.Status.KeyExists, "1");
        assertStatus(st[2], KeyValueRegistry.Status.Ok, "2");
        assertEq(registry.get(alice, K1), V1, "first add wins, second is skipped");
        assertEq(registry.get(alice, K2), V2);
        assertEq(registry.size(alice), 2);
    }

    function test_repeatedKey_addRemoveAddWithinOneBatch() public {
        KeyValueRegistry.Op[] memory list = ops3(op(ADD, K1, V1), op(REMOVE, K1, bytes32(0)), op(ADD, K1, V2));
        vm.prank(alice);
        registry.batchAtomic(list);
        assertEq(registry.get(alice, K1), V2);
        assertEq(registry.size(alice), 1);
    }

    function test_repeatedKey_removeTwice_bestEffortReportsSecondMissing() public {
        vm.startPrank(alice);
        registry.add(K1, V1);
        KeyValueRegistry.Op[] memory list =
            ops3(op(REMOVE, K1, bytes32(0)), op(REMOVE, K1, bytes32(0)), op(UPDATE, K1, V2));
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        vm.stopPrank();
        assertStatus(st[0], KeyValueRegistry.Status.Ok, "0");
        assertStatus(st[1], KeyValueRegistry.Status.KeyMissing, "1");
        assertStatus(st[2], KeyValueRegistry.Status.KeyMissing, "2");
        assertEq(registry.size(alice), 0);
    }

    // ------------------------------------------------------------------ namespaces

    function test_namespaces_areIsolatedPerCaller() public {
        vm.prank(alice);
        registry.add(K1, V1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(KeyValueRegistry.OperationRejected.selector, KeyValueRegistry.Status.KeyMissing)
        );
        registry.update(K1, V2);

        vm.prank(bob);
        registry.add(K1, V3);

        assertEq(registry.get(alice, K1), V1, "alice unchanged");
        assertEq(registry.get(bob, K1), V3, "bob has his own copy");
        assertEq(registry.size(alice), 1);
        assertEq(registry.size(bob), 1);
        assertEq(registry.get(address(this), K1), bytes32(0), "third party sees nothing");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_singleOpsRoundTrip(bytes32 key, bytes32 v1, bytes32 v2) public {
        vm.assume(key != bytes32(0) && v1 != bytes32(0) && v2 != bytes32(0));
        vm.startPrank(alice);
        registry.add(key, v1);
        assertEq(registry.get(alice, key), v1);
        registry.update(key, v2);
        assertEq(registry.get(alice, key), v2);
        assertEq(registry.size(alice), 1);
        registry.remove(key);
        assertEq(registry.get(alice, key), bytes32(0));
        assertEq(registry.size(alice), 0);
        // the key is reusable after removal
        registry.add(key, v1);
        assertEq(registry.get(alice, key), v1);
        vm.stopPrank();
    }

    function testFuzz_atomicRejectsAtExactPosition(uint8 position, uint8 length) public {
        length = uint8(bound(length, 1, 16));
        position = uint8(bound(position, 0, length - 1));

        KeyValueRegistry.Op[] memory list = validOps(length);
        list[position] = op(UPDATE, keccak256("missing"), V1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                KeyValueRegistry.AtomicBatchRejected.selector, uint256(position), KeyValueRegistry.Status.KeyMissing
            )
        );
        registry.batchAtomic(list);
        assertEq(registry.size(alice), 0);

        vm.prank(alice);
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(list);
        assertEq(registry.size(alice), uint256(length) - 1, "best-effort applied every other op");
        for (uint256 i = 0; i < length; ++i) {
            assertStatus(
                st[i], i == position ? KeyValueRegistry.Status.KeyMissing : KeyValueRegistry.Status.Ok, "status"
            );
        }
    }
}
