// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Simplified invariant tests that actually run
contract SimpleInvariantsTest is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 public lastPMin;
    uint256 public lastK;
    uint256 public lastSupply;
    
    function setUp() public override {
        super.setUp();
        
        // Simple token launch
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST",
            1_000_000 * 1e18,
            10 ether,
            alice
        );
        
        // Setup lending
        lenderVault = LenderVault(lendingFactory.lenderVault());
        vault = _createLendingMarket(address(pair));
        
        // Fund lender vault
        vm.startPrank(bob);
        weth.approve(address(lenderVault), 50 ether);
        lenderVault.deposit(50 ether, bob);
        vm.stopPrank();
        
        // Store initial state
        lastPMin = pair.pMin();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        lastK = uint256(r0) * uint256(r1);
        lastSupply = token.totalSupply();
    }
    
    // Simple invariant: pMin should never decrease
    function invariant_pMinNeverDecreases() public {
        uint256 currentPMin = pair.pMin();
        assertGe(currentPMin, lastPMin, "pMin decreased!");
        lastPMin = currentPMin;
    }
    
    // Simple invariant: K should never decrease
    function invariant_kNeverDecreases() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        assertGe(currentK, lastK, "K decreased!");
        lastK = currentK;
    }
    
    // Simple invariant: Supply can only decrease
    function invariant_supplyOnlyDecreases() public {
        uint256 currentSupply = token.totalSupply();
        assertLe(currentSupply, lastSupply, "Supply increased!");
        lastSupply = currentSupply;
    }
    
    // Simple invariant: Token conservation
    function invariant_tokenConservation() public {
        uint256 totalSupply = token.totalSupply();
        
        uint256 sumBalances = 0;
        sumBalances += token.balanceOf(alice);
        sumBalances += token.balanceOf(bob);
        sumBalances += token.balanceOf(charlie);
        sumBalances += token.balanceOf(dave);
        sumBalances += token.balanceOf(eve);
        sumBalances += token.balanceOf(address(pair));
        sumBalances += token.balanceOf(address(vault));
        sumBalances += token.balanceOf(address(feeRouter));
        sumBalances += token.balanceOf(address(lenderVault));
        
        // Allow small difference for rounding
        assertApproxEq(totalSupply, sumBalances, 1000, "Token conservation violated!");
    }
}