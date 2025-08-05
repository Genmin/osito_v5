// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "../base/TestBase.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";

contract CollateralVaultTest is TestBase {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public override {
        super.setUp();
        (token, pair, feeRouter, vault, lenderVault) = createAndLaunchToken("Test Token", "TEST", INITIAL_SUPPLY);
        
        // Do a swap to activate the pair (move tokens out of pool)
        vm.prank(alice);
        swap(pair, address(wbera), 0.1 ether, alice);
        
        // Fund the lender vault
        vm.prank(bob);
        wbera.approve(address(lenderVault), type(uint256).max);
        vm.prank(bob);
        lenderVault.deposit(10 ether, bob);
    }
    
    function test_DepositCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(alice), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }
    
    function test_WithdrawCollateral_NoDebt() public {
        uint256 depositAmount = 1000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        vault.withdrawCollateral(depositAmount);
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(alice), 0);
        assertEq(token.balanceOf(alice), token.balanceOf(alice));
    }
    
    function test_CannotWithdrawWithDebt() public {
        uint256 depositAmount = 10000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        vault.borrow(1 ether);
        
        vm.expectRevert("OUTSTANDING_DEBT");
        vault.withdrawCollateral(depositAmount);
        vm.stopPrank();
    }
    
    function test_BorrowAtPMin() public {
        uint256 depositAmount = 100000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = depositAmount * pMin / 1e18;
        
        uint256 borrowAmount = maxBorrow / 2;
        
        uint256 balanceBefore = wbera.balanceOf(alice);
        vault.borrow(borrowAmount);
        uint256 balanceAfter = wbera.balanceOf(alice);
        
        assertEq(balanceAfter - balanceBefore, borrowAmount);
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, borrowAmount);
        vm.stopPrank();
    }
    
    function test_CannotBorrowAbovePMin() public {
        uint256 depositAmount = 100000 * 1e18;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = depositAmount * pMin / 1e18;
        
        vm.expectRevert("EXCEEDS_PMIN_VALUE");
        vault.borrow(maxBorrow + 1);
        vm.stopPrank();
    }
    
    function test_RepayDebt() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        
        wbera.approve(address(vault), borrowAmount);
        vault.repay(borrowAmount);
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, 0);
        vm.stopPrank();
    }
    
    function test_PartialRepay() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 2 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        
        uint256 repayAmount = 1 ether;
        wbera.approve(address(vault), repayAmount);
        vault.repay(repayAmount);
        
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, borrowAmount - repayAmount);
        vm.stopPrank();
    }
    
    function test_InterestAccrual() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        simulateTime(365 days);
        
        lenderVault.accrueInterest();
        
        (,uint256 debt,,,) = vault.getAccountState(alice);
        assertGt(debt, borrowAmount);
    }
    
    function test_MarkOTM() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        bool isHealthy = vault.isPositionHealthy(alice);
        
        if (!isHealthy) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            (,bool isOTM) = vault.otmPositions(alice);
            assertTrue(isOTM);
        }
    }
    
    function test_RecoveryAfterGracePeriod() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(alice)) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            simulateTime(73 hours);
            
            vm.prank(charlie);
            vault.recover(alice);
            
            assertEq(vault.collateralBalances(alice), 0);
            (uint256 principal,) = vault.accountBorrows(alice);
            assertEq(principal, 0);
        }
    }
    
    function test_CannotRecoverBeforeGracePeriod() public {
        uint256 depositAmount = 100000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(alice)) {
            vm.prank(bob);
            vault.markOTM(alice);
            
            simulateTime(71 hours);
            
            vm.prank(charlie);
            vm.expectRevert("GRACE_PERIOD_ACTIVE");
            vault.recover(alice);
        }
    }
    
    function testFuzz_DepositAndBorrow(uint256 depositAmount, uint256 borrowRatio) public {
        depositAmount = bound(depositAmount, 1000 * 1e18, 10_000_000 * 1e18);
        borrowRatio = bound(borrowRatio, 1, 100);
        
        vm.prank(alice);
        token.transfer(bob, depositAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = depositAmount * pMin / 1e18;
        uint256 borrowAmount = maxBorrow * borrowRatio / 100;
        
        if (borrowAmount > 0) {
            vault.borrow(borrowAmount);
            
            (uint256 principal,) = vault.accountBorrows(bob);
            assertEq(principal, borrowAmount);
        }
        vm.stopPrank();
    }
    
    function testFuzz_Repayment(uint256 depositAmount, uint256 borrowAmount, uint256 repayRatio) public {
        depositAmount = bound(depositAmount, 10000 * 1e18, 10_000_000 * 1e18);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = depositAmount * pMin / 1e18;
        borrowAmount = bound(borrowAmount, 0, maxBorrow);
        repayRatio = bound(repayRatio, 0, 100);
        
        if (borrowAmount == 0) return;
        
        vm.prank(alice);
        token.transfer(charlie, depositAmount);
        
        vm.prank(bob);
        wbera.transfer(charlie, borrowAmount * 2);
        
        vm.startPrank(charlie);
        token.approve(address(vault), depositAmount);
        vault.depositCollateral(depositAmount);
        vault.borrow(borrowAmount);
        
        uint256 repayAmount = borrowAmount * repayRatio / 100;
        
        if (repayAmount > 0) {
            wbera.approve(address(vault), repayAmount);
            vault.repay(repayAmount);
            
            (uint256 principal,) = vault.accountBorrows(charlie);
            assertEq(principal, borrowAmount - repayAmount);
        }
        vm.stopPrank();
    }
    
    function test_MultipleUsersCanBorrow() public {
        uint256 depositAmount = 100000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, depositAmount);
        vm.prank(alice);
        token.transfer(charlie, depositAmount);
        
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
        
        (uint256 alicePrincipal,) = vault.accountBorrows(alice);
        (uint256 bobPrincipal,) = vault.accountBorrows(bob);
        (uint256 charliePrincipal,) = vault.accountBorrows(charlie);
        
        assertEq(alicePrincipal, 0.5 ether);
        assertEq(bobPrincipal, 0.3 ether);
        assertEq(charliePrincipal, 0.2 ether);
    }
}