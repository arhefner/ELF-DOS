import os, random
os.environ['ITER']='0'
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'sim12.py')).read().split('random.seed(1)')[0])
BPBBLK_MAX_CLUST=19; BPBBLK_LEN=22
fails=0
for mc in [0x0000,0x0002,0x0B00,0x0FF4,0x0FF5,0x0FF6,0x0FF7,0x1000,0x10F5,0xFFF5,0xFFFF]:
  for target in (1,5):
    c=CPU()
    c.wr(syms['drive_present']+target,1); c.wr(syms['active_bpb_drive'],0)
    e=syms['drive_bpb_table']+target*BPBBLK_LEN+BPBBLK_MAX_CLUST
    c.wr(e,mc>>8); c.wr(e+1,mc&0xFF)
    c.wr(syms['bpb_fat16'], random.getrandbits(8))
    for k in range(16): c.r[k]=random.getrandbits(16)
    c.r[2]=0x7F00; c.x=2; c.r[6]=SENT; c.push16(0); c.r[3]=syms['_switch_drive']; c.d=target
    c.run({syms['fat_flush']: lambda cpu: setattr(cpu,'df',0)})
    got=c.rd(syms['bpb_fat16']); exp=0 if mc<0x0FF6 else 1
    ok = got==exp and c.df==0 and c.rd(syms['bpb_max_clust'])==mc>>8
    if not ok: fails+=1
    print('max_clust=%04x drive=%d  bpb_fat16=%d (expect %d) %s'%(mc,target,got,exp,'ok' if ok else 'FAIL'))
print('failures',fails)
