const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

async function testBurnAmount() {
  console.log('=== Testing Burn Amount ===\n');
  
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  
  const totalSupply = await pair.totalSupply();
  const [r0, r1] = await pair.getReserves();
  
  console.log('Total LP Supply:', ethers.formatEther(totalSupply));
  console.log('Reserve0 (TOK):', ethers.formatEther(r0));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1));
  
  // Calculate what 1000 wei of LP would give us
  const lpAmount = 1000n;
  const expectedTok = (lpAmount * r0) / totalSupply;
  const expectedWbera = (lpAmount * r1) / totalSupply;
  
  console.log('\nFor 1000 wei LP:');
  console.log('Expected TOK:', expectedTok.toString(), 'wei');
  console.log('Expected WBERA:', expectedWbera.toString(), 'wei');
  
  // The burn function requires amt0 > 0 && amt1 > 0
  // So we need enough LP to get at least 1 wei of each token
  
  // Calculate minimum LP needed
  const minLpForTok = (totalSupply + r0 - 1n) / r0;
  const minLpForWbera = (totalSupply + r1 - 1n) / r1;
  const minLp = minLpForTok > minLpForWbera ? minLpForTok : minLpForWbera;
  
  console.log('\nMinimum LP needed:');
  console.log('For 1 wei TOK:', minLpForTok.toString());
  console.log('For 1 wei WBERA:', minLpForWbera.toString());
  console.log('Required:', minLp.toString());
  
  // Use a bit more to be safe
  const safeLp = minLp * 2n;
  console.log('\nSafe amount to use:', safeLp.toString(), 'wei');
  console.log('In ether:', ethers.formatEther(safeLp));
}

testBurnAmount().catch(console.error);