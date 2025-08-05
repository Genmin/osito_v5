// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {console2} from "forge-std/console2.sol";

contract OsitoPairTest is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token with initial liquidity
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST",
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialization() public view {
        assertEq(pair.name(), "Osito LP");
        assertEq(pair.symbol(), "OSITO-LP");
        assertEq(pair.decimals(), 18);
        
        // Check pair setup
        assertTrue(pair.token0() != address(0));
        assertEq(pair.token1(), address(weth));
        assertTrue(pair.feeRouter() == address(feeRouter));
        
        // Check initial fees
        assertEq(pair.startFeeBps(), 9900); // 99%
        assertEq(pair.endFeeBps(), 30); // 0.3%
    }
    
    function test_InitialReserves() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        
        if (pair.tokIsToken0()) {
            assertEq(r0, SUPPLY); // All tokens in pool initially
            assertEq(r1, INITIAL_LIQUIDITY);
        } else {
            assertEq(r0, INITIAL_LIQUIDITY);
            assertEq(r1, SUPPLY);
        }
    }
    
    function test_InitialPMin() public view {
        uint256 pMin = pair.pMin();
        
        // Initially all tokens are in pool, so pMin = spot price
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 expectedPMin = pair.tokIsToken0() 
            ? (uint256(r1) * 1e18) / uint256(r0)
            : (uint256(r0) * 1e18) / uint256(r1);
            
        assertEq(pMin, expectedPMin, "Initial pMin should equal spot price");
    }
    
    // ============ Swap Tests ============
    
    function test_SwapExactWETHForTokens() public {
        uint256 wethIn = 1 ether;
        
        // Alice swaps WETH for tokens
        vm.startPrank(alice);
        weth.approve(address(pair), wethIn);
        
        uint256 tokensBefore = token.balanceOf(alice);
        _swap(pair, address(weth), wethIn, alice);
        uint256 tokensReceived = token.balanceOf(alice) - tokensBefore;
        
        vm.stopPrank();
        
        assertTrue(tokensReceived > 0, "Should receive tokens");
        
        // Check pMin decreased (tokens left the pool)
        uint256 pMin = pair.pMin();
        assertTrue(pMin > 0, "pMin should be positive");
    }
    
    function test_SwapExactTokensForWETH() public {
        // First get some tokens
        vm.prank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        
        uint256 tokenBalance = token.balanceOf(alice);
        uint256 swapAmount = tokenBalance / 2;
        
        // Swap tokens back for WETH
        vm.startPrank(alice);
        token.approve(address(pair), swapAmount);
        
        uint256 wethBefore = weth.balanceOf(alice);
        _swap(pair, address(token), swapAmount, alice);
        uint256 wethReceived = weth.balanceOf(alice) - wethBefore;
        
        vm.stopPrank();
        
        assertTrue(wethReceived > 0, "Should receive WETH");
    }
    
    function test_SwapMaintainsK() public {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        
        // Do a swap
        vm.prank(alice);
        _swap(pair, address(weth), 0.5 ether, alice);
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        
        // K should increase due to fees
        assertTrue(kAfter >= kBefore, "K should not decrease");
    }
    
    function test_SwapWithHighInitialFee() public view {
        uint256 currentFee = pair.currentFeeBps();
        assertEq(currentFee, 9900, "Initial fee should be 99%");
    }
    
    function test_FeeDecay() public {
        uint256 feeBefore = pair.currentFeeBps();
        
        // Burn some tokens to trigger fee decay
        vm.prank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        
        uint256 tokenBalance = token.balanceOf(alice);
        vm.prank(alice);
        token.burn(tokenBalance / 10); // Burn 10%
        
        uint256 feeAfter = pair.currentFeeBps();
        assertTrue(feeAfter < feeBefore, "Fee should decay after burns");
    }
    
    // ============ LP Token Restriction Tests ============
    
    function test_LPTransferRestriction() public {
        // Try to transfer LP tokens (should fail)
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        
        if (lpBalance > 0) {
            vm.prank(address(feeRouter));
            vm.expectRevert("RESTRICTED");
            pair.transfer(alice, lpBalance);
        }
    }
    
    function test_OnlyFeeRouterCanHoldLP() public {
        // Check that only feeRouter and the pair itself can hold LP
        uint256 totalSupply = pair.totalSupply();
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        uint256 pairBalance = pair.balanceOf(address(pair));
        uint256 deadBalance = pair.balanceOf(address(0xdead));
        
        // Account for minimum liquidity locked
        uint256 minLiquidity = 1000;
        
        assertApproxEq(
            feeRouterBalance + pairBalance + deadBalance + minLiquidity,
            totalSupply,
            10,
            "Only authorized addresses should hold LP"
        );
    }
    
    // ============ pMin Tests ============
    
    function test_pMinIncreasesWithBurns() public {
        uint256 pMinBefore = pair.pMin();
        
        // Get tokens and burn them
        vm.prank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        
        uint256 tokenBalance = token.balanceOf(alice);
        vm.prank(alice);
        token.burn(tokenBalance);
        
        uint256 pMinAfter = pair.pMin();
        assertTrue(pMinAfter > pMinBefore, "pMin should increase after burns");
    }
    
    function test_pMinNeverDecreases() public {
        uint256 lastPMin = pair.pMin();
        
        // Do multiple swaps and burns
        for (uint256 i = 0; i < 10; i++) {
            // Swap WETH for tokens
            vm.prank(alice);
            _swap(pair, address(weth), 0.1 ether, alice);
            
            uint256 currentPMin = pair.pMin();
            assertTrue(currentPMin >= lastPMin, "pMin should never decrease");
            lastPMin = currentPMin;
            
            // Swap tokens back
            uint256 tokenBalance = token.balanceOf(alice);
            if (tokenBalance > 0) {
                vm.prank(alice);
                _swap(pair, address(token), tokenBalance / 10, alice);
                
                currentPMin = pair.pMin();
                assertTrue(currentPMin >= lastPMin, "pMin should never decrease");
                lastPMin = currentPMin;
            }
        }
    }
    
    // ============ Fee Collection Tests ============
    
    function test_FeeCollection() public {
        // Generate fees through swaps
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            _swap(pair, address(weth), 0.1 ether, alice);
        }
        
        // Collect fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        // Check that fees were minted to feeRouter
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        assertTrue(lpBalance > 0, "FeeRouter should receive LP tokens");
    }
    
    // ============ Edge Case Tests ============
    
    function test_MinimumLiquidityLocked() public view {
        // Check that minimum liquidity is locked
        uint256 deadBalance = pair.balanceOf(address(0xdead));
        assertEq(deadBalance, 1000, "Minimum liquidity should be locked");
    }
    
    function test_CannotCallSyncOrSkim() public {
        // sync() and skim() should not exist to prevent attacks
        (bool success,) = address(pair).call(abi.encodeWithSignature("sync()"));
        assertFalse(success, "sync() should not exist");
        
        (success,) = address(pair).call(abi.encodeWithSignature("skim(address)", alice));
        assertFalse(success, "skim() should not exist");
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzz_Swap(uint256 amountIn, bool isWethIn) public {
        amountIn = bound(amountIn, 1000, isWethIn ? 1 ether : token.balanceOf(alice));
        
        if (!isWethIn) {
            // First get some tokens
            vm.prank(alice);
            _swap(pair, address(weth), 0.5 ether, alice);
            amountIn = bound(amountIn, 1000, token.balanceOf(alice));
        }
        
        address tokenIn = isWethIn ? address(weth) : address(token);
        
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        
        vm.prank(alice);
        uint256 amountOut = _swap(pair, tokenIn, amountIn, alice);
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        
        assertTrue(amountOut > 0, "Should receive output");
        assertTrue(kAfter >= kBefore, "K should not decrease");
    }
    
    function testFuzz_pMinMonotonicity(uint256 numSwaps, uint256 numBurns) public {
        numSwaps = bound(numSwaps, 1, 20);
        numBurns = bound(numBurns, 1, 10);
        
        uint256 lastPMin = pair.pMin();
        
        for (uint256 i = 0; i < numSwaps; i++) {
            // Random swap
            uint256 swapAmount = bound(uint256(keccak256(abi.encode(i))), 0.01 ether, 0.5 ether);
            vm.prank(alice);
            _swap(pair, address(weth), swapAmount, alice);
            
            uint256 currentPMin = pair.pMin();
            assertTrue(currentPMin >= lastPMin, "pMin should never decrease");
            lastPMin = currentPMin;
            
            // Random burn
            if (i % 3 == 0 && i < numBurns) {
                uint256 burnAmount = token.balanceOf(alice) / 10;
                if (burnAmount > 0) {
                    vm.prank(alice);
                    token.burn(burnAmount);
                    
                    currentPMin = pair.pMin();
                    assertTrue(currentPMin >= lastPMin, "pMin should increase after burn");
                    lastPMin = currentPMin;
                }
            }
        }
    }
    
    // ============ Gas Tests ============
    
    function test_GasSwap() public {
        vm.prank(alice);
        uint256 gasStart = gasleft();
        _swap(pair, address(weth), 0.1 ether, alice);
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for swap:", gasUsed);
        assertTrue(gasUsed < 150000, "Swap should be gas efficient");
    }
}