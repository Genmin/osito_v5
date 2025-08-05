// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {console2} from "forge-std/console2.sol";

contract OsitoTokenTest is BaseTest {
    OsitoToken public token;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    
    function setUp() public override {
        super.setUp();
        
        vm.prank(deployer);
        token = new OsitoToken("Test Token", "TEST", SUPPLY, "https://ipfs.io/metadata/test", alice);
        vm.label(address(token), "TestToken");
    }
    
    // ============ Constructor Tests ============
    
    function test_Constructor() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.metadataURI(), "https://ipfs.io/metadata/test");
    }
    
    function testFuzz_Constructor(
        string memory name,
        string memory symbol,
        uint256 supply,
        address recipient
    ) public {
        vm.assume(recipient != address(0));
        supply = bound(supply, 0, type(uint256).max);
        
        vm.prank(deployer);
        OsitoToken newToken = new OsitoToken(name, symbol, supply, "https://ipfs.io/metadata/fuzz", recipient);
        
        assertEq(newToken.name(), name);
        assertEq(newToken.symbol(), symbol);
        assertEq(newToken.totalSupply(), supply);
        assertEq(newToken.balanceOf(recipient), supply);
    }
    
    // ============ Transfer Tests ============
    
    function test_Transfer() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
    }
    
    function test_TransferFullBalance() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
    }
    
    function test_TransferZeroAmount() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }
    
    function test_TransferInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, SUPPLY + 1);
    }
    
    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != alice);
        amount = bound(amount, 0, SUPPLY);
        
        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(to), amount);
    }
    
    // ============ MetadataURI Tests ============
    
    function test_MetadataURI() public view {
        assertEq(token.metadataURI(), "https://ipfs.io/metadata/test");
    }
    
    function testFuzz_MetadataURI(string memory metadataURI) public {
        vm.assume(bytes(metadataURI).length < 1000); // Reasonable limit
        
        OsitoToken newToken = new OsitoToken(
            "Test Token",
            "TEST", 
            1000 * 1e18,
            metadataURI,
            alice
        );
        
        assertEq(newToken.metadataURI(), metadataURI);
    }
    
    function test_EmptyMetadataURI() public {
        OsitoToken newToken = new OsitoToken(
            "Test Token",
            "TEST",
            1000 * 1e18,
            "",
            alice
        );
        
        assertEq(newToken.metadataURI(), "");
    }
    
    // ============ Approve & TransferFrom Tests ============
    
    function test_Approve() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(alice);
        assertTrue(token.approve(bob, amount));
        
        assertEq(token.allowance(alice, bob), amount);
    }
    
    function test_TransferFrom() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(alice);
        token.approve(bob, amount);
        
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, charlie, amount));
        
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(charlie), amount);
        assertEq(token.allowance(alice, bob), 0);
    }
    
    function test_TransferFromInsufficientAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, charlie, 101);
    }
    
    function test_TransferFromMaxAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        
        uint256 amount = 1000 * 1e18;
        
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, charlie, amount));
        
        // Max allowance doesn't decrease
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }
    
    function testFuzz_ApproveAndTransferFrom(
        address spender,
        address recipient,
        uint256 approveAmount,
        uint256 transferAmount
    ) public {
        vm.assume(spender != address(0) && recipient != address(0));
        vm.assume(spender != alice && recipient != alice);
        // Exclude Permit2 address which has special behavior
        vm.assume(spender != 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        approveAmount = bound(approveAmount, 0, SUPPLY);
        transferAmount = bound(transferAmount, 0, approveAmount);
        
        vm.prank(alice);
        token.approve(spender, approveAmount);
        
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, recipient, transferAmount));
        
        assertEq(token.balanceOf(alice), SUPPLY - transferAmount);
        assertEq(token.balanceOf(recipient), transferAmount);
        
        if (approveAmount != type(uint256).max) {
            assertEq(token.allowance(alice, spender), approveAmount - transferAmount);
        }
    }
    
    // ============ Burn Tests ============
    
    function test_Burn() public {
        uint256 burnAmount = 1000 * 1e18;
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        assertEq(token.balanceOf(alice), SUPPLY - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
    }
    
    function test_BurnFullBalance() public {
        vm.prank(alice);
        token.burn(SUPPLY);
        
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }
    
    function test_BurnZeroAmount() public {
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.burn(0);
        
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), supplyBefore);
    }
    
    function test_BurnInsufficientBalance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burn(1);
    }
    
    function test_MultipleBurns() public {
        // Transfer to multiple accounts
        vm.startPrank(alice);
        token.transfer(bob, 1000 * 1e18);
        token.transfer(charlie, 2000 * 1e18);
        vm.stopPrank();
        
        uint256 supplyBefore = token.totalSupply();
        
        // Each account burns
        vm.prank(alice);
        token.burn(100 * 1e18);
        
        vm.prank(bob);
        token.burn(500 * 1e18);
        
        vm.prank(charlie);
        token.burn(1000 * 1e18);
        
        uint256 totalBurned = 100 * 1e18 + 500 * 1e18 + 1000 * 1e18;
        assertEq(token.totalSupply(), supplyBefore - totalBurned);
    }
    
    function testFuzz_Burn(uint256 burnAmount) public {
        burnAmount = bound(burnAmount, 0, SUPPLY);
        
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        assertEq(token.balanceOf(alice), SUPPLY - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
    }
    
    // ============ Edge Case Tests ============
    
    function test_TransferToSelf() public {
        vm.prank(alice);
        assertTrue(token.transfer(alice, 1000));
        
        assertEq(token.balanceOf(alice), SUPPLY);
    }
    
    function test_ApproveToZeroAddress() public {
        vm.prank(alice);
        // Solady allows approve to address(0)
        assertTrue(token.approve(address(0), 1000));
    }
    
    function test_TransferToZeroAddress() public {
        // Solady allows transfer to address(0) - acts as burn
        uint256 amount = 1000 * 1e18;
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(alice);
        assertTrue(token.transfer(address(0), amount));
        
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.totalSupply(), supplyBefore); // Supply doesn't change with transfer to 0
    }
    
    // ============ Gas Tests ============
    
    function test_GasTransfer() public {
        vm.prank(alice);
        uint256 gasStart = gasleft();
        token.transfer(bob, 1000);
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for transfer:", gasUsed);
        assertTrue(gasUsed < 50000); // Should be efficient
    }
    
    function test_GasBurn() public {
        vm.prank(alice);
        uint256 gasStart = gasleft();
        token.burn(1000);
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for burn:", gasUsed);
        assertTrue(gasUsed < 30000); // Should be efficient
    }
}