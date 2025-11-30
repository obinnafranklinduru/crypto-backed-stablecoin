// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        // 1. Deploy Handler
        handler = new Handler(dsce, dsc);
        
        // 2. Tell Foundry to use the Handler for fuzz calls
        targetContract(address(handler));
    }

    /**
     * @notice THE GOLDEN RULE
     * Total Value of Collateral > Total Supply of DSC
     */
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // 1. Get Total Supply of Debt
        uint256 totalSupply = dsc.totalSupply();

        // 2. Get Total Value of Collateral held by Engine
        uint256 totalWeth = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtc = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWeth);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtc);

        uint256 totalCollateralValue = wethValue + wbtcValue;

        // 3. Assert
        // This will only hold true if the protocol is overcollateralized
        assert(totalCollateralValue >= totalSupply);
    }
}