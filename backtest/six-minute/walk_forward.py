"""Score the archived BTC model and a monthly expanding-window refit at all checkpoints."""
import json
from pathlib import Path
import numpy as np
import pandas as pd
from scipy.optimize import minimize
from scipy.special import expit

ROOT=Path(__file__).resolve().parent
FEATURES=['strike_gap','opening_move','momentum']
def score(p,y):
    return {'correct':int(np.sum((p>=.5)==y)),'rounds':int(len(y)),
            'brier':round(float(np.mean((p-y)**2)),6)}
def design(frame):
    return np.column_stack([np.ones(len(frame)),frame[FEATURES]])
def fit_chart(frame):
    X=design(frame); y=frame.y.to_numpy()
    def loss(beta):
        logits=X@beta
        return (np.sum(np.logaddexp(0,logits)-y*logits)+2.5*(beta@beta),
                X.T@(expit(logits)-y)+5*beta)
    fitted=minimize(loss,np.zeros(4),jac=True,method='L-BFGS-B')
    if not fitted.success:raise RuntimeError(fitted.message)
    return fitted.x
def interval(delta,expiry):
    daily=pd.DataFrame({'d':delta,'day':expiry//86400}).groupby('day').d.agg(['sum','count']).to_numpy()
    rng=np.random.default_rng(20261116)
    draw=daily[rng.integers(0,len(daily),size=(3000,len(daily)))].sum(axis=1)
    return [round(float(v),6) for v in np.quantile(draw[:,0]/draw[:,1],[.025,.975])]
def run(folder=ROOT):
    roster=pd.read_csv(folder/'replay.csv.gz')
    panel=pd.read_csv(folder/'checkpoints.csv.gz')
    assert roster.expiry.is_unique and roster.ticker.is_unique and roster.y.isin([0,1]).all()
    assert not panel.duplicated(['expiry','minutes_left']).any()
    panel=panel.merge(roster[['expiry','y','bid_ticks','ask_ticks','status']],on='expiry',validate='many_to_one')
    assert panel.chart_up.between(0,1).all()
    # The first partial calendar month seeds the January fit. Every later month is forecast once.
    panel['month']=pd.to_datetime(panel.expiry,unit='s').dt.to_period('M')
    whole={}; walk={}; folds=[]; six=[]
    for left in [10,8,6,4]:
        frame=panel[panel.minutes_left==left].copy()
        whole[left]=score(frame.chart_up.to_numpy(),frame.y.to_numpy())
        outputs=[]
        for month in sorted(frame.month.unique())[1:]:
            cutoff=month.start_time.value//10**9-7*86400
            train=frame[frame.expiry<cutoff]
            test=frame[frame.month==month].copy()
            assert len(train)>0 and train.expiry.max()+7*86400<test.expiry.min()
            beta=fit_chart(train)
            test['forward_up']=expit(design(test)@beta)
            outputs.append(test)
            folds.append({'month':str(month),'minutes_left':left,'trained_on':len(train),
                          **score(test.forward_up.to_numpy(),test.y.to_numpy())})
        out=pd.concat(outputs);walk[left]=score(out.forward_up.to_numpy(),out.y.to_numpy())
        if left==6:six=out[out.status=='paired'].copy()
    book=(six.bid_ticks.to_numpy()+six.ask_ticks.to_numpy())/20000
    chart=six.forward_up.to_numpy();y=six.y.to_numpy();blend=(chart+book)/2
    brier_delta=(book-y)**2-(chart-y)**2
    assert six.expiry.is_unique and len(six)>0
    # Fixed chart side and paper filter. Simulated costs conservatively round up to one cent.
    up=chart>=.5;ticks=np.where(up,six.ask_ticks.to_numpy(),10000-six.bid_ticks.to_numpy()).astype(int)
    fee_ticks=(7*ticks*(10000-ticks)+999999)//1000000
    cash_cents=(ticks+fee_ticks+99)//100
    qualifies=(cash_cents<=50)&(np.where(up,blend,1-blend)+1e-12>=cash_cents/100+.05)
    hit=up==y
    paper={'entries':int(qualifies.sum()),'wins':int(hit[qualifies].sum()),
           'gross':round(float(np.sum(hit[qualifies]-ticks[qualifies]/10000)),4),
           'net':round(float(np.sum(hit[qualifies]-cash_cents[qualifies]/100)),4)}
    return {'archive_distinct_rounds':len(roster),'eligible_distinct_rounds':int(panel.expiry.nunique()),
            'eligible_checkpoints':len(panel),'worker_all':whole,'monthly_forward_chart':walk,
            'monthly_forward_distinct_rounds':int(panel[panel.month>panel.month.min()].expiry.nunique()),
            'six_minute_priced_monthly':{'chart':score(chart,y),'midpoint':score(book,y),'even_blend':score(blend,y),
            'midpoint_minus_chart_brier':round(float(brier_delta.mean()),6),
            'paired_day_bootstrap_95pct':interval(brier_delta,six.expiry.to_numpy()),'paper':paper},
            'folds':folds}
if __name__=='__main__':print(json.dumps(run(),indent=2))
