// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployBasicNFT} from "../script/DeployBasicNFT.s.sol";
import {BasicNFT} from "../src/BasicNFT.sol";

contract BasicNFTTest is Test {
    DeployBasicNFT public deployer;
    BasicNFT public basicNFT;
    address public USER = makeAddr("user");
    string public constant _PKC_ = "ipfs://QmQNxRp7HCoUBnsUTQLc1cQcHP682uj8fdHBNEXCGHkk6n";

    function setUp() public {
        deployer = new DeployBasicNFT();
        basicNFT = deployer.run();
    }

    function testNameIsCorrect() public view {
        string memory expectedName = "Pikachu";
        string memory actualName = basicNFT.name();

        assert(keccak256(abi.encodePacked(expectedName)) == keccak256(abi.encodePacked(actualName)));
    }

    function testMint_Balance() public {
        vm.prank(USER);
        basicNFT.mintNFT(_PKC_);

        assert(basicNFT.balanceOf(USER) == 1);
        assert(keccak256(abi.encodePacked(_PKC_)) ==
            keccak256(abi.encodePacked(basicNFT.tokenURI(0))));
    }
}
