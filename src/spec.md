# Osito Protocol: Technical Specification

## What Osito Actually Is

Osito is **NOT a margin lending protocol**. It is a **mathematically guaranteed safe lending system** that eliminates liquidation risk entirely through its pMin mechanism.

### The Key Insight

Traditional lending asks: "How much risk can we tolerate?"  
Osito asks: "Risk doesn't exist. How much value can we unlock?"

## How It Works: The Complete Lifecycle

### 1. Launch State
- **ALL tokens start in the AMM pool** (x = S, where x = reserves, S = total supply)
- **pMin = 0** because no tokens exist outside the pool
- **No one can borrow yet** - there's literally no collateral available

### 2. First Trade Activates Everything
When the first buyer swaps QT for TOK:
- TOK leaves the pool (now x < S)
- Collateral now exists! (S - x = tokens outside pool)
- pMin becomes non-zero and meaningful
- Borrowing can begin

### 3. The Automatic Value Flywheel
Every single trade:
- Pays fees (99% initially, decaying to 0.3%)
- Fees increase k (constant product)
- Keeper bot calls `collectFees()` periodically
- **Burns LP tokens → receives TOK → BURNS ALL TOK**
- Burning reduces S (total supply) forever

### 4. pMin Monotonically Increases
The formula: `pMin = k / [x + (S-x)(1-f)]²`

Two forces push pMin up:
- **k increases** from trading fees (numerator ↑)
- **S decreases** from token burns (denominator ↓)
- Result: **pMin only goes up, never down**

## The Revolutionary Safety Model

### It's ALWAYS 100% Safe
- **Maximum debt = pMin × collateral**
- pMin is the **GUARANTEED MINIMUM** recovery price through atomic liquidation
- Even if spot price crashes to pMin, liquidation ALWAYS covers 100% of debt
- **Bad debt is mathematically impossible**

### What Rising pMin Actually Means
As pMin increases, the protocol doesn't get "safer" - it's always 100% safe. Instead:
- **Capital efficiency increases**
- Users can borrow MORE against the SAME collateral
- Example: If pMin doubles from 0.01 to 0.02:
  - 1000 TOK could borrow 10 QT before (100% safe)
  - 1000 TOK can borrow 20 QT after (STILL 100% safe)

### Why Liquidations Can't Fail
1. Loans are issued at pMin (the mathematical floor)
2. Liquidations happen at spot price (always ≥ pMin)
3. The gap between spot and pMin is pure profit buffer
4. Even with zero buffer, liquidation covers 100% of debt

## System Architecture

| Layer | Components | Purpose |
|-------|------------|---------|
| **AMM Core** | OsitoPair, FeeRouter | Closed-liquidity DEX that generates the pMin oracle |
| **Lending** | LenderVault, CollateralVault | Permissionless lending using pMin as the safety guarantee |

### Critical Design Choices

1. **Closed LP System**: Only FeeRouter can hold LP tokens
   - Prevents liquidity removal
   - Ensures k never decreases
   - Makes pMin truly monotonic

2. **100% Token Burn**: All collected TOK is burned
   - Permanently reduces supply
   - Directly increases pMin
   - No governance, no treasury, just math

3. **No External Dependencies**: 
   - No price oracles needed
   - No governance decisions
   - No admin keys
   - Just immutable contracts and math

## The pMin Formula Explained

`pMin = k / [x + (S-x)(1-f)]²`

Breaking it down:
- **k = x × y**: The constant product (TOK reserves × QT reserves)
- **x**: TOK currently in the pool
- **S**: Total TOK supply
- **S - x**: TOK outside the pool (available as collateral)
- **f**: Swap fee rate
- **(S-x)(1-f)**: Effective amount after fees when swapping external TOK

This calculates the minimum price if ALL external TOK was dumped into the pool at once.

## Borrowing and Liquidation Logic

### Borrowing Rules
- **Borrow Limit**: `debt ≤ pMin × collateral`
- This is a HARD limit - you cannot borrow more than the guaranteed floor value
- As pMin rises, existing borrowers gain more borrowing power automatically

### Health Monitoring
- **Healthy**: `debt ≤ spotPrice × collateral`
- **Out-of-the-Money (OTM)**: `debt > spotPrice × collateral`
- OTM positions get a 72-hour grace period before liquidation

### Liquidation Process
1. Position marked OTM when underwater at spot price
2. 72-hour grace period begins
3. After grace period, anyone can liquidate
4. Liquidator swaps collateral for QT at spot price
5. Repays debt, keeps profit
6. **Always profitable because spot ≥ pMin and debt was issued at pMin**

## Implementation Details

### OsitoPair (Modified UniswapV2)
- Standard UniV2 with restricted transfers
- Only FeeRouter can receive LP tokens
- Provides `pMin()` view function
- Swap fees: 99% → 0.3% over time

### FeeRouter
- Sole LP token holder
- `collectFees()`: Burns LP, burns TOK, sends QT to treasury
- Fully permissionless - anyone can call

### OsitoToken
- Standard ERC20 with burn function
- Launched through OsitoLaunchpad
- Initial supply goes 100% to AMM

### CollateralVault
- Holds TOK collateral
- Uses Compound V2 BorrowSnapshot pattern
- Isolated per token

### LenderVault (ERC4626)
- Singleton QT lending pool
- Lenders deposit QT, earn yield
- Provides liquidity to all CollateralVaults

## Why This Works

1. **No Risk, Only Efficiency**: The protocol doesn't manage risk - it eliminates it. As pMin rises, capital efficiency improves while maintaining 100% safety.

2. **Self-Reinforcing**: More trading → more fees → more burns → higher pMin → more attractive borrowing → more trading

3. **Immutable and Unstoppable**: No governance, no admin keys, no external dependencies. Just math and code.

4. **Aligned Incentives**: 
   - Traders pay fees that increase pMin
   - Borrowers get increasing capital efficiency
   - Lenders earn yield with zero bad debt risk
   - Keeper bots earn bounties for collecting fees

## Summary

Osito is not a lending protocol that manages risk. It's a lending protocol that **eliminates risk** through mathematical guarantees. The pMin ratchet ensures that every loan is always 100% backed by recoverable value, while continuously improving capital efficiency as the protocol matures.

The genius is in its simplicity: burn tokens to reduce supply, compound fees to increase reserves, and watch as the mathematical floor price (pMin) rises forever, unlocking more borrowing power while maintaining perfect safety.
