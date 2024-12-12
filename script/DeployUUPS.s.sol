// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { BaseScript } from "./Base.s.sol";
import { UUPS } from "../contracts/UUPS.sol";

contract DeployUUPS is BaseScript {
    function run() public broadcast {
        address admin;
        address minter;
        address pauser;

        console.log("Deploying UUPS contract...");
        address proxy = Upgrades.deployUUPSProxy("UUPS.sol", abi.encodeCall(UUPS.initialize, (admin, pauser, minter)));
        UUPS uups = UUPS(proxy);
        console.log("implementation deployed at:", proxy);
        console.log("proxy deployed at:", address(uups));
    }
}
