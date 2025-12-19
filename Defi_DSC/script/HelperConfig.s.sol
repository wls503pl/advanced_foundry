// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wETH_UsdPriceFeed;
        address wBTC_UsdPriceFeed;
        address wETH;
        address wBTC;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 80000e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wETH_UsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wBTC_UsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wETH_UsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast(DEFAULT_ANVIL_KEY);

        MockV3Aggregator wBTC_USDPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wBTCMock = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, 1000e8);

        MockV3Aggregator wETH_USDPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wETHMock = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, 1000e18);

        vm.stopBroadcast();

        return NetworkConfig({
            wETH_UsdPriceFeed: address(wETH_USDPriceFeed),
            wBTC_UsdPriceFeed: address(wBTC_USDPriceFeed),
            wETH: address(wETHMock),
            wBTC: address(wBTCMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
