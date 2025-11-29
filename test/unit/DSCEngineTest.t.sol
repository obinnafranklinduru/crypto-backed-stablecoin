// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20DecimalsMock} from "../mocks/ERC20DecimalsMock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        // Mint fake tokens to user & liquidator unconditionally for tests
        ERC20DecimalsMock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20DecimalsMock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        
        ERC20DecimalsMock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE * 10);
        ERC20DecimalsMock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE * 10);
    }

    ///////////////////////////////////
    // Price Feed & Decimal Tests    //
    ///////////////////////////////////

    function testGetUsdValueWeth() public view {
        // 15e18 * $2000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetUsdValueWbtc() public view {
        // WBTC has 8 decimals. Price is $1000/BTC (Mock config).
        // 1 WBTC = 1e8 sats.
        // Value should be 1 * 1000 = $1000e18
        uint256 btcAmount = 1e8; 
        uint256 expectedUsd = 1000e18;
        uint256 actualUsd = engine.getUsdValue(wbtc, btcAmount);
        assertEq(actualUsd, expectedUsd);
    }
    
    // Critical: Testing the inverse function used in liquidations
    function testGetTokenAmountFromUsdWbtc() public view {
        // If I want $1000 worth of BTC, and BTC is $1000...
        // I expect 1 WBTC (1e8)
        uint256 usdAmount = 1000e18;
        uint256 expectedWbtc = 1e8;
        uint256 actualWbtc = engine.getTokenAmountFromUsd(wbtc, usdAmount);
        assertEq(actualWbtc, expectedWbtc);
    }

    ///////////////////////////////////
    // Deposit & Mint Tests          //
    ///////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public {
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }
    
    ///////////////////////////////////
    // Health Factor & Liquidations  //
    ///////////////////////////////////
    
    function testHealthFactorCanGoBelowOne() public {
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        // Deposit 10 ETH ($20,000 value at $2000/ETH)
        // Mint $15,000 DSC.
        // Threshold is 50%. Collateral Value Adjusted = $10,000.
        // Debt = $15,000.
        // HF = 10,000 / 15,000 = 0.66 (Broken)
        
        // This should REVERT because mintDsc checks HF at the end
        // We use a looser expectRevert because the precise uint calculation depends on the exact version/rounding
        vm.expectRevert();
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 15000e18);
        vm.stopPrank();
    }

    function testLiquidationPayoutIsCorrect() public {
        // 1. Arrange: User deposits 10 ETH ($20k), Mints $10k DSC. HF = 1.0 (Safe-ish)
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 10000e18);
        vm.stopPrank();
        
        // 2. Act: ETH crashes to $1500.
        // Collateral = $15k. Adj Collateral = $7.5k. Debt = $10k. HF = 0.75.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1500e8);
        
        // 3. Act: Liquidator liquidates $5000 of debt
        // Liquidator needs DSC first.
        vm.startPrank(LIQUIDATOR);
        // Liquidator deposits 20 ETH to mint DSC safely
        uint256 liquidatorCollateral = 20 ether;
        ERC20DecimalsMock(weth).approve(address(engine), liquidatorCollateral);
        engine.depositCollateralAndMintDsc(weth, liquidatorCollateral, 5000e18); 
        
        // Liquidate User
        dsc.approve(address(engine), 5000e18);
        engine.liquidate(weth, USER, 5000e18); // Cover $5000 debt
        
        // 4. Assert
        // Liquidator spent $5000 DSC.
        // Should receive $5000 ETH + 10% Bonus = $5500 ETH.
        // Price is $1500/ETH.
        // Expected ETH: 5500 / 1500 = 3.6666 ETH
        uint256 expectedCollateral = engine.getTokenAmountFromUsd(weth, 5500e18);
        
        // Check the Engine's balance dropped by exactly the payout amount
        // Engine Balance = (User Deposit 10) + (Liquidator Deposit 20) - (Payout)
        uint256 engineBalance = ERC20DecimalsMock(weth).balanceOf(address(engine));
        uint256 expectedEngineBalance = AMOUNT_COLLATERAL + liquidatorCollateral - expectedCollateral;
        
        assertEq(engineBalance, expectedEngineBalance);

        vm.stopPrank();
    }
}