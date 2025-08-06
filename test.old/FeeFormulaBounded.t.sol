// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/factories/OsitoLaunchpad.sol";
import "../src/core/OsitoPair.sol";
import "../src/core/FeeRouter.sol";
import "../src/core/OsitoToken.sol";
import "../src/periphery/SwapRouter.sol";
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
    
    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

contract FeeFormulaBoundedTest is Test {
    OsitoLaunchpad launchpad;
    OsitoPair pair;
    FeeRouter feeRouter;
    OsitoToken token;
    MockWETH weth;
    SwapRouter router;
    
    address treasury = address(0x1234);
    
    function setUp() public {
        // Deploy mock WETH
        weth = new MockWETH();
        
        // Deploy launchpad
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        
        // Deploy swap router
        router = new SwapRouter(address(weth));
        
        // Fund with WETH
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.approve(address(launchpad), type(uint256).max);
        
        // Launch token with 1 WETH initial liquidity
        (address tokenAddr, address pairAddr, address feeRouterAddr) = launchpad.launchToken(
            "TestToken",
            "TEST", 
            1000000 * 1e18,  // 1M tokens
            "",
            1 ether,         // 1 WETH liquidity
            1500,            // 15% start fee
            30,              // 0.3% end fee  
            7000             // 70% decay target
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
    }
    
    function testExtremeTradeBoundedFees() public {
        console.log("=== Testing Extreme Trade Fee Bounds ===");
        
        // Initial state
        uint256 initialLp = pair.totalSupply();
        console.log("Initial LP supply:", initialLp);
        
        // Perform EXTREME trade (50x initial liquidity)
        uint256 wethIn = 50 ether;
        weth.transfer(address(pair), wethIn);
        
        // Calculate output using router's method
        uint256 tokOut = router.getAmountOut(address(pair), wethIn, false); // false = WETH in, TOK out
        console.log("Swapping %s WETH for %s TOK", wethIn, tokOut);
        
        // Perform swap
        pair.swap(tokOut, 0, address(this));
        
        // Collect fees
        uint256 lpBeforeFees = pair.totalSupply();
        feeRouter.collectFees();
        uint256 lpAfterFees = pair.totalSupply();
        
        // Calculate fee mint
        uint256 feeMinted = lpAfterFees - lpBeforeFees;
        uint256 feePct = feeMinted * 100 / lpBeforeFees;
        
        console.log("LP before fee collection:", lpBeforeFees);
        console.log("LP after fee collection:", lpAfterFees);
        console.log("Fee LP minted:", feeMinted);
        console.log("Fee mint percentage: %s%%", feePct);
        
        // CRITICAL ASSERTION: Fee mint must be bounded even for extreme trades
        assertLt(feePct, 15, "Fee formula NOT BOUNDED - EXPLOIT POSSIBLE!");
        
        // Verify protocol still functional
        (uint256 r0, uint256 r1,) = pair.getReserves();
        assertGt(r0, 0, "Reserve0 depleted");
        assertGt(r1, 0, "Reserve1 depleted");
    }
    
    function testSequentialExploitAttempt() public {
        console.log("=== Testing Sequential Exploit Attempt ===");
        
        uint256 initialLp = pair.totalSupply();
        uint256 cumulativeFees;
        
        // Attacker tries 10 sequential large trades
        for (uint256 i = 0; i < 10; i++) {
            // Large trade
            uint256 wethIn = 5 ether;
            weth.transfer(address(pair), wethIn);
            
            uint256 tokOut = router.getAmountOut(address(pair), wethIn, false);
            pair.swap(tokOut, 0, address(this));
            
            // Collect fees
            uint256 lpBefore = pair.totalSupply();
            feeRouter.collectFees();
            uint256 lpAfter = pair.totalSupply();
            
            uint256 roundFees = lpAfter - lpBefore;
            cumulativeFees += roundFees;
            
            console.log("Round %s fee mint: %s", i + 1, roundFees);
        }
        
        uint256 totalFeePct = cumulativeFees * 100 / initialLp;
        console.log("Total cumulative fee percentage: %s%%", totalFeePct);
        
        // Even with 10 large sequential trades, fees must remain bounded
        assertLt(totalFeePct, 50, "Sequential exploit possible - fees unbounded!");
    }
    
    function testCompareWithOldFormula() public {
        console.log("=== Comparing New vs Old Formula ===");
        
        // Calculate what the old formula would have minted
        uint256 wethIn = 20 ether;
        weth.transfer(address(pair), wethIn);
        
        // Get k values before swap
        (uint256 r0Before, uint256 r1Before,) = pair.getReserves();
        uint256 kBefore = r0Before * r1Before;
        
        // Perform swap
        uint256 tokOut = router.getAmountOut(address(pair), wethIn, false);
        pair.swap(tokOut, 0, address(this));
        
        // Get k values after swap
        (uint256 r0After, uint256 r1After,) = pair.getReserves();
        uint256 kAfter = r0After * r1After;
        
        // Calculate what old formula would mint
        uint256 rootK = sqrt(kAfter);
        uint256 rootKLast = sqrt(kBefore);
        uint256 totalSupply = pair.totalSupply();
        
        // Old formula: totalSupply * (rootK - rootKLast) * 90 / (rootKLast * 100)
        uint256 oldFormulaLiquidity = totalSupply * (rootK - rootKLast) * 90 / (rootKLast * 100);
        
        // New formula (what actually gets minted)
        uint256 lpBefore = pair.totalSupply();
        feeRouter.collectFees();
        uint256 lpAfter = pair.totalSupply();
        uint256 newFormulaLiquidity = lpAfter - lpBefore;
        
        console.log("Old formula would mint:", oldFormulaLiquidity);
        console.log("New formula actually mints:", newFormulaLiquidity);
        console.log("Reduction factor: %sx", oldFormulaLiquidity / (newFormulaLiquidity + 1)); // +1 to avoid div by 0
        
        // New formula should mint SIGNIFICANTLY less than old
        assertLt(newFormulaLiquidity, oldFormulaLiquidity, "New formula not properly bounded!");
    }
    
    // Helper function for square root
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}