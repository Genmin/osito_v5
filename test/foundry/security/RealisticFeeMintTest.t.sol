// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Test fee minting with realistic swap sizes
contract RealisticFeeMintTest is BaseTest {
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
    
    /// @notice Test with realistic 10% of liquidity swap
    function test_RealisticSwap_10Percent() public {
        // Initialize kLast with small swap
        deal(address(weth), alice, 1 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 0.1 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        
        // Realistic swap: 10% of liquidity
        deal(address(weth), alice, 10 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 10 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 lpMinted = pair.balanceOf(address(feeRouter)) - lpBefore;
        uint256 mintPercentage = (lpMinted * 100) / totalSupplyBefore;
        
        console2.log("10% liquidity swap -> LP mint %:", mintPercentage);
        assertLt(mintPercentage, 5, "Reasonable swap should mint < 5%");
    }
    
    /// @notice Test with very large but realistic swap (50% of liquidity)
    function test_LargeRealisticSwap_50Percent() public {
        // Initialize kLast
        deal(address(weth), alice, 1 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 0.1 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        
        // Large but realistic swap: 50% of liquidity
        deal(address(weth), alice, 50 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 50 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 lpMinted = pair.balanceOf(address(feeRouter)) - lpBefore;
        uint256 mintPercentage = (lpMinted * 100) / totalSupplyBefore;
        
        console2.log("50% liquidity swap -> LP mint %:", mintPercentage);
        assertLt(mintPercentage, 20, "Large swap should mint < 20%");
    }
    
    /// @notice Test the actual fee percentage captured
    function test_ActualFeeCapturePercentage() public {
        // Initialize kLast
        deal(address(weth), alice, 1 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 0.1 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        // Track the swap
        uint256 swapAmount = 10 ether;
        uint256 feeBps = pair.currentFeeBps();
        uint256 expectedFeeValue = swapAmount * feeBps / 10000;
        
        console2.log("Swap amount:", swapAmount);
        console2.log("Fee BPS:", feeBps);
        console2.log("Expected fee value:", expectedFeeValue);
        
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        
        // Do the swap
        deal(address(weth), alice, swapAmount);
        vm.prank(alice);
        _swap(pair, address(weth), swapAmount, alice);
        
        // Collect fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 lpMinted = pair.balanceOf(address(feeRouter)) - lpBefore;
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        
        // Calculate the value of LP minted
        uint256 totalSupply = pair.totalSupply();
        uint256 lpShareBps = (lpMinted * 10000) / totalSupply;
        uint256 wethInPool = pair.tokIsToken0() ? r1After : r0After;
        uint256 lpValueInWeth = (wethInPool * lpShareBps) / 10000;
        
        console2.log("LP minted:", lpMinted);
        console2.log("LP value in WETH:", lpValueInWeth);
        console2.log("Fee capture rate:", (lpValueInWeth * 100) / expectedFeeValue, "%");
        
        // Should capture ~90% of fees
        assertGt(lpValueInWeth * 100 / expectedFeeValue, 85, "Should capture > 85% of fees");
        assertLt(lpValueInWeth * 100 / expectedFeeValue, 95, "Should capture < 95% of fees");
    }
    
    /// @notice The "exploit" only works with unrealistic swaps
    function test_UnrealisticSwapScenario() public {
        // Initialize kLast
        deal(address(weth), alice, 1 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 0.1 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        
        // UNREALISTIC swap: 500% of liquidity (5x!)
        deal(address(weth), alice, 500 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 500 ether, alice);
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 lpMinted = pair.balanceOf(address(feeRouter)) - lpBefore;
        uint256 mintPercentage = (lpMinted * 100) / totalSupplyBefore;
        
        console2.log("500% liquidity swap -> LP mint %:", mintPercentage);
        console2.log("This is EXPECTED behavior for such an extreme swap!");
        
        // This SHOULD mint a lot because the swap fundamentally changed the pool
        assertGt(mintPercentage, 50, "Extreme swaps naturally mint significant LP");
    }
}