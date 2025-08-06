// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/core/OsitoPair.sol";
import "../src/core/FeeRouter.sol";
import "../src/core/OsitoToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped Ether";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WETH";
    }
    
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }
}

contract DebugFeeTest is Test {
    OsitoLaunchpad launchpad;
    OsitoPair pair;
    FeeRouter feeRouter;
    OsitoToken token;
    MockWETH weth;
    
    address treasury = address(0x1234);
    
    function setUp() public {
        weth = new MockWETH();
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.approve(address(launchpad), type(uint256).max);
        
        (address tokenAddr, address pairAddr, address feeRouterAddr) = launchpad.launchToken(
            "TestToken",
            "TEST", 
            1000000 * 1e18,
            "",
            1 ether,
            1500,
            30,
            7000
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
    }
    
    function testDebugFeeCollection() public {
        console.log("=== Debug Fee Collection ===");
        
        // Check initial state
        console.log("Initial kLast:", pair.kLast());
        console.log("Fee router address:", address(feeRouter));
        console.log("Pair's fee router:", pair.feeRouter());
        
        // Perform first swap
        uint256 wethIn = 1 ether;
        weth.transfer(address(pair), wethIn);
        
        // Simple swap
        (uint256 r0Before, uint256 r1Before,) = pair.getReserves();
        console.log("Reserves before swap: r0=%s, r1=%s", r0Before, r1Before);
        
        // Get current fee
        uint256 feeBps = pair.currentFeeBps();
        console.log("Current fee (bps):", feeBps);
        
        // Calculate output with dynamic fee
        uint256 feeMultiplier = 10000 - feeBps;
        uint256 tokOut = (r0Before * wethIn * feeMultiplier) / ((r1Before * 10000) + (wethIn * feeMultiplier));
        console.log("Expected output:", tokOut);
        
        pair.swap(tokOut, 0, address(this));
        
        // Check k after swap
        (uint256 r0After, uint256 r1After,) = pair.getReserves();
        console.log("Reserves after swap: r0=%s, r1=%s", r0After, r1After);
        console.log("kLast after swap:", pair.kLast());
        
        // Now do another swap to create fee growth
        wethIn = 2 ether;
        weth.transfer(address(pair), wethIn);
        
        // Recalculate with current fee
        feeBps = pair.currentFeeBps();
        console.log("Fee for 2nd swap (bps):", feeBps);
        feeMultiplier = 10000 - feeBps;
        tokOut = (r0After * wethIn * feeMultiplier) / ((r1After * 10000) + (wethIn * feeMultiplier));
        pair.swap(tokOut, 0, address(this));
        
        (uint256 r0After2, uint256 r1After2,) = pair.getReserves();
        console.log("Reserves after 2nd swap: r0=%s, r1=%s", r0After2, r1After2);
        
        // Try to collect fees
        console.log("LP supply before fee collection:", pair.totalSupply());
        console.log("kLast before collection:", pair.kLast());
        
        feeRouter.collectFees();
        
        console.log("LP supply after fee collection:", pair.totalSupply());
        console.log("kLast after collection:", pair.kLast());
        
        // Check if any fees were minted
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        console.log("FeeRouter LP balance:", feeRouterBalance);
    }
}