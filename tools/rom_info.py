#!/usr/bin/env python3
"""Report where the non-volatile kernel image belongs in ROM.

The kernel is split across two address regions (see include/memmap.inc).
The non-volatile half is all executable code and is never written after
load, so it can be burned into ROM. The build writes it out on its own as
kernel-rom.bin; this reports the address to burn it at, and how much room
is left under NVK_TOP.

Burning is OPTIONAL. The same bytes are also embedded in kernel-full.bin,
and krnboot loads them from disk when it does not find the signature
already present at NVK_BASE -- so a RAM-only machine boots from the card
alone. Putting the image in ROM is what frees the RAM it would otherwise
occupy.

The address is read from include/memmap.inc rather than hardcoded, so
moving NVK_BASE needs no change here.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from split_kernel import eval_equ, read_equs, repo_root, sectors  # noqa: E402


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: rom_info.py <kernel-rom.bin>")
    rom_path = sys.argv[1]

    os.chdir(repo_root())
    equs = read_equs("include/memmap.inc")
    nvk_base = eval_equ(equs["NVK_BASE"], equs)
    nvk_top = eval_equ(equs["NVK_TOP"], equs)
    sig_len = eval_equ(equs["NVK_SIG_LEN"], equs)

    if not os.path.isfile(rom_path):
        sys.exit(f"error: {rom_path} not found -- build first")

    rom = open(rom_path, "rb").read()
    if rom[0:3] != b"NVK":
        sys.exit(f"error: {rom_path} has no 'NVK' signature -- "
                 f"this is not a non-volatile kernel image")

    end = nvk_base + len(rom) - 1
    if end > nvk_top:
        sys.exit(f"error: image ends at ${end:04X}, past NVK_TOP "
                 f"(${nvk_top:04X}). Lower NVK_BASE and rebuild.")

    print()
    print("ROM image (optional -- the same code is on the card too)")
    print(f"  file      : {rom_path}")
    print(f"  BURN AT   : ${nvk_base:04X}")
    print(f"  occupies  : ${nvk_base:04X} - ${end:04X}"
          f"  ({len(rom)} bytes, {sectors(len(rom))} sectors)")
    print(f"  headroom  : {nvk_top - end} bytes free below NVK_TOP "
          f"(${nvk_top:04X})")
    print(f"  signature : {rom[0:3].decode()} v{rom[sig_len - 1]} at "
          f"${nvk_base:04X}, which is how krnboot detects it is already "
          f"present")
    print()
    print("  Burn it and krnboot skips loading it from disk, freeing the")
    print(f"  RAM at ${nvk_base:04X} and up. Leave it unburned and the kernel")
    print("  still boots -- krnboot loads this same image from the card.")
    print()


if __name__ == "__main__":
    main()
