// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author Peile Wu
 * @notice Core contract of the DSC system handling minting, redeeming, collateral management and liquidation
 * 
 * The system maintains a 1:1 peg to USD with the following properties:
 * - Exogenous Collateral (wETH & wBTC)
 * - Dollar Pegged
 * - Algorithmically Stabilized
 * 
 * Similar to DAI: no governance, no fees, backed only by wBTC and wETH.
 * 
 * @dev The DSC system MUST always be overcollateralized. 
 * The total value of all collateral must always exceed the total value of all minted DSC.
 */
contract DSCEngine {
    
    /**
     * @notice Deposits collateral and mints DSC in a single transaction
     * @dev Combines depositCollateral() and mintDsc() for gas efficiency
     * User deposits wETH/wBTC and receives newly minted DSC based on collateralization ratio
     */
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice Deposits collateral to the protocol
     * @dev User deposits wETH or wBTC to increase their collateral balance
     * Can be used to improve health factor or prepare for minting DSC
     */
    function depositCollateral() external {}

    /**
     * @notice Redeems collateral by burning DSC
     * @dev User burns their DSC tokens and receives back their collateral (wETH/wBTC)
     * The amount of collateral returned depends on current collateralization ratio
     */
    function redeemCollateralForDsc() external {}

    /**
     * @notice Withdraws collateral from the protocol
     * @dev User withdraws wETH/wBTC collateral if health factor remains above minimum threshold
     * Cannot withdraw if it would make position undercollateralized
     */
    function redeemCollateral() external {}

    /**
     * @notice Mints DSC tokens against deposited collateral
     * @dev Creates new DSC tokens for the user based on their collateral value
     * Requires sufficient collateral to maintain overcollateralization ratio
     */
    function mintDsc() external {}

    /**
     * @notice Burns DSC tokens to reduce debt
     * @dev Destroys DSC tokens to decrease user's minted DSC balance
     * Improves health factor and frees up collateral for withdrawal
     */
    function burnDsc() external {}

    /**
     * @notice Liquidates an undercollateralized position
     * @dev Anyone can liquidate a position when health factor falls below minimum threshold
     * Liquidator pays off part/all of the debt and receives collateral at a discount
     * Incentivizes maintaining system overcollateralization
     */
    function liquidate() external {}

    /**
     * @notice Returns the health factor of a position
     * @dev Health Factor = (Collateral Value * Liquidation Threshold) / Total DSC Minted
     * 
     * Health Factor > 1: Position is healthy (safe)
     * Health Factor = 1: Position is at liquidation threshold
     * Health Factor < 1: Position is undercollateralized (can be liquidated)
     * 
     * Example: If liquidation threshold is 50%
     * - $200 collateral, $100 DSC minted → Health Factor = (200 * 0.5) / 100 = 1.0
     * - $200 collateral, $80 DSC minted → Health Factor = (200 * 0.5) / 80 = 1.25 (healthy)
     * - $200 collateral, $120 DSC minted → Health Factor = (200 * 0.5) / 120 = 0.83 (liquidatable)
     */
    function getHealthFactor() external view {}
}