// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/periphery/SwapRouter.sol";

contract DeployRouter is Script {
    address public swapRouter;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0x2dffa64cbf9cdf8b80a4751b2f7c4e37e42c7a4e537c1374d07fa2ba5c3593c7));
        address wbera = vm.envOr("WBERA_ADDRESS", address(0x6969696969696969696969696969696969696969));
        
        console.log("Deploying SwapRouter...");
        console.log("WBERA address:", wbera);
        
        vm.startBroadcast(deployerPrivateKey);
        
        swapRouter = address(new SwapRouter(wbera));
        console.log("SwapRouter deployed at:", swapRouter);
        
        vm.stopBroadcast();
    }
}