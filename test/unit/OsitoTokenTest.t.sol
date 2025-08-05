// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "../base/TestBase.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";

contract OsitoTokenTest is TestBase {
    OsitoToken public token;
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    
    function setUp() public override {
        super.setUp();
        token = new OsitoToken("Test Token", "TEST", INITIAL_SUPPLY, alice);
    }
    
    function test_InitialState() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }
    
    function test_Transfer() public {
        vm.prank(alice);
        token.transfer(bob, 1000 * 1e18);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - 1000 * 1e18);
        assertEq(token.balanceOf(bob), 1000 * 1e18);
    }
    
    function test_TransferFrom() public {
        vm.prank(alice);
        token.approve(bob, 1000 * 1e18);
        
        vm.prank(bob);
        token.transferFrom(alice, charlie, 500 * 1e18);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - 500 * 1e18);
        assertEq(token.balanceOf(charlie), 500 * 1e18);
        assertEq(token.allowance(alice, bob), 500 * 1e18);
    }
    
    function test_Burn() public {
        vm.prank(alice);
        token.burn(1000 * 1e18);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - 1000 * 1e18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1000 * 1e18);
    }
    
    function test_BurnReducesTotalSupply() public {
        uint256 burnAmount = 100_000_000 * 1e18;
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount);
    }
    
    function test_CannotBurnMoreThanBalance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burn(1 * 1e18);
    }
    
    function test_MultipleHoldersBurn() public {
        vm.prank(alice);
        token.transfer(bob, 1000 * 1e18);
        
        vm.prank(alice);
        token.transfer(charlie, 2000 * 1e18);
        
        uint256 aliceBurn = 100 * 1e18;
        uint256 bobBurn = 500 * 1e18;
        uint256 charlieBurn = 1000 * 1e18;
        
        vm.prank(alice);
        token.burn(aliceBurn);
        
        vm.prank(bob);
        token.burn(bobBurn);
        
        vm.prank(charlie);
        token.burn(charlieBurn);
        
        uint256 totalBurned = aliceBurn + bobBurn + charlieBurn;
        assertEq(token.totalSupply(), INITIAL_SUPPLY - totalBurned);
    }
    
    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != alice);
        amount = bound(amount, 0, INITIAL_SUPPLY);
        
        vm.prank(alice);
        token.transfer(to, amount);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(to), amount);
    }
    
    function testFuzz_Burn(uint256 amount) public {
        amount = bound(amount, 0, INITIAL_SUPPLY);
        
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.burn(amount);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - amount);
        assertEq(token.totalSupply(), supplyBefore - amount);
    }
    
    function testFuzz_ApproveAndTransferFrom(
        address spender,
        address recipient,
        uint256 approveAmount,
        uint256 transferAmount
    ) public {
        vm.assume(spender != address(0));
        vm.assume(recipient != address(0));
        vm.assume(spender != alice);
        vm.assume(recipient != alice);
        
        approveAmount = bound(approveAmount, 0, INITIAL_SUPPLY);
        transferAmount = bound(transferAmount, 0, approveAmount);
        
        vm.prank(alice);
        token.approve(spender, approveAmount);
        
        vm.prank(spender);
        token.transferFrom(alice, recipient, transferAmount);
        
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - transferAmount);
        assertEq(token.balanceOf(recipient), transferAmount);
        assertEq(token.allowance(alice, spender), approveAmount - transferAmount);
    }
    
    function test_TransferToZeroAddress() public {
        // Solady's ERC20 allows transfers to address(0) (burns)
        uint256 balanceBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.transfer(address(0), 1000);
        
        // Transfer to address(0) should burn tokens
        assertEq(token.balanceOf(alice), balanceBefore - 1000);
        assertEq(token.totalSupply(), supplyBefore);
    }
    
    function test_MaxSupplyBurn() public {
        vm.prank(alice);
        token.burn(INITIAL_SUPPLY);
        
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }
}