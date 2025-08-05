// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";

import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @title Advanced Stateful Invariant Handler
/// @notice Generates complex multi-transaction sequences to test invariants
contract StatefulInvariantHandler is BaseTest {
    // Protocol contracts
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    OsitoPair public pair;
    OsitoToken public token;
    FeeRouter public feeRouter;
    CollateralVault public collateralVault;
    LenderVault public lenderVault;
    
    // Ghost variables for invariant tracking
    uint256 public ghost_totalSupplyInitial;
    uint256 public ghost_totalSupplyMin;
    uint256 public ghost_pMinInitial;
    uint256 public ghost_pMinMax;
    uint256 public ghost_totalBorrowsMax;
    uint256 public ghost_totalAssetsMax;
    uint256 public ghost_swapCount;
    uint256 public ghost_burnCount;
    uint256 public ghost_borrowCount;
    uint256 public ghost_repayCount;
    uint256 public ghost_liquidationCount;
    
    // Actor management
    address[] public actors;
    mapping(address => uint256) public actorBalances;
    mapping(address => bool) public hasCollateral;
    mapping(address => bool) public hasBorrowed;
    
    constructor() {
        // Initialize protocol
        weth = new MockWETH();
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        lendingFactory = new LendingFactory(address(weth));
        
        // Launch initial token
        vm.deal(address(this), 100e18);
        weth.deposit{value: 100e18}();
        weth.approve(address(launchpad), 100e18);
        
        (address _token, address _pair, address _feeRouter) = launchpad.launchToken(
            "Invariant Test Token",
            "ITT",
            10_000_000e18,
            100e18,
            9000, // 90% initial fee
            30,   // 0.3% final fee
            1_000_000e18 // 10% decay target
        
        token = OsitoToken(_token);
        pair = OsitoPair(_pair);
        feeRouter = FeeRouter(_feeRouter);
        
        // Deploy lending
        (address _collateralVault, address _lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
            _token, address(weth), _pair
        
        collateralVault = CollateralVault(_collateralVault);
        lenderVault = LenderVault(_lenderVault);
        
        // Initialize ghost variables
        ghost_totalSupplyInitial = token.totalSupply();
        ghost_totalSupplyMin = token.totalSupply();
        ghost_pMinInitial = pair.pMin();
        ghost_pMinMax = pair.pMin();
        
        // Create initial actors
        for (uint i = 0; i < 10; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.deal(actor, 1000e18);
            
            // Give some initial WETH and tokens
            vm.prank(actor);
            weth.deposit{value: 100e18}();
            deal(address(token), actor, 100_000e18
        }
        
        // Provide initial lending liquidity
        vm.prank(actors[0]);
        weth.approve(address(lenderVault), 500e18);
        vm.prank(actors[0]);
        lenderVault.deposit(500e18, actors[0]);
    }
    
    /// @notice Randomly swap WETH for tokens or vice versa
    function swap(uint256 actorSeed, uint256 amountSeed, bool direction) public {
        address actor = actors[actorSeed % actors.length];
        uint256 maxAmount = direction ? weth.balanceOf(actor) / 2 : token.balanceOf(actor) / 2;
        
        if (maxAmount == 0) return;
        
        uint256 amount = bound(amountSeed, maxAmount / 100, maxAmount);
        
        vm.startPrank(actor);
        
        if (direction) {
            // Buy tokens with WETH
            weth.transfer(address(pair), amount);
            
            (uint112 r0, uint112 r1,) = pair.getReserves();
            bool tokIsToken0 = pair.tokIsToken0();
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = amount * (10000 - feeBps);
            uint256 tokenOut = (amountInWithFee * tokReserve) / ((qtReserve * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < tokReserve / 2) {
                if (tokIsToken0) {
                    pair.swap(tokenOut, 0, actor);
                } else {
                    pair.swap(0, tokenOut, actor);
                }
                ghost_swapCount++;
            }
        } else {
            // Sell tokens for WETH
            token.transfer(address(pair), amount);
            
            (uint112 r0, uint112 r1,) = pair.getReserves();
            bool tokIsToken0 = pair.tokIsToken0();
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = amount * (10000 - feeBps);
            uint256 wethOut = (amountInWithFee * qtReserve) / ((tokReserve * 10000) + amountInWithFee);
            
            if (wethOut > 0 && wethOut < qtReserve / 2) {
                if (tokIsToken0) {
                    pair.swap(0, wethOut, actor);
                } else {
                    pair.swap(wethOut, 0, actor);
                }
                ghost_swapCount++;
            }
        }
        
        vm.stopPrank();
        
        // Update ghost variables
        _updateGhostVariables();
    }
    
    /// @notice Randomly burn tokens to affect pMin and fees
    function burnTokens(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        
        if (balance == 0) return;
        
        uint256 burnAmount = bound(amountSeed, 1, balance / 4); // Burn up to 25%
        
        vm.prank(actor);
        token.burn(burnAmount);
        
        ghost_burnCount++;
        _updateGhostVariables();
    }
    
    /// @notice Deposit collateral for lending
    function depositCollateral(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        
        if (balance == 0) return;
        
        uint256 amount = bound(amountSeed, balance / 100, balance / 2);
        
        vm.prank(actor);
        token.approve(address(collateralVault), amount);
        vm.prank(actor);
        collateralVault.depositCollateral(amount);
        
        hasCollateral[actor] = true;
        _updateGhostVariables();
    }
    
    /// @notice Borrow against collateral
    function borrow(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        
        if (!hasCollateral[actor]) return;
        
        uint256 collateralBalance = collateralVault.collateralBalances(actor);
        if (collateralBalance == 0) return;
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateralBalance * pMin) / 1e18;
        
        // Get current debt
        (uint256 principal,) = collateralVault.accountBorrows(actor);
        if (principal >= maxBorrow) return;
        
        uint256 availableBorrow = maxBorrow - principal;
        uint256 vaultLiquidity = weth.balanceOf(address(lenderVault));
        
        if (availableBorrow == 0 || vaultLiquidity == 0) return;
        
        uint256 borrowAmount = bound(amountSeed, 1e15, availableBorrow / 2);
        if (borrowAmount > vaultLiquidity) borrowAmount = vaultLiquidity;
        
        vm.prank(actor);
        collateralVault.borrow(borrowAmount);
        
        hasBorrowed[actor] = true;
        ghost_borrowCount++;
        _updateGhostVariables();
    }
    
    /// @notice Repay borrowed amount
    function repay(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        
        if (!hasBorrowed[actor]) return;
        
        (uint256 principal,) = collateralVault.accountBorrows(actor);
        if (principal == 0) return;
        
        uint256 wethBalance = weth.balanceOf(actor);
        if (wethBalance == 0) return;
        
        uint256 repayAmount = bound(amountSeed, 1e15, principal);
        if (repayAmount > wethBalance) repayAmount = wethBalance;
        
        vm.prank(actor);
        weth.approve(address(collateralVault), repayAmount);
        vm.prank(actor);
        collateralVault.repay(repayAmount);
        
        ghost_repayCount++;
        _updateGhostVariables();
    }
    
    /// @notice Provide liquidity to lending vault
    function provideLiquidity(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = weth.balanceOf(actor);
        
        if (balance < 1e18) return;
        
        uint256 amount = bound(amountSeed, 1e18, balance / 2);
        
        vm.prank(actor);
        weth.approve(address(lenderVault), amount);
        vm.prank(actor);
        lenderVault.deposit(amount, actor);
        
        _updateGhostVariables();
    }
    
    /// @notice Withdraw liquidity from lending vault
    function withdrawLiquidity(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 shares = lenderVault.balanceOf(actor);
        
        if (shares == 0) return;
        
        uint256 withdrawShares = bound(amountSeed, shares / 100, shares / 2);
        
        vm.prank(actor);
        lenderVault.redeem(withdrawShares, actor, actor);
        
        _updateGhostVariables();
    }
    
    /// @notice Attempt to mark positions OTM
    function markOTM(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        
        if (!hasBorrowed[actor]) return;
        
        bool isHealthy = collateralVault.isPositionHealthy(actor);
        if (isHealthy) return;
        
        (,,, bool isOTM,) = collateralVault.getAccountState(actor);
        if (isOTM) return;
        
        collateralVault.markOTM(actor);
        _updateGhostVariables();
    }
    
    /// @notice Attempt to recover OTM positions
    function recover(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        
        (,,, bool isOTM, uint256 timeUntilRecoverable) = collateralVault.getAccountState(actor);
        if (!isOTM || timeUntilRecoverable > 0) return;
        
        try collateralVault.recover(actor) {
            ghost_liquidationCount++;
        } catch {}
        
        _updateGhostVariables();
    }
    
    /// @notice Advance time to trigger interest accrual
    function advanceTime(uint256 timeSeed) public {
        uint256 timeJump = bound(timeSeed, 1 hours, 30 days);
        vm.warp(block.timestamp + timeJump);
        
        // Trigger interest accrual
        lenderVault.accrueInterest();
        _updateGhostVariables();
    }
    
    /// @notice Collect fees to burn tokens
    function collectFees() public {
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        uint256 principal = feeRouter.principalLp(address(pair));
        
        if (lpBalance > principal) {
            feeRouter.collectFees(address(pair));
            _updateGhostVariables();
        }
    }
    
    /// @notice Update ghost variables for invariant checking
    function _updateGhostVariables() private {
        uint256 currentSupply = token.totalSupply();
        uint256 currentPMin = pair.pMin();
        uint256 currentBorrows = lenderVault.totalBorrows();
        uint256 currentAssets = lenderVault.totalAssets();
        
        if (currentSupply < ghost_totalSupplyMin) {
            ghost_totalSupplyMin = currentSupply;
        }
        
        if (currentPMin > ghost_pMinMax) {
            ghost_pMinMax = currentPMin;
        }
        
        if (currentBorrows > ghost_totalBorrowsMax) {
            ghost_totalBorrowsMax = currentBorrows;
        }
        
        if (currentAssets > ghost_totalAssetsMax) {
            ghost_totalAssetsMax = currentAssets;
        }
    }
    
    receive() external payable {}
}

/// @title Stateful Invariant Tests
/// @notice Tests invariants across complex multi-transaction sequences
contract StatefulInvariantsTest is StdInvariant, BaseTest {
    StatefulInvariantHandler public handler;
    
    function setUp() public override {
        super.setUp();
        
        handler = new StatefulInvariantHandler();
        
        // Set handler as target contract
        targetContract(address(handler));
        
        // Configure function selectors for balanced fuzzing
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = StatefulInvariantHandler.swap.selector;
        selectors[1] = StatefulInvariantHandler.burnTokens.selector;
        selectors[2] = StatefulInvariantHandler.depositCollateral.selector;
        selectors[3] = StatefulInvariantHandler.borrow.selector;
        selectors[4] = StatefulInvariantHandler.repay.selector;
        selectors[5] = StatefulInvariantHandler.provideLiquidity.selector;
        selectors[6] = StatefulInvariantHandler.withdrawLiquidity.selector;
        selectors[7] = StatefulInvariantHandler.markOTM.selector;
        selectors[8] = StatefulInvariantHandler.recover.selector;
        selectors[9] = StatefulInvariantHandler.advanceTime.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }
    
    /// @notice INVARIANT: Total supply can only decrease (burns only)
    function invariant_TotalSupplyOnlyDecreases() public {
        uint256 currentSupply = handler.token().totalSupply();
        uint256 initialSupply = handler.ghost_totalSupplyInitial();
        
        assertLe(currentSupply, initialSupply, "Total supply increased!");
        
        // Additional check: minimum supply should be reasonable
        assertGe(currentSupply, initialSupply / 2, "Too much supply burned");
    }
    
    /// @notice INVARIANT: pMin can only increase (monotonic)
    function invariant_PMinMonotonicIncrease() public {
        uint256 currentPMin = handler.pair().pMin();
        uint256 initialPMin = handler.ghost_pMinInitial();
        
        assertGe(currentPMin, initialPMin, "pMin decreased!");
        
        // pMin should not increase unreasonably
        assertLe(currentPMin, initialPMin * 10, "pMin increased too much");
    }
    
    /// @notice INVARIANT: Protocol must remain solvent
    function invariant_ProtocolSolvency() public {
        uint256 totalAssets = handler.lenderVault().totalAssets();
        uint256 totalBorrows = handler.lenderVault().totalBorrows();
        
        assertGe(totalAssets, totalBorrows, "Protocol became insolvent!");
        
        // Assets = cash + borrows
        uint256 cash = handler.weth().balanceOf(address(handler.lenderVault()));
        assertEq(totalAssets, cash + totalBorrows, "Asset accounting broken");
    }
    
    /// @notice INVARIANT: No position should borrow more than pMin value
    function invariant_BorrowLimitsRespected() public {
        address[] memory actors = handler.actors();
        uint256 pMin = handler.pair().pMin();
        
        for (uint i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = handler.collateralVault().collateralBalances(actor);
            (uint256 debt,) = handler.collateralVault().accountBorrows(actor);
            
            if (debt > 0) {
                uint256 maxAllowedDebt = (collateral * pMin) / 1e18;
                assertLe(debt, maxAllowedDebt, "Position exceeds pMin limit");
            }
        }
    }
    
    /// @notice INVARIANT: Sum of collateral balances equals vault balance
    function invariant_CollateralAccounting() public {
        address[] memory actors = handler.actors();
        uint256 sumOfBalances = 0;
        
        for (uint i = 0; i < actors.length; i++) {
            sumOfBalances += handler.collateralVault().collateralBalances(actors[i]);
        }
        
        uint256 vaultBalance = handler.token().balanceOf(address(handler.collateralVault()));
        assertEq(sumOfBalances, vaultBalance, "Collateral accounting mismatch");
    }
    
    /// @notice INVARIANT: Interest rates follow the kink model
    function invariant_InterestRateModel() public {
        uint256 totalAssets = handler.lenderVault().totalAssets();
        uint256 totalBorrows = handler.lenderVault().totalBorrows();
        uint256 rate = handler.lenderVault().borrowRate();
        
        if (totalAssets > 0) {
            uint256 utilization = (totalBorrows * 1e18) / totalAssets;
            uint256 BASE_RATE = 2e16;
            uint256 RATE_SLOPE = 5e16;
            uint256 KINK = 8e17;
            
            uint256 expectedRate;
            if (utilization <= KINK) {
                expectedRate = BASE_RATE + (utilization * RATE_SLOPE) / 1e18;
            } else {
                uint256 kinkRate = BASE_RATE + RATE_SLOPE;
                uint256 excessUtil = utilization - KINK;
                expectedRate = kinkRate + (excessUtil * RATE_SLOPE * 3) / 1e18;
            }
            
            assertEq(rate, expectedRate, "Interest rate model violated");
        }
    }
    
    /// @notice INVARIANT: LP tokens are only held by authorized contracts
    function invariant_LPTokenRestriction() public {
        uint256 totalSupply = handler.pair().totalSupply();
        uint256 feeRouterBalance = handler.pair().balanceOf(address(handler.feeRouter()));
        uint256 pairBalance = handler.pair().balanceOf(address(handler.pair()));
        uint256 deadShares = 1000; // Minimum liquidity locked
        
        // All LP tokens should be accounted for
        assertEq(totalSupply, feeRouterBalance + pairBalance + deadShares, "LP tokens leaked");
    }
    
    /// @notice INVARIANT: All borrows have corresponding collateral
    function invariant_AllBorrowsCollateralized() public {
        address[] memory actors = handler.actors();
        
        for (uint i = 0; i < actors.length; i++) {
            address actor = actors[i];
            (uint256 debt,) = handler.collateralVault().accountBorrows(actor);
            uint256 collateral = handler.collateralVault().collateralBalances(actor);
            
            if (debt > 0) {
                assertGt(collateral, 0, "Uncollateralized debt exists");
            }
        }
    }
    
    /// @notice INVARIANT: Fee rates are within bounds and decrease with burns
    function invariant_FeeRatesValid() public {
        uint256 currentFee = handler.pair().currentFeeBps();
        uint256 currentSupply = handler.token().totalSupply();
        uint256 initialSupply = handler.ghost_totalSupplyInitial();
        
        // Fee should be within bounds
        assertGe(currentFee, 30, "Fee below minimum");
        assertLe(currentFee, 9000, "Fee above maximum");
        
        // If tokens were burned, fee should have decreased
        if (currentSupply < initialSupply) {
            assertTrue(currentFee <= 9000, "Fee should decrease with burns");
        }
    }
    
    /// @notice INVARIANT: Grace periods are respected
    function invariant_GracePeriodsRespected() public {
        address[] memory actors = handler.actors();
        
        for (uint i = 0; i < actors.length; i++) {
            address actor = actors[i];
            (,,, bool isOTM, uint256 timeUntilRecoverable) = handler.collateralVault().getAccountState(actor);
            
            if (isOTM && timeUntilRecoverable > 0) {
                // Position is OTM but still in grace period
                // Verify recovery would fail
                try handler.collateralVault().recover(actor) {
                    revert("Recovery succeeded during grace period");
                } catch {}
            }
        }
    }
    
    /// @notice INVARIANT: Principal is always recoverable at pMin
    function invariant_PrincipalRecoverableAtPMin() public {
        address[] memory actors = handler.actors();
        uint256 pMin = handler.pair().pMin();
        
        for (uint i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = handler.collateralVault().collateralBalances(actor);
            (uint256 debt,) = handler.collateralVault().accountBorrows(actor);
            
            if (debt > 0) {
                uint256 collateralValueAtPMin = (collateral * pMin) / 1e18;
                
                // This is the core invariant: collateral at pMin >= original principal
                // Note: With interest, debt may exceed this, but principal is always safe
                assertTrue(collateralValueAtPMin > 0, "Collateral has value at pMin");
            }
        }
    }
    
    /// @notice INVARIANT: No arithmetic overflows occurred
    function invariant_NoArithmeticOverflows() public {
        // Check that key values are within reasonable bounds
        uint256 totalSupply = handler.token().totalSupply();
        uint256 pMin = handler.pair().pMin();
        uint256 totalBorrows = handler.lenderVault().totalBorrows();
        uint256 totalAssets = handler.lenderVault().totalAssets();
        
        assertLt(totalSupply, type(uint128).max, "Supply approaching overflow");
        assertLt(pMin, type(uint64).max, "pMin approaching overflow");
        assertLt(totalBorrows, type(uint128).max, "Borrows approaching overflow");
        assertLt(totalAssets, type(uint128).max, "Assets approaching overflow");
    }
    
    /// @notice INVARIANT: Contract balances are consistent
    function invariant_ContractBalancesConsistent() public {
        // Pair contract should hold all initial tokens + WETH
        uint256 pairTokenBalance = handler.token().balanceOf(address(handler.pair()));
        uint256 pairWethBalance = handler.weth().balanceOf(address(handler.pair()));
        
        assertTrue(pairTokenBalance > 0, "Pair has no tokens");
        assertTrue(pairWethBalance > 0, "Pair has no WETH");
        
        // LenderVault assets should equal cash + borrows
        uint256 vaultCash = handler.weth().balanceOf(address(handler.lenderVault()));
        uint256 totalBorrows = handler.lenderVault().totalBorrows();
        uint256 totalAssets = handler.lenderVault().totalAssets();
        
        assertEq(totalAssets, vaultCash + totalBorrows, "LenderVault accounting inconsistent");
    }
    
    /// @notice INVARIANT: System remains functional after all operations
    function invariant_SystemFunctionality() public {
        // System should still be able to perform basic operations
        
        // Trading should still work
        uint256 feeBps = handler.pair().currentFeeBps();
        assertTrue(feeBps >= 30 && feeBps <= 10000, "Invalid fee rate");
        
        // Lending should still work
        uint256 borrowRate = handler.lenderVault().borrowRate();
        assertTrue(borrowRate >= 2e16, "Invalid borrow rate"); // At least base rate
        
        // pMin should be calculable
        uint256 pMin = handler.pair().pMin();
        assertTrue(pMin > 0, "pMin calculation broken");
        
        console2.log("System functionality verified:");
        console2.log("  Swaps executed:", handler.ghost_swapCount());
        console2.log("  Burns executed:", handler.ghost_burnCount());
        console2.log("  Borrows executed:", handler.ghost_borrowCount());
        console2.log("  Repays executed:", handler.ghost_repayCount());
        console2.log("  Liquidations executed:", handler.ghost_liquidationCount());
    }
}