CREATE TABLE IF NOT EXISTS rounds(
 ticker TEXT PRIMARY KEY,expiry INTEGER NOT NULL, y INTEGER NOT NULL,
 chart_up REAL,holdout_up REAL,bid_ticks INTEGER,ask_ticks INTEGER,
 state TEXT NOT NULL,retry_after INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS waiting_for_quote ON rounds(retry_after,expiry) WHERE state='pending';
CREATE TABLE IF NOT EXISTS sync_state(id INTEGER PRIMARY KEY,lease_until INTEGER NOT NULL DEFAULT 0,last_run INTEGER,last_error TEXT);
INSERT OR IGNORE INTO sync_state(id) VALUES(1);
CREATE VIEW IF NOT EXISTS coverage AS SELECT state,count(*) rounds FROM rounds GROUP BY state;
CREATE VIEW IF NOT EXISTS research_results AS
WITH forecasts AS (
 SELECT 'Retrospective current model' AS sample,*,chart_up AS p FROM rounds WHERE state='paired'
 UNION ALL SELECT 'Chronological holdout',*,holdout_up FROM rounds WHERE state='paired' AND holdout_up IS NOT NULL
 UNION ALL SELECT 'Exact model after fitting',*,chart_up FROM rounds WHERE state='paired' AND expiry>1794191400
), sides AS (
 SELECT *,CASE WHEN p>=0.5 THEN ask_ticks ELSE 10000-bid_ticks END AS ticks,
 ((p>=0.5)=y) AS hit, max(p,1.0-p) AS conf,
 CASE WHEN p>=0.5 THEN (bid_ticks+ask_ticks)/20000.0 ELSE 1.0-(bid_ticks+ask_ticks)/20000.0 END AS mid FROM forecasts
), costs AS (
 SELECT *,((ticks+(7*ticks*(10000-ticks)+999999)/1000000+99)/100)/100.0 AS cost FROM sides
), rules(name) AS (VALUES('All calls'),('50-cent cap'),('Frozen trial')),
qualified AS (SELECT * FROM costs CROSS JOIN rules WHERE name='All calls' OR
 (cost<=0.50 AND (name='50-cent cap' OR (conf+mid)/2+1e-12>=cost+0.05)))
SELECT sample,name AS rule,count(*) entries,sum(hit) wins,round(sum(hit-ticks/10000.0),4) gross_usd,
 round(sum(hit-cost),4) net_usd,round(sum(hit-cost-0.01),4) one_cent_worse_usd
 FROM qualified GROUP BY sample,name;
