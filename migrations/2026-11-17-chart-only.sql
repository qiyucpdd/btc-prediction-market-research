-- Apply to the November 17 journal after deploying the chart-only Worker.
-- All checkpoint, entry, frozen probability and settlement rows stay in place.
-- model_matchup contained a derived tally. See backtest/legacy_matchup.sql.
DROP VIEW IF EXISTS six_minute_hybrid_price_test;
DROP VIEW IF EXISTS six_minute_hybrid_grades;
DROP VIEW IF EXISTS accuracy_by_minute;
DROP VIEW IF EXISTS round_decisions;
DROP TRIGGER IF EXISTS capture_nov16_model_trial;
DROP TRIGGER IF EXISTS save_checkpoint_priority;
DROP TRIGGER IF EXISTS grade_model_matchup;
DROP INDEX IF EXISTS calls_agreement;
DROP INDEX IF EXISTS calls_review;
DROP INDEX IF EXISTS calls_validation;
DROP TABLE IF EXISTS model_matchup;

CREATE VIEW IF NOT EXISTS round_decisions AS
WITH latest AS (
 SELECT expiry, MIN(minutes_left) AS minutes_left, MAX(COALESCE(ticker,btc_ticker)) AS market_ticker FROM _checkpoint_data GROUP BY expiry
)
SELECT c.round_pt,c.minutes_left,
 forecast.btc_lean AS round_call,
 CASE WHEN forecast.minutes_left IS NULL THEN NULL
      WHEN forecast.minutes_left<>c.minutes_left THEN 'Last valid'
      WHEN forecast.minutes_left=10 THEN 'Preview' ELSE 'Updated' END AS call_status,
 forecast.minutes_left AS call_at_min,
 ROUND(100*forecast.btc_probability,1) AS call_confidence_pct,
 d.side AS locked_round_call, d.minutes_left AS entry_at_min,
 ROUND(100*d.entry_ask,2) AS paper_entry_cents,
 s.paper_call AS six_minute_paper_call, s.net_usd AS six_minute_paper_net_usd,
 COALESCE(c.target,(SELECT h.target FROM _checkpoint_data h WHERE h.expiry=c.expiry AND h.target IS NOT NULL LIMIT 1)) AS price_to_beat,

 CASE WHEN settled.result IS NOT NULL THEN 'Settled' WHEN c.expiry<=unixepoch() THEN 'Closed' ELSE 'Open' END AS round_status,
 settled.result,
 CASE WHEN settled.result IN ('Up','Down') AND d.entry_ask IS NOT NULL
 THEN round((d.side=settled.result)-d.entry_ask,4) END AS gross_paper_usd,settled.final_index,
 CASE WHEN l.market_ticker GLOB 'KXBTC15M-*-??' THEN
   'https://kalshi.com/markets/kxbtc15m/btc-15-min/'||lower(substr(l.market_ticker,1,length(l.market_ticker)-3))
 END AS market_url
FROM latest l JOIN _checkpoint_data c USING(expiry,minutes_left)
LEFT JOIN six_minute_paper s ON s.expiry=c.expiry AND s.ticker=l.market_ticker
LEFT JOIN _directional_rounds d ON d.expiry=c.expiry AND d.ticker=l.market_ticker
LEFT JOIN _checkpoint_data forecast ON forecast.expiry=c.expiry AND forecast.minutes_left=(
 SELECT p.minutes_left FROM _checkpoint_data p
 WHERE p.expiry=c.expiry AND p.expiry>=1794853800 AND p.minutes_left IN (10,8,6,4)
 AND p.btc_ticker=l.market_ticker AND p.btc_ticker=p.ticker AND p.btc_lean IN ('Up','Down')
 AND p.btc_probability BETWEEN 0.5 AND 1
 AND unixepoch(p.btc_captured_at) BETWEEN p.expiry-60*p.minutes_left AND p.expiry-60*p.minutes_left+25
 ORDER BY p.minutes_left ASC LIMIT 1)
LEFT JOIN _checkpoint_data settled ON settled.expiry=c.expiry AND settled.minutes_left=(
 SELECT h.minutes_left FROM _checkpoint_data h WHERE h.expiry=c.expiry AND h.ticker=l.market_ticker AND h.result IN ('Up','Down') LIMIT 1)
ORDER BY c.expiry DESC;
