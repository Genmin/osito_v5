// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/factories/LendingFactory.sol";
import "../src/periphery/LensLite.sol";
import "../src/periphery/SwapRouter.sol";

contract Deploy is Script {
    // Deployment addresses
    address public ositoLaunchpad;
    address public lendingFactory;
    address public lensLite;
    address public swapRouter;
    
    function run() external {
        // Use standard addresses for testnet
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0x2dffa64cbf9cdf8b80a4751b2f7c4e37e42c7a4e537c1374d07fa2ba5c3593c7));
        address wbera = vm.envOr("WBERA_ADDRESS", address(0x6969696969696969696969696969696969696969));
        address treasury = vm.envOr("TREASURY", address(0xBfff8b5C308CBb00a114EF2651f9EC7819b69557));
        
        console.log("Deploying to chain:", block.chainid);
        console.log("WBERA address:", wbera);
        console.log("Treasury address:", treasury);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy OsitoLaunchpad
        console.log("Deploying OsitoLaunchpad...");
        ositoLaunchpad = address(new OsitoLaunchpad(wbera, treasury));
        console.log("OsitoLaunchpad deployed at:", ositoLaunchpad);
        
        console.log("Deploying LendingFactory...");
        lendingFactory = address(new LendingFactory(wbera));
        console.log("LendingFactory deployed at:", lendingFactory);
        
        // 3. Deploy LensLite
        console.log("Deploying LensLite...");
        lensLite = address(new LensLite());
        console.log("LensLite deployed at:", lensLite);
        
        // 4. Deploy SwapRouter  
        console.log("Deploying SwapRouter...");
        swapRouter = address(new SwapRouter(wbera));
        console.log("SwapRouter deployed at:", swapRouter);
        
        vm.stopBroadcast();
        
        console.log("\n=== Deployment Summary ===");
        console.log("OsitoLaunchpad:", ositoLaunchpad);
        console.log("LendingFactory:", lendingFactory);
        console.log("LensLite:", lensLite);
        console.log("SwapRouter:", swapRouter);
        console.log("==========================\n");
    }
}