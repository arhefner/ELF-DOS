;
; batchmod.inc - constants shared between kernel/batch.asm (the
; permanently kernel-resident dispatcher) and kernel/batch_mod.asm
; (the standalone, separately-built batch module). Restated on both
; sides rather than #included from one into the other, matching this
; project's own established convention for exactly this situation --
; see include/vollabel.inc/include/ymodem.inc for precedent.
;
; PHASE 1 (2026-07-30) loaded the module to a fixed, compile-time
; address ($D000) -- test-machine-only, since a fixed high address has
; no way to adapt to a smaller/different system. PHASE 2 (2026-07-31)
; replaced this with genuine relocation via lib/modload.asm's
; mod_load, which finds a page-aligned home via K_HIMEM_RESERVE at
; runtime instead -- see kernel/batch_mod.asm's own header comment and
; the project's own design plan for the full mechanism. The old
; BATCHMOD_BASE/BATCHMOD_MEMTOP_CLAMP constants no longer have any
; real use anywhere in this project (removed, not left as dead code) --
; kernel/batch.asm's own batch_mod_load/batch_mod_unclamp now just
; forward to mod_load/mod_release, which handle both the load address
; and the headroom bounds-check internally.
;

; Fixed-offset entry table, right after the module's own 6-byte
; header (3-byte magic + version + 2-byte code_size, mirroring EDF's
; own header shape, see include/modformat.inc) -- each offset holds an
; LBR to the real body, which can move around within the module on a
; rebuild without needing the kernel's own dispatcher (which calls
; these fixed offsets, relative to the module's own runtime base
; address, never the bodies themselves) to change at all.
MOD_START_OFF:      equ     6
MOD_READLINE_OFF:   equ     9
MOD_GOTO_OFF:       equ     12
