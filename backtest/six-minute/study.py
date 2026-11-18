"""Replay six-minute forecasts at archive quotes under the fixed $50 paper policy."""
import json, sys, math
from pathlib import Path
import numpy as np, pandas as pd
from scipy.special import expit
def calculate(rows,prob,scope):
    y=rows.y.to_numpy()
    up=prob>=.5
    hit=(up==y)
    bid=rows.bid_ticks.to_numpy(dtype=int);ask=rows.ask_ticks.to_numpy(dtype=int)
    ticks=np.where(up,ask,10000-bid)
    conf=np.maximum(prob,1-prob);mid=(bid+ask)/20000
    blend=(conf+np.where(up,mid,1-mid))/2
    nfee=(7*ticks*(10000-ticks)+999999)//1000000
    cost=((ticks+nfee+99)//100)/100.0
    masks={'all':np.ones(len(rows),dtype=bool),'cap_only':cost<=.5,'frozen_trial':(cost<=.5)&(blend+1e-12>=cost+.05)}
    result={}
    for name,mask in masks.items():
        v=hit[mask].astype(float)-cost[mask]
        balance=50.;peak=50.;dd=0;trades=0;wins=0
        for h,c in zip(hit[mask],cost[mask]):
            if balance+1e-12<c:continue
            balance=round(balance+int(h)-c,4);peak=max(peak,balance);dd=max(dd,peak-balance);trades+=1;wins+=int(h)
        daily=pd.DataFrame({'day':rows.expiry.to_numpy()[mask]//86400,'v':v}).groupby('day').v.sum()
        result[name]=dict(entries=int(mask.sum()),wins=int(hit[mask].sum()),days=int(len(daily)),gross=round(float(np.sum(hit[mask].astype(float)-ticks[mask]/10000)),4),net=round(float(v.sum()),4),balance=round(balance,4),funded_trades=trades,max_drawdown=round(dd,4),one_cent_worse=round(float(v.sum()-.01*mask.sum()),4))
    return dict(scope=scope,rounds=len(rows),from_expiry=int(rows.expiry.min()),to_expiry=int(rows.expiry.max()),results=result)
def study(filename):
    allrows=pd.read_csv(filename).sort_values('expiry');chart=allrows[allrows.p_up.notna()].copy()
    paired=chart[chart.status=='paired'].copy()
    assert paired.ticker.is_unique and paired.expiry.is_unique and np.all((paired.p_up>=0)&(paired.p_up<=1))
    # Replicate the incumbent probabilities from the independent archived feature computation.
    features=['x_strike','x_open','x_momentum']
    beta=np.array([-.10536618028479769,.5217297593621257,1.0631894272600717,.01319105439953532])
    def matrix(rows):return np.column_stack([np.ones(len(rows)),rows[features].to_numpy()])
    assert np.max(np.abs(expit(matrix(chart)@beta)-chart.p_up))<1e-10
    # Define the last fifth by all listed round times, before filtering missing quotes or targets.
    # Freeze the original November 16 comparison. New archival inputs may add rows.
    cutoff=1789059600
    beta_hold=np.array([0.08049957019678873, 0.9088464119646227, 1.0454511824529507, -0.030266438185864476])
    hold=paired[paired.expiry>=cutoff]
    # The currently deployed chart fit used rounds closing no later than Nov 9 02:30 UTC.
    exact=paired[paired.expiry>1794191400]
    assert len(hold)>0 and len(exact)>0
    res=[calculate(paired,paired.p_up.to_numpy(),'Retrospective fixed Worker'),calculate(hold,expit(matrix(hold)@beta_hold),'Chronological last fifth, earlier chart fit'),calculate(exact,exact.p_up.to_numpy(),'After original chart fitting, exact Worker')]
    counts=allrows.status.value_counts().to_dict()
    return dict(universe=len(allrows),chart_valid=len(chart),paired=len(paired),chart_correct=int(((chart.p_up>=.5)==chart.y).sum()),coverage=counts,fit_n=24322,embargo_days=7,cutoff=cutoff,holdout_weights=beta_hold.tolist(),comparisons=res)
if __name__=='__main__':
    result=study(sys.argv[1] if len(sys.argv)>1 else Path(__file__).with_name('replay.csv.gz'));print(json.dumps(result,indent=2))
