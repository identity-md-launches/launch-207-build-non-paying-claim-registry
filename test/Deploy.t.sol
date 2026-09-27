// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ClaimRegistry} from "../src/ClaimRegistry.sol";

/// @notice Exercises the deploy script's configuration logic without touching the environment.
contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function test_deploysWithDemoRootLocally() public {
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 31_337, merkleRoot: deployer.DEMO_ROOT()});
        ClaimRegistry r = deployer.deployRegistry(cfg);
        assertEq(r.merkleRoot(), deployer.DEMO_ROOT());
        assertEq(r.claimCount(), 0);
    }

    function test_zeroExpectedChainMeansLocalDryRun() public {
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 0, merkleRoot: bytes32(uint256(1))});
        ClaimRegistry r = deployer.deployRegistry(cfg);
        assertEq(r.merkleRoot(), bytes32(uint256(1)));
    }

    function test_deploysOnSepoliaChainId() public {
        vm.chainId(11_155_111);
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 11_155_111, merkleRoot: deployer.DEMO_ROOT()});
        ClaimRegistry r = deployer.deployRegistry(cfg);
        assertEq(r.merkleRoot(), deployer.DEMO_ROOT());
    }

    function test_refusesMainnet() public {
        vm.chainId(1);
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 1, merkleRoot: deployer.DEMO_ROOT()});
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        deployer.deployRegistry(cfg);
    }

    function test_refusesChainMismatch() public {
        // Expecting Sepolia while connected to a local chain.
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 11_155_111, merkleRoot: deployer.DEMO_ROOT()});
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainIdMismatch.selector, 11_155_111, 31_337));
        deployer.deployRegistry(cfg);
    }

    function test_refusesZeroRoot() public {
        Deploy.Config memory cfg = Deploy.Config({expectedChainId: 31_337, merkleRoot: bytes32(0)});
        vm.expectRevert(Deploy.EmptyRoot.selector);
        deployer.deployRegistry(cfg);
    }

    function testFuzz_onlyLocalAndSepoliaAccepted(uint256 expected) public {
        vm.assume(expected != 0 && expected != 31_337 && expected != 11_155_111);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, expected));
        deployer.checkChain(expected, expected);
    }
}
