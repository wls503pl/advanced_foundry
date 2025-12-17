// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DSC — Decentralized Stable Coin
 * @author Peile Wu
 * An exogenous(BTC & ETH) cryptocurrency-collateralized, decentralized, pegged(US dollar),
 * low-volatility token employing an algorithmic stabilization mechanism.
 * This is the contract meant to governed by DSCEngine.
 * This contract is the ERC20 implementation of DSC system.
 * @notice Inherits from ERC20Burnable (which inherits ERC20) and Ownable
 */
contract DSC is ERC20Burnable, Ownable {
    error DSC__BurnAmountMustBeMoreThanZero();
    error DSC__BurnAmountExceedsBalance();
    error DSC__MintToZeroAddress();
    error DSC__MintAmountMustBeMoreThanZero();

    /**
     * @notice Initializes DSC token with name, symbol, and sets deployer as owner
     * @dev Passes msg.sender to Ownable constructor and token parameters to ERC20 constructor
     */
    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender) {}

    /**
     * @notice Mints new DSC tokens (only callable by owner, typically DSCEngine)
     * @dev Uses _mint() from ERC20 base contract
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DSC__MintToZeroAddress();
        }

        if (_amount <= 0) {
            revert DSC__MintAmountMustBeMoreThanZero();
        }

        _mint(_to, _amount); // ERC20._mint()
        return true;
    }

    /**
     * @notice Burns DSC tokens from caller's balance (only callable by owner)
     * @dev Overrides burn() from ERC20Burnable, calls super.burn() which uses ERC20._burn()
     * @dev balanceOf() inherited from ERC20
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender); // ERC20.balanceOf()

        if (_amount <= 0) {
            revert DSC__BurnAmountMustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DSC__BurnAmountExceedsBalance();
        }

        super.burn(_amount); // ERC20Burnable.burn() -> ERC20._burn()
    }
}
