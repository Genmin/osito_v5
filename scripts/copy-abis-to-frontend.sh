#!/bin/bash

# Copy V5 ABIs to frontend
echo "Copying V5 ABIs to frontend..."

# Source directory
SRC_DIR="/Users/joeyroth/Desktop/ositoship/osito_v5/out"
# Destination directory
DEST_DIR="/Users/joeyroth/Desktop/ositoship/Ositoapp/constants/artifacts"

# Core V5 contracts
cp "$SRC_DIR/OsitoLaunchpad.sol/OsitoLaunchpad.json" "$DEST_DIR/OsitoLaunchpad.json"
cp "$SRC_DIR/OsitoPair.sol/OsitoPair.json" "$DEST_DIR/OsitoPair.json"
cp "$SRC_DIR/OsitoToken.sol/OsitoToken.json" "$DEST_DIR/OsitoToken.json"
cp "$SRC_DIR/FeeRouter.sol/FeeRouter.json" "$DEST_DIR/FeeRouter.json"
cp "$SRC_DIR/LendingFactory.sol/LendingFactory.json" "$DEST_DIR/LendingFactory.json"
cp "$SRC_DIR/LenderVault.sol/LenderVault.json" "$DEST_DIR/LenderVault.json"
cp "$SRC_DIR/CollateralVault.sol/CollateralVault.json" "$DEST_DIR/CollateralVault.json"
cp "$SRC_DIR/LensLite.sol/LensLite.json" "$DEST_DIR/LensLite.json"
cp "$SRC_DIR/SwapRouter.sol/SwapRouter.json" "$DEST_DIR/SwapRouter.json"

echo "✅ V5 ABIs copied successfully!"