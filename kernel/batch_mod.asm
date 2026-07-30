;
; batch_mod.asm - loadable batch-script module (phase 1: fixed load
; address, no relocation)
;
; NOT part of kernel.bin -- assembled and linked entirely separately,
; landing on disk as /bin/batch.mod. Loaded into RAM by the kernel's
; own dispatcher (kernel/batch.asm's batch_start/batch_readline/
; batch_goto, the jump-table-visible K_BATCH_* entry points) whenever
; a .bat script needs to run, freshly on every single K_BATCH_START --
; this file is never itself resident in the permanent kernel image.
;
; PHASE 1 DESIGN (test-machine-only, NOT for release): this module
; always loads to the same fixed, compile-time address, BATCHMOD_BASE
; ($D000, see include/batchmod.inc). Because that address is baked in
; at assemble time -- exactly like any ordinary progs/*.asm's own
; "org PROG_BASE" -- every internal branch and data reference here is
; a plain absolute address, resolved normally by the assembler/linker.
; No relocation fixups, no RB-relative addressing, nothing novel.
; PHASE 2 (not started) will make this genuinely relocatable so it can
; adapt to whatever RAM a real target system actually has; until then,
; this only works on a machine with enough RAM above BATCHMOD_BASE (the
; kernel-side loader checks this before ever touching $D000 -- see
; kernel/batch.asm's own batch_mod_load).
;
; What moved here from kernel/batch.asm (2026-07-30): batch_start,
; batch_readline, batch_goto, and their own private data (batch_fcb,
; batch_iobuf, batch_scratch, brl_count, batch_goto_label). What did
; NOT move (stays kernel-resident, unchanged): kernel_batch_args_reserve/
; kernel_batch_args_getarg/_batch_args_release and the %0-%9
; substitution's own himem reservation -- a clean, separate, already-
; small concern with no dependency on any of the data that moved.
;
; Two real behavior changes versus the original kernel-resident code,
; both because the kernel-side dispatcher is now the sole authority on
; "is a batch currently active" (a new 1-byte flag there, checked
; BEFORE this module is ever loaded/touched):
;   1. batch_start no longer does its own nesting check (used to test
;      batch_fcb's own FCB_F_OPEN bit) -- redundant now, since the
;      dispatcher already refuses a nested start before this module
;      would even be reloaded, and reading batch_fcb's own bytes here
;      would be unreliable anyway if the on-disk module file happens
;      to be shorter than its own reserved (ds-declared) data region
;      (nothing guarantees those bytes get overwritten by a partial
;      K_FILE_READ).
;   2. batch_readline/batch_goto's EOF/error/not-found paths no longer
;      call _batch_args_release themselves -- that's kernel-resident
;      state this module has no business touching directly; the
;      kernel-side dispatcher does it once it sees DF=1 come back from
;      here, alongside restoring mem_top (see kernel/batch.asm).
;
; file_open/file_read/file_close/file_seek's kernel-internal extrn
; linkage (only possible in kernel/batch.asm because that file is
; LINKED with the rest of the kernel) becomes ordinary K_FILE_OPEN/
; K_FILE_READ/K_FILE_CLOSE/K_FILE_SEEK jump-table calls here instead --
; this module is a standalone build, reaching kernel functionality the
; same way any ordinary program does. Mechanical substitution, checked
; against kernel_api.inc's own documented contracts: identical calling
; convention either way.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/batchmod.inc

BATCH_GOTO_LABEL_LEN: equ 32   ; generous headroom for a label name

            org     BATCHMOD_BASE

batchmod_header:
            db      'B','M','D'         ; batch-module magic (distinct
                                        ; from 'EDF' -- never runnable
                                        ; as an ordinary program)
            db      1                   ; module version
            dw      0                   ; reserved

; Fixed-offset entry table (BATCHMOD_BASE+MOD_START_OFF/READLINE_OFF/
; GOTO_OFF, include/batchmod.inc) -- insulates the kernel-side
; dispatcher's own fixed-offset calls from this module's real internal
; layout shifting on a rebuild. See this file's own header comment.
                lbr     batch_start         ; BATCHMOD_BASE + $06
                lbr     batch_readline      ; BATCHMOD_BASE + $09
                lbr     batch_goto          ; BATCHMOD_BASE + $0C

;------------------------------------------------------------------
; batch_start: open a batch script for reading. Nesting is NOT
; checked here -- see this file's own header comment for why (the
; kernel-side dispatcher is the sole gatekeeper now).
; Args:    RF = pointer to a null-terminated path, already resolved
;          (and confirmed to exist) by the caller.
; Returns: DF = 0 on success, DF = 1 if the open itself failed.
; Modifies: whatever K_FILE_OPEN modifies
;------------------------------------------------------------------
batch_start:
            mov     rd, batch_fcb       ; RD = our own FCB (RF, the
                                        ; incoming path argument, is
                                        ; untouched by this -- K_FILE_
                                        ; OPEN wants it there directly)
            mov     ra, batch_iobuf     ; RA = our own I/O buffer
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF = 0/1
            lbdf    bst_reject

            ; a NEW batch never inherits a PREVIOUS batch's echo-off
            ; mode -- RUN_BATCH_ECHO_OFF is deliberately NOT reset per
            ; command cycle (see kernel.inc's own comment), so this is
            ; the one place it needs a fresh reset
            mov     rf, RUN_BATCH_ECHO_OFF
            ldi     0
            str     rf

            clc
            rtn

bst_reject:
            stc
            rtn

;------------------------------------------------------------------
; batch_readline: fetch the next line of the active batch script.
; Args:    none (uses batch_fcb)
; Returns: DF = 0 with LINE_BUF holding the next line (null-
;          terminated, CR/LF stripped) if a line was available; DF = 1
;          if the batch just reached EOF (this module's own FCB is
;          closed in that case -- the kernel-side dispatcher handles
;          everything else that needs to happen on real batch-end).
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
;------------------------------------------------------------------
batch_readline:
            mov     rf, brl_count
            ldi     0
            str     rf                  ; brl_count = characters written to
                                        ; LINE_BUF so far this call. Kept
                                        ; in MEMORY, not a register --
                                        ; K_FILE_READ's own underlying
                                        ; file_read documents R9 (and
                                        ; every other register except
                                        ; D/DF) as clobbered, so no
                                        ; register survives the call to
                                        ; it below (see CLAUDE.md gotcha
                                        ; #10 for the hardware bug this
                                        ; discipline traces back to).

brl_loop:
            ; bounds check BEFORE reading another byte, so LINE_BUF's
            ; 128-byte buffer (see kernel_api.inc) is never overrun --
            ; leaves room for the forced NUL terminator
            mov     rf, brl_count
            ldn     rf                  ; D = brl_count
            smi     126
            lbdf    brl_term

            mov     rf, batch_scratch   ; RF = 1-byte read destination
            ldi     0
            phi     rc
            ldi     1
            plo     rc                  ; RC = 1 (read 1 byte)
            mov     rd, batch_fcb       ; RD = FCB pointer (fixed --
                                        ; RF/RC untouched)
            call    K_FILE_READ         ; RC = bytes read, DF = 0/1
            lbdf    brl_ioerr

            glo     rc
            lbz     brl_eof             ; 0 bytes: end of file

            mov     rf, batch_scratch
            ldn     rf                  ; D = the byte just read
            xri     13                  ; CR?
            lbz     brl_loop            ; skip it silently (handles
                                        ; both bare-LF and CRLF line
                                        ; endings with no extra state)

            mov     rf, batch_scratch
            ldn     rf                  ; D = the byte (reload -- xri
                                        ; above clobbered it)
            xri     10                  ; LF?
            lbz     brl_term            ; line complete

            ; append the byte to LINE_BUF at offset brl_count. R9 is
            ; rebuilt fresh from memory right here, immediately before
            ; use -- add16 itself doesn't clobber its second operand,
            ; only D/DF, so this is safe as long as nothing between this
            ; reload and the add16 below can touch R9 (nothing does).
            ldi     0
            phi     r9
            mov     rb, brl_count
            ldn     rb
            plo     r9                  ; R9 = brl_count (16-bit)
            mov     rf, LINE_BUF
            add16   rf, r9              ; RF = LINE_BUF + brl_count
            mov     rb, batch_scratch
            ldn     rb                  ; D = the byte (reload -- add16
                                        ; clobbered it)
            str     rf
            mov     rb, brl_count
            ldn     rb
            adi     1
            str     rb                  ; brl_count += 1
            lbr     brl_loop

brl_term:
            ldi     0
            phi     r9
            mov     rb, brl_count
            ldn     rb
            plo     r9
            mov     rf, LINE_BUF
            add16   rf, r9
            ldi     0
            str     rf                  ; null-terminate
            clc                         ; DF = 0: got a line
            rtn

brl_eof:
            ; if any characters were accumulated this call, return them
            ; as a final, unterminated line -- the NEXT call will hit
            ; EOF again with a fresh (zero) count and close for real
            mov     rf, brl_count
            ldn     rf
            lbnz    brl_term

            mov     rd, batch_fcb
            call    K_FILE_CLOSE
            mov     rf, batch_fcb
            ldi     0
            str     rf                  ; FCB_FLAGS = 0
            stc                         ; DF = 1: no line
            rtn

brl_ioerr:
            ; a real I/O error mid-batch: treat the same as EOF --
            ; close, clear state, report "no line"
            mov     rd, batch_fcb
            call    K_FILE_CLOSE
            mov     rf, batch_fcb
            ldi     0
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; batch_goto: reposition the active batch script to just after a
; labeled line -- see kernel_api.inc's own K_BATCH_GOTO doc comment
; for the full contract.
; Args:    RF = pointer to a null-terminated label name, no leading ':'
; Returns: DF = 0/1 -- see K_BATCH_GOTO's own doc
; Modifies: everything (calls batch_readline repeatedly, which itself
;           has a broad footprint)
;------------------------------------------------------------------
batch_goto:
            ; copy the label into this module's own resident memory
            ; FIRST, before anything below (K_FILE_SEEK, then
            ; batch_readline's own scan loop) can touch the caller's
            ; own buffer -- typically argv[1], living in the shell's
            ; LINE_BUF, which batch_readline overwrites on every call
            mov     rd, batch_goto_label
            ldi     BATCH_GOTO_LABEL_LEN - 1   ; leave room for a
                                                ; forced terminator
            plo     rc
bg_copy_loop:
            glo     rc
            lbz     bg_copy_term
            lda     rf
            str     rd
            lbz     bg_copy_done        ; copied the source's own NUL
            inc     rd
            dec     rc
            lbr     bg_copy_loop
bg_copy_term:
            ldi     0
            str     rd
bg_copy_done:

            ; rewind to the start of the file -- GOTO always rewinds
            ; and scans forward, regardless of whether the label is
            ; before or after the current position
            mov     rd, batch_fcb
            ldi     0
            plo     rc                  ; RC.0 = 0 (SEEK_SET)
            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9                  ; RA:R9 = 0 (offset 0)
            call    K_FILE_SEEK
            lbdf    bg_notfound         ; seek itself failed -- shouldn't
                                        ; normally happen on an already-
                                        ; open file, but there's no
                                        ; other sane response

bg_scan_loop:
            call    batch_readline      ; DF=0: LINE_BUF has the next
                                        ; line; DF=1: real EOF (this
                                        ; module's own FCB already
                                        ; closed -- see its own header)
            lbdf    bg_notfound

            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char

            ldn     rf
            xri     ':'
            lbnz    bg_scan_loop        ; not a label line: keep going

            inc     rf                  ; RF = label text, right after ':'

            ; case-insensitive whole-word compare against
            ; batch_goto_label -- see the original kernel/batch.asm's
            ; own history for why the blind "ani $DF" fold is accepted
            ; here (both sides are arbitrary label text; a same-mask
            ; collision would need to be deliberately constructed)
            mov     rd, batch_goto_label
bg_cmp_loop:
            ldn     rd
            lbz     bg_cmp_checkend     ; pattern exhausted -- the
                                        ; candidate label must ALSO end
                                        ; here (space or NUL) for a
                                        ; real match
            ani     $DF
            str     r2
            ldn     rf
            ani     $DF
            xor
            lbnz    bg_scan_loop        ; mismatch: not this label,
                                        ; keep scanning
            inc     rd
            inc     rf
            lbr     bg_cmp_loop

bg_cmp_checkend:
            ldn     rf
            lbz     bg_found            ; NUL: whole-word match
            xri     ' '
            lbz     bg_found            ; space: whole-word match
            lbr     bg_scan_loop        ; e.g. ":endx" when looking for
                                        ; "end" -- not a match

bg_found:
            clc                         ; DF = 0: label found, batch_fcb
                                        ; is already positioned right
                                        ; after this line (batch_readline's
                                        ; own normal side effect)
            rtn

bg_notfound:
            stc                         ; DF = 1
            rtn

;------------------------------------------------------------------
; Module-private data
;------------------------------------------------------------------
batch_fcb:      ds      FCB_LEN
batch_iobuf:    ds      FCB_IOBUF_LEN
batch_scratch:  db      0           ; 1-byte read scratch for
                                    ; batch_readline's byte-at-a-time
                                    ; loop
brl_count:      db      0           ; characters written to LINE_BUF so
                                    ; far in the current batch_readline
                                    ; call
batch_goto_label: ds    BATCH_GOTO_LABEL_LEN   ; batch_goto's own copy
                                    ; of the target label name, taken
                                    ; before its scan loop starts
                                    ; overwriting LINE_BUF

            end     batchmod_header
