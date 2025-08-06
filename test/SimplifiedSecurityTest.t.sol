// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/OsitoToken.sol";

contract SimplifiedSecurityTest is Test {
    
    // Test 1: Supply cap is enforced
    function test_SupplyCapEnforced() public {
        uint256 maxSupply = 2**111;
        
        // Should revert when exceeding max supply
        vm.expectRevert("EXCEEDS_MAX_SUPPLY");
        new OsitoToken(
            "ExcessToken",
            "EXCESS",
            maxSupply + 1,
            "",
            address(this)
        );
        
        // Should succeed at max supply
        OsitoToken validToken = new OsitoToken(
            "ValidToken",
            "VALID",
            maxSupply,
            "",
            address(this)
        );
        
        assertEq(validToken.totalSupply(), maxSupply, "Token should be created with max supply");
    }
    
    // Test 2: Mint is locked after creation
    function test_MintIsLocked() public {
        OsitoToken token = new OsitoToken(
            "TestToken",
            "TEST",
            1_000_000e18,
            "",
            address(this)
        );
        
        // Check mintLocked flag
        assertTrue(token.mintLocked(), "Mint should be permanently locked");
        
        // Verify initial supply
        assertEq(token.totalSupply(), 1_000_000e18, "Initial supply should be set");
        
        // No public mint function exists - can only burn
        assertEq(token.balanceOf(address(this)), 1_000_000e18, "Should have all tokens");
        
        // Burn should work
        token.burn(100e18);
        assertEq(token.totalSupply(), 1_000_000e18 - 100e18, "Burn should reduce supply");
    }
}