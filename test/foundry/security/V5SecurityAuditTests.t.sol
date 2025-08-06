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

/// @notice Tests for V5 security audit findings
contract V5SecurityAuditTests is BaseTest {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
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
        
        vault = _createLendingMarket(address(pair));
        lenderVault = LenderVault(lendingFactory.lenderVault());
        
        // Fund lender vault
        deal(address(weth), alice, 1000 ether);
        vm.startPrank(alice);
        weth.approve(address(lenderVault), 1000 ether);
        lenderVault.deposit(1000 ether, alice);
        vm.stopPrank();
    }
    
    /// @notice Test C-1: Re-entrancy in LenderVault.borrow()
    function test_C1_ReentrancyInBorrow() public {
        console2.log("=== Testing C-1: Re-entrancy in borrow() ===");
        
        // Deploy malicious borrower contract
        ReentrantBorrower attacker = new ReentrantBorrower(lenderVault, vault);
        
        // Give attacker some collateral
        deal(address(token), address(attacker), 10000 * 1e18);
        
        // Attacker deposits collateral
        attacker.depositCollateral(10000 * 1e18);
        
        // Try re-entrant borrow attack
        // This SHOULD fail if properly protected
        vm.expectRevert(); // Should revert due to reentrancy or liquidity check
        attacker.attackBorrow();
        
        console2.log("Re-entrancy attack blocked (or would drain reserves if vulnerable)");
    }
    
    /// @notice Test C-2: Front-running grief in recover()
    function test_C2_FrontRunningRecover() public {
        console2.log("=== Testing C-2: Front-running recover() ===");
        
        // Setup: Bob has unhealthy position
        deal(address(token), bob, 10000 * 1e18);
        vm.startPrank(bob);
        token.approve(address(vault), 10000 * 1e18);
        vault.depositCollateral(10000 * 1e18);
        uint256 pMin = pair.pMin();
        vault.borrow((10000 * 1e18 * pMin * 90) / (1e18 * 100));
        vm.stopPrank();
        
        // Make position unhealthy by time passing (interest accrual)
        vm.warp(block.timestamp + 365 days);
        
        // Mark OTM
        vault.markOTM(bob);
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Front-runner (charlie) watches mempool
        vm.startPrank(charlie);
        
        // Get reserves before
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        
        // Front-run with small swap to change reserves
        deal(address(weth), charlie, 1 ether);
        weth.approve(address(pair), 1 ether);
        _swap(pair, address(weth), 0.01 ether, charlie);
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        
        // Reserves changed
        assertTrue(r0After != r0Before || r1After != r1Before, "Reserves should change");
        
        vm.stopPrank();
        
        // Now alice tries to recover - might fail due to changed reserves
        vm.prank(alice);
        try vault.recover(bob) {
            console2.log("Recovery succeeded despite front-running");
        } catch {
            console2.log("Recovery griefed by front-runner changing reserves!");
        }
    }
    
    /// @notice Test H-1: Fee-on-transfer token incompatibility
    function test_H1_FeeOnTransferTokens() public {
        console2.log("=== Testing H-1: Fee-on-transfer incompatibility ===");
        
        // Deploy fee-on-transfer token
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        
        // If system accepts fee-on-transfer tokens, accounting breaks
        deal(address(feeToken), alice, 1000 * 1e18);
        
        vm.startPrank(alice);
        uint256 balanceBefore = feeToken.balanceOf(alice);
        feeToken.transfer(bob, 100 * 1e18);
        uint256 balanceAfter = feeToken.balanceOf(alice);
        uint256 bobBalance = feeToken.balanceOf(bob);
        
        // With 1% fee, bob receives 99 tokens, not 100
        assertEq(bobBalance, 99 * 1e18, "Fee-on-transfer takes 1%");
        assertEq(balanceBefore - balanceAfter, 100 * 1e18, "Alice sent 100");
        
        console2.log("Fee-on-transfer would break 1:1 transfer assumptions");
        vm.stopPrank();
    }
    
    /// @notice Test H-2: Lender APR denial-of-service
    function test_H2_LenderAPRDoS() public {
        console2.log("=== Testing H-2: APR DoS via lazy accrual ===");
        
        // Setup: Create a borrow
        deal(address(token), bob, 10000 * 1e18);
        vm.startPrank(bob);
        token.approve(address(vault), 10000 * 1e18);
        vault.depositCollateral(10000 * 1e18);
        vault.borrow(100 * 1e18);
        vm.stopPrank();
        
        // Check initial borrow rate
        uint256 initialRate = lenderVault.borrowRate();
        console2.log("Initial borrow rate:", initialRate);
        
        // No activity for 30 days (no accrual calls)
        vm.warp(block.timestamp + 30 days);
        
        // Rate appears unchanged because no accrual
        uint256 staleRate = lenderVault.borrowRate();
        console2.log("Rate after 30 days (stale):", staleRate);
        
        // Now someone calls accrueInterest
        lenderVault.accrueInterest();
        
        // Rate updates all at once
        uint256 updatedRate = lenderVault.borrowRate();
        console2.log("Rate after accrual:", updatedRate);
        
        // This lazy accrual can make APR appear 0 for long periods
        assertTrue(staleRate == initialRate, "Rate doesn't update without accrual");
    }
    
    /// @notice Test 2.1: Supply cap corner case
    function test_SupplyCapCornerCase() public {
        console2.log("=== Testing Supply Cap Corner Case ===");
        
        // MAX_SUPPLY = 2^111
        uint256 MAX_SUPPLY = 2**111;
        
        // With 18 decimals, actual max should be 2^111 / 1e18
        uint256 maxWholeTokens = MAX_SUPPLY / 1e18;
        console2.log("Max whole tokens allowed:", maxWholeTokens);
        
        // This is about 2.5 * 10^14 tokens
        // If someone tries to launch with more, it should fail
        uint256 tooManyTokens = (maxWholeTokens + 1) * 1e18;
        
        // This would overflow reserves if allowed
        console2.log("Trying to launch with:", tooManyTokens);
        
        // In production, this check should be:
        // require(supply <= MAX_SUPPLY / 10**decimals, "Supply too large");
    }
    
    /// @notice Test 2.3: Partial repayments don't clear OTM
    function test_PartialRepaymentOTMBug() public {
        console2.log("=== Testing Partial Repayment OTM Bug ===");
        
        // Setup: Bob has unhealthy position
        deal(address(token), bob, 10000 * 1e18);
        deal(address(weth), bob, 1000 * 1e18);
        
        vm.startPrank(bob);
        token.approve(address(vault), 10000 * 1e18);
        vault.depositCollateral(10000 * 1e18);
        
        // Borrow close to max
        uint256 pMin = pair.pMin();
        uint256 borrowAmount = (10000 * 1e18 * pMin * 95) / (1e18 * 100);
        vault.borrow(borrowAmount);
        vm.stopPrank();
        
        // Time passes, position becomes unhealthy due to interest
        vm.warp(block.timestamp + 365 days);
        lenderVault.accrueInterest();
        
        // Mark as OTM
        vault.markOTM(bob);
        (uint256 markTime, bool isOTM) = vault.otmPositions(bob);
        assertTrue(isOTM, "Should be marked OTM");
        
        // Bob partially repays to become healthy
        vm.startPrank(bob);
        weth.approve(address(vault), borrowAmount / 2);
        vault.repay(borrowAmount / 2);
        vm.stopPrank();
        
        // Check if still OTM
        (, bool stillOTM) = vault.otmPositions(bob);
        
        // BUG: Position is healthy but still marked OTM!
        if (stillOTM && vault.isPositionHealthy(bob)) {
            console2.log("BUG: Healthy position still marked OTM after partial repay!");
        }
    }
    
    /// @notice Test 2.4: Stuck token donations (QT side)
    function test_StuckQTDonations() public {
        console2.log("=== Testing Stuck QT Donations ===");
        
        // Get initial reserves
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 actualWethBefore = weth.balanceOf(address(pair));
        
        // Someone donates WETH directly to pair
        deal(address(weth), alice, 100 ether);
        vm.prank(alice);
        weth.transfer(address(pair), 50 ether);
        
        // Check reserves vs actual balance
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 actualWethAfter = weth.balanceOf(address(pair));
        
        console2.log("Reserves WETH:", pair.tokIsToken0() ? r1After : r0After);
        console2.log("Actual WETH:", actualWethAfter);
        console2.log("Stuck WETH:", actualWethAfter - (pair.tokIsToken0() ? r1After : r0After));
        
        // Reserves don't update without sync() which is disabled
        assertEq(r0After, r0Before, "TOK reserves unchanged");
        assertEq(r1After, r1Before, "QT reserves unchanged");
        assertGt(actualWethAfter, actualWethBefore, "But actual balance increased");
        
        // This WETH is stuck forever - can't sync, can't skim
        console2.log("Donated WETH is permanently stuck (by design)");
    }
}

/// @notice Malicious contract for reentrancy attack
contract ReentrantBorrower {
    LenderVault public lenderVault;
    CollateralVault public collateralVault;
    uint256 public borrowCount;
    bool attacking;
    
    constructor(LenderVault _lenderVault, CollateralVault _collateralVault) {
        lenderVault = _lenderVault;
        collateralVault = _collateralVault;
    }
    
    function depositCollateral(uint256 amount) external {
        ERC20(collateralVault.collateralToken()).approve(address(collateralVault), amount);
        collateralVault.depositCollateral(amount);
    }
    
    function attackBorrow() external {
        attacking = true;
        borrowCount = 0;
        
        // Start the attack with first borrow
        uint256 pMin = OsitoPair(collateralVault.pair()).pMin();
        uint256 maxBorrow = (collateralVault.collateralBalances(address(this)) * pMin) / 1e18;
        
        collateralVault.borrow(maxBorrow / 10); // Borrow 10% to start
    }
    
    // Called when receiving WETH from borrow
    receive() external payable {
        if (attacking && borrowCount < 10) {
            borrowCount++;
            // Try to re-enter and borrow more
            uint256 pMin = OsitoPair(collateralVault.pair()).pMin();
            uint256 maxBorrow = (collateralVault.collateralBalances(address(this)) * pMin) / 1e18;
            
            // Each re-entry tries to borrow more
            try collateralVault.borrow(maxBorrow / 10) {
                console2.log("Re-entrant borrow", borrowCount, "succeeded!");
            } catch {
                attacking = false;
            }
        }
    }
}

/// @notice Mock fee-on-transfer token
contract FeeOnTransferToken is ERC20 {
    uint256 constant FEE_BPS = 100; // 1% fee
    
    function name() public pure override returns (string memory) {
        return "FeeToken";
    }
    
    function symbol() public pure override returns (string memory) {
        return "FEE";
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 actualAmount = amount - fee;
        
        // Transfer actual amount to recipient
        super.transfer(to, actualAmount);
        // Fee disappears (burned)
        _burn(msg.sender, fee);
        
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 actualAmount = amount - fee;
        
        // Transfer actual amount to recipient
        super.transferFrom(from, to, actualAmount);
        // Fee disappears (burned)
        _burn(from, fee);
        
        return true;
    }
}