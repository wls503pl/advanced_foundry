// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title DSCEngineTest
 * @notice Unit tests for DSCEngine contract functionality
 * @dev Tests price conversions, collateral deposits, and minting logic
 */

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSC} from "../../src/DSC.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../script/ERC20Mock.sol";

contract DSCEngineTest is Test {
    // Deployment contracts
    DeployDSC deployer;
    DSC dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    
    // Network configuration addresses
    address ethUsdPriceFeed;
    address weth;
    
    // Test user and amounts
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    /**
     * @notice Set up test environment before each test
     * @dev Deploys full protocol and mints test collateral to USER
     */
    function setUp() public {
        // Deploy complete DSC protocol
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        
        // Extract network configuration
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();
        
        // Mint initial test collateral to USER
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////
    // Price Tests //////
    /////////////////////
    
    /**
     * @notice Test USD value conversion from token amount
     * @dev Verifies precision handling: 15 ETH @ $2000 = $30,000
     */
    function testGetUsdValue() public {
        // 15 ETH at Chainlink price of $2000
        uint256 ethAmount = 15e18;
        
        // Expected: 15 * 2000 = 30,000 USD (in 18-decimal format)
        uint256 expectedUsd = 15e18 * 2000e8 / 1e8;
        
        // Call DSCEngine conversion function
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        
        // Verify conversion accuracy
        assertEq(expectedUsd, actualUsd);
    }

    /////////////////////////////////
    // DepositCollateral Tests //////
    /////////////////////////////////
    
    /**
     * @notice Test that zero-amount collateral deposits are rejected
     * @dev Ensures moreThanZero modifier is enforced
     */
    function testRevertsIfCollateralZero() public {
        // Impersonate USER
        vm.startPrank(USER);
        
        // Approve DSCEngine to spend USER's wETH
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // Expect revert when attempting to deposit zero collateral
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        
        vm.stopPrank();
    }
}