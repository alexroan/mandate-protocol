// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {FixedMandate} from "../src/FixedMandate.sol";
import {console} from "forge-std/console.sol";

contract DeployFixedMandate is Script {
    bytes32 public constant MANDATE_SALT = keccak256("MANDATE");

    function run() external returns (FixedMandate mandate) {
        address predictedAddress = vm.computeCreate2Address(MANDATE_SALT, keccak256(type(FixedMandate).creationCode));

        vm.startBroadcast();
        if (predictedAddress.code.length == 0) {
            mandate = new FixedMandate{salt: MANDATE_SALT}();
        } else {
            mandate = FixedMandate(predictedAddress);
        }
        require(predictedAddress == address(mandate), "Deployment failed");
        console.log("Deployed mandate to", address(mandate));
        vm.stopBroadcast();
    }
}
