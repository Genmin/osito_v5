// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice ERC4626 vault with Compound-style lending
/// @dev Standard vault + borrow/repay for CollateralVault
contract LenderVault is ERC4626 {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address private immutable _asset;
    address public immutable factory;
    mapping(address => bool) public authorized;
    
    uint256 public totalBorrows;
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrueTime;
    
    uint256 public constant BASE_RATE = 2e16; // 2% APR
    uint256 public constant RATE_SLOPE = 5e16; // 5% APR slope
    uint256 public constant KINK = 8e17; // 80% utilization kink
    
    modifier onlyAuthorized() {
        require(authorized[msg.sender], "UNAUTHORIZED");
        _;
    }
    
    constructor(address asset_, address _collateralVault) {
        _asset = asset_;
        factory = msg.sender;
        if (_collateralVault != address(0)) {
            authorized[_collateralVault] = true;
        }
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
    
    function borrow(uint256 amount) external onlyAuthorized {
        _accrue();
        require(totalAssets() >= totalBorrows + amount, "INSUFFICIENT_LIQUIDITY");
        totalBorrows += amount;
        asset().safeTransfer(msg.sender, amount);
    }
    
    function repay(uint256 amount) external onlyAuthorized {
        _accrue();
        uint256 repayAmount = amount > totalBorrows ? totalBorrows : amount;
        asset().safeTransferFrom(msg.sender, address(this), repayAmount);
        totalBorrows -= repayAmount;
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
        
        uint256 rate = this.borrowRate();
        uint256 timeDelta = currentTime - lastAccrueTime;
        // CRITICAL FIX: Divide by seconds in a year
        uint256 interestAccumulated = rate.mulDiv(timeDelta, 365 days);
        
        totalBorrows += totalBorrows.mulDiv(interestAccumulated, 1e18);
        borrowIndex += borrowIndex.mulDiv(interestAccumulated, 1e18);
        lastAccrueTime = currentTime;
    }
    
    function _tokenName(address assetAddr) private view returns (string memory) {
        return string(abi.encodePacked("Osito ", ERC20(assetAddr).name()));
    }
    
    function _tokenSymbol(address assetAddr) private view returns (string memory) {
        return string(abi.encodePacked("o", ERC20(assetAddr).symbol()));
    }
}