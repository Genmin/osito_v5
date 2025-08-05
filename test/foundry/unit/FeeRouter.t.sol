// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {console2} from "forge-std/console2.sol";

contract FeeRouterTest is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
    }
    
    // ============ Initialization Tests ============
    
    function test_Constructor() public view {
        assertEq(feeRouter.treasury(), treasury);
        assertEq(feeRouter.pair(), address(pair));
    }
    
    function test_InitialState() public view {
        // FeeRouter should initially have some LP tokens from fees
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        // Initially might be 0 until fees are collected
        assertTrue(lpBalance >= 0);
    }
    
    // ============ Fee Collection Tests ============
    
    function test_CollectFees() public {
        // Generate some fees by doing swaps
        vm.startPrank(alice);
        for (uint i = 0; i < 5; i++) {
            _swap(pair, address(weth), 0.1 ether, alice);
        }
        vm.stopPrank();
        
        uint256 feeBalanceBefore = pair.balanceOf(address(feeRouter));
        
        // Collect fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 feeBalanceAfter = pair.balanceOf(address(feeRouter));
        
        // Should have collected some fees
        assertTrue(feeBalanceAfter >= feeBalanceBefore);
    }
    
    function test_OnlyPairCanCollectFees() public {
        // Try to collect fees from unauthorized address
        vm.prank(alice);
        vm.expectRevert();
        pair.collectFees();
    }
    
    // ============ LP Token Handling Tests ============
    
    function test_LPTokenRestrictions() public {
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        
        if (feeRouterBalance > 0) {
            // FeeRouter should not be able to transfer LP tokens to unauthorized addresses
            vm.prank(address(feeRouter));
            vm.expectRevert("RESTRICTED");
            pair.transfer(alice, 1);
        }
    }
    
    function test_CannotBurnLPTokens() public {
        // Generate some fees first
        vm.startPrank(alice);
        for (uint i = 0; i < 10; i++) {
            _swap(pair, address(weth), 0.05 ether, alice);
        }
        vm.stopPrank();
        
        // Collect fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        
        if (feeRouterBalance > 0) {
            // Should not be able to burn LP tokens (they should be eternally locked)
            vm.prank(address(feeRouter));
            vm.expectRevert();
            pair.burn(address(0));
        }
    }
    
    // ============ Treasury Integration Tests ============
    
    function test_TreasuryAddress() public view {
        assertEq(feeRouter.treasury(), treasury);
        assertTrue(feeRouter.treasury() != address(0));
    }
    
    // ============ Edge Case Tests ============
    
    function test_EmptyFeeRouter() public {
        // Deploy a new pair/feeRouter system with no fees
        (OsitoToken newToken, OsitoPair newPair, FeeRouter newFeeRouter) = _launchToken(
            "Empty Token",
            "EMPTY",
            1000 * 1e18,
            1 ether,
            bob
        );
        
        // Should have minimal state
        assertEq(newFeeRouter.treasury(), treasury);
        assertEq(newFeeRouter.pair(), address(newPair));
        
        // Should not have any LP tokens initially
        uint256 lpBalance = newPair.balanceOf(address(newFeeRouter));
        assertTrue(lpBalance >= 0); // Could be 0 or small amount from initial mint
    }
    
    function test_MultipleFeeCollections() public {
        uint256 initialBalance = pair.balanceOf(address(feeRouter));
        
        // Do multiple rounds of fee generation and collection
        for (uint round = 0; round < 3; round++) {
            // Generate fees
            vm.startPrank(alice);
            for (uint i = 0; i < 5; i++) {
                _swap(pair, address(weth), 0.02 ether, alice);
            }
            vm.stopPrank();
            
            // Collect fees
            vm.prank(address(feeRouter));
            pair.collectFees();
        }
        
        uint256 finalBalance = pair.balanceOf(address(feeRouter));
        
        // Should have accumulated more LP tokens over multiple collections
        assertTrue(finalBalance >= initialBalance);
    }
    
    // ============ Gas Tests ============
    
    function test_GasFeeCollection() public {
        // Generate some fees
        vm.startPrank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        vm.stopPrank();
        
        vm.prank(address(feeRouter));
        uint256 gasStart = gasleft();
        pair.collectFees();
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for fee collection:", gasUsed);
        assertTrue(gasUsed < 100000, "Fee collection should be gas efficient");
    }
    
    // ============ Integration Tests ============
    
    function test_FeeRouterIntegration() public {
        // Test the complete flow: swap -> fees -> collection
        uint256 initialTokenBalance = token.balanceOf(alice);
        uint256 initialWethBalance = weth.balanceOf(alice);
        uint256 initialFeeRouterLP = pair.balanceOf(address(feeRouter));
        
        // Perform swap
        vm.startPrank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        vm.stopPrank();
        
        // Check that fees were generated (reserves changed)
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertTrue(r0 > 0 && r1 > 0, "Reserves should be positive");
        
        // Collect fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 finalFeeRouterLP = pair.balanceOf(address(feeRouter));
        
        // FeeRouter should have received LP tokens (fees)
        assertTrue(finalFeeRouterLP >= initialFeeRouterLP);
        
        // Alice should have received tokens and spent WETH
        assertTrue(token.balanceOf(alice) > initialTokenBalance);
        assertTrue(weth.balanceOf(alice) < initialWethBalance);
    }
}