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
; The default targets a 32K RAM + 32K ROM machine: RAM $0000-$7FFF,
; ROM $8000-$FFFF. Deliberately the SAME numbers on a RAM-only
; development machine, where krnboot simply loads the non-volatile
; image into RAM at $8000 -- so the memory map a dev box exercises is
; byte-for-byte the map a ROM machine gets, and hardware testing on
; one genuinely validates the other.
;
NVK_BASE:       equ     $8000       ; start of the non-volatile kernel
NVK_TOP:        equ     $FFFF       ; ceiling; build fails if exceeded

; Signature krnboot checks to decide "is the non-volatile kernel
; already here (ROM), or must I load it from disk (RAM)?". Sits at
; NVK_BASE itself, ahead of any code -- see kernel/nvhdr.asm.
NVK_SIG_LEN:    equ     4           ; 'N','V','K' + version byte
NVK_SIG_VER:    equ     1
