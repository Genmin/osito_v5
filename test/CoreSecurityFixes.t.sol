// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/LenderVault.sol";
import "../src/core/OsitoPair.sol";
import "../src/core/OsitoToken.sol";
import "../src/core/FeeRouter.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) { return "Wrapped ETH"; }
    function symbol() public pure override returns (string memory) { return "WETH"; }
    function decimals() public pure override returns (uint8) { return 18; }
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract CoreSecurityFixesTest is Test {
    using FixedPointMathLib for uint256;
    
    // Core contracts
    MockWETH qtToken;
    OsitoToken token;
    OsitoPair pair;
    CollateralVault vault;
    LenderVault lenderVault;
    FeeRouter feeRouter;
    
    // Test accounts
    address alice = address(0x1);
    address bob = address(0x2);
    address attacker = address(0x3);
    address treasury = address(0x4);
    
    function setUp() public {
        // Deploy mock WETH
        qtToken = new MockWETH();
        
        // Create token with supply under cap
        token = new OsitoToken(
            "TestToken",
            "TEST",
            1_000_000e18,
            "",
            address(this)
        );
        
        // Create pair manually
        pair = new OsitoPair(
            address(token),
            address(qtToken),
            address(0), // feeRouter set later
            9500,       // 95% initial fee
            30,         // 0.3% final fee
            1e16,       // fee decay target
            true        // token is token0
        );
        
        // Create fee router
        feeRouter = new FeeRouter(address(pair), treasury);
        
        // Set fee router in pair
        pair.setFeeRouter(address(feeRouter));
        
        // Create lending contracts
        lenderVault = new LenderVault(address(qtToken), address(this), treasury);
        vault = new CollateralVault(address(token), address(pair), address(lenderVault));
        
        // Initialize pool
        token.transfer(address(pair), 1_000_000e18);
        qtToken.deposit{value: 1e18}();
        qtToken.transfer(address(pair), 1e18);
        pair.mint(address(0)); // Initial mint
        
        // Fund test accounts
        deal(alice, 100e18);
        deal(bob, 100e18);
        deal(attacker, 1000e18);
        
        // Give alice some tokens for testing
        vm.prank(alice);
        qtToken.deposit{value: 10e18}();
        vm.prank(alice);
        qtToken.approve(address(pair), type(uint256).max);
        vm.prank(alice);
        pair.swap(100000e18, 0, alice);
        
        // Fund lender vault
        qtToken.deposit{value: 50e18}();
        qtToken.approve(address(lenderVault), 50e18);
        lenderVault.deposit(50e18, address(this));
    }
    
    // Test 1: OTM flag clears when position becomes healthy
    function test_OTMFlagClearsOnRecovery() public {
        // Alice deposits collateral and borrows
        vm.startPrank(alice);
        token.approve(address(vault), 10000e18);
        vault.depositCollateral(10000e18);
        vault.borrow(1e16); // Small borrow
        vm.stopPrank();
        
        // Temporarily crash price
        vm.startPrank(attacker);
        qtToken.deposit{value: 50e18}();
        qtToken.approve(address(pair), 50e18);
        pair.swap(500000e18, 0, attacker);
        
        // Mark Alice's position as OTM
        vault.markOTM(alice);
        
        // Price recovers
        token.approve(address(pair), 500000e18);
        pair.swap(0, 45e18, attacker);
        vm.stopPrank();
        
        // Position is healthy now
        assertTrue(vault.isPositionHealthy(alice), "Position should be healthy");
        
        // Wait grace period
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Try to recover - should fail because _maybeClearOTM cleared the flag
        vm.expectRevert("NOT_MARKED_OTM");
        vault.recover(alice);
    }
    
    // Test 2: OTM flag clears on deposit
    function test_OTMFlagClearsOnDeposit() public {
        // Setup unhealthy position
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.depositCollateral(1000e18);
        vault.borrow(5e16);
        vm.stopPrank();
        
        // Crash price
        vm.startPrank(attacker);
        qtToken.deposit{value: 20e18}();
        qtToken.approve(address(pair), 20e18);
        pair.swap(200000e18, 0, attacker);
        
        // Mark OTM
        vault.markOTM(alice);
        vm.stopPrank();
        
        // Alice deposits more collateral
        vm.startPrank(alice);
        token.approve(address(vault), 50000e18);
        vault.depositCollateral(50000e18); // This should clear OTM flag
        vm.stopPrank();
        
        // Wait grace period
        vm.warp(block.timestamp + 72 hours + 1);
        
        // Recovery should fail
        vm.expectRevert("NOT_MARKED_OTM");
        vault.recover(alice);
    }
    
    // Test 3: Donation attack is prevented
    function test_DonationAttackPrevented() public {
        uint256 pMinBefore = pair.pMin();
        
        // Attacker tries donation attack
        vm.startPrank(attacker);
        
        // Get tokens
        qtToken.deposit{value: 10e18}();
        qtToken.approve(address(pair), 10e18);
        pair.swap(50000e18, 0, attacker);
        
        // Donate tokens and WETH to pair
        token.transfer(address(pair), 50000e18);
        qtToken.transfer(address(pair), 5e18);
        
        // Try to mint to capture donation - should fail
        vm.expectRevert("ALREADY_INITIALIZED");
        pair.mint(address(0));
        
        // Try to mint to feeRouter - should fail
        vm.expectRevert("ONLY_FEE_ROUTER");
        pair.mint(address(feeRouter));
        
        vm.stopPrank();
        
        // pMin should not decrease
        uint256 pMinAfter = pair.pMin();
        assertGe(pMinAfter, pMinBefore, "pMin should not decrease");
    }
    
    // Test 4: Supply cap is enforced
    function test_SupplyCapEnforced() public {
        // Try to create token exceeding max supply
        uint256 maxSupply = 2**111;
        
        vm.expectRevert("EXCEEDS_MAX_SUPPLY");
        new OsitoToken(
            "ExcessToken",
            "EXCESS",
            maxSupply + 1,
            "",
            address(this)
        );
        
        // Creating at max supply should work
        OsitoToken maxToken = new OsitoToken(
            "MaxToken",
            "MAX",
            maxSupply,
            "",
            address(this)
        );
        
        assertEq(maxToken.totalSupply(), maxSupply);
    }
    
    // Test 5: Mint is permanently locked
    function test_MintLocked() public {
        // Verify mintLocked is true
        assertTrue(token.mintLocked(), "Mint should be locked");
        
        // No public mint function should exist
        // Token can only be minted in constructor
        assertEq(token.totalSupply(), 1_000_000e18, "Supply should be fixed");
    }
    
    // Test 6: FeeRouter can still collect fees
    function test_FeeRouterCanCollect() public {
        // Generate trading fees
        for (uint i = 0; i < 10; i++) {
            vm.startPrank(alice);
            qtToken.deposit{value: 1e18}();
            qtToken.approve(address(pair), 1e18);
            pair.swap(5000e18, 0, alice);
            
            token.approve(address(pair), 5000e18);
            pair.swap(0, 9e17, alice);
            vm.stopPrank();
        }
        
        // FeeRouter collects fees
        vm.prank(address(feeRouter));
        pair.collectFees();
        
        // Should have some LP tokens
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        assertGt(lpBalance, 0, "FeeRouter should have LP tokens");
    }
}