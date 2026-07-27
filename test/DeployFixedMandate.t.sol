// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployFixedMandate} from "../script/DeployFixedMandate.s.sol";
import {FixedMandate} from "../src/FixedMandate.sol";

contract DeployFixedMandateTest is Test {
    DeployFixedMandate internal script;

    function setUp() public {
        script = new DeployFixedMandate();
    }

    function test_RunDeploysFixedMandateAtPredictedCreate2Address() public {
        address predicted = vm.computeCreate2Address(script.MANDATE_SALT(), keccak256(type(FixedMandate).creationCode));

        FixedMandate deployed = script.run();

        assertEq(address(deployed), predicted, "CREATE2 deployment address");
        assertGt(address(deployed).code.length, 0, "deployment has runtime code");
        (, string memory name, string memory version,, address verifyingContract,,) = deployed.eip712Domain();
        assertEq(name, "FixedMandate", "domain name");
        assertEq(version, "1", "domain version");
        assertEq(verifyingContract, address(deployed), "domain verifying contract");
    }

    function test_RunIsIdempotent() public {
        FixedMandate firstDeployment = script.run();
        FixedMandate secondDeployment = script.run();

        assertEq(address(secondDeployment), address(firstDeployment), "same deployment address");
        assertGt(address(secondDeployment).code.length, 0, "deployment retains runtime code");
    }
}
