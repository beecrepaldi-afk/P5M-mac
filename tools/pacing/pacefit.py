import argparse, csv, math
from pathlib import Path
parser = argparse.ArgumentParser(description="Analyze a pacing trace without accessing account settings")
parser.add_argument("trace", type=Path, help="Pacing CSV file to analyze")
args = parser.parse_args()
t = args.trace
rows=[]
for r in csv.DictReader(open(t)):
    try: r={k:float(v) for k,v in r.items()}
    except: continue
    if r['arrival']>0: rows.append(r)
rows=rows[1000:]
g=[r['flip']-r['phase'] for r in rows]
P0=0.016667
k=[round((x-g[0])/P0) for x in g]
n=len(g); mk=sum(k)/n; mg=sum(g)/n
P=sum((a-mk)*(b-mg) for a,b in zip(k,g))/sum((a-mk)**2 for a in k)
res=[b-(g[0]+a*P) for a,b in zip(k,g)]
print('grid period fit %.5f ms, residual range %.3f..%.3f ms'%(P*1000,min(res)*1000,max(res)*1000))
print('measured period field median %.5f'%(sorted(r['period'] for r in rows)[n//2]*1000))
A=[r['arrival'] for r in rows]
print('ps5 frame period %.5f ms (frames %d over %.1f s)'%((A[-1]-A[0])/(n-1)*1000,n,A[-1]-A[0]))
