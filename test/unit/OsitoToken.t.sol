// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";

contract OsitoTokenTest is BaseTest {
    OsitoToken public token;
    
    string constant NAME = "Test Osito";
    string constant SYMBOL = "TOSITO";
    uint256 constant SUPPLY = 1_000_000e18;
    
    function setUp() public override {
        super.setUp();
        token = new OsitoToken(NAME, SYMBOL, SUPPLY, alice);
    }
    
    function test_Constructor() public {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
    }
    
    function test_Burn() public {
        uint256 burnAmount = 100e18;
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        assertEq(token.balanceOf(alice), SUPPLY - burnAmount);
        assertEq(token.totalSupply(), SUPPLY - burnAmount);
    }
    
    function test_BurnAll() public {
        vm.prank(alice);
        token.burn(SUPPLY);
        
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }
    
    function test_BurnMoreThanBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(SUPPLY + 1);
    }
    
    function test_TransferFunctionality() public {
        uint256 transferAmount = 100e18;
        
        vm.prank(alice);
        token.transfer(bob, transferAmount);
        
        assertEq(token.balanceOf(alice), SUPPLY - transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
    }
    
    function test_ApproveFunctionality() public {
        uint256 approveAmount = 100e18;
        
        vm.prank(alice);
        token.approve(bob, approveAmount);
        
        assertEq(token.allowance(alice, bob), approveAmount);
        
        vm.prank(bob);
        token.transferFrom(alice, charlie, approveAmount);
        
        assertEq(token.balanceOf(alice), SUPPLY - approveAmount);
        assertEq(token.balanceOf(charlie), approveAmount);
        assertEq(token.allowance(alice, bob), 0);
    }
    
    // Fuzz tests
    function testFuzz_Burn(uint256 burnAmount) public {
        burnAmount = bound(burnAmount, 0, SUPPLY);
        
        uint256 initialSupply = token.totalSupply();
        uint256 initialBalance = token.balanceOf(alice);
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        assertEq(token.totalSupply(), initialSupply - burnAmount);
        assertEq(token.balanceOf(alice), initialBalance - burnAmount);
    }
    
    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != alice);
        amount = bound(amount, 0, SUPPLY);
        
        vm.prank(alice);
        token.transfer(to, amount);
        
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(to), amount);
    }
}