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
