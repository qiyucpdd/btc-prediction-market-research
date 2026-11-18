// Check a bounded number of public archival quotes per scheduled invocation.
// Captures for live rounds are handled by the independent production watcher.
const api = 'https://external-api.kalshi.com/trade-api/v2';
const cutoff = 1789603200; // September 17, 2026 UTC at discovery; all queued markets are from this fixed snapshot.
async function readQuote(row, budget) {
  const at = row.expiry - 360;
  const paths = ['/historical/markets/', '/series/KXBTC15M/markets/'];
  if (row.expiry >= cutoff) paths.reverse();
  for (const prefix of paths) {
    if (budget.left === 0 || budget.nextRequest >= budget.deadline) return {defer:true};
    const delay=budget.nextRequest-Date.now();
    if(delay>0) await new Promise(resolve=>setTimeout(resolve,delay));
    if(Date.now()>=budget.deadline) return {defer:true};
    budget.nextRequest=Date.now()+1200;
    budget.left--;
    const url = new URL(api + prefix + encodeURIComponent(row.ticker) + '/candlesticks');
    url.search = new URLSearchParams({start_ts: String(at-60), end_ts: String(at), period_interval: '1'});
    const res = await fetch(url, {headers:{Accept:'application/json'},signal:AbortSignal.timeout(9000)});
    if (res.status === 404) continue;
    if (res.status === 429) {
      const retry=res.headers.get('Retry-After');
      const seconds=retry && /^\d+$/.test(retry) ? Number(retry) : (Date.parse(retry)-Date.now())/1000;
      return {throttled:Math.max(60,Number.isFinite(seconds)?Math.ceil(seconds):60)};
    }
    if (!res.ok) throw new Error('Kalshi HTTP '+res.status);
    const body = await res.json();
    if (body.ticker && body.ticker !== row.ticker) throw new Error('Ticker mismatch');
    if (!Array.isArray(body.candlesticks)) throw new Error('Invalid candlestick response');
    const q=body.candlesticks.find(v=>v.end_period_ts===at);
    if (!q) continue;
    const price = v => v?.close_dollars ?? v?.close;
    const bid=Math.round(10000*Number(price(q.yes_bid))), ask=Math.round(10000*Number(price(q.yes_ask)));
    return bid>0 && ask>=bid && ask<10000 ? {state:'paired',bid,ask} : {state:'no_two_sided_book'};
  }
  return {state:'no_quote'};
}
export async function sync(env) {
  const db=env.DB, now=Math.floor(Date.now()/1000);
  const {results:rows}=await db.prepare("SELECT ticker,expiry FROM rounds WHERE state='pending' AND retry_after<=? ORDER BY retry_after,expiry LIMIT 36").bind(now).all();
  if (!rows.length) return;
  const lease=await db.prepare('UPDATE sync_state SET lease_until=?,last_run=? WHERE id=1 AND lease_until<=?').bind(now+300,now,now).run();
  if (!lease.meta.changes) return;
  let resume=0, error=null;
  const writes=[];
  const budget={left:42,nextRequest:0,deadline:(now+48)*1000};
  try {
    for(const row of rows) {
      try {
        if (Date.now()/1000-now>48 || !budget.left) break;
        const quote=await readQuote(row,budget);
        if(quote.defer) break;
        if(quote.throttled){resume=Math.floor(Date.now()/1000)+quote.throttled;error='Rate limited';break;}
        writes.push(db.prepare("UPDATE rounds SET state=?,bid_ticks=?,ask_ticks=? WHERE ticker=? AND state='pending'")
          .bind(quote.state,quote.bid??null,quote.ask??null,row.ticker));
      } catch(e) {
        error=String(e.message).slice(0,150);
        writes.push(db.prepare("UPDATE rounds SET retry_after=? WHERE ticker=? AND state='pending'").bind(now+1800,row.ticker));
      }
    }
    writes.push(db.prepare('UPDATE sync_state SET lease_until=?,last_error=? WHERE id=1 AND lease_until=?').bind(resume,error,now+300));
    await db.batch(writes);
  } catch(e) {console.error('Archive batch retry',String(e.message));throw e;}
}
export default {
  async scheduled(event,env){await sync(env);},
  async fetch(){return new Response('Private paper research',{status:404});}
};
