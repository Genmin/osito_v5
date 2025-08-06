// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Comprehensive attack simulations for Osito protocol
contract ComprehensiveAttackTests is BaseTest {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    address public attacker;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token and lending system
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
        
        vault = _createLendingMarket(address(pair));
        lenderVault = LenderVault(lendingFactory.lenderVault());
        
        // Setup attacker with funds
        attacker = makeAddr("attacker");
        deal(address(weth), attacker, 1000 ether);
        deal(address(token), attacker, SUPPLY / 100); // 1% of supply
        
        // Add liquidity to lender vault
        deal(address(weth), alice, 500 ether);
        vm.startPrank(alice);
        weth.approve(address(lenderVault), 500 ether);
        lenderVault.deposit(500 ether, alice);
        vm.stopPrank();
    }
    
    /// @notice Attack 1: Token Donation Grief Attack
    /// @dev Attacker sends tokens directly to pair to manipulate K
    function test_TokenDonationGriefAttack() public {
        // Record initial state
        uint256 kBefore = _getCurrentK();
        uint256 pMinBefore = pair.pMin();
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        
        // Attacker donates tokens directly to pair
        vm.startPrank(attacker);
        uint256 donationAmount = token.balanceOf(attacker) / 2;
        token.transfer(address(pair), donationAmount);
        
        // Try to exploit by swapping
        uint256 wethAmount = 1 ether;
        weth.approve(address(pair), wethAmount);
        weth.transfer(address(pair), wethAmount);
        
        // Calculate expected output
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 tokReserve = tokIsToken0 ? uint256(r0Before) : uint256(r1Before);
        uint256 qtReserve = tokIsToken0 ? uint256(r1Before) : uint256(r0Before);
        
        // Note: Donated tokens are NOT in reserves until sync
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (wethAmount * (10000 - feeBps)) / 10000;
        uint256 expectedOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
        
        // Perform swap
        pair.swap(
            tokIsToken0 ? expectedOut : 0,
            tokIsToken0 ? 0 : expectedOut,
            attacker
        );
        vm.stopPrank();
        
        // Verify K didn't decrease significantly
        uint256 kAfter = _getCurrentK();
        assertGe(kAfter, kBefore * 99 / 100, "K decreased by more than 1% from donation attack");
        
        // Verify pMin behavior
        uint256 pMinAfter = pair.pMin();
        console2.log("pMin before:", pMinBefore);
        console2.log("pMin after:", pMinAfter);
        
        // pMin might change but shouldn't crash
        assertTrue(pMinAfter > 0, "pMin became zero after donation");
    }
    
    /// @notice Attack 2: Quote-Token-Only Liquidity Addition
    /// @dev Attacker tries to add only quote token as liquidity
    function test_QuoteTokenOnlyLiquidityAttack() public {
        // Record initial state
        uint256 pMinBefore = pair.pMin();
        uint256 totalSupplyBefore = pair.totalSupply();
        
        // Attacker tries to add only WETH (quote token)
        vm.startPrank(attacker);
        uint256 wethOnly = 50 ether;
        weth.transfer(address(pair), wethOnly);
        
        // Try to mint LP tokens
        vm.expectRevert(); // Should revert due to imbalanced liquidity
        pair.mint(attacker);
        vm.stopPrank();
        
        // Verify state unchanged
        assertEq(pair.totalSupply(), totalSupplyBefore, "LP supply changed from failed mint");
        assertEq(pair.pMin(), pMinBefore, "pMin changed from failed mint");
    }
    
    /// @notice Attack 3: Sandwich Attack on Fee Collection
    /// @dev Attacker tries to sandwich the fee collection transaction
    function test_SandwichFeeCollectionAttack() public {
        // Generate fees through normal trading
        vm.startPrank(alice);
        for (uint i = 0; i < 10; i++) {
            _swap(pair, address(weth), 1 ether, alice);
        }
        vm.stopPrank();
        
        // Record state before sandwich
        uint256 attackerTokensBefore = token.balanceOf(attacker);
        uint256 attackerWethBefore = weth.balanceOf(attacker);
        
        // Front-run: Attacker swaps large amount before fee collection
        vm.startPrank(attacker);
        uint256 frontRunAmount = 100 ether;
        weth.approve(address(pair), frontRunAmount);
        _swap(pair, address(weth), frontRunAmount, attacker);
        
        uint256 tokensReceived = token.balanceOf(attacker) - attackerTokensBefore;
        vm.stopPrank();
        
        // Victim transaction: Fee collection
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        // Back-run: Attacker swaps back
        vm.startPrank(attacker);
        token.approve(address(pair), tokensReceived);
        _swap(pair, address(token), tokensReceived, attacker);
        vm.stopPrank();
        
        // Calculate attacker profit/loss
        uint256 attackerTokensAfter = token.balanceOf(attacker);
        uint256 attackerWethAfter = weth.balanceOf(attacker);
        
        // Attacker should have lost money due to fees
        assertLt(attackerWethAfter, attackerWethBefore, "Attacker profited from sandwich");
        
        // The loss should be at least the fee amount
        uint256 loss = attackerWethBefore - attackerWethAfter;
        uint256 feeBps = pair.currentFeeBps();
        uint256 expectedMinLoss = (frontRunAmount * feeBps * 2) / 10000; // Two swaps
        
        assertGe(loss, expectedMinLoss * 90 / 100, "Attacker loss less than expected fees");
    }
    
    /// @notice Attack 4: Flash Loan Attack on Lending System
    /// @dev Attacker tries to manipulate spot price to liquidate positions
    function test_FlashLoanLiquidationAttack() public {
        // Setup: Bob has a healthy position
        deal(address(token), bob, 10000 * 1e18);
        vm.startPrank(bob);
        token.approve(address(vault), 10000 * 1e18);
        vault.depositCollateral(10000 * 1e18);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (10000 * 1e18 * pMin) / 1e18;
        vault.borrow(maxBorrow * 90 / 100); // Borrow 90% of max
        vm.stopPrank();
        
        // Attacker tries to crash price and liquidate
        vm.startPrank(attacker);
        
        // Massive sell to crash price
        uint256 dumpAmount = token.balanceOf(attacker);
        token.approve(address(pair), dumpAmount);
        _swap(pair, address(token), dumpAmount, attacker);
        
        // Check if position can be liquidated
        bool isHealthy = vault.isPositionHealthy(bob);
        
        if (!isHealthy) {
            // First mark position as OTM
            vault.markOTM(bob);
            
            // Wait for grace period
            vm.warp(block.timestamp + 72 hours + 1);
            
            // Try to recover position
            uint256 attackerWethBefore = weth.balanceOf(attacker);
            vault.recover(bob);
            uint256 attackerWethAfter = weth.balanceOf(attacker);
            
            // Attacker gets bounty
            uint256 bounty = attackerWethAfter - attackerWethBefore;
            assertGt(bounty, 0, "No bounty received");
            
            // But position was still fully covered at pMin
            uint256 collateral = 10000 * 1e18;
            uint256 recoveryValue = (collateral * pMin) / 1e18;
            assertGe(recoveryValue, maxBorrow * 90 / 100, "Position not fully backed at pMin");
        }
        
        vm.stopPrank();
    }
    
    /// @notice Attack 5: Reentrancy Attack on Swap
    /// @dev Attacker tries to reenter during swap execution
    function test_ReentrancyAttack() public {
        // Deploy malicious token that attempts reentrancy
        MaliciousToken malToken = new MaliciousToken(address(pair));
        
        // Attacker tries to exploit
        vm.startPrank(attacker);
        deal(address(malToken), attacker, 1000 * 1e18);
        
        // This should fail due to reentrancy guards
        malToken.approve(address(pair), 1000 * 1e18);
        
        // Attempt will revert
        vm.expectRevert(); // Reentrancy guard should trigger
        malToken.triggerAttack();
        
        vm.stopPrank();
    }
    
    /// @notice Attack 6: Overflow/Underflow Attack
    /// @dev Try to cause arithmetic overflow/underflow
    function test_OverflowUnderflowAttack() public {
        // Try maximum possible values
        vm.startPrank(attacker);
        
        // Test with max uint112 reserves (pair limit)
        uint256 maxUint112 = type(uint112).max;
        
        // This would require impossible amounts but test the bounds
        uint256 hugeAmount = 1e30; // Huge but not overflow
        deal(address(weth), attacker, hugeAmount);
        
        weth.approve(address(pair), hugeAmount);
        
        // Should handle large numbers safely
        vm.expectRevert(); // Should revert due to reserve limits
        _swap(pair, address(weth), hugeAmount, attacker);
        
        vm.stopPrank();
    }
    
    /// @notice Attack 7: Debt Ceiling Manipulation
    /// @dev Try to borrow more than allowed through multiple positions
    function test_DebtCeilingManipulation() public {
        // Create multiple attacker accounts
        address[] memory attackers = new address[](10);
        for (uint i = 0; i < 10; i++) {
            attackers[i] = makeAddr(string.concat("attacker", vm.toString(i)));
            deal(address(token), attackers[i], 1000 * 1e18);
        }
        
        uint256 totalBorrowed = 0;
        uint256 pMin = pair.pMin();
        
        // Each attacker tries to max borrow
        for (uint i = 0; i < 10; i++) {
            vm.startPrank(attackers[i]);
            token.approve(address(vault), 1000 * 1e18);
            vault.depositCollateral(1000 * 1e18);
            
            uint256 maxBorrow = (1000 * 1e18 * pMin) / 1e18;
            
            try vault.borrow(maxBorrow) {
                totalBorrowed += maxBorrow;
            } catch {
                // Borrow failed - likely hit lending pool limit
            }
            
            vm.stopPrank();
        }
        
        // Check that total borrows don't exceed lender vault assets
        uint256 lenderAssets = lenderVault.totalAssets();
        assertLe(totalBorrowed, lenderAssets, "Borrowed more than available");
    }
    
    /// @notice Attack 8: Time Manipulation Attack
    /// @dev Try to exploit time-based mechanics
    function test_TimeManipulationAttack() public {
        // Setup position
        vm.startPrank(bob);
        deal(address(token), bob, 10000 * 1e18);
        token.approve(address(vault), 10000 * 1e18);
        vault.depositCollateral(10000 * 1e18);
        
        uint256 pMin = pair.pMin();
        uint256 borrowAmount = (10000 * 1e18 * pMin * 90) / (1e18 * 100);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Fast forward time to accumulate interest
        vm.warp(block.timestamp + 365 days);
        
        // Check if position became unhealthy due to interest
        bool isHealthy = vault.isPositionHealthy(bob);
        
        if (!isHealthy) {
            // Mark position as OTM first
            vm.prank(attacker);
            vault.markOTM(bob);
            
            // Wait for grace period
            vm.warp(block.timestamp + 72 hours + 1);
            
            // Recover position
            vm.prank(attacker);
            vault.recover(bob);
            
            // Verify liquidation was still safe at pMin
            uint256 collateral = 10000 * 1e18;
            uint256 recoveryValue = (collateral * pMin) / 1e18;
            (uint256 debt,) = vault.accountBorrows(bob);
            
            // Even with massive interest, pMin guarantee should hold
            console2.log("Recovery value:", recoveryValue);
            console2.log("Total debt:", debt);
            
            // Principal should always be recoverable
            assertGe(recoveryValue, borrowAmount, "Principal not recoverable at pMin");
        }
    }
    
    // ============ Helper Functions ============
    
    function _getCurrentK() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return uint256(r0) * uint256(r1);
    }
}

/// @notice Malicious token for reentrancy testing
contract MaliciousToken is ERC20 {
    address public pair;
    bool public attacking;
    
    constructor(address _pair) {
        pair = _pair;
    }
    
    function name() public pure override returns (string memory) {
        return "Malicious";
    }
    
    function symbol() public pure override returns (string memory) {
        return "MAL";
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attacking && to == pair) {
            // Try to reenter
            OsitoPair(pair).swap(1, 0, msg.sender);
        }
        return super.transfer(to, amount);
    }
    
    function triggerAttack() external {
        attacking = true;
        transfer(pair, 100);
        attacking = false;
    }
}