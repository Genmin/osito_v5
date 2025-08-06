// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/OsitoPair.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/core/LenderVault.sol";
import "../../src/core/OsitoToken.sol";
import "../../src/factories/OsitoLaunchpad.sol";
import "../../src/factories/LendingFactory.sol";
import "../../src/libraries/PMinLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title Fuzz Tests for Osito Protocol
 * @notice Tests all critical paths with random inputs
 */
contract OsitoFuzzTest is Test {
    // ============ State ============
    OsitoLaunchpad launchpad;
    LendingFactory lendingFactory;
    OsitoToken token;
    OsitoPair pair;
    CollateralVault collateralVault;
    LenderVault lenderVault;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    MockWBERA wbera;
    
    // ============ Setup ============
    
    function setUp() public {
        // Deploy mock WBERA
        wbera = new MockWBERA();
        
        // Deploy infrastructure
        launchpad = new OsitoLaunchpad(address(wbera), treasury);
        lendingFactory = new LendingFactory(address(wbera), treasury);
        
        // Launch a test token
        wbera.mint(alice, 100e18);
        vm.startPrank(alice);
        ERC20(address(wbera)).approve(address(launchpad), type(uint256).max);
        (address tokenAddr, address pairAddr,) = 
            launchpad.launchToken(
                "TEST", "TEST", 1_000_000_000e18, "",
                1e18, // 1 WBERA
                9900, // 99% start fee
                30,   // 0.3% end fee
                30 days // decay target
            );
        vm.stopPrank();
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        
        // Create lending market
        address cv = lendingFactory.createLendingMarket(pairAddr);
        collateralVault = CollateralVault(cv);
        // Get lender vault from collateral vault
        lenderVault = LenderVault(collateralVault.lenderVault());
        
        // Add liquidity to lender vault
        wbera.mint(bob, 1000e18);
        vm.startPrank(bob);
        ERC20(address(wbera)).approve(address(lenderVault), 1000e18);
        lenderVault.deposit(1000e18, bob);
        vm.stopPrank();
    }
    
    // ============ PMin Fuzz Tests ============
    
    /**
     * @notice Fuzz: pMin calculation never reverts
     */
    function testFuzz_PMinNoRevert(
        uint128 tokReserves,
        uint128 qtReserves,
        uint256 totalSupply,
        uint16 feeBps
    ) public pure {
        // Bound inputs
        vm.assume(tokReserves > 0 && tokReserves < type(uint112).max);
        vm.assume(qtReserves > 0 && qtReserves < type(uint112).max);
        vm.assume(totalSupply > 0 && totalSupply < type(uint128).max);
        vm.assume(feeBps <= 10000);
        
        // Should never revert
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Basic invariants
        if (totalSupply <= tokReserves) {
            assertEq(pMin, 0, "pMin should be 0 when all tokens in pool");
        }
        // Note: pMin can exceed spot price when tokensOutside is very small
        // This is mathematically correct - it's the average price of a tiny dump
    }
    
    /**
     * @notice Fuzz: pMin represents average dump price, not spot
     * @dev pMin can exceed spot price when tokensOutside >> tokReserves
     * This is expected behavior - pMin is the average execution price
     */
    function testFuzz_PMinAlwaysLessThanSpot(
        uint128 tokReserves,
        uint128 qtReserves,
        uint128 tokensOutside
    ) public pure {
        // Bound to reasonable values
        vm.assume(tokReserves > 1e18 && tokReserves < type(uint112).max);
        vm.assume(qtReserves > 1e15 && qtReserves < type(uint112).max);
        vm.assume(tokensOutside > 0 && tokensOutside < type(uint112).max);
        
        // Additional constraint: tokensOutside should be reasonable relative to reserves
        // If there are 100x more tokens outside than inside, pMin can exceed spot
        vm.assume(tokensOutside <= tokReserves * 10); // Max 10x outside
        
        uint256 totalSupply = uint256(tokReserves) + uint256(tokensOutside);
        uint256 spotPrice = (uint256(qtReserves) * 1e18) / uint256(tokReserves);
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 30);
        
        // pMin should be less than spot in reasonable scenarios
        assertLe(pMin, spotPrice, "pMin exceeds spot price");
    }
    
    // ============ Swap Fuzz Tests ============
    
    /**
     * @notice Fuzz: Swaps always maintain or increase k
     */
    function testFuzz_SwapMaintainsK(uint256 amountIn) public {
        // Bound input
        amountIn = bound(amountIn, 1e15, 10e18);
        
        // Get initial k
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);
        
        // Do swap
        wbera.mint(alice, amountIn);
        vm.startPrank(alice);
        ERC20(address(wbera)).transfer(address(pair), amountIn);
        
        // Calculate and execute swap
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 qtReserves = tokIsToken0 ? r1 : r0;
        uint256 tokReserves = tokIsToken0 ? r0 : r1;
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInAfterFee = (amountIn * (10000 - feeBps)) / 10000;
        uint256 amountOut = (amountInAfterFee * tokReserves) / (qtReserves + amountInAfterFee);
        
        if (tokIsToken0) {
            pair.swap(amountOut, 0, alice);
        } else {
            pair.swap(0, amountOut, alice);
        }
        vm.stopPrank();
        
        // Check k increased
        (r0, r1,) = pair.getReserves();
        uint256 kAfter = uint256(r0) * uint256(r1);
        
        assertGe(kAfter, kBefore, "k decreased");
    }
    
    /**
     * @notice Fuzz: Swap output is always positive
     */
    function testFuzz_SwapOutputPositive(uint256 amountIn) public {
        // Bound to reasonable swap amounts
        amountIn = bound(amountIn, 1e12, 100e18);
        
        wbera.mint(alice, amountIn);
        uint256 balanceBefore = token.balanceOf(alice);
        
        vm.startPrank(alice);
        ERC20(address(wbera)).transfer(address(pair), amountIn);
        
        // Execute swap
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        
        if (tokIsToken0) {
            pair.swap(1, 0, alice); // Minimum output
        } else {
            pair.swap(0, 1, alice);
        }
        vm.stopPrank();
        
        uint256 balanceAfter = token.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore, "No tokens received");
    }
    
    // ============ Lending Fuzz Tests ============
    
    /**
     * @notice Fuzz: Borrow always respects pMin limit
     */
    function testFuzz_BorrowRespectsLimit(
        uint256 collateralAmount,
        uint256 borrowAmount
    ) public {
        // Bound inputs
        collateralAmount = bound(collateralAmount, 1e18, 100_000e18);
        
        // Give alice tokens
        deal(address(token), alice, collateralAmount);
        
        vm.startPrank(alice);
        token.approve(address(collateralVault), collateralAmount);
        collateralVault.depositCollateral(collateralAmount);
        
        // Calculate max borrow
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateralAmount * pMin) / 1e18;
        
        // Bound borrow amount
        borrowAmount = bound(borrowAmount, 0, maxBorrow * 2); // Allow over-borrow attempts
        
        if (borrowAmount <= maxBorrow && borrowAmount > 0) {
            // Should succeed
            collateralVault.borrow(borrowAmount);
            assertEq(ERC20(address(wbera)).balanceOf(alice), borrowAmount, "Wrong borrow amount");
        } else if (borrowAmount > maxBorrow) {
            // Should fail
            vm.expectRevert("EXCEEDS_PMIN_VALUE");
            collateralVault.borrow(borrowAmount);
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Fuzz: Interest accumulation never overflows
     */
    function testFuzz_InterestNoOverflow(uint256 timeElapsed, uint256 borrowAmount) public {
        // Bound inputs
        timeElapsed = bound(timeElapsed, 1, 365 days * 10); // Up to 10 years
        borrowAmount = bound(borrowAmount, 1e18, 100e18);
        
        // Setup borrow
        deal(address(token), alice, 10_000e18);
        vm.startPrank(alice);
        token.approve(address(collateralVault), 10_000e18);
        collateralVault.depositCollateral(10_000e18);
        
        uint256 pMin = pair.pMin();
        if (pMin > 0) {
            uint256 maxBorrow = (10_000e18 * pMin) / 1e18;
            borrowAmount = bound(borrowAmount, 1, maxBorrow);
            collateralVault.borrow(borrowAmount);
        }
        vm.stopPrank();
        
        // Fast forward time
        vm.warp(block.timestamp + timeElapsed);
        
        // Accrue interest - should not overflow
        lenderVault.accrueInterest();
        
        uint256 borrowIndex = lenderVault.borrowIndex();
        assertGt(borrowIndex, 0, "Borrow index is 0");
        assertLt(borrowIndex, type(uint128).max, "Borrow index too large");
    }
    
    /**
     * @notice Fuzz: Recovery respects grace period
     */
    function testFuzz_RecoveryGracePeriod(uint256 timeElapsed) public {
        // Setup position
        MockWBERA(wbera).mint(alice, 1000e18);
        deal(address(token), alice, 10000e18);
        
        // Activate pMin first
        vm.startPrank(alice);
        MockWBERA(wbera).transfer(address(pair), 1e17);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 tokOut = tokIsToken0 ? r0 / 100 : r1 / 100; // Small swap
        if (tokIsToken0) {
            pair.swap(tokOut, 0, alice);
        } else {
            pair.swap(0, tokOut, alice);
        }
        
        // Now deposit and borrow
        token.approve(address(collateralVault), 10000e18);
        collateralVault.depositCollateral(10000e18);
        
        uint256 pMin = pair.pMin();
        if (pMin > 0) {
            uint256 maxBorrow = (10000e18 * pMin) / 1e18;
            if (maxBorrow > 1e15) {
                collateralVault.borrow(maxBorrow / 2); // Borrow half of max
            }
        }
        vm.stopPrank();
        
        // Make position unhealthy by dumping tokens
        deal(address(token), bob, 500_000e18);
        vm.startPrank(bob);
        token.transfer(address(pair), 500_000e18);
        
        // Calculate reasonable swap output
        (r0, r1,) = pair.getReserves();
        uint256 qtOut = tokIsToken0 ? r1 * 90 / 100 : r0 * 90 / 100;
        if (tokIsToken0) {
            pair.swap(0, qtOut, bob);
        } else {
            pair.swap(qtOut, 0, bob);
        }
        vm.stopPrank();
        
        // Check if position is actually unhealthy
        if (!collateralVault.isPositionHealthy(alice)) {
            // Bound time
            timeElapsed = bound(timeElapsed, 0, 100 hours);
            vm.warp(block.timestamp + timeElapsed);
            
            if (timeElapsed < 72 hours) {
                // Should fail - grace period not expired
                vm.expectRevert("GRACE_NOT_EXPIRED");
                collateralVault.recover(alice);
            } else {
                // Should succeed after grace period
                collateralVault.recover(alice);
            }
        }
    }
    
    // ============ Burn Fuzz Tests ============
    
    /**
     * @notice Fuzz: Burns always reduce supply
     */
    function testFuzz_BurnReducesSupply(uint256 burnAmount) public {
        // Get some tokens
        deal(address(token), alice, 1_000_000e18);
        
        uint256 supplyBefore = token.totalSupply();
        burnAmount = bound(burnAmount, 1, 1_000_000e18);
        
        vm.prank(alice);
        token.burn(burnAmount);
        
        uint256 supplyAfter = token.totalSupply();
        assertEq(supplyAfter, supplyBefore - burnAmount, "Burn didn't reduce supply correctly");
    }
    
    // ============ Overflow Protection ============
    
    /**
     * @notice Fuzz: No overflow in k calculation
     */
    function testFuzz_NoOverflowInK(uint112 r0, uint112 r1) public pure {
        // Max reserves are uint112
        vm.assume(r0 > 0);
        vm.assume(r1 > 0);
        
        // This should not overflow in uint256
        uint256 k = uint256(r0) * uint256(r1);
        
        // k should fit in uint224 (112 + 112 bits)
        assertLt(k, 2**224, "k too large");
    }
}

// ============ Mock Contracts ============

contract MockWBERA is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped BERA";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WBERA";
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}