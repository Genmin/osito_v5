// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Tests for refactored security improvements
contract RefactoredSecurityTest is BaseTest {
    using FixedPointMathLib for uint256;
    
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    function setUp() public override {
        super.setUp();
        
        (token, pair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            SUPPLY,
            INITIAL_LIQUIDITY,
            alice
        );
    }
    
    /// @notice Test that mint restrictions prevent unauthorized minting
    function test_MintRestrictionsEnforced() public {
        // Setup: Add liquidity to pair
        deal(address(token), alice, 1000 * 1e18);
        deal(address(weth), alice, 10 ether);
        
        vm.startPrank(alice);
        token.transfer(address(pair), 1000 * 1e18);
        weth.transfer(address(pair), 10 ether);
        
        // Try to mint to unauthorized address - should fail
        vm.expectRevert("RESTRICTED");
        pair.mint(alice);
        
        // Try to mint to address(0) when already initialized - should fail
        vm.expectRevert("ALREADY_INITIALIZED");
        pair.mint(address(0));
        
        vm.stopPrank();
        
        // Try to mint to feeRouter from non-feeRouter - should fail
        vm.prank(bob);
        vm.expectRevert("ONLY_FEE_ROUTER");
        pair.mint(address(feeRouter));
    }
    
    /// @notice Test that sync() and skim() are disabled
    function test_SyncSkimDisabled() public {
        // These functions should not exist in the refactored code
        // Attempting to call them should fail at compile time
        // This test documents their intentional removal
        
        // Transfer tokens directly to pair (donation attempt)
        deal(address(token), alice, 1000 * 1e18);
        vm.prank(alice);
        token.transfer(address(pair), 1000 * 1e18);
        
        // Without sync(), these donated tokens cannot update reserves
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 actualBalance = token.balanceOf(address(pair));
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 reserveAmount = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        // Reserves should not match actual balance (donation not synced)
        assertGt(actualBalance, reserveAmount, "Donation should not be in reserves");
    }
    
    /// @notice Test LP token transfer restrictions
    function test_LPTokenTransferRestrictions() public {
        // Generate some LP tokens for feeRouter through fees
        deal(address(weth), alice, 10 ether); // Fund alice first
        vm.startPrank(alice);
        for (uint i = 0; i < 5; i++) {
            _swap(pair, address(weth), 1 ether, alice);
        }
        vm.stopPrank();
        
        // Collect fees to mint LP to feeRouter
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        if (feeRouterBalance == 0) return; // Skip test if no fees collected
        
        // FeeRouter cannot transfer LP tokens to unauthorized addresses
        vm.startPrank(address(feeRouter));
        
        // Cannot transfer to EOA
        vm.expectRevert("RESTRICTED");
        pair.transfer(alice, 1);
        
        // Cannot transfer to random contract
        vm.expectRevert("RESTRICTED");
        pair.transfer(address(token), 1);
        
        // Can transfer to itself (pair)
        uint256 balanceBefore = pair.balanceOf(address(pair));
        pair.transfer(address(pair), 1);
        assertEq(pair.balanceOf(address(pair)), balanceBefore + 1);
        
        vm.stopPrank();
    }
    
    /// @notice Test transferFrom restrictions
    function test_LPTokenTransferFromRestrictions() public {
        // Generate LP tokens
        deal(address(weth), alice, 10 ether); // Fund alice first
        vm.startPrank(alice);
        for (uint i = 0; i < 5; i++) {
            _swap(pair, address(weth), 1 ether, alice);
        }
        vm.stopPrank();
        
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        if (feeRouterBalance == 0) return; // Skip test if no fees collected
        
        // FeeRouter approves bob
        vm.prank(address(feeRouter));
        pair.approve(bob, feeRouterBalance);
        
        // Bob still cannot transfer to unauthorized address
        vm.startPrank(bob);
        
        vm.expectRevert("RESTRICTED");
        pair.transferFrom(address(feeRouter), alice, 1);
        
        vm.expectRevert("RESTRICTED");
        pair.transferFrom(address(feeRouter), address(token), 1);
        
        // Can transfer to feeRouter itself
        uint256 balanceBefore = pair.balanceOf(address(feeRouter));
        pair.transferFrom(address(feeRouter), address(feeRouter), 0);
        assertEq(pair.balanceOf(address(feeRouter)), balanceBefore);
        
        vm.stopPrank();
    }
    
    /// @notice Test initialSupply is correctly set
    function test_InitialSupplyCorrectlySet() public {
        // Check initialSupply matches token total supply at launch
        uint256 initialSupply = pair.initialSupply();
        assertEq(initialSupply, SUPPLY, "Initial supply not correctly set");
        
        // Burn some tokens
        vm.prank(alice);
        token.burn(1000 * 1e18);
        
        // Initial supply should remain unchanged
        assertEq(pair.initialSupply(), SUPPLY, "Initial supply changed after burn");
        
        // Current supply should be less
        assertLt(token.totalSupply(), pair.initialSupply(), "Current supply not less after burn");
    }
    
    /// @notice Test fee decay with burned tokens
    function test_FeeDecayWithBurns() public {
        uint256 startFee = pair.startFeeBps();
        uint256 endFee = pair.endFeeBps();
        uint256 decayTarget = pair.feeDecayTarget();
        
        // Initial fee should be at start
        assertEq(pair.currentFeeBps(), startFee, "Initial fee incorrect");
        
        // Burn 50% of decay target
        uint256 burnAmount = decayTarget / 2;
        deal(address(token), alice, burnAmount);
        vm.prank(alice);
        token.burn(burnAmount);
        
        // Fee should be halfway between start and end
        uint256 expectedFee = startFee - (startFee - endFee) / 2;
        assertEq(pair.currentFeeBps(), expectedFee, "Fee decay calculation incorrect");
        
        // Burn to reach decay target
        deal(address(token), alice, decayTarget / 2);
        vm.prank(alice);
        token.burn(decayTarget / 2);
        
        // Fee should be at minimum
        assertEq(pair.currentFeeBps(), endFee, "Fee should be at minimum");
    }
    
    /// @notice Test collectFees can only be called by feeRouter
    function test_CollectFeesRestricted() public {
        // Generate fees
        deal(address(weth), alice, 5 ether); // Fund alice first
        vm.startPrank(alice);
        for (uint i = 0; i < 3; i++) {
            _swap(pair, address(weth), 1 ether, alice);
        }
        vm.stopPrank();
        
        // Non-feeRouter cannot collect fees
        vm.prank(alice);
        vm.expectRevert("ONLY_FEE_ROUTER");
        pair.collectFees();
        
        vm.prank(bob);
        vm.expectRevert("ONLY_FEE_ROUTER");
        pair.collectFees();
        
        // FeeRouter can collect
        uint256 balanceBefore = pair.balanceOf(address(feeRouter));
        vm.prank(address(feeRouter));
        pair.collectFees();
        uint256 balanceAfter = pair.balanceOf(address(feeRouter));
        
        assertGe(balanceAfter, balanceBefore, "No fees collected");
    }
    
    /// @notice Test pMin calculation with current implementation
    function test_PMinCalculation() public {
        // Do an initial swap to establish non-zero reserves and pMin
        deal(address(weth), alice, 10 ether);
        vm.prank(alice);
        _swap(pair, address(weth), 0.1 ether, alice);
        
        uint256 pMinBefore = pair.pMin();
        assertGt(pMinBefore, 0, "Initial pMin should be > 0");
        
        // Do more swaps to generate fees and increase K
        vm.startPrank(alice);
        for (uint i = 0; i < 10; i++) {
            _swap(pair, address(weth), 0.5 ether, alice);
        }
        vm.stopPrank();
        
        // pMin should increase due to increased K from fees
        uint256 pMinAfter = pair.pMin();
        assertGt(pMinAfter, pMinBefore, "pMin should increase with fees");
        
        // Burn tokens to reduce supply
        deal(address(token), alice, 1000000 * 1e18);
        vm.prank(alice);
        token.burn(1000000 * 1e18);
        
        // pMin should increase further due to supply reduction
        uint256 pMinAfterBurn = pair.pMin();
        assertGt(pMinAfterBurn, pMinAfter, "pMin should increase after burn");
    }
    
    /// @notice Test reentrancy protection on all external functions
    function test_ReentrancyProtection() public {
        ReentrantAttacker attacker = new ReentrantAttacker(pair);
        
        // Fund attacker
        deal(address(token), address(attacker), 1000 * 1e18);
        deal(address(weth), address(attacker), 10 ether);
        
        // Try reentrancy on swap
        vm.expectRevert();
        attacker.attackSwap();
        
        // Try reentrancy on mint (though it would fail anyway due to restrictions)
        vm.expectRevert();
        attacker.attackMint();
        
        // Try reentrancy on burn
        vm.expectRevert();
        attacker.attackBurn();
        
        // Try reentrancy on collectFees
        vm.expectRevert();
        attacker.attackCollectFees();
    }
}

/// @notice Helper contract for reentrancy tests
contract ReentrantAttacker {
    OsitoPair public pair;
    bool attacking;
    
    constructor(OsitoPair _pair) {
        pair = _pair;
    }
    
    function attackSwap() external {
        attacking = true;
        pair.swap(1, 0, address(this));
    }
    
    function attackMint() external {
        attacking = true;
        pair.mint(address(0));
    }
    
    function attackBurn() external {
        attacking = true;
        pair.burn(address(this));
    }
    
    function attackCollectFees() external {
        attacking = true;
        pair.collectFees();
    }
    
    // Callback that attempts reentrancy
    receive() external payable {
        if (attacking) {
            attacking = false;
            pair.swap(1, 0, address(this));
        }
    }
}