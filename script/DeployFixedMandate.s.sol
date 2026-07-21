// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {FixedMandate} from "../src/FixedMandate.sol";

contract DeployFixedMandate is Script {
    function run() external returns (FixedMandate executor) {
        vm.startBroadcast();
        executor = new FixedMandate();
        vm.stopBroadcast();
    }
}
