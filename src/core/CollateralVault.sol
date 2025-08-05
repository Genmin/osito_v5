// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {PMinLib} from "../libraries/PMinLib.sol";
import {OsitoPair} from "./OsitoPair.sol";
import {LenderVault} from "./LenderVault.sol";

/// @notice Compound V2 BorrowSnapshot pattern + pMin liquidations
/// @dev EXACT Compound implementation with pMin price oracle + P0 FIXES APPLIED
contract CollateralVault is ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // EXACT Compound V2 BorrowSnapshot pattern
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }
    
    mapping(address => uint256) public collateralBalances;
    mapping(address => BorrowSnapshot) public accountBorrows;
    
    address public immutable collateralToken;
    address public immutable pair;
    address public immutable lenderVault;
    
    uint256 public constant COLLATERAL_FACTOR = 8000; // 80%
    uint256 public constant LIQUIDATION_INCENTIVE = 10500; // 5% bonus
    uint256 public constant CLOSE_FACTOR = 5000; // 50% max liquidation
    
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repayAmount, uint256 collateralSeized);
    
    constructor(address _collateralToken, address _pair, address _lenderVault) {
        collateralToken = _collateralToken;
        pair = _pair;
        lenderVault = _lenderVault;
    }
    
    function depositCollateral(uint256 amount) external nonReentrant {
        // P0 FIX: Add _accrue() hook
        LenderVault(lenderVault).accrueInterest();
        
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalances[msg.sender] += amount;
    }
    
    function withdrawCollateral(uint256 amount) external nonReentrant {
        // P0 FIX: Add _accrue() hook
        LenderVault(lenderVault).accrueInterest();
        
        collateralBalances[msg.sender] -= amount;
        require(_isAccountHealthy(msg.sender), "INSUFFICIENT_COLLATERAL");
        collateralToken.safeTransfer(msg.sender, amount);
    }
    
    function borrow(uint256 amount) external nonReentrant {
        // P0 FIX: Add _accrue() hook
        LenderVault(lenderVault).accrueInterest();
        
        BorrowSnapshot memory snapshot = accountBorrows[msg.sender];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // EXACT Compound pattern: handle first borrow case
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        require(_canBorrow(msg.sender, amount), "INSUFFICIENT_COLLATERAL");
        
        accountBorrows[msg.sender] = BorrowSnapshot({
            principal: currentDebt + amount,
            interestIndex: lenderIndex
        });
        
        LenderVault(lenderVault).borrow(amount);
        ERC20(LenderVault(lenderVault).asset()).transfer(msg.sender, amount);
    }
    
    function repay(uint256 amount) external nonReentrant {
        // P0 FIX: Add _accrue() hook
        LenderVault(lenderVault).accrueInterest();
        
        BorrowSnapshot memory snapshot = accountBorrows[msg.sender];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // EXACT Compound pattern: handle first borrow case
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        
        ERC20(LenderVault(lenderVault).asset()).transferFrom(msg.sender, address(this), repayAmount);
        
        accountBorrows[msg.sender] = BorrowSnapshot({
            principal: currentDebt - repayAmount,
            interestIndex: lenderIndex
        });
        
        LenderVault(lenderVault).repay(repayAmount);
    }
    
    // Liquidation with P0 FIX: min(spot, pMin) oracle
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        require(!_isAccountHealthy(borrower), "ACCOUNT_HEALTHY");
        
        // P0 FIX: Add _accrue() hook
        LenderVault(lenderVault).accrueInterest();
        
        BorrowSnapshot memory snapshot = accountBorrows[borrower];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // EXACT Compound pattern: handle first borrow case
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        uint256 maxRepay = currentDebt.mulDiv(CLOSE_FACTOR, 10000);
        repayAmount = repayAmount > maxRepay ? maxRepay : repayAmount;
        
        // P0 FIX: Use max(spot, pMin) for liquidation oracle
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 spotPrice = _getSpotPrice();
        uint256 liquidationPrice = pMin > spotPrice ? pMin : spotPrice;
        
        uint256 collateralSeized = repayAmount.mulDiv(LIQUIDATION_INCENTIVE, 10000).mulDiv(1e18, liquidationPrice);
        
        require(collateralSeized <= collateralBalances[borrower], "INSUFFICIENT_COLLATERAL");
        
        ERC20(LenderVault(lenderVault).asset()).transferFrom(msg.sender, address(this), repayAmount);
        
        accountBorrows[borrower] = BorrowSnapshot({
            principal: currentDebt - repayAmount,
            interestIndex: lenderIndex
        });
        
        collateralBalances[borrower] -= collateralSeized;
        
        LenderVault(lenderVault).repay(repayAmount);
        collateralToken.safeTransfer(msg.sender, collateralSeized);
        
        emit Liquidate(msg.sender, borrower, repayAmount, collateralSeized);
    }
    
    function _getSpotPrice() private view returns (uint256) {
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        bool tokIsToken0 = OsitoPair(pair).tokIsToken0();
        uint256 rTok = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 rQt = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        if (rTok == 0) return 0;
        return rQt.mulDiv(1e18, rTok);
    }
    
    function _isAccountHealthy(address account) private view returns (bool) {
        BorrowSnapshot memory snapshot = accountBorrows[account];
        if (snapshot.principal == 0) return true;
        
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // EXACT Compound pattern: handle first borrow case
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        // Use max(pMin, spot) to match liquidation oracle
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 spotPrice = _getSpotPrice();
        uint256 price = pMin > spotPrice ? pMin : spotPrice;
        uint256 collateralValue = collateralBalances[account].mulDiv(price, 1e18);
        uint256 borrowPower = collateralValue.mulDiv(COLLATERAL_FACTOR, 10000);
        
        return currentDebt <= borrowPower;
    }
    
    function _canBorrow(address account, uint256 additionalDebt) private view returns (bool) {
        BorrowSnapshot memory snapshot = accountBorrows[account];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // EXACT Compound pattern: handle first borrow case
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        // Use min(pMin, spot) for conservative borrowing valuation
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 spotPrice = _getSpotPrice();
        uint256 price = pMin < spotPrice ? pMin : spotPrice;
        uint256 collateralValue = collateralBalances[account].mulDiv(price, 1e18);
        uint256 borrowPower = collateralValue.mulDiv(COLLATERAL_FACTOR, 10000);
        
        return (currentDebt + additionalDebt) <= borrowPower;
    }
    
    function getAccountHealth(address account) external view returns (uint256 collateral, uint256 debt, bool healthy) {
        BorrowSnapshot memory snapshot = accountBorrows[account];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        collateral = collateralBalances[account];
        
        // EXACT Compound pattern: handle first borrow case
        debt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        healthy = _isAccountHealthy(account);
    }
}