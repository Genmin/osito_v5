// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/OsitoPair.sol";
import "../core/LenderVault.sol";
import "../core/CollateralVault.sol";
import "../core/OsitoToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title LensLite - Market Data Aggregator for Osito Protocol V5
 * @notice Provides view functions compatible with the frontend interface
 * @dev Maintains exact same structure as V3 LensLite for seamless migration
 */
contract LensLite {
    struct M {
        address core;                    // OsitoPair address
        address token;                   // TOK token address  
        uint128 T;                       // Token reserves in AMM
        uint128 Q;                       // WETH reserves in AMM
        uint128 B;                       // Burned tokens (initialSupply - currentSupply)
        uint256 pMin;                    // Floor price from pMin ratchet
        uint256 feeBp;                   // Current trading fee (basis points)
        uint256 spotPrice;               // Current market price
        uint256 tvl;                     // Total value locked
        uint256 utilization;             // Lending utilization percentage (basis points)
        uint256 apy;                     // Lending APY (basis points)
        uint256 totalSupply;             // Current token supply
        uint256 totalSupplyImmutable;    // Original token supply (at launch)
        string name;                     // Token name
        string symbol;                   // Token symbol
        string metadataURI;              // Token metadata URI (empty for now)
    }

    // Track all pairs created
    address[] public allPairs;
    mapping(address => bool) public isPair;

    /**
     * @notice Get market data for a range of pairs
     * @param from Starting index
     * @param count Number of markets to return
     * @return out Array of market data structures
     */
    function markets(uint256 from, uint256 count) external view returns (M[] memory out) {
        uint256 totalPairs = allPairs.length;
        if (from >= totalPairs) return out;

        uint256 end = from + count;
        if (end > totalPairs) end = totalPairs;
        
        out = new M[](end - from);
        
        for (uint256 i = from; i < end; i++) {
            address pair = allPairs[i];
            out[i - from] = _getMarketData(pair);
        }
    }

    /**
     * @notice Add a new pair to track (called by anyone)
     * @dev In production, this could be restricted or automated
     */
    function addPair(address pair) external {
        require(!isPair[pair], "ALREADY_ADDED");
        // Verify it's a valid pair by checking interface
        try OsitoPair(pair).token0() returns (address) {
            isPair[pair] = true;
            allPairs.push(pair);
        } catch {
            revert("INVALID_PAIR");
        }
    }

    /**
     * @notice Get total number of pairs
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function _getMarketData(address pair) internal view returns (M memory market) {
        OsitoPair ositoPair = OsitoPair(pair);
        
        // Basic pair info
        market.core = pair;
        address token0 = ositoPair.token0();
        address token1 = ositoPair.token1();
        bool tokIsToken0 = ositoPair.tokIsToken0();
        
        // Determine which is TOK and which is QT (WETH)
        market.token = tokIsToken0 ? token0 : token1;
        address qtToken = tokIsToken0 ? token1 : token0;
        
        // Get reserves
        (uint112 r0, uint112 r1,) = ositoPair.getReserves();
        uint112 rTOK = tokIsToken0 ? r0 : r1;
        uint112 rQT = tokIsToken0 ? r1 : r0;
        
        market.T = rTOK;
        market.Q = rQT;
        
        // Get burned amount
        uint256 initialSupply = ositoPair.initialSupply();
        uint256 currentSupply = ERC20(market.token).totalSupply();
        
        market.totalSupplyImmutable = initialSupply;
        market.totalSupply = currentSupply;
        market.B = uint128(initialSupply > currentSupply ? initialSupply - currentSupply : 0);

        // Price calculations
        market.pMin = ositoPair.pMin();
        market.feeBp = ositoPair.currentFeeBps();
        
        // Calculate spot price
        if (rTOK > 0) {
            market.spotPrice = (uint256(rQT) * 1e18) / uint256(rTOK);
        }

        // TVL calculation (QT value + TOK value at spot price)
        market.tvl = uint256(rQT) + (uint256(rTOK) * market.spotPrice / 1e18);

        // Token metadata
        market.name = ERC20(market.token).name();
        market.symbol = ERC20(market.token).symbol();
        
        // Get metadataURI from OsitoToken
        try OsitoToken(market.token).metadataURI() returns (string memory uri) {
            market.metadataURI = uri;
        } catch {
            market.metadataURI = ""; // Fallback for non-OsitoToken contracts
        }

        // Note: Lending data (utilization, apy) would need LenderVault integration
        // For now, return 0 as these are optional for basic trading
        market.utilization = 0;
        market.apy = 0;
    }

    /**
     * @notice Get user position data (for lending integration)
     * @dev Placeholder for when lending is integrated
     */
    function getUserPosition(address user, address collateralVault) 
        external 
        view 
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 borrowingPower,
            bool canBorrow,
            bool canWithdraw
        ) 
    {
        if (collateralVault == address(0)) {
            return (0, 0, 0, false, false);
        }
        
        // Get actual data from CollateralVault
        CollateralVault vault = CollateralVault(collateralVault);
        bool isHealthy;
        (collateral, debt, isHealthy, , ) = vault.getAccountState(user);
        
        // Calculate borrowing power based on pMin
        address pair = vault.pair();
        uint256 pMin = OsitoPair(pair).pMin();
        borrowingPower = (collateral * pMin) / 1e18;
        
        canBorrow = isHealthy && (debt < borrowingPower);
        canWithdraw = debt == 0;
        
        return (collateral, debt, borrowingPower, canBorrow, canWithdraw);
    }

    /**
     * @notice Get lending market data
     * @dev Returns data for a specific token's lending market
     */
    function getLendingMarket(address token)
        external
        view
        returns (
            address lenderVault,
            address collateralVault,
            uint256 totalDeposits,
            uint256 totalBorrows,
            uint256 utilization,
            uint256 depositAPY,
            uint256 borrowAPY
        )
    {
        // No central registry - lending markets created per token
        return (address(0), address(0), 0, 0, 0, 0, 0);
    }
}