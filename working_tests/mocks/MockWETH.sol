// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped Ether";
    }
    
    function symbol() public pure override returns (string memory) {
        return "WETH";
    }
    
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }
    
    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    receive() external payable {
        deposit();
    }
}