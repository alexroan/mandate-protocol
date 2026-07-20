// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {FixedMandateExecutor} from "../src/FixedMandateExecutor.sol";

contract DeployFixedMandateExecutor is Script {
    function run() external returns (FixedMandateExecutor executor) {
        vm.startBroadcast();
        executor = new FixedMandateExecutor();
        vm.stopBroadcast();
    }
}
