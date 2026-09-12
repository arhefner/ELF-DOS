#!/usr/bin/env python3
"""Tiny FAT12/FAT16 reader + root-file writer for emulator tests.
Type is decided the spec way: cluster count < 4085 -> FAT12."""
import struct, sys

SEC = 512

class Vol:
    def __init__(self, path, lba):
        self.f = open(path, 'r+b'); self.base = lba * SEC
        b = self.rd(0)
        self.spc = b[13]; self.rsvd = struct.unpack_from('<H', b, 14)[0]
        self.nfats = b[16]; self.rootents = struct.unpack_from('<H', b, 17)[0]
        self.spf = struct.unpack_from('<H', b, 22)[0]
        tot = struct.unpack_from('<H', b, 19)[0] or struct.unpack_from('<I', b, 32)[0]
        self.rootsec = self.rsvd + self.nfats * self.spf
        self.data0 = self.rootsec + (self.rootents * 32 + SEC - 1) // SEC
        self.count = (tot - self.data0) // self.spc
        self.fat12 = self.count < 4085
        self.fat = bytearray(b''.join(self.rd(self.rsvd + i) for i in range(self.spf)))

    def rd(self, s, n=1):
        self.f.seek(self.base + s * SEC); return self.f.read(n * SEC)
    def wr(self, s, data):
        self.f.seek(self.base + s * SEC); self.f.write(data)

    def get(self, c):
        if self.fat12:
            o = c + c // 2; w = self.fat[o] | self.fat[o + 1] << 8
            return (w >> 4) if c & 1 else (w & 0xFFF)
        return struct.unpack_from('<H', self.fat, 2 * c)[0]
    def eoc(self, v): return v >= (0xFF8 if self.fat12 else 0xFFF8)
    def set(self, c, v):
        if self.fat12:
            o = c + c // 2; v &= 0xFFF
            if c & 1:
                self.fat[o] = (self.fat[o] & 0x0F) | (v << 4) & 0xF0; self.fat[o + 1] = v >> 4
            else:
                self.fat[o] = v & 0xFF; self.fat[o + 1] = (self.fat[o + 1] & 0xF0) | v >> 8
        else:
            struct.pack_into('<H', self.fat, 2 * c, v)
    def flush(self):
        for i in range(self.nfats): self.wr(self.rsvd + i * self.spf, bytes(self.fat))

    def chain(self, c):
        out = []
        while 2 <= c < 0xFF7 if self.fat12 else 2 <= c < 0xFFF7:
            out.append(c); c = self.get(c)
            if len(out) > self.count + 2: raise RuntimeError('loop')
        return out
    def clus_sec(self, c): return self.data0 + (c - 2) * self.spc

    def entries(self, first):
        """yield (name, attr, cluster, size) for a directory (0 = root)"""
        if first == 0:
            secs = [self.rootsec + i for i in range((self.rootents * 32 + 511) // 512)]
        else:
            secs = [self.clus_sec(c) + i for c in self.chain(first) for i in range(self.spc)]
        lfn = []
        for s in secs:
            b = self.rd(s)
            for o in range(0, 512, 32):
                e = b[o:o + 32]
                if e[0] == 0: return
                if e[0] == 0xE5: lfn = []; continue
                if e[11] == 0x0F:
                    part = e[1:11] + e[14:26] + e[28:32]
                    lfn.insert(0, part.decode('utf-16le', 'replace').split('\x00')[0].replace('￿', '')); continue
                if e[11] & 0x08: lfn = []; continue
                short = e[0:8].decode('latin-1').rstrip(); ext = e[8:11].decode('latin-1').rstrip()
                if e[12] & 0x08: short = short.lower()
                if e[12] & 0x10: ext = ext.lower()
                name = ''.join(lfn) or (short + ('.' + ext if ext else ''))
                lfn = []
                yield name, e[11], struct.unpack_from('<H', e, 26)[0], struct.unpack_from('<I', e, 28)[0]

    def find(self, path):
        cl = 0; ent = None
        for part in [p for p in path.split('/') if p]:
            for ent in self.entries(cl):
                if ent[0].lower() == part.lower(): cl = ent[2]; break
            else: return None
        return ent

    def readfile(self, path):
        ent = self.find(path)
        if ent is None: return None
        data = b''.join(self.rd(self.clus_sec(c), self.spc) for c in self.chain(ent[2]))
        return data[:ent[3]]

    def putroot(self, name83, data):
        """write a file into the root dir, contiguous from the first free cluster"""
        base, ext = (name83.split('.') + [''])[:2]
        csz = self.spc * SEC; need = max(1, (len(data) + csz - 1) // csz)
        free = [c for c in range(2, self.count + 2) if self.get(c) == 0][:need]
        for i, c in enumerate(free):
            self.set(c, free[i + 1] if i + 1 < len(free) else 0xFFF)
            chunk = data[i * csz:(i + 1) * csz]
            self.wr(self.clus_sec(c), chunk + bytes(csz - len(chunk)))
        self.flush()
        for s in range((self.rootents * 32 + 511) // 512):
            b = bytearray(self.rd(self.rootsec + s))
            for o in range(0, 512, 32):
                if b[o] in (0, 0xE5):
                    e = bytearray(32)
                    e[0:8] = base.upper().ljust(8).encode(); e[8:11] = ext.upper().ljust(3).encode()
                    e[11] = 0x20; e[12] = (0x08 if base.islower() else 0) | (0x10 if ext.islower() else 0)
                    struct.pack_into('<HHHI', e, 22, 0, 0x5A21, free[0], len(data))
                    b[o:o + 32] = e; self.wr(self.rootsec + s, bytes(b)); return free
        raise RuntimeError('root full')
