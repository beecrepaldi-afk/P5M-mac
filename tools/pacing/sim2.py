exec(open(__import__('os').path.join(__import__('os').path.dirname(__file__),'pacesim.py')).read().split("# A earliest")[0])
def clock_policy(B=None,pct=None,creep=0.000002,ps5=None,shrink_s=10):
    out=[];pc=0;per=ps5 or P;ring=[];bt=B or 0;n=0
    for i,e in enumerate(E):
        if i and 0.008<A[i]-A[i-1]<0.025 and ps5 is None:
            per+= (A[i]-A[i-1]-per)*0.002
        if pc<=0 or e-pc>0.25: pc=e
        else:
            nx=pc+per+creep
            if e-nx>per/2: nx+=per*math.floor((e-nx)/per+0.5)
            pc=min(nx,e)
        if pct is not None:
            ring.append(e-pc); ring=ring[-int(60*shrink_s):]; n+=1
            if n%30==0:
                s=sorted(ring); w=s[int(pct*(len(s)-1))]+0.0005
                if w>bt or bt-w>=0.001: bt=w
        out.append(deadline_after(max(e,pc+bt)))
    return out
metrics('earliest',[deadline_after(e) for e in E])
for B in (0.004,0.006,0.008,0.010):
    metrics(f'ps5-rate clock +{B*1000:.0f}',clock_policy(B=B))
for pct in (0.9,0.95,0.98,0.99):
    metrics(f'ps5-rate clock p{pct}',clock_policy(pct=pct))
