// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {LendingFactory} from "../../../src/factories/LendingFactory.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {console2} from "forge-std/console2.sol";

contract LendingFactoryTest is BaseTest {
    
    function setUp() public override {
        super.setUp();
    }
    
    // ============ Constructor Tests ============
    
    function test_Constructor() public view {
        assertEq(lendingFactory.weth(), address(weth));
        assertEq(lendingFactory.treasury(), treasury);
        
        // Should have created a lender vault
        address lenderVaultAddr = lendingFactory.lenderVault();
        assertTrue(lenderVaultAddr != address(0), "LenderVault should be created");
        
        LenderVault lenderVault = LenderVault(lenderVaultAddr);
        assertEq(lenderVault.asset(), address(weth));
    }
    
    function test_LenderVaultCreation() public view {
        LenderVault lenderVault = LenderVault(lendingFactory.lenderVault());
        
        assertEq(lenderVault.name(), "Osito Lender Vault");
        assertEq(lenderVault.symbol(), "oWETH");
        assertEq(lenderVault.decimals(), 18);
        assertEq(lenderVault.asset(), address(weth));
    }
    
    // ============ CollateralVault Creation Tests ============
    
    function test_CreateLendingMarket() public {
        // First launch a token to get a pair
        (OsitoToken token, OsitoPair pair, FeeRouter feeRouter) = _launchToken(
            "Test Token",
            "TEST",
            1_000_000 * 1e18,
            10 ether,
            alice
        );
        
        // Create lending market
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        
        assertTrue(vaultAddr != address(0), "Vault should be created");
        
        // Verify vault is registered
        assertEq(lendingFactory.collateralVaults(address(pair)), vaultAddr);
        
        // Verify vault properties
        CollateralVault vault = CollateralVault(vaultAddr);
        assertEq(vault.pair(), address(pair));
        assertEq(vault.lenderVault(), lendingFactory.lenderVault());
    }
    
    function test_CannotCreateDuplicateMarket() public {
        // Launch token and create first market
        (,OsitoPair pair,) = _launchToken(
            "Duplicate Token",
            "DUP",
            1_000_000 * 1e18,
            10 ether,
            alice
        );
        
        address firstVault = lendingFactory.createLendingMarket(address(pair));
        assertTrue(firstVault != address(0));
        
        // Try to create another market for same pair
        vm.expectRevert("MARKET_EXISTS");
        lendingFactory.createLendingMarket(address(pair));
    }
    
    function test_CreateMultipleMarkets() public {
        // Launch multiple tokens
        (,OsitoPair pair1,) = _launchToken(
            "Token1", "TOK1", 1_000_000 * 1e18, 10 ether, alice
        );
        (,OsitoPair pair2,) = _launchToken(
            "Token2", "TOK2", 2_000_000 * 1e18, 15 ether, bob
        );
        
        // Create markets for both
        address vault1 = lendingFactory.createLendingMarket(address(pair1));
        address vault2 = lendingFactory.createLendingMarket(address(pair2));
        
        assertTrue(vault1 != address(0));
        assertTrue(vault2 != address(0));
        assertTrue(vault1 != vault2, "Vaults should be different");
        
        // Verify both are registered
        assertEq(lendingFactory.collateralVaults(address(pair1)), vault1);
        assertEq(lendingFactory.collateralVaults(address(pair2)), vault2);
    }
    
    function testFuzz_CreateLendingMarket(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 liquidity
    ) public {
        // Bound inputs
        vm.assume(bytes(name).length > 0 && bytes(name).length < 20);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length < 10);
        supply = bound(supply, 1000 * 1e18, 1e9 * 1e18);
        liquidity = bound(liquidity, 0.1 ether, 100 ether);
        
        // Launch token
        (,OsitoPair pair,) = _launchToken(name, symbol, supply, liquidity, alice);
        
        // Create lending market
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        
        assertTrue(vaultAddr != address(0));
        assertEq(lendingFactory.collateralVaults(address(pair)), vaultAddr);
    }
    
    // ============ Market Query Tests ============
    
    function test_GetCollateralVault() public {
        (,OsitoPair pair,) = _launchToken(
            "Query Token", "QUERY", 1_000_000 * 1e18, 5 ether, alice
        );
        
        // Should return zero address before creation
        assertEq(lendingFactory.collateralVaults(address(pair)), address(0));
        
        // Create market
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        
        // Should return vault address after creation
        assertEq(lendingFactory.collateralVaults(address(pair)), vaultAddr);
    }
    
    function test_NonExistentMarket() public view {
        address randomPair = address(0x123);
        assertEq(lendingFactory.collateralVaults(randomPair), address(0));
    }
    
    // ============ Integration Tests ============
    
    function test_EndToEndLendingFlow() public {
        // 1. Launch token
        (OsitoToken token, OsitoPair pair,) = _launchToken(
            "Flow Token", "FLOW", 1_000_000 * 1e18, 20 ether, alice
        );
        
        // 2. Create lending market
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        CollateralVault vault = CollateralVault(vaultAddr);
        
        // 3. Fund lender vault
        LenderVault lenderVault = LenderVault(lendingFactory.lenderVault());
        vm.startPrank(bob);
        weth.approve(address(lenderVault), 100 ether);
        lenderVault.deposit(100 ether, bob);
        vm.stopPrank();
        
        // 4. Get some tokens by swapping
        vm.startPrank(alice);
        _swap(pair, address(weth), 1 ether, alice);
        vm.stopPrank();
        
        // 5. Deposit collateral and borrow
        uint256 tokenBalance = token.balanceOf(alice);
        uint256 collateralAmount = tokenBalance / 10; // Use 10% as collateral
        
        vm.startPrank(alice);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        // Try to borrow a small amount
        vault.borrow(0.1 ether);
        vm.stopPrank();
        
        // Verify borrow was recorded
        (uint256 principal,) = vault.accountBorrows(alice);
        assertEq(principal, 0.1 ether);
    }
    
    function test_MultipleMarketsIntegration() public {
        // Create multiple token pairs and markets
        (OsitoToken token1, OsitoPair pair1,) = _launchToken(
            "Multi1", "M1", 1_000_000 * 1e18, 10 ether, alice
        );
        (OsitoToken token2, OsitoPair pair2,) = _launchToken(
            "Multi2", "M2", 2_000_000 * 1e18, 20 ether, bob
        );
        
        address vault1 = lendingFactory.createLendingMarket(address(pair1));
        address vault2 = lendingFactory.createLendingMarket(address(pair2));
        
        // Fund lender vault
        LenderVault lenderVault = LenderVault(lendingFactory.lenderVault());
        vm.startPrank(charlie);
        weth.approve(address(lenderVault), 200 ether);
        lenderVault.deposit(200 ether, charlie);
        vm.stopPrank();
        
        // Both markets should share the same lender vault
        assertEq(CollateralVault(vault1).lenderVault(), address(lenderVault));
        assertEq(CollateralVault(vault2).lenderVault(), address(lenderVault));
        
        // Both should be able to borrow from the shared pool
        assertEq(lenderVault.totalAssets(), 200 ether);
    }
    
    // ============ Access Control Tests ============
    
    function test_PermissionlessMarketCreation() public {
        // Anyone should be able to create a lending market
        (,OsitoPair pair,) = _launchToken(
            "Permissionless", "PERM", 1_000_000 * 1e18, 5 ether, alice
        );
        
        // Charlie creates market for alice's token
        vm.prank(charlie);
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        
        assertTrue(vaultAddr != address(0));
        assertEq(lendingFactory.collateralVaults(address(pair)), vaultAddr);
    }
    
    // ============ Validation Tests ============
    
    function test_CreateMarketZeroAddress() public {
        vm.expectRevert();
        lendingFactory.createLendingMarket(address(0));
    }
    
    function test_CreateMarketInvalidPair() public {
        // Try to create market for non-pair address
        vm.expectRevert();
        lendingFactory.createLendingMarket(address(weth));
    }
    
    // ============ State Management Tests ============
    
    function test_FactoryState() public view {
        // Factory should maintain correct state
        assertTrue(lendingFactory.lenderVault() != address(0));
        assertEq(lendingFactory.weth(), address(weth));
        assertEq(lendingFactory.treasury(), treasury);
    }
    
    function test_LenderVaultSharing() public {
        // All markets should share the same lender vault
        (,OsitoPair pair1,) = _launchToken("Share1", "SH1", 1000 * 1e18, 1 ether, alice);
        (,OsitoPair pair2,) = _launchToken("Share2", "SH2", 2000 * 1e18, 2 ether, bob);
        
        address vault1 = lendingFactory.createLendingMarket(address(pair1));
        address vault2 = lendingFactory.createLendingMarket(address(pair2));
        
        address lenderVault = lendingFactory.lenderVault();
        
        assertEq(CollateralVault(vault1).lenderVault(), lenderVault);
        assertEq(CollateralVault(vault2).lenderVault(), lenderVault);
    }
    
    // ============ Gas Tests ============
    
    function test_GasCreateMarket() public {
        (,OsitoPair pair,) = _launchToken(
            "Gas Token", "GAS", 1_000_000 * 1e18, 10 ether, alice
        );
        
        uint256 gasStart = gasleft();
        lendingFactory.createLendingMarket(address(pair));
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for market creation:", gasUsed);
        assertTrue(gasUsed < 3_000_000, "Market creation should be reasonably gas efficient");
    }
    
    // ============ Edge Cases ============
    
    function test_MarketCreationOrder() public {
        // Create pairs first
        (,OsitoPair pair1,) = _launchToken("Order1", "ORD1", 1000 * 1e18, 1 ether, alice);
        (,OsitoPair pair2,) = _launchToken("Order2", "ORD2", 2000 * 1e18, 2 ether, bob);
        
        // Create markets in different order
        address vault2 = lendingFactory.createLendingMarket(address(pair2));
        address vault1 = lendingFactory.createLendingMarket(address(pair1));
        
        // Both should work regardless of order
        assertTrue(vault1 != address(0));
        assertTrue(vault2 != address(0));
        assertTrue(vault1 != vault2);
    }
    
    function test_FactoryConsistency() public {
        // Create multiple markets and verify consistency
        address[] memory pairs = new address[](5);
        address[] memory vaults = new address[](5);
        
        for (uint i = 0; i < 5; i++) {
            (,OsitoPair pair,) = _launchToken(
                string(abi.encodePacked("Token", i)),
                string(abi.encodePacked("TOK", i)),
                (i + 1) * 1000 * 1e18,
                (i + 1) * 1 ether,
                alice
            );
            
            pairs[i] = address(pair);
            vaults[i] = lendingFactory.createLendingMarket(address(pair));
        }
        
        // Verify all mappings are correct
        for (uint i = 0; i < 5; i++) {
            assertEq(lendingFactory.collateralVaults(pairs[i]), vaults[i]);
            assertEq(CollateralVault(vaults[i]).pair(), pairs[i]);
        }
    }
}