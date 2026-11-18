-- Six-minute midpoint benchmark. The first eligible expiry is November 16, 2026 at 4:30 p.m. Pacific.
-- Each probability comes from chart and book inputs recorded together before official grading.
WITH bounds AS (
  SELECT 1794875400 AS first_expiry, unixepoch()+360-25 AS latest_due
), captures AS (
  SELECT c.*,
    CASE WHEN btc_ticker=ticker AND btc_probability BETWEEN 0.5 AND 1
      AND midpoint>0 AND midpoint<1 AND btc_lean IN ('Up','Down')
      AND unixepoch(btc_captured_at) BETWEEN expiry-360 AND expiry-335
      AND unixepoch(captured_at) BETWEEN expiry-360 AND expiry-335
      THEN CASE WHEN btc_lean='Up' THEN btc_probability ELSE 1-btc_probability END END AS chart,
    result IN ('Up','Down') AS settled
  FROM _checkpoint_data c,bounds
  WHERE minutes_left=6 AND expiry BETWEEN first_expiry AND latest_due
), scores AS (
  SELECT *, result='Up' AS y FROM captures WHERE chart IS NOT NULL AND settled
)
SELECT max(0,1+CAST((latest_due-first_expiry)/900 AS INTEGER))*(latest_due>=first_expiry) AS expected,
  (SELECT count(*) FROM captures) AS recorded,
  (SELECT count(*) FROM captures WHERE chart IS NULL) AS missing_inputs,
  (SELECT count(*) FROM captures WHERE chart IS NOT NULL AND coalesce(settled,0)=0) AS pending_with_inputs,
  (SELECT count(*) FROM scores) AS paired_graded,
  (SELECT sum((chart>=0.5)=y) FROM scores) AS chart_correct,
  (SELECT sum((midpoint>=0.5)=y) FROM scores) AS midpoint_correct,
  (SELECT round(avg((chart-y)*(chart-y)),6) FROM scores) AS chart_brier,
  (SELECT round(avg((midpoint-y)*(midpoint-y)),6) FROM scores) AS midpoint_brier
FROM bounds;
