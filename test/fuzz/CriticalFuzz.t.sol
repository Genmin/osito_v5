// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract CriticalFuzzTest is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        launchpad = new OsitoLaunchpad(address(weth));
        lendingFactory = new LendingFactory();
    }
    
    /// @notice Fuzz test token launch parameters
    function testFuzz_TokenLaunch(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 wethAmount,
        uint256 startFee,
        uint256 endFee,
        uint256 decayTarget
    ) public {
        // Bound inputs
        supply = bound(supply, 1000e18, 1e30);
        wethAmount = bound(wethAmount, 0.1e18, 10000e18);
        startFee = bound(startFee, 31, 9900);
        endFee = bound(endFee, 0, startFee - 1);
        decayTarget = bound(decayTarget, supply / 1000, supply / 2);
        
        // Fund alice
        vm.deal(alice, wethAmount);
        vm.prank(alice);
        weth.deposit{value: wethAmount}();
        vm.prank(alice);
        weth.approve(address(launchpad), wethAmount);
        
        // Launch token
        vm.prank(alice);
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            name,
            symbol,
            supply,
            wethAmount,
            startFee,
            endFee,
            decayTarget
        );
        
        // Verify deployment
        assertTrue(token != address(0));
        assertTrue(pair != address(0));
        assertTrue(feeRouter != address(0));
        
        // Verify initial state
        assertEq(OsitoToken(token).totalSupply(), supply);
        assertEq(OsitoToken(token).balanceOf(pair), supply);
        assertEq(OsitoPair(pair).currentFeeBps(), startFee);
        
        // Verify pMin exists
        uint256 pMin = OsitoPair(pair).pMin();
        assertTrue(pMin > 0);
    }
    
    /// @notice Fuzz test swap amounts and directions
    function testFuzz_SwapSafety(
        uint256 supply,
        uint256 initialWeth,
        uint256 swapAmount,
        bool buyToken,
        uint256 numSwaps
    ) public {
        // Bound inputs
        supply = bound(supply, 100_000e18, 10_000_000e18);
        initialWeth = bound(initialWeth, 1e18, 1000e18);
        swapAmount = bound(swapAmount, 0.001e18, 50e18);
        numSwaps = bound(numSwaps, 1, 20);
        
        // Launch token
        vm.deal(alice, initialWeth);
        vm.prank(alice);
        weth.deposit{value: initialWeth}();
        vm.prank(alice);
        weth.approve(address(launchpad), initialWeth);
        
        vm.prank(alice);
        (address token, address pair,) = launchpad.launchToken(
            "Fuzz Token",
            "FUZZ",
            supply,
            initialWeth,
            5000, // 50% fee
            30,
            supply / 10
        );
        
        // Record initial state
        uint256 initialPMin = OsitoPair(pair).pMin();
        (uint112 r0Init, uint112 r1Init,) = OsitoPair(pair).getReserves();
        uint256 initialK = uint256(r0Init) * uint256(r1Init);
        
        // Perform swaps
        for (uint i = 0; i < numSwaps; i++) {
            if (buyToken) {
                // Buy tokens with WETH
                vm.deal(bob, swapAmount);
                vm.prank(bob);
                weth.deposit{value: swapAmount}();
                vm.prank(bob);
                weth.transfer(pair, swapAmount);
                
                (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
                uint256 amountInWithFee = swapAmount * (10000 - OsitoPair(pair).currentFeeBps());
                uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
                
                if (tokenOut > 0 && tokenOut < r0 / 2) { // Don't drain pool
                    vm.prank(bob);
                    OsitoPair(pair).swap(tokenOut, 0, bob);
                }
            } else {
                // Sell tokens for WETH
                uint256 bobTokens = OsitoToken(token).balanceOf(bob);
                if (bobTokens > 0) {
                    uint256 sellAmount = bobTokens / 4; // Sell 25%
                    vm.prank(bob);
                    OsitoToken(token).transfer(pair, sellAmount);
                    
                    (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
                    uint256 amountInWithFee = sellAmount * (10000 - OsitoPair(pair).currentFeeBps());
                    uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
                    
                    if (wethOut > 0 && wethOut < r1 / 2) {
                        vm.prank(bob);
                        OsitoPair(pair).swap(0, wethOut, bob);
                    }
                }
            }
            
            buyToken = !buyToken; // Alternate
        }
        
        // Verify invariants
        uint256 finalPMin = OsitoPair(pair).pMin();
        (uint112 r0Final, uint112 r1Final,) = OsitoPair(pair).getReserves();
        uint256 finalK = uint256(r0Final) * uint256(r1Final);
        
        assertGe(finalPMin, initialPMin, "pMin decreased!");
        assertGe(finalK, initialK, "k decreased!");
    }
    
    /// @notice Fuzz test lending operations
    function testFuzz_LendingOperations(
        uint256 collateralAmount,
        uint256 borrowPercent,
        uint256 timeElapsed,
        bool shouldLiquidate
    ) public {
        // Setup
        collateralAmount = bound(collateralAmount, 100e18, 100_000e18);
        borrowPercent = bound(borrowPercent, 10, 80); // 10-80% LTV
        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        
        // Launch token with known parameters
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address token, address pair,) = launchpad.launchToken(
            "Lending Test",
            "LEND",
            1_000_000e18,
            100e18,
            3000,
            30,
            100_000e18
        );
        
        // Deploy lending vaults
        (address collateralVault, address lenderVault) = lendingFactory.deployVaults(
            token,
            address(weth),
            pair
        );
        
        // Fund lender vault
        vm.deal(charlie, 1000e18);
        vm.prank(charlie);
        weth.deposit{value: 1000e18}();
        vm.prank(charlie);
        weth.approve(lenderVault, 1000e18);
        vm.prank(charlie);
        LenderVault(lenderVault).deposit(1000e18, charlie);
        
        // Get collateral tokens (buy from AMM)
        vm.deal(bob, 50e18);
        vm.prank(bob);
        weth.deposit{value: 50e18}();
        vm.prank(bob);
        weth.transfer(pair, 50e18);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 amountInWithFee = 50e18 * (10000 - OsitoPair(pair).currentFeeBps());
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(bob);
        OsitoPair(pair).swap(tokenOut, 0, bob);
        
        // Use bounded collateral amount
        collateralAmount = bound(collateralAmount, 0, tokenOut);
        if (collateralAmount == 0) return;
        
        // Deposit collateral
        vm.prank(bob);
        OsitoToken(token).approve(collateralVault, collateralAmount);
        vm.prank(bob);
        CollateralVault(collateralVault).depositCollateral(collateralAmount);
        
        // Borrow based on pMin
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 maxBorrow = (collateralAmount * pMin * 80) / (100 * 1e18); // 80% of max
        uint256 borrowAmount = (maxBorrow * borrowPercent) / 100;
        
        if (borrowAmount > 0) {
            vm.prank(bob);
            CollateralVault(collateralVault).borrow(borrowAmount);
            
            // Advance time
            advanceTime(timeElapsed);
            
            // Check if position is healthy
            (uint256 collateral, uint256 debt, bool healthy) = 
                CollateralVault(collateralVault).getAccountHealth(bob);
            
            // Debt should have grown due to interest
            assertTrue(debt >= borrowAmount, "Debt didn't accrue");
            
            if (shouldLiquidate && !healthy) {
                // Attempt liquidation
                vm.deal(liquidator, debt);
                vm.prank(liquidator);
                weth.deposit{value: debt}();
                vm.prank(liquidator);
                weth.approve(collateralVault, debt);
                
                vm.prank(liquidator);
                CollateralVault(collateralVault).liquidate(bob, debt / 2);
                
                // Liquidator should have received collateral
                assertTrue(OsitoToken(token).balanceOf(liquidator) > 0);
            }
        }
    }
    
    /// @notice Fuzz test fee collection
    function testFuzz_FeeCollection(
        uint256 numTrades,
        uint256 avgTradeSize,
        uint256 burnPercent
    ) public {
        // Bound inputs
        numTrades = bound(numTrades, 1, 50);
        avgTradeSize = bound(avgTradeSize, 0.1e18, 10e18);
        burnPercent = bound(burnPercent, 0, 100);
        
        // Launch token
        vm.deal(alice, 100e18);
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Fee Test",
            "FEE",
            1_000_000e18,
            100e18,
            5000, // 50% fee
            30,
            100_000e18
        );
        
        uint256 initialSupply = OsitoToken(token).totalSupply();
        
        // Perform trades to generate fees
        for (uint i = 0; i < numTrades; i++) {
            uint256 tradeSize = (avgTradeSize * (90 + (i % 20))) / 100; // Vary trade size
            
            vm.deal(charlie, tradeSize);
            vm.prank(charlie);
            weth.deposit{value: tradeSize}();
            vm.prank(charlie);
            weth.transfer(pair, tradeSize);
            
            (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
            uint256 amountInWithFee = tradeSize * (10000 - OsitoPair(pair).currentFeeBps());
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < r0 / 3) {
                vm.prank(charlie);
                OsitoPair(pair).swap(tokenOut, 0, charlie);
                
                // Sometimes burn tokens
                if (i % 3 == 0 && burnPercent > 0) {
                    uint256 burnAmount = (tokenOut * burnPercent) / 100;
                    vm.prank(charlie);
                    OsitoToken(token).burn(burnAmount);
                }
            }
        }
        
        // Collect fees
        uint256 lpBalance = OsitoPair(pair).balanceOf(address(feeRouter));
        uint256 principal = FeeRouter(feeRouter).principalLp(address(pair));
        
        if (lpBalance > principal) {
            uint256 supplyBefore = OsitoToken(token).totalSupply();
            FeeRouter(feeRouter).collectFees(address(pair));
            uint256 supplyAfter = OsitoToken(token).totalSupply();
            
            // Supply should have decreased (tokens burned)
            assertTrue(supplyAfter < supplyBefore, "Tokens not burned");
            assertTrue(supplyAfter < initialSupply, "Supply didn't decrease");
        }
    }
}