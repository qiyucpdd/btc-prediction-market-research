"""Six-minute hybrid v1. Fixed design and entry rule; one expiry per row."""
import json
from pathlib import Path
import numpy as np
import pandas as pd
from scipy.optimize import minimize
from scipy.special import expit, logit
from walk_forward import interval, score, fit_chart, design

root=Path(__file__).resolve().parent
roster=pd.read_csv(root/'replay.csv.gz').query("status=='paired'").sort_values('expiry')
panel=pd.read_csv(root/'checkpoints.csv.gz').query('minutes_left==6')
rows=roster.merge(panel,on='expiry',validate='one_to_one').sort_values('expiry')
assert len(rows)==len(roster) and rows.expiry.is_unique
def features(f):
    mid=(f.bid_ticks+f.ask_ticks)/20000
    # Bounded chart transforms reduce the influence of extreme moves. The book's weight may vary with spread.
    market=np.clip(logit(mid),-6,6)
    spread=np.minimum((f.ask_ticks-f.bid_ticks)/1000,1)
    return np.column_stack([np.ones(len(f)),market,np.arcsinh(f.strike_gap),np.arcsinh(f.opening_move),
                            np.arcsinh(f.momentum),market*spread])
def fit(f):
    x=features(f);y=f.y.to_numpy()
    prior=np.array([0,1,0,0,0,0])
    def loss(b):
        z=x@b;d=b-prior
        return np.sum(np.logaddexp(0,z)-y*z)+5*(d@d), x.T@(expit(z)-y)+10*d
    res=minimize(loss,prior.astype(float),jac=True,method='L-BFGS-B')
    assert res.success
    return res.x
def paper(f,p):
    up=p>=.5
    t=np.where(up,f.ask_ticks,10000-f.bid_ticks).astype(int)
    cost=((t+(7*t*(10000-t)+999999)//1000000+99)//100)/100
    confidence=np.maximum(p,1-p)
    trade=(confidence>=.60)&(cost<=.90)&(confidence+1e-12>=cost+.05)
    hits=(up==f.y.to_numpy())[trade]
    pnl=hits.astype(float)-cost[trade]
    # Independent $100 account, fixed maximum $20 debit including the fee for the entire order.
    cash=10000
    funded=0
    funded_wins=0
    for tick,win in zip(t[trade],hits):
        if cash<2000:break
        def debit(size):
            fee_ticks=(7*size*tick*(10000-tick)+999999)//1000000
            return (size*tick+fee_ticks+99)//100
        size=200000//tick
        while debit(size)>2000:size-=1
        cash+=100*size*int(win)-debit(size)
        funded+=1
        funded_wins+=int(win)
    return dict(entries=int(trade.sum()),wins=int(hits.sum()),days=int((f.expiry[trade]//86400).nunique()),
                fixed_20_budget={'starting_balance':100,'ending_balance':float(cash/100),'funded':funded,'wins':funded_wins},
                gross=round(float((hits-t[trade]/10000).sum()),4),net=round(float(pnl.sum()),4),
                worse_cent=round(float(pnl.sum()-.01*len(pnl)),4))
def evaluate(f):
    y=f.y.to_numpy(); probs={k:f[k].to_numpy() for k in ['hybrid','chart','book','incumbent']}
    hit=(probs['hybrid']>=.5)==y
    disagreements={}
    for name in ['chart','incumbent','book']:
        other=(probs[name]>=.5)==y
        disagreements[name]=dict(helped=int((hit&~other).sum()),hurt=int((~hit&other).sum()),
            accuracy_difference_95=interval(hit.astype(int)-other.astype(int),f.expiry.to_numpy()))
    return {'rounds':len(f),'paired_changes':disagreements,'scores':{k:score(p,y) for k,p in probs.items()},
            'entries_same_rule':{k:paper(f,p) for k,p in probs.items()},
            'hybrid_minus_book_brier_95':interval((probs['hybrid']-y)**2-(probs['book']-y)**2,f.expiry.to_numpy())}
def predict(train,test):
    t=test.copy()
    t['hybrid']=expit(features(t)@fit(train))
    t['chart']=expit(design(t)@fit_chart(train))
    t['book']=(t.bid_ticks+t.ask_ticks)/20000
    t['incumbent']=t.chart_up
    return t
def run():
    month=pd.to_datetime(rows.expiry,unit='s').dt.to_period('M')
    blocks=[]
    for m in sorted(month.unique())[1:]:
        boundary=m.start_time.value//10**9
        blocks.append(predict(rows[rows.expiry<boundary-604800],rows[month==m]))
    test_start=1789059600
    held=predict(rows[rows.expiry<test_start-604800],rows[rows.expiry>=test_start])
    return {'monthly':evaluate(pd.concat(blocks)),'later_fifth':evaluate(held),
            'monthly_breakdown':[{'first_expiry':int(f.expiry.min()),'scores':{name:score(f[name].to_numpy(),f.y.to_numpy()) for name in ['chart','incumbent','hybrid','book']},'entries':paper(f,f.hybrid.to_numpy())} for f in blocks],
            'frozen_weights':fit(rows).tolist(),'last_training_expiry':int(rows.expiry.max()),'training_rounds':len(rows)}
if __name__=='__main__':print(json.dumps(run(),indent=2))
