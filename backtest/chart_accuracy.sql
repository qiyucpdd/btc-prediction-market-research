-- One original chart capture per ticker and minute, scored at official settlement.
WITH timely AS (
  SELECT expiry,minutes_left,result,btc_lean,btc,target,
         CASE WHEN btc_lean='Up' THEN btc_probability ELSE 1-btc_probability END AS p
  FROM _checkpoint_data
  WHERE expiry>=unixepoch('2026-11-16T10:30:00Z') AND minutes_left IN (10,8,6,4)
    AND btc_ticker=ticker AND btc_lean IN ('Up','Down') AND btc_probability BETWEEN .5 AND 1
    AND unixepoch(btc_captured_at) BETWEEN expiry-minutes_left*60 AND expiry-minutes_left*60+25
)
SELECT minutes_left,count(DISTINCT expiry) AS captured_rounds,
       count(CASE WHEN result IN ('Up','Down') THEN 1 END) AS graded,
       sum(CASE WHEN result IN ('Up','Down') THEN result=btc_lean END) AS correct,
       round(avg(CASE WHEN result IN ('Up','Down') THEN (p-(result='Up'))*(p-(result='Up')) END),6) AS brier,
       count(CASE WHEN result IN ('Up','Down') AND btc>0 AND target>0 THEN 1 END) AS spot_paired,
       sum(CASE WHEN result IN ('Up','Down') AND btc>0 AND target>0 THEN (btc>=target)=(result='Up') END) AS spot_correct,
       sum(CASE WHEN result IN ('Up','Down') AND btc>0 AND target>0 THEN btc_lean=result END) AS chart_correct_on_spot_pairs
FROM timely GROUP BY minutes_left ORDER BY minutes_left DESC;
