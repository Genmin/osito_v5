// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {OsitoPair} from "../src/core/OsitoPair.sol";
import {OsitoToken} from "../src/core/OsitoToken.sol";
import {FeeRouter} from "../src/core/FeeRouter.sol";
import {CollateralVault} from "../src/core/CollateralVault.sol";
import {LenderVault} from "../src/core/LenderVault.sol";
import {OsitoLaunchpad} from "../src/factories/OsitoLaunchpad.sol";

contract MockQT is ERC20 {
    function name() public pure override returns (string memory) { return "Quote Token"; }
    function symbol() public pure override returns (string memory) { return "QT"; }
    function decimals() public pure override returns (uint8) { return 18; }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SecurityFixTests is Test {
    OsitoLaunchpad launchpad;
    OsitoToken token;
    OsitoPair pair;
    FeeRouter feeRouter;
    MockQT qt;
    
    address treasury = address(0x1337);
    address deployer = address(this);
    address attacker = address(0xBEEF);
    address user = address(0xCAFE);
    
    function setUp() public {
        qt = new MockQT();
        
        // Deploy Osito infrastructure
        launchpad = new OsitoLaunchpad(address(qt), treasury);
        
        // Mint and approve QT for launchpad
        qt.mint(deployer, 100000 * 1e18);
        qt.approve(address(launchpad), 100000 * 1e18);
        
        // Launch a token
        (address tokenAddr, address pairAddr, address routerAddr) = launchpad.launchToken(
            "Test Token",
            "TEST",
            1000000 * 1e18,
            100000 * 1e18,
            9900,  // 99% start fee
            30,    // 0.3% end fee
            300000 * 1e18  // fee decay target
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(routerAddr);
        
        // Give attacker and user some funds
        qt.mint(attacker, 10000 * 1e18);
        qt.mint(user, 10000 * 1e18);
    }
    
    // Test 1: Verify donation attack is prevented (no sync/skim)
    function testDonationAttackPrevented() public {
        // Try to call sync() - should fail as function doesn't exist
        (bool success,) = address(pair).call(abi.encodeWithSignature("sync()"));
        assertFalse(success, "sync() should not exist");
        
        // Try to call skim() - should fail as function doesn't exist  
        (success,) = address(pair).call(abi.encodeWithSignature("skim(address)", attacker));
        assertFalse(success, "skim() should not exist");
    }
    
    // Test 2: FeeRouter patch - LP token restriction
    function testLpTokenRestriction() public {
        // FeeRouter should be able to receive LP tokens
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        assertEq(lpBalance, 0, "FeeRouter should start with 0 LP");
        
        // Generate some fees through swaps
        vm.startPrank(user);
        qt.approve(address(pair), type(uint256).max);
        
        // Do a swap to generate fees
        qt.transfer(address(pair), 100 * 1e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = 100 * 1e18 * (10000 - feeBps) / 10000;
        uint256 tokOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokOut, 0, user);
        } else {
            pair.swap(0, tokOut, user);
        }
        vm.stopPrank();
        
        // Collect fees
        feeRouter.collectFees();
        
        // Verify LP is handled correctly (FeeRouter should burn all LP it receives)
        uint256 lpBalanceAfter = pair.balanceOf(address(feeRouter));
        assertEq(lpBalanceAfter, 0, "FeeRouter should have 0 LP after collection");
    }
    
    // Test 3: No phantom fee extraction
    function testNoPhantomFees() public {
        // Generate real fees
        vm.startPrank(user);
        qt.approve(address(pair), type(uint256).max);
        qt.transfer(address(pair), 100 * 1e18);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = 100 * 1e18 * (10000 - feeBps) / 10000;
        uint256 tokOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
        
        if (tokIsToken0) {
            pair.swap(tokOut, 0, user);
        } else {
            pair.swap(0, tokOut, user);
        }
        vm.stopPrank();
        
        // Collect fees once
        feeRouter.collectFees();
        uint256 qtAfter = qt.balanceOf(treasury);
        
        // Try to collect again without new swaps - should not extract more
        vm.roll(block.number + 1);
        feeRouter.collectFees();
        
        assertEq(qt.balanceOf(treasury), qtAfter, "No phantom fees should be extracted");
    }
    
    // Test 4: transferFrom restriction prevents LP exile
    function testTransferFromRestriction() public {
        // Setup: Router has LP tokens
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        assertGt(lpBalance, 0, "Router should have LP");
        
        // Attacker tries to get approval and transfer LP tokens
        vm.startPrank(address(feeRouter));
        pair.approve(attacker, lpBalance);
        vm.stopPrank();
        
        // Attacker tries to pull LP tokens using transferFrom
        vm.startPrank(attacker);
        vm.expectRevert("RESTRICTED");
        pair.transferFrom(address(feeRouter), attacker, lpBalance);
        vm.stopPrank();
        
        // Verify LP tokens remain with router
        assertEq(pair.balanceOf(address(feeRouter)), lpBalance, "LP should remain with router");
    }
    
    // Test 5: CollateralVault dust position gas grief prevention
    function testDustPositionGasPrevention() public {
        // Deploy lending infrastructure
        LenderVault lenderVault = new LenderVault(address(qt), address(launchpad), treasury);
        CollateralVault collateralVault = new CollateralVault(
            address(token),
            address(pair),
            address(lenderVault)
        );
        
        // Setup: Add liquidity to lender vault
        vm.startPrank(user);
        qt.approve(address(lenderVault), type(uint256).max);
        lenderVault.deposit(1000 * 1e18, user);
        vm.stopPrank();
        
        // Create a dust position that would result in qtOut = 0
        address dustUser = address(0xDEAD);
        vm.deal(dustUser, 1 ether);
        
        // Give dust user a tiny amount of collateral (1 wei of TOK)
        vm.startPrank(address(pair));
        token.transfer(dustUser, 1);
        vm.stopPrank();
        
        vm.startPrank(dustUser);
        token.approve(address(collateralVault), 1);
        collateralVault.depositCollateral(1);
        
        // Borrow tiny amount (will create dust debt)
        uint256 pMin = pair.pMin();
        if (pMin > 0) {
            uint256 maxBorrow = pMin / 1e18; // Dust amount
            if (maxBorrow > 0) {
                collateralVault.borrow(1);
            }
        }
        vm.stopPrank();
        
        // Mark position as OTM
        vm.warp(block.timestamp + 1);
        collateralVault.markOTM(dustUser);
        
        // Wait for grace period
        vm.warp(block.timestamp + 73 hours);
        
        // Try to recover - should revert with DUST_POSITION if qtOut would be 0
        if (collateralVault.collateralBalances(dustUser) == 1) {
            vm.expectRevert("DUST_POSITION");
            collateralVault.recover(dustUser);
        }
    }
    
    // Test 6: Verify k remains monotonic after fee collection
    function testMonotonicK() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);
        
        // Generate fees through multiple swaps
        for (uint i = 0; i < 5; i++) {
            vm.startPrank(user);
            qt.approve(address(pair), type(uint256).max);
            qt.transfer(address(pair), 10 * 1e18);
            
            (r0, r1,) = pair.getReserves();
            bool tokIsToken0 = pair.tokIsToken0();
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = 10 * 1e18 * (10000 - feeBps) / 10000;
            uint256 tokOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
            
            if (tokIsToken0) {
                pair.swap(tokOut, 0, user);
            } else {
                pair.swap(0, tokOut, user);
            }
            vm.stopPrank();
            
            // Collect fees after each swap
            feeRouter.collectFees();
            
            // Verify k has not decreased
            (r0, r1,) = pair.getReserves();
            uint256 kAfter = uint256(r0) * uint256(r1);
            assertGe(kAfter, kBefore, "k should be monotonically increasing");
            kBefore = kAfter;
        }
    }
    
    // Test 7: Verify pMin monotonically increases
    function testMonotonicPMin() public {
        uint256 pMinBefore = pair.pMin();
        
        // Generate activity and collect fees
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(user);
            qt.approve(address(pair), type(uint256).max);
            qt.transfer(address(pair), 50 * 1e18);
            
            (uint112 r0, uint112 r1,) = pair.getReserves();
            bool tokIsToken0 = pair.tokIsToken0();
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = 50 * 1e18 * (10000 - feeBps) / 10000;
            uint256 tokOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
            
            if (tokOut > 0) {
                if (tokIsToken0) {
                    pair.swap(tokOut, 0, user);
                } else {
                    pair.swap(0, tokOut, user);
                }
            }
            vm.stopPrank();
            
            feeRouter.collectFees();
            
            uint256 pMinAfter = pair.pMin();
            assertGe(pMinAfter, pMinBefore, "pMin should be monotonically increasing");
            pMinBefore = pMinAfter;
        }
    }
}