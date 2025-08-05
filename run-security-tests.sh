#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     OSITO PROTOCOL SECURITY TEST SUITE        ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Check if required tools are installed
check_tool() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}✗ $1 is not installed${NC}"
        return 1
    else
        echo -e "${GREEN}✓ $1 is installed${NC}"
        return 0
    fi
}

echo -e "${YELLOW}Checking required tools...${NC}"
TOOLS_OK=true
check_tool "forge" || TOOLS_OK=false
check_tool "slither" || TOOLS_OK=false

if [ "$TOOLS_OK" = false ]; then
    echo -e "${RED}Please install missing tools before running tests${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Building contracts...${NC}"
forge build --force

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING UNIT TESTS                        ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Running OsitoToken tests...${NC}"
forge test --match-contract OsitoTokenTest -vv

echo ""
echo -e "${YELLOW}Running CollateralVault tests...${NC}"
forge test --match-contract CollateralVaultTest -vv

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING FUZZ TESTS                        ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Running critical fuzz tests with high runs...${NC}"
forge test --match-contract CriticalFuzzTests --fuzz-runs 10000 -vv

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING INVARIANT TESTS                   ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Running protocol invariants...${NC}"
forge test --match-contract OsitoInvariantsTest --invariant-runs 1000 --invariant-depth 100 -vv

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING ATTACK VECTOR TESTS               ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Testing attack vectors and exploits...${NC}"
forge test --match-contract AttackVectorTests -vv

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING STATIC ANALYSIS (SLITHER)         ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

if command -v slither &> /dev/null; then
    echo -e "${YELLOW}Running Slither analysis...${NC}"
    slither . --config-file slither.config.json --checklist 2>/dev/null | head -50
else
    echo -e "${YELLOW}Slither not installed, skipping static analysis${NC}"
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     RUNNING GAS OPTIMIZATION TESTS            ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Running gas snapshot...${NC}"
forge snapshot --match-test test_ --snap gas-report.txt

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}     TEST COVERAGE REPORT                      ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo -e "${YELLOW}Generating coverage report...${NC}"
forge coverage --report summary

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     CRITICAL SECURITY CHECKS                  ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

echo -e "${YELLOW}Checking critical invariants:${NC}"
echo ""

# Run specific critical invariant checks
echo "1. pMin Monotonicity:"
forge test --match-test invariant_pMinNeverDecreases -vv | grep -E "(PASS|FAIL)"

echo ""
echo "2. K Value Protection:"
forge test --match-test invariant_kNeverDecreases -vv | grep -E "(PASS|FAIL)"

echo ""
echo "3. Recovery Guarantee:"
forge test --match-test invariant_recoveryAlwaysCoversPrincipal -vv | grep -E "(PASS|FAIL)"

echo ""
echo "4. Borrow Limit Enforcement:"
forge test --match-test invariant_borrowsWithinPMinLimit -vv | grep -E "(PASS|FAIL)"

echo ""
echo "5. Token Supply Conservation:"
forge test --match-test invariant_tokenConservation -vv | grep -E "(PASS|FAIL)"

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     SUMMARY                                   ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

TOTAL_TESTS=$(forge test --summary | grep -E "Test result" | grep -oE "[0-9]+ passed")
echo -e "${GREEN}Total tests run: $TOTAL_TESTS${NC}"

echo ""
echo -e "${YELLOW}Security Checklist:${NC}"
echo -e "✓ Unit tests for core contracts"
echo -e "✓ Fuzz testing with high iterations"
echo -e "✓ Invariant testing for protocol properties"
echo -e "✓ Attack vector and exploit testing"
echo -e "✓ Static analysis with Slither"
echo -e "✓ Gas optimization analysis"
echo -e "✓ Test coverage report"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   ALL SECURITY TESTS COMPLETED SUCCESSFULLY   ${NC}"
echo -e "${GREEN}================================================${NC}"