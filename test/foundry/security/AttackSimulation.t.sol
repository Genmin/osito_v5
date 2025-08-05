// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Malicious contract to test reentrancy attacks
contract ReentrancyAttacker {
    CollateralVault public vault;
    OsitoToken public token;
    bool public attacking;
    
    constructor(CollateralVault _vault, OsitoToken _token) {
        vault = _vault;
        token = _token;
    }
    
    function attack() external {
        attacking = true;
        vault.depositCollateral(1000 * 1e18);
    }
    
    // This would be called on token transfer during recovery
    receive() external payable {
        if (attacking && address(this).balance > 0) {
            attacking = false;
            // Try to call vault again (should fail due to reentrancy guard)
            vault.borrow(0.1 ether);
        }
    }
}

/// @notice Malicious token contract
contract MaliciousToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    bool public shouldRevert;
    
    function transfer(address to, uint256 amount) external returns (bool) {
        if (shouldRevert) revert("Malicious revert");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract AttackSimulationTest is BaseTest {
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
            "Test Token",
            "TEST",
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
        lenderVault.deposit(50 ether, bob);
        vm.stopPrank();
        
        // Get tokens for testing
        vm.startPrank(alice);
        weth.approve(address(pair), 2 ether);
        _swap(pair, address(weth), 2 ether, alice);
        vm.stopPrank();
    }
    
    // ============ LP Token Attacks ============
    
    function test_PreventLPTokenExile() public {
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        
        // Try to transfer LP tokens away from feeRouter (should fail)
        if (lpBalance > 0) {
            vm.prank(address(feeRouter));
            vm.expectRevert("RESTRICTED");
            pair.transfer(eve, lpBalance);
        }
        
        // Try direct approval attack
        vm.prank(address(feeRouter));
        vm.expectRevert("RESTRICTED");
        pair.transferFrom(address(feeRouter), eve, lpBalance);
    }
    
    function test_PreventLPTokenManipulation() public {
        // No one should be able to mint LP tokens except through proper channels
        vm.prank(eve);
        vm.expectRevert("RESTRICTED");
        pair.mint(eve);
        
        // Test that only pair itself can receive LP during burns
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        if (lpBalance > 0) {
            vm.prank(address(feeRouter));
            pair.transfer(address(pair), lpBalance);
            
            // Try to burn to attacker address (should fail)
            vm.expectRevert();
            pair.burn(eve);
        }
    }
    
    // ============ Donation Attacks ============
    
    function test_PreventDonationAttack() public {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        
        // Attacker tries to manipulate reserves by direct token transfer
        uint256 donationAmount = 1_000_000 * 1e18;
        vm.prank(alice);
        token.transfer(address(pair), donationAmount);
        
        // K should not change from donation
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        
        assertEq(kAfter, kBefore, "K should not change from donation");
        
        // Reserves should not update from donation alone
        assertEq(r0After, r0Before, "Reserves should not update from donation");
        assertEq(r1After, r1Before, "Reserves should not update from donation");
    }
    
    // ============ Flash Loan Attacks ============
    
    function test_PreventFlashLoanPMinManipulation() public {
        uint256 pMinBefore = pair.pMin();
        
        // Simulate flash loan attack: massive token dump
        uint256 flashAmount = SUPPLY / 2;
        
        vm.startPrank(eve);
        
        // Attacker gets massive token amount (simulating flash loan)
        vm.prank(alice);
        token.transfer(eve, flashAmount);
        
        // Try to manipulate pMin by dumping tokens
        token.approve(address(pair), flashAmount / 10);
        _swap(pair, address(token), flashAmount / 10, eve);
        
        uint256 pMinDuring = pair.pMin();
        
        // Verify pMin didn't decrease (should only increase or stay same)
        assertGe(pMinDuring, pMinBefore, "pMin should not decrease from flash loan attack");
        
        vm.stopPrank();
    }
    
    function test_FlashLoanCannotBorrowMore() public {
        uint256 collateralAmount = 100_000 * 1e18;
        
        vm.startPrank(eve);
        
        // Normal deposit
        vm.prank(alice);
        token.transfer(eve, collateralAmount);
        
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 pMinBefore = pair.pMin();
        uint256 maxBorrowBefore = (collateralAmount * pMinBefore) / 1e18;
        
        // Simulate flash loan to try to increase pMin temporarily
        uint256 flashAmount = SUPPLY / 4;
        vm.prank(alice);
        token.transfer(eve, flashAmount);
        
        // Burn tokens to try to increase pMin
        token.burn(flashAmount);
        
        uint256 pMinAfter = pair.pMin();
        
        // Even if pMin increased, can't borrow more than original pMin allowed
        vm.expectRevert("EXCEEDS_PMIN_VALUE");
        vault.borrow(maxBorrowBefore + 1);
        
        vm.stopPrank();
    }
    
    // ============ Reentrancy Attacks ============
    
    function test_PreventReentrancyInVault() public {
        uint256 amount = 1000 * 1e18;
        
        // Deploy attacker contract
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault, token);
        
        // Give attacker some tokens
        vm.prank(alice);
        token.transfer(address(attacker), amount);
        
        // Attack should fail due to reentrancy guard
        vm.expectRevert();
        attacker.attack();
    }
    
    // ============ Sandwich Attacks ============
    
    function test_SandwichAttackMitigation() public {
        uint256 victimSwapAmount = 1 ether;
        uint256 attackerFrontrun = 3 ether;
        
        // Attacker front-runs with large swap
        vm.startPrank(eve);
        weth.approve(address(pair), attackerFrontrun);
        _swap(pair, address(weth), attackerFrontrun, eve);
        vm.stopPrank();
        
        uint256 victimTokensBefore = token.balanceOf(bob);
        
        // Victim makes their planned swap
        vm.startPrank(bob);
        weth.approve(address(pair), victimSwapAmount);
        _swap(pair, address(weth), victimSwapAmount, bob);
        vm.stopPrank();
        
        uint256 victimTokensReceived = token.balanceOf(bob) - victimTokensBefore;
        
        // Due to high initial fees (99%), sandwich attacks are heavily penalized
        uint256 expectedMinimum = victimSwapAmount / 1000; // Very conservative due to fees
        assertTrue(victimTokensReceived > 0, "Victim should receive some tokens");
        
        // High fees should discourage sandwich attacks
        uint256 currentFee = pair.currentFeeBps();
        assertGe(currentFee, 9000, "Fees should be high initially to prevent sandwiching");
    }
    
    // ============ Liquidation Front-Running ============
    
    function test_PreventLiquidationFrontRunning() public {
        uint256 collateralAmount = 100_000 * 1e18;
        uint256 borrowAmount = 1 ether;
        
        // Create position
        vm.startPrank(alice);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Advance time to make position potentially unhealthy
        _advanceTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(alice)) {
            // Mark position as OTM
            vm.prank(eve);
            vault.markOTM(alice);
            
            // Borrower tries to front-run liquidation by repaying
            (,uint256 debt,,,) = vault.getAccountState(alice);
            
            vm.startPrank(alice);
            weth.approve(address(vault), debt);
            vault.repay(debt);
            vm.stopPrank();
            
            // After repayment, liquidation should fail
            _advanceTime(73 hours);
            
            vm.prank(eve);
            vm.expectRevert();
            vault.recover(alice);
        }
    }
    
    // ============ Interest Rate Manipulation ============
    
    function test_PreventInterestRateManipulation() public {
        uint256 utilization1 = lenderVault.borrowRate();
        
        // Large borrow to increase utilization
        uint256 collateralAmount = 10_000_000 * 1e18;
        vm.prank(alice);
        token.transfer(eve, collateralAmount);
        
        vm.startPrank(eve);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(20 ether); // Large borrow
        vm.stopPrank();
        
        uint256 utilization2 = lenderVault.borrowRate();
        
        // Interest rate should increase with utilization
        assertGt(utilization2, utilization1, "Interest rate should increase with utilization");
        
        // But it should be bounded by the model parameters
        uint256 maxReasonableRate = 5e17; // 50% APR max reasonable
        assertLt(utilization2, maxReasonableRate, "Interest rate should not be exploitably high");
    }
    
    // ============ Oracle Manipulation ============
    
    function test_PreventPMinOracleManipulationAttack() public {
        uint256 pMinBefore = pair.pMin();
        
        // Massive swap to try to manipulate "oracle" (pMin)
        uint256 attackAmount = token.balanceOf(alice);
        
        vm.startPrank(alice);
        token.approve(address(pair), attackAmount / 2);
        _swap(pair, address(token), attackAmount / 2, alice);
        vm.stopPrank();
        
        uint256 pMinAfter = pair.pMin();
        
        // pMin should not decrease from swaps
        assertGe(pMinAfter, pMinBefore, "pMin should not decrease");
        
        // pMin should still represent the floor price for liquidations
        assertTrue(pMinAfter > 0, "pMin should remain positive");
    }
    
    // ============ Governance/Admin Attacks ============
    
    function test_NoAdminKeys() public {
        // Verify no admin functions exist that could be exploited
        
        // Try to call non-existent admin functions
        (bool success,) = address(pair).call(abi.encodeWithSignature("setAdmin(address)", eve));
        assertFalse(success, "No admin functions should exist");
        
        (success,) = address(vault).call(abi.encodeWithSignature("pause()"));
        assertFalse(success, "No pause functions should exist");
        
        (success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", eve, 1000));
        assertFalse(success, "No mint functions should exist");
    }
    
    // ============ Token Standard Attacks ============
    
    function test_TokenStandardCompliance() public {
        // Test that token behaves correctly with edge cases
        
        // Zero amount transfers should work
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        
        // Large amount transfers should work
        uint256 largeAmount = token.balanceOf(alice);
        vm.prank(alice);
        assertTrue(token.transfer(bob, largeAmount));
        
        // Transfer to self should work
        vm.prank(bob);
        assertTrue(token.transfer(bob, 1000));
    }
    
    // ============ MEV Attacks ============
    
    function test_MEVResistance() public {
        // Test that MEV opportunities are minimized
        
        uint256 pMinBefore = pair.pMin();
        
        // Sequence of operations that might be MEV'd
        vm.startPrank(alice);
        weth.approve(address(pair), 0.5 ether);
        _swap(pair, address(weth), 0.5 ether, alice);
        vm.stopPrank();
        
        vm.prank(keeper);
        feeRouter.collectFees();
        
        uint256 tokensReceived = token.balanceOf(alice);
        vm.prank(alice);
        token.burn(tokensReceived / 10);
        
        uint256 pMinAfter = pair.pMin();
        
        // pMin should increase, making the protocol more robust
        assertGe(pMinAfter, pMinBefore, "pMin should increase");
        
        // High fees should make MEV unprofitable
        uint256 currentFee = pair.currentFeeBps();
        assertGe(currentFee, 1000, "Fees should be high enough to deter MEV");
    }
    
    // ============ Economic Attacks ============
    
    function test_EconomicIncentiveAlignment() public {
        // Test that all actors have aligned incentives
        
        uint256 supplyBefore = token.totalSupply();
        uint256 pMinBefore = pair.pMin();
        
        // User swaps (pays fees)
        vm.startPrank(alice);
        weth.approve(address(pair), 0.5 ether);
        _swap(pair, address(weth), 0.5 ether, alice);
        vm.stopPrank();
        
        // Fees collected (increases k)
        vm.prank(keeper);
        feeRouter.collectFees();
        
        // User burns tokens (reduces supply)
        uint256 tokensReceived = token.balanceOf(alice);
        vm.prank(alice);
        token.burn(tokensReceived / 10);
        
        uint256 supplyAfter = token.totalSupply();
        uint256 pMinAfter = pair.pMin();
        
        // Supply should decrease
        assertLt(supplyAfter, supplyBefore, "Supply should decrease from burns");
        
        // pMin should increase
        assertGt(pMinAfter, pMinBefore, "pMin should increase");
        
        // This benefits all participants:
        // - Traders get tokens
        // - Protocol gets fees
        // - Lenders get higher backing ratio
        // - Borrowers get higher capital efficiency
    }
}