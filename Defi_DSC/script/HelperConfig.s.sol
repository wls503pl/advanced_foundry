// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title HelperConfig
 * @notice Manages network-specific configuration for DSC protocol deployment
 * @dev Automatically detects network (Sepolia testnet or local Anvil) and provides appropriate addresses
 * For Sepolia: returns real Chainlink addresses and token contracts
 * For Anvil: deploys mock contracts with predetermined prices for testing
 */

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

contract HelperConfig is Script {
    /**
     * @notice Configuration struct containing all addresses needed for DSCEngine deployment
     * @param wETH_UsdPriceFeed Chainlink ETH/USD price feed address
     * @param wBTC_UsdPriceFeed Chainlink BTC/USD price feed address
     * @param wETH Wrapped Ethereum token address
     * @param wBTC Wrapped Bitcoin token address
     * @param deployerKey Private key for broadcasting transactions
     */
    struct NetworkConfig {
        address wETH_UsdPriceFeed;
        address wBTC_UsdPriceFeed;
        address wETH;
        address wBTC;
        uint256 deployerKey;
    }

    // Chainlink oracle decimal precision (all price feeds use 8 decimals)
    uint8 public constant DECIMALS = 8;

    // Mock ETH price: $2000 (stored as 200000000000 with 8 decimal places)
    int256 public constant ETH_USD_PRICE = 2000e8;

    // Mock BTC price: $80,000 (stored as 8000000000000 with 8 decimal places)
    int256 public constant BTC_USD_PRICE = 80000e8;

    // Anvil's default first account private key (used for local testing)
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Active network configuration (set during contract initialization)
    NetworkConfig public activeNetworkConfig;

    /**
     * @notice Constructor automatically detects network and loads appropriate configuration
     * @dev Chain ID 11155111 = Sepolia testnet, all others default to Anvil
     */
    constructor() {
        if (block.chainid == 11155111) {
            // Sepolia testnet: use real Chainlink addresses
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            // Local Anvil: deploy and use mock contracts
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    /**
     * @notice Retrieves real Chainlink addresses for Sepolia testnet deployment
     * @dev All addresses are production-ready Sepolia testnet contracts
     * @return NetworkConfig struct with Sepolia addresses and PRIVATE_KEY from environment
     */
    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wETH_UsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // Sepolia ETH/USD feed
            wBTC_UsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, // Sepolia BTC/USD feed
            wETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81, // Sepolia WETH token
            wBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063, // Sepolia WBTC token
            deployerKey: vm.envUint("PRIVATE_KEY") // Load from .env file
        });
    }

    /**
     * @notice Creates or retrieves mock contracts for local Anvil testing
     * @dev Deploys fresh MockV3Aggregator and ERC20Mock contracts with predefined prices
     * Returns early if contracts already deployed to save gas
     * @return NetworkConfig struct with mock contract addresses and DEFAULT_ANVIL_KEY
     */
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // Gas optimization: if already initialized, return immediately
        if (activeNetworkConfig.wETH_UsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        // Begin Anvil transactions with default private key
        vm.startBroadcast(DEFAULT_ANVIL_KEY);

        // Deploy BTC mock oracle (8 decimals, $80,000 price)
        MockV3Aggregator wBTC_USDPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);

        // Deploy BTC mock token (8 decimals like real WBTC, 1000 BTC initial supply)
        ERC20Mock wBTCMock = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, 1000e8);

        // Deploy ETH mock oracle (8 decimals, $2000 price)
        MockV3Aggregator wETH_USDPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);

        // Deploy ETH mock token (18 decimals like real WETH, 1000 ETH initial supply)
        ERC20Mock wETHMock = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, 1000e18);

        // End broadcasting
        vm.stopBroadcast();

        // Return configuration pointing to deployed mock contracts
        return NetworkConfig({
            wETH_UsdPriceFeed: address(wETH_USDPriceFeed), // Mock ETH/USD feed
            wBTC_UsdPriceFeed: address(wBTC_USDPriceFeed), // Mock BTC/USD feed
            wETH: address(wETHMock), // Mock WETH token
            wBTC: address(wBTCMock), // Mock WBTC token
            deployerKey: DEFAULT_ANVIL_KEY // Use Anvil default key
        });
    }
}
