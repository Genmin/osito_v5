// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {OsitoPair} from "./OsitoPair.sol";
import {LenderVault} from "./LenderVault.sol";

/// @notice Options protocol: borrow = write PUT at pMin strike
/// @dev Minimal Compound V2 BorrowSnapshot + UniV2 recovery
contract CollateralVault is ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // Compound V2 BorrowSnapshot pattern + implicit grace timer
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
        uint256 lastHealthy;  // Timestamp when position last had S·C ≥ D
    }
    
    mapping(address => uint256) public collateralBalances;
    mapping(address => BorrowSnapshot) public accountBorrows;
    
    address public immutable collateralToken;
    address public immutable pair;
    address public immutable lenderVault;
    
    uint256 public constant GRACE_PERIOD = 72 hours;
    uint256 public constant RECOVERY_BONUS_BPS = 100; // 1% bonus for caller
    
    event PositionOpened(address indexed account, uint256 collateral, uint256 debt);
    event PositionClosed(address indexed account, uint256 repaid);
    event Recovered(address indexed account, uint256 collateralSwapped, uint256 debtRepaid, uint256 bonus);
    
    constructor(address _collateralToken, address _pair, address _lenderVault) {
        collateralToken = _collateralToken;
        pair = _pair;
        lenderVault = _lenderVault;
    }
    
    /// @notice Deposit collateral
    function depositCollateral(uint256 amount) external nonReentrant {
        LenderVault(lenderVault).accrueInterest();
        
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalances[msg.sender] += amount;
        
        // Update lastHealthy if position is now healthy
        _updateHealthStatus(msg.sender);
    }
    
    /// @notice Withdraw collateral (if no debt)
    function withdrawCollateral(uint256 amount) external nonReentrant {
        LenderVault(lenderVault).accrueInterest();
        
        require(accountBorrows[msg.sender].principal == 0, "OUTSTANDING_DEBT");
        require(collateralBalances[msg.sender] >= amount, "INSUFFICIENT_COLLATERAL");
        
        collateralBalances[msg.sender] -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
    }
    
    /// @notice Borrow = write PUT option at pMin strike
    function borrow(uint256 amount) external nonReentrant {
        LenderVault(lenderVault).accrueInterest();
        
        // Calculate max borrowable at pMin valuation
        uint256 pMin = OsitoPair(pair).pMin();
        uint256 maxBorrow = collateralBalances[msg.sender].mulDiv(pMin, 1e18);
        
        BorrowSnapshot memory snapshot = accountBorrows[msg.sender];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        // Get current debt with interest
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        require(currentDebt + amount <= maxBorrow, "EXCEEDS_PMIN_VALUE");
        
        // Update borrow snapshot with current health status
        accountBorrows[msg.sender] = BorrowSnapshot({
            principal: currentDebt + amount,
            interestIndex: lenderIndex,
            lastHealthy: block.timestamp  // New borrow starts healthy by definition (D ≤ pMin·C)
        });
        
        // Borrow from LenderVault (sends QT to this contract)
        LenderVault(lenderVault).borrow(amount);
        
        // CRITICAL: Forward the borrowed QT to the actual borrower
        address qtToken = LenderVault(lenderVault).asset();
        qtToken.safeTransfer(msg.sender, amount);
        
        emit PositionOpened(msg.sender, collateralBalances[msg.sender], currentDebt + amount);
    }
    
    /// @notice Repay debt and reclaim collateral
    function repay(uint256 amount) external nonReentrant {
        LenderVault(lenderVault).accrueInterest();
        
        BorrowSnapshot memory snapshot = accountBorrows[msg.sender];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        uint256 currentDebt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        
        ERC20(LenderVault(lenderVault).asset()).transferFrom(msg.sender, address(this), repayAmount);
        
        // Update or clear borrow
        if (repayAmount == currentDebt) {
            delete accountBorrows[msg.sender];
        } else {
            accountBorrows[msg.sender] = BorrowSnapshot({
                principal: currentDebt - repayAmount,
                interestIndex: lenderIndex,
                lastHealthy: isPositionHealthy(msg.sender) ? block.timestamp : snapshot.lastHealthy
            });
        }
        
        ERC20(LenderVault(lenderVault).asset()).approve(lenderVault, repayAmount);
        LenderVault(lenderVault).repay(repayAmount);
        
        emit PositionClosed(msg.sender, repayAmount);
    }
    
    /// @notice Update lastHealthy timestamp if position is healthy
    function _updateHealthStatus(address account) internal {
        BorrowSnapshot memory snapshot = accountBorrows[account];
        if (snapshot.principal > 0 && isPositionHealthy(account)) {
            accountBorrows[account].lastHealthy = block.timestamp;
        }
    }
    
    /// @notice Recover OTM position after grace period
    function recover(address account) external nonReentrant {
        LenderVault(lenderVault).accrueInterest();
        
        BorrowSnapshot memory snapshot = accountBorrows[account];
        
        // Single grace period check: position must be unhealthy AND grace period expired
        require(!isPositionHealthy(account), "POSITION_HEALTHY");
        require(block.timestamp >= snapshot.lastHealthy + GRACE_PERIOD, "GRACE_NOT_EXPIRED");
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        
        uint256 debt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        uint256 collateral = collateralBalances[account];
        require(collateral > 0 && debt > 0, "INVALID_POSITION");
        
        // Snapshot reserves BEFORE transfer (prevents sandwich attacks)
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        bool tokIsToken0 = OsitoPair(pair).tokIsToken0();
        
        // Clear position
        delete accountBorrows[account];
        delete collateralBalances[account];
        
        // Transfer collateral to pair for swap
        collateralToken.safeTransfer(pair, collateral);
        
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        // Calculate qtOut WITHOUT fee - pMin already includes worst-case fee
        // This maximizes capital efficiency while maintaining safety
        uint256 qtOut = (collateral * qtReserve) / (tokReserve + collateral);
        
        // Prevent gas grief: ensure swap will succeed
        require(qtOut > 0, "DUST_POSITION");
        
        // Execute swap
        if (tokIsToken0) {
            OsitoPair(pair).swap(0, qtOut, address(this));
        } else {
            OsitoPair(pair).swap(qtOut, 0, address(this));
        }
        
        // Repay debt
        uint256 repayAmount = qtOut > debt ? debt : qtOut;
        address qtToken = LenderVault(lenderVault).asset();
        ERC20(qtToken).approve(lenderVault, repayAmount);
        LenderVault(lenderVault).repay(repayAmount);
        
        // Absorb any loss (principal is always safe, only interest at risk)
        uint256 loss = debt > repayAmount ? debt - repayAmount : 0;
        if (loss != 0) {
            LenderVault(lenderVault).absorbLoss(loss);
        }
        
        // Calculate and send caller bonus
        uint256 bonus = 0;
        if (qtOut > debt) {
            uint256 excess = qtOut - debt;
            bonus = excess.mulDiv(RECOVERY_BONUS_BPS, 10000);
            if (bonus > 0) {
                qtToken.safeTransfer(msg.sender, bonus);
            }
            
            // Remaining goes to lenders
            uint256 lenderProfit = excess - bonus;
            if (lenderProfit > 0) {
                qtToken.safeTransfer(lenderVault, lenderProfit);
            }
        }
        
        emit Recovered(account, collateral, repayAmount, bonus);
    }
    
    /// @notice Check if position is healthy (ITM)
    function isPositionHealthy(address account) public view returns (bool) {
        BorrowSnapshot memory snapshot = accountBorrows[account];
        if (snapshot.principal == 0) return true;
        
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        uint256 debt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        // Get spot price from AMM
        (uint112 r0, uint112 r1,) = OsitoPair(pair).getReserves();
        bool tokIsToken0 = OsitoPair(pair).tokIsToken0();
        
        uint256 tokReserve = tokIsToken0 ? uint256(r0) : uint256(r1);
        uint256 qtReserve = tokIsToken0 ? uint256(r1) : uint256(r0);
        
        if (tokReserve == 0) return false;
        uint256 spotPrice = qtReserve.mulDiv(1e18, tokReserve);
        
        uint256 collateralValue = collateralBalances[account].mulDiv(spotPrice, 1e18);
        
        // Healthy if collateral spot value > debt
        return collateralValue > debt;
    }
    
    /// @notice Get account state
    function getAccountState(address account) external view returns (
        uint256 collateral,
        uint256 debt,
        bool isHealthy,
        uint256 timeUntilRecoverable
    ) {
        collateral = collateralBalances[account];
        
        BorrowSnapshot memory snapshot = accountBorrows[account];
        uint256 lenderIndex = LenderVault(lenderVault).borrowIndex();
        debt = snapshot.interestIndex == 0 
            ? snapshot.principal 
            : snapshot.principal.mulDiv(lenderIndex, snapshot.interestIndex);
        
        isHealthy = isPositionHealthy(account);
        
        // Derive time until recoverable from lastHealthy timestamp
        if (!isHealthy && snapshot.principal > 0) {
            uint256 graceEnd = snapshot.lastHealthy + GRACE_PERIOD;
            if (block.timestamp < graceEnd) {
                timeUntilRecoverable = graceEnd - block.timestamp;
            }
        }
    }
}