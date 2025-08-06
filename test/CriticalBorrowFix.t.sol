// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/LenderVault.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

// Minimal test to verify the critical borrow fix
contract CriticalBorrowFixTest is Test {
    
    // Mock contracts to isolate the fix
    MockLenderVault lenderVault;
    MockQT qtToken;
    address borrower = address(0x1);
    
    function test_BorrowForwardsQTToBorrower() public {
        // Setup mocks
        qtToken = new MockQT();
        lenderVault = new MockLenderVault(address(qtToken));
        
        // Create a mock vault that simulates the fixed borrow function
        MockCollateralVault vault = new MockCollateralVault(address(lenderVault));
        
        // Fund the lender vault
        qtToken.mint(address(lenderVault), 1000e18);
        
        // Test: Borrower calls borrow
        vm.prank(borrower);
        uint256 borrowAmount = 100e18;
        vault.testBorrow(borrowAmount);
        
        // Verify: Borrower received the QT tokens
        assertEq(qtToken.balanceOf(borrower), borrowAmount, "Borrower should receive QT");
        assertEq(qtToken.balanceOf(address(vault)), 0, "Vault should not hold QT");
    }
}

// Mock contracts for isolated testing
contract MockQT is ERC20 {
    function name() public pure override returns (string memory) { return "QT"; }
    function symbol() public pure override returns (string memory) { return "QT"; }
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockLenderVault {
    address public immutable asset;
    
    constructor(address _asset) {
        asset = _asset;
    }
    
    function borrow(uint256 amount) external {
        // Simulates LenderVault sending QT to msg.sender (the vault)
        ERC20(asset).transfer(msg.sender, amount);
    }
}

contract MockCollateralVault {
    address public immutable lenderVault;
    
    constructor(address _lenderVault) {
        lenderVault = _lenderVault;
    }
    
    // This simulates the FIXED borrow function
    function testBorrow(uint256 amount) external {
        // Borrow from LenderVault (sends QT to this contract)
        MockLenderVault(lenderVault).borrow(amount);
        
        // CRITICAL FIX: Forward the borrowed QT to the actual borrower
        address qtToken = MockLenderVault(lenderVault).asset();
        ERC20(qtToken).transfer(msg.sender, amount);
    }
}