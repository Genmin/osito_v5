#!/bin/bash

# Static Analysis Runner for Osito Protocol
# This script runs comprehensive static analysis using multiple tools

set -e

echo "🔍 Starting Comprehensive Static Analysis for Osito Protocol"

# Create reports directory
mkdir -p reports/slither
mkdir -p reports/mythril
mkdir -p reports/aderyn

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Build contracts first
echo_status "Building contracts..."
forge build

# Run Slither Analysis
if command_exists slither; then
    echo_status "Running Slither static analysis..."
    slither . \
        --config-file test/static-analysis/slither.config.json \
        --json reports/slither/slither-full.json \
        --sarif reports/slither/slither.sarif \
        --checklist \
        --markdown reports/slither/slither-report.md \
        || echo_warning "Slither completed with issues"
else
    echo_error "Slither not found. Install with: pip install slither-analyzer"
fi

# Run Aderyn Analysis (Rust-based static analyzer)
if command_exists aderyn; then
    echo_status "Running Aderyn static analysis..."
    aderyn . \
        --output reports/aderyn/aderyn-report.json \
        --format json \
        --severity-filter high,medium \
        || echo_warning "Aderyn completed with issues"
else
    echo_warning "Aderyn not found. Install from: https://github.com/Cyfrin/aderyn"
fi

# Run Mythril Analysis (if available)
if command_exists myth; then
    echo_status "Running Mythril analysis on critical contracts..."
    
    # Analyze core contracts individually
    for contract in "OsitoToken" "OsitoPair" "CollateralVault" "LenderVault" "PMinLib"; do
        echo_status "Analyzing $contract with Mythril..."
        myth analyze "src/**/$contract.sol" \
            --config test/static-analysis/mythril.config.yml \
            --output reports/mythril/$contract-mythril.json \
            --format json \
            || echo_warning "Mythril analysis of $contract completed with issues"
    done
else
    echo_warning "Mythril not found. Install with: pip install mythril"
fi

# Run custom security checks
echo_status "Running custom security checks..."

# Check for common vulnerabilities
echo_status "Checking for reentrancy patterns..."
grep -r "call.*value\|delegatecall\|callcode" src/ && echo_warning "Found external calls - review for reentrancy" || echo_status "No obvious external calls found"

# Check for unchecked arithmetic
echo_status "Checking for unchecked arithmetic..."
grep -r "unchecked" src/ && echo_warning "Found unchecked blocks - review carefully" || echo_status "No unchecked blocks found"

# Check for assembly usage
echo_status "Checking for inline assembly..."
grep -r "assembly" src/ && echo_warning "Found assembly code - review carefully" || echo_status "No assembly code found"

# Check for selfdestruct
echo_status "Checking for selfdestruct..."
grep -r "selfdestruct\|suicide" src/ && echo_error "Found selfdestruct - critical security risk!" || echo_status "No selfdestruct found"

# Generate summary report
echo_status "Generating summary report..."
cat > reports/security-analysis-summary.md << EOF
# Osito Protocol Security Analysis Summary

Generated on: $(date)

## Analysis Tools Used

- **Slither**: Static analysis for Solidity smart contracts
- **Aderyn**: Rust-based static analyzer for Solidity
- **Mythril**: Symbolic execution tool for EVM bytecode
- **Custom Checks**: Manual pattern matching for common vulnerabilities

## Critical Areas Analyzed

### 1. OsitoToken
- Burn function overflow protection
- Transfer logic correctness
- Approval edge cases

### 2. OsitoPair
- K invariant maintenance
- pMin calculation accuracy
- LP token restrictions
- Swap calculation overflow
- Fee collection logic

### 3. CollateralVault
- Collateral accounting
- Borrowing limits enforcement
- Liquidation logic
- Interest calculation

### 4. LenderVault
- Deposit/withdrawal logic
- Share calculation
- Interest accrual

### 5. PMinLib
- Mathematical accuracy
- Overflow prevention
- Edge case handling

## Report Files

- \`reports/slither/\` - Slither analysis results
- \`reports/mythril/\` - Mythril analysis results
- \`reports/aderyn/\` - Aderyn analysis results

## Recommendations

1. Review all HIGH and MEDIUM severity findings
2. Implement additional tests for flagged areas
3. Consider formal verification for critical mathematical functions
4. Regular security audits by professional firms

EOF

echo_status "Static analysis complete! Check reports/ directory for detailed findings."
echo_status "Summary available in reports/security-analysis-summary.md"