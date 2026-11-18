-- Counts are paired distinct six-minute rounds. Official settlement grades all three forecasts.
WITH grades AS (
SELECT h.*,c.result,
  CASE WHEN c.result IN ('Up','Down') THEN h.direction=c.result END AS correct,
  CASE WHEN h.paper_call IN ('Up','Down') AND c.result IN ('Up','Down')
       THEN round((h.direction=c.result)-h.all_in_usd,4) END AS net_usd
FROM six_minute_hybrid_v1 h JOIN _checkpoint_data c
ON c.expiry=h.expiry AND c.minutes_left=6 AND c.ticker=h.ticker
AND c.btc_ticker=h.ticker AND c.btc_captured_at=h.captured_at
)
SELECT count(*) AS paired_captures, count(CASE WHEN result IN ('Up','Down') THEN 1 END) AS graded,
       sum(CASE WHEN result IN ('Up','Down') THEN direction=result END) AS hybrid_correct,
       sum(CASE WHEN result IN ('Up','Down') THEN (chart_up>=0.5)=(result='Up') END) AS chart_correct,
       sum(CASE WHEN result IN ('Up','Down') THEN (midpoint>=0.5)=(result='Up') END) AS midpoint_correct,
       round(avg(CASE WHEN result IN ('Up','Down') THEN (hybrid_up-(result='Up'))*(hybrid_up-(result='Up')) END),6) AS hybrid_brier,
       round(avg(CASE WHEN result IN ('Up','Down') THEN (chart_up-(result='Up'))*(chart_up-(result='Up')) END),6) AS chart_brier,
       round(avg(CASE WHEN result IN ('Up','Down') THEN (midpoint-(result='Up'))*(midpoint-(result='Up')) END),6) AS midpoint_brier,
       count(CASE WHEN paper_call IN ('Up','Down') AND result IN ('Up','Down') THEN 1 END) AS graded_entries,
       count(CASE WHEN paper_call=result THEN 1 END) AS wins,
       coalesce(round(sum(net_usd),4),0) AS net_usd
FROM grades;

-- Compare the two entry times on the identical opportunities that had a four-minute observation.
WITH grades AS (
SELECT h.*,c.result,
  CASE WHEN c.result IN ('Up','Down') THEN h.direction=c.result END AS correct,
  CASE WHEN h.paper_call IN ('Up','Down') AND c.result IN ('Up','Down')
       THEN round((h.direction=c.result)-h.all_in_usd,4) END AS net_usd
FROM six_minute_hybrid_v1 h JOIN _checkpoint_data c
ON c.expiry=h.expiry AND c.minutes_left=6 AND c.ticker=h.ticker
AND c.btc_ticker=h.ticker AND c.btc_captured_at=h.captured_at
), price_test AS (
WITH later AS (
  SELECT h.expiry,h.ticker,h.direction,h.all_in_usd AS six_cost,h.net_usd AS six_net,h.result,
         p.btc_lean AS four_direction,p.captured_at AS four_captured_at,
         CASE h.direction WHEN 'Up' THEN p.up_ask ELSE p.down_ask END AS four_ask
  FROM grades h LEFT JOIN _checkpoint_data p
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
FROM decisions
)
SELECT count(*) AS eligible_six_minute_signals,
       count(CASE WHEN alternative_net IS NOT NULL THEN 1 END) AS paired_graded,
       sum(CASE WHEN alternative_net IS NOT NULL THEN cheaper_entry END) AS four_minute_entries,
       round(sum(CASE WHEN alternative_net IS NOT NULL THEN six_net END),4) AS immediate_net,
       round(sum(alternative_net),4) AS alternative_net
FROM price_test;
