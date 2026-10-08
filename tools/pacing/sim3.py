exec(open(__import__('os').path.join(__import__('os').path.dirname(__file__),'pacesim.py')).read().split("# A earliest")[0])
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
for l in (4,8,15,30,60,120,100000):
    metrics(f'hold {l}',follower(l))
