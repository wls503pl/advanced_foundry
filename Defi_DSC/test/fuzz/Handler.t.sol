// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DSC} from "../../src/DSC.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title Handler - Guides fuzzing with validated operations
/// @dev Controls fuzzing inputs to generate realistic test scenarios
contract Handler is Test {
    // ============ State Variables ============

    DSCEngine dscEngine;
    DSC dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    /// @dev Maximum collateral deposit amount
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    /// @dev Fixed user address for all operations
    address USER = address(1);

    // ============ Constructor ============

    /// @dev Initialize with DSC protocol contracts and fetch collateral tokens
    constructor(DSCEngine _dscEngine, DSC _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    // ============ Main Functions ============

    /// @dev Deposit collateral with bounded parameters
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // Bound amount between 1 and MAX_DEPOSIT_SIZE
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        
        vm.startPrank(USER);
        collateral.mint(USER, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    /// @dev Mint DSC with collateral validation
    function mintDsc(uint256 amountDscToMint) public {
        // Get current DSC minted and available collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        
        // Calculate max mintable: (collateral value / 2) - already minted
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        
        // Skip if no available capacity
        if (maxDscToMint < 0) {
            return;
        }
        
        // Bound amount to available capacity
        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        
        // Skip if amount is zero
        if (amountDscToMint == 0) {
            return;
        }
        
        vm.prank(USER);
        dscEngine.mintDsc(amountDscToMint);
    }

    /// @dev Redeem collateral with balance validation
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // Get available collateral balance in protocol
        uint256 maxCollateralToRedeem = collateral.balanceOf(address(dscEngine));
        
        // Skip if no collateral available
        if (maxCollateralToRedeem == 0) {
            return;
        }
        
        // Bound amount to available balance
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);
        
        vm.prank(USER);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    /// @dev Burn DSC with balance validation
    function burnDsc(uint256 amountDsc) public {
        // Get user's DSC balance
        uint256 userBalance = dsc.balanceOf(USER);
        
        // Skip if no balance to burn
        if (userBalance == 0) {
            return;
        }
        
        // Bound amount to available balance
        amountDsc = bound(amountDsc, 1, userBalance);
        
        vm.prank(USER);
        dsc.approve(address(dscEngine), amountDsc);
        dscEngine.burnDsc(amountDsc);
    }

    // ============ Helper Functions ============

    /// @dev Select collateral token: even seed = WETH, odd seed = WBTC
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}