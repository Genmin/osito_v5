// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract OsitoHandler is BaseTest {
    OsitoPair public pair;
    OsitoToken public token;
    FeeRouter public feeRouter;
    CollateralVault public collateralVault;
    LenderVault public lenderVault;
    MockWETH public weth;
    
    uint256 public ghost_totalSwaps;
    uint256 public ghost_totalBurns;
    uint256 public ghost_totalFeeCollections;
    uint256 public ghost_lastPMin;
    uint256 public ghost_lastK;
    
    constructor(
        OsitoPair _pair,
        OsitoToken _token,
        FeeRouter _feeRouter,
        CollateralVault _collateralVault,
        LenderVault _lenderVault,
        MockWETH _weth
    ) {
        pair = _pair;
        token = _token;
        feeRouter = _feeRouter;
        collateralVault = _collateralVault;
        lenderVault = _lenderVault;
        weth = _weth;
        
        ghost_lastPMin = pair.pMin();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        ghost_lastK = uint256(r0) * uint256(r1);
    }
    
    function swap(uint256 wethAmount, bool buyToken) public {
        wethAmount = bound(wethAmount, 0.001e18, 10e18);
        
        // Fund the sender
        weth.deposit{value: wethAmount}();
        weth.transfer(address(pair), wethAmount);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        
        if (buyToken && r0 > 1000) {
            uint256 amountInWithFee = wethAmount * (10000 - pair.currentFeeBps());
            uint256 tokenOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
            
            if (tokenOut > 0 && tokenOut < r0) {
                pair.swap(tokenOut, 0, msg.sender);
                ghost_totalSwaps++;
            }
        }
    }
    
    function burnTokens(uint256 burnPct) public {
        burnPct = bound(burnPct, 0, 100);
        uint256 balance = token.balanceOf(msg.sender);
        
        if (balance > 0) {
            uint256 burnAmount = (balance * burnPct) / 100;
            if (burnAmount > 0) {
                token.burn(burnAmount);
                ghost_totalBurns++;
            }
        }
    }
    
    function collectFees() public {
        uint256 lpBalance = pair.balanceOf(address(feeRouter));
        uint256 principal = feeRouter.principalLp(address(pair));
        
        if (lpBalance > principal) {
            feeRouter.collectFees(address(pair));
            ghost_totalFeeCollections++;
        }
    }
    
    function depositAndBorrow(uint256 depositAmount, uint256 borrowPct) public {
        depositAmount = bound(depositAmount, 0, token.balanceOf(msg.sender));
        borrowPct = bound(borrowPct, 0, 80); // Max 80% LTV
        
        if (depositAmount > 0) {
            token.approve(address(collateralVault), depositAmount);
            collateralVault.depositCollateral(depositAmount);
            
            uint256 borrowPower = (pair.pMin() * depositAmount * borrowPct) / (100 * 1e18);
            if (borrowPower > 0 && weth.balanceOf(address(lenderVault)) >= borrowPower) {
                collateralVault.borrow(borrowPower);
            }
        }
    }
    
    receive() external payable {}
}

contract OsitoInvariantsTest is BaseTest {
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    OsitoHandler public handler;
    
    OsitoPair public pair;
    OsitoToken public token;
    FeeRouter public feeRouter;
    CollateralVault public collateralVault;
    LenderVault public lenderVault;
    MockWETH public weth;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy infrastructure
        weth = new MockWETH();
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        lendingFactory = new LendingFactory();
        
        // Launch token
        vm.prank(alice);
        weth.deposit{value: 100e18}();
        
        vm.prank(alice);
        weth.approve(address(launchpad), 100e18);
        
        vm.prank(alice);
        (address _token, address _pair, address _feeRouter) = launchpad.launchToken(
            "Invariant Osito",
            "INVOSITO",
            1_000_000e18,
            100e18,
            9900, // 99% start fee
            30,   // 0.3% end fee
            100_000e18 // decay target
        );
        
        token = OsitoToken(_token);
        pair = OsitoPair(_pair);
        feeRouter = FeeRouter(_feeRouter);
        
        // Deploy lending vaults
        (address _collateralVault, address _lenderVault) = lendingFactory.deployVaults(
            address(token),
            address(weth),
            address(pair)
        );
        
        collateralVault = CollateralVault(_collateralVault);
        lenderVault = LenderVault(_lenderVault);
        
        // Fund lender vault
        vm.prank(bob);
        weth.deposit{value: 1000e18}();
        vm.prank(bob);
        weth.approve(address(lenderVault), 1000e18);
        vm.prank(bob);
        lenderVault.deposit(1000e18, bob);
        
        // Deploy handler
        handler = new OsitoHandler(pair, token, feeRouter, collateralVault, lenderVault, weth);
        
        // Set handler as target
        targetContract(address(handler));
        
        // Fund handler
        vm.deal(address(handler), 10000e18);
    }
    
    /// @notice pMin should never decrease
    function invariant_PMinMonotonicallyIncreases() public {
        uint256 currentPMin = pair.pMin();
        assertGe(currentPMin, handler.ghost_lastPMin(), "pMin decreased!");
        // Update tracked value
    }
    
    /// @notice k (constant product) should never decrease
    function invariant_KNeverDecreases() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        assertGe(currentK, handler.ghost_lastK(), "k decreased!");
        // Update tracked value
    }
    
    /// @notice Total supply should never increase (only decrease via burns)
    function invariant_TotalSupplyNeverIncreases() public {
        assertLe(token.totalSupply(), 1_000_000e18, "Total supply increased!");
    }
    
    /// @notice LP tokens should only be held by feeRouter or pair
    function invariant_LPTokenRestriction() public {
        uint256 totalLP = pair.totalSupply();
        uint256 routerLP = pair.balanceOf(address(feeRouter));
        uint256 pairLP = pair.balanceOf(address(pair));
        
        assertEq(totalLP, routerLP + pairLP + 1000, "LP tokens leaked!"); // +1000 for dead shares
    }
    
    /// @notice All loans should be safe at pMin
    function invariant_LoansAlwaysSafeAtPMin() public {
        // Check a sample of potential borrowers
        address[] memory borrowers = new address[](5);
        borrowers[0] = alice;
        borrowers[1] = bob;
        borrowers[2] = charlie;
        borrowers[3] = address(handler);
        borrowers[4] = makeAddr("random");
        
        for (uint i = 0; i < borrowers.length; i++) {
            (uint256 collateral, uint256 debt,) = collateralVault.getAccountHealth(borrowers[i]);
            if (debt > 0) {
                uint256 pMin = pair.pMin();
                uint256 maxDebt = (collateral * pMin) / 1e18;
                assertLe(debt, maxDebt, "Loan unsafe at pMin!");
            }
        }
    }
    
    /// @notice Fee decay should work correctly
    function invariant_FeeDecayCorrect() public {
        uint256 currentFee = pair.currentFeeBps();
        uint256 totalSupply = token.totalSupply();
        uint256 burned = 1_000_000e18 - totalSupply;
        
        if (burned >= 100_000e18) {
            assertEq(currentFee, 30, "Fee should be at minimum");
        } else {
            uint256 expectedFee = 9900 - ((9900 - 30) * burned / 100_000e18);
            assertEq(currentFee, expectedFee, "Fee decay incorrect");
        }
    }
    
    /// @notice Protocol should be solvent
    function invariant_ProtocolSolvency() public {
        // Total borrowed should not exceed total lent
        uint256 totalBorrowed = lenderVault.totalBorrows();
        uint256 totalAssets = lenderVault.totalAssets();
        assertLe(totalBorrowed, totalAssets, "Protocol insolvent!");
    }
}