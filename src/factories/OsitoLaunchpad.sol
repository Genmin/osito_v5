// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {OsitoToken} from "../core/OsitoToken.sol";
import {OsitoPair} from "../core/OsitoPair.sol";
import {FeeRouter} from "../core/FeeRouter.sol";

/// @notice Permissionless token + pair creation
/// @dev NO Ownable - anyone can launch
contract OsitoLaunchpad {
    address public immutable weth;
    address public immutable treasury;
    
    event TokenLaunched(
        address indexed token,
        address indexed pair,
        address indexed feeRouter,
        string name,
        string symbol,
        uint256 supply,
        string metadataURI
    );
    
    constructor(address _weth, address _treasury) {
        weth = _weth;
        treasury = _treasury;
    }
    
    /// @notice Create token + pair in single tx - PURE ERC20 WETH PATH
    /// @dev Fully permissionless - no restrictions, caller must have WETH
    function launchToken(
        string memory name,
        string memory symbol,
        uint256 supply,
        string memory metadataURI,
        uint256 wethAmount,
        uint256 startFeeBps,
        uint256 endFeeBps,
        uint256 feeDecayTarget
    ) external returns (address token, address pair, address feeRouter) {
        require(startFeeBps >= endFeeBps, "INVALID_FEE_RANGE");
        
        // ATOMIC CONSTRUCTION - eliminates donation attack window
        
        // Step 1: Create token with launchpad as temporary holder
        token = address(new OsitoToken(name, symbol, supply, metadataURI, address(this)));
        
        // Step 2: Create pair with real token address (no placeholder)
        pair = address(new OsitoPair(
            token,      // token0 - real address
            weth,       // token1 - always WETH  
            startFeeBps,
            endFeeBps,
            feeDecayTarget,
            true        // tokIsToken0 = true
        ));
        
        // Step 3: Create FeeRouter with pair address
        feeRouter = address(new FeeRouter(treasury, pair));
        
        // Step 4: Set feeRouter in pair (one-time setter)
        OsitoPair(pair).setFeeRouter(feeRouter);
        
        // Step 5: Transfer all tokens to pair
        OsitoToken(token).transfer(pair, supply);
        
        // Step 6: Transfer WETH to pair
        ERC20(weth).transferFrom(msg.sender, pair, wethAmount);
        
        // Step 7: Mint LP tokens to address(0) - ETERNAL LIQUIDITY LOCK
        OsitoPair(pair).mint(address(0));
        
        emit TokenLaunched(token, pair, feeRouter, name, symbol, supply, metadataURI);
    }
}