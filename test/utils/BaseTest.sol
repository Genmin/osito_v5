// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

abstract contract BaseTest is Test {
    // Common test addresses
    address internal constant ZERO_ADDRESS = address(0);
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    // Test users
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal keeper;
    address internal liquidator;
    
    // Common test amounts
    uint256 internal constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 internal constant INITIAL_TOKEN_BALANCE = 1_000_000e18;
    
    function setUp() public virtual {
        // Set up test users
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        keeper = makeAddr("keeper");
        liquidator = makeAddr("liquidator");
        
        // Fund test users
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);
        vm.deal(charlie, INITIAL_ETH_BALANCE);
        vm.deal(keeper, INITIAL_ETH_BALANCE);
        vm.deal(liquidator, INITIAL_ETH_BALANCE);
    }
    
    // Helper functions
    function assertApproxEqRel(uint256 a, uint256 b, uint256 maxPercentDelta, string memory err) internal pure override {
        if (b == 0) {
            require(a == 0, err);
            return;
        }
        uint256 percentDelta = ((a > b ? a - b : b - a) * 1e18) / b;
        require(percentDelta <= maxPercentDelta, err);
    }
    
    function expectEmit() internal {
        vm.expectEmit(true, true, true, true);
    }
    
    function advanceTime(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
    }
    
    function advanceBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
    }
}