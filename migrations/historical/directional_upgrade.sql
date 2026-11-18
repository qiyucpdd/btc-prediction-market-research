CREATE TABLE IF NOT EXISTS _directional_rounds(
  expiry INTEGER PRIMARY KEY,
  ticker TEXT NOT NULL,
  minutes_left INTEGER NOT NULL CHECK(minutes_left IN (8,6,4)),
  captured_at TEXT NOT NULL,
  side TEXT NOT NULL CHECK(side IN ('Up','Down')),
  confidence REAL NOT NULL CHECK(confidence BETWEEN 0.5 AND 1),
  entry_ask REAL CHECK(entry_ask>0 AND entry_ask<1)
);
CREATE TRIGGER IF NOT EXISTS record_chart_round_v1 AFTER INSERT ON _checkpoint_data
WHEN NEW.expiry>=1794853800 AND NEW.minutes_left IN (8,6,4)
  AND NEW.result IS NULL AND NEW.btc_lean IN ('Up','Down') AND NEW.btc_probability BETWEEN 0.5 AND 1
  AND NEW.btc_ticker IS NOT NULL AND NEW.ticker=NEW.btc_ticker
  AND unixepoch(NEW.btc_captured_at) BETWEEN NEW.expiry-60*NEW.minutes_left AND NEW.expiry-60*NEW.minutes_left+25
BEGIN
  INSERT INTO _directional_rounds(expiry,ticker,minutes_left,captured_at,side,confidence,entry_ask)
  VALUES(NEW.expiry,NEW.btc_ticker,NEW.minutes_left,NEW.btc_captured_at,NEW.btc_lean,NEW.btc_probability,
    CASE WHEN NEW.btc_ask>0 AND NEW.btc_ask<1 THEN NEW.btc_ask END)
  ON CONFLICT(expiry) DO NOTHING;
END;

DROP VIEW IF EXISTS calls;
CREATE VIEW IF NOT EXISTS calls AS
WITH shift AS (
 SELECT expiry,minutes_left,
 CASE WHEN julianday(captured_at)>=julianday(strftime('%Y',captured_at)||'-03-08','weekday 0','+10 hours')
       AND julianday(captured_at)<julianday(strftime('%Y',captured_at)||'-11-01','weekday 0','+9 hours')
      THEN '-7 hours' ELSE '-8 hours' END AS offset
 FROM _checkpoint_data
)
SELECT c.round_pt,c.minutes_left,
 CASE WHEN c.btc_ticker=c.ticker AND c.btc_lean IN ('Up','Down') THEN c.btc_lean END AS chart_call,
 CASE WHEN d.minutes_left=c.minutes_left THEN d.side END AS locked_round_call,
 CASE WHEN d.minutes_left=c.minutes_left THEN round(100*d.entry_ask,2) END AS paper_entry_cents,
 CASE WHEN c.lean IS NOT NULL THEN c.lean||' · '||printf('%.1f%%',100*c.probability)
      WHEN c.capped_recorded=1 THEN 'No data' ELSE 'Not recorded' END AS capped_forecast,
 CASE WHEN c.btc_lean IS NOT NULL THEN c.btc_lean||' · '||printf('%.1f%%',100*c.btc_probability)
      WHEN c.btc_decision IS NOT NULL THEN 'No data' ELSE 'Not recorded' END AS btc_forecast,
c.priority_at_capture AS priority_model,c.target AS price_to_beat,

 c.result,CASE WHEN julianday(c.captured_at) IS NULL THEN c.captured_at ELSE
 CAST(((CAST(strftime('%H',c.captured_at,shift.offset) AS INTEGER)+11)%12)+1 AS TEXT)||strftime(':%M:%S',c.captured_at,shift.offset)||
 CASE WHEN CAST(strftime('%H',c.captured_at,shift.offset) AS INTEGER)<12 THEN 'am' ELSE 'pm' END END AS captured_at,c.ticker
FROM _checkpoint_data c JOIN shift USING(expiry,minutes_left) LEFT JOIN _directional_rounds d ON d.expiry=c.expiry AND d.ticker=c.btc_ticker ORDER BY c.expiry DESC,c.minutes_left ASC;

DROP VIEW IF EXISTS round_decisions;
CREATE VIEW IF NOT EXISTS round_decisions AS
WITH latest AS (
 SELECT expiry, MIN(minutes_left) AS minutes_left, MAX(COALESCE(ticker,btc_ticker)) AS market_ticker FROM _checkpoint_data GROUP BY expiry
)
SELECT c.round_pt,c.minutes_left,
 CASE WHEN d.side IS NOT NULL THEN d.side WHEN c.expiry>=1794853800 THEN preview.btc_lean END AS round_call,
 CASE WHEN d.side IS NOT NULL THEN 'Locked' WHEN preview.btc_lean IS NOT NULL AND c.expiry>=1794853800 THEN 'Preview' END AS call_status,
 CASE WHEN d.side IS NOT NULL THEN d.minutes_left WHEN preview.btc_lean IS NOT NULL AND c.expiry>=1794853800 THEN 10 END AS call_at_min,
 ROUND(100*CASE WHEN d.side IS NOT NULL THEN d.confidence WHEN c.expiry>=1794853800 THEN preview.btc_probability END,1) AS call_confidence_pct,
 ROUND(100*d.entry_ask,2) AS paper_entry_cents,
 CASE WHEN c.lean IS NOT NULL THEN c.lean||' · '||printf('%.1f%%',100*c.probability)
      WHEN c.capped_recorded=1 THEN 'No data' ELSE 'Not recorded' END AS capped_forecast,
 CASE WHEN c.btc_lean IS NOT NULL THEN c.btc_lean||' · '||printf('%.1f%%',100*c.btc_probability)
      WHEN c.btc_decision IS NOT NULL THEN 'No data' ELSE 'Not recorded' END AS btc_forecast,
 c.priority_at_capture AS priority_model,
 COALESCE(c.target,(SELECT h.target FROM _checkpoint_data h WHERE h.expiry=c.expiry AND h.target IS NOT NULL LIMIT 1)) AS price_to_beat,

 CASE WHEN settled.result IS NOT NULL THEN 'Settled' WHEN c.expiry<=unixepoch() THEN 'Closed' ELSE 'Open' END AS round_status,
 settled.result,
 CASE WHEN settled.result IN ('Up','Down') AND d.entry_ask IS NOT NULL
 THEN round((d.side=settled.result)-d.entry_ask,4) END AS gross_paper_usd,settled.final_index,
 CASE WHEN l.market_ticker GLOB 'KXBTC15M-*-??' THEN
   'https://kalshi.com/markets/kxbtc15m/btc-15-min/'||lower(substr(l.market_ticker,1,length(l.market_ticker)-3))
 END AS market_url
FROM latest l JOIN _checkpoint_data c USING(expiry,minutes_left)
LEFT JOIN _directional_rounds d ON d.expiry=c.expiry AND d.ticker=l.market_ticker
LEFT JOIN _checkpoint_data preview ON preview.expiry=c.expiry AND preview.minutes_left=10 AND preview.btc_ticker=l.market_ticker
LEFT JOIN _checkpoint_data settled ON settled.expiry=c.expiry AND settled.minutes_left=(
 SELECT h.minutes_left FROM _checkpoint_data h WHERE h.expiry=c.expiry AND h.result IN ('Up','Down') LIMIT 1)
ORDER BY c.expiry DESC;
