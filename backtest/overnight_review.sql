-- Compare each fixed challenger with its incumbent on the same settled checkpoints.
WITH evaluated AS (
  SELECT expiry,minutes_left,result,up_ask,down_ask,'BTC price model' AS model,
         CASE btc_lean WHEN 'Up' THEN btc_probability WHEN 'Down' THEN 1.0-btc_probability END AS deployed,
         research_btc_up AS trial
  FROM _checkpoint_data WHERE research_version='nov16-overnight-v1' AND btc_ticker=ticker
  UNION ALL
  SELECT expiry,minutes_left,result,up_ask,down_ask,'Capped watcher',
         CASE lean WHEN 'Up' THEN probability WHEN 'Down' THEN 1.0-probability END,research_capped_up
  FROM _checkpoint_data WHERE research_version='nov16-overnight-v1'
), paired AS (
  SELECT * FROM evaluated WHERE result IN ('Up','Down') AND trial IS NOT NULL AND deployed IS NOT NULL
), forecasts AS (
  SELECT expiry,minutes_left,result,up_ask,down_ask,model,'Current' AS version,deployed AS p FROM paired
  UNION ALL SELECT expiry,minutes_left,result,up_ask,down_ask,model,'Trial',trial FROM paired
), signals AS (
  SELECT *, CASE WHEN p>=0.5 THEN 'Up' ELSE 'Down' END AS direction,
         CASE WHEN p>=0.5 THEN up_ask ELSE down_ask END AS ask FROM forecasts
), eligible AS (
  SELECT *,row_number() OVER (PARTITION BY model,version,expiry ORDER BY minutes_left DESC) AS entry_number
  FROM signals WHERE minutes_left IN (8,4) AND ask>0 AND ask<=0.90
    AND max(p,1.0-p)>=0.90 AND max(p,1.0-p)>ask+1e-12
), totals AS (
  SELECT model,version,COUNT(DISTINCT expiry) AS rounds,COUNT(*) AS checkpoints,
         SUM(direction=result) AS correct,
         round(avg((p-(result='Up'))*(p-(result='Up'))),6) AS brier
  FROM signals GROUP BY model,version
), entries AS (
  SELECT model,version,COUNT(*) AS paper_entries,SUM(direction=result) AS paper_wins,
         round(sum((direction=result)-ask),4) AS gross_usd
  FROM eligible WHERE entry_number=1 GROUP BY model,version
)
SELECT t.*,COALESCE(e.paper_entries,0) AS paper_entries,COALESCE(e.paper_wins,0) AS paper_wins,
       COALESCE(e.gross_usd,0) AS gross_usd
FROM totals t LEFT JOIN entries e USING(model,version)
ORDER BY model,version;
