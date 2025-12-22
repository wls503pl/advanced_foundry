// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Have our invariant aka properties

// What are invariants?

/**
 * 1. The total supply of DSC should be less than the total value of collateral
 * 2. Getter view functions should never revert <- evergreen invariant
 */
import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DSC} from "../../src/DSC.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DSC dsc;
    HelperConfig helperConfig;
    address wETH;
    address wBTC;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (,, wETH, wBTC,) = helperConfig.activeNetworkConfig();
        targetContract(address(dscEngine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // Get the value of all the collateral in the protocol
        // compare it to all the debt(dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalwETHDeposited = IERC20(wETH).balanceOf(address(dscEngine));
        uint256 totalwBTCDeposited = IERC20(wBTC).balanceOf(address(dscEngine));

        uint256 wETHValue = dscEngine.getUsdValue(wETH, totalwETHDeposited);
        uint256 wBTCValue = dscEngine.getUsdValue(wBTC, totalwBTCDeposited);
        console.log("wETH Value: ", wETHValue);
        console.log("wBTC Value: ", wBTCValue);
        console.log("Total Supply: ", totalSupply);

        assert(wETHValue + wBTCValue >= totalSupply);
    }
}
