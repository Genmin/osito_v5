// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/factories/LendingFactory.sol";
import "../src/periphery/LensLite.sol";
import "../src/periphery/SwapRouter.sol";

/**
 * @title FullDeployment - Complete V5 Protocol Deployment
 * @notice Deploys all V5 contracts in correct order with proper configuration
 * @dev This is the mainnet-ready deployment script
 */
contract FullDeployment is Script {
    
    function run() external {
        // Hardcode addresses for reliable deployment
        address wbera = 0x6969696969696969696969696969696969696969;
        address treasury = 0xBfff8b5C308CBb00a114EF2651f9EC7819b69557;
        
        console.log("Starting V5 Full Deployment");
        console.log("WBERA:", wbera);
        console.log("Treasury:", treasury);
        
        vm.startBroadcast();
        
        // 1. Deploy LendingFactory (creates singleton LenderVault)
        console.log("1. Deploying LendingFactory with singleton LenderVault...");
        LendingFactory lendingFactory = new LendingFactory(wbera, treasury);
        console.log("LendingFactory deployed at:", address(lendingFactory));
        console.log("Singleton LenderVault at:", lendingFactory.lenderVault());
        
        // 2. Deploy OsitoLaunchpad (creates tokens + pairs)
        console.log("2. Deploying OsitoLaunchpad...");
        OsitoLaunchpad launchpad = new OsitoLaunchpad(wbera, treasury);
        console.log("OsitoLaunchpad deployed at:", address(launchpad));
        
        // 3. Deploy LensLite (tracks markets)
        console.log("3. Deploying LensLite...");
        LensLite lensLite = new LensLite();
        console.log("LensLite deployed at:", address(lensLite));
        
        // 4. Deploy SwapRouter (trading interface)
        console.log("4. Deploying SwapRouter...");
        SwapRouter swapRouter = new SwapRouter(wbera);
        console.log("SwapRouter deployed at:", address(swapRouter));
        
        vm.stopBroadcast();
        
        // 5. Output deployment summary
        console.log("V5 DEPLOYMENT COMPLETE");
        console.log("===========================");
        console.log("OSITO_LAUNCHPAD=%s", address(launchpad));
        console.log("LENDING_FACTORY=%s", address(lendingFactory));
        console.log("LENS_LITE=%s", address(lensLite));
        console.log("SWAP_ROUTER=%s", address(swapRouter));
        console.log("===========================");
        
        // 6. Write to .env.testnet file
        string memory envContent = string.concat(
            "# Deployed Contract Addresses - TESTNET (FRESH DEPLOYMENT)\n",
            "OSITO_LAUNCHPAD=", vm.toString(address(launchpad)), "\n",
            "LENDING_FACTORY=", vm.toString(address(lendingFactory)), "\n", 
            "LENS_LITE=", vm.toString(address(lensLite)), "\n",
            "SWAP_ROUTER=", vm.toString(address(swapRouter)), "\n"
        );
        
        console.log("Update your .env.testnet with these addresses:");
        console.log(envContent);
        
        // 7. Verify key properties
        console.log("VERIFICATION:");
        console.log("LenderVault is singleton:", lendingFactory.lenderVault() != address(0));
        console.log("LaunchPad WBERA:", launchpad.weth());
        console.log("LaunchPad Treasury:", launchpad.treasury());
        console.log("SwapRouter WBERA:", swapRouter.WBERA());
        
        console.log("Ready for frontend integration and subgraph deployment!");
    }
}