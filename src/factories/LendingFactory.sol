// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../core/CollateralVault.sol";
import {LenderVault} from "../core/LenderVault.sol";

contract LendingFactory {
    address public immutable lenderVault;
    
    mapping(address => address) public collateralVaults;
    address[] public allMarkets;

    error MarketExists();
    
    event MarketCreated(
        address indexed pair,
        address lenderVault,
        address collateralVault,
        uint256 marketIndex
    );
    
    constructor(address lendingAsset) {
        lenderVault = address(new LenderVault(lendingAsset, address(this)));
    }
    
    function createLendingMarket(address pair) external returns (address collateralVault) {
        if (collateralVaults[pair] != address(0)) revert MarketExists();
        
        address token0 = IOsitoPair(pair).token0();
        address token1 = IOsitoPair(pair).token1();
        bool tokIsToken0 = IOsitoPair(pair).tokIsToken0();
        address collateralToken = tokIsToken0 ? token0 : token1;
        
        collateralVault = address(new CollateralVault(collateralToken, pair, lenderVault));
        
        LenderVault(lenderVault).authorize(collateralVault);
        
        collateralVaults[pair] = collateralVault;
        allMarkets.push(pair);
        
        emit MarketCreated(pair, lenderVault, collateralVault, allMarkets.length - 1);
    }
    
    function allMarketsLength() external view returns (uint256) {
        return allMarkets.length;
    }
}

interface IOsitoPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tokIsToken0() external view returns (bool);
}