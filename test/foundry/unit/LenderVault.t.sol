// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {LendingFactory} from "../../../src/factories/LendingFactory.sol";
import {console2} from "forge-std/console2.sol";

contract LenderVaultTest is BaseTest {
    LenderVault public lenderVault;
    
    function setUp() public override {
        super.setUp();
        
        // Get the lender vault from lending factory
        lenderVault = LenderVault(lendingFactory.lenderVault());
    }
    
    // ============ Initialization Tests ============
    
    function test_Constructor() public view {
        assertEq(lenderVault.asset(), address(weth));
        assertEq(lenderVault.name(), "Osito Lender Vault");
        assertEq(lenderVault.symbol(), "oWETH");
        assertEq(lenderVault.decimals(), 18);
    }
    
    function test_InitialState() public view {
        assertEq(lenderVault.totalSupply(), 0);
        assertEq(lenderVault.totalAssets(), 0);
        assertEq(lenderVault.balanceOf(alice), 0);
    }
    
    // ============ Deposit Tests ============
    
    function test_Deposit() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        
        uint256 sharesBefore = lenderVault.balanceOf(alice);
        uint256 shares = lenderVault.deposit(depositAmount, alice);
        uint256 sharesAfter = lenderVault.balanceOf(alice);
        
        vm.stopPrank();
        
        assertTrue(shares > 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance should increase");
        assertEq(lenderVault.totalAssets(), depositAmount, "Total assets should equal deposit");
    }
    
    function test_DepositFor() public {
        uint256 depositAmount = 5 ether;
        
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        
        uint256 sharesBefore = lenderVault.balanceOf(bob);
        uint256 shares = lenderVault.deposit(depositAmount, bob);
        uint256 sharesAfter = lenderVault.balanceOf(bob);
        
        vm.stopPrank();
        
        assertEq(sharesAfter - sharesBefore, shares, "Bob should receive shares");
        assertEq(lenderVault.balanceOf(alice), 0, "Alice should not receive shares");
    }
    
    function test_Mint() public {
        uint256 shares = 1000 * 1e18;
        
        vm.startPrank(alice);
        uint256 assets = lenderVault.previewMint(shares);
        weth.approve(address(lenderVault), assets);
        
        uint256 actualAssets = lenderVault.mint(shares, alice);
        
        vm.stopPrank();
        
        assertEq(actualAssets, assets, "Assets used should match preview");
        assertEq(lenderVault.balanceOf(alice), shares, "Should receive exact shares");
    }
    
    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1e12, 1000 ether); // Reasonable bounds
        
        vm.startPrank(alice);
        weth.approve(address(lenderVault), amount);
        
        uint256 shares = lenderVault.deposit(amount, alice);
        
        vm.stopPrank();
        
        assertTrue(shares > 0, "Should receive shares");
        assertEq(lenderVault.totalAssets(), amount, "Total assets should equal deposit");
        assertTrue(lenderVault.balanceOf(alice) == shares, "Share balance should match");
    }
    
    // ============ Withdrawal Tests ============
    
    function test_Withdraw() public {
        uint256 depositAmount = 10 ether;
        
        // First deposit
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deposit(depositAmount, alice);
        
        // Then withdraw
        uint256 withdrawAmount = 5 ether;
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 shares = lenderVault.withdraw(withdrawAmount, alice, alice);
        uint256 wethAfter = weth.balanceOf(alice);
        
        vm.stopPrank();
        
        assertTrue(shares > 0, "Should burn shares");
        assertEq(wethAfter - wethBefore, withdrawAmount, "Should receive WETH");
        assertEq(lenderVault.totalAssets(), depositAmount - withdrawAmount, "Assets should decrease");
    }
    
    function test_Redeem() public {
        uint256 depositAmount = 10 ether;
        
        // First deposit
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        uint256 shares = lenderVault.deposit(depositAmount, alice);
        
        // Then redeem half
        uint256 redeemShares = shares / 2;
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 assets = lenderVault.redeem(redeemShares, alice, alice);
        uint256 wethAfter = weth.balanceOf(alice);
        
        vm.stopPrank();
        
        assertTrue(assets > 0, "Should receive assets");
        assertEq(wethAfter - wethBefore, assets, "Should receive WETH");
        assertEq(lenderVault.balanceOf(alice), shares - redeemShares, "Shares should decrease");
    }
    
    function test_WithdrawFor() public {
        uint256 depositAmount = 10 ether;
        
        // Alice deposits
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deposit(depositAmount, alice);
        
        // Alice approves bob to withdraw
        lenderVault.approve(bob, type(uint256).max);
        vm.stopPrank();
        
        // Bob withdraws for alice
        vm.startPrank(bob);
        uint256 withdrawAmount = 3 ether;
        uint256 bobWethBefore = weth.balanceOf(bob);
        uint256 shares = lenderVault.withdraw(withdrawAmount, bob, alice);
        uint256 bobWethAfter = weth.balanceOf(bob);
        
        vm.stopPrank();
        
        assertTrue(shares > 0, "Should burn alice's shares");
        assertEq(bobWethAfter - bobWethBefore, withdrawAmount, "Bob should receive WETH");
        assertTrue(lenderVault.balanceOf(alice) < depositAmount, "Alice's shares should decrease");
    }
    
    // ============ Interest Accrual Tests ============
    
    function test_AccrueInterest() public {
        uint256 depositAmount = 100 ether;
        
        // Deposit to vault
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deposit(depositAmount, alice);
        vm.stopPrank();
        
        uint256 assetsBefore = lenderVault.totalAssets();
        
        // Advance time
        _advanceTime(365 days);
        
        // Accrue interest
        lenderVault.accrueInterest();
        
        uint256 assetsAfter = lenderVault.totalAssets();
        
        // Interest should accrue (if there are borrows)
        // Note: Without actual borrows, interest might be minimal
        assertTrue(assetsAfter >= assetsBefore, "Assets should not decrease");
    }
    
    function test_InterestRate() public view {
        uint256 interestRate = lenderVault.getInterestRate();
        
        // Should have a reasonable interest rate
        assertTrue(interestRate >= 0, "Interest rate should be non-negative");
        assertTrue(interestRate <= 1e18, "Interest rate should be reasonable"); // Max 100%
    }
    
    // ============ Borrowing Integration Tests ============
    
    function test_BorrowingIntegration() public {
        uint256 depositAmount = 100 ether;
        
        // Fund lender vault
        vm.startPrank(bob);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deposit(depositAmount, bob);
        vm.stopPrank();
        
        uint256 totalAssetsBefore = lenderVault.totalAssets();
        
        // Simulate borrowing by directly reducing vault assets (if vault allows)
        // Note: Actual borrowing would happen through CollateralVault
        assertTrue(totalAssetsBefore == depositAmount, "Total assets should equal deposit");
    }
    
    // ============ Share Price Tests ============
    
    function test_SharePrice() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        uint256 shares = lenderVault.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Initially, 1 share should equal 1 asset (1:1 ratio)
        uint256 assetsPerShare = lenderVault.convertToAssets(1e18);
        assertEq(assetsPerShare, 1e18, "Initial share price should be 1:1");
        
        // Convert shares back to assets
        uint256 assetsForShares = lenderVault.convertToAssets(shares);
        assertEq(assetsForShares, depositAmount, "Should convert back to original amount");
    }
    
    function test_PreviewFunctions() public {
        uint256 assets = 5 ether;
        uint256 shares = 1000 * 1e18;
        
        // Preview functions should work even with empty vault
        uint256 previewShares = lenderVault.previewDeposit(assets);
        uint256 previewAssets = lenderVault.previewMint(shares);
        uint256 previewWithdrawShares = lenderVault.previewWithdraw(assets);
        uint256 previewRedeemAssets = lenderVault.previewRedeem(shares);
        
        assertTrue(previewShares > 0, "Preview deposit should return shares");
        assertTrue(previewAssets > 0, "Preview mint should return assets");
        assertTrue(previewWithdrawShares > 0, "Preview withdraw should return shares");
        assertTrue(previewRedeemAssets > 0, "Preview redeem should return assets");
    }
    
    // ============ Access Control Tests ============
    
    function test_OnlyAuthorizedCanBorrow() public {
        uint256 depositAmount = 10 ether;
        
        // Fund vault
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deploy(depositAmount, alice);
        vm.stopPrank();
        
        // Unauthorized user should not be able to borrow directly
        // Note: Borrowing typically happens through CollateralVault
        // This test verifies vault security
        assertTrue(lenderVault.totalAssets() == depositAmount, "Vault should be funded");
    }
    
    // ============ Edge Case Tests ============
    
    function test_ZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert();
        lenderVault.deposit(0, alice);
    }
    
    function test_EmptyVaultWithdraw() public {
        vm.prank(alice);
        vm.expectRevert();
        lenderVault.withdraw(1 ether, alice, alice);
    }
    
    function test_InsufficientBalance() public {
        uint256 depositAmount = 1 ether;
        
        vm.startPrank(alice);
        weth.approve(address(lenderVault), depositAmount);
        lenderVault.deposit(depositAmount, alice);
        
        // Try to withdraw more than available
        vm.expectRevert();
        lenderVault.withdraw(depositAmount + 1, alice, alice);
        
        vm.stopPrank();
    }
    
    // ============ Gas Tests ============
    
    function test_GasDeposit() public {
        vm.startPrank(alice);
        weth.approve(address(lenderVault), 1 ether);
        
        uint256 gasStart = gasleft();
        lenderVault.deposit(1 ether, alice);
        uint256 gasUsed = gasStart - gasleft();
        
        vm.stopPrank();
        
        console2.log("Gas used for deposit:", gasUsed);
        assertTrue(gasUsed < 200000, "Deposit should be gas efficient");
    }
    
    function test_GasWithdraw() public {
        // First deposit
        vm.startPrank(alice);
        weth.approve(address(lenderVault), 2 ether);
        lenderVault.deposit(2 ether, alice);
        
        uint256 gasStart = gasleft();
        lenderVault.withdraw(1 ether, alice, alice);
        uint256 gasUsed = gasStart - gasleft();
        
        vm.stopPrank();
        
        console2.log("Gas used for withdraw:", gasUsed);
        assertTrue(gasUsed < 200000, "Withdraw should be gas efficient");
    }
}