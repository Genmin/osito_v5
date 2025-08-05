const { ethers } = require('ethers');
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

async function traceCollectFees() {
  console.log('=== Tracing collectFees() ===\n');
  
  try {
    // Use debug_traceCall to see exactly what happens
    const result = await provider.send('debug_traceCall', [
      {
        from: '0x37A9B9Df87B2cd3fC73A9C0Ad10B4Aff2D52bCc5',
        to: process.env.FEE_ROUTER,
        data: '0xc8796572', // collectFees()
        gas: '0x7a120' // 500k gas
      },
      'latest',
      {
        tracer: 'callTracer',
        tracerConfig: {
          onlyTopCall: false
        }
      }
    ]);
    
    console.log('Trace result:', JSON.stringify(result, null, 2));
  } catch (error) {
    console.error('Trace error:', error);
    
    // If debug_traceCall is not available, try eth_call
    console.log('\nTrying eth_call instead...');
    try {
      const result = await provider.call({
        from: '0x37A9B9Df87B2cd3fC73A9C0Ad10B4Aff2D52bCc5',
        to: process.env.FEE_ROUTER,
        data: '0xc8796572'
      });
      console.log('Call result:', result);
    } catch (callError) {
      console.error('Call error:', callError.message);
      if (callError.data) {
        console.log('Error data:', callError.data);
      }
    }
  }
}

traceCollectFees().catch(console.error);