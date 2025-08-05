// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract FullProtocolFlowTest is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    MockWETH public weth;
    
    // Protocol contracts
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public collateralVault;
    LenderVault public lenderVault;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy infrastructure
        weth = new MockWETH();
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        lendingFactory = new LendingFactory(address(weth));
    }
    
    function test_FullProtocolLifecycle() public {
        // Phase 1: Token Launch
        console2.log("=== Phase 1: Token Launch ===");
        
        uint256 initialWeth = 100e18;
        uint256 tokenSupply = 1_000_000e18;
        
        vm.deal(alice, initialWeth);
        vm.prank(alice);
        weth.deposit{value: initialWeth}();
        vm.prank(alice);
        weth.approve(address(launchpad), initialWeth);
        
        vm.prank(alice);
        (address _token, address _pair, address _feeRouter) = launchpad.launchToken(
            "Osito Protocol Token",
            "OSITO",
            tokenSupply,
            initialWeth,
            9900, // 99% start fee
            30,   // 0.3% end fee
            100_000e18 // fee decay target
        
        token = OsitoToken(_token);
        pair = OsitoPair(_pair);
        feeRouter = FeeRouter(_feeRouter);
        
        console2.log("Token launched at:", address(token));
        console2.log("Initial pMin:", pair.pMin());
        console2.log("Initial fee:", pair.currentFeeBps());
        
        // Verify initial state
        assertEq(token.totalSupply(), tokenSupply);
        assertEq(token.balanceOf(address(pair)), tokenSupply);
        assertTrue(pair.pMin() > 0);
        
        // Phase 2: Early Trading (High Fees)
        console2.log("\n=== Phase 2: Early Trading ===");
        
        // Bob buys tokens
        uint256 bobBuyAmount = 10e18;
        vm.deal(bob, bobBuyAmount);
        vm.prank(bob);
        weth.deposit{value: bobBuyAmount}();
        vm.prank(bob);
        weth.transfer(address(pair), bobBuyAmount);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 expectedOut = calculateSwapOut(bobBuyAmount, r1, r0, pair.currentFeeBps());
        
        vm.prank(bob);
        pair.swap(expectedOut, 0, bob);
        
        console2.log("Bob bought tokens:", token.balanceOf(bob));
        console2.log("Fee paid (bps):", pair.currentFeeBps());
        
        // Phase 3: Deploy Lending
        console2.log("\n=== Phase 3: Deploy Lending ===");
        
        (address _collateralVault, address _lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
            address(token),
            address(weth),
            address(pair)
        
        collateralVault = CollateralVault(_collateralVault);
        lenderVault = LenderVault(_lenderVault);
        
        // Charlie provides lending liquidity
        uint256 lendingLiquidity = 500e18;
        vm.deal(charlie, lendingLiquidity);
        vm.prank(charlie);
        weth.deposit{value: lendingLiquidity}();
        vm.prank(charlie);
        weth.approve(address(lenderVault), lendingLiquidity);
        vm.prank(charlie);
        uint256 shares = lenderVault.deposit(lendingLiquidity, charlie);
        
        console2.log("Lending liquidity provided:", lendingLiquidity);
        console2.log("LP shares received:", shares);
        
        // Phase 4: Borrowing
        console2.log("\n=== Phase 4: Borrowing ===");
        
        uint256 bobTokens = token.balanceOf(bob);
        vm.prank(bob);
        token.approve(address(collateralVault), bobTokens);
        vm.prank(bob);
        collateralVault.depositCollateral(bobTokens);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (bobTokens * pMin) / 1e18; // Full pMin value
        
        // Borrow 50% of max to leave room for interest
        uint256 borrowAmount = maxBorrow / 2;
        vm.prank(bob);
        collateralVault.borrow(borrowAmount);
        
        console2.log("Collateral deposited:", bobTokens);
        console2.log("Amount borrowed:", borrowAmount);
        console2.log("Borrow rate:", lenderVault.borrowRate());
        
        // Phase 5: More Trading & Burns
        console2.log("\n=== Phase 5: Trading & Burns ===");
        
        // More users trade
        for (uint i = 0; i < 5; i++) {
            address trader = makeAddr(string.concat("trader", vm.toString(i)));
            uint256 tradeAmount = 5e18 + i * 1e18;
            
            vm.deal(trader, tradeAmount);
            vm.prank(trader);
            weth.deposit{value: tradeAmount}();
            vm.prank(trader);
            weth.transfer(address(pair), tradeAmount);
            
            (r0, r1,) = pair.getReserves();
            uint256 out = calculateSwapOut(tradeAmount, r1, r0, pair.currentFeeBps());
            
            vm.prank(trader);
            pair.swap(out, 0, trader);
            
            // Some traders burn tokens
            if (i % 2 == 0) {
                uint256 burnAmount = out / 10; // Burn 10%
                vm.prank(trader);
                token.burn(burnAmount);
            }
        }
        
        uint256 supplyAfterBurns = token.totalSupply();
        console2.log("Supply after burns:", supplyAfterBurns);
        console2.log("Tokens burned:", tokenSupply - supplyAfterBurns);
        
        // Phase 6: Fee Collection
        console2.log("\n=== Phase 6: Fee Collection ===");
        
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        uint256 principal = feeRouter.principalLp(address(pair));
        
        console2.log("LP balance:", lpBalance);
        console2.log("Principal LP:", principal);
        console2.log("Fees accumulated:", lpBalance - principal);
        
        if (lpBalance > principal) {
            uint256 supplyBefore = token.totalSupply();
            uint256 pMinBefore = pair.pMin();
            
            feeRouter.collectFees(address(pair));
            
            uint256 supplyAfter = token.totalSupply();
            uint256 pMinAfter = pair.pMin();
            
            console2.log("Tokens burned from fees:", supplyBefore - supplyAfter);
            console2.log("pMin increase:", pMinAfter - pMinBefore);
            
            assertTrue(supplyAfter < supplyBefore, "Supply should decrease");
            assertTrue(pMinAfter > pMinBefore, "pMin should increase");
        }
        
        // Phase 7: Interest Accrual
        console2.log("\n=== Phase 7: Interest Accrual ===");
        
        advanceTime(30 days);
        
        (uint256 collateral, uint256 debtBefore, bool isHealthy, bool isOTM,) = collateralVault.getAccountState(bob);
        
        // Trigger interest accrual
        lenderVault.accrueInterest();
        
        (, uint256 debtAfter,,,) = collateralVault.getAccountState(bob);
        
        console2.log("Debt after 30 days:", debtAfter);
        console2.log("Interest accrued:", debtAfter - debtBefore);
        
        // Phase 8: Partial Repayment
        console2.log("\n=== Phase 8: Partial Repayment ===");
        
        uint256 repayAmount = debtAfter / 2;
        vm.prank(bob);
        weth.approve(address(collateralVault), repayAmount);
        vm.prank(bob);
        collateralVault.repay(repayAmount);
        
        (, uint256 debtFinal,,,) = collateralVault.getAccountState(bob);
        console2.log("Remaining debt:", debtFinal);
        
        // Final State
        console2.log("\n=== Final Protocol State ===");
        console2.log("Total supply:", token.totalSupply());
        console2.log("Final pMin:", pair.pMin());
        console2.log("Current fee:", pair.currentFeeBps());
        console2.log("Total borrows:", lenderVault.totalBorrows());
        console2.log("Lender APY:", calculateAPY(lenderVault.borrowRate()));
        
        // Verify key invariants
        assertTrue(pair.pMin() > 0, "pMin must be positive");
        assertTrue(token.totalSupply() < tokenSupply, "Supply must have decreased");
        assertTrue(lenderVault.totalBorrows() <= lenderVault.totalAssets(), "Protocol must be solvent");
    }
    
    function calculateSwapOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        return (amountInWithFee * reserveOut) / ((reserveIn * 10000) + amountInWithFee);
    }
    
    function calculateAPY(uint256 rate) internal pure returns (uint256) {
        // Simple APY calculation (not compounded)
        return rate;
    }
}