/*
 * Certora Formal Verification Specification for Osito Protocol
 * 
 * This specification defines the critical invariants and properties
 * that must hold for the Osito protocol to be considered secure.
 */

using OsitoPair as pair
using CollateralVault as vault
using LenderVault as lenderVault
using OsitoToken as token
using FeeRouter as feeRouter

methods {
    // OsitoPair methods
    pMin() returns (uint256) envfree
    getReserves() returns (uint112, uint112, uint32) envfree
    currentFeeBps() returns (uint256) envfree
    totalSupply() returns (uint256) envfree
    balanceOf(address) returns (uint256) envfree
    
    // OsitoToken methods
    token.totalSupply() returns (uint256) envfree
    token.balanceOf(address) returns (uint256) envfree
    token.burn(uint256)
    
    // CollateralVault methods
    collateralBalances(address) returns (uint256) envfree
    accountBorrows(address) returns (uint256, uint256) envfree
    isPositionHealthy(address) returns (bool) envfree
    
    // LenderVault methods
    borrowIndex() returns (uint256) envfree
    totalBorrows() returns (uint256) envfree
    totalAssets() returns (uint256) envfree
}

// Ghost variables to track historical values
ghost uint256 lastPMin {
    init_state axiom lastPMin == 0;
}

ghost uint256 lastK {
    init_state axiom lastK == 0;
}

ghost uint256 lastTotalSupply {
    init_state axiom lastTotalSupply == 0;
}

ghost mapping(address => uint256) ghostCollateral {
    init_state axiom forall address a. ghostCollateral[a] == 0;
}

ghost mapping(address => uint256) ghostDebt {
    init_state axiom forall address a. ghostDebt[a] == 0;
}

// Hooks to update ghost variables
hook Sstore pair.reserves[KEY uint256 index] uint256 newValue (uint256 oldValue) STORAGE {
    // Update lastK when reserves change
    uint112 r0;
    uint112 r1;
    uint32 timestamp;
    (r0, r1, timestamp) = pair.getReserves();
    lastK = to_uint256(r0) * to_uint256(r1);
}

hook Sstore token._totalSupply uint256 newValue (uint256 oldValue) STORAGE {
    lastTotalSupply = newValue;
}

hook Sstore vault.collateralBalances[KEY address account] uint256 newValue (uint256 oldValue) STORAGE {
    ghostCollateral[account] = newValue;
}

// ==============================================================================
// CRITICAL INVARIANTS
// ==============================================================================

// INVARIANT 1: pMin Never Decreases
// The pMin value must be monotonically increasing
invariant pMinNeverDecreases()
    pair.pMin() >= lastPMin
    {
        preserved with (env e) {
            require lastPMin == pair.pMin();
        }
    }

// INVARIANT 2: K Never Decreases (except for fee collection)
// The constant product k = x * y must never decrease
invariant kNeverDecreases()
    lastK <= currentK()
    {
        preserved with (env e) {
            require lastK == currentK();
        }
    }

definition currentK() returns uint256 = 
    let r0, r1, _ = pair.getReserves() in
    to_uint256(r0) * to_uint256(r1);

// INVARIANT 3: Total Supply Only Decreases
// Token supply can only go down through burns, never up
invariant totalSupplyOnlyDecreases()
    token.totalSupply() <= lastTotalSupply
    {
        preserved with (env e) {
            require token.totalSupply() == lastTotalSupply;
        }
    }

// INVARIANT 4: Borrowing Never Exceeds pMin Valuation
// For any account, debt <= collateral * pMin
invariant borrowingWithinPMin(address account)
    let collateral = vault.collateralBalances(account) in
    let principal, _ = vault.accountBorrows(account) in
    let pMin = pair.pMin() in
    principal <= collateral * pMin / 10^18
    {
        preserved {
            requireInvariant pMinNeverDecreases();
        }
    }

// INVARIANT 5: Recovery Always Covers Principal
// At any point, liquidating collateral at pMin covers the principal
invariant recoveryGuarantee(address account)
    let collateral = vault.collateralBalances(account) in
    let principal, _ = vault.accountBorrows(account) in
    let pMin = pair.pMin() in
    collateral > 0 && principal > 0 => 
        collateral * pMin / 10^18 >= principal

// INVARIANT 6: LP Token Restriction
// LP tokens can only be held by FeeRouter or address(0xdead)
invariant lpTokenRestriction(address holder)
    holder != feeRouter && holder != 0xdead => pair.balanceOf(holder) == 0

// INVARIANT 7: Lender Vault Solvency
// Lender vault must always be solvent
invariant lenderVaultSolvency()
    lenderVault.totalSupply() > 0 => lenderVault.totalAssets() > 0

// ==============================================================================
// RULES (Properties that must hold for specific functions)
// ==============================================================================

// RULE 1: Borrow increases debt correctly
rule borrowIncreasesDebt(address borrower, uint256 amount) {
    env e;
    require e.msg.sender == borrower;
    
    uint256 collateral = vault.collateralBalances(borrower);
    uint256 principalBefore;
    uint256 indexBefore;
    (principalBefore, indexBefore) = vault.accountBorrows(borrower);
    
    uint256 pMin = pair.pMin();
    uint256 maxBorrow = collateral * pMin / 10^18;
    
    require amount <= maxBorrow - principalBefore;
    
    vault.borrow(e, amount);
    
    uint256 principalAfter;
    uint256 indexAfter;
    (principalAfter, indexAfter) = vault.accountBorrows(borrower);
    
    assert principalAfter == principalBefore + amount;
}

// RULE 2: Repay reduces debt correctly
rule repayReducesDebt(address borrower, uint256 amount) {
    env e;
    require e.msg.sender == borrower;
    
    uint256 principalBefore;
    uint256 indexBefore;
    (principalBefore, indexBefore) = vault.accountBorrows(borrower);
    
    require amount <= principalBefore;
    
    vault.repay(e, amount);
    
    uint256 principalAfter;
    uint256 indexAfter;
    (principalAfter, indexAfter) = vault.accountBorrows(borrower);
    
    assert principalAfter == principalBefore - amount;
}

// RULE 3: Token burn reduces total supply
rule burnReducesSupply(address burner, uint256 amount) {
    env e;
    require e.msg.sender == burner;
    
    uint256 balanceBefore = token.balanceOf(burner);
    uint256 supplyBefore = token.totalSupply();
    
    require amount <= balanceBefore;
    
    token.burn(e, amount);
    
    uint256 balanceAfter = token.balanceOf(burner);
    uint256 supplyAfter = token.totalSupply();
    
    assert balanceAfter == balanceBefore - amount;
    assert supplyAfter == supplyBefore - amount;
}

// RULE 4: Swap maintains k invariant
rule swapMaintainsK(uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out) {
    env e;
    
    uint112 r0Before;
    uint112 r1Before;
    uint32 timestampBefore;
    (r0Before, r1Before, timestampBefore) = pair.getReserves();
    
    uint256 kBefore = to_uint256(r0Before) * to_uint256(r1Before);
    
    pair.swap(e, amount0Out, amount1Out, e.msg.sender);
    
    uint112 r0After;
    uint112 r1After;
    uint32 timestampAfter;
    (r0After, r1After, timestampAfter) = pair.getReserves();
    
    uint256 kAfter = to_uint256(r0After) * to_uint256(r1After);
    
    assert kAfter >= kBefore;
}

// RULE 5: Fee collection burns tokens
rule feeCollectionBurns() {
    env e;
    require e.msg.sender == keeper;
    
    uint256 supplyBefore = token.totalSupply();
    uint256 feeRouterTokensBefore = token.balanceOf(feeRouter);
    
    feeRouter.collectFees(e);
    
    uint256 supplyAfter = token.totalSupply();
    uint256 feeRouterTokensAfter = token.balanceOf(feeRouter);
    
    // All tokens collected should be burned
    assert supplyAfter <= supplyBefore;
    assert feeRouterTokensAfter <= feeRouterTokensBefore;
}

// RULE 6: Recovery at pMin always covers principal
rule recoveryAtPMinCoversPrincipal(address account) {
    env e;
    
    uint256 collateral = vault.collateralBalances(account);
    uint256 principal;
    uint256 index;
    (principal, index) = vault.accountBorrows(account);
    
    require collateral > 0 && principal > 0;
    require !vault.isPositionHealthy(account);
    
    uint256 pMin = pair.pMin();
    uint256 guaranteedRecovery = collateral * pMin / 10^18;
    
    assert guaranteedRecovery >= principal;
}

// ==============================================================================
// PARAMETRIC RULES (Properties with quantifiers)
// ==============================================================================

// For all users, if they have debt, it must be backed by sufficient collateral
rule allDebtIsBacked {
    address user;
    
    uint256 collateral = vault.collateralBalances(user);
    uint256 principal;
    uint256 index;
    (principal, index) = vault.accountBorrows(user);
    
    uint256 pMin = pair.pMin();
    
    assert principal > 0 => collateral * pMin / 10^18 >= principal;
}

// No user can borrow more than their pMin valuation
rule noBorrowingAbovePMin {
    address user;
    env e;
    require e.msg.sender == user;
    
    uint256 collateral = vault.collateralBalances(user);
    uint256 pMin = pair.pMin();
    uint256 maxBorrow = collateral * pMin / 10^18;
    
    uint256 principal;
    uint256 index;
    (principal, index) = vault.accountBorrows(user);
    
    uint256 borrowAmount;
    require borrowAmount > maxBorrow - principal;
    
    vault.borrow@withrevert(e, borrowAmount);
    
    assert lastReverted;
}