CREATE TABLE IF NOT EXISTS six_minute_hybrid_v1 (
  expiry INTEGER PRIMARY KEY,
  ticker TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  quoted_at INTEGER NOT NULL,
  chart_up REAL NOT NULL,
  midpoint REAL NOT NULL,
  hybrid_up REAL NOT NULL CHECK(hybrid_up BETWEEN 0 AND 1),
  direction TEXT NOT NULL,
  paper_call TEXT NOT NULL,
  ask_usd REAL,
  all_in_usd REAL
);
CREATE VIEW IF NOT EXISTS six_minute_hybrid_grades AS
SELECT h.*,c.result,
  CASE WHEN c.result IN ('Up','Down') THEN h.direction=c.result END AS correct,
  CASE WHEN h.paper_call IN ('Up','Down') AND c.result IN ('Up','Down')
       THEN round((h.direction=c.result)-h.all_in_usd,4) END AS net_usd
FROM six_minute_hybrid_v1 h JOIN _checkpoint_data c
ON c.expiry=h.expiry AND c.minutes_left=6 AND c.ticker=h.ticker
AND c.btc_ticker=h.ticker AND c.btc_captured_at=h.captured_at;
-- Execution comparison only. Each row is the same existing six-minute candidate.
-- Use the fresh four-minute executable ask and require the chart to still agree.
CREATE VIEW IF NOT EXISTS six_minute_hybrid_price_test AS
WITH later AS (
  SELECT h.expiry,h.ticker,h.direction,h.all_in_usd AS six_cost,h.net_usd AS six_net,h.result,
         p.btc_lean AS four_direction,p.captured_at AS four_captured_at,
         CASE h.direction WHEN 'Up' THEN p.up_ask ELSE p.down_ask END AS four_ask
  FROM six_minute_hybrid_grades h LEFT JOIN _checkpoint_data p
    ON p.expiry=h.expiry AND p.ticker=h.ticker AND p.btc_ticker=h.ticker AND p.minutes_left=4
    AND unixepoch(p.captured_at) BETWEEN p.expiry-240 AND p.expiry-215
    AND unixepoch(p.btc_captured_at) BETWEEN p.expiry-240 AND p.expiry-215
  WHERE h.paper_call IN ('Up','Down')
), ticks AS (
  SELECT *,CAST(round(four_ask*10000) AS INTEGER) AS t FROM later
), costs AS (
  SELECT *,CASE WHEN t BETWEEN 1 AND 9999 THEN ((t+(7*t*(10000-t)+999999)/1000000+99)/100)/100.0 END AS four_cost FROM ticks
), decisions AS (
  SELECT *,CASE WHEN four_captured_at IS NULL OR four_direction IS NULL OR four_cost IS NULL THEN NULL
    ELSE four_direction=direction AND four_cost<=six_cost-.03+1e-12 END AS cheaper_entry
  FROM costs
)
SELECT expiry,ticker,direction,six_cost,six_net,result,four_captured_at,four_direction,
       four_ask,four_cost,cheaper_entry,
       CASE WHEN result IN ('Up','Down') AND cheaper_entry=1 THEN round((direction=result)-four_cost,4)
            WHEN result IN ('Up','Down') AND cheaper_entry=0 THEN 0 END AS alternative_net
FROM decisions;
