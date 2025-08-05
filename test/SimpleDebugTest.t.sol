// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {OsitoLaunchpad} from "../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../src/factories/LendingFactory.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockWBERA is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped BERA";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WBERA";
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }
}

contract SimpleDebugTest is Test {
    MockWBERA public wbera;
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    
    address public alice = address(0x1);
    address public treasury = address(0xdead);
    
    function setUp() public {
        console2.log("Creating WBERA...");
        wbera = new MockWBERA();
        
        console2.log("Creating Launchpad...");
        launchpad = new OsitoLaunchpad(address(wbera), treasury);
        
        console2.log("Creating LendingFactory...");
        lendingFactory = new LendingFactory(address(wbera), treasury);
        
        console2.log("Setup complete");
    }
    
    function test_SimpleSetup() public view {
        assertEq(address(launchpad.weth()), address(wbera));
        assertEq(address(lendingFactory.lenderVault()) != address(0), true);
    }
    
    function test_LaunchToken() public {
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        
        // Get some WBERA
        wbera.deposit{value: 10 ether}();
        
        // Approve launchpad
        wbera.approve(address(launchpad), 1 ether);
        
        // Launch token
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Test Token",
            "TEST",
            1_000_000 * 1e18,
            1 ether,  // wethAmount for initial liquidity
            9900,     // startFeeBps (99%)
            30,       // endFeeBps (0.3%)
            100_000 * 1e18  // feeDecayTarget
        );
        
        console2.log("Token:", token);
        console2.log("Pair:", pair);
        console2.log("FeeRouter:", feeRouter);
        
        assertTrue(token != address(0));
        assertTrue(pair != address(0));
        assertTrue(feeRouter != address(0));
        
        vm.stopPrank();
    }
}