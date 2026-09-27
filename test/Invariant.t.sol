// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";

/// @notice Drives one namespace through random single and batch calls from a small key pool.
///         Every call is wrapped so the handler itself never reverts; refused calls are counted.
contract RegistryHandler is Test {
    KeyValueRegistry public immutable registry;
    bytes32[6] public keys;

    uint256 public accepted;
    uint256 public refused;
    uint256 public atomicReverts;

    constructor(KeyValueRegistry registry_) {
        registry = registry_;
        keys = [bytes32(0), keccak256("k1"), keccak256("k2"), keccak256("k3"), keccak256("k4"), keccak256("k5")];
    }

    function single(uint8 kind, uint8 keyIdx, bytes32 value) external {
        kind = uint8(bound(kind, 0, 2));
        bytes32 key = keys[bound(keyIdx, 0, 5)];
        bool ok;
        if (kind == 0) {
            try registry.add(key, value) {
                ok = true;
            } catch {}
        } else if (kind == 1) {
            try registry.update(key, value) {
                ok = true;
            } catch {}
        } else {
            try registry.remove(key) {
                ok = true;
            } catch {}
        }
        if (ok) accepted += 1;
        else refused += 1;
    }

    function bestEffort(uint256 seed, uint8 n) external {
        n = uint8(bound(n, 1, 16));
        KeyValueRegistry.Status[] memory st = registry.batchBestEffort(_gen(seed, n));
        for (uint256 i = 0; i < st.length; ++i) {
            if (st[i] == KeyValueRegistry.Status.Ok) accepted += 1;
            else refused += 1;
        }
    }

    function atomic(uint256 seed, uint8 n) external {
        n = uint8(bound(n, 1, 16));
        try registry.batchAtomic(_gen(seed, n)) {
            accepted += n;
        } catch {
            atomicReverts += 1;
        }
    }

    function _gen(uint256 seed, uint8 n) private view returns (KeyValueRegistry.Op[] memory list) {
        list = new KeyValueRegistry.Op[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            list[i] = KeyValueRegistry.Op({
                kind: uint8(r % 4),
                key: keys[(r >> 8) % 6],
                value: bytes32((r >> 16) % 3) // 0, 1, 2
            });
        }
    }
}

contract RegistryInvariantTest is Test {
    KeyValueRegistry internal registry;
    RegistryHandler internal handler;

    function setUp() public {
        registry = new KeyValueRegistry();
        handler = new RegistryHandler(registry);
        targetContract(address(handler));
    }

    /// @dev `size` is exactly the number of present keys, and only pool keys can ever be present.
    function invariant_sizeEqualsNumberOfPresentKeys() public view {
        uint256 present;
        for (uint256 i = 0; i < 6; ++i) {
            bytes32 key = handler.keys(i);
            bytes32 value = registry.get(address(handler), key);
            if (value != bytes32(0)) present += 1;
            assertEq(registry.contains(address(handler), key), value != bytes32(0), "contains vs get");
        }
        assertEq(registry.size(address(handler)), present, "size drifted from the number of present keys");
    }

    /// @dev Key zero can never hold a value, whatever the handler tried.
    function invariant_zeroKeyIsNeverPresent() public view {
        assertEq(registry.get(address(handler), bytes32(0)), bytes32(0));
        assertFalse(registry.contains(address(handler), bytes32(0)));
    }

    /// @dev Nothing the handler does leaks into another namespace.
    function invariant_otherNamespacesUntouched() public view {
        assertEq(registry.size(address(this)), 0);
        assertEq(registry.size(address(0xBEEF)), 0);
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(registry.get(address(this), handler.keys(i)), bytes32(0));
        }
    }
}
