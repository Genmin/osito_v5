# Ultra-Minimal Osito V5 Proposal

## The Realization
We're still fighting symptoms. The root cause: we're trying to implement "health checks" and "grace periods" - concepts that DON'T EXIST in our reference implementations.

## What Compound V2 Actually Does
1. Borrow up to collateral * collateralFactor
2. Anyone can liquidate when price moves against you
3. Fixed liquidation incentive
4. NO grace periods, NO health checks, NO OTM flags

## What UniV2 Actually Does  
1. Swap tokens using x*y=k
2. NO concept of positions or health
3. NO time-based logic

## The Brutal Truth About Osito

The ONLY invariant that matters: **pMin ≥ debt/collateral**

Since:
1. Debt starts at pMin (by construction)
2. pMin only goes up (monotonic ratchet)
3. Therefore: **Principal is ALWAYS safe**

## Ultra-Minimal Implementation

### Remove ALL Health Checks
```solidity
// DELETE THIS ENTIRE FUNCTION
function isPositionHealthy() { /* GONE */ }

// DELETE THIS TOO
function _updateHealthStatus() { /* GONE */ }
```

### Simplify BorrowSnapshot to Pure Compound V2
```solidity
struct BorrowSnapshot {
    uint256 principal;
    uint256 interestIndex;
    // NO lastHealthy, NO timestamps, NOTHING ELSE
}
```

### Make Recovery Pure Economic Incentive
```solidity
function recover(address account) external nonReentrant {
    // ONLY requirements:
    // 1. Position exists (has debt)
    // 2. Caller gets 1% bonus (economic incentive)
    
    // NO health checks
    // NO grace periods  
    // NO time logic
    
    // Just swap and repay like Compound V2 liquidation
}
```

## Why This Works

1. **Bad liquidations are unprofitable**: If S > pMin, liquidator loses money
2. **Good liquidations are profitable**: If S < pMin, liquidator makes 1%
3. **Market sorts it out**: Just like Compound V2

## What We Delete

- `isPositionHealthy()` - 30 lines
- `_updateHealthStatus()` - 5 lines  
- `lastHealthy` field - 1 storage slot
- All time-based logic - 10 lines
- Grace period checks - 5 lines

**Total: 50+ more lines deleted**

## The Result

A protocol that is:
1. **Purely economic** - no time-based state machines
2. **Battle-tested** - exact Compound V2 liquidation model
3. **Minimal** - under 200 lines total
4. **Provably safe** - pMin monotonicity ensures principal safety

## The Osito Ethos Achieved

> "Subtract until the flaw has nowhere left to hide"

When you remove time-based logic, you remove:
- Flash loan attacks (nothing to manipulate)
- Griefing attacks (no flags to set)
- Race conditions (no timers to race)
- State bloat (no timestamps to store)

Pure economic incentives. Pure algebraic safety. Pure simplicity.