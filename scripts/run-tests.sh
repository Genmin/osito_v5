#!/bin/bash

# Osito Protocol Comprehensive Testing Suite

echo "🔍 Running Osito Protocol Comprehensive Testing Suite"
echo "===================================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to run a test category
run_test() {
    local test_name=$1
    local test_command=$2
    
    echo -e "\n${YELLOW}Running ${test_name}...${NC}"
    if eval "$test_command"; then
        echo -e "${GREEN}✓ ${test_name} passed${NC}"
        return 0
    else
        echo -e "${RED}✗ ${test_name} failed${NC}"
        return 1
    fi
}

# Track failures
FAILED_TESTS=()

# 1. Unit Tests
run_test "Unit Tests" "forge test --match-path test/unit/*.t.sol -vvv" || FAILED_TESTS+=("Unit Tests")

# 2. Fuzz Tests
run_test "Fuzz Tests" "forge test --match-path test/fuzz/*.t.sol -vvv --fuzz-runs 10000" || FAILED_TESTS+=("Fuzz Tests")

# 3. Invariant Tests
run_test "Invariant Tests" "forge test --match-path test/invariant/*.t.sol -vvv --invariant-runs 1000 --invariant-depth 50" || FAILED_TESTS+=("Invariant Tests")

# 4. Gas Benchmarks
echo -e "\n${YELLOW}Running Gas Benchmarks...${NC}"
forge test --gas-report > gas-report.txt
echo -e "${GREEN}✓ Gas report saved to gas-report.txt${NC}"

# 5. Coverage Report
echo -e "\n${YELLOW}Generating Coverage Report...${NC}"
forge coverage --report lcov
forge coverage --report summary
echo -e "${GREEN}✓ Coverage report generated${NC}"

# 6. Static Analysis with Slither
if command -v slither &> /dev/null; then
    echo -e "\n${YELLOW}Running Slither Static Analysis...${NC}"
    slither . --checklist > slither-report.md 2>&1
    echo -e "${GREEN}✓ Slither report saved to slither-report.md${NC}"
else
    echo -e "${YELLOW}⚠ Slither not installed, skipping static analysis${NC}"
fi

# 7. Mythril Security Analysis
if command -v myth &> /dev/null; then
    echo -e "\n${YELLOW}Running Mythril Security Analysis...${NC}"
    for contract in src/core/*.sol; do
        echo "Analyzing $contract..."
        myth analyze "$contract" --solc-json mythril-config.json > "mythril-$(basename $contract .sol).txt" 2>&1
    done
    echo -e "${GREEN}✓ Mythril reports generated${NC}"
else
    echo -e "${YELLOW}⚠ Mythril not installed, skipping security analysis${NC}"
fi

# 8. Formal Verification with Certora
if command -v certoraRun &> /dev/null; then
    echo -e "\n${YELLOW}Running Certora Formal Verification...${NC}"
    certoraRun test/formal/certora.conf
else
    echo -e "${YELLOW}⚠ Certora not installed, skipping formal verification${NC}"
fi

# Summary
echo -e "\n===================================================="
echo -e "${YELLOW}Testing Summary:${NC}"

if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Failed tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "${RED}  - $test${NC}"
    done
    exit 1
fi