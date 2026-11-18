import { setTimeout as wait } from 'node:timers/promises';
import { sixMinuteScreen } from './six-minute-screen.mjs';
import { model, hybridEntry } from './worker.mjs';

const marketsURL = 'https://external-api.kalshi.com/trade-api/v2/markets';
const candlesURL = 'https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD/candles';
const checkpoints = [10, 8, 6, 4];
const pacific = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Los_Angeles', month: 'short', day: 'numeric',
  hour: 'numeric', minute: '2-digit', timeZoneName: 'short'
});
const clock = seconds => pacific.format(seconds * 1000);
const now = () => Math.floor(Date.now() / 1000);

async function readPublic(url, params = {}, includeDate = false) {
  const endpoint = new URL(url);
  for (const [key, value] of Object.entries(params)) endpoint.searchParams.set(key, String(value));
  const response = await fetch(endpoint, {
    cache: 'no-store', signal: AbortSignal.timeout(9000), headers: { Accept: 'application/json' }
  });
  if (!response.ok) throw new Error(endpoint.hostname + ' returned HTTP ' + response.status);
  const data = await response.json();
  return includeDate ? {data, time: Date.parse(response.headers.get('date'))/1000} : data;
}

function checkpointReport(market, candles, asOf) {
  const close = Date.parse(market.close_time) / 1000;
  const target = Number(market.floor_strike);
  if (!Number.isFinite(target) || target <= 0) throw new Error('Official Price to Beat is unavailable.');
  const rows = [];
  for (const left of checkpoints) {
    const at = close - left * 60;
    if (at > asOf) continue;
    try {
      // The shared Worker function selects exactly 61 completed candles ending before at.
      const { price_up: p, btc } = model(candles, at, target, null, null, left);
      if (!Number.isFinite(p) || !(btc > 0)) throw new Error('invalid chart values');
      rows.push({ left, at, side: p >= 0.5 ? 'Up' : 'Down', confidence: Math.max(p, 1 - p), btc });
    } catch (error) {
      rows.push({ left, at, error: error.message });
    }
  }
  return { market, target, close, rows };
}

async function liveReport(details) {
  const listing = await readPublic(marketsURL, { series_ticker: 'KXBTC15M', status: 'open', limit: 10 });
  const time = now();
  let market = listing.markets?.find(m => {
    const start = Date.parse(m.open_time) / 1000, end = Date.parse(m.close_time) / 1000;
    return m.status === 'active' && !m.result && end - start === 900 && start <= time && time < end;
  });
  if (!market) throw new Error('No active Kalshi BTC 15-minute round in the listing.');
  if (!(Number(market.floor_strike) > 0)) {
    const details = await readPublic(marketsURL + '/' + encodeURIComponent(market.ticker));
    const fresh = details.market;
    if (fresh?.ticker !== market.ticker || fresh.close_time !== market.close_time ||
        fresh.status !== 'active' || fresh.result) throw new Error('The active round changed during lookup.');
    market = fresh;
  }
  const close = Date.parse(market.close_time) / 1000;
  const due = checkpoints.filter(left => close - 60 * left <= time);
  let candles = [];
  if (due.length) {
    const end = close - 60 * due.at(-1);
    const data = await readPublic(candlesURL, {
      start: close - (10 + 65) * 60, end, granularity: 'ONE_MINUTE'
    });
    if (!Array.isArray(data.candles)) throw new Error('Coinbase did not return minute candles.');
    candles = data.candles;
  }
  if (now() >= close) throw new Error('The round closed during the request. Refresh for the next round.');
  const report = checkpointReport(market, candles, time);
  const chart = report.rows.at(-1);
  if (details && chart?.left===6 && !chart.error && now()<=chart.at+25) {
    try {
      const snapshot = await readPublic(marketsURL+'/'+encodeURIComponent(market.ticker), {}, true);
      const quote = snapshot.data.market;
      report.sixPaper = sixMinuteScreen(chart, market, quote, snapshot.time, Date.now()/1000);
      if (report.sixPaper && report.sixPaper!=='No timely quote') {
        const bid=Number(quote.yes_bid_dollars), ask=Number(quote.yes_ask_dollars);
        const {hybrid_up:p}=model(candles,chart.at,report.target,bid,ask,6);
        if (Number.isFinite(p)) {
          const entry=hybridEntry(p, Number(quote.yes_ask_size_fp)>=1 ? ask : null,
            Number(quote.yes_bid_size_fp)>=1 ? Number(quote.no_ask_dollars) : null);
          report.hybrid=entry.direction+' '+(100*Math.max(p,1-p)).toFixed(1)+'% | paper: '+entry.call;
        }
      }
    } catch { report.sixPaper = 'No timely quote'; }
  }
  return report;
}

function printReport(report, details) {
  const { market, target, close, rows } = report;
  const latest = rows.filter(row => !row.error).at(-1);
  const lastAttempt = rows.at(-1);
  console.log('');
  if (latest) {
    const age = latest === lastAttempt ? '' : ' · last valid';
    console.log(`BTC forecast   ${latest.side.toUpperCase()} · ${(100 * latest.confidence).toFixed(1)}% model confidence`);
    console.log(`Round closes   ${clock(close)} · forecast from the ${latest.left}m checkpoint${age}`);
    console.log(`BTC at capture $${latest.btc.toFixed(2)} · target $${target.toFixed(2)}`);
  } else {
    console.log(rows.length ? 'BTC forecast   Unavailable' : 'BTC forecast   Waiting for first checkpoint');
    console.log('Round closes   ' + clock(close));
    if (lastAttempt) console.log(`${lastAttempt.left}m checkpoint unavailable · ${lastAttempt.error}`);
    else console.log('First forecast ' + clock(close - 600));
  }
  if (!details) return;
  console.log('\nCheckpoint details · ' + market.ticker);
  for (const row of rows) {
    const reading = row.error ? 'Unavailable (' + row.error + ')' :
      row.side + ' ' + (100 * row.confidence).toFixed(1) + '% · BTC $' + row.btc.toFixed(2);
    console.log(`${row.left}m · ${clock(row.at)} · ${reading}`);
  }
  if (report.hybrid) console.log('Research hybrid · ' + report.hybrid);
  if (report.sixPaper) console.log('Independent $50 paper screen · ' + report.sixPaper);
}

async function main() {
  const args = process.argv.slice(2);
  const modes = args.filter(arg => arg !== '--details');
  const mode = modes[0];
  const details = args.includes('--details');
  if (new Set(args).size !== args.length || modes.length > 1 ||
      ![undefined, '--watch', '--once', '--demo', '--help'].includes(mode))
    throw new Error('Usage: node run.mjs [--watch | --once | --demo | --help] [--details]');
  if (mode === '--help') {
    console.log('node run.mjs            Follow live chart calls (Ctrl+C to stop)\nnode run.mjs --once     Show the current call and exit\nnode run.mjs --watch    Follow live chart calls\nnode run.mjs --demo     Run a fictional round offline\nAdd --details to see checkpoint history and available research signals.');
    return;
  }
  if (mode === '--demo') {
    const { default: sample } = await import('./backtest/demo-round.mjs');
    console.log('Offline demo using synthetic BTC candles');
    printReport(checkpointReport(sample.market, sample.candles, Date.parse(sample.market.close_time) / 1000 - 1), details);
    return;
  }
  const watching = mode !== '--once';
  if (watching) console.log('Following live BTC rounds. Press Ctrl+C to stop.');
  let lastOutput;
  do {
    let delay = 10;
    try {
      const report = await liveReport(details);
      const state = JSON.stringify([report.market.ticker, report.target, report.rows, report.hybrid, report.sixPaper]);
      if (state !== lastOutput) printReport(report, details);
      lastOutput = state;
      const latest = report.rows.at(-1);
      const remaining = checkpoints.slice(report.rows.length);
      const next = remaining.length ? report.close - remaining[0] * 60 : report.close;
      delay = Math.max(1, next - now() + 1);
      if (latest?.error) {
        delay = Math.min(delay, 10);
        if (!watching) process.exitCode = 1;
      }
    } catch (error) {
      if (!watching) throw error;
      console.error('Live data unavailable: ' + error.message + '. Retrying in 10 seconds.');
    }
    if (watching) await wait(delay * 1000);
  } while (watching);
}
main().catch(error => {
  console.error(error.message + (error.cause?.message ? ' (' + error.cause.message + ')' : ''));
  process.exitCode = 1;
});
