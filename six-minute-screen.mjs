// Mirror the fixed six-minute D1 price filter. The hosted journal owns the paper balance.
export function sixMinuteScreen(chart, market, quote, quotedAt, receivedAt) {
  if (!chart || chart.left!==6 || chart.error) return null;
  if (!(receivedAt>=chart.at && receivedAt<=chart.at+25)) return null;
  if (!quote || quote.ticker!==market.ticker || quote.status!=='active' || quote.result ||
      quote.close_time!==market.close_time || !(quotedAt>=chart.at && quotedAt<=receivedAt && receivedAt-quotedAt<=12))
    return 'No timely quote';
  const bid=Number(quote.yes_bid_dollars), ask=Number(quote.yes_ask_dollars);
  const up=chart.side==='Up';
  const offer=up?ask:Number(quote.no_ask_dollars);
  const size=Number(up?quote.yes_ask_size_fp:quote.yes_bid_size_fp);
  if (!(bid>0 && bid<=ask && ask<1 && offer>0 && offer<1 && size>=1)) return 'No executable quote';
  const ticks=Math.round(offer*10000);
  const feeTicks=Math.ceil(7*ticks*(10000-ticks)/1000000);
  const cents=Math.ceil((ticks+feeTicks)/100);
  const midpoint=(bid+ask)/2, estimate=(chart.confidence+(up?midpoint:1-midpoint))/2;
  const action=cents>50?'Pass (over 50¢)':estimate+1e-12<cents/100+.05?'Pass (estimated edge below 5¢)':'Paper candidate '+chart.side;
  return action+' | '+cents+'¢ all-in | blended estimate '+(100*estimate).toFixed(1)+'%';
}
