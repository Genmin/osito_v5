// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/LenderVault.sol";
import "../src/core/OsitoPair.sol";
import "../src/core/OsitoToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) { return "Mock WETH"; }
    function symbol() public pure override returns (string memory) { return "WETH"; }
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract BorrowFundsDeliveryTest is Test {
    MockWETH qtToken;
    OsitoToken collateralToken;
    OsitoPair pair;
    LenderVault lenderVault;
    CollateralVault vault;
    
    address borrower = address(0x1);
    address lender = address(0x2);
    address treasury = address(0x3);
    
    function setUp() public {
        // Deploy tokens
        qtToken = new MockWETH();
        collateralToken = new OsitoToken("Collateral", "COL", 1_000_000e18, "", address(this));
        
        // Create pair
        pair = new OsitoPair(
            address(collateralToken),
            address(qtToken),
            address(0), // feeRouter
            9500,
            30,
            1e16,
            true
        );
        
        // Initialize pair with liquidity
        collateralToken.transfer(address(pair), 1_000_000e18);
        qtToken.mint(address(pair), 100e18);
        pair.mint(address(0));
        
        // Deploy lending infrastructure (this contract acts as factory)
        lenderVault = new LenderVault(address(qtToken), address(this), treasury);
        vault = new CollateralVault(address(collateralToken), address(pair), address(lenderVault));
        
        // Authorize vault to borrow (as factory)
        lenderVault.authorize(address(vault));
        
        // Fund lender vault with QT (mint to this, then deposit)
        qtToken.mint(address(this), 1000e18);
        qtToken.approve(address(lenderVault), 1000e18);
        lenderVault.deposit(1000e18, address(this));
        
        // Give borrower some collateral
        collateralToken.transfer(borrower, 10000e18);
    }
    
    function test_BorrowDeliversFundsToBorrower() public {
        // Setup: Borrower deposits collateral
        vm.startPrank(borrower);
        collateralToken.approve(address(vault), 10000e18);
        vault.depositCollateral(10000e18);
        
        // Check initial QT balance
        uint256 qtBalanceBefore = qtToken.balanceOf(borrower);
        assertEq(qtBalanceBefore, 0, "Borrower should start with no QT");
        
        // Get pMin to calculate max borrow
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (10000e18 * pMin) / 1e18;
        
        // Borrow half of max
        uint256 borrowAmount = maxBorrow / 2;
        vault.borrow(borrowAmount);
        
        // Check QT was delivered to borrower
        uint256 qtBalanceAfter = qtToken.balanceOf(borrower);
        assertEq(qtBalanceAfter, borrowAmount, "Borrower should receive borrowed QT");
        
        // Verify vault doesn't hold the QT
        uint256 vaultQtBalance = qtToken.balanceOf(address(vault));
        assertEq(vaultQtBalance, 0, "Vault should not hold borrowed QT");
        
        vm.stopPrank();
    }
    
    function test_RepayPullsFundsFromBorrower() public {
        // Setup: Borrower has a loan
        vm.startPrank(borrower);
        collateralToken.approve(address(vault), 10000e18);
        vault.depositCollateral(10000e18);
        
        uint256 pMin = pair.pMin();
        uint256 borrowAmount = (10000e18 * pMin) / 1e18 / 2;
        vault.borrow(borrowAmount);
        
        // Borrower should have the QT
        assertEq(qtToken.balanceOf(borrower), borrowAmount, "Should have borrowed funds");
        
        // Approve vault to pull QT for repayment
        qtToken.approve(address(vault), borrowAmount);
        
        // Repay the loan
        vault.repay(borrowAmount);
        
        // Borrower's QT should be gone
        assertEq(qtToken.balanceOf(borrower), 0, "QT should be repaid");
        
        // Debt should be cleared
        (uint256 principal, , ) = vault.accountBorrows(borrower);
        assertEq(principal, 0, "Debt should be cleared");
        
        vm.stopPrank();
    }
    
    function test_MultipleUsersCanBorrow() public {
        address alice = address(0x4);
        address bob = address(0x5);
        
        // Give both users collateral
        collateralToken.transfer(alice, 5000e18);
        collateralToken.transfer(bob, 5000e18);
        
        // Alice borrows
        vm.startPrank(alice);
        collateralToken.approve(address(vault), 5000e18);
        vault.depositCollateral(5000e18);
        uint256 pMin = pair.pMin();
        uint256 aliceBorrow = (5000e18 * pMin) / 1e18 / 2;
        vault.borrow(aliceBorrow);
        vm.stopPrank();
        
        // Bob borrows
        vm.startPrank(bob);
        collateralToken.approve(address(vault), 5000e18);
        vault.depositCollateral(5000e18);
        uint256 bobBorrow = (5000e18 * pMin) / 1e18 / 2;
        vault.borrow(bobBorrow);
        vm.stopPrank();
        
        // Both should have received their QT
        assertEq(qtToken.balanceOf(alice), aliceBorrow, "Alice should have QT");
        assertEq(qtToken.balanceOf(bob), bobBorrow, "Bob should have QT");
        
        // Vault should hold no QT
        assertEq(qtToken.balanceOf(address(vault)), 0, "Vault should hold no QT");
    }
}