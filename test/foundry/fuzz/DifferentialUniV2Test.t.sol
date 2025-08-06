// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {OsitoToken} from "../../../src/core/OsitoToken.sol";
import {OsitoPair} from "../../../src/core/OsitoPair.sol";
import {FeeRouter} from "../../../src/core/FeeRouter.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Reference UniswapV2 pair interface for differential testing
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function sync() external;
    function kLast() external view returns (uint);
    function totalSupply() external view returns (uint);
    function balanceOf(address) external view returns (uint);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Minimal UniswapV2 pair implementation for testing
contract MockUniswapV2Pair {
    using FixedPointMathLib for uint256;
    
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public kLast;
    
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    
    uint256 private constant MINIMUM_LIQUIDITY = 10**3;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        factory = msg.sender;
    }
    
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = address(0x1234); // Mock fee recipient
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = (uint256(_reserve0) * uint256(_reserve1)).sqrt();
                uint256 rootKLast = _kLast.sqrt();
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) {
                        totalSupply += liquidity;
                        balanceOf[feeTo] += liquidity;
                    }
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }
    
    function mint(address to) external returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;
        
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply;
        
        if (_totalSupply == 0) {
            liquidity = (amount0 * amount1).sqrt() - MINIMUM_LIQUIDITY;
            totalSupply = MINIMUM_LIQUIDITY;
            balanceOf[address(0)] = MINIMUM_LIQUIDITY;
        } else {
            liquidity = min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        totalSupply += liquidity;
        balanceOf[to] += liquidity;
        
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        
        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);
    }
    
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");
        
        uint256 balance0;
        uint256 balance1;
        {
            require(to != token0 && to != token1, "INVALID_TO");
            if (amount0Out > 0) ERC20(token0).transfer(to, amount0Out);
            if (amount1Out > 0) ERC20(token1).transfer(to, amount1Out);
            balance0 = ERC20(token0).balanceOf(address(this));
            balance1 = ERC20(token1).balanceOf(address(this));
        }
        
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");
        
        {
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3; // 0.3% fee
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
            require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * 1000**2, "K");
        }
        
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
    
    function burn(address) external pure returns (uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }
    
    function sync() external {
        reserve0 = uint112(ERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(ERC20(token1).balanceOf(address(this)));
    }
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice Differential testing between Osito and UniswapV2
contract DifferentialUniV2Test is BaseTest {
    using FixedPointMathLib for uint256;
    
    OsitoToken public token;
    OsitoPair public ositoPair;
    FeeRouter public feeRouter;
    MockUniswapV2Pair public uniV2Pair;
    
    // Track divergence metrics
    uint256 public maxKDivergenceBps;
    uint256 public maxSupplyDivergenceBps;
    uint256 public maxFeeMintDivergenceBps;
    
    function setUp() public override {
        super.setUp();
        
        // Launch Osito token and pair
        (token, ositoPair, feeRouter) = _launchToken(
            "Test Token",
            "TEST", 
            1_000_000_000 * 1e18,
            100 ether,
            alice
        );
        
        // Deploy mock UniV2 pair with same tokens
        bool tokIsToken0 = ositoPair.tokIsToken0();
        address token0 = tokIsToken0 ? address(token) : address(weth);
        address token1 = tokIsToken0 ? address(weth) : address(token);
        
        uniV2Pair = new MockUniswapV2Pair(token0, token1);
        
        // Initialize UniV2 pair with same liquidity
        (uint112 r0, uint112 r1,) = ositoPair.getReserves();
        deal(token0, address(uniV2Pair), uint256(r0));
        deal(token1, address(uniV2Pair), uint256(r1));
        uniV2Pair.mint(address(this));
    }
    
    /// @notice Test that K values remain close between implementations
    function testFuzz_KValuesDiverge(uint256 swapSeed, bool swapDirection) public {
        uint256 swapAmount = bound(swapSeed, 0.01 ether, 10 ether);
        
        // Record initial K values
        uint256 ositoKBefore = _getOsitoK();
        uint256 uniV2KBefore = _getUniV2K();
        
        // Perform identical swaps on both pairs
        _performMirrorSwap(swapAmount, swapDirection);
        
        // Compare K values after swap
        uint256 ositoKAfter = _getOsitoK();
        uint256 uniV2KAfter = _getUniV2K();
        
        // Calculate divergence
        uint256 kDivergence = ositoKAfter > uniV2KAfter ? 
            ositoKAfter - uniV2KAfter : 
            uniV2KAfter - ositoKAfter;
        
        uint256 divergenceBps = (kDivergence * 10000) / uniV2KAfter;
        
        // Track max divergence
        if (divergenceBps > maxKDivergenceBps) {
            maxKDivergenceBps = divergenceBps;
        }
        
        // K values should not diverge by more than 1%
        assertLe(divergenceBps, 100, "K values diverged by more than 1%");
    }
    
    /// @notice Test fee minting divergence
    function testFuzz_FeeMintDivergence(uint256 swapSeed, uint8 numSwaps) public {
        numSwaps = uint8(bound(numSwaps, 1, 10));
        
        for (uint256 i = 0; i < numSwaps; i++) {
            uint256 swapAmount = bound(swapSeed + i, 0.1 ether, 5 ether);
            _performMirrorSwap(swapAmount, i % 2 == 0);
        }
        
        // Record LP supplies before fee collection
        uint256 ositoSupplyBefore = ositoPair.totalSupply();
        uint256 uniV2SupplyBefore = uniV2Pair.totalSupply();
        
        // Trigger fee collection on Osito
        vm.prank(address(feeRouter));
        ositoPair.collectFees();
        
        // Trigger fee mint on UniV2 (via mint call)
        uniV2Pair.mint(address(this));
        
        // Compare LP supply increases
        uint256 ositoFeeMint = ositoPair.totalSupply() - ositoSupplyBefore;
        uint256 uniV2FeeMint = uniV2Pair.totalSupply() - uniV2SupplyBefore;
        
        if (ositoFeeMint > 0 && uniV2FeeMint > 0) {
            uint256 divergence = ositoFeeMint > uniV2FeeMint ?
                ositoFeeMint - uniV2FeeMint :
                uniV2FeeMint - ositoFeeMint;
            
            uint256 divergenceBps = (divergence * 10000) / uniV2FeeMint;
            
            if (divergenceBps > maxFeeMintDivergenceBps) {
                maxFeeMintDivergenceBps = divergenceBps;
            }
            
            // Osito should mint approximately 90% of fees (54/60 of UniV2's 1/6)
            // So Osito should mint about 5.4x more than UniV2
            uint256 expectedOsitoMint = uniV2FeeMint * 54 / 10;
            uint256 actualDifference = ositoFeeMint > expectedOsitoMint ?
                ositoFeeMint - expectedOsitoMint :
                expectedOsitoMint - ositoFeeMint;
            
            uint256 differenceBps = (actualDifference * 10000) / expectedOsitoMint;
            
            // Allow 10% tolerance on the expected ratio
            assertLe(differenceBps, 1000, "Fee mint ratio diverged from expected");
        }
    }
    
    /// @notice Test reserve consistency after multiple operations
    function testFuzz_ReserveConsistency(uint256[5] memory swapSeeds) public {
        for (uint256 i = 0; i < swapSeeds.length; i++) {
            uint256 swapAmount = bound(swapSeeds[i], 0.01 ether, 2 ether);
            bool direction = i % 2 == 0;
            
            _performMirrorSwap(swapAmount, direction);
            
            // Compare reserves
            (uint112 ositoR0, uint112 ositoR1,) = ositoPair.getReserves();
            (uint112 uniR0, uint112 uniR1,) = uniV2Pair.getReserves();
            
            // Reserves should be very close (within 0.1%)
            _assertApproxEqBps(uint256(ositoR0), uint256(uniR0), 10, "Reserve0 diverged");
            _assertApproxEqBps(uint256(ositoR1), uint256(uniR1), 10, "Reserve1 diverged");
        }
    }
    
    /// @notice Test extreme swap scenarios
    function test_ExtremeLargeSwap() public {
        // Test very large swap (50% of reserves)
        (uint112 r0, uint112 r1,) = ositoPair.getReserves();
        bool tokIsToken0 = ositoPair.tokIsToken0();
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        uint256 largeSwap = qtReserve / 2;
        deal(address(weth), alice, largeSwap);
        
        // Perform on both pairs
        _performMirrorSwap(largeSwap, true);
        
        // Both should handle it without breaking invariants
        uint256 ositoK = _getOsitoK();
        uint256 uniV2K = _getUniV2K();
        
        // K should have increased due to fees
        assertGt(ositoK, _getInitialK(), "Osito K didn't increase");
        assertGt(uniV2K, _getInitialK(), "UniV2 K didn't increase");
    }
    
    /// @notice Test tiny swap scenarios (dust amounts)
    function test_DustSwaps() public {
        // Test multiple dust swaps
        for (uint256 i = 0; i < 100; i++) {
            uint256 dustAmount = 1000 + i; // Very small amounts
            deal(address(weth), alice, dustAmount);
            
            _performMirrorSwap(dustAmount, i % 2 == 0);
        }
        
        // Check that both pairs handled dust correctly
        uint256 ositoK = _getOsitoK();
        uint256 uniV2K = _getUniV2K();
        
        // K values should still be close
        _assertApproxEqBps(ositoK, uniV2K, 100, "K diverged after dust swaps");
    }
    
    // ============ Helper Functions ============
    
    function _performMirrorSwap(uint256 amount, bool swapDirection) internal {
        if (swapDirection) {
            // Swap WETH for tokens on both pairs
            deal(address(weth), alice, amount * 2); // Need double for both swaps
            
            // Swap on Osito
            vm.startPrank(alice);
            weth.approve(address(ositoPair), amount);
            _swap(ositoPair, address(weth), amount, alice);
            
            // Swap on UniV2
            weth.transfer(address(uniV2Pair), amount);
            bool tokIsToken0 = ositoPair.tokIsToken0();
            
            // Calculate output amount
            (uint112 r0, uint112 r1,) = uniV2Pair.getReserves();
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            uint256 amountInWithFee = amount * 997; // 0.3% fee
            uint256 amountOut = (amountInWithFee * tokReserve) / (qtReserve * 1000 + amountInWithFee);
            
            uniV2Pair.swap(
                tokIsToken0 ? amountOut : 0,
                tokIsToken0 ? 0 : amountOut,
                alice,
                ""
            );
            vm.stopPrank();
        } else {
            // Swap tokens for WETH (reverse direction)
            uint256 tokenAmount = amount * 1000; // Scale for token amount
            deal(address(token), alice, tokenAmount * 2);
            
            // Similar swap logic in reverse
            vm.startPrank(alice);
            token.approve(address(ositoPair), tokenAmount);
            _swap(ositoPair, address(token), tokenAmount, alice);
            
            token.transfer(address(uniV2Pair), tokenAmount);
            bool tokIsToken0 = ositoPair.tokIsToken0();
            
            (uint112 r0, uint112 r1,) = uniV2Pair.getReserves();
            uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
            uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
            uint256 amountInWithFee = tokenAmount * 997;
            uint256 amountOut = (amountInWithFee * qtReserve) / (tokReserve * 1000 + amountInWithFee);
            
            uniV2Pair.swap(
                tokIsToken0 ? 0 : amountOut,
                tokIsToken0 ? amountOut : 0,
                alice,
                ""
            );
            vm.stopPrank();
        }
    }
    
    function _getOsitoK() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = ositoPair.getReserves();
        return uint256(r0) * uint256(r1);
    }
    
    function _getUniV2K() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = uniV2Pair.getReserves();
        return uint256(r0) * uint256(r1);
    }
    
    function _getInitialK() internal pure returns (uint256) {
        return 100 ether * 1_000_000_000 * 1e18; // Approximate initial K
    }
    
    function _assertApproxEqBps(uint256 a, uint256 b, uint256 maxBps, string memory err) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        uint256 bps = (diff * 10000) / (b > 0 ? b : 1);
        require(bps <= maxBps, err);
    }
}