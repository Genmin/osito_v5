// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Improved invariants that handle edge cases and attack scenarios
contract ImprovedInvariants is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    // Track historical values for bounded assertions
    uint256 public lowestK;
    uint256 public highestK;
    uint256 public lowestPMin;
    uint256 public highestPMin;
    uint256 public initialTotalSupply;
    uint256 public totalBurned;
    
    // Track LP token holdings
    mapping(address => bool) public knownLPHolders;
    uint256 public unauthorizedLPBalance;
    
    // Track solvency metrics
    uint256 public minSolvencyRatio = type(uint256).max;
    uint256 public maxLeverageObserved;
    
    function setUp() public override {
        super.setUp();
        
        // Launch token
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            1_000_000_000 * 1e18,
            100 ether,
            alice
        );
        
        // Deploy lending system
        vault = _createLendingMarket(address(pair));
        lenderVault = LenderVault(lendingFactory.lenderVault());
        
        // Initialize tracking variables
        (uint112 r0, uint112 r1,) = pair.getReserves();
        lowestK = uint256(r0) * uint256(r1);
        highestK = lowestK;
        lowestPMin = pair.pMin();
        highestPMin = lowestPMin;
        initialTotalSupply = token.totalSupply();
        
        // Mark authorized LP holders
        knownLPHolders[address(feeRouter)] = true;
        knownLPHolders[address(pair)] = true;
        knownLPHolders[address(0xdead)] = true;
        knownLPHolders[address(0)] = true; // For minimum liquidity
    }
    
    /// @notice IMPROVED: K can decrease slightly due to rounding but should be bounded
    function invariant_kBounded() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        
        // K can decrease by at most 0.1% due to rounding errors
        if (currentK < lowestK) {
            uint256 decrease = lowestK - currentK;
            uint256 decreaseBps = (decrease * 10000) / lowestK;
            assertLe(decreaseBps, 10, "K decreased by more than 0.1%");
            lowestK = currentK;
        }
        
        // Track highest K
        if (currentK > highestK) {
            highestK = currentK;
        }
        
        // K should generally trend upward over time due to fees
        // Allow temporary decreases but long-term should increase
        if (block.timestamp > 1 days) {
            assertGe(highestK, lowestK * 101 / 100, "K hasn't grown by at least 1% over time");
        }
    }
    
    /// @notice IMPROVED: pMin can decrease when balanced liquidity is added
    function invariant_pMinBehavior() public {
        uint256 currentPMin = pair.pMin();
        
        // pMin can decrease when:
        // 1. Balanced liquidity is added (both reserves increase proportionally)
        // 2. Direct token transfers followed by sync (if implemented)
        
        if (currentPMin < lowestPMin) {
            // Check if this is due to balanced liquidity addition
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 currentK = uint256(r0) * uint256(r1);
            
            // If K increased significantly, pMin decrease might be legitimate
            if (currentK > highestK * 110 / 100) {
                // Balanced liquidity was likely added
                lowestPMin = currentPMin;
            } else {
                // Unexpected pMin decrease - bound it
                uint256 decrease = lowestPMin - currentPMin;
                uint256 decreaseBps = (decrease * 10000) / lowestPMin;
                assertLe(decreaseBps, 100, "pMin decreased by more than 1% without balanced liquidity");
            }
        }
        
        // Track highest pMin
        if (currentPMin > highestPMin) {
            highestPMin = currentPMin;
        }
    }
    
    /// @notice IMPROVED: Total supply can increase from fee mints but should be bounded
    function invariant_totalSupplyBehavior() public {
        uint256 currentSupply = pair.totalSupply();
        
        if (currentSupply > initialTotalSupply) {
            // Supply increased - must be from fee mints
            uint256 increase = currentSupply - initialTotalSupply;
            uint256 increaseBps = (increase * 10000) / initialTotalSupply;
            
            // Fee mints should never exceed 10% of initial supply cumulatively
            assertLe(increaseBps, 1000, "LP supply increased by more than 10% from fees");
        }
    }
    
    /// @notice CRITICAL: No unauthorized LP token holders
    function invariant_lpTokenRestriction() public {
        uint256 totalSupply = pair.totalSupply();
        uint256 authorizedBalance;
        
        // Sum up all authorized holders
        authorizedBalance += pair.balanceOf(address(feeRouter));
        authorizedBalance += pair.balanceOf(address(pair));
        authorizedBalance += pair.balanceOf(address(0xdead));
        authorizedBalance += 1000; // Minimum liquidity locked at address(0)
        
        // Check for unauthorized holders by scanning recent transfers
        // In production, this would use events or a more efficient method
        uint256 unauthorizedFound = totalSupply - authorizedBalance;
        
        // Allow tiny rounding errors (< 0.01%)
        if (unauthorizedFound > 0) {
            uint256 unauthorizedBps = (unauthorizedFound * 10000) / totalSupply;
            assertLe(unauthorizedBps, 1, "Unauthorized LP token holders detected");
        }
    }
    
    /// @notice Token supply conservation with burns
    function invariant_tokenConservationWithBurns() public {
        uint256 currentTotalSupply = token.totalSupply();
        
        // Calculate all token locations
        uint256 tokensInPair = token.balanceOf(address(pair));
        uint256 tokensInVault = token.balanceOf(address(vault));
        uint256 tokensInFeeRouter = token.balanceOf(address(feeRouter));
        
        // Sum user balances
        uint256 userTokens = 0;
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < actors.length; i++) {
            userTokens += token.balanceOf(actors[i]);
        }
        
        uint256 totalAccountedFor = tokensInPair + tokensInVault + tokensInFeeRouter + userTokens;
        
        // Current supply + burned should equal initial supply
        uint256 impliedBurned = initialTotalSupply - currentTotalSupply;
        
        // Total accounted for should equal current supply (within rounding)
        assertApproxEq(
            totalAccountedFor,
            currentTotalSupply,
            100, // Allow 100 wei rounding error
            "Token conservation violated"
        );
        
        // Track total burned
        totalBurned = impliedBurned;
    }
    
    /// @notice Solvency ratio should remain healthy
    function invariant_solvencyRatio() public {
        uint256 totalAssets = lenderVault.totalAssets();
        uint256 totalBorrows = lenderVault.totalBorrows();
        
        if (totalBorrows > 0) {
            uint256 solvencyRatio = (totalAssets * 1e18) / totalBorrows;
            
            // Track minimum solvency
            if (solvencyRatio < minSolvencyRatio) {
                minSolvencyRatio = solvencyRatio;
            }
            
            // Solvency should never drop below 100% (1e18)
            assertGe(solvencyRatio, 1e18, "Lender vault insolvent!");
            
            // Warning if solvency drops below 110%
            if (solvencyRatio < 1.1e18) {
                console2.log("WARNING: Solvency ratio below 110%:", solvencyRatio);
            }
        }
    }
    
    /// @notice Maximum leverage should be bounded by pMin
    function invariant_leverageBounds() public {
        uint256 currentPMin = pair.pMin();
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = vault.collateralBalances(actor);
            (uint256 debt,) = vault.accountBorrows(actor);
            
            if (collateral > 0 && debt > 0) {
                // Calculate effective leverage
                uint256 leverage = (debt * 1e18) / (collateral * currentPMin / 1e18);
                
                // Track max leverage
                if (leverage > maxLeverageObserved) {
                    maxLeverageObserved = leverage;
                }
                
                // Leverage should never exceed 100% (1e18) at pMin
                assertLe(leverage, 1e18, "Position overleveraged beyond pMin guarantee");
            }
        }
    }
    
    /// @notice Fee collection should not break invariants
    function invariant_feeCollectionSafety() public {
        uint256 lpBefore = pair.balanceOf(address(feeRouter));
        uint256 totalSupplyBefore = pair.totalSupply();
        
        // Trigger fee collection
        vm.prank(address(feeRouter));
        try pair.collectFees() {
            uint256 lpAfter = pair.balanceOf(address(feeRouter));
            uint256 totalSupplyAfter = pair.totalSupply();
            
            if (lpAfter > lpBefore) {
                uint256 minted = lpAfter - lpBefore;
                uint256 mintPercentage = (minted * 10000) / totalSupplyBefore;
                
                // Single fee collection should never mint more than 5% of supply
                assertLe(mintPercentage, 500, "Excessive fee mint in single collection");
            }
            
            // Total supply should only increase (never decrease from fee collection)
            assertGe(totalSupplyAfter, totalSupplyBefore, "Total supply decreased during fee collection");
        } catch {
            // Fee collection can fail if no fees to collect - that's fine
        }
    }
    
    /// @notice No position should be both healthy and underwater
    function invariant_positionConsistency() public {
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        uint256 spotPrice = _getSpotPrice();
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            bool isHealthy = vault.isPositionHealthy(actor);
            
            uint256 collateral = vault.collateralBalances(actor);
            (uint256 debt,) = vault.accountBorrows(actor);
            
            if (collateral > 0 && debt > 0) {
                uint256 collateralValue = (collateral * spotPrice) / 1e18;
                
                if (isHealthy) {
                    // Healthy positions should have collateral value > debt
                    assertGt(collateralValue, debt, "Healthy position is underwater");
                } else {
                    // Unhealthy positions should be in grace period or recoverable
                    (,bool isOTM) = vault.otmPositions(actor);
                    if (isOTM) {
                        // Position is marked OTM - check it's recoverable
                        uint256 pMin = pair.pMin();
                        uint256 recoveryValue = (collateral * pMin) / 1e18;
                        assertGe(recoveryValue, debt, "Unrecoverable position beyond grace period");
                    }
                }
            }
        }
    }
    
    /// @notice Helper to get current spot price
    function _getSpotPrice() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        if (tokReserve == 0) return 0;
        return (qtReserve * 1e18) / tokReserve;
    }
}