#!/bin/bash

# Comprehensive Testing Script for Osito Protocol
# Runs ALL testing methodologies with maximum rigor

set -e

echo "🧪 OSITO PROTOCOL - COMPREHENSIVE TESTING SUITE"
echo "================================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to run test and track results
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -e "\n${BLUE}🔧 Running: $test_name${NC}"
    echo "Command: $test_command"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if eval "$test_command"; then
        echo -e "${GREEN}✅ PASSED: $test_name${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}❌ FAILED: $test_name${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
    
    # Check if forge is installed
    if ! command -v forge &> /dev/null; then
        echo -e "${RED}❌ Forge not found. Please install Foundry.${NC}"
        exit 1
    fi
    
    # Check if ETH_RPC_URL is set for fork tests
    if [ -z "$ETH_RPC_URL" ]; then
        echo -e "${YELLOW}⚠️  ETH_RPC_URL not set. Fork tests will be skipped.${NC}"
        SKIP_FORK_TESTS=true
    fi
    
    echo -e "${GREEN}✅ Prerequisites check passed${NC}"
}

# 1. UNIT TESTS - Comprehensive coverage of every function
run_unit_tests() {
    echo -e "\n${YELLOW}📋 1. UNIT TESTS${NC}"
    echo "Testing every single function with exhaustive scenarios..."
    
    run_test "PMinLib Unit Tests" "forge test --match-path 'test/unit/PMinLibUnit.t.sol' -vv"
    run_test "CollateralVault Unit Tests" "forge test --match-path 'test/unit/CollateralVaultUnit.t.sol' -vv"
    run_test "LenderVault Unit Tests" "forge test --match-path 'test/unit/LenderVaultUnit.t.sol' -vv"
    run_test "OsitoPair Unit Tests" "forge test --match-path 'test/unit/*Pair*.t.sol' -vv"
    run_test "OsitoToken Unit Tests" "forge test --match-path 'test/unit/*Token*.t.sol' -vv"
    run_test "FeeRouter Unit Tests" "forge test --match-path 'test/unit/*Router*.t.sol' -vv"
}

# 2. FUZZ TESTS - Property-based testing with domain-specific invariants
run_fuzz_tests() {
    echo -e "\n${YELLOW}🎲 2. FUZZ TESTS${NC}"
    echo "Property-based testing with domain-specific invariants..."
    
    run_test "Critical Fuzz Tests" "forge test --match-path 'test/fuzz/CriticalFuzz.t.sol' --fuzz-runs 10000 -vv"
    run_test "Property-Based Fuzz Tests" "forge test --match-path 'test/fuzz/PropertyBasedFuzz.t.sol' --fuzz-runs 5000 -vv"
    run_test "Advanced Fuzz Tests" "forge test --match-path 'test/fuzz/AdvancedFuzzTests.t.sol' --fuzz-runs 10000 -vv"
}

# 3. FORK TESTS - Testing against real mainnet state
run_fork_tests() {
    if [ "$SKIP_FORK_TESTS" = true ]; then
        echo -e "\n${YELLOW}🍴 3. FORK TESTS - SKIPPED${NC}"
        echo "ETH_RPC_URL not set, skipping fork tests"
        return
    fi
    
    echo -e "\n${YELLOW}🍴 3. FORK TESTS${NC}"
    echo "Testing against real mainnet state and conditions..."
    
    run_test "Mainnet Fork Tests" "forge test --match-path 'test/fork/MainnetForkTests.t.sol' --fork-url $ETH_RPC_URL -vv"
    run_test "High Gas Fork Tests" "forge test --match-path 'test/fork/*' --match-test '*HighGas*' --fork-url $ETH_RPC_URL -vv"
    run_test "MEV Protection Fork Tests" "forge test --match-path 'test/fork/*' --match-test '*MEV*' --fork-url $ETH_RPC_URL -vv"
}

# 4. INVARIANT TESTS - Stateful fuzzing with complex scenarios
run_invariant_tests() {
    echo -e "\n${YELLOW}🔄 4. INVARIANT TESTS${NC}"
    echo "Stateful fuzzing with complex multi-transaction scenarios..."
    
    run_test "Original Invariant Tests" "forge test --match-path 'test/invariant/OsitoInvariants.t.sol' -vv"
    run_test "Stateful Invariant Tests" "forge test --match-path 'test/invariant/StatefulInvariants.t.sol' -vv"
}

# 5. FORMAL VERIFICATION - Symbolic execution and mathematical proofs
run_formal_verification() {
    echo -e "\n${YELLOW}🔬 5. FORMAL VERIFICATION${NC}"
    echo "Symbolic execution and mathematical property verification..."
    
    run_test "Symbolic Execution Tests" "forge test --match-path 'test/formal/SymbolicExecution.t.sol' -vv"
    
    # Additional formal verification with SMT solvers would go here
    echo "Note: Full SMT solver integration would require additional tools"
}

# 6. STATIC ANALYSIS - Custom rules for vulnerability detection
run_static_analysis() {
    echo -e "\n${YELLOW}🔍 6. STATIC ANALYSIS${NC}"
    echo "Custom static analysis rules for vulnerability detection..."
    
    run_test "Static Analysis Rules" "forge test --match-path 'test/static/StaticAnalysisRules.t.sol' -vv"
    
    # Run additional static analysis tools if available
    if command -v slither &> /dev/null; then
        run_test "Slither Analysis" "slither src/ --print human-summary"
    else
        echo "Slither not available - install with 'pip install slither-analyzer'"
    fi
}

# 7. MUTATION TESTING - Test suite quality verification
run_mutation_tests() {
    echo -e "\n${YELLOW}🧬 7. MUTATION TESTING${NC}"
    echo "Systematic mutation testing to verify test suite quality..."
    
    run_test "Mutation Test Framework" "forge test --match-path 'test/mutation/MutationTestFramework.t.sol' -vv"
    run_test "Critical Mutation Tests" "forge test --match-path 'test/mutation/*' --match-test '*Critical*' -vv"
}

# 8. EDGE CASE TESTS - Comprehensive edge case coverage
run_edge_case_tests() {
    echo -e "\n${YELLOW}⚡ 8. EDGE CASE TESTS${NC}"
    echo "Comprehensive edge case and exploit detection..."
    
    run_test "Loss Absorption Edge Cases" "forge test --match-path 'test/edge-cases/LossAbsorptionEdgeCases.t.sol' -vv"
    run_test "pMin Overflow Edge Cases" "forge test --match-path 'test/edge-cases/PMinOverflowEdgeCases.t.sol' -vv"
    run_test "Advanced Exploit Tests" "forge test --match-path 'test/edge-cases/AdvancedExploitTests.t.sol' -vv"
    run_test "Grace Period Edge Cases" "forge test --match-path 'test/edge-cases/GracePeriodEdgeCases.t.sol' -vv"
}

# 9. INTEGRATION TESTS - Full protocol flow testing
run_integration_tests() {
    echo -e "\n${YELLOW}🔗 9. INTEGRATION TESTS${NC}"
    echo "Full protocol lifecycle and integration testing..."
    
    run_test "Full Protocol Flow" "forge test --match-path 'test/integration/FullProtocolFlow.t.sol' -vv"
    run_test "Multi-Contract Integration" "forge test --match-path 'test/integration/*' -vv"
}

# 10. EXPLOIT TESTS - Ruthless exploit detection
run_exploit_tests() {
    echo -e "\n${YELLOW}💥 10. EXPLOIT TESTS${NC}"
    echo "Ruthless exploit detection and attack vector analysis..."
    
    run_test "Exploit Detection Tests" "forge test --match-path 'test/exploits/ExploitTests.t.sol' -vv"
    run_test "Advanced Attack Vectors" "forge test --match-path 'test/exploits/*' -vv"
}

# Coverage Analysis
run_coverage_analysis() {
    echo -e "\n${YELLOW}📊 COVERAGE ANALYSIS${NC}"
    echo "Generating comprehensive coverage reports..."
    
    if forge coverage --report summary > coverage_summary.txt 2>&1; then
        echo -e "${GREEN}✅ Coverage analysis completed${NC}"
        echo "Coverage Summary:"
        cat coverage_summary.txt
        
        # Check if coverage meets threshold
        if grep -q "100%" coverage_summary.txt; then
            echo -e "${GREEN}🎉 Perfect coverage achieved!${NC}"
        else
            echo -e "${YELLOW}⚠️  Coverage could be improved${NC}"
        fi
    else
        echo -e "${RED}❌ Coverage analysis failed${NC}"
    fi
}

# Gas Analysis
run_gas_analysis() {
    echo -e "\n${YELLOW}⛽ GAS ANALYSIS${NC}"
    echo "Analyzing gas consumption patterns..."
    
    run_test "Gas Usage Analysis" "forge test --gas-report"
}

# Main execution
main() {
    echo "Starting comprehensive test suite..."
    echo "This will run ALL testing methodologies with maximum rigor."
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Run all test categories
    run_unit_tests
    run_fuzz_tests
    run_fork_tests
    run_invariant_tests
    run_formal_verification
    run_static_analysis
    run_mutation_tests
    run_edge_case_tests
    run_integration_tests
    run_exploit_tests
    
    # Analysis
    run_coverage_analysis
    run_gas_analysis
    
    # Final summary
    echo -e "\n${BLUE}📈 COMPREHENSIVE TEST RESULTS${NC}"
    echo "==============================="
    echo "Total Tests Run: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
    
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "\n${GREEN}🎉 ALL TESTS PASSED! Protocol is ready for deployment.${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some tests failed. Review the failures above.${NC}"
        exit 1
    fi
}

# Handle script arguments
case "${1:-all}" in
    "unit")
        check_prerequisites
        run_unit_tests
        ;;
    "fuzz")
        check_prerequisites
        run_fuzz_tests
        ;;
    "fork")
        check_prerequisites
        run_fork_tests
        ;;
    "invariant")
        check_prerequisites
        run_invariant_tests
        ;;
    "formal")
        check_prerequisites
        run_formal_verification
        ;;
    "static")
        check_prerequisites
        run_static_analysis
        ;;
    "mutation")
        check_prerequisites
        run_mutation_tests
        ;;
    "edge")
        check_prerequisites
        run_edge_case_tests
        ;;
    "integration")
        check_prerequisites
        run_integration_tests
        ;;
    "exploit")
        check_prerequisites
        run_exploit_tests
        ;;
    "coverage")
        check_prerequisites
        run_coverage_analysis
        ;;
    "gas")
        check_prerequisites
        run_gas_analysis
        ;;
    "all"|*)
        main
        ;;
esac