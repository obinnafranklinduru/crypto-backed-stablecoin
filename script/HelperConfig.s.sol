// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20DecimalsMock} from "../test/mocks/ERC20DecimalsMock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8; // Made cheap for testing math

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
            wethUsdPriceFeed: address(0x694AA1769357215DE4FAC081bf1f309aDC325306),
            wbtcUsdPriceFeed: address(0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43),
            weth: address(0xdd13E55209Fd76AfE204dBda4007C227904f0a81),
            wbtc: address(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();

        // 1. Deploy Mock Oracles
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);

        // 2. Deploy Mock Tokens
        ERC20DecimalsMock weth = new ERC20DecimalsMock("WETH", "WETH", 18);
        ERC20DecimalsMock wbtc = new ERC20DecimalsMock("WBTC", "WBTC", 8);

        vm.stopBroadcast();

        activeNetworkConfig = NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(weth),
            wbtc: address(wbtc),
            deployerKey: 
                 // Default Anvil private key #0
                 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        });

        return activeNetworkConfig;
    }
}
