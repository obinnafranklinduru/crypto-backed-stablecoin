// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20DecimalsMock} from "../mocks/ERC20DecimalsMock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    
    ERC20DecimalsMock weth;
    ERC20DecimalsMock wbtc;

    // Ghost Variables
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateral;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; 

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20DecimalsMock(collateralTokens[0]);
        wbtc = ERC20DecimalsMock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    // --- FUNNEL 1: DEPOSIT COLLATERAL ---
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20DecimalsMock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        
        // Track users who have deposited so we can use them later for minting/redeeming
        usersWithCollateral.push(msg.sender);
    }

    // --- FUNNEL 2: REDEEM COLLATERAL ---
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20DecimalsMock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        
        // If they have 0, we can't redeem. Return to avoid revert spam.
        if (maxCollateralToRedeem == 0) return;
        
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;

        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // --- FUNNEL 3: MINT DSC ---
    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateral.length == 0) return;
        
        address sender = usersWithCollateral[addressSeed % usersWithCollateral.length];
        
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        
        if (maxDscToMint < 0) return;
        
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) return;

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        
        timesMintIsCalled++;
    }

    // --- FUNNEL 4: LIQUIDATE ---
    function liquidate(uint256 collateralSeed, uint256 userToBeLiquidatedIndex, uint256 debtToCover) public {
        if (usersWithCollateral.length == 0) return;
        
        // 1. Select a Victim
        address victim = usersWithCollateral[userToBeLiquidatedIndex % usersWithCollateral.length];

        // 2. Check Solvency (We only liquidate if they are actually underwater)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(victim);
        int256 marginOfSafety = int256(collateralValueInUsd) / 2 - int256(totalDscMinted);
        
        // If margin is positive, they are healthy. Return.
        if (marginOfSafety >= 0) return;

        // 3. Bound debt coverage to their actual debt
        debtToCover = bound(debtToCover, 1, totalDscMinted);

        // 4. Bootstrap the Liquidator (msg.sender)
        // The random msg.sender needs money to pay off the debt. 
        ERC20DecimalsMock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 collateralAmount = dsce.getTokenAmountFromUsd(address(collateral), debtToCover * 2);

        vm.startPrank(msg.sender);
        
        // Liquidator gets collateral -> Deposits -> Mints DSC
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dsce), collateralAmount);
        dsce.depositCollateralAndMintDsc(address(collateral), collateralAmount, debtToCover);
        
        // Liquidator approves Engine to burn DSC
        dsc.approve(address(dsce), debtToCover);

        // Execute
        dsce.liquidate(address(collateral), victim, debtToCover);
        
        vm.stopPrank();
    }

    // --- INTERNAL HELPER ---
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20DecimalsMock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}