#!/usr/bin/env python3
"""Reference model of MDV (progs/mdv.asm): Markdown -> ANSI rows.

A byte-exact model of the assembly, written first and used to test it:
MDV -c <file> under Run/02 must print exactly these rows, each followed
by CR LF. Change both together.

    python3 tools/mdvref.py [-w COLUMNS] [-p] file.md

Not modelled: the ~32000-byte paragraph buffer (a longer paragraph, or a
single line over ~31K, is rendered in pieces by the program) and the
row buffer's 1024-byte hard limit.
"""
import sys

ESC = b'\x1b'
PUNCT = set(b'!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~')

# style bits
S_B, S_I, S_L, S_C, S_U = 1, 2, 4, 8, 16

HEAD_SGR = {1: b';1;4;36', 2: b';1;36', 3: b';1;35'}   # 4-6: ';1'
MARK_SGR = b'\x1b[36m'
BAR_SGR = b'\x1b[32m'
HR_SGR = b'\x1b[36m'
RESET = b'\x1b[0m'

K_NONE, K_PARA, K_LIST, K_QUOTE, K_HEAD, K_TABLE = 0, 1, 2, 3, 4, 5


def sgr(base, st):
    s = b'\x1b[0' + base
    if st & S_B: s += b';1'
    if st & S_I: s += b';3'
    if st & S_L: s += b';4'
    if st & S_C: s += b';33'
    if st & S_U: s += b';32'
    return s + b'm'


class Out:
    def __init__(self, width, plain):
        self.W = width
        self.plain = plain
        self.rows = []
        self.any_out = False
        self.need_blank = False

    def row(self, b):
        self.rows.append(bytes(b))
        self.any_out = True


class Wrap:
    """Row builder for one block."""
    def __init__(self, out, words, first_prefix, cont_prefix, base=b''):
        self.o = out
        self.words = words
        self.fp = first_prefix      # function(rb) -> visible cols added
        self.cp = cont_prefix
        self.base = base
        self.cur = 0                # desired style bits
        self.started = False

    # --- row management ---
    def _start(self, first):
        o = self.o
        if o.need_blank and o.any_out:
            o.row(b'')
        o.need_blank = False
        self.rb = bytearray()
        self.col = (self.fp if first else self.cp)(self.rb, self.o.plain)
        self.pcol = self.col          # prefix end column
        self.rstyle = None            # style in effect on the terminal (None = 0 / reset)
        self.brk = None               # (idx, col, style)
        self.started = True

    def _style_bytes(self, st):
        if self.o.plain:
            return b''
        return sgr(self.base, st)

    def _apply(self):
        """Put the wanted style in effect before a visible byte."""
        if self.cur or self.base:
            if self.rstyle != self.cur:
                self.rb += self._style_bytes(self.cur)
                self.rstyle = self.cur
        elif self.rstyle is not None:
            if not self.o.plain:
                self.rb += RESET
            self.rstyle = None

    def _end_row(self):
        if self.rstyle is not None and not self.o.plain:
            self.rb += RESET
        self.o.row(self.rb)

    def put(self, c):
        """Add one byte of rendered text."""
        if not self.started:
            self._start(True)
        if c == 9:
            c = 32
        if c < 32 or c == 127:
            return
        if (c & 0xC0) == 0x80:          # UTF-8 continuation: zero width
            self.rb.append(c)
            return
        W = self.o.W
        if c == 32 and self.words:
            if self.col == self.pcol:
                return                  # no leading spaces on a row
            if self.col >= W:
                self._end_row()
                self._start(False)
                return
            self._apply()
            self.rb.append(32)
            self.col += 1
            self.brk = (len(self.rb) - 1, self.rstyle)
            return
        if self.col >= W or len(self.rb) > 900:
            if self.words and self.brk is not None:
                idx, bst = self.brk
                rest = self.rb[idx + 1:]
                old_rstyle = self.rstyle
                self.rb = self.rb[:idx]
                self.rstyle = bst
                self._end_row()
                self._start(False)
                if bst is not None:
                    self.rb += self._style_bytes(bst)
                self.rb += rest
                self.rstyle = old_rstyle
                self.col += vis(rest)
            else:
                self._end_row()
                self._start(False)
        self._apply()
        self.rb.append(c)
        self.col += 1

    def finish(self):
        if not self.started:
            self._start(True)
        self._end_row()
        self.started = False


def vis(b):
    n = 0
    i = 0
    while i < len(b):
        c = b[i]
        if c == 27:
            i += 1
            if i < len(b) and b[i] == ord('['):
                i += 1
                while i < len(b) and not (0x40 <= b[i] <= 0x7e):
                    i += 1
            i += 1
            continue
        if (c & 0xC0) != 0x80:
            n += 1
        i += 1
    return n


def spaces(n):
    def f(rb, plain):
        rb += b' ' * n
        return n
    return f


def is_ws(c):
    return c in (0, 32, 9)


def run_len(t, i, ch):
    k = 0
    while t[i + k] == ch:
        k += 1
    return k


def find_code_close(t, i, k):
    j = i + k
    while t[j]:
        if t[j] == 96:
            m = run_len(t, j, 96)
            if m == k:
                return j
            j += m
        else:
            j += 1
    return -1


def flank(t, i, k):
    prev = t[i - 1] if i > 0 else 32
    nxt = t[i + k]
    pw, nw = is_ws(prev), is_ws(nxt)
    pp, npn = prev in PUNCT, nxt in PUNCT
    left = (not nw) and ((not npn) or pw or pp)
    right = (not pw) and ((not pp) or nw or npn)
    return left, right, pp, npn


def can_open(t, i, k, ch):
    left, right, pp, npn = flank(t, i, k)
    if ch == 42:
        return left
    return left and ((not right) or pp)


def can_close(t, i, k, ch):
    left, right, pp, npn = flank(t, i, k)
    if ch == 42:
        return right
    return right and ((not left) or npn)


def find_emph_close(t, i, k, ch):
    j = i + k
    while t[j]:
        c = t[j]
        if c == 92 and t[j + 1]:
            j += 2
            continue
        if c == 96:
            m = run_len(t, j, 96)
            e = find_code_close(t, j, m)
            j = (e + m) if e >= 0 else j + m
            continue
        if c == ch:
            m = run_len(t, j, ch)
            if m == k and can_close(t, j, k, ch):
                return j
            j += m
            continue
        j += 1
    return -1


def find_bracket(t, i):
    """t[i] == '['; index of matching ']' or -1."""
    j = i + 1
    depth = 1
    while t[j]:
        c = t[j]
        if c == 92 and t[j + 1]:
            j += 2
            continue
        if c == 91:
            depth += 1
        elif c == 93:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def find_paren(t, j):
    """t[j] == '('; index of matching ')' or -1."""
    depth = 1
    j += 1
    while t[j]:
        c = t[j]
        if c == 92 and t[j + 1]:
            j += 2
            continue
        if c == 40:
            depth += 1
        elif c == 41:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def render_inline(w, t):
    """t: bytes with a trailing NUL."""
    i = 0
    it_ch = 0
    bo_ch = 0
    link_end = -1
    link_after = 0
    url = None
    while t[i]:
        c = t[i]
        if i == link_end:
            w.cur &= ~S_L
            if url is not None:
                w.cur |= S_U
                for b in b' (' + url + b')':
                    w.put(b)
                w.cur &= ~S_U
            i = link_after
            link_end = -1
            continue
        if c == 92:
            n = t[i + 1]
            if n in PUNCT:
                w.put(n)
                i += 2
            else:
                w.put(c)
                i += 1
            continue
        if c == 96:
            k = run_len(t, i, 96)
            e = find_code_close(t, i, k)
            if e < 0:
                for _ in range(k):
                    w.put(96)
                i += k
                continue
            s, f = i + k, e
            if f - s >= 2 and t[s] == 32 and t[f - 1] == 32:
                if any(x != 32 for x in t[s:f]):
                    s += 1
                    f -= 1
            w.cur |= S_C
            for x in t[s:f]:
                w.put(x)
            w.cur &= ~S_C
            i = e + k
            continue
        if c in (42, 95):
            k = run_len(t, i, c)
            done = False
            if 1 <= k <= 3:
                need = (S_I if k & 1 else 0) | (S_B if k & 2 else 0)
                on = w.cur & need
                chars_ok = ((not (need & S_I)) or it_ch == c) and ((not (need & S_B)) or bo_ch == c)
                if on == need and chars_ok and can_close(t, i, k, c):
                    w.cur &= ~need
                    done = True
                elif on == 0 and can_open(t, i, k, c) and find_emph_close(t, i, k, c) >= 0:
                    w.cur |= need
                    if need & S_I: it_ch = c
                    if need & S_B: bo_ch = c
                    done = True
            if not done:
                for _ in range(k):
                    w.put(c)
            i += k
            continue
        if c == 33 and t[i + 1] == 91 and not (w.cur & S_L):
            j = find_bracket(t, i + 1)
            if j >= 0 and t[j + 1] in (40, 91):
                i += 1
                continue
            w.put(c)
            i += 1
            continue
        if c == 91 and not (w.cur & S_L):
            j = find_bracket(t, i)
            if j >= 0 and t[j + 1] == 40:
                e = find_paren(t, j + 1)
                if e >= 0:
                    us = j + 2
                    ue = us
                    while ue < e and t[ue] not in (32, 9):
                        ue += 1
                    u = bytes(t[us:ue])
                    url = u if (u and u != bytes(t[i + 1:j])) else None
                    link_end = j
                    link_after = e + 1
                    w.cur |= S_L
                    i += 1
                    continue
            if j >= 0 and t[j + 1] == 91:
                e = find_bracket(t, j + 1)
                if e >= 0:
                    url = None
                    link_end = j
                    link_after = e + 1
                    w.cur |= S_L
                    i += 1
                    continue
            w.put(c)
            i += 1
            continue
        if c == 60:
            j = i + 1
            special = False
            while t[j] and t[j] > 32 and t[j] not in (60, 62):
                if t[j] in (58, 64):
                    special = True
                j += 1
            if t[j] == 62 and j > i + 1 and special:
                w.cur |= S_L
                for x in t[i + 1:j]:
                    w.put(x)
                w.cur &= ~S_L
                i = j + 1
                continue
            w.put(c)
            i += 1
            continue
        w.put(c)
        i += 1
    w.cur = 0


class Doc:
    def __init__(self, width, plain):
        self.o = Out(width, plain)
        self.kind = K_NONE
        self.blk = bytearray()
        self.margin = 0
        self.marker = b''
        self.cont = 0
        self.in_list = False
        self.list_cont = 0
        self.in_fence = False
        self.fch = 0
        self.flen = 0
        self.find = 0

    # --- block output ---
    def flush(self):
        if self.kind == K_NONE:
            return
        k = self.kind
        t = bytes(self.blk) + b'\0'
        o = self.o
        if k == K_PARA:
            w = Wrap(o, True, spaces(self.margin), spaces(self.margin))
        elif k == K_LIST:
            m, mk = self.margin, self.marker

            def fp(rb, plain, m=m, mk=mk):
                rb += b' ' * m
                if not plain:
                    rb += MARK_SGR
                rb += mk
                if not plain:
                    rb += RESET
                rb += b' '
                return m + len(mk) + 1
            w = Wrap(o, True, fp, spaces(self.cont))
        elif k == K_QUOTE:
            def qp(rb, plain):
                if not plain:
                    rb += BAR_SGR
                rb += b'|'
                if not plain:
                    rb += RESET
                rb += b' '
                return 2
            w = Wrap(o, True, qp, qp)
        elif k == K_HEAD:
            w = Wrap(o, True, spaces(0), spaces(0), HEAD_SGR.get(self.level, b';1'))
        else:  # K_TABLE
            w = Wrap(o, True, spaces(0), spaces(0))
        render_inline(w, t)
        w.finish()
        self.kind = K_NONE
        self.blk = bytearray()

    def code_row(self, text):
        o = self.o
        w = Wrap(o, False, spaces(2), spaces(2))
        w.cur = S_C
        col = 0
        for c in text:
            if c == 9:
                n = 8 - (col & 7)
                for _ in range(n):
                    w.put(32)
                col += n
                continue
            if c < 32 or c == 127:
                continue
            w.put(c)
            if (c & 0xC0) != 0x80:
                col += 1
        w.finish()

    def quote_blank(self):
        o = self.o
        if o.need_blank and o.any_out:
            o.row(b'')
        o.need_blank = False
        rb = bytearray()
        if not o.plain:
            rb += BAR_SGR
        rb += b'|'
        if not o.plain:
            rb += RESET
        o.row(rb)

    def hr(self):
        o = self.o
        if o.need_blank and o.any_out:
            o.row(b'')
        o.need_blank = False
        rb = bytearray()
        if not o.plain:
            rb += HR_SGR
        rb += b'-' * o.W
        if not o.plain:
            rb += RESET
        o.row(rb)

    def start(self, kind, content):
        self.flush()
        self.kind = kind
        self.blk = bytearray(content)

    # --- one source line ---
    def line(self, L):
        # indentation
        ind = 0
        p = 0
        while p < len(L) and L[p] in (32, 9):
            ind = (ind + 4) & ~3 if L[p] == 9 else ind + 1
            p += 1
        s = L[p:]

        if self.in_fence:
            if ind < 4 and len(s) >= self.flen and s[0] == self.fch:
                k = 0
                while k < len(s) and s[k] == self.fch:
                    k += 1
                if k >= self.flen and all(x in (32, 9) for x in s[k:]):
                    self.in_fence = False
                    return
            # strip up to fence indent spaces
            q = 0
            while q < self.find and q < len(L) and L[q] == 32:
                q += 1
            self.code_row(L[q:])
            return

        if not s:
            self.flush()
            if self.o.any_out:
                self.o.need_blank = True
            return

        # fence open
        if ind < 4 and len(s) >= 3 and s[0] in (96, 126) and s[1] == s[0] and s[2] == s[0]:
            k = 0
            while k < len(s) and s[k] == s[0]:
                k += 1
            if not (s[0] == 96 and 96 in s[k:]):
                self.flush()
                self.in_fence = True
                self.fch, self.flen, self.find = s[0], k, ind
                self.in_list = False
                return

        # setext underline
        if ind < 4 and self.kind == K_PARA and s[0] in (61, 45):
            t = s.rstrip(b' \t')
            if all(x == s[0] for x in t):
                self.kind = K_HEAD
                self.level = 1 if s[0] == 61 else 2
                self.flush()
                self.in_list = False
                return

        # thematic break
        if ind < 4 and s[0] in (45, 42, 95):
            n = 0
            ok = True
            for x in s:
                if x == s[0]:
                    n += 1
                elif x not in (32, 9):
                    ok = False
                    break
            if ok and n >= 3:
                self.flush()
                self.hr()
                self.in_list = False
                return

        # ATX heading
        if ind < 4 and s[0] == 35:
            k = 0
            while k < len(s) and s[k] == 35:
                k += 1
            if k <= 6 and (k == len(s) or s[k] in (32, 9)):
                c = s[k:].strip(b' \t')
                e = len(c)
                while e > 0 and c[e - 1] == 35:
                    e -= 1
                if e == 0 or c[e - 1] in (32, 9):
                    c = c[:e].rstrip(b' \t')
                self.start(K_HEAD, c)
                self.level = k
                self.flush()
                self.in_list = False
                return

        # list item
        lim = 64 if self.in_list else 4
        if ind < lim:
            mk = None
            q = 0
            if s[0] in (45, 42, 43) and (len(s) == 1 or s[1] in (32, 9)):
                mk = b'*' if ind == 0 else b'-'
                q = 1
            elif 48 <= s[0] <= 57:
                while q < len(s) and q < 9 and 48 <= s[q] <= 57:
                    q += 1
                if q < len(s) and s[q] in (46, 41) and (q + 1 == len(s) or s[q + 1] in (32, 9)):
                    q += 1
                    mk = bytes(s[:q])
            if mk is not None:
                while q < len(s) and s[q] in (32, 9):
                    q += 1
                self.start(K_LIST, s[q:])
                self.margin = min(ind, 8)
                self.marker = mk
                self.cont = self.margin + len(mk) + 1
                self.in_list = True
                self.list_cont = self.cont
                return

        # block quote
        if ind < 4 and s[0] == 62:
            q = 0
            while q < len(s) and s[q] == 62:
                q += 1
                if q < len(s) and s[q] == 32:
                    q += 1
            c = s[q:].lstrip(b' \t')
            if not c:
                self.flush()
                self.quote_blank()
                return
            if self.kind == K_QUOTE:
                self.blk += b' ' + c
            else:
                self.start(K_QUOTE, c)
            self.in_list = False
            return

        # table row
        if ind < 4 and s[0] == 124:
            self.start(K_TABLE, s)
            self.flush()
            self.in_list = False
            return

        # indented code
        if ind >= 4 and not self.in_list and self.kind == K_NONE:
            q = 0
            col = 0
            while q < len(L) and col < 4 and L[q] in (32, 9):
                col = (col + 4) & ~3 if L[q] == 9 else col + 1
                q += 1
            self.code_row(L[q:])
            return

        # text
        if self.kind in (K_PARA, K_LIST, K_QUOTE):
            if self.blk:
                self.blk += b' '
            self.blk += s
            return
        if ind == 0:
            self.in_list = False
        self.start(K_PARA, s)
        self.margin = self.list_cont if self.in_list else 0

    def end(self):
        self.flush()


def render(data, width=79, plain=False):
    d = Doc(width, plain)
    lines = data.split(b'\n')
    if lines and lines[-1] == b'':
        lines.pop()
    for L in lines:
        L = bytes(x for x in L if x not in (13, 0))
        d.line(L)
    d.end()
    return d.o.rows


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('-w', type=int, default=80)
    ap.add_argument('-p', action='store_true')
    a = ap.parse_args()
    data = open(a.file, 'rb').read()
    for r in render(data, max(20, min(250, a.w - 1)), a.p):
        sys.stdout.buffer.write(r + b'\n')
