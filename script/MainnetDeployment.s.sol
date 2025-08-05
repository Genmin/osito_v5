// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/factories/LendingFactory.sol";
import "../src/periphery/LensLite.sol";
import "../src/periphery/SwapRouter.sol";

/**
 * @title MainnetDeployment - Production V5 Protocol Deployment
 * @notice Deploys all V5 contracts to Berachain Mainnet with production configuration
 * @dev This script is ready for mainnet deployment
 */
contract MainnetDeployment is Script {
    
    // Berachain Mainnet addresses
    address constant WBERA_MAINNET = 0x7507C1dc16935B82698E4C63f2746A5fCf453D92;
    address constant TREASURY_MAINNET = 0xBfff8b5C308CBb00a114EF2651f9EC7819b69557; // Update with mainnet treasury
    
    function run() external {
        console.log("Starting V5 MAINNET Deployment");
        console.log("WBERA:", WBERA_MAINNET);
        console.log("Treasury:", TREASURY_MAINNET);
        
        // Verify we're on mainnet
        require(block.chainid == 80084, "This script is for Berachain Mainnet only");
        
        vm.startBroadcast();
        
        // 1. Deploy LendingFactory (creates singleton LenderVault)
        console.log("1. Deploying LendingFactory with singleton LenderVault...");
        LendingFactory lendingFactory = new LendingFactory(WBERA_MAINNET, TREASURY_MAINNET);
        console.log("LendingFactory deployed at:", address(lendingFactory));
        console.log("Singleton LenderVault at:", lendingFactory.lenderVault());
        
        // 2. Deploy OsitoLaunchpad (creates tokens + pairs)
        console.log("2. Deploying OsitoLaunchpad...");
        OsitoLaunchpad launchpad = new OsitoLaunchpad(WBERA_MAINNET, TREASURY_MAINNET);
        console.log("OsitoLaunchpad deployed at:", address(launchpad));
        
        // 3. Deploy LensLite (tracks markets)
        console.log("3. Deploying LensLite...");
        LensLite lensLite = new LensLite();
        console.log("LensLite deployed at:", address(lensLite));
        
        // 4. Deploy SwapRouter (trading interface)
        console.log("4. Deploying SwapRouter...");
        SwapRouter swapRouter = new SwapRouter(WBERA_MAINNET);
        console.log("SwapRouter deployed at:", address(swapRouter));
        
        vm.stopBroadcast();
        
        // 5. Output deployment summary
        console.log("V5 MAINNET DEPLOYMENT COMPLETE");
        console.log("======================================");
        console.log("OSITO_LAUNCHPAD=%s", address(launchpad));
        console.log("LENDING_FACTORY=%s", address(lendingFactory));
        console.log("LENS_LITE=%s", address(lensLite));
        console.log("SWAP_ROUTER=%s", address(swapRouter));
        console.log("LENDER_VAULT=%s", lendingFactory.lenderVault());
        console.log("======================================");
        
        // 6. Mainnet environment file content
        string memory mainnetEnvContent = string.concat(
            "# Berachain Mainnet V5 Deployment\n",
            "CHAIN_ID=80084\n",
            "RPC_URL=https://rpc.berachain.com/\n",
            "WBERA_ADDRESS=", vm.toString(WBERA_MAINNET), "\n",
            "TREASURY=", vm.toString(TREASURY_MAINNET), "\n",
            "OSITO_LAUNCHPAD=", vm.toString(address(launchpad)), "\n",
            "LENDING_FACTORY=", vm.toString(address(lendingFactory)), "\n", 
            "LENS_LITE=", vm.toString(address(lensLite)), "\n",
            "SWAP_ROUTER=", vm.toString(address(swapRouter)), "\n",
            "LENDER_VAULT=", vm.toString(lendingFactory.lenderVault()), "\n"
        );
        
        console.log("Create .env.mainnet with these addresses:");
        console.log(mainnetEnvContent);
        
        // 7. Verify key properties
        console.log("MAINNET VERIFICATION:");
        console.log("Chain ID:", block.chainid);
        console.log("LenderVault is singleton:", lendingFactory.lenderVault() != address(0));
        console.log("LaunchPad WBERA:", launchpad.weth());
        console.log("LaunchPad Treasury:", launchpad.treasury());
        console.log("SwapRouter WBERA:", swapRouter.WBERA());
        
        console.log("Ready for mainnet frontend integration!");
        
        // 8. Post-deployment checklist
        console.log("");
        console.log("POST-DEPLOYMENT CHECKLIST:");
        console.log("[ ] Update frontend wagmi.config.ts with mainnet addresses");
        console.log("[ ] Deploy subgraph to Goldsky for mainnet");  
        console.log("[ ] Update charts frontend environment variables");
        console.log("[ ] Test token launch on mainnet");
        console.log("[ ] Test trading via SwapRouter");
        console.log("[ ] Test lending market creation");
        console.log("[ ] Verify LensLite shows launched tokens");
        console.log("[ ] Monitor protocol metrics");
    }
}