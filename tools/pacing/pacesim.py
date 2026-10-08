import argparse, csv, math
from pathlib import Path
parser = argparse.ArgumentParser(description="Analyze a pacing trace without accessing account settings")
parser.add_argument("trace", type=Path, help="Pacing CSV file to analyze")
parser.add_argument("--processing-ms", type=float, default=3.6, help="Simulated decode time (default: 3.6 ms)")
args = parser.parse_args()
t = args.trace
rows=[]
for r in csv.DictReader(open(t)):
    try: r={k:float(v) for k,v in r.items()}
    except: continue
    if r['arrival']<=0: continue
    rows.append(r)
rows=rows[1000:]  # skip startup
g=[r['flip']-r['phase'] for r in rows]
k=[round((x-g[0])/0.016667) for x in g]
n=len(g); mk=sum(k)/n; mg=sum(g)/n
P=sum((a-mk)*(b-mg) for a,b in zip(k,g))/sum((a-mk)**2 for a in k)
anchor=mg-mk*P
PROC=args.processing_ms / 1000.0
Lat=0.0031
def deadline_after(t,late_ok=0.0002):
    k=math.ceil((t-late_ok-anchor)/P); return anchor+k*P
def phase(t):
    ph=(t-anchor)%P; return ph-P if ph>=P/2 else ph
E=[r['arrival']+PROC+Lat for r in rows]   # earliest flip
A=[r['arrival'] for r in rows]
def metrics(name,slots):
    lat=[s-a for s,a in zip(slots,A)]
    drops=sum(1 for i in range(1,len(slots)) if slots[i]-slots[i-1]<P/2)
    rep=sum(max(0,round((slots[i]-slots[i-1])/P)-1) for i in range(1,len(slots)) if slots[i]-slots[i-1]<0.2)
    mins=(A[-1]-A[0])/60
    lat.sort()
    print(f"{name:28s} arrival->flip avg {sum(lat)/len(lat)*1000:5.1f} ms p95 {lat[int(.95*len(lat))]*1000:5.1f} | drops {drops/mins/6:5.1f}/10s repeats {rep/mins/6:5.1f}/10s")
# A earliest
metrics('earliest (original, no hold)',[deadline_after(e) for e in E])
# hold follower (original with hold limit)
def follower(limit):
    out=[];last=0;run=0
    for e in E:
        s=deadline_after(e)
        if last and s-last<0.5:
            nxt=last+P
            if s<nxt-P/2:
                run+=1
                if run<=limit: s=nxt
                else: run=0
            else: run=0
        out.append(s);last=s
    return out
metrics('original hold 4 (remote)',follower(4))
metrics('original hold 30',follower(30))
# fixed extra delay D
for D in (0.002,0.004,0.006,0.008):
    metrics(f'fixed +{D*1000:.0f} ms',[deadline_after(e+D) for e in E])
# percentile clock
def pclock_policy(pct,cap=True):
    out=[];pc=0;ring=[];bt=0;n=0;last=0
    for e in E:
        if pc<=0 or e-pc>0.25 or pc-e>2*P: pc=e
        else:
            nx=pc+P+0.00002
            if cap and e-nx>P/2: nx+=P*math.floor((e-nx)/P+0.5)
            pc=min(nx,e)
        ring.append(e-pc); ring=ring[-600:]; n+=1
        if n%30==0:
            s=sorted(ring); w=s[int(pct*(len(s)-1))]+0.0005
            if w>bt or bt-w>=0.001: bt=w
        out.append(deadline_after(max(e,pc+bt)))
    return out
for pct in (0.9,0.95,0.98,0.995):
    metrics(f'percentile clock {pct}',pclock_policy(pct))
print('--- lateness vs envelope clock')
pc=0;late=[]
for e in E:
    if pc<=0 or e-pc>0.25: pc=e
    else:
        nx=pc+P+0.00002
        if e-nx>P/2: nx+=P*math.floor((e-nx)/P+0.5)
        pc=min(nx,e)
    late.append(e-pc)
s=sorted(late); print('lateness ms p50,80,90,95,98,99,99.5', [round(s[int(p*(len(s)-1))]*1000,2) for p in (.5,.8,.9,.95,.98,.99,.995)])
def fixedbuf(B):
    out=[];pc=0
    for e in E:
        if pc<=0 or e-pc>0.25: pc=e
        else:
            nx=pc+P+0.00002
            if e-nx>P/2: nx+=P*math.floor((e-nx)/P+0.5)
            pc=min(nx,e)
        out.append(deadline_after(max(e,pc+B)))
    return out
for B in (0.002,0.004,0.006,0.008,0.010,0.012,0.016):
    metrics(f'envelope clock + {B*1000:.0f} ms',fixedbuf(B))
print('--- arrival intervals')
ia=[A[i]-A[i-1] for i in range(1,len(A))]
mins=(A[-1]-A[0])/60
for lo,hi in ((0,0.004),(0.004,0.008),(0.008,0.025),(0.025,0.04),(0.04,1)):
    print(f'{lo*1000:4.0f}-{hi*1000:4.0f} ms: {sum(1 for x in ia if lo<=x<hi)/mins/6:6.1f}/10s')
# is a long gap followed by a short one (late frame) or not (missing frame)?
late=sum(1 for i in range(1,len(ia)) if ia[i-1]>0.025 and ia[i]<0.008)
miss=sum(1 for i in range(1,len(ia)) if ia[i-1]>0.025 and ia[i]>=0.008)
print('long gap then bunched (a late frame): %.1f/10s, long gap not followed by bunch (missing frame): %.1f/10s'%(late/mins/6,miss/mins/6))
