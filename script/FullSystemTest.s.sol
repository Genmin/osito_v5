// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {OsitoLaunchpad} from "../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../src/factories/LendingFactory.sol";
import {OsitoPair} from "../src/core/OsitoPair.sol";
import {FeeRouter} from "../src/core/FeeRouter.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {CollateralVault} from "../src/core/CollateralVault.sol";
import {LenderVault} from "../src/core/LenderVault.sol";

interface IWBERA {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function withdraw(uint256) external;
}

contract FullSystemTest is Script {
    address constant WBERA = 0x6969696969696969696969696969696969696969;
    uint256 constant ONE_BILLION = 1_000_000_000 * 1e18;
    uint256 constant ONE_BERA = 1e18;
    
    function run() external {
        // Get deployment addresses
        address launchpad = vm.envAddress("OSITO_LAUNCHPAD");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address lendingFactory = vm.envAddress("LENDING_FACTORY");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("\n=== FULL SYSTEM TEST ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        
        // 1. LAUNCH TOKEN
        console.log("\n1. LAUNCHING TOKEN...");
        IWBERA(WBERA).deposit{value: 10 * ONE_BERA}();
        IWBERA(WBERA).approve(launchpad, 2 * ONE_BERA);
        
        (address tok, address pair, address feeRouter) = OsitoLaunchpad(launchpad).launchToken(
            "FullTest",
            "TEST",
            ONE_BILLION,
            "https://ipfs.io/metadata/test", // metadataURI
            2 * ONE_BERA,  // Start with 2 BERA for more liquidity
            9900,  // 99% start fee
            30,    // 0.3% end fee
            100000
        );
        
        console.log("  Token:", tok);
        console.log("  Pair:", pair);
        console.log("  FeeRouter:", feeRouter);
        
        // Verify eternal lock
        uint256 lpAtZero = OsitoPair(pair).balanceOf(address(0));
        uint256 lpAtRouter = OsitoPair(pair).balanceOf(feeRouter);
        console.log("  LP at address(0):", lpAtZero);
        console.log("  LP at FeeRouter:", lpAtRouter);
        require(lpAtZero > 0, "No eternal lock!");
        require(lpAtRouter == 0, "FeeRouter shouldn't hold LP!");
        
        // 2. TEST SWAPS
        console.log("\n2. TESTING SWAPS...");
        IWBERA(WBERA).approve(swapRouter, 5 * ONE_BERA);
        
        // Swap 1: BERA -> TOK
        SwapRouter(payable(swapRouter)).swapExactETHForTokens{value: ONE_BERA}(
            pair,
            1,  // min out
            deployer,
            block.timestamp + 100
        );
        uint256 tokBalance = ERC20(tok).balanceOf(deployer);
        console.log("  Received TOK:", tokBalance);
        require(tokBalance > 0, "No TOK received!");
        
        // Swap 2: TOK -> BERA
        ERC20(tok).approve(swapRouter, tokBalance / 2);
        SwapRouter(payable(swapRouter)).swapExactTokensForETH(
            pair,
            tokBalance / 2,
            1,  // min out
            deployer,
            block.timestamp + 100
        );
        console.log("  Swapped back half TOK for BERA");
        
        // 3. TEST FEE COLLECTION
        console.log("\n3. TESTING FEE COLLECTION...");
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);
        uint256 kLast = OsitoPair(pair).kLast();
        console.log("  Current k:", kBefore);
        console.log("  kLast:", kLast);
        
        if (kBefore > kLast) {
            FeeRouter(feeRouter).collectFees();
            console.log("  Fees collected successfully!");
            
            // Verify FeeRouter is still stateless
            uint256 routerLpAfter = OsitoPair(pair).balanceOf(feeRouter);
            console.log("  FeeRouter LP after collection:", routerLpAfter);
            require(routerLpAfter == 0, "FeeRouter should be stateless!");
        }
        
        // 4. CREATE LENDING MARKET
        console.log("\n4. CREATING LENDING MARKET...");
        address vault = LendingFactory(lendingFactory).createLendingMarket(pair);
        console.log("  CollateralVault:", vault);
        
        // 5. TEST LENDING
        console.log("\n5. TESTING LENDING...");
        
        // Get singleton lender vault
        address lenderVault = LendingFactory(lendingFactory).lenderVault();
        console.log("  LenderVault:", lenderVault);
        
        // Deposit WBERA to lend
        IWBERA(WBERA).approve(lenderVault, 2 * ONE_BERA);
        uint256 shares = LenderVault(lenderVault).deposit(2 * ONE_BERA, deployer);
        console.log("  Deposited 2 BERA, got shares:", shares);
        
        // 6. TEST BORROWING
        console.log("\n6. TESTING BORROWING...");
        
        // Check pMin
        uint256 pMin = OsitoPair(pair).pMin();
        console.log("  Current pMin:", pMin);
        require(pMin > 0, "pMin should be non-zero!");
        
        // Approve and deposit collateral
        uint256 collateralAmount = tokBalance / 4;  // Use 1/4 of our TOK
        ERC20(tok).approve(vault, collateralAmount);
        CollateralVault(vault).depositCollateral(collateralAmount);
        console.log("  Deposited collateral:", collateralAmount);
        
        // Borrow based on pMin
        uint256 borrowAmount = (collateralAmount * pMin) / 1e18 / 2;  // Borrow 50% of max
        if (borrowAmount > 0) {
            CollateralVault(vault).borrow(borrowAmount);
            console.log("  Borrowed:", borrowAmount);
            
            // Check position
            uint256 collateral = CollateralVault(vault).collateralBalances(deployer);
            (uint256 principal,,) = CollateralVault(vault).accountBorrows(deployer);
            console.log("  Position - Collateral:", collateral, "Debt:", principal);
            
            // 7. TEST REPAYMENT
            console.log("\n7. TESTING REPAYMENT...");
            IWBERA(WBERA).approve(vault, principal);
            CollateralVault(vault).repay(principal / 2);
            console.log("  Repaid half debt");
            
            collateral = CollateralVault(vault).collateralBalances(deployer);
            (principal,,) = CollateralVault(vault).accountBorrows(deployer);
            console.log("  Position after - Collateral:", collateral, "Debt:", principal);
        }
        
        // 8. TEST FEE DECAY
        console.log("\n8. CHECKING FEE DECAY...");
        uint256 currentFee = OsitoPair(pair).currentFeeBps();
        console.log("  Current fee (bps):", currentFee);
        
        // Burn some tokens to trigger decay
        uint256 burnAmount = tokBalance / 10;
        ERC20(tok).transfer(address(0xdead), burnAmount);  // Send to dead address
        
        uint256 newFee = OsitoPair(pair).currentFeeBps();
        console.log("  Fee after burn (bps):", newFee);
        
        // 9. FINAL STATE CHECK
        console.log("\n9. FINAL STATE CHECK...");
        (r0, r1,) = OsitoPair(pair).getReserves();
        console.log("  Final reserves - Token0:", r0, "Token1:", r1);
        console.log("  Final k:", uint256(r0) * uint256(r1));
        console.log("  Final pMin:", OsitoPair(pair).pMin());
        
        // Check balances
        console.log("\n  Final Balances:");
        console.log("    TOK:", ERC20(tok).balanceOf(deployer));
        console.log("    WBERA:", ERC20(WBERA).balanceOf(deployer));
        console.log("    ETH:", deployer.balance);
        console.log("    Lender shares:", LenderVault(lenderVault).balanceOf(deployer));
        
        console.log("\n=== ALL TESTS PASSED! ===");
        
        vm.stopBroadcast();
    }
}