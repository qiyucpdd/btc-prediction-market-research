// Rebuild every archived checkpoint from the included Coinbase OHLC and official Kalshi targets.
// Run with Node.js 22+ in the source project.
import { readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync, gzipSync } from 'node:zlib';
import { model } from '../../worker.mjs';
const file=name=>new URL(name,import.meta.url);
function rows(name) {
  const [header,...lines]=gunzipSync(readFileSync(file(name))).toString().trimEnd().split(/\r?\n/);
  return {names:header.split(','),lines};
}
const marketFile=rows('replay.csv.gz'), bars=new Map();
for(const line of rows('candles.csv.gz').lines) {
  const [start,open,high,low,close]=line.split(',').map(Number);
  bars.set(start,{start,open,high,low,close});
}
const columns=Object.fromEntries(marketFile.names.map((name,i)=>[name,i]));
const output=['expiry,minutes_left,chart_up,strike_gap,opening_move,momentum'];
const clip=x=>Math.max(-8,Math.min(8,x));
for(const line of marketFile.lines) {
  const row=line.split(','), expiry=Number(row[columns.expiry]), target=Number(row[columns.target]);
  if(!(target>0))continue;
  for(const left of [10,8,6,4]) {
    const at=expiry-left*60;
    const candles=Array.from({length:61},(_,i)=>bars.get(at-(61-i)*60));
    if(candles.some(v=>!v))continue;
    const {price_up:p,btc}=model(candles,at,target,null,null,left);
    const delta=candles.slice(1).map((b,i)=>(b.close-candles[i].close)**2);
    const sum=(s,x)=>s+x;
    const vol=Math.sqrt((delta.reduce(sum,0)/60+delta.slice(-12).reduce(sum,0)/12)/2);
    const open=bars.get(expiry-16*60);
    const anchor=(open.open+open.high+open.low+open.close)/4;
    const horizon=vol*Math.sqrt(left-.5);
    const x=[(btc-target)/horizon,(btc-anchor)/horizon,(btc-candles[57].close)/(vol*Math.sqrt(3))].map(clip);
    output.push([expiry,left,p,...x].join(','));
  }
}
writeFileSync(file('checkpoints.csv.gz'),gzipSync(output.join('\n')+'\n'));
console.log('Rebuilt',output.length-1,'BTC chart checkpoints');
