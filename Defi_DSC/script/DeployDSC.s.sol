// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title DeployDSC
 * @notice Foundry script for deploying the complete DSC protocol
 * @dev Use this script to deploy DSC and DSCEngine contracts across different networks (Anvil, Sepolia)
 * Handles network configuration, contract instantiation, and ownership transfer in correct order
 */

import {Script} from "forge-std/Script.sol";
import {DSC} from "../src/DSC.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    // Collateral token addresses (wETH, wBTC)
    address[] public tokenAddresses;

    // Corresponding Chainlink price feed addresses for each token
    address[] public priceFeedAddresses;

    /**
     * @notice Main deployment function
     * @dev Deploys DSC token first, then DSCEngine, and transfers ownership
     * @return dsc The deployed DSC token contract
     * @return dscEngine The deployed DSCEngine contract with full initialization
     */
    function run() external returns (DSC, DSCEngine) {
        // Get network-specific configuration (Sepolia or Anvil)
        HelperConfig helperConfig = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        // Organize collateral tokens and their corresponding price feeds
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // Begin broadcasting transactions with deployer's private key
        vm.startBroadcast(deployerKey);

        // Deploy DSC token contract (deployer is initial owner)
        DSC dsc = new DSC();

        // Deploy DSCEngine with collateral config and reference to DSC token
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // End transaction broadcasting
        vm.stopBroadcast();

        // Transfer DSC ownership from deployer to DSCEngine for minting/burning control
        dsc.transferOwnership(address(dscEngine));

        return (dsc, dscEngine);
    }
}
