// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/OsitoPair.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/core/LenderVault.sol";
import "../../src/core/OsitoToken.sol";
import "../../src/factories/OsitoLaunchpad.sol";
import "../../src/factories/LendingFactory.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title Fork Tests for Osito Protocol
 * @notice Tests against real mainnet/testnet state
 * @dev Run with: forge test --fork-url <RPC_URL> --match-contract OsitoForkTest
 */
contract OsitoForkTest is Test {
    // ============ Testnet Contracts ============
    address constant TESTNET_WBERA = 0x8239FBb3e3D0C2cDFd7888D8aF7701240Ac4DcA4;
    address constant TESTNET_LAUNCHPAD = 0x78FFF2548B07F2fc5c3A4787809dA675e8BA5159;
    
    // Known testnet tokens (from previous debugging)
    address constant FROB_TOKEN = 0x3a369629DbFBF6E8f3201F5489696486b752bF7e;
    address constant FROB_PAIR = 0x3e7676bf4d71E5A476FAb7a7a27859d00E97B5bF;
    address constant CHOP_TOKEN = 0x0F9065E9F71d6e86305a4815b3397829AEAa52C9;
    
    // ============ State ============
    OsitoLaunchpad launchpad;
    LendingFactory lendingFactory;
    IERC20 wbera;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");
    
    // ============ Setup ============
    
    function setUp() public {
        // Fork from testnet
        // Note: Replace with actual RPC URL when running
        // vm.createFork("https://rpc.testnet.berachain.com");
        
        // Use testnet contracts if available
        if (block.chainid == 80084) { // Berachain testnet
            launchpad = OsitoLaunchpad(TESTNET_LAUNCHPAD);
            wbera = IERC20(TESTNET_WBERA);
        } else {
            // Deploy fresh for local testing
            _deployFresh();
        }
        
        // Fund test accounts
        MockWBERA(address(wbera)).mint(alice, 1000e18);
        MockWBERA(address(wbera)).mint(bob, 1000e18);
        MockWBERA(address(wbera)).mint(whale, 100_000e18);
    }
    
    // ============ Fork Tests ============
    
    /**
     * @notice Test: Verify FROB token pMin calculation matches expected
     */
    function test_Fork_FROBPMinCalculation() public {
        if (block.chainid != 80084) {
            console.log("Skipping: Not on testnet");
            return;
        }
        
        OsitoPair frobPair = OsitoPair(FROB_PAIR);
        uint256 pMin = frobPair.pMin();
        
        // From previous debugging, we expect pMin to be around 7.7e-9 WBERA
        console.log("FROB pMin:", pMin);
        
        // Verify it's in reasonable range (not billions)
        assertLt(pMin, 1e18, "pMin unreasonably high");
        assertGt(pMin, 0, "pMin is zero");
    }
    
    /**
     * @notice Test: Interact with existing testnet pools
     */
    function test_Fork_SwapOnExistingPair() public {
        if (block.chainid != 80084) {
            console.log("Skipping: Not on testnet");
            return;
        }
        
        OsitoPair frobPair = OsitoPair(FROB_PAIR);
        OsitoToken frobToken = OsitoToken(FROB_TOKEN);
        
        // Get initial state
        (uint112 r0, uint112 r1,) = frobPair.getReserves();
        uint256 initialBalance = frobToken.balanceOf(alice);
        
        // Perform swap
        uint256 swapAmount = 0.01e18; // Small swap
        vm.startPrank(alice);
        wbera.transfer(address(frobPair), swapAmount);
        
        // Calculate expected output
        bool tokIsToken0 = frobPair.tokIsToken0();
        uint256 expectedOut = tokIsToken0
            ? (swapAmount * 997 * r0) / (r1 * 1000 + swapAmount * 997)
            : (swapAmount * 997 * r1) / (r0 * 1000 + swapAmount * 997);
        
        if (expectedOut > 0) {
            if (tokIsToken0) {
                frobPair.swap(expectedOut, 0, alice);
            } else {
                frobPair.swap(0, expectedOut, alice);
            }
        }
        vm.stopPrank();
        
        // Verify tokens received
        uint256 finalBalance = frobToken.balanceOf(alice);
        assertGt(finalBalance, initialBalance, "No tokens received");
    }
    
    /**
     * @notice Test: Large trades affect pMin correctly
     */
    function test_Fork_LargeTradeImpact() public {
        // Deploy fresh token for controlled test
        _deployFresh();
        
        // Launch new token
        vm.startPrank(alice);
        wbera.approve(address(launchpad), type(uint256).max);
        (address tokenAddr, address pairAddr,) = launchpad.launchToken(
            "FORK", "FORK", 1_000_000_000e18, "",
            1e18, 9900, 30, 30 days
        );
        vm.stopPrank();
        
        OsitoToken token = OsitoToken(tokenAddr);
        OsitoPair pair = OsitoPair(pairAddr);
        
        // Initial pMin should be 0
        assertEq(pair.pMin(), 0, "Initial pMin not 0");
        
        // Large buy
        vm.startPrank(whale);
        wbera.transfer(address(pair), 100e18);
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool tokIsToken0 = pair.tokIsToken0();
        uint256 output = tokIsToken0
            ? (100e18 * 997 * r0) / (r1 * 1000 + 100e18 * 997)
            : (100e18 * 997 * r1) / (r0 * 1000 + 100e18 * 997);
        
        if (tokIsToken0) {
            pair.swap(output, 0, whale);
        } else {
            pair.swap(0, output, whale);
        }
        vm.stopPrank();
        
        // pMin should now be positive
        uint256 pMinAfter = pair.pMin();
        assertGt(pMinAfter, 0, "pMin didn't increase");
        console.log("pMin after large buy:", pMinAfter);
    }
    
    /**
     * @notice Test: Fee collection and burning on fork
     */
    function test_Fork_FeeCollectionAndBurn() public {
        _deployFresh();
        
        // Launch token with fee router
        vm.startPrank(alice);
        wbera.approve(address(launchpad), type(uint256).max);
        (address tokenAddr, address pairAddr, address feeRouterAddr) = 
            launchpad.launchToken(
                "BURN", "BURN", 1_000_000_000e18, "",
                1e18, 9900, 30, 30 days
            );
        vm.stopPrank();
        
        OsitoToken token = OsitoToken(tokenAddr);
        OsitoPair pair = OsitoPair(pairAddr);
        FeeRouter feeRouter = FeeRouter(feeRouterAddr);
        
        uint256 initialSupply = token.totalSupply();
        
        // Generate fees through trades
        for (uint i = 0; i < 10; i++) {
            vm.startPrank(bob);
            wbera.transfer(address(pair), 1e18);
            
            (uint112 r0, uint112 r1,) = pair.getReserves();
            bool tokIsToken0 = pair.tokIsToken0();
            uint256 out = tokIsToken0
                ? (1e18 * 997 * r0) / (r1 * 1000 + 1e18 * 997)
                : (1e18 * 997 * r1) / (r0 * 1000 + 1e18 * 997);
            
            if (out > 100) { // Minimum output
                if (tokIsToken0) {
                    pair.swap(out - out/100, 0, bob); // Leave some slippage
                } else {
                    pair.swap(0, out - out/100, bob);
                }
            }
            vm.stopPrank();
        }
        
        // Collect fees
        feeRouter.collectFees();
        
        // Verify supply decreased
        uint256 finalSupply = token.totalSupply();
        assertLt(finalSupply, initialSupply, "Supply didn't decrease from burns");
        console.log("Supply burned:", initialSupply - finalSupply);
    }
    
    /**
     * @notice Test: Lending integration with real pools
     */
    function test_Fork_LendingWithRealPool() public {
        _deployFresh();
        
        // Launch token
        vm.startPrank(alice);
        wbera.approve(address(launchpad), type(uint256).max);
        (address tokenAddr, address pairAddr,) = launchpad.launchToken(
            "LEND", "LEND", 1_000_000_000e18, "",
            1e18, 9900, 30, 30 days
        );
        vm.stopPrank();
        
        OsitoToken token = OsitoToken(tokenAddr);
        OsitoPair pair = OsitoPair(pairAddr);
        
        // Create lending market
        address cvAddr = lendingFactory.createLendingMarket(pairAddr);
        CollateralVault cv = CollateralVault(cvAddr);
        LenderVault lv = LenderVault(cv.lenderVault());
        
        // Add lending liquidity
        vm.startPrank(whale);
        wbera.approve(address(lv), 1000e18);
        lv.deposit(1000e18, whale);
        vm.stopPrank();
        
        // Do initial trade to activate pMin
        vm.startPrank(bob);
        wbera.transfer(address(pair), 10e18);
        pair.swap(1000e18, 0, bob); // Rough estimate
        vm.stopPrank();
        
        // Now test borrowing
        uint256 pMin = pair.pMin();
        assertGt(pMin, 0, "pMin not activated");
        
        // Bob deposits collateral and borrows
        vm.startPrank(bob);
        token.approve(address(cv), 1000e18);
        cv.depositCollateral(1000e18);
        
        uint256 maxBorrow = (1000e18 * pMin) / 1e18;
        if (maxBorrow > 1e15) { // If reasonable borrow amount
            cv.borrow(maxBorrow / 2); // Borrow half of max
            
            uint256 borrowed = wbera.balanceOf(bob);
            assertGt(borrowed, 0, "No funds borrowed");
            console.log("Successfully borrowed:", borrowed);
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Gas optimization - batch operations
     */
    function test_Fork_GasOptimization() public {
        _deployFresh();
        
        // Launch token
        vm.startPrank(alice);
        wbera.approve(address(launchpad), type(uint256).max);
        (address tokenAddr, address pairAddr,) = launchpad.launchToken(
            "GAS", "GAS", 1_000_000_000e18, "",
            1e18, 9900, 30, 30 days
        );
        vm.stopPrank();
        
        OsitoPair pair = OsitoPair(pairAddr);
        
        // Measure gas for single swap
        uint256 gasBefore = gasleft();
        vm.startPrank(bob);
        wbera.transfer(address(pair), 1e18);
        pair.swap(100e18, 0, bob);
        vm.stopPrank();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for swap:", gasUsed);
        assertLt(gasUsed, 200_000, "Swap too expensive");
    }
    
    // ============ Helper Functions ============
    
    function _deployFresh() internal {
        // Deploy fresh contracts for testing
        address mockWbera = address(new MockWBERA());
        wbera = IERC20(mockWbera);
        
        address treasury = makeAddr("treasury");
        launchpad = new OsitoLaunchpad(mockWbera, treasury);
        lendingFactory = new LendingFactory(mockWbera, treasury);
    }
}

// ============ Mock Contracts ============

contract MockWBERA is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    
    function name() external pure returns (string memory) {
        return "Wrapped BERA";
    }
    
    function symbol() external pure returns (string memory) {
        return "WBERA";
    }
    
    function decimals() external pure returns (uint8) {
        return 18;
    }
    
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "Insufficient allowance");
        _allowances[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _balances[to] += amount;
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }
    
    function deposit() external payable {
        _balances[msg.sender] += msg.value;
        _totalSupply += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }
}