# FeeRouter Architecture Fix

## Problem
The FeeRouter implementation was inconsistent with the protocol architecture where each pair has its own FeeRouter instance.

## Original Implementation (INCORRECT)
```solidity
contract FeeRouter {
    mapping(address => uint256) public principalLp; // ❌ Suggests managing multiple pairs
    
    function setPrincipalLp(address pair) external { // ❌ Takes pair parameter
        principalLp[pair] = ...
    }
    
    function collectFees(address pair) external { // ❌ Takes pair parameter
        uint256 principal = principalLp[pair];
        ...
    }
}
```

## Fixed Implementation (CORRECT)
```solidity
contract FeeRouter {
    address public pair;                    // ✅ One pair per FeeRouter
    uint256 public principalLp;            // ✅ Single value, not mapping
    
    function setPrincipalLp(address _pair) external { // ✅ Sets the pair once
        require(pair == address(0), "ALREADY_SET");
        pair = _pair;
        principalLp = ...
    }
    
    function collectFees() external {      // ✅ No pair parameter needed
        // Works with the single pair this FeeRouter manages
    }
}
```

## Architecture Confirmation

**SINGLETONS:**
- OsitoLaunchpad (factory)
- LendingFactory (factory)  
- LenderVault (one WETH lending pool)

**DEPLOYED PER TOKEN/PAIR:**
- OsitoToken (one per launch)
- OsitoPair (one per launch)
- FeeRouter (one per launch)
- CollateralVault (one per pair, deployed by LendingFactory)

## Benefits
1. Cleaner architecture - each FeeRouter manages exactly one pair
2. Gas efficient - no mapping lookups
3. Matches keeper script expectations
4. Follows single responsibility principle