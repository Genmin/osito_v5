// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @notice ERC4626 vault with Compound-style lending
/// @dev Standard vault + borrow/repay for CollateralVault
contract LenderVault is ERC4626, ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address private immutable _asset;
    address public immutable factory;
    address public immutable treasury;
    mapping(address => bool) public authorized;
    
    uint256 public totalBorrows;
    uint256 public totalReserves; // Protocol reserves (Compound pattern)
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrueTime;
    
    uint256 public constant BASE_RATE = 2e16; // 2% APR
    uint256 public constant RATE_SLOPE = 5e16; // 5% APR slope
    uint256 public constant KINK = 8e17; // 80% utilization kink
    uint256 public constant RESERVE_FACTOR = 1e17; // 10% reserveFactor (0.1 * 1e18)
    
    modifier onlyAuthorized() {
        require(authorized[msg.sender], "UNAUTHORIZED");
        _;
    }
    
    constructor(address asset_, address _factory, address _treasury) {
        _asset = asset_;
        factory = _factory;
        treasury = _treasury;
        lastAccrueTime = block.timestamp;
    }
    
    function asset() public view override returns (address) {
        return _asset;
    }
    
    function name() public view override returns (string memory) {
        return _tokenName(asset());
    }
    
    function symbol() public view override returns (string memory) {
        return _tokenSymbol(asset());
    }
    
    /// @notice Authorize vault to borrow/repay
    /// @dev Only factory can authorize - prevents sybil attacks
    function authorize(address vault) external {
        require(msg.sender == factory, "UNAUTHORIZED");
        authorized[vault] = true;
    }
    
    /// @notice External accrual function called by CollateralVault
    function accrueInterest() external {
        _accrue();
    }
    
    function borrow(uint256 amount) external onlyAuthorized nonReentrant {
        _accrue();
        require(totalAssets() >= totalBorrows + amount, "INSUFFICIENT_LIQUIDITY");
        totalBorrows += amount;
        asset().safeTransfer(msg.sender, amount);
    }
    
    function repay(uint256 amount) external onlyAuthorized nonReentrant {
        _accrue();
        uint256 repayAmount = amount > totalBorrows ? totalBorrows : amount;
        asset().safeTransferFrom(msg.sender, address(this), repayAmount);
        totalBorrows -= repayAmount;
    }
    
    /// @notice Absorb loss when recovery doesn't cover full debt
    /// @dev Only called by CollateralVault when Qₜ < Q₀ + Qᵢ
    function absorbLoss(uint256 loss) external onlyAuthorized {
        totalBorrows -= loss;
    }
    
    function borrowRate() external view returns (uint256) {
        uint256 totalSupply = totalAssets();
        if (totalSupply == 0) return BASE_RATE;
        
        uint256 utilization = totalBorrows.mulDiv(1e18, totalSupply);
        
        if (utilization <= KINK) {
            return BASE_RATE + utilization.mulDiv(RATE_SLOPE, 1e18);
        } else {
            uint256 excessUtil = utilization - KINK;
            return BASE_RATE + RATE_SLOPE + excessUtil.mulDiv(RATE_SLOPE * 3, 1e18);
        }
    }
    
    function totalAssets() public view override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this)) + totalBorrows;
    }
    
    function _accrue() private {
        uint256 currentTime = block.timestamp;
        if (currentTime == lastAccrueTime) return;
        
        uint256 rate = _borrowRate();
        uint256 timeDelta = currentTime - lastAccrueTime;
        uint256 interestFactor = rate.mulDiv(timeDelta, 365 days);
        
        // Calculate interest accumulated (Compound pattern)
        uint256 interestAccumulated = totalBorrows.mulDiv(interestFactor, 1e18);
        
        // Update state following Compound pattern:
        // totalBorrowsNew = interestAccumulated + totalBorrows
        // totalReservesNew = interestAccumulated * reserveFactor + totalReserves
        totalBorrows += interestAccumulated;
        totalReserves += interestAccumulated.mulDiv(RESERVE_FACTOR, 1e18);
        borrowIndex += borrowIndex.mulDiv(interestFactor, 1e18);
        lastAccrueTime = currentTime;
    }
    
    function _borrowRate() private view returns (uint256) {
        if (totalBorrows == 0) return BASE_RATE;
        
        uint256 total = totalAssets();
        uint256 utilization = totalBorrows.mulDiv(1e18, total);
        
        if (utilization <= KINK) {
            return BASE_RATE + utilization.mulDiv(RATE_SLOPE, 1e18);
        } else {
            uint256 excessUtil = utilization - KINK;
            return BASE_RATE + RATE_SLOPE + excessUtil.mulDiv(RATE_SLOPE * 3, 1e18);
        }
    }
    
    function _tokenName(address assetAddr) private view returns (string memory) {
        return string(abi.encodePacked("Osito ", ERC20(assetAddr).name()));
    }
    
    function _tokenSymbol(address assetAddr) private view returns (string memory) {
        return string(abi.encodePacked("o", ERC20(assetAddr).symbol()));
    }
    
    /// @notice Reduces reserves by transferring to treasury
    /// @dev Simplified Compound pattern - only treasury can withdraw
    function reduceReserves(uint256 amount) external {
        require(msg.sender == treasury, "ONLY_TREASURY");
        _accrue();
        
        require(amount <= totalReserves, "INSUFFICIENT_RESERVES");
        require(amount <= ERC20(asset()).balanceOf(address(this)), "INSUFFICIENT_CASH");
        
        totalReserves -= amount;
        asset().safeTransfer(treasury, amount);
    }
}