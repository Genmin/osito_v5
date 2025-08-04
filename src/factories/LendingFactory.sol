// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralVault} from "../core/CollateralVault.sol";
import {LenderVault} from "../core/LenderVault.sol";

/// @notice Permissionless vault deployment
/// @dev NO Ownable - anyone can deploy
contract LendingFactory {
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
        // Deploy lender vault first
        lenderVault = address(new LenderVault(lendingAsset, address(0)));
        
        // Deploy collateral vault
        collateralVault = address(new CollateralVault(collateralToken, pair, lenderVault));
        
        // Authorize collateral vault to borrow/repay
        LenderVault(lenderVault).authorize(collateralVault);
        
        emit VaultsDeployed(collateralToken, lendingAsset, pair, collateralVault, lenderVault);
    }
}