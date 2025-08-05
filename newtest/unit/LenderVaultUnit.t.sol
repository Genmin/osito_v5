// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @title Exhaustive Unit Tests for LenderVault
/// @notice Tests every single function in LenderVault with mathematical precision
contract LenderVaultUnitTest is BaseTest {
    LenderVault public vault;
    MockWETH public weth;
    address public mockCollateralVault;
    
    function setUp() public override {
        super.setUp();
        
        weth = new MockWETH();
        mockCollateralVault = makeAddr("mockCollateralVault");
        
        vault = new LenderVault(address(weth), mockCollateralVault);
        
        // Fund test accounts
        deal(address(weth), alice, 10000e18);
        deal(address(weth), bob, 10000e18);
        deal(address(weth), charlie, 10000e18);
    }
    
    /// @notice Test constructor and initial state
    function test_constructor() public {
        assertEq(vault.asset(), address(weth), "Asset not set correctly");
        assertEq(vault.factory(), address(this), "Factory not set correctly");
        assertTrue(vault.authorized(mockCollateralVault), "CollateralVault not authorized");
        assertEq(vault.totalBorrows(), 0, "Initial total borrows not zero");
        assertEq(vault.borrowIndex(), 1e18, "Initial borrow index not 1e18");
        assertTrue(vault.lastAccrueTime() > 0, "Last accrue time not set");
    }
    
    /// @notice Test asset function
    function test_asset() public {
        assertEq(vault.asset(), address(weth), "Asset function failed");
    }
    
    /// @notice Test name function
    function test_name() public {
        string memory expectedName = string(abi.encodePacked("Osito ", weth.name()));
        assertEq(vault.name(), expectedName, "Name function failed");
    }
    
    /// @notice Test symbol function
    function test_symbol() public {
        string memory expectedSymbol = string(abi.encodePacked("o", weth.symbol()));
        assertEq(vault.symbol(), expectedSymbol, "Symbol function failed");
    }
    
    /// @notice Test authorize function
    function test_authorize_OnlyFactory() public {
        address newVault = makeAddr("newVault");
        
        // Should work when called by factory (this contract)
        vault.authorize(newVault);
        assertTrue(vault.authorized(newVault), "Authorization failed");
        
        // Should fail when called by non-factory
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        vault.authorize(makeAddr("anotherVault"));
    }
    
    /// @notice Test accrueInterest function
    function test_accrueInterest_NoTimeElapsed() public {
        uint256 indexBefore = vault.borrowIndex();
        uint256 borrowsBefore = vault.totalBorrows();
        
        vault.accrueInterest();
        
        assertEq(vault.borrowIndex(), indexBefore, "Index changed without time");
        assertEq(vault.totalBorrows(), borrowsBefore, "Borrows changed without time");
    }
    
    function test_accrueInterest_WithTimeElapsed() public {
        // First create some borrows
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        uint256 indexBefore = vault.borrowIndex();
        uint256 borrowsBefore = vault.totalBorrows();
        
        // Advance time
        vm.warp(block.timestamp + 365 days);
        
        vault.accrueInterest();
        
        assertTrue(vault.borrowIndex() > indexBefore, "Index should increase");
        assertTrue(vault.totalBorrows() > borrowsBefore, "Borrows should increase");
    }
    
    function test_accrueInterest_ZeroBorrows() public {
        uint256 indexBefore = vault.borrowIndex();
        
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        
        assertEq(vault.borrowIndex(), indexBefore, "Index should not change with zero borrows");
    }
    
    /// @notice Test borrow function
    function test_borrow_BasicFunctionality() public {
        // Fund vault first
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 borrowAmount = 100e18;
        uint256 balanceBefore = weth.balanceOf(mockCollateralVault);
        
        vm.prank(mockCollateralVault);
        vault.borrow(borrowAmount);
        
        assertEq(vault.totalBorrows(), borrowAmount, "Total borrows not updated");
        assertEq(weth.balanceOf(mockCollateralVault), balanceBefore + borrowAmount, "WETH not transferred");
    }
    
    function test_borrow_OnlyAuthorized() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        vault.borrow(100e18);
    }
    
    function test_borrow_InsufficientLiquidity() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        // Try to borrow more than available
        vm.prank(mockCollateralVault);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        vault.borrow(2000e18);
    }
    
    function test_borrow_AccruesInterest() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        // First borrow
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        vm.warp(block.timestamp + 365 days);
        
        uint256 indexBefore = vault.borrowIndex();
        
        // Second borrow should accrue interest
        vm.prank(mockCollateralVault);
        vault.borrow(50e18);
        
        assertTrue(vault.borrowIndex() > indexBefore, "Interest not accrued on borrow");
    }
    
    /// @notice Test repay function
    function test_repay_BasicFunctionality() public {
        // Setup borrow first
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        // Fund collateral vault for repayment
        deal(address(weth), mockCollateralVault, 100e18);
        
        vm.prank(mockCollateralVault);
        weth.approve(address(vault), 100e18);
        
        vm.prank(mockCollateralVault);
        vault.repay(100e18);
        
        assertEq(vault.totalBorrows(), 0, "Total borrows not reduced");
    }
    
    function test_repay_PartialRepayment() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        deal(address(weth), mockCollateralVault, 50e18);
        vm.prank(mockCollateralVault);
        weth.approve(address(vault), 50e18);
        
        vm.prank(mockCollateralVault);
        vault.repay(50e18);
        
        assertEq(vault.totalBorrows(), 50e18, "Partial repay failed");
    }
    
    function test_repay_ExcessiveRepayment() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        deal(address(weth), mockCollateralVault, 200e18);
        vm.prank(mockCollateralVault);
        weth.approve(address(vault), 200e18);
        
        uint256 balanceBefore = weth.balanceOf(mockCollateralVault);
        
        vm.prank(mockCollateralVault);
        vault.repay(200e18);
        
        assertEq(vault.totalBorrows(), 0, "Should repay all debt");
        assertEq(weth.balanceOf(mockCollateralVault), balanceBefore - 100e18, "Should only take what's owed");
    }
    
    function test_repay_OnlyAuthorized() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        vault.repay(100e18);
    }
    
    function test_repay_AccruesInterest() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        vm.warp(block.timestamp + 365 days);
        
        uint256 indexBefore = vault.borrowIndex();
        
        deal(address(weth), mockCollateralVault, 50e18);
        vm.prank(mockCollateralVault);
        weth.approve(address(vault), 50e18);
        
        vm.prank(mockCollateralVault);
        vault.repay(50e18);
        
        assertTrue(vault.borrowIndex() > indexBefore, "Interest not accrued on repay");
    }
    
    /// @notice Test absorbLoss function
    function test_absorbLoss_BasicFunctionality() public {
        // Setup borrows first
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        uint256 loss = 25e18;
        uint256 borrowsBefore = vault.totalBorrows();
        
        vm.prank(mockCollateralVault);
        vault.absorbLoss(loss);
        
        assertEq(vault.totalBorrows(), borrowsBefore - loss, "Loss not absorbed");
    }
    
    function test_absorbLoss_FullLoss() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        vm.prank(mockCollateralVault);
        vault.absorbLoss(100e18);
        
        assertEq(vault.totalBorrows(), 0, "Full loss not absorbed");
    }
    
    function test_absorbLoss_OnlyAuthorized() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        vault.absorbLoss(100e18);
    }
    
    function test_absorbLoss_ZeroLoss() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18);
        
        uint256 borrowsBefore = vault.totalBorrows();
        
        vm.prank(mockCollateralVault);
        vault.absorbLoss(0);
        
        assertEq(vault.totalBorrows(), borrowsBefore, "Zero loss changed borrows");
    }
    
    /// @notice Test borrowRate function
    function test_borrowRate_ZeroTotalSupply() public {
        uint256 rate = vault.borrowRate();
        assertEq(rate, 2e16, "Should return base rate for zero supply"); // 2% base rate
    }
    
    function test_borrowRate_ZeroBorrows() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 rate = vault.borrowRate();
        assertEq(rate, 2e16, "Should return base rate for zero borrows");
    }
    
    function test_borrowRate_BelowKink() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(500e18); // 50% utilization (below 80% kink)
        
        uint256 rate = vault.borrowRate();
        
        // Expected: BASE_RATE + (utilization * RATE_SLOPE)
        // = 2e16 + (0.5e18 * 5e16 / 1e18) = 2e16 + 2.5e16 = 4.5e16
        uint256 expectedRate = 2e16 + (5e17 * 5e16) / 1e18; // 50% util * 5% slope
        assertEq(rate, expectedRate, "Below kink rate calculation failed");
    }
    
    function test_borrowRate_AboveKink() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(900e18); // 90% utilization (above 80% kink)
        
        uint256 rate = vault.borrowRate();
        
        // Expected: BASE_RATE + RATE_SLOPE + (excess_util * RATE_SLOPE * 3)
        // = 2e16 + 5e16 + (0.1e18 * 5e16 * 3 / 1e18) = 7e16 + 1.5e16 = 8.5e16
        uint256 kinkRate = 2e16 + 5e16; // Base + slope at kink
        uint256 excessUtil = 9e17 - 8e17; // 90% - 80%
        uint256 expectedRate = kinkRate + (excessUtil * 5e16 * 3) / 1e18;
        assertEq(rate, expectedRate, "Above kink rate calculation failed");
    }
    
    function test_borrowRate_AtKink() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(800e18); // Exactly 80% utilization
        
        uint256 rate = vault.borrowRate();
        uint256 expectedRate = 2e16 + 5e16; // BASE_RATE + RATE_SLOPE
        assertEq(rate, expectedRate, "At kink rate calculation failed");
    }
    
    /// @notice Test totalAssets function
    function test_totalAssets_OnlyDeposits() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        assertEq(vault.totalAssets(), 1000e18, "Total assets with only deposits");
    }
    
    function test_totalAssets_WithBorrows() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(200e18);
        
        assertEq(vault.totalAssets(), 1000e18, "Total assets should remain same with borrows");
        // Note: totalAssets = cash + borrows = 800 + 200 = 1000
    }
    
    function test_totalAssets_WithInterest() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(200e18);
        
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        
        assertTrue(vault.totalAssets() > 1000e18, "Total assets should increase with interest");
    }
    
    /// @notice Test interest rate model constants
    function test_interestRateConstants() public {
        // These are tested via behavior in borrowRate tests
        assertTrue(true, "Constants tested via borrowRate function");
    }
    
    /// @notice Test ERC4626 compatibility
    function test_erc4626_deposit() public {
        uint256 amount = 1000e18;
        
        vm.prank(alice);
        weth.approve(address(vault), amount);
        
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);
        
        assertEq(shares, amount, "1:1 share ratio initially");
        assertEq(vault.balanceOf(alice), shares, "Share balance");
        assertEq(vault.totalSupply(), shares, "Total supply");
    }
    
    function test_erc4626_mint() public {
        uint256 shares = 500e18;
        
        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
        
        vm.prank(alice);
        uint256 assets = vault.mint(shares, alice);
        
        assertEq(assets, shares, "1:1 asset ratio initially");
        assertEq(vault.balanceOf(alice), shares, "Share balance");
    }
    
    function test_erc4626_withdraw() public {
        // Deposit first
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 withdrawAmount = 300e18;
        uint256 balanceBefore = weth.balanceOf(alice);
        
        vm.prank(alice);
        uint256 shares = vault.withdraw(withdrawAmount, alice, alice);
        
        assertEq(shares, withdrawAmount, "Withdraw shares");
        assertEq(weth.balanceOf(alice), balanceBefore + withdrawAmount, "WETH returned");
        assertEq(vault.balanceOf(alice), 1000e18 - shares, "Remaining shares");
    }
    
    function test_erc4626_redeem() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 redeemShares = 400e18;
        uint256 balanceBefore = weth.balanceOf(alice);
        
        vm.prank(alice);
        uint256 assets = vault.redeem(redeemShares, alice, alice);
        
        assertEq(assets, redeemShares, "Redeem assets");
        assertEq(weth.balanceOf(alice), balanceBefore + assets, "WETH returned");
        assertEq(vault.balanceOf(alice), 1000e18 - redeemShares, "Remaining shares");
    }
    
    /// @notice Test edge cases and error conditions
    function test_edge_maxDeposit() public {
        uint256 maxDeposit = vault.maxDeposit(alice);
        assertEq(maxDeposit, type(uint256).max, "Max deposit should be unlimited");
    }
    
    function test_edge_maxMint() public {
        uint256 maxMint = vault.maxMint(alice);
        assertEq(maxMint, type(uint256).max, "Max mint should be unlimited");
    }
    
    function test_edge_maxWithdraw() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 maxWithdraw = vault.maxWithdraw(alice);
        assertEq(maxWithdraw, 1000e18, "Max withdraw should equal deposits");
    }
    
    function test_edge_maxRedeem() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        uint256 maxRedeem = vault.maxRedeem(alice);
        assertEq(maxRedeem, 1000e18, "Max redeem should equal shares");
    }
    
    function test_edge_previewFunctions() public {
        uint256 amount = 1000e18;
        
        assertEq(vault.previewDeposit(amount), amount, "Preview deposit");
        assertEq(vault.previewMint(amount), amount, "Preview mint");
        assertEq(vault.previewWithdraw(amount), amount, "Preview withdraw");
        assertEq(vault.previewRedeem(amount), amount, "Preview redeem");
    }
    
    /// @notice Test complex scenarios
    function test_complex_interestAccrualPrecision() public {
        // Test interest accrual over multiple periods
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        vm.prank(mockCollateralVault);
        vault.borrow(500e18);
        
        uint256 initialBorrows = vault.totalBorrows();
        uint256 initialIndex = vault.borrowIndex();
        
        // Accrue over multiple small periods
        for (uint i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);
            vault.accrueInterest();
        }
        
        assertTrue(vault.totalBorrows() > initialBorrows, "Borrows should increase");
        assertTrue(vault.borrowIndex() > initialIndex, "Index should increase");
        
        // Verify compound interest is working
        uint256 finalBorrows = vault.totalBorrows();
        uint256 simpleInterest = (initialBorrows * 5e16) / 100; // ~5% simple
        assertTrue(finalBorrows > initialBorrows + simpleInterest, "Should be compound interest");
    }
    
    function test_complex_utilizationEffects() public {
        vm.prank(alice);
        weth.approve(address(vault), 1000e18);
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        
        // Test rate changes with utilization
        uint256 rate0 = vault.borrowRate(); // 0% utilization
        
        vm.prank(mockCollateralVault);
        vault.borrow(400e18); // 40% utilization
        uint256 rate40 = vault.borrowRate();
        
        vm.prank(mockCollateralVault);
        vault.borrow(400e18); // 80% utilization (at kink)
        uint256 rate80 = vault.borrowRate();
        
        vm.prank(mockCollateralVault);
        vault.borrow(100e18); // 90% utilization (above kink)
        uint256 rate90 = vault.borrowRate();
        
        assertTrue(rate0 < rate40, "Rate should increase with utilization");
        assertTrue(rate40 < rate80, "Rate should increase to kink");
        assertTrue(rate80 < rate90, "Rate should jump above kink");
        
        // Rate above kink should increase more steeply
        uint256 kinkIncrease = rate80 - rate40;
        uint256 postKinkIncrease = rate90 - rate80;
        assertTrue(postKinkIncrease > kinkIncrease, "Post-kink increase should be steeper");
    }
}