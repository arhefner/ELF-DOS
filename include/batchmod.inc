;
; batchmod.inc - constants shared between kernel/batch.asm (the
; permanently kernel-resident dispatcher) and kernel/batch_mod.asm
; (the standalone, separately-built batch module). Restated on both
; sides rather than #included from one into the other, matching this
; project's own established convention for exactly this situation --
; see include/vollabel.inc/include/ymodem.inc for precedent.
;
; PHASE 1 (2026-07-30, test-machine-only, NOT for release): the module
; always loads to this same fixed, compile-time address. See
; kernel/batch_mod.asm's own header comment for the full reasoning and
; kernel/batch.asm's batch_mod_load for the runtime bounds check that
; refuses to load it if the current machine doesn't actually have this
; much RAM free above BATCHMOD_BASE right now.
;

BATCHMOD_BASE:          equ     $D000

; mem_top is clamped to this (BATCHMOD_BASE-1) for the duration a
; batch is active, then restored -- see kernel/batch.asm's own
; batch_mod_load/batch_mod_unclamp.
BATCHMOD_MEMTOP_CLAMP:  equ     BATCHMOD_BASE-1

; Fixed-offset entry table, right after the module's own 6-byte
; header (3-byte magic + version + 2 reserved, mirroring EDF's own
; header shape) -- each offset holds an LBR to the real body, which
; can move around within the module on a rebuild without needing the
; kernel's own dispatcher (which calls these fixed offsets directly,
; never the bodies themselves) to change at all.
MOD_START_OFF:      equ     6
MOD_READLINE_OFF:   equ     9
MOD_GOTO_OFF:       equ     12
