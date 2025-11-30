// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { DSCEngine } from "../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../src/DecentralizedStableCoin.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);

        // 1. Deploy Token
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        // 2. Deploy Engine
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // 3. Transfer Ownership of Token to Engine
        dsc.transferOwnership(address(engine));

        vm.stopBroadcast();

        return (dsc, engine, config);
    }
}
