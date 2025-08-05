// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract OsitoPairTest is BaseTest {
    OsitoPair public pair;
    OsitoToken public token;
    MockWETH public weth;
    FeeRouter public feeRouter;
    
    uint256 constant TOKEN_SUPPLY = 1_000_000e18;
    uint256 constant INITIAL_WETH = 100e18;
    uint256 constant START_FEE_BPS = 9900; // 99%
    uint256 constant END_FEE_BPS = 30; // 0.3%
    uint256 constant FEE_DECAY_TARGET = 100_000e18;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy WETH
        weth = new MockWETH();
        
        // Deploy FeeRouter with treasury
        address treasury = makeAddr("treasury");
        feeRouter = new FeeRouter(treasury);
        
        // Deploy pair with placeholder token0
        pair = new OsitoPair(
            address(0),
            address(weth),
            address(feeRouter),
            START_FEE_BPS,
            END_FEE_BPS,
            FEE_DECAY_TARGET,
            true // tokIsToken0
        );
        
        // Deploy token
        token = new OsitoToken("Test Osito", "TOSITO", TOKEN_SUPPLY, address(pair));
        
        // Initialize pair with token
        pair.initialize(address(token));
        
        // Add initial liquidity
        vm.prank(alice);
        weth.deposit{value: INITIAL_WETH}();
        
        vm.prank(alice);
        weth.transfer(address(pair), INITIAL_WETH);
        
        pair.mint(address(feeRouter));
        feeRouter.setPrincipalLp(address(pair));
    }
    
    function test_InitialState() public {
        assertEq(pair.token0(), address(token));
        assertEq(pair.token1(), address(weth));
        assertEq(pair.feeRouter(), address(feeRouter));
        assertEq(pair.tokIsToken0(), true);
        assertEq(pair.startFeeBps(), START_FEE_BPS);
        assertEq(pair.endFeeBps(), END_FEE_BPS);
        assertEq(pair.feeDecayTarget(), FEE_DECAY_TARGET);
        assertEq(pair.initialSupply(), TOKEN_SUPPLY);
    }
    
    function test_GetReserves() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, TOKEN_SUPPLY);
        assertEq(r1, INITIAL_WETH);
    }
    
    function test_PMin_InitialState() public {
        uint256 pMin = pair.pMin();
        assertTrue(pMin > 0);
        
        // At launch with all tokens in pool, pMin should be close to spot price
        uint256 spotPrice = (INITIAL_WETH * 1e18) / TOKEN_SUPPLY;
        assertApproxEqRel(pMin, spotPrice, 1e16, "pMin should be close to spot");
    }
    
    function test_CurrentFeeBps_NoDecay() public {
        assertEq(pair.currentFeeBps(), START_FEE_BPS);
    }
    
    function test_CurrentFeeBps_PartialDecay() public {
        // Burn some tokens to trigger fee decay
        uint256 targetBurn = FEE_DECAY_TARGET / 2;
        
        // First need to get tokens out of the pool via swap
        uint256 wethIn = 10e18;
        vm.prank(bob);
        weth.deposit{value: wethIn}();
        vm.prank(bob);
        weth.transfer(address(pair), wethIn);
        
        // Calculate expected output
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountInWithFee = wethIn * (10000 - pair.currentFeeBps());
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(bob);
        pair.swap(tokenOut, 0, bob);
        
        // Burn tokens up to target
        uint256 burnAmount = tokenOut > targetBurn ? targetBurn : tokenOut;
        vm.prank(bob);
        token.burn(burnAmount);
        
        // Fee should decay proportionally
        uint256 expectedFee = START_FEE_BPS - ((START_FEE_BPS - END_FEE_BPS) * burnAmount / FEE_DECAY_TARGET);
        assertEq(pair.currentFeeBps(), expectedFee);
    }
    
    function test_Swap_BuyToken() public {
        uint256 wethIn = 1e18;
        
        // Get initial reserves
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        
        // Bob buys tokens with WETH
        vm.prank(bob);
        weth.deposit{value: wethIn}();
        vm.prank(bob);
        weth.transfer(address(pair), wethIn);
        
        // Calculate expected output
        uint256 amountInWithFee = wethIn * (10000 - pair.currentFeeBps());
        uint256 expectedOut = (amountInWithFee * r0Before) / ((r1Before * 10000) + amountInWithFee);
        
        vm.prank(bob);
        pair.swap(expectedOut, 0, bob);
        
        assertEq(token.balanceOf(bob), expectedOut);
        
        // Check k increased due to fees
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        assertTrue(kAfter > kBefore);
    }
    
    function test_Swap_SellToken() public {
        // First get some tokens by buying
        uint256 wethIn = 10e18;
        vm.prank(bob);
        weth.deposit{value: wethIn}();
        vm.prank(bob);
        weth.transfer(address(pair), wethIn);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountInWithFee = wethIn * (10000 - pair.currentFeeBps());
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(bob);
        pair.swap(tokenOut, 0, bob);
        
        // Now sell tokens back
        uint256 tokenIn = tokenOut / 2;
        vm.prank(bob);
        token.transfer(address(pair), tokenIn);
        
        (r0, r1,) = pair.getReserves();
        amountInWithFee = tokenIn * (10000 - pair.currentFeeBps());
        uint256 wethOut = (amountInWithFee * r1) / ((r0 * 10000) + amountInWithFee);
        
        uint256 bobWethBefore = weth.balanceOf(bob);
        vm.prank(bob);
        pair.swap(0, wethOut, bob);
        
        assertEq(weth.balanceOf(bob), bobWethBefore + wethOut);
    }
    
    function test_Transfer_Restriction() public {
        // Try to transfer LP tokens to non-feeRouter address
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        
        vm.prank(address(feeRouter));
        vm.expectRevert("RESTRICTED");
        pair.transfer(alice, lpBalance);
        
        // Should work when transferring to feeRouter or pair itself
        vm.prank(address(feeRouter));
        pair.transfer(address(pair), 1);
    }
    
    function test_Mint_Restriction() public {
        // Only feeRouter can receive minted LP tokens
        vm.expectRevert("RESTRICTED");
        pair.mint(alice);
        
        // Should work for feeRouter
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        
        // First, swap to generate some fees
        vm.prank(bob);
        weth.deposit{value: 10e18}();
        vm.prank(bob);
        weth.transfer(address(pair), 10e18);
        
        // Do a swap to generate fees
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountInWithFee = 10e18 * (10000 - pair.currentFeeBps());
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        vm.prank(bob);
        pair.swap(tokenOut, 0, bob);
        
        // Now bob can add liquidity with his tokens
        vm.prank(bob);
        token.transfer(address(pair), tokenOut / 10); // Add some tokens back
        vm.prank(bob);
        weth.deposit{value: 1e18}();
        vm.prank(bob);
        weth.transfer(address(pair), 1e18);
        
        pair.mint(address(feeRouter));
        assertTrue(pair.balanceOf(address(feeRouter)) > lpBefore);
    }
    
    function test_PMin_IncreasesWithBurns() public {
        uint256 pMinBefore = pair.pMin();
        
        // Get tokens out via swap
        uint256 wethIn = 10e18;
        vm.prank(bob);
        weth.deposit{value: wethIn}();
        vm.prank(bob);
        weth.transfer(address(pair), wethIn);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountInWithFee = wethIn * (10000 - pair.currentFeeBps());
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        vm.prank(bob);
        pair.swap(tokenOut, 0, bob);
        
        // Burn tokens
        vm.prank(bob);
        token.burn(tokenOut);
        
        uint256 pMinAfter = pair.pMin();
        assertTrue(pMinAfter > pMinBefore, "pMin should increase after burn");
    }
    
    // Fuzz tests
    function testFuzz_Swap(uint256 wethIn, bool buyToken) public {
        wethIn = bound(wethIn, 0.01e18, 50e18);
        
        vm.prank(bob);
        weth.deposit{value: wethIn}();
        vm.prank(bob);
        weth.transfer(address(pair), wethIn);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        
        if (buyToken) {
            uint256 amountInWithFee = wethIn * (10000 - pair.currentFeeBps());
            uint256 expectedOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (expectedOut > 0 && expectedOut < r0) {
                vm.prank(bob);
                pair.swap(expectedOut, 0, bob);
                assertEq(token.balanceOf(bob), expectedOut);
            }
        }
    }
}