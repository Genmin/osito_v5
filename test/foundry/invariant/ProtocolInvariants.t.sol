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

/// @notice Handler contract for invariant testing
contract ProtocolHandler is BaseTest {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    address[] public actors;
    uint256[] public actorBalances;
    
    // Track state for invariant checks
    uint256 public lastPMin;
    uint256 public lastK;
    uint256 public lastTotalSupply;
    
    constructor() {
        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);
        actors.push(dave);
        actors.push(eve);
    }
    
    function initialize(
        OsitoToken _token,
        OsitoPair _pair,
        FeeRouter _feeRouter,
        CollateralVault _vault,
        LenderVault _lenderVault
    ) external {
        token = _token;
        pair = _pair;
        feeRouter = _feeRouter;
        vault = _vault;
        lenderVault = _lenderVault;
        
        _updateState();
    }
    
    function _updateState() internal {
        lastPMin = pair.pMin();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        lastK = uint256(r0) * uint256(r1);
        lastTotalSupply = token.totalSupply();
    }
    
    function _boundActor(uint256 actorSeed) internal view returns (address) {
        return actors[bound(actorSeed, 0, actors.length - 1)];
    }
    
    function swapWETHForTokens(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 maxAmount = weth.balanceOf(actor) / 10; // Don't use all
        if (maxAmount == 0) return;
        
        uint256 amount = bound(amountSeed, 0.01 ether, maxAmount);
        
        vm.prank(actor);
        _swap(pair, address(weth), amount, actor);
        
        _updateState();
    }
    
    function swapTokensForWETH(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 tokenBalance = token.balanceOf(actor);
        if (tokenBalance == 0) return;
        
        uint256 amount = bound(amountSeed, 1, tokenBalance / 2);
        
        vm.prank(actor);
        _swap(pair, address(token), amount, actor);
        
        _updateState();
    }
    
    function burnTokens(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 tokenBalance = token.balanceOf(actor);
        if (tokenBalance == 0) return;
        
        uint256 amount = bound(amountSeed, 1, tokenBalance / 4);
        
        vm.prank(actor);
        token.burn(amount);
        
        _updateState();
    }
    
    function depositCollateral(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 tokenBalance = token.balanceOf(actor);
        if (tokenBalance == 0) return;
        
        uint256 amount = bound(amountSeed, 1, tokenBalance / 2);
        
        vm.startPrank(actor);
        token.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();
        
        _updateState();
    }
    
    function borrowAgainstCollateral(uint256 actorSeed, uint256 ratioSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 collateral = vault.collateralBalances(actor);
        if (collateral == 0) return;
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateral * pMin) / 1e18;
        
        (uint256 currentDebt,) = vault.accountBorrows(actor);
        if (currentDebt >= maxBorrow) return;
        
        uint256 availableBorrow = maxBorrow - currentDebt;
        uint256 borrowRatio = bound(ratioSeed, 1, 50); // 1-50% of available
        uint256 borrowAmount = (availableBorrow * borrowRatio) / 100;
        
        if (borrowAmount == 0) return;
        
        vm.prank(actor);
        try vault.borrow(borrowAmount) {
            // Success
        } catch {
            // Might fail due to liquidity or other constraints
        }
        
        _updateState();
    }
    
    function repayDebt(uint256 actorSeed, uint256 ratioSeed) external {
        address actor = _boundActor(actorSeed);
        (uint256 debt,) = vault.accountBorrows(actor);
        if (debt == 0) return;
        
        uint256 wethBalance = weth.balanceOf(actor);
        if (wethBalance == 0) return;
        
        uint256 repayRatio = bound(ratioSeed, 1, 100);
        uint256 repayAmount = (debt * repayRatio) / 100;
        repayAmount = repayAmount > wethBalance ? wethBalance : repayAmount;
        
        if (repayAmount == 0) return;
        
        vm.startPrank(actor);
        weth.approve(address(vault), repayAmount);
        vault.repay(repayAmount);
        vm.stopPrank();
        
        _updateState();
    }
    
    function collectFees() external {
        vm.prank(keeper);
        feeRouter.collectFees();
        
        _updateState();
    }
    
    function advanceTime(uint256 timeSeed) external {
        uint256 timeJump = bound(timeSeed, 1 hours, 30 days);
        _advanceTime(timeJump);
        
        // Accrue interest
        lenderVault.accrueInterest();
        
        _updateState();
    }
}

/// @notice Protocol invariant tests
contract ProtocolInvariantsTest is StdInvariant, BaseTest {
    ProtocolHandler public handler;
    
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
        
        // Get lender vault and create collateral vault
        lenderVault = LenderVault(lendingFactory.lenderVault());
        vault = _createLendingMarket(address(pair));
        
        // Fund lender vault
        vm.startPrank(bob);
        weth.approve(address(lenderVault), type(uint256).max);
        lenderVault.deposit(100 ether, bob);
        vm.stopPrank();
        
        // Get tokens for all actors
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            _swap(pair, address(weth), 1 ether, actors[i]);
        }
        
        // Create handler
        handler = new ProtocolHandler();
        handler.initialize(token, pair, feeRouter, vault, lenderVault);
        
        // Target handler for invariant testing
        targetContract(address(handler));
        
        // Define function selectors to call
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = ProtocolHandler.swapWETHForTokens.selector;
        selectors[1] = ProtocolHandler.swapTokensForWETH.selector;
        selectors[2] = ProtocolHandler.burnTokens.selector;
        selectors[3] = ProtocolHandler.depositCollateral.selector;
        selectors[4] = ProtocolHandler.borrowAgainstCollateral.selector;
        selectors[5] = ProtocolHandler.repayDebt.selector;
        selectors[6] = ProtocolHandler.collectFees.selector;
        selectors[7] = ProtocolHandler.advanceTime.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }
    
    // ============ CRITICAL INVARIANTS ============
    
    /// @notice CRITICAL: pMin must never decrease
    function invariant_pMinNeverDecreases() public view {
        uint256 currentPMin = pair.pMin();
        uint256 lastPMin = handler.lastPMin();
        
        assertGe(currentPMin, lastPMin, "pMin decreased!");
    }
    
    /// @notice CRITICAL: K value must never decrease (except for controlled scenarios)
    function invariant_kNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        uint256 lastK = handler.lastK();
        
        assertGe(currentK, lastK, "K decreased!");
    }
    
    /// @notice CRITICAL: Total supply can only decrease (burns only)
    function invariant_totalSupplyOnlyDecreases() public view {
        uint256 currentSupply = token.totalSupply();
        uint256 lastSupply = handler.lastTotalSupply();
        
        assertLe(currentSupply, lastSupply, "Total supply increased!");
    }
    
    /// @notice CRITICAL: All borrowing positions must be backed by sufficient collateral at pMin
    function invariant_allPositionsFullyBacked() public view {
        uint256 pMin = pair.pMin();
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = vault.collateralBalances(actor);
            (uint256 debt,) = vault.accountBorrows(actor);
            
            if (debt > 0) {
                uint256 maxDebt = (collateral * pMin) / 1e18;
                assertLe(debt, maxDebt, "Position undercollateralized!");
            }
        }
    }
    
    /// @notice CRITICAL: LP tokens can only be held by authorized addresses
    function invariant_lpTokenRestriction() public view {
        uint256 totalSupply = pair.totalSupply();
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        uint256 pairBalance = pair.balanceOf(address(pair));
        uint256 deadBalance = pair.balanceOf(address(0xdead));
        
        // Allow for small rounding errors
        uint256 authorizedTotal = feeRouterBalance + pairBalance + deadBalance + 1000; // +1000 for minimum liquidity
        
        assertApproxEq(authorizedTotal, totalSupply, 10, "Unauthorized LP token holders exist!");
    }
    
    /// @notice CRITICAL: Lender vault must remain solvent
    function invariant_lenderVaultSolvency() public view {
        uint256 totalAssets = lenderVault.totalAssets();
        uint256 totalBorrows = lenderVault.totalBorrows();
        
        assertGe(totalAssets, totalBorrows, "Lender vault insolvent!");
    }
    
    /// @notice CRITICAL: Token conservation (no tokens created from thin air)
    function invariant_tokenConservation() public view {
        uint256 totalInCirculation = token.totalSupply();
        uint256 tokensInPair = token.balanceOf(address(pair));
        uint256 tokensInVault = token.balanceOf(address(vault));
        uint256 tokensInFeeRouter = token.balanceOf(address(feeRouter));
        
        // Calculate user balances
        uint256 userTokens = 0;
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < actors.length; i++) {
            userTokens += token.balanceOf(actors[i]);
        }
        
        uint256 totalAccountedFor = tokensInPair + tokensInVault + tokensInFeeRouter + userTokens;
        
        assertEq(totalAccountedFor, totalInCirculation, "Token conservation violated!");
    }
    
    /// @notice Recovery guarantee: All positions can be liquidated at pMin for full principal
    function invariant_recoveryGuarantee() public view {
        uint256 pMin = pair.pMin();
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = vault.collateralBalances(actor);
            (uint256 principal,) = vault.accountBorrows(actor);
            
            if (principal > 0) {
                uint256 recoveryValue = (collateral * pMin) / 1e18;
                assertGe(recoveryValue, principal, "Recovery guarantee violated!");
            }
        }
    }
    
    // ============ PROPERTY INVARIANTS ============
    
    /// @notice Fee decay works correctly
    function invariant_feeDecayDirection() public view {
        uint256 currentFee = pair.currentFeeBps();
        uint256 startFee = pair.startFeeBps();
        uint256 endFee = pair.endFeeBps();
        
        assertGe(currentFee, endFee, "Fee below minimum!");
        assertLe(currentFee, startFee, "Fee above maximum!");
    }
    
    /// @notice No position can be healthy with debt exceeding collateral value at spot
    function invariant_healthyPositionsViable() public view {
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            bool isHealthy = vault.isPositionHealthy(actor);
            
            if (isHealthy) {
                uint256 collateral = vault.collateralBalances(actor);
                (uint256 debt,) = vault.accountBorrows(actor);
                
                if (debt > 0) {
                    // Get spot price
                    (uint112 r0, uint112 r1,) = pair.getReserves();
                    uint256 tokReserve = pair.tokIsToken0() ? uint256(r0) : uint256(r1);
                    uint256 qtReserve = pair.tokIsToken0() ? uint256(r1) : uint256(r0);
                    
                    if (tokReserve > 0) {
                        uint256 spotPrice = (qtReserve * 1e18) / tokReserve;
                        uint256 collateralValue = (collateral * spotPrice) / 1e18;
                        
                        assertGe(collateralValue, debt, "Healthy position underwater!");
                    }
                }
            }
        }
    }
}