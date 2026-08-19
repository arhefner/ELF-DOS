;
; batch_mod.asm - loadable batch-script module (phase 2: genuinely
; relocatable, loads wherever lib/modload.asm's mod_load can find room)
;
; NOT part of kernel.bin -- assembled and linked entirely separately,
; landing on disk as /bin/batch.mod. Loaded into RAM by the kernel's
; own dispatcher (kernel/batch.asm's batch_start/batch_readline/
; batch_goto, the jump-table-visible K_BATCH_* entry points) whenever
; a .bat script needs to run, freshly on every single K_BATCH_START --
; this file is never itself resident in the permanent kernel image.
;
; PHASE 2 DESIGN (2026-07-31, supersedes the original fixed-$D000
; Phase 1): built `org $0000` and linked with Link/02's own "-m"
; module output mode (see the project's own design plan and
; lib/modload.asm's header for the full mechanism) -- every internal
; branch/call/data reference here is expressed relative to address 0,
; and gets fixed up once at LOAD time by lib/modload.asm's mod_load,
; not baked in at build time the way Phase 1's fixed BATCHMOD_BASE
; was. This is what makes the module adapt to whatever RAM a real
; target system actually has, rather than only working on a machine
; with room free above a hardcoded address. The kernel-side dispatcher
; (kernel/batch.asm) now calls mod_load/mod_release instead of doing
; its own fixed-address bounds check, and reaches this module's own
; entry points via lib/icall.asm's indirect call (module_base is only
; known at runtime) instead of a plain LBR to a compile-time constant.
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
#include    include/modformat.inc

BATCH_GOTO_LABEL_LEN: equ 32   ; generous headroom for a label name

; Restructured into real proc/endp blocks (2026-07-31, Phase 2) --
; Phase 1 was flat (progs-style), which worked fine for a fixed
; compile-time address, but Link/02's own relocation/fixup machinery
; (both the pre-existing -r short-branch relaxation and the new -m
; module output mode this Phase depends on) only ever tracks
; references that cross a proc boundary -- a flat file's own internal
; branches/calls are fully resolved by Asm/02 itself at assemble time,
; with nothing left for Link/02 to fix up at load time. Confirmed
; directly: an early build of this exact restructuring, still flat,
; linked with "-m" and reported zero fixups for the whole module --
; not because there was nothing to relocate, but because nothing was
; ever being tracked as relocatable in the first place. Every routine
; here is now its own proc; the shared data lives in its own data
; proc, matching kernel/*.asm's own established convention (and
; CLAUDE.md gotcha #20's warning against bare top-level content mixed
; with proc/endp blocks in the same file).
            extrn   batch_start
            extrn   batch_readline
            extrn   batch_goto
            extrn   batch_fcb
            extrn   batch_iobuf
            extrn   batch_scratch
            extrn   brl_count
            extrn   batch_goto_label

            org     0

            proc    _batchmod_header

batchmod_header:
            db      MOD_MAGIC0, MOD_MAGIC1, MOD_MAGIC2  ; distinct from
                                        ; both 'EDF' (never runnable as
                                        ; an ordinary program) and
                                        ; Phase 1's own 'BMD' (the
                                        ; on-disk FORMAT changed --
                                        ; Phase 1 has no code_size
                                        ; field and no trailing fixup
                                        ; table, so a loader for one
                                        ; format must never
                                        ; misinterpret the other)
            db      MOD_VERSION
            dw      0                   ; code_size -- patched directly
                                        ; into the output file by
                                        ; Link/02's own "-m" mode (see
                                        ; include/modformat.inc); this
                                        ; source-level placeholder is
                                        ; never the real value

; Fixed-offset entry table (module_base+MOD_START_OFF/READLINE_OFF/
; GOTO_OFF, include/batchmod.inc, unchanged from Phase 1 -- the header
; is still exactly MOD_HEADER_LEN=6 bytes) -- insulates the kernel-side
; dispatcher's own fixed-offset calls from this module's real internal
; layout shifting on a rebuild. Each entry is an ordinary LBR, fixed up
; like any other internal reference at load time -- the dispatcher
; reaches these via lib/icall.asm (module_base + MOD_*_OFF, computed at
; runtime), not a direct call, since it can't know module_base at its
; own compile time. See this file's own header comment.
                lbr     batch_start         ; module_base + $06
                lbr     batch_readline      ; module_base + $09
                lbr     batch_goto          ; module_base + $0C

            endp

;------------------------------------------------------------------
; batch_start: open a batch script for reading. Nesting is NOT
; checked here -- see this file's own header comment for why (the
; kernel-side dispatcher is the sole gatekeeper now).
; Args:    RF = pointer to a null-terminated path, already resolved
;          (and confirmed to exist) by the caller.
; Returns: DF = 0 on success, DF = 1 if the open itself failed.
; Modifies: whatever K_FILE_OPEN modifies
;------------------------------------------------------------------
            proc    batch_start

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

            endp

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
            proc    batch_readline

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

brl_ioerr:
            ; a real I/O error mid-batch: treat the same as EOF --
            ; close, clear state, report "no line". Reached both from
            ; a genuine K_FILE_READ error (via the lbdf above) and by
            ; falling straight through from brl_eof's own zero-count
            ; case immediately above (2026-08-01 size-reduction pass:
            ; both used to carry this exact 7-instruction tail
            ; verbatim -- hoisted into one shared copy, reached by
            ; fallthrough from one caller and an explicit lbdf from
            ; the other, with no behavior change).
            mov     rd, batch_fcb
            call    K_FILE_CLOSE
            mov     rf, batch_fcb
            ldi     0
            str     rf
            stc
            rtn

            endp

;------------------------------------------------------------------
; batch_goto: reposition the active batch script to just after a
; labeled line -- see kernel_api.inc's own K_BATCH_GOTO doc comment
; for the full contract.
; Args:    RF = pointer to a null-terminated label name, no leading ':'
; Returns: DF = 0/1 -- see K_BATCH_GOTO's own doc
; Modifies: everything (calls batch_readline repeatedly, which itself
;           has a broad footprint)
;------------------------------------------------------------------
            proc    batch_goto

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

            endp

;------------------------------------------------------------------
; Module-private data
;------------------------------------------------------------------
            proc    _batchmod_data

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

; REAL BUG FOUND AND FIXED (2026-08-18, batch-hang investigation):
; batch_goto_label, being the module's own LAST declared field and a
; "ds" (uninitialized) region, was never counted in Link/02's own
; "highest address" tracking -- that tracking only ever counts bytes
; actually WRITTEN to memory[], and a trailing ds never writes
; anything. Since Link/02's "-m" (module) mode computes code_size as
; highest-lowest+1, this meant code_size silently stopped 32 bytes
; (BATCH_GOTO_LABEL_LEN) short of the module's own real footprint --
; confirmed by direct byte-decode of a rebuilt bin/batch.mod's own
; 6-byte header (code_size=0x036b, exactly batch_goto_label's own
; start address, not its end).
;
; This matters because mod_load's own reservation is code_size +
; MOD_RESERVE_PAD (255, meant ONLY to cover page-alignment slack, per
; its own header comment -- not to cover missing module data). The
; actual usable space beyond code_size after page-alignment varies
; from 0 to 255 bytes depending on mem_top's own low byte at the exact
; moment of reservation (0 in the worst case, when mem_top+1's low
; byte is 1). In that worst case, batch_goto_label's own 32-byte
; buffer would land entirely OUTSIDE the reserved himem region,
; silently corrupting whatever real RAM sits just above it -- and
; since that worst case depends on mem_top's own value at that exact
; moment (itself dependent on prior himem reservation/release history
; this same boot session, not on this module's own code at all), it
; could plausibly manifest differently across builds that changed
; kernel size elsewhere for entirely unrelated reasons.
;
; Fixed by writing one explicit byte immediately after
; batch_goto_label's own 32-byte span -- forcing Link/02 to see that
; address as genuinely written, extending "highest address" (and thus
; code_size) to correctly cover the buffer's full real extent. No
; symbol needed; nothing ever reads this byte's own value.
                db      0

                public  batch_fcb
                public  batch_iobuf
                public  batch_scratch
                public  brl_count
                public  batch_goto_label

            endp

            end     batchmod_header
