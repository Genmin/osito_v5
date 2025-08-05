// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {console2} from "forge-std/console2.sol";

import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @title Critical Loss Absorption Edge Case Tests
/// @notice Tests the most dangerous edge cases in the loss absorption mechanism
contract LossAbsorptionEdgeCasesTest is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    address public token;
    address public pair;
    address public feeRouter;
    address public collateralVault;
    address public lenderVault;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy infrastructure
        weth = new MockWETH();
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        lendingFactory = new LendingFactory(address(weth));
        
        // Launch token
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (token, pair, feeRouter) = launchpad.launchToken(
            "Edge Case Test", "EDGE", 1_000_000e18, 100e18,
            9900, 30, 100_000e18
        
        // Deploy lending
        collateralVault = lendingFactory.createLendingMarket(pair);
        lenderVault = lendingFactory.lenderVault();
        
        // Fund lender vault
        vm.deal(charlie, 1000e18);
        vm.prank(charlie);
        weth.deposit{value: 1000e18}();
        vm.prank(charlie);
        weth.approve(lenderVault, 1000e18);
        vm.prank(charlie);
        LenderVault(lenderVault).deposit(1000e18, charlie);
    }
    
    /// @notice Test: Loss absorption when totalBorrows approaches zero
    function test_LossAbsorption_TotalBorrowsNearZero() public {
        // Setup: Very small borrow that will result in loss > totalBorrows
        _setupSmallBorrow(bob, 0.001e18); // Tiny borrow
        
        // Crash price severely to ensure massive loss
        _crashPriceSeverely();
        
        // Mark OTM and wait
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        uint256 totalBorrowsBefore = LenderVault(lenderVault).totalBorrows();
        console2.log("Total borrows before:", totalBorrowsBefore);
        
        // Recover - should handle loss > totalBorrows gracefully
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
        console2.log("Total borrows after:", totalBorrowsAfter);
        
        // Protocol should remain stable
        assertTrue(totalBorrowsAfter <= totalBorrowsBefore, "Borrows should decrease or stay same");
        console2.log("[PASS] Loss absorption with tiny totalBorrows handled");
    }
    
    /// @notice Test: Multiple simultaneous recoveries causing cascading losses
    function test_LossAbsorption_CascadingLosses() public {
        // Setup: Multiple borrowers with positions that will all fail
        address[] memory borrowers = new address[](5);
        for (uint i = 0; i < 5; i++) {
            borrowers[i] = makeAddr(string.concat("borrower", vm.toString(i)));
            _setupOTMPosition(borrowers[i]);
        }
        
        uint256 totalBorrowsBefore = LenderVault(lenderVault).totalBorrows();
        uint256 totalAssetsBefore = LenderVault(lenderVault).totalAssets();
        
        console2.log("Before cascading losses:");
        console2.log("  Total borrows:", totalBorrowsBefore);
        console2.log("  Total assets:", totalAssetsBefore);
        
        // Mark all OTM
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(keeper);
            CollateralVault(collateralVault).markOTM(borrowers[i]);
        }
        
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Recover all positions
        for (uint i = 0; i < borrowers.length; i++) {
            vm.prank(keeper);
            CollateralVault(collateralVault).recover(borrowers[i]);
        }
        
        uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
        uint256 totalAssetsAfter = LenderVault(lenderVault).totalAssets();
        
        console2.log("After cascading losses:");
        console2.log("  Total borrows:", totalBorrowsAfter);  
        console2.log("  Total assets:", totalAssetsAfter);
        console2.log("  Total losses absorbed:", totalBorrowsBefore - totalBorrowsAfter);
        
        // Protocol must remain solvent
        assertTrue(totalAssetsAfter >= totalBorrowsAfter, "Protocol became insolvent!");
        assertTrue(totalBorrowsAfter <= totalBorrowsBefore, "Borrows should decrease");
        
        console2.log("[PASS] Cascading losses handled without insolvency");
    }
    
    /// @notice Test: Loss absorption exactly equals totalBorrows
    function test_LossAbsorption_ExactTotalBorrows() public {
        // Setup: Create scenario where loss exactly equals totalBorrows
        _setupSmallBorrow(bob, 1e18);
        
        uint256 totalBorrows = LenderVault(lenderVault).totalBorrows();
        
        // Engineer a scenario where qtOut = 0 (complete loss)
        _drainAMMCompletely();
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Recovery should handle total loss
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
        
        // Should absorb all debt
        assertEq(totalBorrowsAfter, 0, "Should absorb exactly all borrows");
        console2.log("[PASS] Complete loss absorption handled");
    }
    
    /// @notice Test: Loss absorption with zero vault liquidity
    function test_LossAbsorption_ZeroVaultLiquidity() public {
        // Setup position
        _setupOTMPosition(bob);
        
        // Withdraw all liquidity from vault
        uint256 charlieShares = LenderVault(lenderVault).balanceOf(charlie);
        vm.prank(charlie);
        LenderVault(lenderVault).redeem(charlieShares, charlie, charlie);
        
        uint256 vaultBalance = weth.balanceOf(lenderVault);
        console2.log("Vault balance after withdrawal:", vaultBalance);
        
        // Mark and recover
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Should still handle recovery and loss absorption
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Loss absorption with zero liquidity handled");
    }
    
    /// @notice Test: Loss absorption precision with very small amounts
    function test_LossAbsorption_DustAmounts() public {
        // Setup: Microscopic borrow
        _setupSmallBorrow(bob, 1); // 1 wei
        
        // Add tiny interest
        vm.warp(block.timestamp + 1 days);
        LenderVault(lenderVault).accrueInterest();
        
        (,uint256 debt,,,) = CollateralVault(collateralVault).getAccountState(bob);
        console2.log("Dust debt amount:", debt);
        
        // Crash price to cause loss
        _crashPriceSeverely();
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Recovery should handle dust amounts
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Dust amount loss absorption handled");
    }
    
    /// @notice Test: Loss absorption during interest accrual
    function test_LossAbsorption_DuringInterestAccrual() public {
        _setupOTMPosition(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Interest accrues during recovery transaction
        vm.warp(block.timestamp + 1 days);
        
        uint256 totalBorrowsBefore = LenderVault(lenderVault).totalBorrows();
        
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
        
        assertTrue(totalBorrowsAfter <= totalBorrowsBefore, "Proper loss absorption with accrual");
        console2.log("[PASS] Loss absorption during interest accrual handled");
    }
    
    // Helper functions
    function _setupSmallBorrow(address user, uint256 borrowAmount) private {
        // Buy some tokens for collateral
        uint256 buyAmount = 1e18;
        vm.deal(user, buyAmount);
        vm.prank(user);
        weth.deposit{value: buyAmount}();
        vm.prank(user);
        weth.transfer(pair, buyAmount);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = buyAmount * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(user);
        OsitoPair(pair).swap(tokenOut, 0, user);
        
        // Deposit collateral and borrow
        vm.prank(user);
        OsitoToken(token).approve(collateralVault, tokenOut);
        vm.prank(user);
        CollateralVault(collateralVault).depositCollateral(tokenOut);
        
        if (borrowAmount > 0) {
            vm.prank(user);
            CollateralVault(collateralVault).borrow(borrowAmount);
        }
        
        // Wait for interest to make position risky
        vm.warp(block.timestamp + 365 days);
    }
    
    function _setupOTMPosition(address user) private {
        _setupSmallBorrow(user, 10e18); // Reasonable borrow
        _crashPriceSeverely();
    }
    
    function _crashPriceSeverely() private {
        // Massive dump to crash price below pMin
        address whale = makeAddr("whale");
        uint256 buyAmount = 500e18;
        
        vm.deal(whale, buyAmount);
        vm.prank(whale);
        weth.deposit{value: buyAmount}();
        vm.prank(whale);
        weth.transfer(pair, buyAmount);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = buyAmount * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(whale);
        OsitoPair(pair).swap(tokenOut, 0, whale);
        
        // Dump all tokens
        vm.prank(whale);
        OsitoToken(token).transfer(pair, tokenOut);
        
        (r0, r1,) = OsitoPair(pair).getReserves();
        amountInWithFee = tokenOut * (10000 - feeBps);
        uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
        
        vm.prank(whale);
        OsitoPair(pair).swap(0, wethOut, whale);
    }
    
    function _drainAMMCompletely() private {
        // Attempt to drain AMM to qtReserve ≈ 0
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        bool tokIsToken0 = OsitoPair(pair).tokIsToken0();
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        if (qtReserve > 1e15) { // If significant WETH remains
            address drainer = makeAddr("drainer");
            uint256 tokensNeeded = tokIsToken0 ? uint256(r0) / 2 : uint256(r1) / 2;
            
            deal(token, drainer, tokensNeeded);
            vm.prank(drainer);
            OsitoToken(token).transfer(pair, tokensNeeded);
            
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = tokensNeeded * (10000 - feeBps);
            uint256 tokReserveAfterDrain = tokIsToken0 ? uint256(r0) : uint256(r1);
            uint256 wethOut = (amountInWithFee * qtReserve) / ((tokReserveAfterDrain * 10000) + amountInWithFee);
            
            vm.prank(drainer);
            if (tokIsToken0) {
                OsitoPair(pair).swap(0, wethOut, drainer);
            } else {
                OsitoPair(pair).swap(wethOut, 0, drainer);
            }
        }
    }
}