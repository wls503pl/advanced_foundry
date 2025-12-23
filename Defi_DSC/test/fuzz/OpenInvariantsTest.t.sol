// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title Invariant Testing - Property-based fuzzing for DSC Protocol
/// @dev Tests that core protocol properties hold true under all conditions

/// @notice Invariants being tested:
/// 1. Total DSC supply must always be less than total collateral value
/// 2. Getter view functions should never revert (evergreen invariant)

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DSC} from "../../src/DSC.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title OpenInvariantsTest - Open fuzzing test contract (comparison baseline)
/// @dev Directly targets DSCEngine without Handler - generates ~100% revert rate
/// @notice For comparison with InvariantsTest - demonstrates why Handler is necessary
contract OpenInvariantsTest is StdInvariant, Test {
    // ============ State Variables ============

    DeployDSC deployer;
    DSCEngine dscEngine;
    DSC dsc;
    HelperConfig helperConfig;
    address wETH;
    address wBTC;

    // ============ Setup ============

    /// @dev Initialize test environment with open fuzzing
    function setUp() external {
        // Deploy DSC protocol
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        // Get collateral token addresses
        (,, wETH, wBTC,) = helperConfig.activeNetworkConfig();
        // Target DSCEngine directly for open fuzzing
        // Warning: This generates mostly invalid random parameters with high revert rates
        targetContract(address(dscEngine));
    }

    // ============ Invariant Tests ============

    /// @dev Invariant: Protocol collateral value >= total DSC supply
    /// @notice Core security property - ensures all minted DSC is fully backed
    /// @dev This test has limited value due to open fuzzing approach
    function invariant_protocolMustHaveMoreValueThanTotalSupply_open() public view {
        // Get total circulating DSC
        uint256 totalSupply = dsc.totalSupply();
        // Get total WETH deposited in protocol
        uint256 totalwETHDeposited = IERC20(wETH).balanceOf(address(dscEngine));
        // Get total WBTC deposited in protocol
        uint256 totalwBTCDeposited = IERC20(wBTC).balanceOf(address(dscEngine));

        // Convert WETH amount to USD value
        uint256 wETHValue = dscEngine.getUsdValue(wETH, totalwETHDeposited);
        // Convert WBTC amount to USD value
        uint256 wBTCValue = dscEngine.getUsdValue(wBTC, totalwBTCDeposited);
        // Uncomment below to debug values during testing
        // console.log("wETH Value: ", wETHValue);
        // console.log("wBTC Value: ", wBTCValue);
        // console.log("Total Supply: ", totalSupply);

        // Assert: total collateral value always >= total DSC supply
        assert(wETHValue + wBTCValue >= totalSupply);
    }
}