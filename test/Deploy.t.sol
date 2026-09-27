// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {KeyValueRegistry} from "../src/KeyValueRegistry.sol";

/// @notice Exercises the deploy script through its config entry point. No test sets environment
///         variables: `run()` is the only reader of EXPECTED_CHAIN_ID and is not called here.
contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function test_deploy_onLocalChainWithExplicitId() public {
        KeyValueRegistry registry = deployer.deploy(Deploy.Config({expectedChainId: 31_337}));
        assertGt(address(registry).code.length, 0);
        assertEq(registry.MAX_BATCH(), 16);
        assertEq(registry.size(address(this)), 0);
    }

    function test_deploy_zeroMeansLocalDryRun() public {
        KeyValueRegistry registry = deployer.deploy(Deploy.Config({expectedChainId: 0}));
        assertGt(address(registry).code.length, 0);
    }

    function test_deploy_onSepoliaWhenChainMatches() public {
        vm.chainId(11_155_111);
        KeyValueRegistry registry = deployer.deploy(Deploy.Config({expectedChainId: 11_155_111}));
        assertGt(address(registry).code.length, 0);
        // A fresh deployment is usable immediately: no initialisation step exists.
        registry.add(keccak256("k"), bytes32(uint256(1)));
        assertEq(registry.get(address(this), keccak256("k")), bytes32(uint256(1)));
    }

    function test_deploy_refusesChainMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainIdMismatch.selector, 31_337, 11_155_111));
        deployer.deploy(Deploy.Config({expectedChainId: 11_155_111}));
    }

    function test_deploy_refusesMainnetAndOtherChains() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChainId.selector, 1));
        deployer.deploy(Deploy.Config({expectedChainId: 1}));

        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChainId.selector, 8453));
        deployer.deploy(Deploy.Config({expectedChainId: 8453}));
    }

    function test_deployedRuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public {
        KeyValueRegistry registry = deployer.deploy(Deploy.Config({expectedChainId: 31_337}));
        bytes memory code = address(registry).code;
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j = 0; j < code.length; ++j) {
            uint8 opcode = uint8(code[j]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                j += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
