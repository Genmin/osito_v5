// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {OsitoToken} from "../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../src/core/OsitoPair.sol";
import {CollateralVault} from "../../src/core/CollateralVault.sol";
import {LenderVault} from "../../src/core/LenderVault.sol";
import {FeeRouter} from "../../src/core/FeeRouter.sol";
import {OsitoLaunchpad} from "../../src/factories/OsitoLaunchpad.sol";
import {LendingFactory} from "../../src/factories/LendingFactory.sol";
import {SwapRouter} from "../../src/periphery/SwapRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";

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
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
    
    receive() external payable {
        deposit();
    }
}

abstract contract TestBase is Test {
    MockWBERA public wbera;
    OsitoLaunchpad public launchpad;
    LendingFactory public lendingFactory;
    SwapRouter public swapRouter;
    
    address public treasury;
    
    address public alice;
    address public bob;
    address public charlie;
    address public keeper;
    address public attacker;
    
    uint256 public aliceKey = 0x1;
    uint256 public bobKey = 0x2;
    uint256 public charlieKey = 0x3;
    uint256 public keeperKey = 0x4;
    uint256 public attackerKey = 0x5;
    
    event PMinUpdated(uint256 newPMin, uint256 k, uint256 supply);
    event PositionOpened(address indexed account, uint256 collateral, uint256 debt);
    event PositionClosed(address indexed account, uint256 repaid);
    event MarkedOTM(address indexed account, uint256 markTime);
    event Recovered(address indexed account, uint256 collateralSwapped, uint256 debtRepaid, uint256 bonus);
    
    function setUp() public virtual {
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        charlie = vm.addr(charlieKey);
        keeper = vm.addr(keeperKey);
        attacker = vm.addr(attackerKey);
        treasury = address(0xdead);
        
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(keeper, "Keeper");
        vm.label(attacker, "Attacker");
        vm.label(treasury, "Treasury");
        
        wbera = new MockWBERA();
        vm.label(address(wbera), "WBERA");
        
        launchpad = new OsitoLaunchpad(address(wbera), treasury);
        vm.label(address(launchpad), "Launchpad");
        
        lendingFactory = new LendingFactory(address(wbera), treasury);
        vm.label(address(lendingFactory), "LendingFactory");
        
        swapRouter = new SwapRouter(address(wbera));
        vm.label(address(swapRouter), "SwapRouter");
        
        deal(alice, 1000 ether);
        deal(bob, 1000 ether);
        deal(charlie, 1000 ether);
        deal(keeper, 10 ether);
        deal(attacker, 1000 ether);
        
        vm.prank(alice);
        wbera.deposit{value: 100 ether}();
        
        vm.prank(bob);
        wbera.deposit{value: 100 ether}();
        
        vm.prank(charlie);
        wbera.deposit{value: 100 ether}();
        
        vm.prank(attacker);
        wbera.deposit{value: 100 ether}();
    }
    
    function createAndLaunchToken(
        string memory name,
        string memory symbol,
        uint256 supply
    ) internal returns (OsitoToken token, OsitoPair pair, FeeRouter feeRouter, CollateralVault vault, LenderVault lenderVault) {
        vm.startPrank(alice);
        
        // Approve WBERA for initial liquidity
        wbera.approve(address(launchpad), 1 ether);
        
        // Launch token with initial liquidity
        (address tokenAddr, address pairAddr, address feeRouterAddr) = launchpad.launchToken(
            name,
            symbol,
            supply,
            1 ether,  // wethAmount for initial liquidity
            9900,     // startFeeBps (99%)
            30,       // endFeeBps (0.3%)
            supply / 10  // feeDecayTarget (10% of supply)
        );
        
        token = OsitoToken(tokenAddr);
        pair = OsitoPair(pairAddr);
        feeRouter = FeeRouter(feeRouterAddr);
        
        // Get lender vault (deployed in LendingFactory constructor)
        lenderVault = LenderVault(lendingFactory.lenderVault());
        
        // Create lending market for this pair
        address vaultAddr = lendingFactory.collateralVaults(pairAddr);
        if (vaultAddr == address(0)) {
            vaultAddr = lendingFactory.createLendingMarket(pairAddr);
        }
        vault = CollateralVault(vaultAddr);
        
        vm.stopPrank();
    }
    
    function addLiquidity(
        OsitoPair pair,
        uint256 wberaAmount
    ) internal {
        require(wberaAmount > 0, "Invalid liquidity amount");
        
        wbera.transfer(address(pair), wberaAmount);
        pair.mint(address(pair.feeRouter()));
    }
    
    function swap(
        OsitoPair pair,
        address tokenIn,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 amountOut) {
        ERC20(tokenIn).transfer(address(pair), amountIn);
        
        bool tokIsToken0 = pair.tokIsToken0();
        address token0 = pair.token0();
        address token1 = pair.token1();
        
        bool isToken0In = tokenIn == token0;
        
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveIn = isToken0In ? uint256(r0) : uint256(r1);
        uint256 reserveOut = isToken0In ? uint256(r1) : uint256(r0);
        
        uint256 feeBps = pair.currentFeeBps();
        uint256 amountInWithFee = amountIn * (10000 - feeBps) / 10000;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        
        if (isToken0In) {
            pair.swap(0, amountOut, recipient);
        } else {
            pair.swap(amountOut, 0, recipient);
        }
    }
    
    function simulateTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }
    
    function assertApproxEq(uint256 a, uint256 b, uint256 maxDelta, string memory err) internal pure {
        uint256 delta = a > b ? a - b : b - a;
        require(delta <= maxDelta, err);
    }
}