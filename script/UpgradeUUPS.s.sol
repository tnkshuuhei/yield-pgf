// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { BaseScript } from "./Base.s.sol";

contract UpgradeScript is BaseScript {
    function run() public broadcast {
        address proxy;

        Upgrades.upgradeProxy(proxy, "UUPSV2.sol", "");
    }
}
