-- Rebuild the retired standings from original checkpoint rows at the recorded reset boundary.
SELECT count(*) AS paired_graded, sum(btc_lean=result) AS btc_correct_leans,
       sum(lean=result) AS capped_correct_leans
FROM _checkpoint_data
WHERE expiry>=unixepoch('2026-11-16T10:30:00Z') AND minutes_left IN (10,8,6,4)
  AND ticker=btc_ticker AND result IN ('Up','Down')
  AND lean IN ('Up','Down') AND btc_lean IN ('Up','Down');
