#!/usr/bin/env python3
"""Slice the single linked kernel image into its two loadable halves.

The kernel is ONE link spanning TWO address regions (see
include/memmap.inc):

    $0100 .. kvol_end     volatile   -- must be RAM, loaded every boot
    NVK_BASE .. Highest   non-volatile -- ROM-able, loaded only when
                                         the signature is absent

Link/02 writes one contiguous file from its lowest to its highest
address, so kernel.bin contains both regions plus a large zero-filled
gap between them. This tool writes the two halves out separately:

    kvol.bin   the volatile image
    knv.bin    the non-volatile image

Why a marker symbol instead of trimming zeros: the volatile region can
legitimately END in zero bytes (a field initialized to zero, or a "ds"
reservation, which emits no bytes at all -- Link/02 just advances its
cursor). Trimming trailing zeros would silently truncate the image and
leave the kernel running with data it believes it owns but that was
never loaded. kernel/kvolend.asm contributes a real byte as the last
volatile object precisely so this tool has an authoritative end address
to slice at, and so the linker's own watermark covers every reserved
byte before it.

The region addresses come from a symbol-table link rather than being
hardcoded here, so moving NVK_BASE or adding volatile data needs no
change to this file.
"""

import os
import re
import subprocess
import sys
import tempfile

SECTOR_SIZE = 512


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def eval_equ(text, equs, seen=None):
    """Evaluate an 'equ' expression ($hex, decimal, or another equ)."""
    seen = seen or set()
    text = text.strip()
    m = re.fullmatch(r"\$([0-9A-Fa-f]+)", text)
    if m:
        return int(m.group(1), 16)
    if re.fullmatch(r"\d+", text):
        return int(text)
    if text in equs and text not in seen:
        return eval_equ(equs[text], equs, seen | {text})
    raise ValueError(f"cannot evaluate {text!r}")


def read_equs(path):
    equs = {}
    pat = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:?\s+equ\s+(\S+)", re.I)
    for line in open(path):
        line = line.split(";", 1)[0]
        m = pat.match(line)
        if m:
            equs[m.group(1)] = m.group(2)
    return equs


def link_symbols(objs):
    """Re-link with -S purely to read back the symbol table."""
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "ksym")
        r = subprocess.run(["link02", "-b", "-be", "-r", "-S", "-o", out] + objs,
                           capture_output=True, text=True)
        sym = out + ".sym"
        if not os.path.isfile(sym):
            sys.exit("error: link02 -S produced no symbol file:\n"
                     + r.stdout + r.stderr)
        syms = {}
        for line in open(sym):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    syms[parts[0]] = int(parts[-1], 16)
                except ValueError:
                    pass
        return syms


def sectors(n):
    return (n + SECTOR_SIZE - 1) // SECTOR_SIZE


# Header offsets inside krnboot's first sector (see boot/krnboot.asm).
# The volatile count keeps its historic offset; the non-volatile count
# sits after the 3-byte "lbr boot_main" at $4406, so that the MBR's
# fixed entry point does not move.
KVOL_CNT_OFFSET = 4      # $4404-$4405, big-endian
KNV_CNT_OFFSET = 9       # $4409-$440A, big-endian
KRNBOOT_SECTORS = 5      # must match boot/krnboot.asm and boot/mbr.asm


def main():
    if len(sys.argv) < 7:
        sys.exit("usage: split_kernel.py <kernel.bin> <kvol.bin> <knv.bin> "
                 "<krnboot.bin> <kernel-full.bin> <obj.prg> [obj.prg ...]")
    kernel_bin, vol_out, nv_out, krnboot_bin, full_out = sys.argv[1:6]
    objs = sys.argv[6:]

    os.chdir(repo_root())
    equs = read_equs("include/memmap.inc")
    nvk_base = eval_equ(equs["NVK_BASE"], equs)
    nvk_top = eval_equ(equs["NVK_TOP"], equs)

    syms = link_symbols(objs)
    if "kvol_end" not in syms:
        sys.exit("error: kvol_end not in the symbol table -- is "
                 "kernel/kvolend.asm still last in KVOL?")
    vol_end = syms["kvol_end"]

    data = open(kernel_bin, "rb").read()
    base = 0x0100                      # link's lowest address
    nv_end = base + len(data) - 1      # link's highest address

    # Sanity: the two regions must not have run into each other, and the
    # non-volatile half must fit under its ceiling. Both are real
    # failure modes (volatile data growing past NVK_BASE; ROM overflow),
    # and both are silent if not checked here.
    if vol_end >= nvk_base:
        sys.exit(f"error: volatile region ends at {vol_end:04x}, at or past "
                 f"NVK_BASE ({nvk_base:04x})")
    # krnboot loads WHOLE sectors, so the final one is written in full
    # even when the image only partly fills it. Check the address the
    # load actually reaches, not the image's own end -- the difference
    # is up to 511 bytes, and at NVK_BASE=$BD00 it silently ran into ROM
    # and hung the machine at boot with no output.
    nv_load_end = nvk_base + sectors(len(data) - (nvk_base - base)) * SECTOR_SIZE - 1
    if nv_load_end > nvk_top:
        sys.exit(f"error: non-volatile image ends at {nv_end:04x}, but "
                 f"krnboot loads whole sectors and would write through "
                 f"{nv_load_end:04x}, past NVK_TOP ({nvk_top:04x}). "
                 f"Lower NVK_BASE.")

    vol = data[0:vol_end - base + 1]
    nv = data[nvk_base - base:]

    if nv[0:3] != b"NVK":
        sys.exit(f"error: no 'NVK' signature at NVK_BASE ({nvk_base:04x}) -- "
                 f"is kernel/nvhdr.asm still FIRST in KNV? got {nv[0:4]!r}")

    open(vol_out, "wb").write(vol)
    open(nv_out, "wb").write(nv)

    print(f"split_kernel: volatile {base:04x}-{vol_end:04x} "
          f"{len(vol):>6} bytes ({sectors(len(vol)):>2} sectors) -> {vol_out}")
    print(f"split_kernel: non-vol  {nvk_base:04x}-{nv_end:04x} "
          f"{len(nv):>6} bytes ({sectors(len(nv)):>2} sectors) -> {nv_out}")
    print(f"split_kernel: gap between regions: "
          f"{nvk_base - vol_end - 1} bytes (not written to either image)")

    # ---- assemble the installable image ----------------------------
    # krnboot | volatile (sector-padded) | non-volatile
    #
    # Both sector counts are patched in HERE rather than by the
    # installers. Only the build knows where one image ends and the
    # next begins; an installer seeing just kernel-full.bin cannot
    # infer the split from the file size, which is all the old
    # single-image installers ever had to work with.
    boot = bytearray(open(krnboot_bin, "rb").read())
    if boot[0:3] != b"KRN":
        sys.exit(f"error: {krnboot_bin} has no 'KRN' signature")
    want = KRNBOOT_SECTORS * SECTOR_SIZE
    if len(boot) != want:
        sys.exit(f"error: {krnboot_bin} is {len(boot)} bytes, expected "
                 f"{want} ({KRNBOOT_SECTORS} sectors) -- keep the pad "
                 f"target in boot/krnboot.asm, KRNBOOT_SECTORS in "
                 f"boot/mbr.asm and sys/sys.c, and this tool in step")

    vol_sectors, nv_sectors = sectors(len(vol)), sectors(len(nv))
    for off, n, what in ((KVOL_CNT_OFFSET, vol_sectors, "volatile"),
                         (KNV_CNT_OFFSET, nv_sectors, "non-volatile")):
        if n > 0xFFFF:
            sys.exit(f"error: {what} image needs {n} sectors, max 65535")
        boot[off] = (n >> 8) & 0xFF
        boot[off + 1] = n & 0xFF

    # The volatile image is padded to a whole sector so the
    # non-volatile image starts exactly where krnboot's own LBA
    # arithmetic (which counts in sectors) expects it.
    vol_padded = vol + b"\x00" * (vol_sectors * SECTOR_SIZE - len(vol))
    open(full_out, "wb").write(bytes(boot) + vol_padded + nv)

    print(f"split_kernel: image {full_out}: krnboot {KRNBOOT_SECTORS} + "
          f"volatile {vol_sectors} + non-volatile {nv_sectors} = "
          f"{KRNBOOT_SECTORS + vol_sectors + nv_sectors} sectors")
    print(f"split_kernel: header counts patched -- "
          f"$4404={vol_sectors} (volatile), $4409={nv_sectors} (non-volatile)")


if __name__ == "__main__":
    main()
