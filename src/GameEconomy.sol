// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    ERC1155SupplyUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title GameEconomy – Upgradeable ERC-1155 game economy
/// @author Adrian (thuisdev)
/// @notice Users buy in-game currency with ETH, spend it on materials and burn
///         materials to craft unique items.
/// @dev UUPS upgradeable (OpenZeppelin v5). Token ID ranges:
///      - 0                 = fungible currency
///      - 1 .. 999_999      = fungible materials
///      - >= 1_000_000      = unique crafted items (supply 1, never reused)
///      All value flows follow checks-effects-interactions and use nonReentrant.
contract GameEconomy is
    Initializable,
    ERC1155Upgradeable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Role allowed to pause and unpause the game.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role allowed to upgrade the implementation behind the proxy.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Role allowed to manage material prices and recipes.
    bytes32 public constant GAME_ADMIN_ROLE = keccak256("GAME_ADMIN_ROLE");

    // Currency ID 0, material IDs start at 1, crafted items start at FIRST_UNIQUE_ID
    /// @notice Token ID of the fungible in-game currency.
    uint256 public constant CURRENCY_ID = 0;

    /// @notice First token ID used for crafted items. Material IDs must be below this value.
    uint256 public constant FIRST_UNIQUE_ID = 1_000_000;

    // Bounds the number of materials per recipe so crafting never loops unbounded
    /// @notice Maximum number of different materials a recipe can require.
    uint256 public constant MAX_RECIPE_SIZE = 5;

    // ─────────────────────────────────────────────────────────────────────────
    // State Variables (order must never change – append only in future versions)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Price of one currency unit in wei.
    uint256 public currencyPrice;

    // Material prices in currency units
    /// @notice Price of one unit of a material, denominated in currency units.
    /// @dev A price of 0 means the material does not exist.
    mapping(uint256 materialId => uint256 price) public materialPrice;

    // Active recipe stored as two parallel arrays (index i = material + amount)
    /// @dev Material IDs required by the active recipe.
    uint256[] private _recipeMaterialIds;

    /// @dev Required amount per material; same index as `_recipeMaterialIds`.
    uint256[] private _recipeAmounts;

    /// @notice Token ID that will be assigned to the next crafted item.
    uint256 public nextUniqueId;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a user buys currency with ETH.
    /// @param buyer  Address that bought the currency.
    /// @param amount Number of currency units minted.
    /// @param paid   ETH paid in wei.
    event CurrencyBought(address indexed buyer, uint256 amount, uint256 paid);

    /// @notice Emitted when the admin withdraws ETH from the contract.
    /// @param to     Recipient of the ETH.
    /// @param amount ETH withdrawn in wei.
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when a material price is set or updated.
    /// @param materialId ID of the material.
    /// @param price      New price in currency units.
    event MaterialPriceSet(uint256 indexed materialId, uint256 price);

    /// @notice Emitted when a user buys materials with currency.
    /// @param buyer      Address that bought the materials.
    /// @param materialId ID of the purchased material.
    /// @param amount     Number of material units minted.
    /// @param cost       Currency units burned.
    event MaterialPurchased(address indexed buyer, uint256 indexed materialId, uint256 amount, uint256 cost);

    /// @notice Emitted when the active recipe is replaced.
    /// @param materialIds Material IDs required by the new recipe.
    /// @param amounts     Required amount per material.
    event RecipeSet(uint256[] materialIds, uint256[] amounts);

    /// @notice Emitted when a user crafts a unique item.
    /// @param crafter Address that crafted the item.
    /// @param itemId  Token ID of the newly minted item.
    event Crafted(address indexed crafter, uint256 indexed itemId);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when an amount or price of zero is passed.
    error ZeroAmount();

    /// @notice Thrown when the zero address is passed where a real address is required.
    error ZeroAddress();

    /// @notice Thrown when the ETH sent does not match the required payment.
    /// @param expected ETH required in wei.
    /// @param received ETH actually sent in wei.
    error IncorrectPayment(uint256 expected, uint256 received);

    /// @notice Thrown when a balance is too low for the requested operation.
    /// @param available The balance that is actually available.
    /// @param requested The amount that was requested.
    error InsufficientBalance(uint256 available, uint256 requested);

    /// @notice Thrown when an ID is not a valid, priced material.
    /// @param id The invalid material ID.
    error InvalidMaterial(uint256 id);

    /// @notice Thrown when a recipe is empty, too large, has mismatched arrays or zero amounts.
    error InvalidRecipe();

    /// @notice Thrown when crafting is attempted before a recipe has been set.
    error NoActiveRecipe();

    /// @notice Thrown when an ETH transfer fails.
    error TransferFailed();

    /// @notice Thrown when trying to craft a unique item, that has already been crafted.
    /// @param itemId The unqique itemId.
    error ItemIdAlreadyUsed(uint256 itemId);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Locks the implementation contract so it can never be initialized directly.
    ///      State is only ever set on the proxy via `initialize`.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // External – initializer
    // ─────────────────────────────────────────────────────────────────────────

    // Initialize once – roles, base URI, currency price and first crafted ID
    /// @notice Initializes the game economy behind the proxy. Can only be called once.
    /// @dev Replaces the constructor for upgradeable contracts. Reverts with ZeroAddress
    ///      if any role address is zero and with ZeroAmount if the currency price is zero.
    /// @param defaultAdmin   Receives DEFAULT_ADMIN_ROLE (can grant/revoke roles and withdraw ETH).
    /// @param pauser         Receives PAUSER_ROLE.
    /// @param upgrader       Receives UPGRADER_ROLE.
    /// @param gameAdmin      Receives GAME_ADMIN_ROLE.
    /// @param baseUri_       Metadata URI for all tokens, using the ERC-1155 `{id}` placeholder.
    /// @param currencyPrice_ Price of one currency unit in wei.
    function initialize(
        address defaultAdmin,
        address pauser,
        address upgrader,
        address gameAdmin,
        string memory baseUri_,
        uint256 currencyPrice_
    ) external initializer {
        if (defaultAdmin == address(0) || pauser == address(0) || upgrader == address(0) || gameAdmin == address(0)) {
            revert ZeroAddress();
        }

        if (currencyPrice_ == 0) {
            revert ZeroAmount();
        }

        __ERC1155_init(baseUri_);
        __AccessControl_init();
        __ERC1155Supply_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(GAME_ADMIN_ROLE, gameAdmin);

        currencyPrice = currencyPrice_;
        nextUniqueId = FIRST_UNIQUE_ID;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // External – payable
    // ─────────────────────────────────────────────────────────────────────────

    // Fixed-price ETH sale – mints currency ID 0, ETH stays in the contract
    /// @notice Buy in-game currency with ETH at the fixed `currencyPrice`.
    /// @dev Emits CurrencyBought. Reverts if paused, if `amount` is zero or if
    ///      `msg.value` does not equal `amount * currencyPrice`. Minting triggers the
    ///      ERC-1155 receiver hook, so the function is protected by nonReentrant.
    /// @param amount Number of currency units to buy.
    function buyCurrency(uint256 amount) external payable nonReentrant whenNotPaused {
        // CHECKS
        _checkZeroAmount(amount);

        uint256 expectedPayment = amount * currencyPrice;

        if (msg.value != expectedPayment) {
            revert IncorrectPayment(expectedPayment, msg.value);
        }

        // INTERACTIONS
        _mint(msg.sender, CURRENCY_ID, amount, "");

        emit CurrencyBought(msg.sender, amount, msg.value);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // External – state-changing
    // ─────────────────────────────────────────────────────────────────────────

    // Admin ETH withdrawal (CEI, nonReentrant, not paused)
    /// @notice Withdraw ETH collected from currency sales.
    /// @dev Emits Withdrawn. Only DEFAULT_ADMIN_ROLE. Reverts if paused, if `to` is the
    ///      zero address, if `amount` is zero, if the contract balance is too low or if
    ///      the ETH transfer fails.
    /// @param to     Recipient of the ETH.
    /// @param amount ETH to withdraw in wei.
    function withdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        // CHECKS
        _checkZeroAmount(amount);

        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 available = address(this).balance;
        if (amount > available) {
            revert InsufficientBalance(available, amount);
        }

        // INTERACTIONS
        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Withdrawn(to, amount);
    }

    // Role-gated material price updates
    /// @notice Set or update the currency price of a material.
    /// @dev Emits MaterialPriceSet. Only GAME_ADMIN_ROLE. Reverts with InvalidMaterial if
    ///      `materialId` is 0 or >= FIRST_UNIQUE_ID, and with ZeroAmount if `price` is zero.
    ///      Setting a price is what makes an ID a valid material.
    /// @param materialId ID of the material (1 .. FIRST_UNIQUE_ID - 1).
    /// @param price      Price per unit in currency units.
    function setMaterialPrice(uint256 materialId, uint256 price) external onlyRole(GAME_ADMIN_ROLE) {
        // CHECKS
        _checkMaterialIdRange(materialId);
        _checkZeroAmount(price);

        // EFFECTS
        materialPrice[materialId] = price;

        emit MaterialPriceSet(materialId, price);
    }

    // Burn currency, mint materials
    /// @notice Buy materials by spending in-game currency.
    /// @dev Emits MaterialPurchased. Burns `amount * materialPrice[materialId]` currency
    ///      from the caller and mints `amount` of the material. Reverts if paused, if
    ///      `amount` is zero, if the material is invalid or if the caller's currency
    ///      balance is too low.
    /// @param materialId ID of the material to buy.
    /// @param amount     Number of material units to buy.
    function buyMaterial(uint256 materialId, uint256 amount) external nonReentrant whenNotPaused {
        // CHECKS
        _checkZeroAmount(amount);

        uint256 price = materialPrice[materialId];
        if (price == 0) {
            revert InvalidMaterial(materialId);
        }

        uint256 cost = amount * price;
        uint256 available = balanceOf(msg.sender, CURRENCY_ID);
        if (available < cost) {
            revert InsufficientBalance(available, cost);
        }

        // EFFECTS
        _burn(msg.sender, CURRENCY_ID, cost);

        // INTERACTIONS (mint triggers the ERC-1155 receiver hook on contracts)
        _mint(msg.sender, materialId, amount, "");

        emit MaterialPurchased(msg.sender, materialId, amount, cost);
    }

    // Role-gated recipe – replaces the single active recipe
    /// @notice Replace the active crafting recipe.
    /// @dev Emits RecipeSet. Only GAME_ADMIN_ROLE. Reverts with InvalidRecipe if the arrays
    ///      are empty, longer than MAX_RECIPE_SIZE, of different length or contain a zero
    ///      amount, and with InvalidMaterial if an ID is not a priced material.
    ///      The loop is bounded by MAX_RECIPE_SIZE.
    /// @param materialIds Material IDs required by the recipe.
    /// @param amounts     Required amount per material (same index as `materialIds`).
    function setRecipe(uint256[] calldata materialIds, uint256[] calldata amounts) external onlyRole(GAME_ADMIN_ROLE) {
        // CHECKS
        uint256 length = materialIds.length;
        if (length == 0 || length > MAX_RECIPE_SIZE || length != amounts.length) {
            revert InvalidRecipe();
        }

        for (uint256 i = 0; i < length;) {
            if (materialPrice[materialIds[i]] == 0) {
                revert InvalidMaterial(materialIds[i]);
            }
            if (amounts[i] == 0) {
                revert InvalidRecipe();
            }
            // Safe: i < length <= MAX_RECIPE_SIZE
            unchecked {
                ++i;
            }
        }

        // EFFECTS
        _recipeMaterialIds = materialIds;
        _recipeAmounts = amounts;

        emit RecipeSet(materialIds, amounts);
    }

    // Burn recipe materials, mint unique item with supply 1
    /// @notice Craft a unique item by burning the materials of the active recipe.
    /// @dev Emits Crafted. Burns all recipe materials in one `_burnBatch` call (reverts if
    ///      the caller lacks any material), mints `nextUniqueId` with supply 1 and
    ///      increments the counter so IDs are never reused. Reverts if paused or if no
    ///      recipe is set.
    /// @return itemId Token ID of the crafted item.
    function craft() external nonReentrant whenNotPaused returns (uint256 itemId) {
        // CHECKS
        if (_recipeMaterialIds.length == 0) {
            revert NoActiveRecipe();
        }

        itemId = nextUniqueId;
        if (exists(itemId)) {
            revert ItemIdAlreadyUsed(itemId);
        }

        // EFFECTS
        nextUniqueId = itemId + 1;
        // reverts if the caller lacks any recipe material
        _burnBatch(msg.sender, _recipeMaterialIds, _recipeAmounts);

        // INTERACTIONS
        _mint(msg.sender, itemId, 1, "");

        emit Crafted(msg.sender, itemId);
    }

    // Role-gated pause
    /// @notice Pause currency purchases, material purchases, crafting and withdrawals.
    /// @dev Only PAUSER_ROLE. Emits Paused (from PausableUpgradeable).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    // Role-gated unpause
    /// @notice Resume all paused game actions.
    /// @dev Only PAUSER_ROLE. Emits Unpaused (from PausableUpgradeable).
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // External – view
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the currently active crafting recipe.
    /// @dev Both arrays are empty if no recipe has been set yet.
    /// @return materialIds Material IDs required by the recipe.
    /// @return amounts     Required amount per material (same index as `materialIds`).
    function getRecipe() external view returns (uint256[] memory materialIds, uint256[] memory amounts) {
        return (_recipeMaterialIds, _recipeAmounts);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public – view
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Checks whether this contract implements a given interface (ERC-165).
    /// @dev Required override because both ERC1155 and AccessControl implement it.
    /// @param interfaceId The 4-byte interface identifier.
    /// @return supported True if the interface is supported.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool supported)
    {
        return super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    // Only UPGRADER_ROLE can upgrade the UUPS proxy
    /// @dev Called by `upgradeToAndCall`. Reverts unless the caller has UPGRADER_ROLE.
    /// @param newImplementation Address of the new implementation (unused, required by UUPS).
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @dev Required override because ERC1155 and ERC1155Supply both implement `_update`.
    ///      ERC1155Supply uses it to track total supply per token ID.
    /// @param from   Sender (zero address on mint).
    /// @param to     Recipient (zero address on burn).
    /// @param ids    Token IDs being moved.
    /// @param values Amounts per token ID.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Upgradeable, ERC1155SupplyUpgradeable)
    {
        super._update(from, to, ids, values);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reverts with InvalidMaterial if `materialId` is outside the material range
    ///      (1 .. FIRST_UNIQUE_ID - 1). Does not check whether a price is set.
    /// @param materialId The ID to check.
    function _checkMaterialIdRange(uint256 materialId) private pure {
        if (materialId == CURRENCY_ID || materialId >= FIRST_UNIQUE_ID) {
            revert InvalidMaterial(materialId);
        }
    }

    /// @dev Reverts with ZeroAmount if `amount` is zero.
    /// @param amount The value to check.
    function _checkZeroAmount(uint256 amount) private pure {
        if (amount == 0) {
            revert ZeroAmount();
        }
    }
}
