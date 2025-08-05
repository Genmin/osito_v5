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

contract LaunchAndTestToken is Script {
    address constant WBERA = 0x6969696969696969696969696969696969696969;
    uint256 constant ONE_BILLION = 1_000_000_000 * 1e18;
    uint256 constant ONE_BERA = 1e18;
    
    function run() external {
        // Get deployment addresses from env
        address launchpad = vm.envAddress("OSITO_LAUNCHPAD");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Deployer address:", deployer);
        console.log("Deployer BERA balance:", deployer.balance);
        
        // 1. Wrap BERA for liquidity
        console.log("Wrapping 2 BERA...");
        IWBERA(WBERA).deposit{value: 2 * ONE_BERA}();
        IWBERA(WBERA).approve(launchpad, 2 * ONE_BERA);
        
        // 2. Launch token with 1 billion supply and 1 BERA
        console.log("Launching token with 1 billion supply and 1 BERA liquidity...");
        (address tok, address pair, address feeRouter) = OsitoLaunchpad(launchpad).launchToken(
            "TestToken",
            "TEST",
            ONE_BILLION,
            "https://ipfs.io/metadata/test", // metadataURI
            ONE_BERA,
            9900,  // 99% start fee (in bps)
            30,    // 0.3% end fee (in bps)
            100000 // fee decay target (100k swaps)
        );
        
        console.log("Token deployed at:", tok);
        console.log("Pair deployed at:", pair);
        console.log("FeeRouter deployed at:", feeRouter);
        
        // 3. Get initial state
        OsitoPair pairContract = OsitoPair(pair);
        (uint112 r0, uint112 r1,) = pairContract.getReserves();
        bool tokIs0 = pairContract.tokIsToken0();
        
        uint256 tokReserves = tokIs0 ? uint256(r0) : uint256(r1);
        uint256 beraReserves = tokIs0 ? uint256(r1) : uint256(r0);
        
        console.log("Initial reserves:");
        console.log("  TOK:", tokReserves);
        console.log("  BERA:", beraReserves);
        console.log("  K:", tokReserves * beraReserves);
        
        // 4. Make a swap to generate fees
        console.log("\n4. Making swap to generate fees...");
        IWBERA(WBERA).approve(swapRouter, ONE_BERA);
        
        uint256 minOut = 1; // Accept any amount
        SwapRouter(payable(swapRouter)).swapExactETHForTokens{value: ONE_BERA}(
            pair,
            minOut,
            deployer,
            block.timestamp + 100
        );
        
        console.log("Swap completed!");
        
        // 5. Check k growth
        (r0, r1,) = pairContract.getReserves();
        tokReserves = tokIs0 ? uint256(r0) : uint256(r1);
        beraReserves = tokIs0 ? uint256(r1) : uint256(r0);
        
        console.log("\nPost-swap reserves:");
        console.log("  TOK:", tokReserves);
        console.log("  BERA:", beraReserves);
        console.log("  K:", tokReserves * beraReserves);
        console.log("  kLast:", pairContract.kLast());
        
        // 6. Check sacrifice calculation
        uint256 totalSupply = pairContract.totalSupply();
        uint256 bal0 = ERC20(pairContract.token0()).balanceOf(address(pairContract));
        uint256 bal1 = ERC20(pairContract.token1()).balanceOf(address(pairContract));
        uint256 minBalance = bal0 < bal1 ? bal0 : bal1;
        
        console.log("\nFee collection parameters:");
        console.log("  Total LP Supply:", totalSupply);
        console.log("  Balance token0:", bal0);
        console.log("  Balance token1:", bal1);
        console.log("  Min balance:", minBalance);
        
        // Calculate sacrifice using our formula
        uint256 sacrificeNeeded = (totalSupply * 6 / 5) / minBalance + 1;
        console.log("  Calculated sacrifice needed:", sacrificeNeeded);
        
        // 7. Try to collect fees
        console.log("\n7. Attempting fee collection...");
        try FeeRouter(feeRouter).collectFees() {
            console.log("SUCCESS: Fees collected!");
            
            // Check how much was actually sacrificed
            uint256 newTotalSupply = pairContract.totalSupply();
            console.log("  New total supply:", newTotalSupply);
            console.log("  Supply change:", totalSupply - newTotalSupply);
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
        } catch (bytes memory) {
            console.log("FAILED: Unknown error");
        }
        
        vm.stopBroadcast();
    }
}