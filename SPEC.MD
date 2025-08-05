# Osito Protocol: Technical Specification

## What Osito Actually Is

Osito is **NOT a margin lending protocol**. It is an **options protocol disguised as lending** that eliminates liquidation risk entirely through its pMin mechanism. Borrowing is actually writing a PUT option with strike = pMin.

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

## Borrowing as Options (Not Margin Lending!)

### What Borrowing Actually Is
- **Borrowing = Writing a PUT option** with strike price = pMin
- Deposit TOK collateral, receive QT equal to `collateral × pMin`
- Interest accrues as a fee to maintain the option position
- NO collateralization ratios, NO liquidation risk, NO margin calls

### Position States
- **In-the-Money (ITM)**: `collateral × spot > debt (including interest)`
  - Borrower will repay to reclaim collateral (exercise the option)
- **Out-of-the-Money (OTM)**: `collateral × spot < debt (including interest)`
  - Borrower may walk away (let option expire)
  - Note: The ONLY way to go OTM is interest accumulation, since debt starts at pMin value

### Recovery Process (Not Liquidation!)
1. Position becomes OTM (debt with interest > spot value of collateral)
2. 72-hour grace period begins (convenience for borrowers, not for solvency)
3. After grace period, anyone can trigger recovery
4. Protocol atomically swaps ALL collateral for QT in the AMM
5. Repays original debt to lenders (guaranteed by pMin mechanism)
6. Caller receives small bounty
7. Any excess QT is profit for lenders (the interest)

### Why This is Always Safe
- Debt issued at pMin, which is the mathematical floor
- Even if spot crashes to pMin, swap recovers 100% of principal
- Interest is pure profit when collected
- No external liquidators needed - the AMM is the liquidator
- No solvency risk - protocol remains safe even if recovery is never called

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
- Holds TOK collateral for option positions
- Uses Compound V2 BorrowSnapshot pattern for interest accrual
- Debt = principal (at pMin) + accrued interest
- Recovery via atomic AMM swap when OTM after grace period
- Isolated per token

### LenderVault (ERC4626)
- Singleton QT lending pool
- Lenders deposit QT, earn yield from option premiums (interest)
- Uses Compound's proven interest accrual model
- Provides liquidity to all CollateralVaults
- Principal always recoverable via pMin guarantee

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

Osito is not a lending protocol - it's an **options protocol** where:
- **Borrowing = Writing a PUT** with strike at pMin (the mathematical floor)
- **Interest = Option premium** paid to maintain the position
- **Recovery = Automatic exercise** when positions go OTM

The pMin ratchet ensures that every position is always 100% backed by recoverable value. As pMin rises, writers can issue more PUTs against the same collateral.

The genius is in its simplicity: 
1. Issue options at the mathematical floor (always safe)
2. Collect premiums as interest (pure profit)
3. Auto-exercise OTM positions via AMM (guaranteed recovery)
4. Watch pMin rise forever from burns and fees

No liquidations. No margin calls. No external capital. Just math and inevitability.
