# 🚀 Osito Protocol V5 - Mainnet Deployment Guide

This guide provides step-by-step instructions for deploying Osito Protocol V5 to Berachain Mainnet.

## 📋 Pre-Deployment Checklist

### 1. Environment Setup
```bash
# Create mainnet environment file
cp .env.testnet .env.mainnet

# Update .env.mainnet with mainnet values:
CHAIN_ID=80084
RPC_URL=https://rpc.berachain.com/
WBERA_ADDRESS=0x7507c1dc16935B82698e4C63f2746A5fCf453D92
TREASURY=<MAINNET_TREASURY_ADDRESS>
PRIVATE_KEY=<MAINNET_DEPLOUER_PRIVATE_KEY>
```

### 2. Verification Requirements
- [ ] Deployer wallet has sufficient BERA for gas
- [ ] Treasury address is set correctly
- [ ] All contracts compile without errors
- [ ] Testnet deployment fully tested

## 🏗️ Deployment Steps

### Step 1: Deploy Contracts
```bash
# Deploy all V5 contracts to mainnet
forge script script/MainnetDeployment.s.sol \
  --rpc-url https://rpc.berachain.com/ \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### Step 2: Verify Deployment
```bash
# Verify each contract bytecode on-chain
cast code <OSITO_LAUNCHPAD> --rpc-url https://rpc.berachain.com/
cast code <LENDING_FACTORY> --rpc-url https://rpc.berachain.com/
cast code <LENS_LITE> --rpc-url https://rpc.berachain.com/
cast code <SWAP_ROUTER> --rpc-url https://rpc.berachain.com/
cast code <LENDER_VAULT> --rpc-url https://rpc.berachain.com/
```

### Step 3: Update Frontend
```bash
# Update wagmi configuration
cd ../OsitoappV5
```

Edit `wagmi.config.ts`:
```typescript
const ADDR = {
  "80084": { // Berachain mainnet
    "OsitoLaunchpad": "<DEPLOYED_ADDRESS>",
    "LendingFactory": "<DEPLOYED_ADDRESS>", 
    "LensLite": "<DEPLOYED_ADDRESS>",
    "SwapRouter": "<DEPLOYED_ADDRESS>",
    "WBERA": "0x7507c1dc16935B82698e4C63f2746A5fCf453D92"
  }
}
```

```bash
# Regenerate contracts and build
npm run generate
npm run build
```

### Step 4: Deploy Subgraph
```bash
cd ../ositocharts/subgraph

# Update subgraph.yaml for mainnet
# Change network to: berachain
# Update contract addresses
# Set appropriate startBlock

# Build and deploy
npm run build
../goldsky subgraph deploy ositoapp-mainnet/1.0.0 --path .
```

### Step 5: Update Charts Frontend
```bash
cd ../frontend

# Update .env.production
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/.../ositoapp-mainnet/1.0.0/gn
```

## 🧪 Testing Protocol

### 1. Token Launch Test
```bash
# Test creating a new token
# Verify it appears in LensLite
# Confirm automatic pair registration
```

### 2. Trading Test  
```bash
# Test SwapRouter buy/sell
# Verify price movements
# Check subgraph data collection
```

### 3. Lending Test
```bash
# Create lending market
# Test deposit/borrow flow
# Verify singleton LenderVault
```

## 📊 Post-Deployment Monitoring

### Key Metrics to Track
- **Gas Costs**: Monitor deployment and operation costs
- **Transaction Success Rate**: Ensure high reliability
- **Subgraph Sync**: Verify data collection works
- **User Activity**: Track token launches and trades
- **Protocol Revenue**: Monitor treasury accumulation

### Monitoring Tools
- **Berascan**: Transaction and contract verification
- **Goldsky Dashboard**: Subgraph performance 
- **Frontend Analytics**: User interaction tracking
- **Custom Dashboards**: Protocol-specific metrics

## 🔧 Configuration Files

### Mainnet Environment (.env.mainnet)
```bash
# Berachain Mainnet Configuration
PRIVATE_KEY=<SECURE_MAINNET_KEY>
RPC_URL=https://rpc.berachain.com/
CHAIN_ID=80084
ETHERSCAN_API_KEY=<BERASCAN_API_KEY>

# Core Token Addresses
QT_TOKEN=0x7507c1dc16935B82698e4C63f2746A5fCf453D92
WBERA_ADDRESS=0x7507c1dc16935B82698e4C63f2746A5fCf453D92

# Treasury & Fee Collection
TREASURY=<MAINNET_TREASURY_ADDRESS>
TREASURY_FEE_RATE=100000000000000000  # 10% (0.1e18)

# Deployed Contract Addresses (filled after deployment)
OSITO_LAUNCHPAD=
LENDING_FACTORY=
LENS_LITE=
SWAP_ROUTER=
LENDER_VAULT=
```

### Frontend Mainnet Config
```typescript
// wagmi.config.ts mainnet section
"80084": { // Berachain mainnet  
  "OsitoLaunchpad": "<DEPLOYED_ADDRESS>",
  "LendingFactory": "<DEPLOYED_ADDRESS>",
  "LensLite": "<DEPLOYED_ADDRESS>",
  "SwapRouter": "<DEPLOYED_ADDRESS>",
  "WBERA": "0x7507c1dc16935B82698e4C63f2746A5fCf453D92"
}
```

## ⚠️ Security Considerations

### Smart Contract Security
- [ ] All contracts are immutable (no admin functions)
- [ ] No upgradeable proxies used
- [ ] Private keys secured properly
- [ ] Multi-sig setup for treasury (recommended)

### Operational Security  
- [ ] RPC endpoints are reliable and secure
- [ ] Monitoring alerts configured
- [ ] Incident response plan ready
- [ ] Team access properly managed

## 🎯 Success Criteria

### Technical Success
- [ ] All contracts deployed and verified
- [ ] Frontend connects to mainnet contracts
- [ ] Subgraph indexing mainnet data
- [ ] First token launch successful
- [ ] Trading functions working
- [ ] Lending markets operational

### Business Success
- [ ] User onboarding flow complete
- [ ] Documentation updated
- [ ] Community announcement ready
- [ ] Support channels prepared
- [ ] Analytics tracking active

## 🚨 Emergency Procedures

### If Deployment Fails
1. **Stop immediately** - Do not continue with failed contracts
2. **Diagnose issue** - Check logs and error messages  
3. **Fix and redeploy** - Address root cause
4. **Update all configurations** - Ensure consistency

### If Post-Deployment Issues
1. **Assess impact** - Determine severity and scope
2. **Communicate** - Inform users if necessary
3. **Implement fix** - Deploy patches if possible
4. **Monitor closely** - Ensure stability restored

---

## 📞 Support

For deployment support or issues:
- Check logs and error messages first
- Verify all environment variables
- Confirm network connectivity
- Test on fresh testnet deployment

**This deployment guide ensures a smooth, secure, and successful mainnet launch of Osito Protocol V5.**