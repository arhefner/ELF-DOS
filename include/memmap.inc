;
; memmap.inc - split memory model: volatile vs non-volatile kernel
;
; Include in any kernel/boot source that needs to know where the
; non-volatile kernel lives.
;
; ----------------------------------------------------------------
; The split
; ----------------------------------------------------------------
; The kernel is linked as ONE image but placed in TWO address regions:
;
;   $0100 .. (volatile top)   VOLATILE  -- must be RAM
;       EDF header + the K_* jump table (kernel/kernel.asm), plus every
;       module's _*_data proc (kernel/*_data.asm, lib/modload_data.asm).
;       The jump table is RAM-resident by necessity, not convenience:
;       _patch_io_vector (kernel/redir.asm) REWRITES the K_TYPE/K_READ
;       slots at boot, and I/O redirection rewrites them again at run
;       time. Loaded from disk on every boot (it carries real initial
;       values, e.g. fat_csec=$FFFF, not just reserved space).
;
;   NVK_BASE .. NVK_TOP       NON-VOLATILE -- may be ROM
;       All executable kernel code. Never written after load, so it can
;       be burned into ROM. On a ROM machine krnboot finds the signature
;       already present and skips loading it; on a RAM-only machine the
;       signature is absent and krnboot loads it from disk to the very
;       same address.
;
; Cross-references between the regions resolve normally because both
; are produced by a SINGLE link -- the volatile objects are listed
; first (so they land at $0100), then nvhdr.prg carries an absolute
; "org NVK_BASE" that moves the linker's placement cursor, and every
; code object listed after it lands in the non-volatile region.
;
; ----------------------------------------------------------------
; Choosing NVK_BASE / NVK_TOP
; ----------------------------------------------------------------
; NVK_BASE is the region's START; NVK_TOP is the highest address it is
; allowed to reach (a ceiling that tools/check_kernel_margin.py
; enforces -- it is NOT used to derive NVK_BASE today; see the branch
; notes for the planned NVK_TOP -> NVK_BASE auto-derivation).
;
; Currently set for a 60K RAM + 4K ROM machine: RAM $0000-$EFFF, ROM
; from $F000. NVK_TOP is the last RAM byte, NOT the last address --
; krnboot must never write above it (see trap 1 below). The non-volatile kernel is loaded into high RAM every
; boot (there is no room for it in a 4K ROM), so NVK_BASE is placed as
; HIGH as it can go -- every byte it moves up is a byte of program RAM
; handed back below it.
;
; PICKING NVK_BASE BY HAND (see the branch notes on the deferred
; NVK_TOP -> NVK_BASE auto-derivation):
;
;   1. Build. check_kernel_margin.py reports the non-volatile region's
;      real span and its headroom under NVK_TOP.
;   2. If it FAILS (region past NVK_TOP), lower NVK_BASE and rebuild.
;      If headroom is large, raise it.
;
; TWO TRAPS, both of which have already cost a hardware round:
;
; 1. krnboot loads WHOLE SECTORS. The last one is written in full even
;    when the image only partly fills it, so the load reaches up to 511
;    bytes past the image's own end. NVK_BASE=$BD00 put the image at
;    $BD00-$EF6E, comfortably under $EFFF -- but the load wrote through
;    $F0FF, 256 bytes into ROM, and the machine hung at boot with no
;    output whatsoever. The constraint is on the SECTOR-ROUNDED span:
;
;      NVK_BASE + ceil(size/512)*512 - 1  <=  NVK_TOP
;
;    tools/check_kernel_margin.py now enforces exactly this, and reports
;    the address krnboot really writes through. Trust that line.
;
; 2. base + size is NOT constant. -r relaxation shortens a long branch
;    only when source and target share a 256-byte page, so moving
;    NVK_BASE shifts every proc and flips branches either way: measured
;    sizes ranged 12905-12919 bytes across bases only 144 apart, and
;    $BD90 -- which arithmetic said would end exactly at $EFFE --
;    actually overran by 5. Always trust the built figure.
;
; $BA00 leaves a full 512-byte sector of headroom on the load span
; (26 sectors reach $EDFF, against a $EFFF ceiling). $BC00 would be the
; highest base that fits today, but with ZERO margin: one more byte of
; kernel would tip it to 27 sectors and silently reproduce trap 1. A
; whole spare sector costs 512 bytes of program RAM out of ~44,000
; (1.2%) and buys immunity to exactly the failure that has already
; happened once.
;
; For a 32K RAM + 32K ROM machine, use NVK_BASE $8000 / NVK_TOP $FFFF:
; the kernel then sits in ROM, krnboot finds the signature already
; present and skips loading it entirely.
;
NVK_BASE:       equ     $BA00       ; start of the non-volatile kernel
NVK_TOP:        equ     $EFFF       ; ceiling; build fails if exceeded

; Signature krnboot checks to decide "is the non-volatile kernel
; already here (ROM), or must I load it from disk (RAM)?". Sits at
; NVK_BASE itself, ahead of any code -- see kernel/nvhdr.asm.
NVK_SIG_LEN:    equ     4           ; 'N','V','K' + version byte
NVK_SIG_VER:    equ     1
