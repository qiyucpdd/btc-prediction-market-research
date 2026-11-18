CREATE TABLE IF NOT EXISTS _checkpoint_data(
  round_pt TEXT NOT NULL, minutes_left INTEGER NOT NULL,
  lean TEXT, btc_lean TEXT, priority_at_capture TEXT,
  decision TEXT NOT NULL, btc_decision TEXT, probability REAL, btc_probability REAL,
  ask REAL, btc_ask REAL, btc REAL, target REAL, result TEXT, final_index REAL, gross_usd REAL,
  model_id TEXT, detail TEXT, raw_up REAL, midpoint REAL, up_ask REAL, down_ask REAL,
  six_trial_call TEXT, agreement_call TEXT, agreement_recheck_call TEXT, agreement_recheck_ask REAL,
  calibration_review TEXT, last_settle_check INTEGER NOT NULL DEFAULT 0,
  capped_recorded INTEGER NOT NULL DEFAULT 1, expiry INTEGER NOT NULL,
  btc_captured_at TEXT, btc_ticker TEXT, captured_at TEXT NOT NULL, ticker TEXT,
  research_version TEXT, research_btc_up REAL, research_capped_up REAL,
  locked_round_call TEXT,
  paper_entry_cents REAL,
  captured_at_pt TEXT GENERATED ALWAYS AS (
  CASE WHEN julianday(captured_at) IS NULL THEN captured_at ELSE
       (((CAST(strftime('%H',captured_at,CASE WHEN julianday(captured_at)>=julianday(strftime('%Y',captured_at)||'-03-08','weekday 0','+10 hours')
       AND julianday(captured_at)<julianday(strftime('%Y',captured_at)||'-11-01','weekday 0','+9 hours')
      THEN '-7 hours' ELSE '-8 hours' END) AS INTEGER)+11)%12)+1)||strftime(':%M:%S',captured_at)||
       CASE WHEN CAST(strftime('%H',captured_at,CASE WHEN julianday(captured_at)>=julianday(strftime('%Y',captured_at)||'-03-08','weekday 0','+10 hours')
       AND julianday(captured_at)<julianday(strftime('%Y',captured_at)||'-11-01','weekday 0','+9 hours')
      THEN '-7 hours' ELSE '-8 hours' END) AS INTEGER)<12 THEN 'am' ELSE 'pm' END END
) VIRTUAL,
  PRIMARY KEY(expiry DESC, minutes_left ASC)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS calls_pending_result ON _checkpoint_data(last_settle_check,expiry,ticker)
  WHERE result IS NULL AND ticker IS NOT NULL;

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

CREATE TRIGGER IF NOT EXISTS show_checkpoint_lock AFTER INSERT ON _directional_rounds
BEGIN
  UPDATE _checkpoint_data SET locked_round_call=NEW.side, paper_entry_cents=ROUND(100*NEW.entry_ask,2) WHERE expiry=NEW.expiry AND minutes_left=NEW.minutes_left AND btc_ticker=NEW.ticker;
END;
CREATE TRIGGER IF NOT EXISTS correct_checkpoint_lock AFTER UPDATE ON _directional_rounds
BEGIN
  UPDATE _checkpoint_data SET locked_round_call=NULL, paper_entry_cents=NULL WHERE expiry=OLD.expiry AND minutes_left=OLD.minutes_left AND btc_ticker=OLD.ticker;
  UPDATE _checkpoint_data SET locked_round_call=NEW.side, paper_entry_cents=ROUND(100*NEW.entry_ask,2) WHERE expiry=NEW.expiry AND minutes_left=NEW.minutes_left AND btc_ticker=NEW.ticker;
END;
CREATE TRIGGER IF NOT EXISTS clear_checkpoint_lock AFTER DELETE ON _directional_rounds
BEGIN
  UPDATE _checkpoint_data SET locked_round_call=NULL, paper_entry_cents=NULL WHERE expiry=OLD.expiry AND minutes_left=OLD.minutes_left AND btc_ticker=OLD.ticker;
END;

CREATE TABLE IF NOT EXISTS six_minute_paper (
  round_pt TEXT NOT NULL,
  paper_call TEXT NOT NULL,
  btc_side TEXT,
  btc_confidence REAL,
  estimated_win_probability REAL,
  ask_usd REAL,
  all_in_usd REAL,
  result TEXT,
  net_usd REAL GENERATED ALWAYS AS (
    CASE WHEN paper_call IN ('Up','Down') AND result IN ('Up','Down')
      THEN round((paper_call=result)-all_in_usd,4) END
  ) VIRTUAL,
  reason TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  ticker TEXT,
  expiry INTEGER PRIMARY KEY DESC
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS six_paper_entries ON six_minute_paper(expiry)
  WHERE paper_call IN ('Up','Down');
CREATE TRIGGER IF NOT EXISTS capture_six50_v1 AFTER INSERT ON _checkpoint_data
WHEN NEW.minutes_left=6 AND NEW.expiry>=1794866400 AND NEW.result IS NULL
BEGIN
 INSERT OR IGNORE INTO six_minute_paper
   (round_pt,paper_call,btc_side,btc_confidence,estimated_win_probability,ask_usd,all_in_usd,reason,captured_at,ticker,expiry)
 SELECT NEW.round_pt,CASE WHEN reason='Qualified' THEN NEW.btc_lean ELSE 'Pass' END,
   NEW.btc_lean,NEW.btc_probability,p_win,ask,cost,reason,NEW.captured_at,NEW.ticker,NEW.expiry
 FROM (
  SELECT *,CASE
   WHEN NOT valid OR valid IS NULL THEN 'No timely chart forecast'
   WHEN ask IS NULL OR p_win IS NULL THEN 'No fresh two-sided quote'
   WHEN cost>0.50 THEN 'Over 50 cents'
   WHEN p_win+1e-12<cost+0.05 THEN 'Estimated edge below 5 cents'
   WHEN cost>50.0+COALESCE((SELECT SUM(CASE WHEN result IN ('Up','Down') THEN net_usd ELSE -all_in_usd END)
         FROM six_minute_paper WHERE paper_call IN ('Up','Down')),0)+1e-12 THEN 'Paper balance too low'
   ELSE 'Qualified' END AS reason
  FROM (
   SELECT *,((ticks+(7*ticks*(10000-ticks)+999999)/1000000+99)/100)/100.0 AS cost
   FROM (
    SELECT NEW.ticker=NEW.btc_ticker AND NEW.btc_lean IN ('Up','Down') AND NEW.btc_probability BETWEEN .5 AND 1
         AND unixepoch(NEW.btc_captured_at) BETWEEN NEW.expiry-360 AND NEW.expiry-335 AS valid,
     CASE WHEN NEW.btc_ask>0 AND NEW.btc_ask<1 THEN NEW.btc_ask END AS ask,
     CASE WHEN NEW.btc_ask>0 AND NEW.btc_ask<1 THEN CAST(round(NEW.btc_ask*10000) AS INTEGER) END AS ticks,
     CASE WHEN NEW.midpoint>0 AND NEW.midpoint<1 AND NEW.btc_lean IN ('Up','Down')
          AND NEW.btc_probability BETWEEN .5 AND 1 THEN
        (NEW.btc_probability+CASE NEW.btc_lean WHEN 'Up' THEN NEW.midpoint ELSE 1-NEW.midpoint END)/2 END AS p_win
   )
  )
 );
END;
CREATE TRIGGER IF NOT EXISTS settle_six50_v1 AFTER UPDATE OF result ON _checkpoint_data
WHEN NEW.minutes_left=6 AND OLD.result IS NOT NEW.result
BEGIN
 UPDATE six_minute_paper SET result=CASE WHEN NEW.result IN ('Up','Down') THEN NEW.result END
 WHERE expiry=NEW.expiry AND ticker=NEW.ticker;
END;
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

CREATE VIEW IF NOT EXISTS round_decisions AS
WITH latest AS (
 SELECT expiry, MIN(minutes_left) AS minutes_left, MAX(COALESCE(ticker,btc_ticker)) AS market_ticker FROM _checkpoint_data GROUP BY expiry
), recorded AS (
SELECT c.expiry,c.round_pt,c.minutes_left,
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
)
SELECT
 CASE WHEN round_call IS NULL THEN
        CASE WHEN round_status='Open' THEN 'No valid chart call yet' ELSE 'No recorded chart call' END
      ELSE printf('%s · %.1f%% at %dm',round_call,call_confidence_pct,call_at_min)
        || CASE WHEN call_status='Last valid' OR
                     (call_at_min>4 AND unixepoch()>expiry-(call_at_min-2)*60+25)
                THEN ' · last valid' ELSE '' END
 END AS forecast,
 CASE round_status WHEN 'Closed' THEN 'Awaiting settlement' ELSE round_status END
     || ' · ' || round_pt || ' PT' AS round_closes_pt,
 CASE WHEN locked_round_call IS NOT NULL THEN locked_round_call || ' at ' || entry_at_min || 'm · '
        || CASE WHEN paper_entry_cents IS NULL THEN 'unpriced' ELSE printf('%g¢',paper_entry_cents) END
      WHEN round_status='Open' AND unixepoch()<expiry-8*60 THEN 'Waiting for 8m'
      WHEN round_status='Open' AND unixepoch()<=expiry-4*60+25 THEN 'Waiting for valid entry'
      ELSE 'No locked entry'
 END AS paper_entry,
 CASE WHEN result IS NULL THEN 'Pending'
      WHEN locked_round_call IS NULL THEN result || ' · no locked entry'
      WHEN gross_paper_usd IS NULL THEN result || ' · ' ||
        CASE WHEN result=locked_round_call THEN 'paper win' ELSE 'paper loss' END || ' (unpriced)'
      ELSE result || ' · ' || CASE WHEN result=locked_round_call THEN 'paper win +' ELSE 'paper loss −' END
        || printf('%g¢ gross',round(abs(gross_paper_usd)*100,2))
 END AS official_outcome,
 round_pt,minutes_left,round_call,call_status,call_at_min,call_confidence_pct,
 locked_round_call,entry_at_min,paper_entry_cents,six_minute_paper_call,six_minute_paper_net_usd,
 price_to_beat,round_status,result,gross_paper_usd,final_index,market_url,expiry
FROM recorded
ORDER BY expiry DESC;
