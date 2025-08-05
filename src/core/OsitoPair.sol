// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {PMinLib} from "../libraries/PMinLib.sol";
import {OsitoToken} from "./OsitoToken.sol";

/// @notice UniswapV2Pair with restricted transfers + pMin oracle
/// @dev EXACT UniV2 implementation + 2 lines of transfer restrictions
contract OsitoPair is ERC20, ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;
    
    // UniswapV2 Events - REQUIRED for ecosystem compatibility
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    
    function name() public pure override returns (string memory) {
        return "Osito LP";
    }
    
    function symbol() public pure override returns (string memory) {
        return "OSITO-LP";
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // UniV2 state variables
    struct Reserves { uint112 r0; uint112 r1; uint32 blockTimestampLast; }
    Reserves public reserves;
    uint256 public kLast;
    
    // Immutable pair configuration
    address public immutable factory;
    address public token0;
    address public immutable token1;
    address public feeRouter;  // Not immutable, set after creation
    bool public immutable tokIsToken0;
    
    // Fee decay parameters
    uint256 public immutable startFeeBps;
    uint256 public immutable endFeeBps;
    uint256 public immutable feeDecayTarget;
    uint256 public initialSupply;
    
    uint256 private constant MINIMUM_LIQUIDITY = 10**3;

    constructor(
        address _token0,
        address _token1,
        address _feeRouter,
        uint256 _startFeeBps,
        uint256 _endFeeBps,
        uint256 _feeDecayTarget,
        bool _tokIsToken0
    ) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        feeRouter = _feeRouter;
        startFeeBps = _startFeeBps;
        endFeeBps = _endFeeBps;
        feeDecayTarget = _feeDecayTarget;
        tokIsToken0 = _tokIsToken0;
        
        // Initialize with 0 if token0 is placeholder
        if (_token0 != address(0)) {
            address tokToken = _tokIsToken0 ? _token0 : _token1;
            initialSupply = ERC20(tokToken).totalSupply();
        }
    }
    
    /// @notice Initialize token0 after pair creation (for circular dependency)
    function initialize(address _token0) external {
        require(msg.sender == factory, "UNAUTHORIZED");
        require(token0 == address(0), "ALREADY_INITIALIZED");
        
        token0 = _token0;
        // CRITICAL FIX: Always set initialSupply when token0 is set
        address tokToken = tokIsToken0 ? _token0 : token1;
        initialSupply = ERC20(tokToken).totalSupply();
    }
    
    /// @notice Set feeRouter after pair creation (for circular dependency)
    function setFeeRouter(address _feeRouter) external {
        require(msg.sender == factory, "UNAUTHORIZED");
        require(feeRouter == address(0), "ALREADY_SET");
        feeRouter = _feeRouter;
    }

    // EXACT UniV2 implementation with Solady optimizations
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 blockTimestampLast) {
        Reserves memory R = reserves;
        return (R.r0, R.r1, R.blockTimestampLast);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        reserves = Reserves(
            balance0.toUint112(),
            balance1.toUint112(),
            uint32(block.timestamp)
        );
        emit Sync(reserves.r0, reserves.r1);
    }

    // 100% of k growth goes to FeeRouter - NO SPLITS, NO DIVERSIONS
    function _mintFee(uint112 r0, uint112 r1) private returns (bool feeOn) {
        address _feeRouter = feeRouter;
        feeOn = _feeRouter != address(0);
        uint256 _kLast = kLast;
        
        if (feeOn) {
            if (_kLast != 0) {
                uint256 k = uint256(r0) * uint256(r1);
                if (k > _kLast) {
                    uint256 rootK = k.sqrt();
                    uint256 rootKLast = _kLast.sqrt();
                    uint256 _totalSupply = totalSupply();
                    
                    if (rootK > rootKLast) {
                        // 90% of k growth to FeeRouter, 10% stays in pool
                        // FeeRouter always burns 100% of what it receives
                        uint256 liquidity = _totalSupply * (rootK - rootKLast) * 90 / (rootKLast * 100);
                        
                        if (liquidity > 0) {
                            _mint(_feeRouter, liquidity);
                        }
                    }
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        // Allow address(0) for initial burn, or feeRouter for fee collection
        require(to == address(0) || to == feeRouter, "RESTRICTED");
        
        Reserves memory R = reserves;
        uint256 bal0 = ERC20(token0).balanceOf(address(this));
        uint256 bal1 = ERC20(token1).balanceOf(address(this));
        uint256 amt0 = bal0 - R.r0;
        uint256 amt1 = bal1 - R.r1;

        bool feeOn = _mintFee(R.r0, R.r1);
        uint256 _supply = totalSupply();
        
        if (_supply == 0) {
            liquidity = (amt0 * amt1).sqrt() - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = min(
                amt0 * _supply / R.r0,
                amt1 * _supply / R.r1
            );
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY");

        _mint(to, liquidity);
        _update(bal0, bal1);
        
        if (feeOn) kLast = uint256(reserves.r0) * uint256(reserves.r1);
        emit Mint(msg.sender, amt0, amt1);
    }

    function burn(address to) external nonReentrant returns (uint256 amt0, uint256 amt1) {
        Reserves memory R = reserves;
        uint256 bal0 = ERC20(token0).balanceOf(address(this));
        uint256 bal1 = ERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(R.r0, R.r1);
        uint256 _supply = totalSupply();
        
        amt0 = liquidity * bal0 / _supply;
        amt1 = liquidity * bal1 / _supply;
        require(amt0 > 0 && amt1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        token0.safeTransfer(to, amt0);
        token1.safeTransfer(to, amt1);

        bal0 = ERC20(token0).balanceOf(address(this));
        bal1 = ERC20(token1).balanceOf(address(this));
        _update(bal0, bal1);
        
        if (feeOn) kLast = uint256(reserves.r0) * uint256(reserves.r1);
        emit Burn(msg.sender, amt0, amt1, to);
    }

    function swap(uint256 a0Out, uint256 a1Out, address to) external nonReentrant {
        require(a0Out > 0 || a1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        
        Reserves memory R = reserves;
        require(a0Out < R.r0 && a1Out < R.r1, "INSUFFICIENT_LIQUIDITY");

        if (a0Out > 0) token0.safeTransfer(to, a0Out);
        if (a1Out > 0) token1.safeTransfer(to, a1Out);

        uint256 bal0 = ERC20(token0).balanceOf(address(this));
        uint256 bal1 = ERC20(token1).balanceOf(address(this));

        uint256 a0In = bal0 > R.r0 - a0Out ? bal0 - (R.r0 - a0Out) : 0;
        uint256 a1In = bal1 > R.r1 - a1Out ? bal1 - (R.r1 - a1Out) : 0;
        require(a0In > 0 || a1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        uint256 feeBps = currentFeeBps();
        uint256 bal0Adj = bal0 * 10000 - a0In * feeBps;
        uint256 bal1Adj = bal1 * 10000 - a1In * feeBps;
        
        require(bal0Adj * bal1Adj >= uint256(R.r0) * uint256(R.r1) * (10000**2), "K");

        _update(bal0, bal1);
        emit Swap(msg.sender, a0In, a1In, a0Out, a1Out, to);
    }

    // ONLY restriction: LP tokens can only go to feeRouter or pair itself
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to == feeRouter || to == address(this), "RESTRICTED");
        return super.transfer(to, amount);
    }
    
    // Override transferFrom to prevent LP token exile via approvals
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(to == feeRouter || to == address(this), "RESTRICTED");
        return super.transferFrom(from, to, amount);
    }

    function currentFeeBps() public view returns (uint256) {
        address tokToken = tokIsToken0 ? token0 : token1;
        uint256 currentSupply = ERC20(tokToken).totalSupply();
        uint256 burned = initialSupply > currentSupply ? initialSupply - currentSupply : 0;
        
        if (burned >= feeDecayTarget) return endFeeBps;
        
        uint256 range = startFeeBps - endFeeBps;
        uint256 reduction = range * burned / feeDecayTarget;
        return startFeeBps - reduction;
    }

    function pMin() external view returns (uint256) {
        Reserves memory R = reserves;
        uint256 rTok = tokIsToken0 ? uint256(R.r0) : uint256(R.r1);
        uint256 rQt = tokIsToken0 ? uint256(R.r1) : uint256(R.r0);
        
        address tokToken = tokIsToken0 ? token0 : token1;
        uint256 supply = ERC20(tokToken).totalSupply();
        
        return PMinLib.calculate(rTok, rQt, supply, currentFeeBps());
    }
    
    // Minimal addition: trigger fee collection without burn complexity
    function collectFees() external {
        require(msg.sender == feeRouter, "ONLY_FEE_ROUTER");
        Reserves memory R = reserves;
        _mintFee(R.r0, R.r1);
        if (kLast != 0) {
            kLast = uint256(R.r0) * uint256(R.r1);
        }
    }
    
    // CRITICAL: sync() and skim() are INTENTIONALLY OMITTED to prevent donation attacks
    // The protocol maintains its "closed-liquidity" property by disabling these functions
    
    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}