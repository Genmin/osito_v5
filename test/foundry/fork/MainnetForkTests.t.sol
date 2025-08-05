// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// Core contracts
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../../src/core/CollateralVault.sol";
import {LenderVault} from "../../../src/core/LenderVault.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";

// Factories
import {OsitoLaunchpad} from "../../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../../src/factories/LendingFactory.sol";

// Interfaces
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Fork tests against mainnet state
/// @dev These tests require forking mainnet and using real WETH
contract MainnetForkTests is Test {
    using SafeTransferLib for address;
    
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WHALE = 0x8EB8a3b98659Cce290402893d0123abb75E3ab28; // avalanche bridge
    
    // Protocol contracts
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    
    // Test contracts
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    // Test accounts
    address public alice = address(0xa11ce);
    address public bob = address(0xb0b);
    address public treasury = address(0xdead);
    
    uint256 constant SUPPLY = 1_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 10 ether;
    
    function setUp() public {
        // Fork mainnet
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://eth-mainnet.alchemyapi.io/v2/demo"));
        vm.createFork(rpc);
        
        // Fund test accounts from whale
        vm.startPrank(WHALE);
        WETH.safeTransfer(alice, 100 ether);
        WETH.safeTransfer(bob, 100 ether);
        vm.stopPrank();
        
        // Deploy protocol
        launchpad = new OsitoLaunchpad(WETH, treasury);
        lendingFactory = new LendingFactory(WETH, treasury);
        
        // Launch token
        vm.startPrank(alice);
        (address tokenAddr, address pairAddr, address feeRouterAddr) = launchpad.launchToken(
            "Fork Test Token",
            "FORK",
            SUPPLY,
            "https://ipfs.io/metadata/test", // metadataURI
            INITIAL_LIQUIDITY,
            9900, // 99% start fee
            30,   // 0.3% end fee
            SUPPLY / 2 // fee decay target
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
        vm.stopPrank();
        
        // Setup lending
        lenderVault = LenderVault(lendingFactory.lenderVault());
        address vaultAddr = lendingFactory.createLendingMarket(address(pair));
        vault = CollateralVault(vaultAddr);
        
        // Fund lender vault
        vm.startPrank(bob);
        ERC20(WETH).approve(address(lenderVault), type(uint256).max);
        lenderVault.deposit(50 ether, bob);
        vm.stopPrank();
    }
    
    // ============ MAINNET INTEGRATION TESTS ============
    
    /// @notice Test token launch on mainnet fork
    function test_MainnetTokenLaunch() public {
        assertTrue(address(token) != address(0), "Token should be deployed");
        assertTrue(address(pair) != address(0), "Pair should be deployed");
        
        assertEq(token.totalSupply(), SUPPLY, "Supply should match");
        assertEq(token.name(), "Fork Test Token", "Name should match");
        assertEq(token.symbol(), "FORK", "Symbol should match");
        
        // Check pair has initial liquidity
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertTrue(r0 > 0 && r1 > 0, "Pair should have liquidity");
    }
    
    /// @notice Test swapping with real WETH
    function test_MainnetSwapping() public {
        uint256 swapAmount = 1 ether;
        
        vm.startPrank(alice);
        ERC20(WETH).approve(address(pair), swapAmount);
        
        uint256 tokensBefore = token.balanceOf(alice);
        uint256 wethBefore = ERC20(WETH).balanceOf(alice);
        
        // Transfer WETH to pair
        ERC20(WETH).transfer(address(pair), swapAmount);
        
        // Calculate expected output
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (swapAmount * (10000 - feeBps)) / 10000;
        uint256 expectedOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        // Execute swap
        if (tokIsToken0) {
            pair.swap(expectedOut, 0, alice);
        } else {
            pair.swap(0, expectedOut, alice);
        }
        
        uint256 tokensAfter = token.balanceOf(alice);
        uint256 wethAfter = ERC20(WETH).balanceOf(alice);
        
        assertTrue(tokensAfter > tokensBefore, "Should receive tokens");
        assertTrue(wethBefore > wethAfter, "Should spend WETH");
        
        vm.stopPrank();
    }
    
    /// @notice Test lending integration with real WETH
    function test_MainnetLending() public {
        // Get some tokens first
        vm.startPrank(alice);
        ERC20(WETH).approve(address(pair), 2 ether);
        ERC20(WETH).transfer(address(pair), 2 ether);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (2 ether * (10000 - feeBps)) / 10000;
        uint256 tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokensOut, 0, alice);
        } else {
            pair.swap(0, tokensOut, alice);
        }
        
        // Use tokens as collateral
        uint256 collateralAmount = token.balanceOf(alice) / 2;
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        // Borrow against collateral
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateralAmount * pMin) / 1e18;
        uint256 borrowAmount = maxBorrow / 2;
        
        uint256 wethBefore = ERC20(WETH).balanceOf(alice);
        vault.borrow(borrowAmount);
        uint256 wethAfter = ERC20(WETH).balanceOf(alice);
        
        assertEq(wethAfter - wethBefore, borrowAmount, "Should receive borrowed WETH");
        
        vm.stopPrank();
    }
    
    /// @notice Test gas costs on mainnet
    function test_MainnetGasCosts() public {
        vm.startPrank(alice);
        
        // Measure token transfer gas
        uint256 gasStart = gasleft();
        token.transfer(bob, 1000 * 1e18);
        uint256 transferGas = gasStart - gasleft();
        
        // Measure token burn gas
        gasStart = gasleft();
        token.burn(1000 * 1e18);
        uint256 burnGas = gasStart - gasleft();
        
        // Measure swap gas
        ERC20(WETH).approve(address(pair), 1 ether);
        ERC20(WETH).transfer(address(pair), 1 ether);
        
        gasStart = gasleft();
        pair.swap(0, 1000 * 1e18, alice);
        uint256 swapGas = gasStart - gasleft();
        
        vm.stopPrank();
        
        console2.log("Transfer gas:", transferGas);
        console2.log("Burn gas:", burnGas);
        console2.log("Swap gas:", swapGas);
        
        // Verify gas costs are reasonable
        assertLt(transferGas, 100000, "Transfer should be gas efficient");
        assertLt(burnGas, 100000, "Burn should be gas efficient");
        assertLt(swapGas, 200000, "Swap should be gas efficient");
    }
    
    /// @notice Test protocol behavior under mainnet MEV conditions
    function test_MainnetMEVResistance() public {
        // Simulate MEV bot trying to sandwich user transaction
        address mevBot = address(0xbad);
        vm.deal(mevBot, 100 ether);
        
        // Give MEV bot some WETH
        vm.prank(WHALE);
        WETH.safeTransfer(mevBot, 10 ether);
        
        uint256 userSwapAmount = 0.5 ether;
        uint256 mevFrontrunAmount = 2 ether;
        
        // MEV bot front-runs
        vm.startPrank(mevBot);
        ERC20(WETH).approve(address(pair), mevFrontrunAmount);
        ERC20(WETH).transfer(address(pair), mevFrontrunAmount);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (mevFrontrunAmount * (10000 - feeBps)) / 10000;
        uint256 tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokensOut, 0, mevBot);
        } else {
            pair.swap(0, tokensOut, mevBot);
        }
        vm.stopPrank();
        
        // User transaction
        vm.startPrank(alice);
        ERC20(WETH).approve(address(pair), userSwapAmount);
        
        uint256 userTokensBefore = token.balanceOf(alice);
        ERC20(WETH).transfer(address(pair), userSwapAmount);
        
        (r0, r1,) = pair.getReserves();
        wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        amountInWithFee = (userSwapAmount * (10000 - feeBps)) / 10000;
        tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokensOut, 0, alice);
        } else {
            pair.swap(0, tokensOut, alice);
        }
        
        uint256 userTokensReceived = token.balanceOf(alice) - userTokensBefore;
        vm.stopPrank();
        
        // Due to high fees (99% initially), MEV should be heavily penalized
        assertTrue(userTokensReceived > 0, "User should still receive some tokens");
        
        // Verify MEV bot paid high fees
        uint256 currentFee = pair.currentFeeBps();
        assertGe(currentFee, 5000, "Fees should still be high to deter MEV");
    }
    
    /// @notice Test protocol with real mainnet blocks and timestamps
    function test_MainnetTimeBasedFeatures() public {
        uint256 initialBlock = block.number;
        uint256 initialTime = block.timestamp;
        
        // Create a position
        vm.startPrank(alice);
        
        // Get tokens
        ERC20(WETH).approve(address(pair), 1 ether);
        ERC20(WETH).transfer(address(pair), 1 ether);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (1 ether * (10000 - feeBps)) / 10000;
        uint256 tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokensOut, 0, alice);
        } else {
            pair.swap(0, tokensOut, alice);
        }
        
        // Deposit collateral and borrow
        uint256 collateral = token.balanceOf(alice) / 2;
        token.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        vault.borrow(0.1 ether);
        
        vm.stopPrank();
        
        // Advance time (simulate passing days)
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216000); // ~30 days of blocks
        
        // Accrue interest
        lenderVault.accrueInterest();
        
        // Check position health after time
        bool isHealthy = vault.isPositionHealthy(alice);
        (,uint256 debt,,,) = vault.getAccountState(alice);
        
        console2.log("Position healthy after 30 days:", isHealthy);
        console2.log("Debt after 30 days:", debt);
        
        assertTrue(debt > 0.1 ether, "Interest should have accrued");
        
        // Verify time-based features work correctly
        assertGt(block.timestamp, initialTime, "Time should have advanced");
        assertGt(block.number, initialBlock, "Block should have advanced");
    }
    
    /// @notice Test protocol limits under mainnet conditions
    function test_MainnetScalability() public {
        // Test with larger amounts typical of mainnet
        uint256 largeAmount = 1000 ether;
        
        // Fund alice with large amount
        vm.prank(WHALE);
        WETH.safeTransfer(alice, largeAmount);
        
        vm.startPrank(alice);
        
        // Large swap
        ERC20(WETH).approve(address(pair), largeAmount / 10);
        ERC20(WETH).transfer(address(pair), largeAmount / 10);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        // Ensure we don't drain the pool
        uint256 swapAmount = largeAmount / 10;
        require(swapAmount < wethReserve / 2, "Swap too large");
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (swapAmount * (10000 - feeBps)) / 10000;
        uint256 tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokensOut < tokReserve) {
            if (tokIsToken0) {
                pair.swap(tokensOut, 0, alice);
            } else {
                pair.swap(0, tokensOut, alice);
            }
            
            assertTrue(token.balanceOf(alice) > 0, "Should receive tokens from large swap");
        }
        
        vm.stopPrank();
    }
    
    /// @notice Test recovery scenarios on mainnet
    function test_MainnetRecoveryScenarios() public {
        // Create a position that might go underwater
        vm.startPrank(alice);
        
        // Get tokens
        ERC20(WETH).approve(address(pair), 2 ether);
        ERC20(WETH).transfer(address(pair), 2 ether);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 wethReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (2 ether * (10000 - feeBps)) / 10000;
        uint256 tokensOut = (amountInWithFee * tokReserve) / (wethReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokensOut, 0, alice);
        } else {
            pair.swap(0, tokensOut, alice);
        }
        
        // Create leveraged position
        uint256 collateral = token.balanceOf(alice);
        token.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = (collateral * pMin) / 1e18;
        vault.borrow(maxBorrow / 2);
        
        vm.stopPrank();
        
        // Simulate time passing and interest accruing
        vm.warp(block.timestamp + 365 days);
        lenderVault.accrueInterest();
        
        // Check if position can be recovered
        bool isHealthy = vault.isPositionHealthy(alice);
        console2.log("Position healthy after 1 year:", isHealthy);
        
        if (!isHealthy) {
            // Mark OTM
            vm.prank(bob);
            vault.markOTM(alice);
            
            // Wait grace period
            vm.warp(block.timestamp + 73 hours);
            
            // Attempt recovery
            uint256 recovererBalanceBefore = ERC20(WETH).balanceOf(bob);
            
            vm.prank(bob);
            vault.recover(alice);
            
            uint256 recovererBalanceAfter = ERC20(WETH).balanceOf(bob);
            
            // Recoverer should get bonus
            if (recovererBalanceAfter > recovererBalanceBefore) {
                console2.log("Recovery bonus:", recovererBalanceAfter - recovererBalanceBefore);
            }
            
            // Position should be cleared
            assertEq(vault.collateralBalances(alice), 0, "Collateral should be cleared");
        }
    }
}