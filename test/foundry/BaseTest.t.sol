// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

// Core contracts
import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";

// Factories
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";

// Libraries
import {PMinLib} from "../../src/libraries/PMinLib.sol";

// Interfaces
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Mock WETH for testing
contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped ETH";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WETH";
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    receive() external payable {
        deposit();
    }
}

/// @notice Base test contract with all setup and helpers
abstract contract BaseTest is Test {
    using SafeTransferLib for address;
    
    // Core contracts
    MockWETH public weth;
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    
    // Test accounts
    address public deployer;
    address public alice;
    address public bob;
    address public charlie;
    address public dave;
    address public eve;
    address public keeper;
    address public treasury;
    
    // Private keys for signing
    uint256 public deployerKey = 0x1;
    uint256 public aliceKey = 0x2;
    uint256 public bobKey = 0x3;
    uint256 public charlieKey = 0x4;
    uint256 public daveKey = 0x5;
    uint256 public eveKey = 0x6;
    uint256 public keeperKey = 0x7;
    
    // Common test values
    uint256 public constant INITIAL_ETH = 1000 ether;
    uint256 public constant INITIAL_WETH = 100 ether;
    
    modifier prank(address account) {
        vm.startPrank(account);
        _;
        vm.stopPrank();
    }
    
    function setUp() public virtual {
        // Setup accounts
        deployer = vm.addr(deployerKey);
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        charlie = vm.addr(charlieKey);
        dave = vm.addr(daveKey);
        eve = vm.addr(eveKey);
        keeper = vm.addr(keeperKey);
        treasury = address(0xdead);
        
        // Label accounts for traces
        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(dave, "Dave");
        vm.label(eve, "Eve");
        vm.label(keeper, "Keeper");
        vm.label(treasury, "Treasury");
        
        // Fund accounts with ETH
        vm.deal(deployer, INITIAL_ETH);
        vm.deal(alice, INITIAL_ETH);
        vm.deal(bob, INITIAL_ETH);
        vm.deal(charlie, INITIAL_ETH);
        vm.deal(dave, INITIAL_ETH);
        vm.deal(eve, INITIAL_ETH);
        vm.deal(keeper, 10 ether);
        
        // Deploy core infrastructure
        vm.startPrank(deployer);
        
        // Deploy WETH
        weth = new MockWETH();
        vm.label(address(weth), "WETH");
        
        // Deploy factories
        launchpad = new OsitoLaunchpad(address(weth), treasury);
        vm.label(address(launchpad), "Launchpad");
        
        lendingFactory = new LendingFactory(address(weth), treasury);
        vm.label(address(lendingFactory), "LendingFactory");
        
        vm.stopPrank();
        
        // Give initial WETH to test accounts
        _fundAccountWithWETH(alice, INITIAL_WETH);
        _fundAccountWithWETH(bob, INITIAL_WETH);
        _fundAccountWithWETH(charlie, INITIAL_WETH);
        _fundAccountWithWETH(dave, INITIAL_WETH);
        _fundAccountWithWETH(eve, INITIAL_WETH);
    }
    
    /// @notice Helper to fund account with WETH
    function _fundAccountWithWETH(address account, uint256 amount) internal {
        vm.prank(account);
        weth.deposit{value: amount}();
    }
    
    /// @notice Helper to launch a token with proper setup
    function _launchToken(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 initialLiquidity,
        address launcher
    ) internal returns (
        OsitoToken token,
        OsitoPair pair,
        FeeRouter feeRouter
    ) {
        vm.startPrank(launcher);
        
        // Approve WETH for initial liquidity
        weth.approve(address(launchpad), initialLiquidity);
        
        // Launch token
        (address tokenAddr, address pairAddr, address feeRouterAddr) = launchpad.launchToken(
            name,
            symbol,
            supply,
            initialLiquidity,
            9900,  // 99% initial fee
            30,    // 0.3% final fee
            supply / 10  // 10% burn target for fee decay
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
        
        // Label contracts
        vm.label(tokenAddr, string.concat("Token-", symbol));
        vm.label(pairAddr, string.concat("Pair-", symbol));
        vm.label(feeRouterAddr, string.concat("FeeRouter-", symbol));
        
        vm.stopPrank();
    }
    
    /// @notice Helper to create lending market
    function _createLendingMarket(address pair) internal returns (CollateralVault vault) {
        address vaultAddr = lendingFactory.collateralVaults(pair);
        
        if (vaultAddr == address(0)) {
            vaultAddr = lendingFactory.createLendingMarket(pair);
        }
        
        vault = CollateralVault(vaultAddr);
        vm.label(vaultAddr, "CollateralVault");
    }
    
    /// @notice Helper to perform a swap
    function _swap(
        OsitoPair pair,
        address tokenIn,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 amountOut) {
        // Get reserves
        (uint112 r0, uint112 r1,) = pair.getReserves();
        address token0 = pair.token0();
        address token1 = pair.token1();
        
        bool isToken0In = tokenIn == token0;
        uint256 reserveIn = isToken0In ? uint256(r0) : uint256(r1);
        uint256 reserveOut = isToken0In ? uint256(r1) : uint256(r0);
        
        // Calculate output with fee
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = (amountIn * (10000 - feeBps)) / 10000;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        
        // Transfer input token to pair (caller must have tokens and approval)
        ERC20(tokenIn).transfer(address(pair), amountIn);
        
        // Execute swap
        if (isToken0In) {
            pair.swap(0, amountOut, recipient);
        } else {
            pair.swap(amountOut, 0, recipient);
        }
    }
    
    /// @notice Helper to get current pMin
    function _getPMin(OsitoPair pair) internal view returns (uint256) {
        return pair.pMin();
    }
    
    /// @notice Helper to calculate expected pMin
    function _calculatePMin(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 totalSupply,
        uint256 feeBps
    ) internal pure returns (uint256) {
        return PMinLib.calculate(tokReserve, qtReserve, totalSupply, feeBps);
    }
    
    /// @notice Helper to advance time
    function _advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }
    
    /// @notice Helper to advance blocks
    function _advanceBlocks(uint256 blocks_) internal {
        vm.roll(block.number + blocks_);
    }
    
    /// @notice Assert approximately equal with tolerance
    function assertApproxEq(uint256 a, uint256 b, uint256 tolerance, string memory err) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > tolerance) {
            revert(string.concat(err, " - diff: ", vm.toString(diff)));
        }
    }
    
    /// @notice Get token balances for an account
    function _getBalances(address account, OsitoToken token) internal view returns (
        uint256 ethBalance,
        uint256 wethBalance,
        uint256 tokenBalance
    ) {
        ethBalance = account.balance;
        wethBalance = weth.balanceOf(account);
        tokenBalance = token.balanceOf(account);
    }
    
    /// @notice Snapshot protocol state
    function _snapshotProtocol(OsitoPair pair) internal view returns (
        uint256 pMin,
        uint256 k,
        uint256 totalSupply,
        uint256 feeBps,
        uint112 reserve0,
        uint112 reserve1
    ) {
        pMin = pair.pMin();
        (reserve0, reserve1,) = pair.getReserves();
        k = uint256(reserve0) * uint256(reserve1);
        
        address token = pair.tokIsToken0() ? pair.token0() : pair.token1();
        totalSupply = OsitoToken(token).totalSupply();
        feeBps = pair.currentFeeBps();
    }
}