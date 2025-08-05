// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "../base/TestBase.sol";
import {console2} from "forge-std/console2.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

contract CriticalFuzzTests is TestBase {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    uint256 public initialPMin;
    uint256 public initialK;
    
    function setUp() public override {
        super.setUp();
        
        (token, pair, feeRouter, vault, lenderVault) = createAndLaunchToken("Test Token", "TEST", INITIAL_SUPPLY);
        
        vm.prank(alice);
        addLiquidity(pair, INITIAL_LIQUIDITY);
        
        vm.prank(alice);
        swap(pair, address(wbera), 10 ether, alice);
        
        vm.prank(bob);
        wbera.approve(address(lenderVault), type(uint256).max);
        vm.prank(bob);
        lenderVault.deposit(50 ether, bob);
        
        initialPMin = pair.pMin();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        initialK = uint256(r0) * uint256(r1);
    }
    
    /// @notice Fuzz test: pMin calculation correctness
    function testFuzz_PMinCalculation(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 supply,
        uint256 feeBps
    ) public pure {
        tokReserve = bound(tokReserve, 1e18, 1e30);
        qtReserve = bound(qtReserve, 1e18, 1e30);
        supply = bound(supply, tokReserve, tokReserve * 100);
        feeBps = bound(feeBps, 30, 9900);
        
        uint256 k = tokReserve * qtReserve;
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        uint256 externalTok = supply - tokReserve;
        uint256 effectiveExternal = externalTok * (10000 - feeBps) / 10000;
        uint256 totalEffective = tokReserve + effectiveExternal;
        
        uint256 expectedPMin = k / (totalEffective * totalEffective / 1e18);
        
        assertApproxEq(pMin, expectedPMin, 1e10, "pMin calculation mismatch");
    }
    
    /// @notice Fuzz test: Swap always maintains k invariant
    function testFuzz_SwapMaintainsK(uint256 swapAmount, bool isBuy) public {
        swapAmount = bound(swapAmount, 1000, 10 ether);
        
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        
        if (isBuy) {
            vm.prank(alice);
            swap(pair, address(wbera), swapAmount, alice);
        } else {
            uint256 tokBalance = token.balanceOf(alice);
            if (tokBalance > 0) {
                swapAmount = bound(swapAmount, 1, tokBalance);
                vm.prank(alice);
                swap(pair, address(token), swapAmount, alice);
            }
        }
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        
        assert(kAfter >= kBefore);
    }
    
    /// @notice Fuzz test: Borrowing never exceeds pMin valuation
    function testFuzz_BorrowingWithinPMin(
        uint256 collateralAmount,
        uint256 borrowRatio
    ) public {
        collateralAmount = bound(collateralAmount, 1000 * 1e18, 10_000_000 * 1e18);
        borrowRatio = bound(borrowRatio, 1, 100);
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = collateralAmount * pMin / 1e18;
        uint256 borrowAmount = maxBorrow * borrowRatio / 100;
        
        if (borrowAmount > 0 && borrowAmount <= maxBorrow) {
            vault.borrow(borrowAmount);
            
            (uint256 principal,) = vault.accountBorrows(bob);
            assert(principal <= maxBorrow);
        }
        vm.stopPrank();
    }
    
    /// @notice Fuzz test: Recovery always successful at pMin
    function testFuzz_RecoveryAtPMin(
        uint256 collateralAmount,
        uint256 swapVolume
    ) public {
        collateralAmount = bound(collateralAmount, 10000 * 1e18, 1_000_000 * 1e18);
        swapVolume = bound(swapVolume, 1 ether, 50 ether);
        
        vm.prank(alice);
        token.transfer(charlie, collateralAmount);
        
        vm.startPrank(charlie);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 pMinBefore = pair.pMin();
        uint256 borrowAmount = collateralAmount * pMinBefore / 1e18;
        
        if (borrowAmount > 0) {
            vault.borrow(borrowAmount);
        }
        vm.stopPrank();
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            swap(pair, address(wbera), swapVolume / 5, alice);
        }
        
        vm.prank(keeper);
        feeRouter.collectFees();
        
        uint256 pMinAfter = pair.pMin();
        assert(pMinAfter >= pMinBefore);
        
        uint256 guaranteedRecovery = collateralAmount * pMinAfter / 1e18;
        assert(guaranteedRecovery >= borrowAmount);
    }
    
    /// @notice Fuzz test: Token burns always reduce supply
    function testFuzz_BurnReducesSupply(uint256 burnAmount, uint256 numBurns) public {
        numBurns = bound(numBurns, 1, 10);
        
        uint256 aliceBalance = token.balanceOf(alice);
        uint256 totalBurnAmount = 0;
        
        for (uint256 i = 0; i < numBurns; i++) {
            uint256 remainingBalance = token.balanceOf(alice);
            if (remainingBalance == 0) break;
            
            burnAmount = bound(burnAmount, 0, remainingBalance / (numBurns - i + 1));
            
            if (burnAmount > 0) {
                uint256 supplyBefore = token.totalSupply();
                
                vm.prank(alice);
                token.burn(burnAmount);
                
                uint256 supplyAfter = token.totalSupply();
                
                assertEq(supplyAfter, supplyBefore - burnAmount);
                totalBurnAmount += burnAmount;
            }
        }
        
        assertEq(token.totalSupply(), INITIAL_SUPPLY - totalBurnAmount);
    }
    
    /// @notice Fuzz test: Fee collection always burns tokens
    function testFuzz_FeeCollectionBurns(uint256 numSwaps, uint256 swapSize) public {
        numSwaps = bound(numSwaps, 1, 20);
        swapSize = bound(swapSize, 0.1 ether, 2 ether);
        
        uint256 supplyBefore = token.totalSupply();
        
        for (uint256 i = 0; i < numSwaps; i++) {
            vm.prank(alice);
            swap(pair, address(wbera), swapSize, alice);
            
            if (i % 5 == 0) {
                vm.prank(keeper);
                feeRouter.collectFees();
            }
        }
        
        vm.prank(keeper);
        feeRouter.collectFees();
        
        uint256 supplyAfter = token.totalSupply();
        assert(supplyAfter <= supplyBefore);
    }
    
    /// @notice Fuzz test: Interest accrual correctness
    function testFuzz_InterestAccrual(
        uint256 borrowAmount,
        uint256 timeElapsed
    ) public {
        borrowAmount = bound(borrowAmount, 0.1 ether, 10 ether);
        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        
        uint256 collateralAmount = 1_000_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        uint256 indexBefore = lenderVault.borrowIndex();
        
        simulateTime(timeElapsed);
        lenderVault.accrueInterest();
        
        uint256 indexAfter = lenderVault.borrowIndex();
        
        assert(indexAfter > indexBefore);
        
        (,,,uint256 debt,,) = vault.getAccountState(bob);
        assert(debt > borrowAmount);
    }
    
    /// @notice Fuzz test: Multiple concurrent positions
    function testFuzz_MultipleConcurrentPositions(
        uint256[3] memory collateralAmounts,
        uint256[3] memory borrowRatios
    ) public {
        address[3] memory users = [alice, bob, charlie];
        
        for (uint256 i = 0; i < 3; i++) {
            collateralAmounts[i] = bound(collateralAmounts[i], 10000 * 1e18, 1_000_000 * 1e18);
            borrowRatios[i] = bound(borrowRatios[i], 10, 90);
            
            if (i > 0) {
                vm.prank(alice);
                token.transfer(users[i], collateralAmounts[i]);
            }
            
            vm.startPrank(users[i]);
            token.approve(address(vault), collateralAmounts[i]);
            vault.depositCollateral(collateralAmounts[i]);
            
            uint256 pMin = pair.pMin();
            uint256 maxBorrow = collateralAmounts[i] * pMin / 1e18;
            uint256 borrowAmount = maxBorrow * borrowRatios[i] / 100;
            
            if (borrowAmount > 0) {
                vault.borrow(borrowAmount);
            }
            vm.stopPrank();
        }
        
        for (uint256 i = 0; i < 3; i++) {
            (uint256 collateral, uint256 debt,,,) = vault.getAccountState(users[i]);
            assertEq(collateral, collateralAmounts[i]);
            
            uint256 pMin = pair.pMin();
            uint256 maxBorrow = collateralAmounts[i] * pMin / 1e18;
            assert(debt <= maxBorrow);
        }
    }
    
    /// @notice Fuzz test: Grace period timing
    function testFuzz_GracePeriodTiming(uint256 timeBeforeRecovery) public {
        timeBeforeRecovery = bound(timeBeforeRecovery, 1 hours, 100 hours);
        
        uint256 collateralAmount = 100000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(1 ether);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(bob)) {
            vm.prank(charlie);
            vault.markOTM(bob);
            
            simulateTime(timeBeforeRecovery);
            
            if (timeBeforeRecovery >= 72 hours) {
                vm.prank(charlie);
                vault.recover(bob);
                
                assertEq(vault.collateralBalances(bob), 0);
            } else {
                vm.prank(charlie);
                vm.expectRevert("GRACE_PERIOD_ACTIVE");
                vault.recover(bob);
            }
        }
    }
}