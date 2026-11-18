ALTER TABLE _checkpoint_data ADD COLUMN locked_round_call TEXT;
ALTER TABLE _checkpoint_data ADD COLUMN paper_entry_cents REAL;
ALTER TABLE _checkpoint_data ADD COLUMN captured_at_pt TEXT GENERATED ALWAYS AS (
  CASE WHEN julianday(captured_at) IS NULL THEN captured_at ELSE
       (((CAST(strftime('%H',captured_at,CASE WHEN julianday(captured_at)>=julianday(strftime('%Y',captured_at)||'-03-08','weekday 0','+10 hours')
       AND julianday(captured_at)<julianday(strftime('%Y',captured_at)||'-11-01','weekday 0','+9 hours')
      THEN '-7 hours' ELSE '-8 hours' END) AS INTEGER)+11)%12)+1)||strftime(':%M:%S',captured_at)||
       CASE WHEN CAST(strftime('%H',captured_at,CASE WHEN julianday(captured_at)>=julianday(strftime('%Y',captured_at)||'-03-08','weekday 0','+10 hours')
       AND julianday(captured_at)<julianday(strftime('%Y',captured_at)||'-11-01','weekday 0','+9 hours')
      THEN '-7 hours' ELSE '-8 hours' END) AS INTEGER)<12 THEN 'am' ELSE 'pm' END END
) VIRTUAL;
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
UPDATE _checkpoint_data AS c
SET locked_round_call=d.side, paper_entry_cents=ROUND(100*d.entry_ask,2)
FROM _directional_rounds AS d
WHERE c.expiry=d.expiry AND c.minutes_left=d.minutes_left AND c.btc_ticker=d.ticker;
DROP VIEW IF EXISTS calls;
