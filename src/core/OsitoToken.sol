// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Standard ERC20 with burn - entire supply minted to pair at launch
contract OsitoToken is ERC20 {
    string private _name;
    string private _symbol;
    
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address recipient
    ) {
        _name = name_;
        _symbol = symbol_;
        _mint(recipient, supply);
    }
    
    function name() public view override returns (string memory) {
        return _name;
    }
    
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    /// @notice Burn tokens to reduce total supply (critical for pMin ratchet)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}