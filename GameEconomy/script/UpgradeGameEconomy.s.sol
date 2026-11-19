// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title UpgradeGameEconomy
/// @notice Upgrades the existing GameEconomy proxy to GameEconomyV2.
/// @dev The OpenZeppelin Upgrades plugin compares the storage layout of V2 against
///      V1 (via `@custom:oz-upgrades-from GameEconomy`) before upgrading.
///      The sender must hold UPGRADER_ROLE.
contract UpgradeGameEconomy is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("Old implementation:", Upgrades.getImplementationAddress(proxy));

        vm.startBroadcast(deployer);
        // GE-10: deploy V2 implementation and point the proxy to it (state is kept)
        Upgrades.upgradeProxy(proxy, "GameEconomyV2.sol", "");
        vm.stopBroadcast();

        console.log("Proxy:             ", proxy);
        console.log("New implementation:", Upgrades.getImplementationAddress(proxy));
    }
}
