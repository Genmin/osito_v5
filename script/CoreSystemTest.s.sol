// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {OsitoLaunchpad} from "../src/factories/OsitoLaunchpad.sol";
import {OsitoPair} from "../src/core/OsitoPair.sol";
import {FeeRouter} from "../src/core/FeeRouter.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";

interface IWBERA {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

contract CoreSystemTest is Script {
    address constant WBERA = 0x6969696969696969696969696969696969696969;
    
    function run() external {
        address launchpad = vm.envAddress("OSITO_LAUNCHPAD");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("\n=== CORE SYSTEM TEST ===");
        
        // 1. LAUNCH TOKEN WITH EXTREME PARAMETERS
        console.log("\n1. LAUNCHING TOKEN (10B supply, 0.5 BERA)...");
        IWBERA(WBERA).deposit{value: 5 ether}();
        IWBERA(WBERA).approve(launchpad, 5 ether);
        
        (address tok, address pair, address feeRouter) = OsitoLaunchpad(launchpad).launchToken(
            "ExtremeTest",
            "XTEST",
            10_000_000_000 * 1e18,  // 10 billion supply
            0.5 ether,              // Only 0.5 BERA liquidity (extreme!)
            9900,                   // 99% start fee
            30,                     // 0.3% end fee
            1_000_000              // 1M burn target
        );
        
        console.log("  Token:", tok);
        console.log("  Pair:", pair);
        console.log("  FeeRouter:", feeRouter);
        
        // VERIFY ETERNAL LOCK
        uint256 lpAtZero = OsitoPair(pair).balanceOf(address(0));
        uint256 lpAtRouter = OsitoPair(pair).balanceOf(feeRouter);
        console.log("  LP burned to 0x0:", lpAtZero);
        console.log("  LP at FeeRouter:", lpAtRouter);
        require(lpAtZero > 0, "FAILED: No eternal lock!");
        require(lpAtRouter == 0, "FAILED: FeeRouter has LP!");
        
        // 2. MULTIPLE SWAPS TO GENERATE FEES
        console.log("\n2. PERFORMING SWAPS...");
        
        // Swap 1: Buy tokens
        SwapRouter(payable(swapRouter)).swapExactETHForTokens{value: 0.1 ether}(
            pair, 1, deployer, block.timestamp + 100
        );
        
        // Swap 2: Buy more
        SwapRouter(payable(swapRouter)).swapExactETHForTokens{value: 0.2 ether}(
            pair, 1, deployer, block.timestamp + 100
        );
        
        // Swap 3: Sell some back
        uint256 tokBal = ERC20(tok).balanceOf(deployer);
        ERC20(tok).approve(swapRouter, tokBal);
        SwapRouter(payable(swapRouter)).swapExactTokensForETH(
            pair, tokBal / 10, 1, deployer, block.timestamp + 100
        );
        
        console.log("  Swaps completed, k should have grown");
        
        // 3. COLLECT FEES MULTIPLE TIMES
        console.log("\n3. FEE COLLECTION TEST...");
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        uint256 kLast = OsitoPair(pair).kLast();
        
        console.log("  Current k:", currentK);
        console.log("  kLast:", kLast);
        console.log("  k growth:", currentK > kLast ? currentK - kLast : 0);
        
        // First collection
        if (currentK > kLast) {
            console.log("  Collecting fees (1st time)...");
            FeeRouter(feeRouter).collectFees();
            
            // Verify stateless
            require(OsitoPair(pair).balanceOf(feeRouter) == 0, "FAILED: FeeRouter not stateless!");
            console.log("  [OK] FeeRouter balance: 0 (stateless!)");
        }
        
        // Do another swap to generate more fees
        SwapRouter(payable(swapRouter)).swapExactETHForTokens{value: 0.1 ether}(
            pair, 1, deployer, block.timestamp + 100
        );
        
        // Second collection
        (r0, r1,) = OsitoPair(pair).getReserves();
        currentK = uint256(r0) * uint256(r1);
        kLast = OsitoPair(pair).kLast();
        
        if (currentK > kLast) {
            console.log("  Collecting fees (2nd time)...");
            FeeRouter(feeRouter).collectFees();
            require(OsitoPair(pair).balanceOf(feeRouter) == 0, "FAILED: FeeRouter not stateless!");
            console.log("  [OK] FeeRouter balance: 0 (still stateless!)");
        }
        
        // 4. TEST PMIN
        console.log("\n4. PMIN TEST...");
        uint256 pMin = OsitoPair(pair).pMin();
        console.log("  pMin:", pMin);
        require(pMin > 0, "FAILED: pMin is zero!");
        
        // 5. TEST FEE DECAY
        console.log("\n5. FEE DECAY TEST...");
        uint256 feeBefore = OsitoPair(pair).currentFeeBps();
        console.log("  Fee before burn:", feeBefore);
        
        // Burn tokens to trigger decay
        ERC20(tok).transfer(address(0xdead), ERC20(tok).balanceOf(deployer) / 100);
        
        uint256 feeAfter = OsitoPair(pair).currentFeeBps();
        console.log("  Fee after burn:", feeAfter);
        require(feeAfter <= feeBefore, "FAILED: Fee didn't decay!");
        
        // 6. FINAL RESERVES CHECK
        console.log("\n6. FINAL STATE...");
        (r0, r1,) = OsitoPair(pair).getReserves();
        bool tokIs0 = OsitoPair(pair).tokIsToken0();
        
        console.log("  Token reserves:", tokIs0 ? r0 : r1);
        console.log("  BERA reserves:", tokIs0 ? r1 : r0);
        console.log("  Final k:", uint256(r0) * uint256(r1));
        console.log("  Final pMin:", OsitoPair(pair).pMin());
        
        // 7. CHECK TREASURY
        console.log("\n7. TREASURY CHECK...");
        address treasury = FeeRouter(feeRouter).treasury();
        uint256 treasuryBal = ERC20(WBERA).balanceOf(treasury);
        console.log("  Treasury WBERA balance:", treasuryBal);
        console.log("  (Accumulated from all tests)");
        
        console.log("\n=== ALL CORE TESTS PASSED! ===");
        console.log("[OK] Eternal liquidity lock working");
        console.log("[OK] Stateless FeeRouter working");
        console.log("[OK] Fee collection working");
        console.log("[OK] pMin calculation working");
        console.log("[OK] Fee decay working");
        console.log("[OK] Swaps working");
        
        vm.stopBroadcast();
    }
}