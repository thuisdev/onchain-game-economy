// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {GameEconomy} from "../src/GameEconomy.sol";
import {GameEconomyV2} from "../src/GameEconomyV2.sol";

/// @title GameEconomyTest
/// @notice Tests the V1 game economy behind a UUPS proxy.
/// @dev Setup: wood (ID 1, price 5) and iron (ID 2, price 10) are priced,
///      active recipe = 2 wood + 3 iron (costs 40 currency in total).
contract GameEconomyTest is Test {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 private constant CURRENCY_PRICE = 0.01 ether;
    string private constant BASE_URI = "https://example.com/api/item/{id}.json";

    uint256 private constant WOOD = 1;
    uint256 private constant IRON = 2;
    uint256 private constant WOOD_PRICE = 5;
    uint256 private constant IRON_PRICE = 10;

    uint256 private constant RECIPE_WOOD = 2;
    uint256 private constant RECIPE_IRON = 3;
    uint256 private constant RECIPE_COST = RECIPE_WOOD * WOOD_PRICE + RECIPE_IRON * IRON_PRICE; // 40

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address private _admin = makeAddr("admin");
    address private _pauser = makeAddr("pauser");
    address private _upgrader = makeAddr("upgrader");
    address private _gameAdmin = makeAddr("gameAdmin");
    address private _player = makeAddr("player");

    GameEconomy private _gameEconomy;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploys the implementation, puts it behind an ERC1967 (UUPS) proxy and
    ///      calls `initialize` through the proxy in the same transaction.
    function setUp() public {
        GameEconomy implementation = new GameEconomy();
        bytes memory initData =
            abi.encodeCall(GameEconomy.initialize, (_admin, _pauser, _upgrader, _gameAdmin, BASE_URI, CURRENCY_PRICE));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        _gameEconomy = GameEconomy(address(proxy));

        vm.startPrank(_gameAdmin);
        _gameEconomy.setMaterialPrice(WOOD, WOOD_PRICE);
        _gameEconomy.setMaterialPrice(IRON, IRON_PRICE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = WOOD;
        ids[1] = IRON;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = RECIPE_WOOD;
        amounts[1] = RECIPE_IRON;
        _gameEconomy.setRecipe(ids, amounts);
        vm.stopPrank();

        vm.deal(_player, 10 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core flows
    // ─────────────────────────────────────────────────────────────────────────

    function test_buyMaterial_withCurrency_mintsCorrectMaterials() public {
        _buyCurrency(_player, 20);

        vm.prank(_player);
        _gameEconomy.buyMaterial(WOOD, 4); // 4 * 5 = 20 currency

        assertEq(_gameEconomy.balanceOf(_player, WOOD), 4, "wood not minted");
        assertEq(_gameEconomy.balanceOf(_player, _gameEconomy.CURRENCY_ID()), 0, "currency not burned");
    }

    function test_craft_withMaterials_burnsRecipeAndMintsUniqueItem() public {
        _buyRecipeMaterials(_player);
        uint256 firstUniqueId = _gameEconomy.FIRST_UNIQUE_ID();

        vm.prank(_player);
        uint256 itemId = _gameEconomy.craft();

        // materials burnd
        assertEq(_gameEconomy.balanceOf(_player, WOOD), 0, "wood not burned");
        assertEq(_gameEconomy.balanceOf(_player, IRON), 0, "iron not burned");

        // unique item minted with supply 1
        assertEq(itemId, firstUniqueId, "wrong item id");
        assertEq(_gameEconomy.balanceOf(_player, itemId), 1, "item not minted");
        assertEq(_gameEconomy.totalSupply(itemId), 1, "item supply not 1");

        // counter moved on, so the ID is never reused
        assertEq(_gameEconomy.nextUniqueId(), firstUniqueId + 1, "counter not incremented");
    }

    function test_pause_blocksPurchasesAndCrafting() public {
        _buyRecipeMaterials(_player);

        vm.prank(_pauser);
        _gameEconomy.pause();

        vm.startPrank(_player);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _gameEconomy.buyCurrency{value: CURRENCY_PRICE}(1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _gameEconomy.buyMaterial(WOOD, 1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _gameEconomy.craft();
        vm.stopPrank();
    }

    function test_endToEnd_buyCurrency_buyMaterials_craft() public {
        uint256 currencyId = _gameEconomy.CURRENCY_ID();

        // 1. buy currency with ETH
        vm.startPrank(_player);
        _gameEconomy.buyCurrency{value: RECIPE_COST * CURRENCY_PRICE}(RECIPE_COST);
        assertEq(_gameEconomy.balanceOf(_player, currencyId), RECIPE_COST, "currency not minted");
        assertEq(address(_gameEconomy).balance, RECIPE_COST * CURRENCY_PRICE, "ETH not in contract");

        // 2. buy wood (2 * 5 = 10 currency)
        _gameEconomy.buyMaterial(WOOD, RECIPE_WOOD);
        assertEq(_gameEconomy.balanceOf(_player, WOOD), RECIPE_WOOD, "wood not minted");
        assertEq(
            _gameEconomy.balanceOf(_player, currencyId),
            RECIPE_COST - RECIPE_WOOD * WOOD_PRICE,
            "wrong currency after wood"
        );

        // 3. buy iron (3 * 10 = 30 currency)
        _gameEconomy.buyMaterial(IRON, RECIPE_IRON);
        assertEq(_gameEconomy.balanceOf(_player, IRON), RECIPE_IRON, "iron not minted");
        assertEq(_gameEconomy.balanceOf(_player, currencyId), 0, "currency not fully spent");

        // 4. craft
        uint256 itemId = _gameEconomy.craft();
        vm.stopPrank();

        assertEq(_gameEconomy.balanceOf(_player, WOOD), 0, "wood not burned");
        assertEq(_gameEconomy.balanceOf(_player, IRON), 0, "iron not burned");
        assertEq(_gameEconomy.balanceOf(_player, itemId), 1, "item not minted");
    }

    function test_upgrade_toV2_preservesState() public {
        // build up some V1 state
        _buyRecipeMaterials(_player);
        vm.prank(_player);
        uint256 itemId = _gameEconomy.craft();

        // upgrade
        GameEconomyV2 implementationV2 = new GameEconomyV2();
        vm.prank(_upgrader);
        _gameEconomy.upgradeToAndCall(address(implementationV2), "");
        GameEconomyV2 gameV2 = GameEconomyV2(address(_gameEconomy));

        // state is still there
        assertEq(gameV2.version(), "2", "not upgraded");
        assertEq(gameV2.balanceOf(_player, itemId), 1, "item lost");
        assertEq(gameV2.materialPrice(WOOD), WOOD_PRICE, "price lost");
        assertEq(gameV2.nextUniqueId(), itemId + 1, "counter lost");
        assertEq(gameV2.currencyPrice(), CURRENCY_PRICE, "currency price lost");
        (uint256[] memory ids, uint256[] memory amounts) = gameV2.getRecipe();
        assertEq(ids.length, 2, "recipe lost");
        assertEq(amounts[1], RECIPE_IRON, "recipe amounts lost");
    }

    function test_v2_buyMaterialsBatch_mintsAllMaterials() public {
        GameEconomyV2 implementationV2 = new GameEconomyV2();
        vm.prank(_upgrader);
        _gameEconomy.upgradeToAndCall(address(implementationV2), "");
        GameEconomyV2 gameV2 = GameEconomyV2(address(_gameEconomy));

        _buyCurrency(_player, RECIPE_COST);

        uint256[] memory ids = new uint256[](2);
        ids[0] = WOOD;
        ids[1] = IRON;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = RECIPE_WOOD;
        amounts[1] = RECIPE_IRON;

        vm.prank(_player);
        uint256 totalCost = gameV2.buyMaterialsBatch(ids, amounts);

        assertEq(totalCost, RECIPE_COST, "wrong total cost");
        assertEq(gameV2.balanceOf(_player, WOOD), RECIPE_WOOD, "wood not minted");
        assertEq(gameV2.balanceOf(_player, IRON), RECIPE_IRON, "iron not minted");
        assertEq(gameV2.balanceOf(_player, gameV2.CURRENCY_ID()), 0, "currency not burned");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Edge cases
    // ─────────────────────────────────────────────────────────────────────────

    function test_buyCurrency_wrongPayment_revertsIncorrectPayment() public {
        vm.prank(_player);
        vm.expectRevert(abi.encodeWithSelector(GameEconomy.IncorrectPayment.selector, CURRENCY_PRICE, 1));
        _gameEconomy.buyCurrency{value: 1}(1);
    }

    function test_setMaterialPrice_nonGameAdmin_reverts() public {
        // Read the role BEFORE vm.prank – otherwise this call would consume the prank.
        bytes32 role = _gameEconomy.GAME_ADMIN_ROLE();

        vm.prank(_player);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _player, role));
        _gameEconomy.setMaterialPrice(3, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Buys `amount` currency for `buyer`, paying the exact ETH price.
    function _buyCurrency(address buyer, uint256 amount) private {
        vm.prank(buyer);
        _gameEconomy.buyCurrency{value: amount * CURRENCY_PRICE}(amount);
    }

    /// @dev Gives `buyer` exactly the materials of the active recipe (2 wood + 3 iron).
    function _buyRecipeMaterials(address buyer) private {
        _buyCurrency(buyer, RECIPE_COST);

        vm.startPrank(buyer);
        _gameEconomy.buyMaterial(WOOD, RECIPE_WOOD);
        _gameEconomy.buyMaterial(IRON, RECIPE_IRON);
        vm.stopPrank();
    }
}
