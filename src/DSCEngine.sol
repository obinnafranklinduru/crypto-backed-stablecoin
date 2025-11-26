// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Obinna Franklin Duru
 * @notice The core logic for the Decentralized Stablecoin system.
 * Handles all collateral deposits, minting, redeeming, and liquidations.
 *
 * The system is designed to be minimal and maintain a 1 token == $1 peg.
 * Properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * @notice This contract MUST handle "Pull over Push" payments.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Types         //
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // Errors        //
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // State Variables //
    ///////////////////
    
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% Overcollateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% Bonus

    // Immutables (Gas Efficient)
    DecentralizedStableCoin private immutable i_dsc;

    // Mappings (O(1) Access)
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    // Arrays (For Iteration)
    address[] private s_collateralTokens;

    ///////////////////
    // Events        //
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    ///////////////////
    // Modifiers     //
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ///////////////////
    // Functions     //
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        
        // Set the Price Feeds
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral checks health factor already
    }

    /**
     * @notice Follows CEI: Checks, Effects, Interactions
     * @notice If the user has DSC minted, this might fail if their Health Factor breaks
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice Follows CEI: Checks, Effects, Interactions
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) 
        public 
        moreThanZero(amountCollateral) 
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant 
    {
        // TODO: Future Improvement - Implement EIP-2612 Permit to allow gasless approvals

        // 1. Effects (Update State)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // 2. Interactions (External Call)
        // We use transferFrom because we are PULLING the tokens from the user
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // 1. Effects (Update State)
        s_DSCMinted[msg.sender] += amountDscToMint;
        
        // 2. Checks (Health Factor) - This is a "Check" that happens AFTER state update (Optimistic Accounting)
        _revertIfHealthFactorIsBroken(msg.sender);

        // 3. Interactions (Mint Tokens)
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        // Usually, burning improves health factor, so we don't strictly need to check it.
        // But if we allow minting in the same block, checking it is safe.
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateral The ERC20 collateral address to liquidate
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice This function assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // 1. Check if user is actually insolvent
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // 2. Calculate Collateral to take
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        
        // 3. Calculate Bonus (10%)
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // 4. Interactions
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        // 5. Checks
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        
        // Verify Liquidator is safe
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////////
    // Private & Internal View Functions     //
    ///////////////////////////////////////////

    /**
     * @dev Low-level internal function to burn DSC.
     * @dev Does not check health factor.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        
        i_dsc.burn(amountDscToBurn);
    }

    /**
     * @dev Low-level internal function to redeem collateral.
     * @dev Does not check health factor.
     */
    function _redeemCollateral(
        address from, 
        address to, 
        address tokenCollateralAddress, 
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Returns how close to liquidation a user is.
     * If a user goes below 1, then they can be liquidated.
     * @param user The address of the user to check
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        
        // Prevent Divide by Zero
        if (totalDscMinted == 0) return type(uint256).max;
        
        // Calculate Collateral Adjusted for Threshold
        // Example: $150 Collateral * 50 / 100 = $75 Adjusted
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        
        // Example: ($75 * 1e18) / $50 Debt = 1.5e18 (Health Factor)
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    ///////////////////////////////////////////
    // Public & External View Functions      //
    ///////////////////////////////////////////

    /**
     * @notice Loops through all collateral tokens and sums their USD value.
     * @param user The user to check
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each allowed token
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            
            // Only convert if they actually have a balance (Gas optimization)
            if (amount > 0) {
                totalCollateralValueInUsd += getUsdValue(token, amount);
            }
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Converts a token amount to its USD value using Chainlink.
     * @dev Dynamically handles token decimals (e.g. USDC 6 decimals vs WETH 18).
     * @dev Uses OracleLib to check for stale prices.
     * @param token The token address
     * @param amount The amount of tokens
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        
        // Use OracleLib for stale checks
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        
        // 1. Get Token Decimals (e.g., 6 for USDC, 8 for WBTC, 18 for WETH)
        uint256 tokenDecimals = IERC20Metadata(token).decimals();
        
        // 2. Normalize Price (Chainlink is 8 decimals, we want 18)
        uint256 normalizedPrice = uint256(price) * ADDITIONAL_FEED_PRECISION;

        // 3. Normalize Amount (Token is X decimals, we want 18)
        uint256 normalizedAmount;
        if (tokenDecimals < 18) {
            normalizedAmount = amount * (10 ** (18 - tokenDecimals));
        } else {
            normalizedAmount = amount; 
        }

        // 4. Calculate Value
        return (normalizedPrice * normalizedAmount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        
        uint256 tokenDecimals = IERC20Metadata(token).decimals();

        // Formula: (usdAmount * PRECISION) / (price * ADDITIONAL_FEED_PRECISION * adjustment)
        // Note: We need to reverse the logic of getUsdValue
        
        uint256 feedPrecision = uint256(price) * ADDITIONAL_FEED_PRECISION;
        uint256 decimalAdjustment = 1;
        
        if (tokenDecimals < 18) {
            decimalAdjustment = 10 ** (18 - tokenDecimals);
        }
        
        return (usdAmountInWei * PRECISION) / (feedPrecision * decimalAdjustment);
    }
}