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

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateral;
    MockV3Aggregator public ethUsdPriceFeed;

    // We can't use msg.sender in fuzz tests because it's random.
    // We use a set of "Ghost Users" to simulate real traffic.
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; 

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20DecimalsMock(collateralTokens[0]);
        wbtc = ERC20DecimalsMock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    // FUNNEL 1: DEPOSIT
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

    // FUNNEL 2: REDEEM
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

    // FUNNEL 3: MINT DSC
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

    // HELPER: PRICE SHOCK (Simulate Market Volatility)
    // This breaks the invariant OFTEN. We include it to see if the protocol handles bad debt correctly.
    // For now, we constrain it to prevent instant insolvency from ruining the test run.
    function updateCollateralPrice(uint96 newPrice) public {
        // Example: Price can vary by +/- 10% or set a hard min/max
        // Here we just prevent the "infinite" value
        // let's say max price is $100,000 (100000e8)
        // and min price is $1 (1e8)
        
        int256 newPriceInt = int256(uint256(newPrice));
        
        // If the fuzzer gives us a huge number, we clamp it or return
        // Using bound to keep it realistic (e.g. between $1 and $10,000)
        // Note: MockV3Aggregator decimals is 8
        int256 minPrice = 1e8; // $1
        int256 maxPrice = 10000e8; // $10,000
        
        // We use valid values to avoid breaking the math
        newPriceInt = int256(bound(uint256(newPriceInt), uint256(minPrice), uint256(maxPrice)));

        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // HELPER: Pick a random token
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20DecimalsMock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}