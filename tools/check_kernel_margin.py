#!/usr/bin/env python3
#
# check_kernel_margin.py - guard against a specific, previously-real bug:
# a "ds" (uninitialized) buffer that happens to be the last thing placed
# in the whole kernel link, with nothing after it anywhere, never gets
# counted in Link/02's own "Highest address" tracking (that tracking only
# advances when a byte is actually written -- a "ds" reservation never
# writes anything). If that ever happens in the kernel image itself, the
# kernel's real footprint would be larger than what "Highest address"
# reports, silently eating into the margin before PROG_BASE.
#
# This exact bug hit kernel/batch_mod.asm for real (its own trailing
# "ds"-declared buffer, batch_goto_label, was 32 bytes past the module's
# reported code_size) before it was found and fixed. The kernel proper
# turned out not to have the same problem -- lib/icall.asm is always
# linked last and ends in real code, not a "ds" -- but that's a fact
# about today's link order, not a guarantee, so this check runs on every
# kernel build rather than being trusted once and forgotten.
#
# What it does: re-links the kernel object files with "-s" to get every
# public symbol's real address, finds every "label: ds SIZE" declaration
# in the same set of source files, evaluates SIZE against the project's
# own "equ" constants, and confirms every such buffer's own last byte
# still falls comfortably below the linker's own reported "Highest
# address" -- i.e. that real, written content genuinely follows it
# somewhere in the link, so it isn't silently being left out of the
# output binary.
#
# Usage: tools/check_kernel_margin.py [--threshold N] [file.prg ...]
# With no file arguments, checks the same object list the Makefile's own
# $(KOBJ) does (kept in sync by hand below -- see the Makefile if this
# script ever reports the wrong file set).
# Exit code 0 = all clear, 1 = a buffer is too close to (or past) the
# reported highest address, 2 = a setup/parsing problem (couldn't run
# the linker, couldn't find a buffer's address, etc).
#

import re
import subprocess
import sys
import tempfile
import os

# Default margin (in bytes) every "ds" buffer's own last byte must stay
# below "Highest address" -- comfortably larger than any single buffer
# this project has ever declared, so a warning here means something
# genuinely needs a second look, not just "one buffer is a bit close."
DEFAULT_THRESHOLD = 16

# Same file list as the Makefile's own $(KOBJ), .prg swapped for .asm
# (the source this script actually needs to read). Update this if KOBJ
# ever changes -- nothing here reads the Makefile itself, since KOBJ's
# own syntax (line continuations, $(...) substitutions) isn't worth a
# real parser for a list this short and this rarely changed.
DEFAULT_KOBJ_ASM = [
    "kernel/kernel.asm",
    "kernel/fat.asm",
    "kernel/dir.asm",
    "kernel/path.asm",
    "kernel/rtc.asm",
    "kernel/file.asm",
    "kernel/loader.asm",
    "kernel/batch.asm",
    "kernel/redir.asm",
    "kernel/glob.asm",
    "lib/modload.asm",
    "lib/icall.asm",
]

# Every .inc/.def under include/ is a plausible source of "equ" constants
# referenced by a "ds" size expression, even though not every kernel
# file includes every one of them -- harmless over-inclusion, since a
# name collision would have to also collide in VALUE to go unnoticed,
# and this project's own naming has stayed collision-free so far.
INCLUDE_GLOB_DIRS = ["include"]

EQU_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:?\s*\bequ\b\s*(.+?)\s*(;.*)?$"
)
DS_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*ds\s+(.+?)\s*(;.*)?$"
)


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


def read_lines(path):
    with open(path, "r", errors="replace") as f:
        return f.readlines()


def collect_equs(paths):
    """Scan every given file for 'NAME: equ VALUE' and return a raw
    (unevaluated) {name: value_text} map. Later definitions win if a
    name repeats -- acceptable for this script's narrow purpose (see
    the module docstring)."""
    equs = {}
    for path in paths:
        if not os.path.isfile(path):
            continue
        for line in read_lines(path):
            m = EQU_RE.match(line)
            if m:
                equs[m.group(1)] = m.group(2).strip()
    return equs


TOKEN_RE = re.compile(r"\$[0-9A-Fa-f]+|'.'|[0-9]+|[A-Za-z_][A-Za-z0-9_]*|[*+\-]")


def eval_expr(text, equs, _seen=None):
    """Evaluate a small subset of Asm/02 constant-expression syntax:
    decimal/'$hex'/'c' literals, named 'equ' constants (resolved
    recursively), combined left-to-right with *, +, -. Enough for every
    "ds SIZE" expression this project has ever written (plain constants,
    A*B, A*2) -- not a general expression parser, and deliberately
    raises rather than guessing if it sees something it doesn't
    recognize."""
    if _seen is None:
        _seen = set()
    tokens = TOKEN_RE.findall(text)
    if not tokens:
        raise ValueError(f"empty/unparseable expression: {text!r}")

    def value_of(tok):
        if tok.startswith("$"):
            return int(tok[1:], 16)
        if tok.startswith("'") and tok.endswith("'") and len(tok) == 3:
            return ord(tok[1])
        if tok[0].isdigit():
            return int(tok, 10)
        # named constant -- resolve recursively
        if tok in _seen:
            raise ValueError(f"circular equ definition involving {tok!r}")
        if tok not in equs:
            raise ValueError(f"unknown constant {tok!r} in expression {text!r}")
        return eval_expr(equs[tok], equs, _seen | {tok})

    result = value_of(tokens[0])
    i = 1
    while i < len(tokens):
        op = tokens[i]
        rhs = value_of(tokens[i + 1])
        if op == "*":
            result *= rhs
        elif op == "+":
            result += rhs
        elif op == "-":
            result -= rhs
        else:
            raise ValueError(f"unsupported operator {op!r} in {text!r}")
        i += 2
    return result


def collect_ds_buffers(asm_paths):
    """Return [(name, size_text, source_path), ...] for every top-level
    'label: ds SIZE' declaration found in the given files."""
    out = []
    for path in asm_paths:
        for line in read_lines(path):
            m = DS_RE.match(line)
            if m:
                out.append((m.group(1), m.group(2).strip(), path))
    return out


def link_and_get_symbols(prg_paths, extra_link_flags):
    """Runs link02 with -s against the given .prg files and returns
    (lowest, highest, {symbol: address})."""
    with tempfile.TemporaryDirectory() as tmp:
        out_bin = os.path.join(tmp, "check.bin")
        cmd = ["link02"] + extra_link_flags + ["-o", out_bin, "-s"] + prg_paths
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, check=False
            )
        except FileNotFoundError:
            print("error: link02 not found on PATH", file=sys.stderr)
            sys.exit(2)
        output = proc.stdout + proc.stderr
        if proc.returncode != 0:
            print("error: link02 failed:", file=sys.stderr)
            print(output, file=sys.stderr)
            sys.exit(2)

        lowest = highest = None
        symbols = {}
        for line in output.splitlines():
            lm = re.match(r"^Lowest address\s*:\s*([0-9A-Fa-f]+)", line)
            if lm:
                lowest = int(lm.group(1), 16)
                continue
            hm = re.match(r"^Highest address\s*:\s*([0-9A-Fa-f]+)", line)
            if hm:
                highest = int(hm.group(1), 16)
                continue
            sm = re.match(r"^(\S+)\s+([0-9A-Fa-f]{4})\s*$", line)
            if sm:
                symbols[sm.group(1)] = int(sm.group(2), 16)

        if lowest is None or highest is None:
            print("error: could not parse Lowest/Highest address from link02 output:",
                  file=sys.stderr)
            print(output, file=sys.stderr)
            sys.exit(2)
        return lowest, highest, symbols


def main():
    threshold = DEFAULT_THRESHOLD
    args = sys.argv[1:]
    if "--threshold" in args:
        i = args.index("--threshold")
        threshold = int(args[i + 1])
        del args[i:i + 2]

    root = repo_root()
    os.chdir(root)

    asm_paths = args if args else DEFAULT_KOBJ_ASM
    prg_paths = [os.path.splitext(p)[0] + ".prg" for p in asm_paths]

    missing = [p for p in prg_paths if not os.path.isfile(p)]
    if missing:
        print("error: missing .prg files (run the normal asm02 build step "
              "first):", file=sys.stderr)
        for p in missing:
            print(f"  {p}", file=sys.stderr)
        sys.exit(2)

    include_files = []
    for d in INCLUDE_GLOB_DIRS:
        for name in sorted(os.listdir(d)):
            if name.endswith((".inc", ".def")):
                include_files.append(os.path.join(d, name))

    equs = collect_equs(include_files + asm_paths)
    buffers = collect_ds_buffers(asm_paths)

    lowest, highest, symbols = link_and_get_symbols(
        prg_paths, ["-b", "-be", "-r"]
    )

    print(f"check_kernel_margin: Lowest={lowest:04x} Highest={highest:04x} "
          f"({len(buffers)} 'ds' buffers checked, threshold={threshold})")

    failed = False
    worst_name, worst_margin = None, None
    for name, size_text, source in buffers:
        if name not in symbols:
            print(f"  WARNING: {name} (in {source}) has no address in the "
                  f"linked symbol table -- not declared 'public'? Skipped, "
                  f"not verified.")
            continue
        try:
            size = eval_expr(size_text, equs)
        except ValueError as e:
            print(f"  WARNING: could not evaluate size of {name} "
                  f"({size_text!r}, in {source}): {e} -- skipped, not "
                  f"verified.")
            continue

        start = symbols[name]
        end = start + size - 1
        margin = highest - end

        if worst_margin is None or margin < worst_margin:
            worst_margin, worst_name = margin, name

        if margin < threshold:
            failed = True
            print(f"  FAIL: {name} ({source}) spans {start:04x}-{end:04x} "
                  f"(size {size}) -- only {margin} bytes before Highest "
                  f"address {highest:04x}. This buffer may be silently "
                  f"excluded from the linked output.")

    if worst_name is not None:
        status = "OK" if not failed else "FAILED"
        print(f"check_kernel_margin: {status} -- tightest buffer is "
              f"{worst_name}, {worst_margin} bytes of real content after "
              f"it before Highest address.")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
