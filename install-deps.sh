#!/bin/bash

echo "Installing dependencies for Osito Protocol..."

# Install forge-std
forge install foundry-rs/forge-std --no-commit

# Install solady
forge install vectorized/solady --no-commit

echo "Dependencies installed!"