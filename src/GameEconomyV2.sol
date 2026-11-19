// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GameEconomy} from "./GameEconomy.sol";

/// @title GameEconomyV2 – Adds batch material purchases
/// @author Adrian (thuisdev)
/// @notice Same game economy as V1, plus buying several materials in one transaction.
/// @dev Inherits V1 so the storage layout is identical. Adds NO new state variables
///      (constants live in bytecode, not storage), so all V1 state stays untouched.
///      No initializer needed: the proxy was already initialized by V1 and V2
///      adds no new state variables.
/// @custom:oz-upgrades-from GameEconomy
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract GameEconomyV2 is GameEconomy {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    // GE-9 / GE-10: bounds the batch loop so it can never grow unbounded
    /// @notice Maximum number of entries in one batch purchase.
    uint256 public constant MAX_BATCH_SIZE = 10;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a user buys several materials in one transaction.
    /// @param buyer       Address that bought the materials.
    /// @param materialIds IDs of the purchased materials.
    /// @param amounts     Number of units per material.
    /// @param totalCost   Total currency units burned (single burn).
    event MaterialsBatchPurchased(address indexed buyer, uint256[] materialIds, uint256[] amounts, uint256 totalCost);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a batch is empty, larger than MAX_BATCH_SIZE or has mismatched arrays.
    error InvalidBatch();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs the V1 constructor, which locks this implementation (_disableInitializers).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() GameEconomy() {}

    // ─────────────────────────────────────────────────────────────────────────
    // External – state-changing
    // ─────────────────────────────────────────────────────────────────────────

    // GE-10: Buy multiple materials in one transaction with a single currency burn
    /// @notice Buy several materials at once, paying the total in currency.
    /// @dev Emits MaterialsBatchPurchased. Sums the cost of all entries, burns that total
    ///      once and mints all materials with one `_mintBatch`. Reverts if paused, if the
    ///      batch is empty, too large or has mismatched arrays, if an amount is zero, if a
    ///      material has no price or if the caller's currency balance is too low.
    ///      The loop is bounded by MAX_BATCH_SIZE (GE-9).
    /// @param materialIds IDs of the materials to buy.
    /// @param amounts     Number of units per material (same index as `materialIds`).
    /// @return totalCost  Total currency units burned.
    function buyMaterialsBatch(uint256[] calldata materialIds, uint256[] calldata amounts)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 totalCost)
    {
        // CHECKS
        uint256 length = materialIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE || length != amounts.length) {
            revert InvalidBatch();
        }

        for (uint256 i = 0; i < length;) {
            uint256 amount = amounts[i];
            if (amount == 0) {
                revert ZeroAmount();
            }

            uint256 price = materialPrice[materialIds[i]];
            if (price == 0) {
                revert InvalidMaterial(materialIds[i]);
            }

            totalCost += amount * price;

            // Safe: i < length <= MAX_BATCH_SIZE
            unchecked {
                ++i;
            }
        }

        uint256 available = balanceOf(msg.sender, CURRENCY_ID);
        if (available < totalCost) {
            revert InsufficientBalance(available, totalCost);
        }

        // EFFECTS
        _burn(msg.sender, CURRENCY_ID, totalCost);

        // INTERACTIONS
        _mintBatch(msg.sender, materialIds, amounts, "");

        emit MaterialsBatchPurchased(msg.sender, materialIds, amounts, totalCost);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // External – pure
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the implementation version, useful to confirm an upgrade on-chain.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "2";
    }
}
