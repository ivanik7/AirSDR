import sys
def tr(p):
    st={};out=[]
    for l in open(p):
        f=l.split(' ',2); 
        if st.get(f[1])!=l: st[f[1]]=l; out.append(l.strip())
    return out
def fr(p):
    b=open(p,'rb').read(); return [b[i:i+9] for i in range(0,len(b),9)]
tx=fr('tx_ts1.ambe')+fr('tx_ts2.ambe')
for t in sys.argv[1:]:
    o,n=fr('o_'+t+'.ambe'),fr('n_'+t+'.ambe')
    print(t,'meta_transitions_equal',tr('o_'+t+'.meta')==tr('n_'+t+'.meta'),'frames o/n',len(o),len(n),'equal',sum(a==b for a,b in zip(o,n)),'o_in_tx',sum(x in tx for x in o),'n_in_tx',sum(x in tx for x in n))
