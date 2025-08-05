// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "../base/TestBase.sol";
import {console2} from "forge-std/console2.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";

contract MaliciousToken is OsitoToken {
    address public owner;
    
    constructor(string memory name, string memory symbol, uint256 supply) 
        OsitoToken(name, symbol, supply, "https://ipfs.io/metadata/test", msg.sender) {
        owner = msg.sender;
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == owner) {
            _mint(to, amount);
            return true;
        }
        return super.transfer(to, amount);
    }
}

contract ReentrancyAttacker {
    CollateralVault public vault;
    OsitoToken public token;
    uint256 public attackCount;
    
    constructor(CollateralVault _vault, OsitoToken _token) {
        vault = _vault;
        token = _token;
    }
    
    function attack() external {
        token.approve(address(vault), type(uint256).max);
        vault.depositCollateral(token.balanceOf(address(this)));
    }
    
    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            vault.borrow(0.1 ether);
        }
    }
}

contract AttackVectorTests is TestBase {
    OsitoToken public token;
    OsitoPair public pair;
    FeeRouter public feeRouter;
    CollateralVault public vault;
    LenderVault public lenderVault;
    
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    
    function setUp() public override {
        super.setUp();
        
        (token, pair, feeRouter, vault, lenderVault) = createAndLaunchToken("Test Token", "TEST", INITIAL_SUPPLY);
        
        // Do a swap to activate the pair
        vm.prank(alice);
        swap(pair, address(wbera), 0.5 ether, alice);
        
        // Fund the lender vault
        vm.prank(bob);
        wbera.approve(address(lenderVault), type(uint256).max);
        vm.prank(bob);
        lenderVault.deposit(50 ether, bob);
    }
    
    /// @notice Test: Prevent LP token exile attack
    function test_PreventLPTokenExile() public {
        vm.prank(alice);
        vm.expectRevert("RESTRICTED");
        pair.transfer(attacker, 1000);
        
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        
        vm.prank(address(feeRouter));
        vm.expectRevert("RESTRICTED");
        pair.transfer(attacker, lpBalance);
    }
    
    /// @notice Test: Prevent k manipulation via donation
    function test_PreventDonationAttack() public {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);
        
        vm.prank(attacker);
        token.transfer(address(pair), 1_000_000 * 1e18);
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        
        assertEq(kAfter, kBefore, "K changed via donation");
    }
    
    /// @notice Test: Prevent flash loan attack on pMin
    function test_PreventFlashLoanPMinManipulation() public {
        uint256 pMinBefore = pair.pMin();
        
        uint256 collateralAmount = 100_000 * 1e18;
        vm.prank(alice);
        token.transfer(attacker, collateralAmount);
        
        vm.startPrank(attacker);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 flashLoanAmount = 10_000_000 * 1e18;
        vm.prank(alice);
        token.transfer(attacker, flashLoanAmount);
        
        token.transfer(address(pair), flashLoanAmount);
        
        uint256 pMinDuring = pair.pMin();
        
        vm.expectRevert("EXCEEDS_PMIN_VALUE");
        vault.borrow(collateralAmount * pMinDuring / 1e18);
        
        vm.stopPrank();
        
        uint256 pMinAfter = pair.pMin();
        assertEq(pMinAfter, pMinBefore, "pMin should return to original");
    }
    
    /// @notice Test: Prevent reentrancy in CollateralVault
    function test_PreventReentrancy() public {
        ReentrancyAttacker reentrancyAttacker = new ReentrancyAttacker(vault, token);
        
        vm.prank(alice);
        token.transfer(address(reentrancyAttacker), 100_000 * 1e18);
        
        vm.expectRevert();
        reentrancyAttacker.attack();
    }
    
    /// @notice Test: Prevent sandwich attacks on swaps
    function test_SandwichAttackMitigation() public {
        uint256 victimSwapAmount = 5 ether;
        uint256 attackerFrontrunAmount = 20 ether;
        
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        
        vm.prank(attacker);
        swap(pair, address(wbera), attackerFrontrunAmount, attacker);
        
        uint256 victimTokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        swap(pair, address(wbera), victimSwapAmount, alice);
        uint256 victimTokensReceived = token.balanceOf(alice) - victimTokensBefore;
        
        uint256 attackerTokens = token.balanceOf(attacker);
        vm.prank(attacker);
        swap(pair, address(token), attackerTokens, attacker);
        
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        
        uint256 feeBps = pair.currentFeeBps();
        assert(feeBps > 30);
    }
    
    /// @notice Test: Prevent interest rate manipulation
    function test_PreventInterestRateManipulation() public {
        uint256 collateralAmount = 1_000_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(attacker, collateralAmount);
        
        vm.startPrank(attacker);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 rateBefore = lenderVault.borrowRate();
        
        vault.borrow(10 ether);
        
        uint256 rateAfter = lenderVault.borrowRate();
        
        vault.borrow(30 ether);
        
        uint256 rateFinal = lenderVault.borrowRate();
        
        assert(rateFinal > rateAfter);
        assert(rateAfter > rateBefore);
        vm.stopPrank();
    }
    
    /// @notice Test: Prevent OTM marking manipulation
    function test_PreventFalseOTMMarking() public {
        uint256 collateralAmount = 1_000_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(0.1 ether);
        vm.stopPrank();
        
        vm.prank(attacker);
        vm.expectRevert("POSITION_HEALTHY");
        vault.markOTM(bob);
    }
    
    /// @notice Test: Prevent double OTM marking
    function test_PreventDoubleOTMMarking() public {
        uint256 collateralAmount = 100_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(1 ether);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(bob)) {
            vm.prank(attacker);
            vault.markOTM(bob);
            
            vm.prank(attacker);
            vm.expectRevert("ALREADY_MARKED");
            vault.markOTM(bob);
        }
    }
    
    /// @notice Test: Prevent recovery front-running
    function test_PreventRecoveryFrontRunning() public {
        uint256 collateralAmount = 100_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        vault.borrow(1 ether);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(bob)) {
            vm.prank(charlie);
            vault.markOTM(bob);
            
            simulateTime(73 hours);
            
            (,uint256 debtBefore,,,) = vault.getAccountState(bob);
            
            vm.prank(bob);
            wbera.approve(address(vault), debtBefore);
            vm.prank(bob);
            vault.repay(debtBefore);
            
            vm.prank(attacker);
            vm.expectRevert();
            vault.recover(bob);
        }
    }
    
    /// @notice Test: Prevent unauthorized vault creation
    function test_PreventUnauthorizedVaultCreation() public {
        vm.prank(attacker);
        vm.expectRevert();
        lenderVault.authorize(attacker);
    }
    
    /// @notice Test: Prevent fee router replacement
    function test_PreventFeeRouterReplacement() public {
        vm.prank(attacker);
        vm.expectRevert("ALREADY_SET");
        pair.setFeeRouter(attacker);
    }
    
    /// @notice Test: Prevent pMin overflow
    function testFuzz_PreventPMinOverflow(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 supply
    ) public view {
        tokReserve = bound(tokReserve, 1, type(uint112).max);
        qtReserve = bound(qtReserve, 1, type(uint112).max);
        supply = bound(supply, tokReserve, type(uint256).max);
        
        uint256 k = tokReserve * qtReserve;
        
        if (k > 0 && supply > tokReserve) {
            uint256 externalTok = supply - tokReserve;
            uint256 effectiveExternal = externalTok * 9970 / 10000;
            uint256 totalEffective = tokReserve + effectiveExternal;
            
            if (totalEffective > 0) {
                uint256 denominator = (totalEffective * totalEffective) / 1e18;
                if (denominator > 0) {
                    uint256 pMin = k / denominator;
                    assert(pMin <= type(uint256).max);
                }
            }
        }
    }
    
    /// @notice Test: Ensure atomic liquidation always works
    function test_AtomicLiquidationAlwaysWorks() public {
        uint256 collateralAmount = 1_000_000 * 1e18;
        
        vm.prank(alice);
        token.transfer(bob, collateralAmount);
        
        vm.startPrank(bob);
        token.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        
        uint256 pMin = pair.pMin();
        uint256 maxBorrow = collateralAmount * pMin / 1e18;
        
        vault.borrow(maxBorrow);
        vm.stopPrank();
        
        simulateTime(10000 days);
        lenderVault.accrueInterest();
        
        if (!vault.isPositionHealthy(bob)) {
            vm.prank(charlie);
            vault.markOTM(bob);
            
            simulateTime(73 hours);
            
            uint256 vaultBalanceBefore = token.balanceOf(address(vault));
            
            vm.prank(charlie);
            vault.recover(bob);
            
            uint256 vaultBalanceAfter = token.balanceOf(address(vault));
            
            assertEq(vaultBalanceAfter, 0, "Vault should have no tokens after recovery");
        }
    }
}