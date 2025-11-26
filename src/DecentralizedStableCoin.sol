// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Obinna Franklin Duru
 * @notice This is the contract for our stablecoin.
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Stability: Pegged to USD
 *
 * @dev This contract is the ERC20 implementation of our stablecoin system.
 * It is governed entirely by DSCEngine.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    ///////////////////
    // Errors        //
    ///////////////////
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    ///////////////////
    // Constructor   //
    ///////////////////
    constructor() ERC20("BinnaStableCoin", "BUSD") Ownable(msg.sender) {}

    ///////////////////
    // Functions     //
    ///////////////////

    /**
     * @notice Burns tokens from the owner's balance (The Engine).
     * @dev Overrides the burn function to include specific checks.
     * @param _amount The amount of tokens to burn.
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        // Calls the parent implementation in ERC20Burnable
        super.burn(_amount);
    }

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Can only be called by the owner (DSCEngine).
     * @param _to The address to receive the minted tokens.
     * @param _amount The amount of tokens to mint.
     * @return true if the mint was successful.
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }

        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
