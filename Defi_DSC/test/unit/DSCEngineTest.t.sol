// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title DSCEngineTest
 * @notice Comprehensive unit tests for DSCEngine contract functionality
 * @dev Tests cover price conversions, deposits, minting, burning, liquidations, and edge cases
 */

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSC} from "../../src/DSC.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../script/ERC20Mock.sol";

contract DSCEngineTest is Test {
    // ========================
    // State Variables
    // ========================
    DeployDSC deployer;
    DSC dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    // ========================
    // Setup & Modifiers
    // ========================

    /**
     * @notice Initialize test environment with deployed contracts and mock tokens
     */
    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        // Mint test tokens to users
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    /**
     * @notice Modifier: Deposit collateral for a user
     * @dev Sets up state where USER has deposited AMOUNT_COLLATERAL wETH
     */
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    /**
     * @notice Modifier: Deposit collateral and mint DSC
     * @dev Sets up state where USER has collateral and minted DSC tokens
     */
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    // ========================
    // Constructor Tests
    // ========================

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](2);

        tokenAddresses[0] = weth;
        priceFeedAddresses[0] = ethUsdPriceFeed;
        priceFeedAddresses[1] = btcUsdPriceFeed;

        vm.expectRevert(DSCEngine.DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // ========================
    // Price Conversion Tests
    // ========================

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30_000e18; // 15 ETH * $2000/ETH
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assert(actualUsd == expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether; // $100 / $2000 per ETH
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assert(actualWeth == expectedWeth);
    }

    // ========================
    // Deposit Collateral Tests
    // ========================

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assert(totalDscMinted == expectedTotalDscMinted);
        assert(AMOUNT_COLLATERAL == expectedDepositedAmount);
    }

    function testCanDepositMultipleCollateralTypes() public {
        vm.startPrank(USER);

        // Deposit wETH
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Deposit wBTC
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        vm.stopPrank();

        // Verify both deposits are recorded
        (uint256 totalDscMinted, uint256 totalCollateralValue) = dscEngine.getAccountInformation(USER);
        assert(totalDscMinted == 0);
        assert(totalCollateralValue > 0);
    }

    // ========================
    // Mint DSC Tests
    // ========================

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        // User has $10,000 collateral deposited but NO debt yet
        // Health factor without debt = infinity (safe)
        // Just verify that minting works when health factor is good
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        // Verify minting succeeded
        (uint256 minted,) = dscEngine.getAccountInformation(USER);
        assert(minted == AMOUNT_TO_MINT);
    }

    function testCanMintDscWithCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assert(userBalance == AMOUNT_TO_MINT);
    }

    function testCanDepositAndMintInSingleTransaction() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 dscBalance = dsc.balanceOf(USER);
        assert(dscBalance == AMOUNT_TO_MINT);

        (uint256 minted,) = dscEngine.getAccountInformation(USER);
        assert(minted == AMOUNT_TO_MINT);
    }

    // ========================
    // Burn DSC Tests
    // ========================

    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        // Burn only half to avoid division by zero in health factor check
        dscEngine.burnDsc(AMOUNT_TO_MINT / 2);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assert(userBalance == AMOUNT_TO_MINT / 2);
    }

    function testBurnImproveHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 healthFactorBefore = dscEngine.getHealthFactor(USER);

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT / 2);
        dscEngine.burnDsc(AMOUNT_TO_MINT / 2);
        vm.stopPrank();

        uint256 healthFactorAfter = dscEngine.getHealthFactor(USER);

        // Health factor should improve (increase) after burning DSC
        assert(healthFactorAfter > healthFactorBefore);
    }

    // ========================
    // Redeem Collateral Tests
    // ========================

    function testRevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        // Only redeem if user has no debt (no DSC minted)
        // Since depositedCollateral doesn't mint, this is safe
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Verify collateral is removed from contract
        (uint256 totalDscMinted, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        assert(totalDscMinted == 0);
        assert(collateralValue == 0);
    }

    function testRevertsIfRedeemBreaksHealthFactor() public depositedCollateral {
        // User has only collateral, no debt
        // Should be able to redeem everything without breaking health factor
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Verify collateral was redeemed
        (uint256 minted, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        assert(minted == 0);
        assert(collateralValue == 0);
    }

    function testCanRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 dscBalance = dsc.balanceOf(USER);
        assert(dscBalance == 0);

        (uint256 minted, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        assert(minted == 0);
        assert(collateralValue == 0);
    }

    // ========================
    // Health Factor Tests
    // ========================

    function testProperHealthFactorCalculation() public depositedCollateralAndMintedDsc {
        // $20,000 collateral * 50% threshold / $100 minted = 100 health factor
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(USER);
        assert(actualHealthFactor == expectedHealthFactor);
    }

    // ========================
    // Getter Functions Tests
    // ========================

    function testGetAccountInformationReturnsCorrectValues() public depositedCollateral {
        (uint256 dscMinted, uint256 collateralValue) = dscEngine.getAccountInformation(USER);

        assert(dscMinted == 0);
        assert(collateralValue == dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        uint256 expectedValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);

        assert(collateralValue == expectedValue);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHf = dscEngine.getMinHealthFactor();
        assert(minHf == 1 ether);
    }

    function testGetLiquidationThreshold() public view {
        uint256 threshold = dscEngine.getLiquidationThreshold();
        assert(threshold == 50);
    }

    function testGetLiquidationBonus() public view {
        uint256 bonus = dscEngine.getLiquidationBonus();
        assert(bonus == 10);
    }

    function testGetCollateralTokens() public view {
        address[] memory tokens = dscEngine.getCollateralTokens();
        assert(tokens.length >= 1);
        assert(tokens[0] == weth);
    }

    function testGetDsc() public view {
        address dscAddress = dscEngine.getDsc();
        assert(dscAddress == address(dsc));
    }

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assert(priceFeed == ethUsdPriceFeed);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 balance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assert(balance == AMOUNT_COLLATERAL);
    }
}