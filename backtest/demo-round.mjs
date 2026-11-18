// Deterministic fictional prices for the offline CLI demonstration.
const expiry = Date.UTC(2026, 0, 2, 16, 15) / 1000;
const market = {
  ticker: 'DEMO-BTC-15M',
  open_time: new Date((expiry - 900) * 1000).toISOString(),
  close_time: new Date(expiry * 1000).toISOString(),
  floor_strike: 50000
};

function demoPrice(minute) {
  return Math.round((50000 + 21 * Math.sin(minute / 3) + 9 * Math.cos(minute / 7)) * 100) / 100;
}

const candles = Array.from({length: 72}, (_, minute) => {
  const open = demoPrice(minute);
  const close = demoPrice(minute + 1);
  return {
    start: expiry - (72 - minute) * 60, open, close,
    high: Math.max(open, close) + 3, low: Math.min(open, close) - 3
  };
});

export default {market, candles};
