// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/OsitoPair.sol";
import "../../src/core/OsitoToken.sol";
import "../../src/core/FeeRouter.sol";
import "../../src/factories/OsitoLaunchpad.sol";
import "../../src/libraries/PMinLib.sol";
import "../../src/libraries/Constants.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title Core Unit Tests for Osito Protocol
 * @notice Tests all critical invariants from SPEC.MD
 * @dev Must achieve 100% coverage of core functionality
 */
contract OsitoCoreTest is Test {
    // ============ Constants ============
    uint256 constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint256 constant INITIAL_BERA = 1 ether;
    
    // ============ State ============
    OsitoLaunchpad launchpad;
    OsitoToken token;
    OsitoPair pair;
    FeeRouter feeRouter;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    MockWBERA wbera;
    
    // ============ Setup ============
    
    function setUp() public {
        // Deploy mock WBERA
        wbera = new MockWBERA();
        
        // Deploy launchpad
        launchpad = new OsitoLaunchpad(address(wbera), treasury);
        
        // Fund alice with WBERA
        wbera.mint(alice, 100e18);
        // Approve launchpad to spend WBERA
        vm.prank(alice);
        ERC20(address(wbera)).approve(address(launchpad), type(uint256).max);
    }
    
    // ============ SPEC.MD Requirement Tests ============
    
    /**
     * @notice Test: ALL tokens start in the AMM pool (SPEC.MD #1)
     */
    function test_Spec_AllTokensStartInPool() public {
        // Launch token
        vm.prank(alice);
        (address tokenAddr, address pairAddr, address feeRouterAddr) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, // wethAmount
                9900, // startFeeBps (99%)
                30,   // endFeeBps (0.3%)
                30 days // feeDecayTarget
            );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        
        // Check reserves
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint112 tokReserves = tokIsToken0 ? r0 : r1;
        
        // All tokens should be in pool
        assertEq(tokReserves, INITIAL_SUPPLY, "Not all tokens in pool at launch");
        
        // pMin should be 0 (no tokens outside)
        uint256 pMin = pair.pMin();
        assertEq(pMin, 0, "pMin should be 0 when all tokens in pool");
    }
    
    /**
     * @notice Test: First trade activates the system (SPEC.MD #2)
     */
    function test_Spec_FirstTradeActivatesSystem() public {
        // Launch
        vm.startPrank(alice);
        (address tokenAddr, address pairAddr,) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, 9900, 30, 30 days
            );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        
        // pMin should be 0 before trade
        assertEq(pair.pMin(), 0, "pMin not 0 before first trade");
        
        // Do first trade - buy some tokens
        wbera.mint(alice, 1e18);
        ERC20(address(wbera)).transfer(address(pair), 1e18);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        
        // Calculate output
        uint256 qtIn = 1e18;
        uint256 tokOut;
        if (tokIsToken0) {
            // token0 is TOK, token1 is QT
            uint256 feeBps = pair.currentFeeBps();
            uint256 qtInAfterFee = (qtIn * (10000 - feeBps)) / 10000;
            tokOut = (qtInAfterFee * r0) / (r1 + qtInAfterFee);
            pair.swap(tokOut, 0, alice);
        } else {
            // token0 is QT, token1 is TOK
            uint256 feeBps = pair.currentFeeBps();
            uint256 qtInAfterFee = (qtIn * (10000 - feeBps)) / 10000;
            tokOut = (qtInAfterFee * r1) / (r0 + qtInAfterFee);
            pair.swap(0, tokOut, alice);
        }
        
        vm.stopPrank();
        
        // After trade:
        // 1. Tokens left the pool
        (r0, r1,) = pair.getReserves();
        uint112 newTokReserves = tokIsToken0 ? r0 : r1;
        assertLt(newTokReserves, INITIAL_SUPPLY, "Tokens didn't leave pool");
        
        // 2. pMin is now non-zero
        uint256 pMinAfter = pair.pMin();
        assertGt(pMinAfter, 0, "pMin still 0 after trade");
        
        // 3. Collateral exists
        uint256 tokensOutside = INITIAL_SUPPLY - newTokReserves;
        assertGt(tokensOutside, 0, "No collateral created");
    }
    
    /**
     * @notice Test: Fees increase k (SPEC.MD #3)
     */
    function test_Spec_FeesIncreaseK() public {
        // Launch and setup
        vm.startPrank(alice);
        (address tokenAddr, address pairAddr,) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, 9900, 30, 30 days
            );
        
        pair = OsitoPair(pairAddr);
        
        // Get initial k
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);
        
        // Do a trade (which pays fees)
        wbera.mint(alice, 10e18);
        ERC20(address(wbera)).transfer(address(pair), 10e18);
        
        // Execute swap
        bool tokIsToken0 = pair.tokIsToken0();
        if (tokIsToken0) {
            pair.swap(1000e18, 0, alice); // Rough estimate
        } else {
            pair.swap(0, 1000e18, alice);
        }
        vm.stopPrank();
        
        // Check k increased
        (r0, r1,) = pair.getReserves();
        uint256 kAfter = uint256(r0) * uint256(r1);
        
        assertGt(kAfter, kBefore, "k didn't increase from fees");
    }
    
    /**
     * @notice Test: pMin is monotonically increasing (SPEC.MD #4)
     */
    function test_Spec_PMinMonotonic() public {
        // Launch
        vm.startPrank(alice);
        (address tokenAddr, address pairAddr, address feeRouterAddr) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, // wethAmount
                9900, // startFeeBps (99%)
                30,   // endFeeBps (0.3%)
                30 days // feeDecayTarget
            );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
        
        // Do initial trade to activate
        wbera.mint(alice, 10e18);
        ERC20(address(wbera)).transfer(address(pair), 10e18);
        pair.swap(1000e18, 0, alice); // Rough
        
        uint256 pMin1 = pair.pMin();
        
        // Do more trades
        for (uint i = 0; i < 10; i++) {
            wbera.mint(alice, 1e18);
            ERC20(address(wbera)).transfer(address(pair), 1e18);
            pair.swap(100e18, 0, alice); // Small trades
        }
        
        uint256 pMin2 = pair.pMin();
        assertGe(pMin2, pMin1, "pMin decreased after trades");
        
        // Collect fees and burn
        feeRouter.collectFees();
        
        uint256 pMin3 = pair.pMin();
        assertGe(pMin3, pMin2, "pMin decreased after burn");
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Fee decay from 99% to 0.3% based on burns (SPEC.MD #3)
     */
    function test_Spec_FeeDecay() public {
        // Launch with a smaller decay target for testing
        uint256 decayTarget = INITIAL_SUPPLY / 100; // 1% of supply
        vm.prank(alice);
        (address tokenAddr, address pairAddr,) = launchpad.launchToken(
            "TEST", "TEST", INITIAL_SUPPLY, "",
            INITIAL_BERA, 9900, 30, decayTarget
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        
        // Initial fee should be high (close to 99%)
        uint256 initialFee = pair.currentFeeBps();
        assertEq(initialFee, 9900, "Initial fee not set correctly");
        
        // Burn some tokens to trigger decay
        // First get some tokens out of the pool
        vm.startPrank(alice);
        MockWBERA(wbera).approve(address(pair), 10e18);
        MockWBERA(wbera).transfer(address(pair), 10e18);
        
        // Calculate actual output
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInAfterFee = (10e18 * (10000 - feeBps)) / 10000;
        uint256 tokOut = tokIsToken0
            ? (amountInAfterFee * r0) / (r1 + amountInAfterFee)
            : (amountInAfterFee * r1) / (r0 + amountInAfterFee);
        
        if (tokIsToken0) {
            pair.swap(tokOut, 0, alice);
        } else {
            pair.swap(0, tokOut, alice);
        }
        
        // Now burn them
        token.burn(decayTarget / 2); // Burn half the decay target
        vm.stopPrank();
        
        // Fee should have decayed partially
        uint256 midFee = pair.currentFeeBps();
        assertLt(midFee, initialFee, "Fee didn't decay");
        assertGt(midFee, 30, "Fee decayed too much");
        
        // Burn more to reach target
        vm.prank(alice);
        token.burn(decayTarget / 2);
        
        // Should be at minimum now
        uint256 finalFee = pair.currentFeeBps();
        assertEq(finalFee, 30, "Fee didn't reach minimum");
    }
    
    /**
     * @notice Test: Token burns reduce supply permanently (SPEC.MD #3)
     */
    function test_Spec_TokenBurnReducesSupply() public {
        // Launch
        vm.startPrank(alice);
        (address tokenAddr, address pairAddr, address feeRouterAddr) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, // wethAmount
                9900, // startFeeBps (99%)
                30,   // endFeeBps (0.3%)
                30 days // feeDecayTarget
            );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
        
        // Do trades to generate fees
        for (uint i = 0; i < 5; i++) {
            wbera.mint(alice, 5e18);
            ERC20(address(wbera)).transfer(address(pair), 5e18);
            pair.swap(500e18, 0, alice);
        }
        
        uint256 supplyBefore = token.totalSupply();
        
        // Collect fees (burns tokens)
        feeRouter.collectFees();
        
        uint256 supplyAfter = token.totalSupply();
        
        assertLt(supplyAfter, supplyBefore, "Supply didn't decrease from burn");
        assertLt(supplyAfter, INITIAL_SUPPLY, "Supply not less than initial");
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: LP tokens restricted to FeeRouter only (SPEC.MD #71)
     */
    function test_Spec_LPRestricted() public {
        // Launch
        vm.prank(alice);
        (address tokenAddr, address pairAddr,) = 
            launchpad.launchToken(
                "TEST", "TEST", INITIAL_SUPPLY, "",
                INITIAL_BERA, 9900, 30, 30 days
            );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        
        // Try to mint LP tokens as attacker
        address attacker = makeAddr("attacker");
        deal(address(token), attacker, 1000e18);
        wbera.mint(attacker, 10e18);
        
        vm.startPrank(attacker);
        token.transfer(address(pair), 1000e18);
        ERC20(address(wbera)).transfer(address(pair), 10e18);
        
        // Should revert - can't mint to attacker
        vm.expectRevert("RESTRICTED");
        pair.mint(attacker);
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: pMin calculation correctness
     */
    function test_PMinCalculation() public {
        // Test with known values
        uint256 tokReserves = 100e18;
        uint256 qtReserves = 10e18;
        uint256 totalSupply = 200e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Manual calculation:
        // deltaX = 100e18
        // deltaXEff = 100e18 * 0.997 = 99.7e18
        // xFinal = 199.7e18
        // k = 1000e36
        // yFinal = k / xFinal = ~5.01e18
        // deltaY = 10e18 - 5.01e18 = ~4.99e18
        // pMin = deltaY / deltaX * 0.995 = ~0.0497e18
        
        assertApproxEqRel(pMin, 0.0497e18, 0.01e18, "pMin calculation incorrect");
    }
    
    // ============ Edge Cases ============
    
    function test_EdgeCase_ZeroSupply() public {
        // Can't launch with 0 supply
        vm.prank(alice);
        vm.expectRevert();
        launchpad.launchToken("TEST", "TEST", 0, "", INITIAL_BERA, 9900, 30, 30 days);
    }
    
    function test_EdgeCase_MaxSupply() public {
        // Test max supply (2^111)
        uint256 maxSupply = 2**111;
        
        vm.prank(alice);
        (address tokenAddr,,) = launchpad.launchToken(
            "MAX", "MAX", maxSupply, "",
            INITIAL_BERA, 9900, 30, 30 days
        );
        
        token = OsitoToken(tokenAddr);
        assertEq(token.totalSupply(), maxSupply, "Max supply not set correctly");
    }
    
    function test_EdgeCase_MinimumLiquidity() public {
        // Test that minimum liquidity is locked
        vm.prank(alice);
        (,address pairAddr,) = launchpad.launchToken(
            "TEST", "TEST", INITIAL_SUPPLY, "",
            INITIAL_BERA, 9900, 30, 30 days
        );
        
        pair = OsitoPair(pairAddr);
        
        // Check that dead address has minimum liquidity
        uint256 deadBalance = pair.balanceOf(address(0xdead));
        assertEq(deadBalance, 1000, "Minimum liquidity not locked");
    }
}

// ============ Mock Contracts ============

contract MockWBERA is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped BERA";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WBERA";
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
    
    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}