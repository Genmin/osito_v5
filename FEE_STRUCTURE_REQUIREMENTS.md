# Fee Structure Requirements

## Current Issues

1. **No Treasury in LendingFactory/LenderVault**
   - LendingFactory constructor doesn't take treasury address
   - LenderVault has no protocol fee mechanism
   - Currently 100% of interest goes to lenders

2. **Swap Fee Structure**
   - Currently uses standard UniV2 (all fees in pool, 1/6th LP growth as protocol fee)
   - Requirement: 10% stays in pool, 90% to FeeRouter for burn/treasury

## Required Architecture

### ONE TREASURY ADDRESS FOR ENTIRE PROTOCOL
- Set immutably at deployment
- Used by ALL protocol components

### Swap Fees (via FeeRouter)
- 10% stays in pool as liquidity
- 90% unwrapped into:
  - Osito tokens → BURNED (using canonical burn)
  - WETH → sent to TREASURY

### Interest Fees (via LenderVault)
- 90% to lenders
- 10% to TREASURY

## Required Changes

### 1. Update LendingFactory
```solidity
contract LendingFactory {
    address public immutable treasury;  // ADD THIS
    
    constructor(address lendingAsset, address _treasury) {
        treasury = _treasury;  // ADD THIS
        lenderVault = address(new LenderVault(lendingAsset, address(this), _treasury));
    }
}
```

### 2. Update LenderVault
```solidity
contract LenderVault {
    address public immutable treasury;  // ADD THIS
    uint256 public constant PROTOCOL_FEE_BPS = 1000; // 10%
    
    constructor(address asset_, address _factory, address _treasury) {
        treasury = _treasury;  // ADD THIS
        // ... rest
    }
    
    // Modify _accrue() to allocate 10% of interest to treasury
}
```

### 3. Swap Fee Consideration
The 10%/90% swap fee split deviates from battle-tested UniV2. Options:
1. Keep UniV2 mechanism (safer, battle-tested)
2. Implement custom split (more complex, untested)

## Questions
1. Should we keep UniV2 fee mechanism or implement custom 10%/90% split?
2. How should the 10% treasury fee be collected in LenderVault?