import json
from pathlib import Path
from collections import defaultdict
import numpy as np
from scipy.special import expit,logit
from scipy.optimize import minimize

rows=sorted(json.loads(Path(__file__).with_name('history.json').read_text()),key=lambda r:(r['expiry'],-r['left']))
rounds=defaultdict(list)
for r in rows:
    prev=rounds[r['tick']]
    scale=4*np.sqrt(r['left']-.5)
    gap=np.clip(10000*(r['btc']/r['target']-1)/scale,-5,5)
    move=np.clip(10000*(r['btc']/prev[-1]['btc']-1)/(4*np.sqrt(prev[-1]['left']-r['left'])),-5,5) if prev else 0
    r['x']=np.array([logit(np.clip(r['price'],1e-6,1-1e-6)),gap,move])
    prev.append(r)

def fit(rr,n):
    prior=np.zeros(n);prior[0]=1
    X=np.array([r['x'][:n] for r in rr]);y=np.array([r['y'] for r in rr]);w=np.array([1/len(rounds[r['tick']]) for r in rr])
    def loss(b):
        z=X@b
        return w@(np.logaddexp(0,z)-y*z)+10*np.sum((b-prior)**2),X.T@(w*(expit(z)-y))+20*(b-prior)
    res=minimize(loss,prior,jac=True,method='L-BFGS-B');assert res.success
    return res.x
def ev(rr,b):
    y=np.array([r['y'] for r in rr]);p=np.array([expit(r['x'][:len(b)]@b) for r in rr])
    return [int(sum((p>=.5)==y)),len(rr),round(float(np.mean((p-y)**2)),6)]
fitrounds=[g for g in rounds.values() if g[0]['split']=='fit']
test=[r for r in rows if r['split']=='test']
assert max(g[0]['expiry'] for g in fitrounds)<min(r['expiry'] for r in test)
candidates=[0,2,3];cv={}
for n in candidates:
    metrics=[]
    for start in [112,168,224,280]:
        tr=[r for g in fitrounds[:start] for r in g];val=[r for g in fitrounds[start:start+56] for r in g if r['left']==8]
        b=fit(tr,n) if n else [1.]
        metrics.append(ev(val,b))
    cv[n]=[sum(m[0] for m in metrics),np.average([m[2] for m in metrics],weights=[m[1] for m in metrics])]
best=max(candidates,key=lambda n:(cv[n][0],-cv[n][1]))
if cv[best][1]>cv[0][1]:best=0
b=fit([r for g in fitrounds for r in g],best) if best else [1.]
b=np.round(b,9)
print('cv',cv,'selected',best,'weights',b)

o={}
for m in [10,8,6,4]:
    group=[r for r in test if r['left']==m];print(m,ev(group,b),ev(group,[1]),'spot',sum(int((r['btc']>=r['target'])==r['y']) for r in group))
    o[m]=ev(group,b)
# One call in each round, first available of 8,6,4. Only price when that side has an ask.
chosen=[next((r for r in g if r['left'] in (8,6,4)),None) for g in rounds.values() if g[0]['split']=='test'];chosen=[r for r in chosen if r]
priced=[];sides=defaultdict(lambda:[0,0])
for r in chosen:
    up=r['x'][:len(b)]@b>=0;y=r['y'];hit=int(up==y)
    ask=r['up' if up else 'down']
    if ask is not None: priced.append((hit,ask))
    s=sides['up' if up else 'down'];s[0]+=hit;s[1]+=1
gross=sum(hit-ask for hit,ask in priced)
summary=dict(minutes=o,round_decisions=ev(chosen,b),baseline_correct=sum(int((r['btc']>=r['target'])==r['y']) for r in chosen),sides=dict(sides),quoted=len(priced),gross=round(gross,4),wins=sum(p[0] for p in priced),fit_rounds=len(fitrounds),tested_rounds=len(chosen),cutoff=min(r['expiry'] for r in test))
print(summary)

