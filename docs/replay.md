# Replaying the six-minute study

The six-minute comparison tests whether a chart, the market midpoint or a hybrid gives the best forecast at the same instant. January through November 2026 are monthly test blocks. Each block trains on earlier rounds with a seven-day gap before the test month. December 2025 seeds the first fit. Researchers explored this archive before freezing the hybrid, so future official settlements provide the prospective test.

## Inputs for a full historical rerun

Use a local copy of the November 16 research snapshot or equivalent market data you have permission to use. The public repository includes the model, analysis code and aggregate outputs. The original exchange records stay in the local snapshot. Later data downloads can contain revisions.

Place the following files in `backtest/six-minute/`.

| Input | Contents |
| --- | --- |
| `replay.csv.gz` | One record per settled ticker. Fields are ticker, expiry, target, y, btc, p_up, x_strike, x_open, x_momentum, bid_ticks, ask_ticks, status and target_source. Expiry is Unix seconds, y is one for an official Up result, and 10,000 ticks equal one dollar. |
| `candles.csv.gz` | Coinbase one-minute BTC-USD bars with start, open, high, low and close in that order. Start is in Unix seconds. |
| `hybrid-four-quotes.csv` | The alternate execution test uses ticker, bid and ask, in ticks, from the original candidates’ four-minute checkpoints. |

From the project root, use Python 3.11+ and Node.js 22+. An isolated Python environment is recommended. The first Node command regenerates `checkpoints.csv.gz` in the input folder. Use a working copy when preserving the original snapshot.

```sh
python -m pip install -r requirements.txt
node backtest/six-minute/rebuild_chart.mjs
python backtest/six-minute/walk_forward.py
python backtest/six-minute/study.py
python backtest/six-minute/hybrid_study.py
python backtest/six-minute/hybrid_price_test.py
```

Compare the JSON outputs respectively with `walk-results.json`, `snapshot-results.json`, `hybrid-results.json` and `hybrid-price-results.json` in the same directory. Optional earlier research in `backtest/study.py` uses the separate checkpoint extract `backtest/history.json` from the source package.

## What the results measure

The archive reconstructs 126,445 checkpoints from 61 consecutive completed candles per forecast. At six minutes, 96 rounds had no verified target and 189 had missing candles. A further 142 lacked an exact-time quote and 278 had an unusable book. Missing inputs remain in coverage counts. Only matched forecasts with valid inputs enter the head-to-head comparison.

The hybrid estimates Up probability using regularized logistic regression. Its paper entry buys one contract on the favored side when forecast confidence reaches 60%, all-in cost is at most $0.90 and estimated margin is at least $0.05. The historical cost uses a quadratic fee with multiplier one and conservative whole-cent rounding. The one-cent adverse-price stress turns the monthly hybrid’s −$6.36 into −$9.46.

The four-minute alternative is a separate exploratory strategy. Among 308 of the 310 candidates with usable data, buying immediately returned −$6.64. Waiting for chart agreement and a three-cent better all-in price led to 45 entries, 23 wins and −$6.02. The two policies compete for the same candidates.

## Prospective grading

The scheduled Worker writes to a D1 binding named `DB`. The current fresh-install schema is `schema.sql`. The local VS Code runner can reconstruct elapsed chart checkpoints using the currently available candles. The hosted journal retains the original capture, source timestamps and official outcome.

Use `forward_midpoint.sql` in `backtest/six-minute/` for the separately frozen chart-versus-midpoint comparison and `hybrid_review.sql` for the hybrid. A missing six-minute book or a pending settlement stays visible in coverage. Each model is compared on the same seconds-to-close and distinct round. The locked eight-minute entry, the separate six-minute $50 experiment and the hybrid each have their own paper rules.

## November 17 tracker cleanup

Open `round_decisions` in D1 Studio for the latest chart direction, the separately locked entry, official settlement and paper P&L. Its six-minute paper columns show the independent $50 experiment. Four backing tables hold the original checkpoints, locked entries, hybrid observations and $50 paper ledger.

The capped watcher, its agreement trial and its automatic recalibration were retired from new captures. Historical rows retain their original values. Use [historical matchup](../backtest/legacy_matchup.sql) to reconstruct the old standings and [chart accuracy](../backtest/chart_accuracy.sql) for checkpoint scores. The two frozen hybrid comparisons run directly against the captured records through [hybrid review](../backtest/six-minute/hybrid_review.sql).

On an existing November 17 journal, deploy the chart-only Worker first, then apply [the cleanup migration](../migrations/2026-11-17-chart-only.sql). Then apply the [round display migration](../migrations/2026-11-17-readable-rounds.sql). A journal that already has the chart-only cleanup needs only the display migration. For a new journal, use the root schema. Earlier upgrades under `migrations/historical/` document earlier versions.
