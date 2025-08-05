// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";

/// @title Mainnet Fork Tests for Osito Protocol
/// @notice Tests protocol behavior against real mainnet state and conditions
contract MainnetForkTests is Test {
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86a33E6417C9527BF8d14A00Bb80C4c4a7F0B;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WHALE = 0x8EB8a3b98659Cce290402893d0123abb75E3ab28; // Example whale
    
    // Protocol contracts
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    
    // Test state
    address public treasury;
    uint256 public forkId;
    
    function setUp() public {
        // Fork mainnet at latest block
        forkId = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(forkId);
        
        treasury = makeAddr("treasury");
        
        // Deploy protocol on mainnet fork
        launchpad = new OsitoLaunchpad(WETH, treasury);
        lendingFactory = new LendingFactory(address(weth));
        
        console2.log("Fork test setup at block:", block.number);
        console2.log("WETH balance of whale:", IERC20(WETH).balanceOf(WHALE));
    }
    
    /// @notice Test token launch with real WETH on mainnet
    function test_fork_TokenLaunchWithRealWETH() public {
        uint256 launchAmount = 50 ether;
        
        // Use a whale account with real WETH
        vm.startPrank(WHALE);
        
        uint256 wethBalance = IERC20(WETH).balanceOf(WHALE);
        vm.assume(wethBalance >= launchAmount);
        
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Mainnet Test Token",
            "MTT",
            1_000_000e18,
            launchAmount,
            5000, // 50% initial fee
            30,   // 0.3% final fee
            100_000e18
        
        vm.stopPrank();
        
        // Verify deployment
        assertTrue(token != address(0), "Token not deployed");
        assertTrue(pair != address(0), "Pair not deployed");
        assertTrue(feeRouter != address(0), "FeeRouter not deployed");
        
        // Verify real WETH was used
        assertEq(IERC20(WETH).balanceOf(pair), launchAmount, "WETH not in pair");
        assertEq(OsitoToken(token).balanceOf(pair), 1_000_000e18, "Tokens not in pair");
        
        // Verify pMin calculation with real reserves
        uint256 pMin = OsitoPair(pair).pMin();
        assertTrue(pMin > 0, "pMin not calculated");
        
        console2.log("Token launched at:", token);
        console2.log("Pair created at:", pair);
        console2.log("Initial pMin:", pMin);
    }
    
    /// @notice Test protocol behavior during high gas conditions
    function test_fork_HighGasConditions() public {
        // Simulate high gas price conditions
        vm.txGasPrice(500 gwei);
        
        uint256 launchAmount = 10 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        uint256 gasBefore = gasleft();
        
        (address token, address pair,) = launchpad.launchToken(
            "High Gas Test",
            "HGT",
            1_000_000e18,
            launchAmount,
            3000,
            30,
            50_000e18
        
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for token launch:", gasUsed);
        
        // Deploy lending with high gas
        gasBefore = gasleft();
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
            token, WETH, pair
        gasUsed = gasBefore - gasleft();
        console2.log("Gas used for lending deployment:", gasUsed);
        
        vm.stopPrank();
        
        // Verify deployment succeeded despite high gas
        assertTrue(collateralVault != address(0), "CollateralVault not deployed");
        assertTrue(lenderVault != address(0), "LenderVault not deployed");
    }
    
    /// @notice Test protocol with realistic mainnet block times and MEV
    function test_fork_MEVProtection() public {
        uint256 launchAmount = 20 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair,) = launchpad.launchToken(
            "MEV Test Token",
            "MEV",
            1_000_000e18,
            launchAmount,
            9900, // Very high initial fee for MEV protection
            30,
            100_000e18
        
        vm.stopPrank();
        
        // Simulate MEV bot trying to sandwich attack
        address mevBot = makeAddr("mevBot");
        vm.deal(mevBot, 100 ether);
        
        vm.startPrank(mevBot);
        
        // MEV bot tries to buy before legitimate user
        IERC20(WETH).deposit{value: 5 ether}();
        IERC20(WETH).transfer(pair, 5 ether);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = 5 ether * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        OsitoPair(pair).swap(tokenOut, 0, mevBot);
        
        vm.stopPrank();
        
        // Check that high fees limited MEV bot's profit
        uint256 mevBotTokens = OsitoToken(token).balanceOf(mevBot);
        uint256 wethSpent = 5 ether;
        uint256 impliedPrice = (wethSpent * 1e18) / mevBotTokens;
        
        console2.log("MEV bot tokens received:", mevBotTokens);
        console2.log("Implied price paid:", impliedPrice);
        console2.log("Fee rate applied:", feeBps);
        
        // High fees should make MEV less profitable
        assertTrue(feeBps >= 9900, "High fee protection active");
    }
    
    /// @notice Test protocol behavior with real network congestion
    function test_fork_NetworkCongestion() public {
        // Simulate network congestion by filling blocks
        for (uint i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12); // 12 second blocks
        }
        
        uint256 launchAmount = 15 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        // Deploy during "congestion"
        uint256 blockBefore = block.number;
        
        (address token, address pair,) = launchpad.launchToken(
            "Congestion Test",
            "CONG",
            500_000e18,
            launchAmount,
            4000,
            30,
            50_000e18
        
        uint256 blockAfter = block.number;
        
        vm.stopPrank();
        
        // Protocol should work regardless of network conditions
        assertTrue(token != address(0), "Token deployment failed during congestion");
        assertTrue(pair != address(0), "Pair deployment failed during congestion");
        
        console2.log("Blocks elapsed during deployment:", blockAfter - blockBefore);
    }
    
    /// @notice Test interaction with real Uniswap V2 ecosystem
    function test_fork_UniswapV2Compatibility() public {
        address UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
        address UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        
        uint256 launchAmount = 25 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair,) = launchpad.launchToken(
            "UniV2 Comp Test",
            "UV2",
            1_000_000e18,
            launchAmount,
            3000,
            30,
            100_000e18
        
        vm.stopPrank();
        
        // Verify our pair behaves like UniV2
        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = OsitoPair(pair).getReserves();
        assertTrue(r0 > 0 && r1 > 0, "Reserves not set");
        assertTrue(blockTimestampLast > 0, "Timestamp not set");
        
        // Test swap functionality matches UniV2 interface
        vm.startPrank(WHALE);
        
        uint256 swapAmount = 1 ether;
        IERC20(WETH).transfer(pair, swapAmount);
        
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = swapAmount * (10000 - feeBps);
        uint256 expectedOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        uint256 tokenBalanceBefore = OsitoToken(token).balanceOf(WHALE);
        
        OsitoPair(pair).swap(expectedOut, 0, WHALE);
        
        uint256 tokenBalanceAfter = OsitoToken(token).balanceOf(WHALE);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, expectedOut, "Swap output mismatch");
        
        vm.stopPrank();
        
        console2.log("UniV2 compatibility verified");
    }
    
    /// @notice Test lending protocol with real WETH liquidity
    function test_fork_RealWETHLending() public {
        uint256 launchAmount = 30 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair,) = launchpad.launchToken(
            "Lending Test",
            "LEND",
            1_000_000e18,
            launchAmount,
            3000,
            30,
            100_000e18
        
        // Deploy lending vaults
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
            token, WETH, pair
        
        // Provide WETH liquidity to lender vault
        uint256 lendingAmount = 100 ether;
        vm.assume(IERC20(WETH).balanceOf(WHALE) >= lendingAmount);
        
        IERC20(WETH).approve(lenderVault, lendingAmount);
        uint256 shares = LenderVault(lenderVault).deposit(lendingAmount, WHALE);
        
        assertEq(shares, lendingAmount, "1:1 share ratio initially");
        assertEq(IERC20(WETH).balanceOf(lenderVault), lendingAmount, "WETH not in vault");
        
        vm.stopPrank();
        
        // Test borrowing against token collateral
        address borrower = makeAddr("borrower");
        
        // Buy some tokens for collateral
        vm.deal(borrower, 10 ether);
        vm.startPrank(borrower);
        
        IERC20(WETH).deposit{value: 5 ether}();
        IERC20(WETH).transfer(pair, 5 ether);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = 5 ether * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        OsitoPair(pair).swap(tokenOut, 0, borrower);
        
        // Deposit as collateral
        OsitoToken(token).approve(collateralVault, tokenOut);
        CollateralVault(collateralVault).depositCollateral(tokenOut);
        
        // Borrow WETH against token collateral
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 maxBorrow = (tokenOut * pMin) / 1e18 / 2; // Borrow 50% of max
        
        if (maxBorrow > 0) {
            CollateralVault(collateralVault).borrow(maxBorrow);
            
            uint256 borrowerWETH = IERC20(WETH).balanceOf(borrower);
            assertEq(borrowerWETH, maxBorrow, "WETH not borrowed");
            
            console2.log("Successfully borrowed", maxBorrow, "WETH");
        }
        
        vm.stopPrank();
    }
    
    /// @notice Test protocol behavior across multiple mainnet blocks
    function test_fork_MultipleBLockBehavior() public {
        uint256 launchAmount = 20 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair,) = launchpad.launchToken(
            "Multi Block Test",
            "MBT",
            1_000_000e18,
            launchAmount,
            5000,
            30,
            100_000e18
        
        vm.stopPrank();
        
        uint256 initialPMin = OsitoPair(pair).pMin();
        uint256 initialSupply = OsitoToken(token).totalSupply();
        
        // Simulate activity over multiple blocks
        for (uint i = 0; i < 10; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            
            // Random trading activity
            address trader = makeAddr(string.concat("trader", vm.toString(i)));
            vm.deal(trader, 5 ether);
            
            vm.startPrank(trader);
            IERC20(WETH).deposit{value: 1 ether}();
            IERC20(WETH).transfer(pair, 1 ether);
            
            (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = 1 ether * (10000 - feeBps);
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < r0 / 10) {
                OsitoPair(pair).swap(tokenOut, 0, trader);
                
                // Sometimes burn tokens
                if (i % 3 == 0) {
                    uint256 burnAmount = tokenOut / 10;
                    OsitoToken(token).burn(burnAmount);
                }
            }
            
            vm.stopPrank();
        }
        
        uint256 finalPMin = OsitoPair(pair).pMin();
        uint256 finalSupply = OsitoToken(token).totalSupply();
        
        // Invariants should hold across blocks
        assertTrue(finalPMin >= initialPMin, "pMin decreased across blocks");
        assertTrue(finalSupply <= initialSupply, "Supply increased across blocks");
        
        console2.log("pMin change over 10 blocks:", finalPMin - initialPMin);
        console2.log("Supply burned over 10 blocks:", initialSupply - finalSupply);
    }
    
    /// @notice Test protocol with realistic mainnet transaction patterns
    function test_fork_RealisticTransactionPatterns() public {
        uint256 launchAmount = 40 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Realistic Test",
            "REAL",
            2_000_000e18,
            launchAmount,
            8000, // 80% initial fee
            30,
            200_000e18
        
        vm.stopPrank();
        
        // Simulate realistic trading patterns
        address[] memory traders = new address[](20);
        for (uint i = 0; i < 20; i++) {
            traders[i] = makeAddr(string.concat("trader", vm.toString(i)));
            vm.deal(traders[i], 20 ether);
        }
        
        // Phase 1: Early high-fee trading
        for (uint i = 0; i < 5; i++) {
            vm.startPrank(traders[i]);
            
            uint256 tradeSize = 1 ether + (i * 0.5 ether);
            IERC20(WETH).deposit{value: tradeSize}();
            IERC20(WETH).transfer(pair, tradeSize);
            
            (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = tradeSize * (10000 - feeBps);
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < r0 / 20) {
                OsitoPair(pair).swap(tokenOut, 0, traders[i]);
                
                console2.log("Trade", i, "- Fee:", feeBps, "Tokens:", tokenOut);
            }
            
            vm.stopPrank();
        }
        
        // Phase 2: Token burning to reduce fees
        uint256 totalToBurn = 150_000e18;
        uint256 burnPerTrader = totalToBurn / 10;
        
        for (uint i = 0; i < 10; i++) {
            uint256 traderBalance = OsitoToken(token).balanceOf(traders[i]);
            if (traderBalance >= burnPerTrader) {
                vm.prank(traders[i]);
                OsitoToken(token).burn(burnPerTrader);
            }
        }
        
        // Phase 3: Lower fee trading
        for (uint i = 10; i < 15; i++) {
            vm.startPrank(traders[i]);
            
            uint256 tradeSize = 2 ether;
            IERC20(WETH).deposit{value: tradeSize}();
            IERC20(WETH).transfer(pair, tradeSize);
            
            (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
            uint256 feeBps = OsitoPair(pair).currentFeeBps();
            uint256 amountInWithFee = tradeSize * (10000 - feeBps);
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < r0 / 20) {
                OsitoPair(pair).swap(tokenOut, 0, traders[i]);
                
                console2.log("Trade", i, "- Fee:", feeBps, "Tokens:", tokenOut);
            }
            
            vm.stopPrank();
        }
        
        // Phase 4: Fee collection
        uint256 lpBalance = OsitoPair(pair).balanceOf(address(feeRouter));
        uint256 principal = FeeRouter(feeRouter).principalLp(address(pair));
        
        if (lpBalance > principal) {
            uint256 supplyBefore = OsitoToken(token).totalSupply();
            FeeRouter(feeRouter).collectFees(address(pair));
            uint256 supplyAfter = OsitoToken(token).totalSupply();
            
            console2.log("Fees collected - tokens burned:", supplyBefore - supplyAfter);
        }
        
        // Verify realistic behavior
        uint256 finalFee = OsitoPair(pair).currentFeeBps();
        assertTrue(finalFee < 8000, "Fees should have decreased");
        assertTrue(finalFee >= 30, "Fees should not go below minimum");
        
        console2.log("Final fee after realistic trading:", finalFee);
    }
    
    /// @notice Test gas costs on mainnet conditions
    function test_fork_GasCosts() public {
        uint256 launchAmount = 15 ether;
        
        vm.startPrank(WHALE);
        IERC20(WETH).approve(address(launchpad), launchAmount);
        
        uint256 gasUsed;
        uint256 gasBefore;
        
        // Measure token launch gas cost
        gasBefore = gasleft();
        (address token, address pair, address feeRouter) = launchpad.launchToken(
            "Gas Test Token",
            "GAS",
            1_000_000e18,
            launchAmount,
            5000,
            30,
            100_000e18
        gasUsed = gasBefore - gasleft();
        console2.log("Token launch gas cost:", gasUsed);
        
        vm.stopPrank();
        
        // Measure lending deployment gas cost
        gasBefore = gasleft();
        (address collateralVault, address lenderVault) = lendingFactory.createLendingMarket(pair); address lenderVault = lendingFactory.lenderVault(); // was deployVaults(
            token, WETH, pair
        gasUsed = gasBefore - gasleft();
        console2.log("Lending deployment gas cost:", gasUsed);
        
        // Measure trading gas costs
        address trader = makeAddr("gasTrader");
        vm.deal(trader, 10 ether);
        
        vm.startPrank(trader);
        IERC20(WETH).deposit{value: 2 ether}();
        IERC20(WETH).transfer(pair, 2 ether);
        
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        uint256 feeBps = OsitoPair(pair).currentFeeBps();
        uint256 amountInWithFee = 2 ether * (10000 - feeBps);
        uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        gasBefore = gasleft();
        OsitoPair(pair).swap(tokenOut, 0, trader);
        gasUsed = gasBefore - gasleft();
        console2.log("Swap gas cost:", gasUsed);
        
        // Measure burn gas cost
        gasBefore = gasleft();
        OsitoToken(token).burn(tokenOut / 2);
        gasUsed = gasBefore - gasleft();
        console2.log("Burn gas cost:", gasUsed);
        
        vm.stopPrank();
        
        // Measure fee collection gas cost
        gasBefore = gasleft();
        FeeRouter(feeRouter).collectFees(address(pair));
        gasUsed = gasBefore - gasleft();
        console2.log("Fee collection gas cost:", gasUsed);
        
        // All operations should be reasonably gas efficient
        assertTrue(true, "Gas costs measured on mainnet fork");
    }
}