"""Compare entry now to an observed four-minute executable quote for the same candidate."""
import json
from pathlib import Path
import numpy as np
import pandas as pd
from scipy.special import expit
from hybrid_study import rows,predict,root
from walk_forward import fit_chart,design,interval

def candidates():
    month=pd.to_datetime(rows.expiry,unit='s').dt.to_period('M')
    four=pd.read_csv(root/'checkpoints.csv.gz').query('minutes_left==4').merge(rows[['expiry','y']],on='expiry',validate='one_to_one')
    parts=[]
    for m in sorted(month.unique())[1:]:
        start=m.start_time.value//10**9
        six=predict(rows[rows.expiry<start-604800],rows[month==m])
        p=six.hybrid.to_numpy();up=p>=.5
        t=np.where(up,six.ask_ticks,10000-six.bid_ticks).astype(int)
        cost=((t+(7*t*(10000-t)+999999)//1000000+99)//100)/100
        conf=np.maximum(p,1-p)
        six=six.assign(up=up,cost=cost)[(conf>=.60)&(cost<=.90)&(conf+1e-12>=cost+.05)]
        if six.empty:continue
        later=four[four.expiry.isin(six.expiry)].copy()
        train=four[four.expiry<start-604800]
        later['four_up']=expit(design(later)@fit_chart(train))>=.5
        parts.append(six.merge(later[['expiry','four_up']],on='expiry',how='left')[['ticker','expiry','y','up','cost','four_up']])
    return pd.concat(parts)
def analyze(c,price):
    q=c.merge(price,on='ticker',how='left',validate='one_to_one')
    valid=q.bid.gt(0)&q.ask.lt(10000)&q.bid.le(q.ask)&q.four_up.notna()
    d=q[valid].copy();t=np.where(d.up,d.ask,10000-d.bid).astype(int)
    cost=((t+(7*t*(10000-t)+999999)//1000000+99)//100)/100
    enter=(d.up==d.four_up)&(cost<=d.cost-.03+1e-12)
    hit=(d.up==d.y)
    delayed=np.where(enter,hit.astype(float)-cost,0)
    immediate=hit.astype(float)-d.cost
    # Resample complete UTC days to avoid treating clustered candidates as independent.
    paired_interval=interval(delayed-immediate,d.expiry.to_numpy()) if len(d) else None
    recent=d.expiry>=1789059600
    late={'candidates':int(recent.sum()),'entries':int((enter&recent).sum()),
          'wins':int(hit[enter&recent].sum()),'net':round(float(delayed[recent].sum()),4)}
    return {'paired_pnl_difference_per_candidate_95':paired_interval,'later_fifth_monthly_forecasts':late,
            'candidates':len(c),'priced_with_chart':len(d),'immediate_net_same_rows':round(float((hit-d.cost).sum()),4),
            'alternative_entries':int(enter.sum()),'alternative_wins':int(hit[enter].sum()),
            'alternative_net':round(float((hit[enter]-cost[enter]).sum()),4),
            'alternative_one_cent_worse':round(float((hit[enter]-cost[enter]-.01).sum()),4),
            'distinct_entry_days':int((d.expiry[enter]//86400).nunique())}
if __name__=='__main__':
    print(json.dumps(analyze(candidates(),pd.read_csv(root/'hybrid-four-quotes.csv')),indent=2))
