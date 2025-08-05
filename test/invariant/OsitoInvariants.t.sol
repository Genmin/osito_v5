// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "../base/TestBase.sol";
import {console2} from "forge-std/console2.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

contract InvariantHandler is TestBase {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 public lastPMin;
    uint256 public lastK;
    uint256 public lastSupply;
    
    address[] public actors;
    mapping(address => uint256) public collateralDeposits;
    mapping(address => uint256) public borrowAmounts;
    
    constructor(
        OsitoToken _token,
        OsitoPair _pair,
        FeeRouter _feeRouter,
        CollateralVault _vault,
        LenderVault _lenderVault
    ) {
        token = _token;
        pair = _pair;
        feeRouter = _feeRouter;
        vault = _vault;
        lenderVault = _lenderVault;
        
        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);
        
        lastPMin = pair.pMin();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        lastK = uint256(r0) * uint256(r1);
        lastSupply = token.totalSupply();
    }
    
    function swap(uint256 actorSeed, uint256 amountSeed, bool isBuy) public {
        address actor = actors[actorSeed % actors.length];
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        if (isBuy) {
            uint256 maxAmount = qtReserve / 10;
            uint256 amount = bound(amountSeed, 1000, maxAmount);
            
            if (wbera.balanceOf(actor) < amount) {
                deal(address(wbera), actor, amount);
            }
            
            vm.prank(actor);
            wbera.transfer(address(pair), amount);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = amount * (10000 - feeBps) / 10000;
            uint256 tokOut = (amountInWithFee * tokReserve) / (qtReserve + amountInWithFee);
            
            if (tokIsToken0) {
                vm.prank(actor);
                pair.swap(tokOut, 0, actor);
            } else {
                vm.prank(actor);
                pair.swap(0, tokOut, actor);
            }
        } else {
            uint256 maxAmount = token.balanceOf(actor);
            if (maxAmount == 0) return;
            
            uint256 amount = bound(amountSeed, 1, maxAmount);
            
            vm.prank(actor);
            token.transfer(address(pair), amount);
            
            uint256 feeBps = pair.currentFeeBps();
            uint256 amountInWithFee = amount * (10000 - feeBps) / 10000;
            uint256 qtOut = (amountInWithFee * qtReserve) / (tokReserve + amountInWithFee);
            
            if (tokIsToken0) {
                vm.prank(actor);
                pair.swap(0, qtOut, actor);
            } else {
                vm.prank(actor);
                pair.swap(qtOut, 0, actor);
            }
        }
    }
    
    function collectFees() public {
        vm.prank(keeper);
        feeRouter.collectFees();
    }
    
    function depositCollateral(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 maxAmount = token.balanceOf(actor);
        
        if (maxAmount == 0) return;
        
        uint256 amount = bound(amountSeed, 1, maxAmount);
        
        vm.startPrank(actor);
        token.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();
        
        collateralDeposits[actor] += amount;
    }
    
    function borrow(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 collateral = vault.collateralBalances(actor);
        
        if (collateral == 0) return;
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = collateral * pMin / 1e18;
        
        (uint256 principal,) = vault.accountBorrows(actor);
        uint256 currentDebt = principal;
        
        if (currentDebt >= maxBorrow) return;
        
        uint256 availableBorrow = maxBorrow - currentDebt;
        uint256 amount = bound(amountSeed, 0, availableBorrow);
        
        if (amount == 0) return;
        
        vm.prank(actor);
        vault.borrow(amount);
        
        borrowAmounts[actor] += amount;
    }
    
    function repay(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        
        (uint256 principal,) = vault.accountBorrows(actor);
        if (principal == 0) return;
        
        uint256 maxRepay = wbera.balanceOf(actor);
        if (maxRepay == 0) return;
        
        uint256 amount = bound(amountSeed, 1, min(principal, maxRepay));
        
        vm.startPrank(actor);
        wbera.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();
        
        borrowAmounts[actor] = borrowAmounts[actor] > amount ? borrowAmounts[actor] - amount : 0;
    }
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract OsitoInvariantsTest is StdInvariant, TestBase {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    InvariantHandler public handler;
    
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    function setUp() public override {
        super.setUp();
        
        (token, pair, feeRouter, vault, lenderVault) = createAndLaunchToken("Test Token", "TEST", INITIAL_SUPPLY);
        
        // Do initial swaps to distribute tokens
        vm.prank(alice);
        swap(pair, address(wbera), 0.5 ether, alice);
        
        vm.prank(bob);
        swap(pair, address(wbera), 0.3 ether, bob);
        
        vm.prank(charlie);
        swap(pair, address(wbera), 0.2 ether, charlie);
        
        // Fund the lender vault
        vm.prank(bob);
        wbera.approve(address(lenderVault), type(uint256).max);
        vm.prank(bob);
        lenderVault.deposit(50 ether, bob);
        
        handler = new InvariantHandler(token, pair, feeRouter, vault, lenderVault);
        
        targetContract(address(handler));
        
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = InvariantHandler.swap.selector;
        selectors[1] = InvariantHandler.collectFees.selector;
        selectors[2] = InvariantHandler.depositCollateral.selector;
        selectors[3] = InvariantHandler.borrow.selector;
        selectors[4] = InvariantHandler.repay.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }
    
    /// @notice CRITICAL INVARIANT: pMin must never decrease
    function invariant_pMinNeverDecreases() public view {
        uint256 currentPMin = pair.pMin();
        assert(currentPMin >= handler.lastPMin());
    }
    
    /// @notice CRITICAL INVARIANT: k must never decrease (except for impermanent loss protection)
    function invariant_kNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        assert(currentK >= handler.lastK());
    }
    
    /// @notice CRITICAL INVARIANT: Total supply can only decrease (via burns)
    function invariant_totalSupplyOnlyDecreases() public view {
        uint256 currentSupply = token.totalSupply();
        assert(currentSupply <= handler.lastSupply());
    }
    
    /// @notice CRITICAL INVARIANT: All borrows must be <= pMin valuation
    function invariant_borrowsWithinPMinLimit() public view {
        uint256 pMin = pair.pMin();
        
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = vault.collateralBalances(actor);
            
            if (collateral > 0) {
                (uint256 principal,) = vault.accountBorrows(actor);
                uint256 maxBorrow = collateral * pMin / 1e18;
                assert(principal <= maxBorrow);
            }
        }
    }
    
    /// @notice CRITICAL INVARIANT: Recovery always covers principal
    function invariant_recoveryAlwaysCoversPrincipal() public {
        uint256 pMin = pair.pMin();
        
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;
        
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 collateral = vault.collateralBalances(actor);
            
            if (collateral > 0) {
                (uint256 principal,) = vault.accountBorrows(actor);
                
                if (principal > 0) {
                    uint256 guaranteedRecovery = collateral * pMin / 1e18;
                    assert(guaranteedRecovery >= principal);
                }
            }
        }
    }
    
    /// @notice INVARIANT: Token conservation (no tokens created from thin air)
    function invariant_tokenConservation() public view {
        uint256 totalInPair = token.balanceOf(address(pair));
        uint256 totalInVault = token.balanceOf(address(vault));
        uint256 totalInUsers = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie);
        uint256 totalInFeeRouter = token.balanceOf(address(feeRouter));
        
        uint256 totalAccountedFor = totalInPair + totalInVault + totalInUsers + totalInFeeRouter;
        
        assert(totalAccountedFor <= INITIAL_SUPPLY);
    }
    
    /// @notice INVARIANT: LP tokens can only be held by FeeRouter or burned
    function invariant_lpTokenRestriction() public view {
        uint256 totalLpSupply = pair.totalSupply();
        uint256 feeRouterBalance = pair.balanceOf(address(feeRouter));
        uint256 deadBalance = pair.balanceOf(address(0xdead));
        
        assert(feeRouterBalance + deadBalance + 1000 >= totalLpSupply);
    }
    
    /// @notice INVARIANT: Lender vault always solvent
    function invariant_lenderVaultSolvency() public view {
        uint256 totalAssets = lenderVault.totalAssets();
        uint256 totalShares = lenderVault.totalSupply();
        
        if (totalShares > 0) {
            assert(totalAssets > 0);
        }
    }
}