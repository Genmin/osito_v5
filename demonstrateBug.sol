// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract DemonstratePMinBug {
    
    // Simulate the buggy calculation from PMinLib lines 39-40
    function buggyYFinal(uint256 k, uint256 xFinal) public pure returns (uint256) {
        // This is what PMinLib does:
        // uint256 yFinal = FixedPointMathLib.mulDiv(k, Constants.WAD, xFinal);
        // yFinal = yFinal / Constants.WAD;
        
        uint256 WAD = 1e18;
        uint256 step1 = (k * WAD) / xFinal;  // mulDiv(k, WAD, xFinal)
        uint256 step2 = step1 / WAD;         // divide by WAD
        return step2;
    }
    
    // Correct calculation
    function correctYFinal(uint256 k, uint256 xFinal) public pure returns (uint256) {
        return k / xFinal;
    }
    
    // Test with real numbers
    function demonstrateBug() public pure returns (uint256 buggy, uint256 correct, int256 difference) {
        uint256 k = 90000000000 * 1e36;  // 90 billion * 1e36
        uint256 xFinal = 900001000 * 1e18; // ~900M * 1e18
        
        buggy = buggyYFinal(k, xFinal);
        correct = correctYFinal(k, xFinal);
        difference = int256(buggy) - int256(correct);
        
        // The results will be DIFFERENT due to precision loss!
    }
}