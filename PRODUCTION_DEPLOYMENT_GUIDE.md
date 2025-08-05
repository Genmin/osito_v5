# 🚀 Osito V5 Production Deployment Guide

## ✅ TESTNET DEPLOYMENT COMPLETE

### Deployed Contracts (Berachain Testnet - Chain ID: 80069)

| Contract | Address | Purpose |
|----------|---------|---------|
| **OsitoLaunchpad** | `0x7E3fcAC742EAC70e6E2aDad2B7373b7fE569A9b5` | Single-step token + pair creation |
| **LendingFactory** | `0xedA30de4628955f3759eE7829d4124D6239F28ba` | Creates lending markets |
| **LensLite** | `0x993F97eF95633A47412C9E837a0E2B4274D05de7` | Market data aggregation |

### Configuration
- **WBERA**: `0x6969696969696969696969696969696969696969`
- **Treasury**: `0xBfff8b5C308CBb00a114EF2651f9EC7819b69557`
- **Deployment Block**: `7744628`

---

## 🎯 Frontend Integration Status

### OsitoappV5 Directory Structure
```
OsitoappV5/
├── constants/
│   ├── addresses.ts          ✅ Updated with V5 addresses
│   └── generated.ts          ✅ Generated TypeScript bindings
├── wagmi.config.ts           ✅ Configured for V5 contracts
├── .env.local               ✅ Environment variables set
└── package.json             ✅ Dependencies installed
```

### Key Changes from V3 to V5
1. **Single Factory**: `OsitoLaunchpad` replaces separate `TokenFactory` + `PairFactory`
2. **One-Step Launch**: Create token + pair in single transaction
3. **Backward Compatibility**: Legacy factory addresses map to `OsitoLaunchpad`
4. **Same Frontend Logic**: Existing hooks and components work unchanged

---

## 🔄 Migration Path

### For Existing Users
- No action required - V5 maintains full protocol compatibility
- Existing tokens and pairs continue to work
- New launches use improved V5 system

### For Developers
- Import from `constants/generated.ts` (auto-generated)
- Use `useOsitoLaunchpadLaunchToken` instead of separate token/pair calls
- All other hooks remain identical

---

## 🌐 Production Deployment (Mainnet)

### Step 1: Environment Setup
```bash
# Update .env.mainnet
PRIVATE_KEY=your_mainnet_private_key
RPC_URL=https://mainnet-rpc-url
WBERA_ADDRESS=0x_actual_mainnet_wbera
TREASURY=0xBfff8b5C308CBb00a114EF2651f9EC7819b69557
```

### Step 2: Deploy Contracts
```bash
cd osito_v5
forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

### Step 3: Update Frontend
```bash
cd ../OsitoappV5
# Update wagmi.config.ts with mainnet addresses
# Update .env.production
npm run generate
```

### Step 4: Verify Integration
```bash
npm run build
npm run start
```

---

## 🧪 Testing Checklist

### Contract Testing
- [x] Deploy script execution
- [x] Contract compilation
- [x] Address generation
- [ ] Integration testing with frontend
- [ ] Token launch flow
- [ ] Lending market creation

### Frontend Testing
- [x] TypeScript generation
- [x] Environment configuration
- [x] Development server startup
- [ ] Wallet connection
- [ ] Contract interaction
- [ ] Transaction submission

---

## 📊 Integration Verification

### Quick Test Commands
```bash
# Check contract deployment
curl -X POST $RPC_URL \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getCode","params":["0x7E3fcAC742EAC70e6E2aDad2B7373b7fE569A9b5","latest"],"id":1}'

# Start frontend
cd OsitoappV5
npm run dev
# Visit http://localhost:3006
```

### Expected Behavior
1. Frontend loads without errors
2. Wallet connection works
3. Contract addresses resolve correctly
4. TypeScript types are available

---

## 🔐 Security Considerations

### Testnet Validation
- [x] Contracts deployed with correct parameters
- [x] Treasury address properly configured
- [x] WBERA address matches testnet standard
- [ ] Full protocol flow testing

### Mainnet Preparation
- [ ] Multi-sig treasury setup
- [ ] Contract verification on explorer
- [ ] Comprehensive integration testing
- [ ] Performance optimization
- [ ] Security audit (if needed)

---

## 🎉 Next Steps

1. **Test Full Integration Flow** ⏳
   - Connect wallet
   - Launch test token
   - Create lending market
   - Verify all data flows

2. **Subgraph Deployment**
   - Update subgraph for V5 events
   - Deploy to Goldsky
   - Test price chart integration

3. **Production Launch**
   - Deploy to mainnet
   - Update DNS/hosting
   - Monitor initial transactions

---

## 📞 Support

For technical issues:
- Contract bugs: Check `osito_v5/test/` directory
- Frontend issues: Check `OsitoappV5/` console logs
- Integration problems: Verify `.env.local` configuration

**Status**: Ready for integration testing ✅