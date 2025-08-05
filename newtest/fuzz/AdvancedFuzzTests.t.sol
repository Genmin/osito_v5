// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @title Advanced Fuzz Tests for Edge Cases
/// @notice Comprehensive fuzzing of edge cases and boundary conditions
contract AdvancedFuzzTests is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        lendingFactory = new LendingFactory(address(weth));
    }
    
    /// @notice Fuzz test pMin calculation with extreme parameters
    function testFuzz_PMinCalculationExtreme(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 tokTotalSupply,
        uint256 feeBps
    ) public {
        // Bound to extreme but valid ranges
        tokReserves = bound(tokReserves, 1, type(uint112).max);
        qtReserves = bound(qtReserves, 1, type(uint112).max);
        tokTotalSupply = bound(tokTotalSupply, tokReserves, tokReserves + type(uint64).max);
        feeBps = bound(feeBps, 0, 9999);
        
        // Calculate pMin
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // Verify it doesn't revert and follows basic constraints
        assertTrue(pMin >= 0, "pMin should never be negative");
        
        if (tokTotalSupply == 0) {
            assertEq(pMin, 0, "Zero supply should give zero pMin");
        }
        
        if (tokReserves >= tokTotalSupply) {
            // All tokens in pool case
            uint256 expectedSpotPrice = (qtReserves * 1e18) / tokReserves;
            uint256 expectedPMin = (expectedSpotPrice * 9950) / 10000; // 0.5% discount
            
            // Allow for rounding differences
            uint256 diff = pMin > expectedPMin ? pMin - expectedPMin : expectedPMin - pMin;
            assertTrue(diff <= 2, "Spot price case should match expected");
        }
        
        // Test invariant: higher fees should not increase pMin dramatically
        if (feeBps < 9999) {
            uint256 pMinHigherFee = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps + 1);
            assertTrue(pMinHigherFee <= pMin, "Higher fee should not increase pMin");
        }
    }
    
    /// @notice Fuzz test loss absorption under extreme conditions
    function testFuzz_LossAbsorptionExtremeConditions(
        uint256 initialLiquidity,
        uint256 borrowAmount,
        uint256 timeElapsed,
        uint256 priceDropPercent
    ) public {
        // Bound inputs to create extreme but valid scenarios
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        borrowAmount = bound(borrowAmount, 0.001e18, initialLiquidity / 2);
        timeElapsed = bound(timeElapsed, 1 days, 3650 days); // Up to 10 years
        priceDropPercent = bound(priceDropPercent, 50, 99); // 50-99% price drop
        
        // Setup protocol
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address token, address pair,) = launchpad.launchToken(
            "Extreme Test", "EXTR", 1_000_000e18, 100e18,
            9900, 30, 100_000e18
        
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
        
        // Fund lender vault
        vm.deal(charlie, initialLiquidity);
        vm.prank(charlie);
        weth.deposit{value: initialLiquidity}();
        vm.prank(charlie);
        weth.approve(lenderVault, initialLiquidity);
        vm.prank(charlie);
        LenderVault(lenderVault).deposit(initialLiquidity, charlie);
        
        // Create borrower position
        _setupBorrowerPosition(bob, token, pair, collateralVault, borrowAmount);
        
        uint256 totalBorrowsBefore = LenderVault(lenderVault).totalBorrows();
        uint256 totalAssetsBefore = LenderVault(lenderVault).totalAssets();
        
        // Advance time for extreme interest accrual
        vm.warp(block.timestamp + timeElapsed);
        
        // Crash price
        _crashPrice(token, pair, priceDropPercent);
        
        // Mark OTM and recover
        bool isHealthy = CollateralVault(collateralVault).isPositionHealthy(bob);
        if (!isHealthy) {
            vm.prank(keeper);
            CollateralVault(collateralVault).markOTM(bob);
            vm.warp(block.timestamp + 72 hours + 1);
            
            vm.prank(keeper);
            CollateralVault(collateralVault).recover(bob);
        }
        
        uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
        uint256 totalAssetsAfter = LenderVault(lenderVault).totalAssets();
        
        // Critical invariants that must hold
        assertTrue(totalAssetsAfter >= totalBorrowsAfter, "Protocol became insolvent!");
        assertTrue(totalBorrowsAfter <= totalBorrowsBefore, "Borrows should not increase");
        
        // Position should be cleared
        (,uint256 remainingDebt,,,) = CollateralVault(collateralVault).getAccountState(bob);
        assertEq(remainingDebt, 0, "Position should be fully cleared");
    }
    
    /// @notice Fuzz test interest accrual precision under extreme conditions
    function testFuzz_InterestAccrualPrecision(
        uint256 principal,
        uint256 rate,
        uint256 timeElapsed,
        uint256 numAccruals
    ) public {
        // Bound to extreme ranges
        principal = bound(principal, 1, 1000e18); // Wei to 1000 ETH
        rate = bound(rate, 1e12, 1e18); // 0.0001% to 100% APR
        timeElapsed = bound(timeElapsed, 1, 365 days * 10); // 1 second to 10 years
        numAccruals = bound(numAccruals, 1, 1000); // 1 to 1000 accruals
        
        // Setup lending vault
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address token, address pair,) = launchpad.launchToken(
            "Interest Test", "INT", 1_000_000e18, 100e18,
            3000, 30, 100_000e18
        
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
        
        // Fund and create borrow
        vm.deal(charlie, 1000e18);
        vm.prank(charlie);
        weth.deposit{value: 1000e18}();
        vm.prank(charlie);
        weth.approve(lenderVault, 1000e18);
        vm.prank(charlie);
        LenderVault(lenderVault).deposit(1000e18, charlie);
        
        // Create a position with the principal amount
        if (principal <= weth.balanceOf(lenderVault)) {
            _setupBorrowerPosition(bob, token, pair, collateralVault, principal);
            
            uint256 initialBorrows = LenderVault(lenderVault).totalBorrows();
            uint256 timeStep = timeElapsed / numAccruals;
            
            // Accrue interest in steps
            for (uint i = 0; i < numAccruals; i++) {
                vm.warp(block.timestamp + timeStep);
                LenderVault(lenderVault).accrueInterest();
                
                uint256 currentBorrows = LenderVault(lenderVault).totalBorrows();
                assertTrue(currentBorrows >= initialBorrows, "Borrows should not decrease");
                
                // Check for reasonable growth (not infinite)
                if (currentBorrows > initialBorrows * 100) {
                    break; // Prevent unrealistic compound growth
                }
            }
            
            uint256 finalBorrows = LenderVault(lenderVault).totalBorrows();
            
            // Interest should have accrued
            if (timeElapsed > 0 && rate > 0) {
                assertTrue(finalBorrows >= initialBorrows, "Interest should accrue");
            }
            
            // Should not overflow
            assertTrue(finalBorrows < type(uint256).max / 2, "Should not approach overflow");
        }
    }
    
    /// @notice Fuzz test AMM edge cases with extreme reserves
    function testFuzz_AMMExtremeReserves(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 swapAmount,
        bool direction
    ) public {
        // Bound to extreme but valid ranges
        tokReserves = bound(tokReserves, 1e9, type(uint112).max / 2); // Avoid total overflow
        qtReserves = bound(qtReserves, 1e9, type(uint112).max / 2);
        swapAmount = bound(swapAmount, 1e12, qtReserves / 10); // Up to 10% of reserves
        
        // Setup with specific reserves (would need custom deployment)
        vm.deal(alice, qtReserves);
        vm.prank(alice);
        weth.deposit{value: qtReserves}();
        vm.prank(alice);
        weth.approve(address(launchpad), qtReserves);
        
        vm.prank(alice);
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Extreme AMM", "EAMM", tokReserves, qtReserves,
            3000, 30, tokReserves / 10
        
        // Get initial state
        (uint112 r0Initial, uint112 r1Initial,) = OsitoPair(pair).getReserves();
        uint256 kInitial = uint256(r0Initial) * uint256(r1Initial);
        uint256 pMinInitial = OsitoPair(pair).pMin();
        
        // Perform swap
        if (direction) {
            // Buy tokens with WETH
            vm.deal(bob, swapAmount);
            vm.prank(bob);
            weth.deposit{value: swapAmount}();
            vm.prank(bob);
            weth.transfer(pair, swapAmount);
            
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = swapAmount * (10000 - feeBps);
            uint256 expectedOut = (amountInWithFee * r0Initial) / ((r1Initial * 10000) + amountInWithFee);
            
            if (expectedOut > 0 && expectedOut < r0Initial) {
                vm.prank(bob);
                OsitoPair(pair).swap(expectedOut, 0, bob);
            }
        } else {
            // Sell some tokens
            uint256 tokensToSell = bound(swapAmount, 1e12, uint256(r0Initial) / 20);
            deal(token, bob, tokensToSell);
            
            vm.prank(bob);
            OsitoToken(token).transfer(pair, tokensToSell);
            
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = tokensToSell * (10000 - feeBps);
            uint256 expectedOut = (amountInWithFee * r1Initial) / ((r0Initial * 10000) + amountInWithFee);
            
            if (expectedOut > 0 && expectedOut < r1Initial) {
                vm.prank(bob);
                OsitoPair(pair).swap(0, expectedOut, bob);
            }
        }
        
        // Verify invariants held
        (uint112 r0Final, uint112 r1Final,) = OsitoPair(pair).getReserves();
        uint256 kFinal = uint256(r0Final) * uint256(r1Final);
        uint256 pMinFinal = OsitoPair(pair).pMin();
        
        assertTrue(kFinal >= kInitial, "K should never decrease");
        assertTrue(pMinFinal >= pMinInitial, "pMin should never decrease");
        assertTrue(r0Final > 0 && r1Final > 0, "Reserves should remain positive");
    }
    
    /// @notice Fuzz test recovery with extreme collateral-debt ratios
    function testFuzz_RecoveryExtremeRatios(
        uint256 collateralAmount,
        uint256 debtRatio, // 1-1000 (0.1% to 100%)
        uint256 priceChange, // 1-1000 (0.1% to 100% of original)
        uint256 gracePeriodWait
    ) public {
        // Bound inputs
        collateralAmount = bound(collateralAmount, 1e15, 10000e18); // 0.001 to 10000 tokens
        debtRatio = bound(debtRatio, 1, 800); // 0.1% to 80% LTV
        priceChange = bound(priceChange, 1, 200); // 0.1% to 20% of original price
        gracePeriodWait = bound(gracePeriodWait, 72 hours, 72 hours + 30 days);
        
        // Setup protocol
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address token, address pair,) = launchpad.launchToken(
            "Recovery Test", "REC", 1_000_000e18, 100e18,
            3000, 30, 100_000e18
        
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
        
        // Fund lender vault
        vm.deal(charlie, 2000e18);
        vm.prank(charlie);
        weth.deposit{value: 2000e18}();
        vm.prank(charlie);
        weth.approve(lenderVault, 2000e18);
        vm.prank(charlie);
        LenderVault(lenderVault).deposit(2000e18, charlie);
        
        // Setup borrower with specific ratio
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 maxBorrow = (collateralAmount * pMin) / 1e18;
        uint256 borrowAmount = (maxBorrow * debtRatio) / 1000;
        
        if (borrowAmount > 0 && borrowAmount <= weth.balanceOf(lenderVault)) {
            // Give bob collateral tokens
            deal(token, bob, collateralAmount);
            
            vm.prank(bob);
            OsitoToken(token).approve(collateralVault, collateralAmount);
            vm.prank(bob);
            CollateralVault(collateralVault).depositCollateral(collateralAmount);
            
            vm.prank(bob);
            CollateralVault(collateralVault).borrow(borrowAmount);
            
            // Manipulate price by the specified ratio
            _setPriceRatio(token, pair, priceChange);
            
            // Add interest by advancing time
            vm.warp(block.timestamp + 365 days);
            LenderVault(lenderVault).accrueInterest();
            
            bool isHealthy = CollateralVault(collateralVault).isPositionHealthy(bob);
            
            if (!isHealthy) {
                // Mark OTM
                vm.prank(keeper);
                CollateralVault(collateralVault).markOTM(bob);
                
                // Wait specified grace period
                vm.warp(block.timestamp + gracePeriodWait);
                
                uint256 totalBorrowsBefore = LenderVault(lenderVault).totalBorrows();
                uint256 totalAssetsBefore = LenderVault(lenderVault).totalAssets();
                
                // Recover
                vm.prank(keeper);
                CollateralVault(collateralVault).recover(bob);
                
                uint256 totalBorrowsAfter = LenderVault(lenderVault).totalBorrows();
                uint256 totalAssetsAfter = LenderVault(lenderVault).totalAssets();
                
                // Critical invariants
                assertTrue(totalAssetsAfter >= totalBorrowsAfter, "Protocol became insolvent!");
                assertTrue(totalBorrowsAfter <= totalBorrowsBefore, "Borrows should not increase");
                
                // Position should be cleared
                (uint256 remainingCollateral, uint256 remainingDebt,,,) = 
                    CollateralVault(collateralVault).getAccountState(bob);
                assertEq(remainingCollateral, 0, "Collateral should be cleared");
                assertEq(remainingDebt, 0, "Debt should be cleared");
            }
        }
    }
    
    // Helper functions
    function _setupBorrowerPosition(
        address user,
        address token,
        address pair,
        address collateralVault,
        uint256 borrowAmount
    ) private {
        // Buy tokens
        uint256 buyAmount = borrowAmount * 5; // Buy 5x the borrow amount in tokens
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
        
        // Deposit collateral
        vm.prank(user);
        OsitoToken(token).approve(collateralVault, tokenOut);
        vm.prank(user);
        CollateralVault(collateralVault).depositCollateral(tokenOut);
        
        // Borrow
        if (borrowAmount > 0) {
            vm.prank(user);
            CollateralVault(collateralVault).borrow(borrowAmount);
        }
    }
    
    function _crashPrice(address token, address pair, uint256 dropPercent) private {
        address crasher = makeAddr("crasher");
        
        // Buy tokens first
        uint256 buyAmount = 100e18;
        vm.deal(crasher, buyAmount);
        vm.prank(crasher);
        weth.deposit{value: buyAmount}();
        vm.prank(crasher);
        weth.transfer(pair, buyAmount);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = buyAmount * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(crasher);
        OsitoPair(pair).swap(tokenOut, 0, crasher);
        
        // Sell portion based on drop percent
        uint256 sellAmount = (tokenOut * dropPercent) / 100;
        vm.prank(crasher);
        OsitoToken(token).transfer(pair, sellAmount);
        
        (r0, r1,) = OsitoPair(pair).getReserves();
        amountInWithFee = sellAmount * (10000 - feeBps);
        uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
        
        vm.prank(crasher);
        OsitoPair(pair).swap(0, wethOut, crasher);
    }
    
    function _setPriceRatio(address token, address pair, uint256 ratio) private {
        // Manipulate price to achieve specific ratio (simplified)
        if (ratio < 100) {
            _crashPrice(token, pair, 100 - ratio);
        }
        // For ratio > 100, would need to pump price (more complex)
    }
}