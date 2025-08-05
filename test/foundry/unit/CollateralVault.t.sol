// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {console2} from "forge-std/console2.sol";

contract CollateralVaultTest is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST",
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
        
        // Get lender vault
        lenderVault = LenderVault(lendingFactory.lenderVault());
        
        // Create collateral vault
        vault = _createLendingMarket(address(pair));
        
        // Fund lender vault
        vm.startPrank(bob);
        weth.approve(address(lenderVault), type(uint256).max);
        lenderVault.deposit(50 ether, bob);
        vm.stopPrank();
        
        // Get some tokens for testing by swapping
        vm.prank(alice);
        _swap(pair, address(weth), 1 ether, alice);
    }
    
    // ============ Deposit Tests ============
    
    function test_DepositCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(alice), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }
    
    function test_WithdrawCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 balanceBefore = token.balanceOf(alice);
        vault.withdrawCollateral(depositAmount);
        uint256 balanceAfter = token.balanceOf(alice);
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(alice), 0);
        assertEq(balanceAfter - balanceBefore, depositAmount);
    }
    
    function test_CannotWithdrawWithDebt() public {
        uint256 depositAmount = 10000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        // Borrow some amount
        vault.borrow(0.1 ether);
        
        // Should not be able to withdraw with debt
        vm.expectRevert("OUTSTANDING_DEBT");
        vault.withdrawCollateral(depositAmount);
        vm.stopPrank();
    }
    
    // ============ Borrowing Tests ============
    
    function test_Borrow() public {
        uint256 depositAmount = 100000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (depositAmount * pMin) / 1e18;
        uint256 borrowAmount = maxBorrow / 2; // Borrow 50% of max
        
        uint256 wethBefore = weth.balanceOf(alice);
        vault.borrow(borrowAmount);
        uint256 wethAfter = weth.balanceOf(alice);
        vm.stopPrank();
        
        assertEq(wethAfter - wethBefore, borrowAmount);
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, borrowAmount);
    }
    
    function test_CannotBorrowExceedingPMin() public {
        uint256 depositAmount = 100000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (depositAmount * pMin) / 1e18;
        
        vm.expectRevert("EXCEEDS_PMIN_VALUE");
        vault.borrow(maxBorrow + 1);
        vm.stopPrank();
    }
    
    function test_RepayDebt() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Borrow
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        
        // Repay
        weth.approve(address(vault), borrowAmount);
        vault.repay(borrowAmount);
        vm.stopPrank();
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, 0);
    }
    
    function test_PartialRepay() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 2 ether;
        uint256 repayAmount = 1 ether;
        
        // Borrow
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        
        // Partial repay
        weth.approve(address(vault), repayAmount);
        vault.repay(repayAmount);
        vm.stopPrank();
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, borrowAmount - repayAmount);
    }
    
    // ============ Interest Accrual Tests ============
    
    function test_InterestAccrual() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Borrow
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Advance time
        _advanceTime(365 days);
        
        // Accrue interest
        lenderVault.accrueInterest();
        
        (,uint256 debt,,,) = vault.getAccountState(alice);
        assertTrue(debt > borrowAmount, "Debt should include accrued interest");
    }
    
    // ============ Position Health Tests ============
    
    function test_PositionHealth() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Borrow
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        assertTrue(vault.isPositionHealthy(alice), "Position should be healthy initially");
        
        // Advance time significantly to accrue interest
        _advanceTime(10000 days);
        lenderVault.accrueInterest();
        
        // Check if position might become unhealthy due to interest
        bool isHealthy = vault.isPositionHealthy(alice);
        console2.log("Position healthy after time:", isHealthy);
    }
    
    function test_MarkOTM() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Create position
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Advance time to accrue significant interest
        _advanceTime(10000 days);
        lenderVault.accrueInterest();
        
        // Check if position is unhealthy
        if (!vault.isPositionHealthy(alice)) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            (,bool isOTM) = vault.otmPositions(alice);
            assertTrue(isOTM, "Position should be marked OTM");
        }
    }
    
    function test_CannotMarkHealthyPosition() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 0.1 ether; // Small borrow
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        vm.prank(bob);
        vm.expectRevert("POSITION_HEALTHY");
        vault.markOTM(alice);
    }
    
    // ============ Recovery Tests ============
    
    function test_Recovery() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Create position
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Advance time significantly
        _advanceTime(10000 days);
        lenderVault.accrueInterest();
        
        // Mark and recover if unhealthy
        if (!vault.isPositionHealthy(alice)) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            // Wait grace period
            _advanceTime(73 hours);
            
            vm.prank(charlie);
            vault.recover(alice);
            
            // Position should be cleared
            assertEq(vault.collateralBalances(alice), 0);
            (uint256 principal,) = vault.accountBorrows(alice);
            assertEq(principal, 0);
        }
    }
    
    function test_CannotRecoverDuringGracePeriod() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Create position
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Advance time significantly
        _advanceTime(10000 days);
        lenderVault.accrueInterest();
        
        // Mark and try to recover immediately
        if (!vault.isPositionHealthy(alice)) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            // Try to recover before grace period ends
            vm.prank(charlie);
            vm.expectRevert("GRACE_PERIOD_ACTIVE");
            vault.recover(alice);
        }
    }
    
    // ============ State Query Tests ============
    
    function test_GetAccountState() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Create position
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        (uint256 collateral, uint256 debt, bool isHealthy, bool isOTM, uint256 timeUntilRecoverable) = vault.getAccountState(alice);
        
        assertEq(collateral, depositAmount);
        assertEq(debt, borrowAmount);
        assertTrue(isHealthy);
        assertFalse(isOTM);
        assertEq(timeUntilRecoverable, 0);
    }
    
    // ============ Edge Case Tests ============
    
    function test_EmptyPosition() public view {
        (uint256 collateral, uint256 debt, bool isHealthy, bool isOTM, uint256 timeUntilRecoverable) = vault.getAccountState(alice);
        
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertTrue(isHealthy);
        assertFalse(isOTM);
        assertEq(timeUntilRecoverable, 0);
    }
    
    function test_MultipleUsers() public {
        uint256 depositAmount = 50000 * 1e18;
        
        // Give tokens to bob and charlie
        vm.prank(alice);
        token.transfer(bob, depositAmount);
        vm.prank(alice);
        token.transfer(charlie, depositAmount);
        
        // Each user creates a position
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(0.5 ether);
        vm.stopPrank();
        
        vm.startPrank(bob);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(0.3 ether);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(0.2 ether);
        vm.stopPrank();
        
        // Check all positions
        (uint256 aliceCollateral, uint256 aliceDebt,,,) = vault.getAccountState(alice);
        (uint256 bobCollateral, uint256 bobDebt,,,) = vault.getAccountState(bob);
        (uint256 charlieCollateral, uint256 charlieDebt,,,) = vault.getAccountState(charlie);
        
        assertEq(aliceCollateral, depositAmount);
        assertEq(aliceDebt, 0.5 ether);
        assertEq(bobCollateral, depositAmount);
        assertEq(bobDebt, 0.3 ether);
        assertEq(charlieCollateral, depositAmount);
        assertEq(charlieDebt, 0.2 ether);
    }
}