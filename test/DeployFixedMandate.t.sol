// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployFixedMandate} from "../script/DeployFixedMandate.s.sol";
import {FixedMandate} from "../src/FixedMandate.sol";

contract DeployFixedMandateTest is Test {
    function test_RunDeploysConfiguredFixedMandate() public {
        FixedMandate deployed = new DeployFixedMandate().run();

        assertGt(address(deployed).code.length, 0, "deployment has runtime code");
        (, string memory name, string memory version,, address verifyingContract,,) = deployed.eip712Domain();
        assertEq(name, "FixedMandate", "domain name");
        assertEq(version, "1", "domain version");
        assertEq(verifyingContract, address(deployed), "domain verifying contract");
    }
}
