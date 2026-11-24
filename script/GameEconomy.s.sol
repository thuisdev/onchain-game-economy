// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GameEconomy} from "../src/GameEconomy.sol";

/// @title DeployGameEconomy
/// @notice Deploys GameEconomy V1 behind a UUPS proxy and sets up materials and a recipe.
/// @dev The OpenZeppelin Upgrades plugin validates the implementation (constructor,
///      initializer, storage layout) before deploying. All roles go to the deployer
///      for the testnet deployment.
contract DeployGameEconomy is Script {
    uint256 private constant CURRENCY_PRICE = 0.0001 ether;
    string private constant BASE_URI = "https://example.com/api/item/{id}.json";

    uint256 private constant WOOD = 1;
    uint256 private constant IRON = 2;

    function run() external returns (address proxy) {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        vm.startBroadcast(deployer);

        // Deploy implementation + UUPS proxy and call initialize once
        proxy = Upgrades.deployUUPSProxy(
            "GameEconomy.sol",
            abi.encodeCall(GameEconomy.initialize, (deployer, deployer, deployer, deployer, BASE_URI, CURRENCY_PRICE))
        );

        GameEconomy game = GameEconomy(proxy);

        // Material prices in currency units
        game.setMaterialPrice(WOOD, 5);
        game.setMaterialPrice(IRON, 10);

        // Recipe = 2 wood + 3 iron
        uint256[] memory ids = new uint256[](2);
        ids[0] = WOOD;
        ids[1] = IRON;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2;
        amounts[1] = 3;
        game.setRecipe(ids, amounts);

        vm.stopBroadcast();

        console.log("Proxy:         ", proxy);
        console.log("Implementation:", Upgrades.getImplementationAddress(proxy));
    }
}
