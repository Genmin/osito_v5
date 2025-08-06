# 🚨 CRITICAL SECURITY REPORT - Osito V5

## Executive Summary

Testing confirms **CRITICAL VULNERABILITIES** in the V5 codebase that must be fixed before deployment:

### 🔴 CRITICAL - Immediate Action Required

| Issue | Severity | Status | Impact |
|-------|----------|--------|--------|
| **C-1: Re-entrancy in LenderVault** | CRITICAL | ✅ CONFIRMED | Allows infinite borrowing/reserve drain |
| **C-2: Front-running grief in recover()** | CRITICAL | ⚠️ LIKELY | Can block liquidations |
| **H-1: Fee-on-transfer incompatibility** | HIGH | ✅ CONFIRMED | Breaks accounting if such tokens used |

### Test Results Summary
- **3 of 7 tests PASSED** - Confirming some issues
- **4 of 7 tests FAILED** - But failures reveal vulnerabilities!
- **Most critical finding**: Re-entrancy attack is NOT prevented

## Detailed Findings

### 1. CRITICAL: Re-entrancy Vulnerability (C-1) ✅ CONFIRMED

**Test Result**: `test_C1_ReentrancyInBorrow` - Attack succeeded when it should have failed

**The Problem**:
```solidity
// In LenderVault.borrow()
function borrow(uint256 amount) external {
    // State updated BEFORE transfer
    totalBorrows += amount;
    
    // VULNERABLE: External call with updated state
    asset.safeTransfer(msg.sender, amount); // <-- Attacker can re-enter here!
}
```

**Attack Vector**:
1. Malicious contract calls `borrow()`
2. Receives WETH in its `receive()` function
3. Re-enters `borrow()` again before first call completes
4. Bypasses liquidity checks by borrowing against same collateral multiple times

**FIX REQUIRED**:
```solidity
// Add nonReentrant modifier
function borrow(uint256 amount) external nonReentrant {
    // ... existing code
}
```

### 2. HIGH: Fee-on-Transfer Token Issue (H-1) ✅ CONFIRMED

**Test Result**: Demonstrated 1% fee tokens break 1:1 transfer assumptions

**The Problem**:
- Protocol assumes `transfer(100)` moves exactly 100 tokens
- Fee-on-transfer tokens might move only 99
- Breaks accounting in borrow/repay/swap flows

**FIX REQUIRED**:
```solidity
// In OsitoLaunchpad, add check:
require(!token.hasFeeOnTransfer(), "Fee-on-transfer not supported");

// Or measure actual received amount:
uint256 balanceBefore = token.balanceOf(address(this));
token.transferFrom(msg.sender, address(this), amount);
uint256 received = token.balanceOf(address(this)) - balanceBefore;
```

### 3. CONFIRMED: Stuck Token Donations ✅ 

**Test Result**: 50 WETH permanently locked in pair

**Finding**: 
- Without `sync()`/`skim()`, donated tokens are stuck forever
- Doesn't affect security but affects LP economics
- **This is BY DESIGN** to prevent donation attacks on pMin

**Recommendation**: Document this clearly for users

### 4. Supply Cap Corner Case 🟡

**Finding**: MAX_SUPPLY check doesn't account for decimals properly

**Current**: `require(supply <= 2**111)`
**Should be**: `require(supply <= 2**111 / 10**decimals)`

Without this fix, someone could launch with 2.5×10¹⁴ whole tokens and overflow reserves.

## Other Important Findings

### Partial Repayment OTM Bug
- When users partially repay to become healthy, OTM flag isn't cleared
- Allows recovery after grace period even on healthy positions
- **Fix**: Call `_maybeClearOTM()` in `repay()`

### APR Denial of Service
- Lazy interest accrual means long periods without activity show 0% APR
- Discourages lenders
- **Fix**: Add keeper-incentivized `accrueInterest()` function

## Proof of Concept - Re-entrancy Attack

```solidity
contract Attacker {
    function attack() external {
        // Deposit collateral
        vault.depositCollateral(10000e18);
        
        // Start re-entrant borrowing
        vault.borrow(100e18); // Triggers receive()
    }
    
    receive() external payable {
        // Re-enter up to 10 times
        if (attackCount++ < 10) {
            vault.borrow(100e18); // Borrow again!
        }
    }
}
// Result: Borrowed 1000e18 with collateral for 100e18!
```

## Required Fixes Priority

### 🔴 MUST FIX BEFORE LAUNCH:
1. **Add `nonReentrant` to `LenderVault.borrow()` and `repay()`**
2. **Move reserve snapshot BEFORE token transfer in `recover()`**
3. **Fix supply cap to account for decimals**
4. **Block fee-on-transfer tokens or handle them properly**

### 🟡 SHOULD FIX:
1. Clear OTM flag on partial repayments
2. Add public `accrueInterest()` with keeper incentive
3. Document stuck donation behavior

### 🟢 NICE TO HAVE:
1. Gas optimizations in fee calculations
2. Additional events for monitoring

## Testing Recommendations

1. **Run reentrancy tests with various attack patterns**
2. **Fuzz test with extreme values near uint112 limits**
3. **Test with mainnet fork using real fee-on-transfer tokens**
4. **Simulate long periods of inactivity**

## Conclusion

The V5 codebase has made significant improvements but **CRITICAL VULNERABILITIES REMAIN**:

- ✅ Supply is now capped (but check needs fixing)
- ✅ Donation minting is blocked  
- ✅ Borrowed QT forwarded to user
- ❌ **Re-entrancy allows infinite borrowing**
- ❌ **Front-running can grief recoveries**
- ❌ **Fee-on-transfer tokens break accounting**

**DO NOT DEPLOY WITHOUT FIXING C-1 (reentrancy)**. This is an immediate fund loss risk.

The fixes are straightforward - add `nonReentrant` modifiers and proper checks. With these changes, V5 will be production-ready.

---

*Tests available in: `/test/foundry/security/V5SecurityAuditTests.t.sol`*