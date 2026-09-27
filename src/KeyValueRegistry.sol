// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title KeyValueRegistry
/// @notice A minimal bytes32 -> bytes32 registry with per-caller namespaces and two clearly distinct
///         batch APIs: an atomic batch that reverts on the first invalid operation, and a best-effort
///         batch that applies every valid operation in order and reports a per-item outcome.
///
/// @dev Namespace model
///      Every caller owns an independent namespace keyed by its address. There is no administrator,
///      no shared namespace and no way for one account to write into another account's namespace.
///
///      Key and value rules
///      - A key is a nonzero bytes32. Key zero is refused everywhere.
///      - A stored value is a nonzero bytes32. Value zero means "absent", so add/update refuse it.
///      - add    : key must be absent, value nonzero. Stores the value.
///      - update : key must be present, value nonzero. Replaces the value.
///      - remove : key must be present. The `value` field of the operation is ignored.
///
///      Refusal order (per operation, first match wins)
///      1. InvalidKind  - kind is not 0 (add), 1 (update) or 2 (remove)
///      2. ZeroKey      - key == 0
///      3. ZeroValue    - value == 0 (add and update only)
///      4. KeyExists    - add on a present key
///         KeyMissing   - update or remove on an absent key
///      The state check is always last, so a malformed operation reports its shape problem even
///      when the state would also have rejected it.
///
///      Batch rules
///      - A batch holds 1..16 operations. Empty batches and batches above 16 revert in both APIs.
///      - Operations are evaluated strictly in order, and each one sees the effects of the earlier
///        ones in the same batch. Repeating a key inside a batch is allowed and follows the rules above
///        (add then update the same key succeeds; add then add the same key refuses the second).
///      - batchAtomic  : the first refused operation reverts the whole call with its index and status.
///        Nothing from the batch is kept.
///      - batchBestEffort : every operation is checked; valid ones are applied immediately, refused
///        ones are skipped and reported. The returned array has one Status per operation, in order.
///        A refused operation never changes state. Skipped items also emit `OperationSkipped`.
contract KeyValueRegistry {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Outcome of checking or applying one operation.
    enum Status {
        Ok,
        InvalidKind,
        ZeroKey,
        ZeroValue,
        KeyExists,
        KeyMissing
    }

    /// @notice One batch operation. `kind` is a uint8 rather than an enum so that an out-of-range
    ///         kind is reported per item by the best-effort API instead of aborting ABI decoding.
    struct Op {
        uint8 kind;
        bytes32 key;
        bytes32 value;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    uint8 public constant KIND_ADD = 0;
    uint8 public constant KIND_UPDATE = 1;
    uint8 public constant KIND_REMOVE = 2;

    /// @notice Maximum number of operations per batch (inclusive).
    uint256 public constant MAX_BATCH = 16;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address owner => mapping(bytes32 key => bytes32 value)) private _values;
    mapping(address owner => uint256 count) private _sizes;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Added(address indexed owner, bytes32 indexed key, bytes32 value);
    event Updated(address indexed owner, bytes32 indexed key, bytes32 oldValue, bytes32 newValue);
    event Removed(address indexed owner, bytes32 indexed key, bytes32 oldValue);
    /// @notice Emitted by the best-effort batch for every refused item.
    event OperationSkipped(address indexed owner, uint256 index, Status status);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice A single-operation call (add/update/remove) was refused.
    error OperationRejected(Status status);
    /// @notice The atomic batch was refused at `index`; no operation from the batch was kept.
    error AtomicBatchRejected(uint256 index, Status status);
    /// @notice The batch contained no operations.
    error EmptyBatch();
    /// @notice The batch exceeded `MAX_BATCH` operations.
    error BatchTooLarge(uint256 length, uint256 max);

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Value stored under `key` in `owner`'s namespace, or zero when absent.
    function get(address owner, bytes32 key) external view returns (bytes32) {
        return _values[owner][key];
    }

    /// @notice Whether `key` is present in `owner`'s namespace.
    function contains(address owner, bytes32 key) external view returns (bool) {
        return _values[owner][key] != bytes32(0);
    }

    /// @notice Number of keys present in `owner`'s namespace.
    function size(address owner) external view returns (uint256) {
        return _sizes[owner];
    }

    /// @notice Dry-run of the per-operation rules against `owner`'s current namespace.
    ///         Returns the status the operation would get if it ran now, in isolation.
    function check(address owner, Op calldata op) external view returns (Status) {
        return _check(owner, op.kind, op.key, op.value);
    }

    // ---------------------------------------------------------------------------------------------
    // Single operations
    // ---------------------------------------------------------------------------------------------

    /// @notice Add `key` -> `value` to the caller's namespace. Reverts unless the key is absent.
    function add(bytes32 key, bytes32 value) external {
        _single(KIND_ADD, key, value);
    }

    /// @notice Replace the value under `key` in the caller's namespace. Reverts unless present.
    function update(bytes32 key, bytes32 value) external {
        _single(KIND_UPDATE, key, value);
    }

    /// @notice Remove `key` from the caller's namespace. Reverts unless present.
    function remove(bytes32 key) external {
        _single(KIND_REMOVE, key, bytes32(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Batch operations
    // ---------------------------------------------------------------------------------------------

    /// @notice All-or-nothing batch. Reverts with `AtomicBatchRejected(index, status)` on the first
    ///         refused operation; earlier writes in the same call are rolled back by the revert.
    function batchAtomic(Op[] calldata ops) external {
        _boundBatch(ops.length);
        for (uint256 i = 0; i < ops.length; ++i) {
            Op calldata op = ops[i];
            Status status = _check(msg.sender, op.kind, op.key, op.value);
            if (status != Status.Ok) revert AtomicBatchRejected(i, status);
            _apply(msg.sender, op.kind, op.key, op.value);
        }
    }

    /// @notice Best-effort batch. Applies each valid operation in order, skips refused ones, and
    ///         returns one Status per operation. Never reverts because of an individual operation;
    ///         only the batch-size rules revert.
    function batchBestEffort(Op[] calldata ops) external returns (Status[] memory statuses) {
        _boundBatch(ops.length);
        statuses = new Status[](ops.length);
        for (uint256 i = 0; i < ops.length; ++i) {
            Op calldata op = ops[i];
            Status status = _check(msg.sender, op.kind, op.key, op.value);
            statuses[i] = status;
            if (status == Status.Ok) {
                _apply(msg.sender, op.kind, op.key, op.value);
            } else {
                emit OperationSkipped(msg.sender, i, status);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _boundBatch(uint256 length) private pure {
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH) revert BatchTooLarge(length, MAX_BATCH);
    }

    function _single(uint8 kind, bytes32 key, bytes32 value) private {
        Status status = _check(msg.sender, kind, key, value);
        if (status != Status.Ok) revert OperationRejected(status);
        _apply(msg.sender, kind, key, value);
    }

    /// @dev The single source of truth for the refusal order documented at the top of the file.
    function _check(address owner, uint8 kind, bytes32 key, bytes32 value) private view returns (Status) {
        if (kind > KIND_REMOVE) return Status.InvalidKind;
        if (key == bytes32(0)) return Status.ZeroKey;
        if (kind != KIND_REMOVE && value == bytes32(0)) return Status.ZeroValue;

        bool present = _values[owner][key] != bytes32(0);
        if (kind == KIND_ADD) {
            if (present) return Status.KeyExists;
        } else {
            if (!present) return Status.KeyMissing;
        }
        return Status.Ok;
    }

    /// @dev Precondition: `_check` returned Ok for the same arguments in this same call frame.
    function _apply(address owner, uint8 kind, bytes32 key, bytes32 value) private {
        bytes32 old = _values[owner][key];
        if (kind == KIND_ADD) {
            _values[owner][key] = value;
            _sizes[owner] += 1;
            emit Added(owner, key, value);
        } else if (kind == KIND_UPDATE) {
            _values[owner][key] = value;
            emit Updated(owner, key, old, value);
        } else {
            delete _values[owner][key];
            _sizes[owner] -= 1;
            emit Removed(owner, key, old);
        }
    }
}
