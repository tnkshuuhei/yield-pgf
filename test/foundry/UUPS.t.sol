// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UUPS } from "../../contracts/UUPS.sol";

/// @custom:oz-upgrades-from UUPS
contract UUPSV2 is UUPS {
    function version() public pure override returns (string memory) {
        return "v2.0.0";
    }
}

contract UUPSTest is Test {
    address currentPrankee;
    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address pauser = makeAddr("pauser");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    UUPS public uups;
    address proxy;

    event CredentialGranted(address indexed account, uint256 amount);
    event CredentialBurned(address indexed account, uint256 amount);

    function setUp() public {
        // deploy UUPS proxy and initialize the contract
        proxy = Upgrades.deployUUPSProxy("UUPS.sol", abi.encodeCall(UUPS.initialize, (admin, pauser, minter)));

        uups = UUPS(proxy);
    }

    function testInitializations() external view {
        assertEq(uups.name(), "ERC20");
        assertEq(uups.symbol(), "TOKEN");
        assertEq(uups.decimals(), 18);
    }

    function testUpgrade() external {
        assertEq(uups.version(), "v1.0.0");

        vm.startPrank(admin);
        Upgrades.upgradeProxy(proxy, "out/UUPS.t.sol/UUPSV2.json", "");
        vm.stopPrank();

        assertEq(uups.version(), "v2.0.0");
    }

    function testVersion() external view {
        assertEq(uups.version(), "v1.0.0");
    }

    modifier prankception(address prankee) {
        address prankBefore = currentPrankee;
        vm.stopPrank();
        vm.startPrank(prankee);
        _;
        vm.stopPrank();
        if (prankBefore != address(0)) {
            vm.startPrank(prankBefore);
        }
    }
}
