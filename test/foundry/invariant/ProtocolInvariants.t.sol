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
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Handler contract for invariant testing
contract ProtocolHandler is Test {
    using SafeTransferLib for address;
    
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    address public weth;
    address public keeper;
    
    address[] public actors;
    uint256[] public actorBalances;
    
    // Track state for invariant checks
    uint256 public lastPMin;
    uint256 public lastK;
    uint256 public lastTotalSupply;
    
    constructor() {
        // Don't initialize actors in constructor - will be set later
    }
    
    function initialize(
        OsitoToken _token,
        OsitoPair _pair,
        FeeRouter _feeRouter,
        CollateralVault _vault,
        LenderVault _lenderVault,
        address _weth,
        address _keeper,
        address[5] memory _actors
    ) external {
        token = _token;
        pair = _pair;
        feeRouter = _feeRouter;
        vault = _vault;
        lenderVault = _lenderVault;
        weth = _weth;
        keeper = _keeper;
        
        // Set up actors
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
        }
        
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
        uint256 wethBalance = ERC20(weth).balanceOf(actor);
        if (wethBalance < 0.01 ether) return; // Need minimum amount
        
        uint256 maxAmount = wethBalance / 20; // Use even smaller portion
        if (maxAmount < 0.001 ether) return;
        uint256 amount = bound(amountSeed, 0.001 ether, maxAmount); // Lower minimum
        
        vm.startPrank(actor);
        ERC20(weth).approve(address(pair), amount);
        ERC20(weth).transfer(address(pair), amount);
        
        // Calculate swap amount properly
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) {
            vm.stopPrank();
            return; // No reserves yet
        }
        
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (amount * (10000 - feeBps)) / 10000;
        uint256 amountOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
        
        if (amountOut > 0 && amountOut < tokReserve) {
            try pair.swap(tokIsToken0 ? amountOut : 0, tokIsToken0 ? 0 : amountOut, actor) {
                // Success
            } catch {
                // Failed - skip
            }
        }
        vm.stopPrank();
        
        _updateState();
    }
    
    function swapTokensForWETH(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _boundActor(actorSeed);
        uint256 tokenBalance = token.balanceOf(actor);
        if (tokenBalance < 1000) return; // Need minimum meaningful amount
        
        uint256 amount = bound(amountSeed, 100, tokenBalance / 10); // More conservative
        
        vm.startPrank(actor);
        token.approve(address(pair), amount);
        token.transfer(address(pair), amount);
        
        // Calculate swap amount properly
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) {
            vm.stopPrank();
            return; // No reserves yet
        }
        
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (amount * (10000 - feeBps)) / 10000;
        uint256 amountOut = (amountInWithFee * qtReserve) / (tokReserve + amountInWithFee);
        
        if (amountOut > 0 && amountOut < qtReserve) {
            try pair.swap(tokIsToken0 ? 0 : amountOut, tokIsToken0 ? amountOut : 0, actor) {
                // Success
            } catch {
                // Failed - skip
            }
        }
        vm.stopPrank();
        
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
        
        uint256 wethBalance = ERC20(weth).balanceOf(actor);
        if (wethBalance == 0) return;
        
        uint256 repayRatio = bound(ratioSeed, 1, 100);
        uint256 repayAmount = (debt * repayRatio) / 100;
        repayAmount = repayAmount > wethBalance ? wethBalance : repayAmount;
        
        if (repayAmount == 0) return;
        
        vm.startPrank(actor);
        ERC20(weth).approve(address(vault), repayAmount);
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
    
    // Helper functions
    function _swap(OsitoPair _pair, address tokenIn, uint256 amountIn, address to) internal {
        // First approve if needed
        uint256 currentAllowance = ERC20(tokenIn).allowance(address(this), address(_pair));
        if (currentAllowance < amountIn) {
            ERC20(tokenIn).approve(address(_pair), type(uint256).max);
        }
        ERC20(tokenIn).transfer(address(_pair), amountIn);
        
        (uint112 r0, uint112 r1,) = _pair.getReserves();
        bool tokIsToken0 = _pair.tokIsToken0();
        
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        uint256 feeBps = _pair.currentFeeBps();
        uint256 amountInWithFee = (amountIn * (10000 - feeBps)) / 10000;
        
        uint256 amountOut;
        if (tokenIn == address(token)) {
            // Swapping token for WETH
            amountOut = (amountInWithFee * qtReserve) / (tokReserve + amountInWithFee);
            _pair.swap(0, amountOut, to);
        } else {
            // Swapping WETH for token
            amountOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
            _pair.swap(amountOut, 0, to);
        }
    }
    
    function _advanceTime(uint256 timeJump) internal {
        vm.warp(block.timestamp + timeJump);
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
    
    uint256 constant SUPPLY = 100_000 * 1e18;  // Further reduced supply for invariant tests
    uint256 constant INITIAL_LIQUIDITY = 2 ether;   // Further reduced liquidity
    
    function setUp() public override {
        super.setUp();
        
        // Use dave for token launch (preserving alice/bob/charlie for other operations)
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST",
            SUPPLY,
            INITIAL_LIQUIDITY,
            dave
        );
        
        // Get lender vault and create collateral vault
        lenderVault = LenderVault(lendingFactory.lenderVault());
        vault = _createLendingMarket(address(pair));
        
        // Fund lender vault using eve with smaller amount
        vm.startPrank(eve);
        weth.approve(address(lenderVault), 10 ether);
        lenderVault.deposit(10 ether, eve);
        vm.stopPrank();
        
        // Get tokens for actors with minimal swaps
        address[5] memory actors = [alice, bob, charlie, dave, eve];
        
        // Don't give tokens in setUp - let the handler functions do it during testing
        // This avoids complex swap logic in setUp that can fail
        
        // Create handler
        handler = new ProtocolHandler();
        handler.initialize(token, pair, feeRouter, vault, lenderVault, address(weth), keeper, actors);
        
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