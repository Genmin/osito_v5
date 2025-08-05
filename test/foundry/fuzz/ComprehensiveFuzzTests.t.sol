// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {PMinLib} from "../../../src/libraries/PMinLib.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Comprehensive fuzz testing for all protocol functions
contract ComprehensiveFuzzTests is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token
        (token, pair, feeRouter) = _launchToken(
            "Fuzz Token",
            "FUZZ",
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
        
        // Setup lending
        lenderVault = LenderVault(lendingFactory.lenderVault());
        vault = _createLendingMarket(address(pair));
        
        // Fund lender vault
        vm.startPrank(bob);
        weth.approve(address(lenderVault), type(uint256).max);
        lenderVault.deposit(100 ether, bob);
        vm.stopPrank();
        
        // Get tokens for testing
        vm.startPrank(alice);
        weth.approve(address(pair), 5 ether);
        _swap(pair, address(weth), 5 ether, alice);
        vm.stopPrank();
    }
    
    // ============ TOKEN FUZZ TESTS ============
    
    /// @notice Fuzz test token transfers with random amounts and recipients
    function testFuzz_TokenTransfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != address(0x000000000022D473030F116dDEE9F6B43aC78BA3)); // Exclude Permit2
        vm.assume(to.code.length == 0); // EOA only for simplicity
        
        uint256 aliceBalance = token.balanceOf(alice);
        amount = bound(amount, 0, aliceBalance);
        
        vm.prank(alice);
        bool success = token.transfer(to, amount);
        
        assertTrue(success, "Transfer should succeed");
        assertEq(token.balanceOf(to), amount, "Recipient should receive amount");
        assertEq(token.balanceOf(alice), aliceBalance - amount, "Sender balance should decrease");
    }
    
    /// @notice Fuzz test token burns with random amounts
    function testFuzz_TokenBurn(uint256 amount) public {
        uint256 aliceBalance = token.balanceOf(alice);
        amount = bound(amount, 0, aliceBalance);
        
        uint256 totalSupplyBefore = token.totalSupply();
        
        vm.prank(alice);
        token.burn(amount);
        
        assertEq(token.balanceOf(alice), aliceBalance - amount, "Balance should decrease");
        assertEq(token.totalSupply(), totalSupplyBefore - amount, "Total supply should decrease");
    }
    
    /// @notice Fuzz test approvals and transferFrom
    function testFuzz_TokenApproval(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.assume(spender != alice);
        vm.assume(spender != address(0x000000000022D473030F116dDEE9F6B43aC78BA3)); // Exclude Permit2
        
        uint256 aliceBalance = token.balanceOf(alice);
        amount = bound(amount, 0, aliceBalance);
        
        vm.prank(alice);
        token.approve(spender, amount);
        
        assertEq(token.allowance(alice, spender), amount, "Allowance should be set");
        
        if (amount > 0) {
            vm.prank(spender);
            bool success = token.transferFrom(alice, spender, amount);
            assertTrue(success, "TransferFrom should succeed");
            assertEq(token.balanceOf(spender), amount, "Spender should receive tokens");
        }
    }
    
    // ============ PAIR FUZZ TESTS ============
    
    /// @notice Fuzz test swaps with random amounts
    function testFuzz_PairSwap(uint256 amountIn, bool swapWETHForTokens) public {
        if (swapWETHForTokens) {
            uint256 wethBalance = weth.balanceOf(alice);
            amountIn = bound(amountIn, 0.01 ether, wethBalance / 2);
            
            vm.startPrank(alice);
            weth.approve(address(pair), amountIn);
            
            uint256 tokensBefore = token.balanceOf(alice);
            _swap(pair, address(weth), amountIn, alice);
            uint256 tokensAfter = token.balanceOf(alice);
            
            assertTrue(tokensAfter > tokensBefore, "Should receive tokens");
            vm.stopPrank();
        } else {
            uint256 tokenBalance = token.balanceOf(alice);
            amountIn = bound(amountIn, 1, tokenBalance / 2);
            
            vm.startPrank(alice);
            token.approve(address(pair), amountIn);
            
            uint256 wethBefore = weth.balanceOf(alice);
            _swap(pair, address(token), amountIn, alice);
            uint256 wethAfter = weth.balanceOf(alice);
            
            assertTrue(wethAfter > wethBefore, "Should receive WETH");
            vm.stopPrank();
        }
    }
    
    /// @notice Fuzz test that pMin behaves correctly with random operations
    function testFuzz_PMinBehavior(uint256 burnAmount, uint256 swapAmount) public {
        uint256 pMinBefore = pair.pMin();
        
        // Burn some tokens (should increase pMin)
        uint256 aliceBalance = token.balanceOf(alice);
        burnAmount = bound(burnAmount, 0, aliceBalance / 4);
        
        if (burnAmount > 0) {
            vm.prank(alice);
            token.burn(burnAmount);
        }
        
        uint256 pMinAfterBurn = pair.pMin();
        
        // Swap some tokens (may affect pMin through reserves)
        swapAmount = bound(swapAmount, 0, aliceBalance / 4);
        if (swapAmount > 0 && swapAmount <= token.balanceOf(alice)) {
            vm.startPrank(alice);
            token.approve(address(pair), swapAmount);
            _swap(pair, address(token), swapAmount, alice);
            vm.stopPrank();
        }
        
        uint256 pMinAfterSwap = pair.pMin();
        
        // pMin should increase or stay same after burns
        if (burnAmount > 0) {
            assertGe(pMinAfterBurn, pMinBefore, "pMin should not decrease from burns");
        }
        
        // pMin should remain positive
        assertTrue(pMinAfterSwap > 0, "pMin should always be positive");
    }
    
    /// @notice Fuzz test fee calculation with random token supply changes
    function testFuzz_FeeDecay(uint256 burnAmount) public {
        uint256 aliceBalance = token.balanceOf(alice);
        burnAmount = bound(burnAmount, 0, aliceBalance);
        
        uint256 feeBefore = pair.currentFeeBps();
        uint256 startFee = pair.startFeeBps();
        uint256 endFee = pair.endFeeBps();
        
        if (burnAmount > 0) {
            vm.prank(alice);
            token.burn(burnAmount);
        }
        
        uint256 feeAfter = pair.currentFeeBps();
        
        // Fee should be within bounds
        assertGe(feeAfter, endFee, "Fee should not go below minimum");
        assertLe(feeAfter, startFee, "Fee should not exceed maximum");
        
        // If tokens were burned, fee should decrease or stay same
        if (burnAmount > 0) {
            assertLe(feeAfter, feeBefore, "Fee should decrease with burns");
        }
    }
    
    // ============ VAULT FUZZ TESTS ============
    
    /// @notice Fuzz test collateral deposits with random amounts
    function testFuzz_CollateralDeposit(uint256 amount) public {
        uint256 aliceBalance = token.balanceOf(alice);
        amount = bound(amount, 1, aliceBalance);
        
        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(alice), amount, "Collateral should be recorded");
        assertEq(token.balanceOf(address(vault)), amount, "Vault should hold tokens");
    }
    
    /// @notice Fuzz test borrowing within pMin limits
    function testFuzz_BorrowingWithinLimits(uint256 collateralAmount, uint256 borrowRatio) public {
        uint256 aliceBalance = token.balanceOf(alice);
        collateralAmount = bound(collateralAmount, 1000 * 1e18, aliceBalance);
        borrowRatio = bound(borrowRatio, 1, 90); // 1-90% of max
        
        // Deposit collateral
        vm.startPrank(alice);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        // Calculate max borrow and borrow a percentage
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateralAmount * pMin) / 1e18;
        uint256 borrowAmount = (maxBorrow * borrowRatio) / 100;
        
        // Ensure there's enough liquidity
        uint256 availableLiquidity = lenderVault.totalAssets() - lenderVault.totalBorrows();
        if (borrowAmount <= availableLiquidity) {
            uint256 wethBefore = weth.balanceOf(alice);
            vault.borrow(borrowAmount);
            uint256 wethAfter = weth.balanceOf(alice);
            
            assertEq(wethAfter - wethBefore, borrowAmount, "Should receive borrowed amount");
            
            (uint256 principal,) = vault.accountBorrows(alice);
            assertEq(principal, borrowAmount, "Should record debt");
        }
        
        vm.stopPrank();
    }
    
    /// @notice Fuzz test repayments with random amounts
    function testFuzz_Repayment(uint256 collateralAmount, uint256 borrowAmount, uint256 repayRatio) public {
        uint256 aliceBalance = token.balanceOf(alice);
        collateralAmount = bound(collateralAmount, 1000 * 1e18, aliceBalance / 2);
        repayRatio = bound(repayRatio, 1, 100);
        
        // Setup position
        vm.startPrank(alice);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateralAmount * pMin) / 1e18;
        borrowAmount = bound(borrowAmount, 0.1 ether, maxBorrow / 2);
        
        uint256 availableLiquidity = lenderVault.totalAssets() - lenderVault.totalBorrows();
        if (borrowAmount <= availableLiquidity) {
            vault.borrow(borrowAmount);
            
            // Repay a percentage
            uint256 repayAmount = (borrowAmount * repayRatio) / 100;
            weth.approve(address(vault), repayAmount);
            vault.repay(repayAmount);
            
            (uint256 remainingDebt,) = vault.accountBorrows(alice);
            uint256 expectedRemaining = borrowAmount - repayAmount;
            
            if (repayAmount >= borrowAmount) {
                assertEq(remainingDebt, 0, "Debt should be cleared if fully repaid");
            } else {
                assertEq(remainingDebt, expectedRemaining, "Partial repayment should reduce debt");
            }
        }
        
        vm.stopPrank();
    }
    
    // ============ PMIN LIBRARY FUZZ TESTS ============
    
    /// @notice Fuzz test PMinLib calculations with random inputs
    function testFuzz_PMinCalculation(
        uint256 tokReserve,
        uint256 qtReserve, 
        uint256 totalSupply,
        uint256 feeBps
    ) public pure {
        tokReserve = bound(tokReserve, 1e18, 1e30);
        qtReserve = bound(qtReserve, 1e18, 1e30);
        totalSupply = bound(totalSupply, 1e18, 1e30);
        feeBps = bound(feeBps, 30, 9900); // 0.3% to 99%
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, totalSupply, feeBps);
        
        // pMin should always be positive
        assertTrue(pMin > 0, "pMin should be positive");
        
        // pMin should be less than current spot price (it's a floor)
        uint256 spotPrice = (qtReserve * 1e18) / tokReserve;
        assertLe(pMin, spotPrice, "pMin should be below spot price");
    }
    
    /// @notice Fuzz test pMin monotonicity with supply decreases
    function testFuzz_PMinMonotonicity(uint256 supplyDecrease) public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        uint256 currentSupply = token.totalSupply();
        uint256 feeBps = pair.currentFeeBps();
        
        uint256 pMinBefore = PMinLib.calculate(tokReserve, qtReserve, currentSupply, feeBps);
        
        supplyDecrease = bound(supplyDecrease, 0, currentSupply / 2);
        if (supplyDecrease > 0) {
            uint256 newSupply = currentSupply - supplyDecrease;
            uint256 pMinAfter = PMinLib.calculate(tokReserve, qtReserve, newSupply, feeBps);
            
            assertGe(pMinAfter, pMinBefore, "pMin should increase when supply decreases");
        }
    }
    
    // ============ EDGE CASE FUZZ TESTS ============
    
    /// @notice Fuzz test behavior with extreme values
    function testFuzz_ExtremeValues(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        
        // Test that operations don't overflow/underflow
        if (amount <= token.balanceOf(alice)) {
            vm.prank(alice);
            token.burn(amount);
            
            // Verify state remains consistent
            assertTrue(token.totalSupply() > 0, "Supply should remain positive");
            assertTrue(pair.pMin() > 0, "pMin should remain positive");
        }
    }
    
    /// @notice Fuzz test multiple operations in sequence
    function testFuzz_OperationSequence(
        uint256 burnAmount,
        uint256 swapAmount,
        uint256 collateralAmount
    ) public {
        uint256 aliceBalance = token.balanceOf(alice);
        burnAmount = bound(burnAmount, 0, aliceBalance / 4);
        swapAmount = bound(swapAmount, 0, aliceBalance / 4);
        collateralAmount = bound(collateralAmount, 0, aliceBalance / 4);
        
        uint256 pMinStart = pair.pMin();
        
        // Sequence of operations
        vm.startPrank(alice);
        
        if (burnAmount > 0) {
            token.burn(burnAmount);
        }
        
        if (swapAmount > 0 && swapAmount <= token.balanceOf(alice)) {
            token.approve(address(pair), swapAmount);
            _swap(pair, address(token), swapAmount, alice);
        }
        
        if (collateralAmount > 0 && collateralAmount <= token.balanceOf(alice)) {
            token.approve(address(vault), collateralAmount);
            vault.depositCollateral(collateralAmount);
        }
        
        vm.stopPrank();
        
        uint256 pMinEnd = pair.pMin();
        
        // Verify system remains in valid state
        assertTrue(pMinEnd > 0, "pMin should remain positive");
        assertTrue(token.totalSupply() > 0, "Token supply should remain positive");
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertTrue(r0 > 0 && r1 > 0, "Reserves should remain positive");
    }
    
    /// @notice Fuzz test gas consumption stays reasonable
    function testFuzz_GasConsumption(uint256 amount) public {
        uint256 aliceBalance = token.balanceOf(alice);
        amount = bound(amount, 1, aliceBalance / 2);
        
        uint256 gasBefore = gasleft();
        
        vm.prank(alice);
        token.burn(amount);
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Gas should be reasonable (less than 100k for a burn)
        assertLt(gasUsed, 100000, "Gas consumption should be reasonable");
    }
}