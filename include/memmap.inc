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
; ONE TRAP LEFT, and one that has been closed:
;
; CLOSED -- krnboot used to load WHOLE sectors, writing up to 511 bytes
;   past the image. At NVK_BASE=$BD00 that reached $F000, inside the
;   EEPROM. A write there starts an internal write cycle that takes the
;   whole chip offline for milliseconds; the BIOS lives in that chip, so
;   the next SCRT return fetched a busy chip, ran garbage, and the
;   machine hung at boot with no output at all. krnboot now reads the
;   final sector into boot_scratch and copies out only the bytes the
;   image occupies, so the load writes exactly len(image) bytes and
;   cannot touch anything above NVK_BASE + size - 1. Placement no longer
;   has to be chosen to dodge that. (If that buffered copy is ever
;   removed, both build checks must go back to measuring the rounded-up
;   span -- they say so in their own comments.)
;
; STILL LIVE -- base + size is NOT constant. -r relaxation shortens a
;   long branch only when source and target share a 256-byte page, so
;   moving NVK_BASE shifts every proc and flips branches either way:
;   measured sizes ranged 12905-12919 bytes across bases only 144 apart,
;   and $BD90 -- which arithmetic said would end exactly at $EFFE --
;   actually overran by 5. Always trust the built figure, never the
;   computed one.
;
; $BC40 (2026-09-11: $BE00 -> $BCE0 for buffered output redirection, then
; -> $BC40 on this branch for FAT12, which adds ~284 bytes of non-volatile
; code). See check_kernel_margin.py's report for the current headroom. $BE00 ended at $EEC6, 313 bytes below NVK_TOP --
; deliberately close.
; Program RAM is the whole point of this layout, and overshooting is now
; a loud build failure rather than a silent hang, so thin headroom costs
; a rebuild rather than a hardware round. Expect to re-tune this after
; any real kernel addition; drop to $BD00 (569 bytes clear) if the
; re-tuning gets tiresome.
;
; NOTE, so nobody re-derives it the hard way: on THIS machine the split
; is roughly RAM-neutral for programs. The old layout put the kernel
; below PROG_BASE=$4000 and ran programs up to f_freemem-128; the new
; one puts programs at $0D00 and the kernel above them. The kernel is
; the same size either way, so relocating it does not create space --
; it just moves the hole. The real win is on a machine with usable ROM
; (32K RAM + 32K ROM, NVK_BASE $8000 / NVK_TOP $FFFF), where the kernel
; leaves RAM entirely and programs gain its whole ~12.9K.
;
NVK_BASE:       equ     $BC40       ; start of the non-volatile kernel
NVK_TOP:        equ     $EFFF       ; ceiling; build fails if exceeded

; Signature krnboot checks to decide "is the non-volatile kernel
; already here (ROM), or must I load it from disk (RAM)?". Sits at
; NVK_BASE itself, ahead of any code -- see kernel/nvhdr.asm.
NVK_SIG_LEN:    equ     4           ; 'N','V','K' + version byte
NVK_SIG_VER:    equ     1
