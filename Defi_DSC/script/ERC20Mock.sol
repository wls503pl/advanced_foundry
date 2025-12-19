// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mock
 * @notice Simple ERC20 mock for local testing (Anvil / Foundry)
 * @dev Designed for DSC collateral tokens (e.g. WETH / WBTC)
 */
contract ERC20Mock is ERC20 {
    constructor(string memory _name, string memory _symbol, address initialHolder, uint256 initialSupply)
        ERC20(_name, _symbol)
    {
        _mint(initialHolder, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
