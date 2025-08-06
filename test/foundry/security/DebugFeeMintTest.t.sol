// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Debug test to understand the fee mint issue
contract DebugFeeMintTest is BaseTest {
    using FixedPointMathLib for uint256;
    
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    function setUp() public override {
        super.setUp();
        
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
    }
    
    function test_DebugFeeMintExploit() public {
        console2.log("=== INITIAL STATE ===");
        (uint112 r0, uint112 r1,) = pair.getReserves();
        console2.log("Initial reserves r0:", r0);
        console2.log("Initial reserves r1:", r1);
        console2.log("Initial K:", uint256(r0) * uint256(r1));
        console2.log("Initial kLast:", pair.kLast());
        console2.log("Initial totalSupply:", pair.totalSupply());
        console2.log("Initial feeRouter LP:", pair.balanceOf(address(feeRouter)));
        
        // First, do a small swap to set kLast
        console2.log("\n=== SMALL INITIAL SWAP ===");
        deal(address(weth), alice, 10 ether);
        vm.startPrank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        vm.stopPrank();
        
        // Collect fees to set kLast
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        (r0, r1,) = pair.getReserves();
        console2.log("After first swap r0:", r0);
        console2.log("After first swap r1:", r1);
        console2.log("After first swap K:", uint256(r0) * uint256(r1));
        console2.log("After first swap kLast:", pair.kLast());
        console2.log("After first swap totalSupply:", pair.totalSupply());
        console2.log("After first swap feeRouter LP:", pair.balanceOf(address(feeRouter)));
        
        // Now do the massive swap
        console2.log("\n=== MASSIVE SWAP ===");
        uint256 attackSwapAmount = 500 ether;
        deal(address(weth), alice, attackSwapAmount);
        
        uint256 lpBalanceBefore = pair.balanceOf(address(feeRouter));
        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 kLastBefore = pair.kLast();
        
        vm.startPrank(alice);
        weth.approve(address(pair), attackSwapAmount);
        _swap(pair, address(weth), attackSwapAmount, alice);
        vm.stopPrank();
        
        (r0, r1,) = pair.getReserves();
        uint256 kAfterSwap = uint256(r0) * uint256(r1);
        console2.log("After massive swap r0:", r0);
        console2.log("After massive swap r1:", r1);
        console2.log("After massive swap K:", kAfterSwap);
        
        // Calculate what SHOULD be minted
        uint256 rootK = kAfterSwap.sqrt();
        uint256 rootKLast = kLastBefore.sqrt();
        console2.log("rootK:", rootK);
        console2.log("rootKLast:", rootKLast);
        console2.log("rootK - rootKLast:", rootK - rootKLast);
        
        // The UniV2 formula
        uint256 numerator = totalSupplyBefore * (rootK - rootKLast);
        uint256 denominator = rootK * 5 + rootKLast;
        uint256 oneSixth = numerator / denominator;
        uint256 expectedLiquidity = oneSixth * 54 / 10;
        
        console2.log("Expected numerator:", numerator);
        console2.log("Expected denominator:", denominator);
        console2.log("Expected oneSixth:", oneSixth);
        console2.log("Expected liquidity (90%):", expectedLiquidity);
        console2.log("As % of totalSupply:", (expectedLiquidity * 100) / totalSupplyBefore);
        
        // Collect fees
        console2.log("\n=== FEE COLLECTION ===");
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 lpMinted = pair.balanceOf(address(feeRouter)) - lpBalanceBefore;
        uint256 totalSupplyAfter = pair.totalSupply();
        
        console2.log("Actual LP minted:", lpMinted);
        console2.log("Total supply after:", totalSupplyAfter);
        console2.log("Actual mint %:", (lpMinted * 100) / totalSupplyBefore);
        
        // Compare expected vs actual
        console2.log("\n=== ANALYSIS ===");
        if (lpMinted > expectedLiquidity) {
            console2.log("OVERMINT by:", lpMinted - expectedLiquidity);
        } else if (lpMinted < expectedLiquidity) {
            console2.log("UNDERMINT by:", expectedLiquidity - lpMinted);
        } else {
            console2.log("EXACT MATCH!");
        }
    }
}