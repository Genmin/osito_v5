// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../core/CollateralVault.sol";
import {LenderVault} from "../core/LenderVault.sol";

/// @notice Permissionless vault deployment
/// @dev NO Ownable - anyone can deploy
contract LendingFactory {
    // Uniswap V2-style mappings for vault discovery
    mapping(address => mapping(address => address)) public getCollateralVault; // collateralToken => lendingAsset => vault
    mapping(address => mapping(address => address)) public getLenderVault;     // lendingAsset => collateralToken => vault  
    address[] public allCollateralVaults;
    address[] public allLenderVaults;

    event VaultsDeployed(
        address indexed collateralToken,
        address indexed lendingAsset,
        address indexed pair,
        address collateralVault,
        address lenderVault
    );
    
    /// @notice Deploy lending vaults for any pair
    /// @dev Fully permissionless - no restrictions
    function deployVaults(
        address collateralToken,
        address lendingAsset,
        address pair
    ) external returns (address collateralVault, address lenderVault) {
        // Prevent duplicate deployments (Uniswap V2 pattern)
        require(getCollateralVault[collateralToken][lendingAsset] == address(0), 'LendingFactory: VAULT_EXISTS');
        
        // Deploy lender vault first
        lenderVault = address(new LenderVault(lendingAsset, address(0)));
        
        // Deploy collateral vault
        collateralVault = address(new CollateralVault(collateralToken, pair, lenderVault));
        
        // Authorize collateral vault to borrow/repay
        LenderVault(lenderVault).authorize(collateralVault);
        
        // Store vault addresses (Uniswap V2 pattern)
        getCollateralVault[collateralToken][lendingAsset] = collateralVault;
        getLenderVault[lendingAsset][collateralToken] = lenderVault;
        allCollateralVaults.push(collateralVault);
        allLenderVaults.push(lenderVault);
        
        emit VaultsDeployed(collateralToken, lendingAsset, pair, collateralVault, lenderVault);
    }

    // Enumeration functions (Uniswap V2 pattern)
    function allCollateralVaultsLength() external view returns (uint) {
        return allCollateralVaults.length;
    }

    function allLenderVaultsLength() external view returns (uint) {
        return allLenderVaults.length;
    }
}