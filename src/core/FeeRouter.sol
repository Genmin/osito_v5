// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {OsitoPair} from "./OsitoPair.sol";
import {OsitoToken} from "./OsitoToken.sol";

/// @notice Stateless fee collector - burns TOK and routes QT to treasury
/// @dev ZERO state, ZERO principal - receives only fees from _mintFee
contract FeeRouter {
    using SafeTransferLib for address;
    
    address public immutable treasury;
    address public immutable factory;
    address public immutable pair;
    
    event FeesCollected(uint256 tokBurned, uint256 qtCollected);
    
    constructor(address _treasury, address _pair) {
        treasury = _treasury;
        factory = msg.sender;
        pair = _pair;
    }
    
    /// @notice Collect fees and immediately burn/distribute
    /// @dev Completely stateless - FeeRouter holds ZERO LP between calls
    function collectFees() external {
        OsitoPair pair_ = OsitoPair(pair);
        
        // Trigger fee mint - FeeRouter receives 90% of k growth as LP
        pair_.collectFees();
        
        // Get ALL LP we hold (should only be fees, never principal)
        uint256 feeLp = pair_.balanceOf(address(this));
        if (feeLp == 0) return;  // No fees to collect
        
        // Burn ALL LP to get underlying tokens
        pair_.transfer(pair, feeLp);
        (uint256 amt0, uint256 amt1) = pair_.burn(address(this));
        
        // Identify TOK and QT
        bool tokIs0 = pair_.tokIsToken0();
        address tokAddr = tokIs0 ? pair_.token0() : pair_.token1();
        address qtAddr = tokIs0 ? pair_.token1() : pair_.token0();
        
        uint256 tokAmt = tokIs0 ? amt0 : amt1;
        uint256 qtAmt = tokIs0 ? amt1 : amt0;
        
        // Burn TOK, send QT to treasury
        if (tokAmt > 0) OsitoToken(tokAddr).burn(tokAmt);
        if (qtAmt > 0) qtAddr.safeTransfer(treasury, qtAmt);
        
        emit FeesCollected(tokAmt, qtAmt);
    }
}