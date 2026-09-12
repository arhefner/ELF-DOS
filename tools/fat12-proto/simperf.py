import os, random
os.environ['ITER']='0'
src=open('sim12.py').read().split('random.seed(1)')[0]
exec(src)
calls = {'n':0}
def count_run(fat16, entry, cl, v, warm):
    c = CPU(); w = World()
    c.wr(syms['bpb_fat16'], fat16)
    idx = (cl >> 8) if fat16 else (cl + cl//2) >> 9
    c.wr(syms['fat_csec'], 0); c.wr(syms['fat_csec']+1, idx if warm else 0x7F); c.wr(syms['fat_dirty'], 0)
    c.m[syms['fat_cache']:syms['fat_cache']+512] = w.disk[idx]
    calls['n']=0
    h = mk_hook(w)
    def hook(cpu): calls['n']+=1; h(cpu)
    for k in range(16): c.r[k]=random.getrandbits(16)
    c.r[2]=0x7F00; c.x=2; c.r[13]=cl; c.r[11]=v; c.steps=0
    c.r[6]=SENT; c.push16(0); c.r[3]=entry
    c.run({syms['_fat_load_sector']: hook})
    return c.steps, calls['n'], w.reads, w.writes
for name, f16 in (('FAT16',1),('FAT12',0)):
    for cl,label in ((100,'normal'),(341 if not f16 else 100,'straddle')):
        if f16 and label=='straddle': continue
        g = count_run(f16, syms['fat_get'], cl, 0, True)
        s = count_run(f16, syms['fat_set'], cl, 0x0123, True)
        print(f"{name} {label:8}: fat_get {g[0]:3} instr, {g[1]} load call(s), {g[2]} read(s) | fat_set {s[0]:3} instr, {s[1]} load call(s), {s[2]} read(s)")

print("--- warm cache, real _fat_load_sector (no mock), counting SCRT calls")
def real_run(fat16, entry, cl, v):
    c = CPU(); c.wr(syms['bpb_fat16'], fat16)
    idx = (cl >> 8) if fat16 else (cl + cl//2) >> 9
    c.wr(syms['fat_csec'], 0); c.wr(syms['fat_csec']+1, idx); c.wr(syms['fat_dirty'], 0)
    for k in range(16): c.r[k]=random.getrandbits(16)
    c.r[2]=0x7F00; c.x=2; c.r[13]=cl; c.r[11]=v; c.steps=0
    c.r[6]=SENT; c.push16(0); c.r[3]=entry
    ncall = [0]
    orig = c.fetch
    c.run({})
    return c.steps
for name, f16 in (('FAT16',1),('FAT12',0)):
    g = real_run(f16, syms['fat_get'], 100, 0); s = real_run(f16, syms['fat_set'], 100, 0x123)
    print(f"{name}: fat_get {g} instr, fat_set {s} instr (SCRT call/return counted as 1 each)")
