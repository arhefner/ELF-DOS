import os, struct, subprocess, random
os.environ['ITER']='0'
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'sim12.py')).read().split('random.seed(1)')[0])
kb = open(SC + 'kb.bin','rb').read()   # link02 -b -be -r -o kb.bin boot/krnboot.prg
# addresses below are from boot/krnboot.lst of the committed prototype -- re-read them after any krnboot change
START, END, ABSENT = 0x486b, 0x48f5, 0x46c7
SCR, P1, DATA, SHIFT, MAXC = 0x4b8d, 0x4b68, 0x4b71, 0x4b75, 0x4b7b
def run(vbr, part1):
    c = CPU(); c.m[0x4400:0x4400+len(kb)] = kb
    c.m[SCR:SCR+512] = vbr
    bps,spc,rsvd,nf,roots,tot16,media,spf = struct.unpack_from('<HBHBHHBH',vbr,11)
    if spf == 0: spf = struct.unpack_from('<I',vbr,36)[0]
    fat = part1 + rsvd; root = fat + nf*spf; data = root + (roots >> 4)   # krnboot's own steps
    for a,v in ((P1,part1),(DATA,data)):
        c.wr(a,v>>16); c.wr(a+1,v>>8); c.wr(a+2,v)
    c.wr(SHIFT, spc.bit_length()-1)
    for k in range(16): c.r[k]=random.getrandbits(16)
    c.r[2]=0x7F00; c.x=2; c.r[3]=START
    # run with END and ABSENT as return hooks that raise
    class Stop(Exception): pass
    def stop(cpu): raise Stop()
    try: c.run({END: stop, ABSENT: stop})
    except Stop: pass
    got = None if c.r[3]==ABSENT else (c.rd(MAXC)<<8)|c.rd(MAXC+1)
    tot = tot16 or struct.unpack_from('<I',vbr,32)[0]
    count = (tot - (data-part1)) // spc
    exp = None if count >= 65525 else count+1
    return got, exp
fails=0
for fat, kb_ in [(12,360),(12,720),(12,1440),(12,2880),(12,8192),(16,16384),(16,32768),(16,511744),(16,1048576),(16,2097152),(32,1048576)]:
    for part1 in (0, 2048, 0x7FFFF0):
        fimg='t.img'; os.path.exists(fimg) and os.remove(fimg)
        subprocess.run(['mkfs.fat','-F',str(fat),'-C',fimg,str(kb_)],capture_output=True,check=True)
        vbr = open(fimg,'rb').read(512)
        got, exp = run(vbr, part1)
        ok = got == exp; fails += not ok
        print(f"FAT{fat} {kb_:>8}K part1={part1:#08x}: max_clust {got} expected {exp} {'ok' if ok else 'FAIL'}")
print('failures', fails)
