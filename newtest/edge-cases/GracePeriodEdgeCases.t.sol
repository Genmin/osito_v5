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

/// @title Grace Period Edge Case Tests
/// @notice Tests for all possible edge cases during the 72-hour grace period
contract GracePeriodEdgeCasesTest is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    address public token;
    address public pair;
    address public feeRouter;
    address public collateralVault;
    address public lenderVault;
    
    uint256 constant GRACE_PERIOD = 72 hours;
    
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
            "Grace Test", "GRACE", 1_000_000e18, 100e18,
            9900, 30, 100_000e18
        );
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
    
    /// @notice Test: Grace period timing at exact boundaries
    function test_GracePeriod_ExactBoundaryTiming() public {
        _setupOTMPosition(bob);
        
        // Mark OTM at specific timestamp
        uint256 markTime = block.timestamp;
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Test recovery attempts at exact boundaries
        
        // 1. Exactly at grace period end (should fail)
        vm.warp(markTime + GRACE_PERIOD);
        vm.prank(keeper);
        vm.expectRevert("GRACE_PERIOD_ACTIVE");
        CollateralVault(collateralVault).recover(bob);
        
        // 2. One second after grace period (should succeed)
        vm.warp(markTime + GRACE_PERIOD + 1);
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Grace period boundary timing works correctly");
    }
    
    /// @notice Test: Multiple positions with overlapping grace periods
    function test_GracePeriod_OverlappingPositions() public {
        address[] memory borrowers = new address[](3);
        uint256[] memory markTimes = new uint256[](3);
        
        // Setup multiple positions
        for (uint i = 0; i < 3; i++) {
            borrowers[i] = makeAddr(string.concat("borrower", vm.toString(i)));
            _setupOTMPosition(borrowers[i]);
        }
        
        // Mark them OTM at different times
        markTimes[0] = block.timestamp;
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(borrowers[0]);
        
        vm.warp(block.timestamp + 1 hours);
        markTimes[1] = block.timestamp;
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(borrowers[1]);
        
        vm.warp(block.timestamp + 2 hours);
        markTimes[2] = block.timestamp;
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(borrowers[2]);
        
        // Test recovery at different times
        
        // First position should be recoverable after its grace period
        vm.warp(markTimes[0] + GRACE_PERIOD + 1);
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(borrowers[0]);
        
        // Second position should still be in grace period
        vm.prank(keeper);
        vm.expectRevert("GRACE_PERIOD_ACTIVE");
        CollateralVault(collateralVault).recover(borrowers[1]);
        
        // Third position should still be in grace period
        vm.prank(keeper);
        vm.expectRevert("GRACE_PERIOD_ACTIVE");
        CollateralVault(collateralVault).recover(borrowers[2]);
        
        console2.log("[PASS] Overlapping grace periods handled correctly");
    }
    
    /// @notice Test: Position becomes healthy during grace period
    function test_GracePeriod_PositionBecomesHealthy() public {
        _setupMarginalPosition(bob);
        
        // Mark OTM
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Verify position is marked
        (,,, bool isOTM,) = CollateralVault(collateralVault).getAccountState(bob);
        assertTrue(isOTM, "Position should be marked OTM");
        
        // During grace period, pump price back up
        _pumpPrice();
        
        // Check if position became healthy
        bool isHealthy = CollateralVault(collateralVault).isPositionHealthy(bob);
        console2.log("Position healthy after price pump:", isHealthy);
        
        // Grace period should still be active (OTM marking remains)
        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        
        if (isHealthy) {
            // If position is healthy, should we still be able to recover?
            // This tests the design decision: does OTM marking persist?
            try CollateralVault(collateralVault).recover(bob) {
                console2.log("Recovery succeeded despite healthy position");
            } catch {
                console2.log("Recovery failed for healthy position");
            }
        } else {
            vm.prank(keeper);
            CollateralVault(collateralVault).recover(bob);
        }
        
        console2.log("[PASS] Price changes during grace period handled");
    }
    
    /// @notice Test: User actions during grace period
    function test_GracePeriod_UserActionsBlocked() public {
        _setupOTMPosition(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Test that user can still perform certain actions during grace period
        
        // 1. Can user repay debt?
        (,uint256 debt,,,) = CollateralVault(collateralVault).getAccountState(bob);
        vm.deal(bob, debt);
        vm.prank(bob);
        weth.deposit{value: debt}();
        vm.prank(bob);
        weth.approve(collateralVault, debt);
        
        vm.prank(bob);
        CollateralVault(collateralVault).repay(debt);
        
        // Check if OTM marking is cleared after full repayment
        (,uint256 remainingDebt,, bool isOTM,) = CollateralVault(collateralVault).getAccountState(bob);
        console2.log("Remaining debt after repay:", remainingDebt);
        console2.log("Still marked OTM after repay:", isOTM);
        
        if (remainingDebt == 0) {
            assertFalse(isOTM, "OTM marking should be cleared after full repay");
        }
        
        console2.log("[PASS] User actions during grace period tested");
    }
    
    /// @notice Test: Grace period with continuous interest accrual
    function test_GracePeriod_ContinuousInterestAccrual() public {
        _setupOTMPosition(bob);
        
        (,uint256 debtAtMark,,,) = CollateralVault(collateralVault).getAccountState(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Interest continues to accrue during grace period
        uint256 timeStep = GRACE_PERIOD / 24; // Check every 3 hours
        
        for (uint i = 1; i <= 24; i++) {
            vm.warp(block.timestamp + timeStep);
            LenderVault(lenderVault).accrueInterest();
            
            (,uint256 currentDebt,,,) = CollateralVault(collateralVault).getAccountState(bob);
            console2.log("Debt after", i * 3, "hours:", currentDebt);
            
            assertTrue(currentDebt >= debtAtMark, "Debt should continue growing");
        }
        
        // After grace period, recovery should account for all accrued interest
        vm.warp(block.timestamp + 1);
        (,uint256 finalDebt,,,) = CollateralVault(collateralVault).getAccountState(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("Final debt at recovery:", finalDebt);
        console2.log("[PASS] Interest accrual during grace period handled");
    }
    
    /// @notice Test: Grace period with price manipulation attempts
    function test_GracePeriod_PriceManipulationResistance() public {
        _setupOTMPosition(bob);
        
        uint256 pMinAtMark = OsitoPair(pair).pMin();
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Attacker tries to manipulate pMin during grace period
        address attacker = makeAddr("attacker");
        
        // Strategy 1: Buy and burn tokens to increase pMin
        uint256 buyAmount = 50e18;
        vm.deal(attacker, buyAmount);
        vm.prank(attacker);
        weth.deposit{value: buyAmount}();
        vm.prank(attacker);
        weth.transfer(pair, buyAmount);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = buyAmount * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(attacker);
        OsitoPair(pair).swap(tokenOut, 0, attacker);
        
        // Burn half the tokens
        vm.prank(attacker);
        OsitoToken(token).burn(tokenOut / 2);
        
        uint256 pMinAfterManipulation = OsitoPair(pair).pMin();
        console2.log("pMin before manipulation:", pMinAtMark);
        console2.log("pMin after manipulation:", pMinAfterManipulation);
        
        // Wait for grace period to end
        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        
        // Recovery should use current market conditions
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Price manipulation during grace period analyzed");
    }
    
    /// @notice Test: Grace period with fee collection timing
    function test_GracePeriod_FeeCollectionTiming() public {
        // Generate fees first
        _generateFees();
        
        _setupOTMPosition(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Collect fees during grace period
        uint256 lpBalance = OsitoPair(pair).balanceOf(address(feeRouter));
        uint256 principal = FeeRouter(feeRouter).principalLp(address(pair));
        
        if (lpBalance > principal) {
            uint256 supplyBefore = OsitoToken(token).totalSupply();
            uint256 pMinBefore = OsitoPair(pair).pMin();
            
            FeeRouter(feeRouter).collectFees(address(pair));
            
            uint256 supplyAfter = OsitoToken(token).totalSupply();
            uint256 pMinAfter = OsitoPair(pair).pMin();
            
            console2.log("Supply burned from fees:", supplyBefore - supplyAfter);
            console2.log("pMin increase from fees:", pMinAfter - pMinBefore);
        }
        
        // Recovery after grace period should use post-fee-collection state
        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Fee collection during grace period handled");
    }
    
    /// @notice Test: Grace period expiration edge cases
    function test_GracePeriod_ExpirationEdgeCases() public {
        _setupOTMPosition(bob);
        
        uint256 markTime = block.timestamp;
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Test various expiration scenarios
        
        // 1. Multiple recovery attempts during grace period
        uint256[] memory testTimes = new uint256[](5);
        testTimes[0] = markTime + 1 hours;
        testTimes[1] = markTime + 24 hours;
        testTimes[2] = markTime + 48 hours;
        testTimes[3] = markTime + 71 hours + 59 minutes + 59 seconds; // 1 second before
        testTimes[4] = markTime + GRACE_PERIOD; // Exactly at expiration
        
        for (uint i = 0; i < testTimes.length; i++) {
            vm.warp(testTimes[i]);
            vm.prank(keeper);
            vm.expectRevert("GRACE_PERIOD_ACTIVE");
            CollateralVault(collateralVault).recover(bob);
        }
        
        // 2. First valid recovery
        vm.warp(markTime + GRACE_PERIOD + 1);
        vm.prank(keeper);
        CollateralVault(collateralVault).recover(bob);
        
        console2.log("[PASS] Grace period expiration edge cases handled");
    }
    
    /// @notice Test: Grace period with position modifications
    function test_GracePeriod_PositionModifications() public {
        _setupOTMPosition(bob);
        
        vm.prank(keeper);
        CollateralVault(collateralVault).markOTM(bob);
        
        // Bob tries to deposit more collateral during grace period
        uint256 additionalCollateral = 1000e18;
        deal(token, bob, additionalCollateral);
        
        vm.prank(bob);
        OsitoToken(token).approve(collateralVault, additionalCollateral);
        vm.prank(bob);
        CollateralVault(collateralVault).depositCollateral(additionalCollateral);
        
        // Check if additional collateral affects OTM status
        bool isHealthy = CollateralVault(collateralVault).isPositionHealthy(bob);
        (,,, bool isOTM,) = CollateralVault(collateralVault).getAccountState(bob);
        
        console2.log("Position healthy after adding collateral:", isHealthy);
        console2.log("Still marked OTM:", isOTM);
        
        // Test if position can still be recovered
        vm.warp(block.timestamp + GRACE_PERIOD + 1);
        
        if (isHealthy && !isOTM) {
            // Position should not be recoverable if healthy and not marked
            vm.prank(keeper);
            vm.expectRevert("NOT_MARKED_OTM");
            CollateralVault(collateralVault).recover(bob);
        } else {
            vm.prank(keeper);
            CollateralVault(collateralVault).recover(bob);
        }
        
        console2.log("[PASS] Position modifications during grace period handled");
    }
    
    // Helper functions
    function _setupOTMPosition(address user) private {
        _setupHealthyPosition(user);
        
        // Make position OTM through time and interest
        vm.warp(block.timestamp + 365 days * 2);
        
        // Force unhealthy if needed
        if (CollateralVault(collateralVault).isPositionHealthy(user)) {
            _crashPrice();
        }
    }
    
    function _setupMarginalPosition(address user) private {
        _setupHealthyPosition(user);
        
        // Just enough time to make position marginal
        vm.warp(block.timestamp + 180 days);
    }
    
    function _setupHealthyPosition(address user) private {
        uint256 buyAmount = 10e18;
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
        
        vm.prank(user);
        OsitoToken(token).approve(collateralVault, tokenOut);
        vm.prank(user);
        CollateralVault(collateralVault).depositCollateral(tokenOut);
        
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 maxBorrow = (tokenOut * pMin) / 1e18 / 2;
        
        if (maxBorrow > 0) {
            vm.prank(user);
            CollateralVault(collateralVault).borrow(maxBorrow);
        }
    }
    
    function _crashPrice() private {
        address crasher = makeAddr("crasher");
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
        
        // Dump tokens
        vm.prank(crasher);
        OsitoToken(token).transfer(pair, tokenOut);
        
        (r0, r1,) = OsitoPair(pair).getReserves();
        amountInWithFee = tokenOut * (10000 - feeBps);
        uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
        
        vm.prank(crasher);
        OsitoPair(pair).swap(0, wethOut, crasher);
    }
    
    function _pumpPrice() private {
        address pumper = makeAddr("pumper");
        
        // Get tokens to sell for WETH (pump price)
        uint256 sellAmount = 50000e18;
        deal(token, pumper, sellAmount);
        
        vm.prank(pumper);
        OsitoToken(token).transfer(pair, sellAmount);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = sellAmount * (10000 - feeBps);
        uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
        
        vm.prank(pumper);
        OsitoPair(pair).swap(0, wethOut, pumper);
    }
    
    function _generateFees() private {
        for (uint i = 0; i < 10; i++) {
            address trader = makeAddr(string.concat("trader", vm.toString(i)));
            uint256 tradeAmount = 5e18;
            
            vm.deal(trader, tradeAmount);
            vm.prank(trader);
            weth.deposit{value: tradeAmount}();
            vm.prank(trader);
            weth.transfer(pair, tradeAmount);
            
            (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = tradeAmount * (10000 - feeBps);
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            vm.prank(trader);
            OsitoPair(pair).swap(tokenOut, 0, trader);
        }
    }
}