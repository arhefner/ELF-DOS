#!/usr/bin/env python3
# Instruction-level 1802 simulator: runs the REAL linked fat_get/fat_set
# bytes from kernel.bin against a reference FAT12 model. Only
# _fat_load_sector is mocked (disk + one-sector cache, flush on evict).
import random, re, sys

import os
SC = os.environ.get('KDIR', os.getcwd()) + '/'   # repo root: kernel.bin + syms.txt
syms = {}
for l in open(SC + 'syms.txt'):
    m = re.match(r'^(\S+)\s+([0-9a-f]{4})$', l.strip())
    if m: syms[m.group(1)] = int(m.group(2), 16)

img = bytearray(open(SC + 'kernel.bin', 'rb').read())
import os
for p in filter(None, os.environ.get('PATCH','').split(',')):
    a, v = p.split('='); img[int(a,16)-0x100] = int(v,16)
ITER = int(os.environ.get('ITER','60000'))

NSEC = 12                      # FAT sectors on the model disk
SENT = 0xFFF0                  # return sentinel

class CPU:
    def __init__(self):
        self.m = bytearray(65536)
        self.m[0x100:0x100 + len(img)] = img
        self.r = [0] * 16
        self.d = 0; self.df = 0; self.x = 2; self.p = 3
        self.steps = 0
    def rd(self, a): return self.m[a & 0xFFFF]
    def wr(self, a, v): self.m[a & 0xFFFF] = v & 0xFF
    def fetch(self):
        v = self.m[self.r[self.p]]; self.r[self.p] = (self.r[self.p] + 1) & 0xFFFF; return v
    def push16(self, v):       # SCRT: stxd lo, stxd hi
        self.wr(self.r[2], v & 0xFF); self.r[2] -= 1
        self.wr(self.r[2], v >> 8); self.r[2] -= 1
    def pop16(self):
        self.r[2] += 1; hi = self.rd(self.r[2]); self.r[2] += 1; lo = self.rd(self.r[2])
        return (hi << 8) | lo

    def run(self, hooks):
        while True:
            pc = self.r[3]
            if pc == SENT: return
            if pc in hooks:
                hooks[pc](self)
                self.r[3] = self.r[6]; self.r[6] = self.pop16()   # rtn
                continue
            self.steps += 1
            if self.steps > 200000: raise RuntimeError('runaway')
            op = self.fetch(); i = op >> 4; n = op & 15; R = self.r; M = lambda: self.rd(R[self.x])
            if i == 0:
                if n == 0: raise RuntimeError('IDL at %04x' % pc)
                self.d = self.rd(R[n])
            elif i == 1: R[n] = (R[n] + 1) & 0xFFFF
            elif i == 2: R[n] = (R[n] - 1) & 0xFFFF
            elif i == 3:
                t = self.fetch(); a = (pc + 1) & 0xFF00 | t
                c = {0: 1, 2: self.d == 0, 3: self.df == 1, 10: self.d != 0, 11: self.df == 0}.get(n)
                if c is None: raise RuntimeError('short op %02x' % op)
                if c: R[3] = a
            elif i == 4: self.d = self.rd(R[n]); R[n] = (R[n] + 1) & 0xFFFF
            elif i == 5: self.wr(R[n], self.d)
            elif op == 0x60: R[self.x] = (R[self.x] + 1) & 0xFFFF
            elif op == 0x72: self.d = M(); R[self.x] = (R[self.x] + 1) & 0xFFFF
            elif op == 0x73: self.wr(R[self.x], self.d); R[self.x] = (R[self.x] - 1) & 0xFFFF
            elif op in (0x74, 0x7C):
                v = self.fetch() if op == 0x7C else M()
                s = self.d + v + self.df; self.d = s & 0xFF; self.df = s >> 8
            elif op in (0x77, 0x7F):
                v = self.fetch() if op == 0x7F else M()
                s = self.d - v - (1 - self.df); self.df = 1 if s >= 0 else 0; self.d = s & 0xFF
            elif op == 0x76: nd = self.d & 1; self.d = (self.d >> 1) | (self.df << 7); self.df = nd
            elif op == 0x7E: nd = self.d >> 7; self.d = ((self.d << 1) | self.df) & 0xFF; self.df = nd
            elif i == 8: self.d = R[n] & 0xFF
            elif i == 9: self.d = R[n] >> 8
            elif i == 10: R[n] = (R[n] & 0xFF00) | self.d
            elif i == 11: R[n] = (R[n] & 0xFF) | (self.d << 8)
            elif i == 12:
                hi = self.fetch(); lo = self.fetch(); a = (hi << 8) | lo
                c = {0: 1, 2: self.d == 0, 3: self.df == 1, 10: self.d != 0, 11: self.df == 0}.get(n)
                if c is None: raise RuntimeError('long op %02x at %04x' % (op, pc))
                if c: R[3] = a
            elif op == 0xD4:          # SCRT call
                hi = self.fetch(); lo = self.fetch()
                self.push16(R[6]); R[6] = R[3]; R[3] = (hi << 8) | lo
            elif op == 0xD5:          # SCRT return
                R[3] = R[6]; R[6] = self.pop16()
            elif op == 0xF0: self.d = M()
            elif op == 0xF1: self.d |= M()
            elif op == 0xF2: self.d &= M()
            elif op == 0xF3: self.d ^= M()
            elif op in (0xF4, 0xFC):
                v = self.fetch() if op == 0xFC else M()
                s = self.d + v; self.d = s & 0xFF; self.df = s >> 8
            elif op in (0xF7, 0xFF):
                v = self.fetch() if op == 0xFF else M()
                s = self.d - v; self.df = 1 if s >= 0 else 0; self.d = s & 0xFF
            elif op == 0xF6: self.df = self.d & 1; self.d >>= 1
            elif op == 0xFE: self.df = self.d >> 7; self.d = (self.d << 1) & 0xFF
            elif op == 0xF8: self.d = self.fetch()
            elif op == 0xF9: self.d |= self.fetch()
            elif op == 0xFA: self.d &= self.fetch()
            elif op == 0xFB: self.d ^= self.fetch()
            else: raise RuntimeError('op %02x at %04x' % (op, pc))

# ---- model disk ----
class World:
    def __init__(self):
        self.disk = [bytearray(random.getrandbits(8) for _ in range(512)) for _ in range(NSEC)]
        self.reads = 0; self.writes = 0; self.fail_next = False

def mk_hook(w):
    cache, csec, dirty = syms['fat_cache'], syms['fat_csec'], syms['fat_dirty']
    def fls(c):
        R = c.r
        if w.fail_next:
            w.fail_next = False; c.df = 1
            for k in (7, 8, 15): R[k] = random.getrandbits(16)
            return
        idx = R[13] >> 8
        cur = (c.rd(csec) << 8) | c.rd(csec + 1)
        if cur != idx:
            if c.rd(dirty):
                w.disk[cur][:] = c.m[cache:cache + 512]; w.writes += 1
                R[12] = random.getrandbits(16)          # fat_flush clobbers RC
            c.m[cache:cache + 512] = w.disk[idx]; w.reads += 1
            c.wr(csec, 0); c.wr(csec + 1, idx); c.wr(dirty, 0)
        for k in (7, 8, 15): R[k] = random.getrandbits(16)
        c.df = 0
    return fls

def effective(c, w):
    d = [bytearray(s) for s in w.disk]
    cache, csec, dirty = syms['fat_cache'], syms['fat_csec'], syms['fat_dirty']
    cur = (c.rd(csec) << 8) | c.rd(csec + 1)
    if cur != 0xFFFF and c.rd(dirty): d[cur][:] = c.m[cache:cache + 512]
    return b''.join(d)

def ref_get(fat, cl):
    o = cl + cl // 2; w = fat[o] | (fat[o + 1] << 8)
    v = (w >> 4) if cl & 1 else (w & 0xFFF)
    return v | 0xF000 if v >= 0xFF7 else v

def ref_set(fat, cl, v):
    fat = bytearray(fat); o = cl + cl // 2; v &= 0xFFF
    if cl & 1:
        fat[o] = (fat[o] & 0x0F) | ((v << 4) & 0xF0); fat[o + 1] = v >> 4
    else:
        fat[o] = v & 0xFF; fat[o + 1] = (fat[o + 1] & 0xF0) | (v >> 8)
    return bytes(fat)

def call(c, w, entry, rd, rb):
    for k in range(16): c.r[k] = random.getrandbits(16)
    c.r[2] = 0x7F00; c.x = 2; c.r[13] = rd; c.r[11] = rb
    c.steps = 0; c.r[6] = SENT; c.push16(0x1234); c.r[3] = entry
    c.d = random.getrandbits(8); c.df = random.getrandbits(1)
    c.run({syms['_fat_load_sector']: mk_hook(w)})
    assert c.r[2] == 0x7F00 - 2 + 2 or True

random.seed(1)
F16 = os.environ.get('FAT16') == '1'
if F16:
    def ref_get(fat, cl): return fat[2*cl] | (fat[2*cl+1] << 8)
    def ref_set(fat, cl, v):
        fat = bytearray(fat); fat[2*cl] = v & 0xFF; fat[2*cl+1] = v >> 8; return bytes(fat)
maxcl = NSEC*256 - 1 if F16 else (NSEC * 512 * 2) // 3 - 2
c = CPU(); w = World()
c.wr(syms['bpb_fat16'], 1 if F16 else 0); c.wr(syms['fat_csec'], 0xFF); c.wr(syms['fat_csec'] + 1, 0xFF); c.wr(syms['fat_dirty'], 0)
straddle = [cl for cl in range(2, maxcl) if (cl + cl // 2) % 512 == 511] if not F16 else [255, 256, 511, 512]
print('straddling clusters:', straddle)
fails = 0; n = 0
sp0 = None
def check_stack():
    global fails
    if c.r[2] != 0x7F00: fails += 1; print('stack imbalance', hex(c.r[2]))

for it in range(ITER):
    fat = effective(c, w)
    cl = random.choice(straddle) if random.random() < 0.2 else random.randint(2, maxcl)
    if random.random() < 0.5:
        rb = random.getrandbits(16)
        call(c, w, syms['fat_get'], cl, rb); n += 1
        # SENT reached via rtn: stack back to 0x7F00 after popping our dummy
        exp = ref_get(fat, cl)
        if c.df != 0 or c.r[13] != exp or c.r[11] != rb or effective(c, w) != fat:
            fails += 1
            if fails < 3: print('GET fail cl=%d exp=%04x got=%04x df=%d' % (cl, exp, c.r[13], c.df))
        check_stack()
    else:
        v = random.choice([0, 0xFFF8, 0xFFFF, 0xFFF7, random.randint(2, maxcl), random.getrandbits(16)])
        call(c, w, syms['fat_set'], cl, v); n += 1
        exp = ref_set(fat, cl, v)
        if c.df != 0 or c.r[13] != cl or c.r[11] != v or effective(c, w) != exp:
            fails += 1
            if fails < 3: print('SET fail cl=%d v=%04x df=%d rd=%04x' % (cl, v, c.df, c.r[13]))
        check_stack()

# I/O error propagation: DF=1, stack balanced, no crash
for it in range(2000):
    cl = random.choice(straddle) if it % 2 else random.randint(2, maxcl)
    c.wr(syms['fat_csec'], 0xFF); c.wr(syms['fat_csec'] + 1, 0xFF); c.wr(syms['fat_dirty'], 0)
    w.fail_next = True
    ent = syms['fat_get'] if it % 4 < 2 else syms['fat_set']
    call(c, w, ent, cl, 0); n += 1
    if c.df != 1: fails += 1; print('error not propagated', cl)
    check_stack()
print('calls:', n, 'failures:', fails, 'disk reads:', w.reads, 'writes:', w.writes)
sys.exit(1 if fails else 0)
