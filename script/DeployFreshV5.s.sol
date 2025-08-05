// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/core/OsitoToken.sol";
import "../src/core/OsitoPair.sol";
import "../src/core/FeeRouter.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract DeployFreshV5 is Script {
    function run() external returns (address, address, address) {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0x2dffa64cbf9cdf8b80a4751b2f7c4e37e42c7a4e537c1374d07fa2ba5c3593c7));
        address wbera = vm.envOr("WBERA_ADDRESS", address(0x6969696969696969696969696969696969696969));
        address treasury = vm.envOr("TREASURY", address(0xBfff8b5C308CBb00a114EF2651f9EC7819b69557));
        address ositoLaunchpad = vm.envOr("OSITO_LAUNCHPAD", address(0xa0ed42aE45eC59Fb1bAaD358DA05Dae764f58b1F));
        
        console.log("Deploying fresh V5 token with updated FeeRouter...");
        console.log("OsitoLaunchpad:", ositoLaunchpad);
        console.log("Treasury:", treasury);
        console.log("WBERA:", wbera);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy through launchpad
        OsitoLaunchpad launchpad = OsitoLaunchpad(ositoLaunchpad);
        
        // Calculate WETH needed for initial liquidity (0.001 WBERA)
        uint256 wethAmount = 0.001 ether;
        
        // Approve WETH spending
        IERC20(wbera).approve(ositoLaunchpad, wethAmount);
        
        // Deploy with 1M supply
        (address tok, address pair, address feeRouter) = launchpad.launchToken(
            "Test Osito V5 Robust", 
            "TOK5R", 
            1_000_000 * 1e18,  // 1M supply
            "ipfs://QmTestOsitoV5Metadata", // metadataURI
            wethAmount,        // 0.001 WBERA initial liquidity
            200,               // 2% start fee
            30,                // 0.3% end fee
            500_000 * 1e18     // Fee decay at 500k tokens traded
        );
        
        console.log("\n=== Fresh V5 Deployment ===");
        console.log("TOK:", tok);
        console.log("Pair:", pair);
        console.log("FeeRouter:", feeRouter);
        
        vm.stopBroadcast();
        
        return (tok, pair, feeRouter);
    }
}