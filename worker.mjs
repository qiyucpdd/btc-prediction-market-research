const KALSHI = 'https://external-api.kalshi.com/trade-api/v2/markets';
const COINBASE = 'https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD/candles';
const PRICE_FITS = {
  4: [0.011011155242991047, 0.601241178168646, 1.2298532960925468, 0.1284393899582682],
  6: [-0.10536618028479769, 0.5217297593621257, 1.0631894272600717, 0.01319105439953532],
  8: [-0.0815501766346952, 0.5458106427186011, 1.0613944278179865, 0.01394421187136076],
  10: [-0.05795932192494235, 0.5800192589964934, 1.0549556857672477, -0.052563642881360464]
};
const ptDate = new Intl.DateTimeFormat('en-US',{timeZone:'America/Los_Angeles',month:'short',day:'numeric',year:'numeric'});
const ptTime = new Intl.DateTimeFormat('en-US',{timeZone:'America/Los_Angeles',hour:'numeric',minute:'2-digit',hour12:true});
const clock = t => ptDate.format(t*1000)+' · '+ptTime.format(t*1000).replace(/\s/g,'').toLowerCase();
const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
const bound = (n,low,high) => Math.min(high,Math.max(low,n));
const logistic = x => 1/(1+Math.exp(-x));
const logit = p => Math.log(p/(1-p));
const now = () => Date.now()/1000;
const epoch = s => Date.parse(s)/1000;
function number(input) {
  const n = Number(input);
  if (input==null || input==='' || !Number.isFinite(n)) throw Error('missing numeric input');
  return n;
}
async function data(url,params={}) {
  const u=new URL(url);
  for(const [k,v] of Object.entries(params)) u.searchParams.set(k,v);
  const r=await fetch(u,{cache:'no-store',signal:AbortSignal.timeout(7500),headers:{Accept:'application/json'}});
  if(!r.ok) throw Error(u.hostname+' returned '+r.status);
  return {body:await r.json(),date:epoch(r.headers.get('date'))};
}
// Six-minute prospective research model. Frozen after the November 16 archive.
const HYBRID_WEIGHTS = [-0.006079281207743095, 0.9156343909747083, 0.08597076452869983, 0.17997634937783197, 0.017422264741965527, 0.09122220704985028];
const FIRST_HYBRID_EXPIRY = 1794938400;

export function hybridProbability(inputs, midpoint, spread) {
  const market = bound(logit(midpoint), -6, 6);
  const features = [1, market, ...inputs.slice(1).map(Math.asinh), market * Math.min(10 * spread, 1)];
  return logistic(features.reduce((sum, x, i) => sum + x * HYBRID_WEIGHTS[i], 0));
}

export function hybridEntry(p, upAsk, downAsk) {
  const direction = p >= 0.5 ? 'Up' : 'Down';
  const ask = direction === 'Up' ? upAsk : downAsk;
  if (!(ask > 0 && ask < 1)) return {direction, ask:null, cost:null, call:'No quote'};
  const ticks = Math.round(ask * 10000);
  const feeTicks = Math.ceil(7 * ticks * (10000 - ticks) / 1000000);
  const cost = Math.ceil((ticks + feeTicks) / 100) / 100;
  const confidence = Math.max(p, 1-p);
  const eligible = confidence >= .60 && cost <= .90 && confidence + 1e-12 >= cost + .05;
  return {direction, ask, cost, call:eligible ? direction : 'Pass'};
}

export function model(candles,at,target,bid,ask,left) {
  const bars=new Map(candles.map(b=>[Number(b.start),b]));
  const prices=[];
  for(let t=at-61*60;t<at;t+=60) prices.push(number(bars.get(t)?.close));
  const btc=prices[60];
  const vol=Math.sqrt(prices.slice(1).reduce((sum,p,i)=>sum+(p-prices[i])**2,0)/60);
  if(!(vol>0)) throw Error('missing volatility');
  const opening=bars.get(at-(15-left)*60-60);
  const anchor=['open','high','low','close'].reduce((s,k)=>s+number(opening?.[k]),0)/4;
  const recent=prices.slice(-13);
  const recentVariance=recent.slice(1).reduce((s,v,i)=>s+(v-recent[i])**2,0)/12;
  const fastVol=Math.sqrt((vol**2+recentVariance)/2);
  const fastHorizon=fastVol*Math.sqrt(left-.5);
  const inputs=[1,bound((btc-target)/fastHorizon,-8,8),bound((btc-anchor)/fastHorizon,-8,8),
    bound((btc-prices[57])/(fastVol*Math.sqrt(3)),-8,8)];
  const price_up=logistic(inputs.reduce((s,v,i)=>s+PRICE_FITS[left][i]*v,0));
  const midpoint = bid > 0 && bid <= ask && ask < 1 ? (bid + ask) / 2 : null;
  const hybrid_up = left === 6 && midpoint !== null
    ? hybridProbability(inputs, midpoint, ask - bid) : null;
  return {btc, price_up, midpoint, hybrid_up};
}

function offer(price, size) {
  const ask = Number(price);
  return ask > 0 && ask < 1 && Number(size) >= 1 ? ask : null;
}

// The original BTC-only threshold signal is separate from the locked round call.
function chartSignal(side, confidence, ask, left, prior) {
  const thresholdCall = ask === null ? 'No data'
    : ask <= .90 && confidence >= .90 && confidence > ask + 1e-12 ? side : 'Pass';
  if (left === 10 || (left === 4 && ['Up','Down'].includes(prior?.btc_decision))) return 'Watch';
  if (left !== 6) return thresholdCall;
  if (prior?.minutes_left !== 8 || prior.btc_decision !== 'Pass' || !prior.btc_lean) return 'Watch';
  if (ask === null) return 'No data';
  return prior.btc_lean === side ? thresholdCall : 'Pass';
}

async function capture(at,left,env) {
  const expiry=at+60*left;
  if(await env.DB.prepare('SELECT 1 FROM _checkpoint_data WHERE expiry=? AND minutes_left=?').bind(expiry,left).first()) return;
  if(left===8 && await env.DB.prepare('SELECT 1 FROM _checkpoint_data WHERE expiry=? AND minutes_left=5').bind(expiry).first()) return;
  const prior = left === 4 || left === 6 ? await env.DB.prepare(
    'SELECT minutes_left,btc_lean,btc_decision FROM _checkpoint_data ' +
    'WHERE expiry=? AND minutes_left IN (5,8) ORDER BY minutes_left DESC LIMIT 1'
  ).bind(expiry).first() : null;
  const insert = env.DB.prepare(
    'INSERT OR IGNORE INTO _checkpoint_data(expiry,minutes_left,round_pt,captured_at,ticker,' +
    'decision,capped_recorded,btc,target,model_id,midpoint,up_ask,down_ask,btc_captured_at,' +
    'btc_ticker,btc_lean,btc_probability,btc_ask,btc_decision) ' +
    "VALUES(?,?,?,?,?,'Not recorded',0,?,?,?,?,?,?,?,?,?,?,?,?)"
  );
  let reason='Scheduler arrived outside the 25-second checkpoint';
  for(let attempt=0;attempt<5 && now()<=at+25;attempt++){
    try{
      const [listed,bars]=await Promise.all([
        data(KALSHI,{series_ticker:'KXBTC15M',status:'open',limit:10}),
        data(COINBASE,{start:at-65*60,end:at,granularity:'ONE_MINUTE'})
      ]);
      const listedMarket=listed.body.markets.find(m=>epoch(m.close_time)===expiry);
      if(!listedMarket) throw Error('matching open market unavailable');
      // An active listing supplies the official target even if the order book is unavailable.
      const quoted=await data(KALSHI+'/'+encodeURIComponent(listedMarket.ticker)).catch(()=>null);
      const captured=now(), m=quoted?.body.market ?? listedMarket;
      if(!(captured>=at && captured<=at+25)) throw Error('outside checkpoint');
      if(m.status!=='active'||m.result||m.ticker!==listedMarket.ticker||epoch(m.close_time)!==expiry||epoch(m.open_time)!==expiry-900) throw Error('ineligible market');
      const target=number(m.floor_strike);
      if(target<=0) throw Error('missing price to beat');
      const fresh=quoted!=null && quoted.date>=at && captured>=quoted.date && captured-quoted.date<=12;
      const bid=fresh ? Number(m.yes_bid_dollars) : null;
      const ask=fresh ? Number(m.yes_ask_dollars) : null;
      const row=model(bars.body.candles,at,target,bid,ask,left);
      const crossed=bid>0 && ask>0 && bid>ask;
      row.up_ask=fresh && !crossed ? offer(m.yes_ask_dollars,m.yes_ask_size_fp) : null;
      row.down_ask=fresh && !crossed ? offer(m.no_ask_dollars,m.yes_bid_size_fp) : null;
      const side = row.price_up >= .5 ? 'Up' : 'Down';
      const confidence = Math.max(row.price_up, 1-row.price_up);
      const chartAsk = side === 'Up' ? row.up_ask : row.down_ask;
      const capturedAt = new Date(captured*1000).toISOString();
      const writes = [insert.bind(expiry,left,clock(expiry),capturedAt,m.ticker,row.btc,target,
        'btc-chart-v1',row.midpoint,row.up_ask,row.down_ask,capturedAt,m.ticker,side,confidence,
        chartAsk,chartSignal(side,confidence,chartAsk,left,prior))];
      if (left===6 && expiry>=FIRST_HYBRID_EXPIRY && Number.isFinite(row.hybrid_up)) {
        const entry = hybridEntry(row.hybrid_up, row.up_ask, row.down_ask);
        const archive = env.DB.prepare(
          'INSERT OR IGNORE INTO six_minute_hybrid_v1 ' +
          '(expiry,ticker,captured_at,quoted_at,chart_up,midpoint,hybrid_up,direction,paper_call,ask_usd,all_in_usd) ' +
          'SELECT ?,?,?,?,?,?,?,?,?,?,? WHERE EXISTS (SELECT 1 FROM _checkpoint_data ' +
          'WHERE expiry=? AND minutes_left=6 AND ticker=? AND btc_ticker=ticker AND btc_captured_at=? AND result IS NULL)'
        );
        writes.push(archive.bind(expiry,m.ticker,capturedAt,quoted.date,row.price_up,row.midpoint,
          row.hybrid_up,entry.direction,entry.call,entry.ask,entry.cost,expiry,m.ticker,capturedAt));
      }
      await env.DB.batch(writes);
      return;
    }catch(e){ reason=String(e.message).slice(0,180); if(now()<at+24) await sleep(650); }
  }
  const capturedAt=new Date().toISOString();
  await env.DB.prepare(
    'INSERT OR IGNORE INTO _checkpoint_data(expiry,minutes_left,round_pt,captured_at,decision,' +
    "capped_recorded,detail,model_id,btc_captured_at,btc_decision) VALUES(?,?,?,?,'Not recorded',0,?,'btc-chart-v1',?,'No data')"
  ).bind(expiry,left,clock(expiry),capturedAt,reason,capturedAt).run();
}
async function settle(env) {
  const rows=await env.DB.prepare(
    'SELECT expiry,ticker FROM _checkpoint_data WHERE result IS NULL '+
    'AND ticker IS NOT NULL AND expiry<=? GROUP BY expiry,ticker ORDER BY MIN(last_settle_check),expiry LIMIT 8'
  ).bind(Math.floor(now())).all();
  for(const row of rows.results) {
    await env.DB.prepare('UPDATE _checkpoint_data SET last_settle_check=? WHERE expiry=? AND ticker=? AND result IS NULL')
      .bind(Math.floor(now()),row.expiry,row.ticker).run();
    try {
      const m=(await data(KALSHI+'/'+encodeURIComponent(row.ticker))).body.market;
      if(m.ticker!==row.ticker||!['finalized','settled'].includes(m.status)||!['yes','no'].includes(m.result)) continue;
      const result=m.result==='yes'?'Up':'Down';
      const final=number(m.expiration_value);
      await env.DB.prepare("UPDATE _checkpoint_data SET result=?,final_index=?,gross_usd=CASE WHEN decision IN ('Up','Down') THEN round((decision=?)-ask,4) ELSE NULL END WHERE expiry=? AND ticker=? AND result IS NULL")
        .bind(result,final,result,row.expiry,row.ticker).run();
    } catch(e){console.warn('Settlement retry',row.ticker,String(e.message));}
  }
}
// Cron dispatch can arrive partway through a minute. Start one minute
// early and fetch at the original checkpoint, keeping the 25-second cutoff.
export async function dispatch(at,env,observe=capture,pause=sleep,readTime=now) {
  const offset=Math.floor(at/60)%15;
  if(offset===2){await settle(env);return;}
  if(![4,6,8,9].includes(offset)) return; // 8/9 also cover a four-minute checkpoint during cron propagation.
  const roundStart=at-offset*60;
  for(const left of [10,8,6,4]){
    const checkpoint=roundStart+(15-left)*60;
    if(checkpoint<at) continue;
    const ms=Math.max(0,Math.ceil((checkpoint+0.25-readTime())*1000));
    if(ms>0) await pause(ms);
    await observe(checkpoint,left,env);
  }
}
export const run=dispatch;
export default {
  async scheduled(event,env){await run(Math.floor(event.scheduledTime/60000)*60,env);},
  async fetch(){return new Response('Private paper watcher. Results are available in Cloudflare D1 Studio.',{status:404});}
};
