;
; batch.asm - minimal flat (non-nested) batch script execution
;
; The shell (progs/shell.asm) is reloaded fresh from disk on every
; single command cycle -- it has no memory of its own that survives
; from one prompt to the next. A batch script needs to remember "which
; file, how far in" across many such reloads (one per line executed),
; so that state has to live here, in permanently kernel-resident
; memory, the same reason cur_dir/cur_drive do.
;
; Design: the kernel owns one dedicated FCB+I/O buffer (batch_fcb/
; batch_iobuf, exactly the same shape prog_fcb/prog_iobuf already use
; for program loading -- can't just reuse those, since a batch file
; stays open across many command cycles while EACH of those commands
; independently loads+runs its own program through prog_fcb, so both
; need to be open at once). batch_start opens a file into it;
; batch_readline pulls one line at a time into LINE_BUF, auto-closing
; on EOF. FCB_FPOS (inside batch_fcb) already tracks the resume
; position for free, since batch_fcb is a fixed, persistent address --
; no separate "resume position" field is needed. FCB_FLAGS' FCB_F_OPEN
; bit doubles as the "is a batch currently active" signal, so no
; separate flag is needed either.
;
; Nesting is deliberately unsupported (batch_start rejects a second
; start while one is already active) -- the user confirmed flat/non-
; nested batch files are sufficient for 1.0 (see project notes).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   file_open
            extrn   file_read
            extrn   file_close
            extrn   file_seek

; cross-file references into kernel/redir.asm -- the same shared
; himem-reservation mechanism kernel/glob.asm already uses (see
; kernel_batch_args_reserve's own comment below for why this file
; reuses it rather than inventing a new one)
            extrn   _himem_reserve
            extrn   _himem_release
            extrn   mem_top

; same-file cross-proc data references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   batch_fcb
            extrn   batch_iobuf
            extrn   batch_scratch
            extrn   brl_count
            extrn   batch_goto_label
            extrn   batch_args_reserved
            extrn   batch_args_empty

; same-file cross-proc CODE reference (batch_goto calls batch_readline
; directly, reusing its line-reading loop rather than duplicating it)
            extrn   batch_readline
            extrn   _batch_args_release

BATCH_GOTO_LABEL_LEN: equ 32   ; generous headroom for a label name

; ----------------------------------------------------------------
; batch_start: begin executing a batch script.
; Args:    RF = pointer to a null-terminated path, already resolved
;          (and confirmed to exist) by the caller -- see
;          progs/shell.asm's own K_STAT check before calling this.
; Returns: DF = 0 on success (a batch is now active; the next call to
;          batch_readline will return its first line), DF = 1 if a
;          batch is already active (nesting isn't supported) or the
;          open itself failed
; Modifies: whatever file_open modifies, plus R9
; ----------------------------------------------------------------
            proc    batch_start

            mov     rd, rf              ; RD = path (preserve the
                                        ; caller's argument across the
                                        ; nesting check below, which
                                        ; needs RF as scratch)

            mov     rf, batch_fcb
            ldn     rf
            ani     FCB_F_OPEN
            lbnz    bst_reject          ; already active: reject

            mov     rf, rd              ; RF = path (restored)
            mov     rd, batch_fcb       ; RD = our own FCB (K_FILE_OPEN's
                                        ; own caller-FCB argument)
            mov     ra, batch_iobuf     ; RA = our own I/O buffer
            ldi     0                   ; mode = read
            call    file_open           ; DF = 0/1 (D unspecified --
                                        ; batch_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    bst_reject

            ; a NEW batch never inherits a PREVIOUS batch's echo-off
            ; mode -- RUN_BATCH_ECHO_OFF is deliberately NOT reset per
            ; command cycle (see kernel.inc's own comment), so this is
            ; the one place it needs a fresh reset
            mov     rf, RUN_BATCH_ECHO_OFF
            ldi     0
            str     rf

            clc                         ; DF = 0, success
            rtn

bst_reject:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; batch_readline: fetch the next line of the active batch script.
; Args:    none (uses batch_fcb)
; Returns: DF = 0 with LINE_BUF holding the next line (null-
;          terminated, CR/LF stripped) if a batch is active and a line
;          was available; DF = 1 if no batch is active, or the batch
;          just reached EOF (the FCB is closed and batch state cleared
;          in that case, so the caller's very next command cycle goes
;          back to reading from the console automatically)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    batch_readline

            mov     rf, batch_fcb
            ldn     rf
            ani     FCB_F_OPEN
            lbz     brl_inactive        ; not open: no batch active

            mov     rf, brl_count
            ldi     0
            str     rf                  ; brl_count = characters written to
                                        ; LINE_BUF so far this call. Kept
                                        ; in MEMORY, not a register --
                                        ; file_read's own header documents
                                        ; R9 (and every other register
                                        ; except D/DF) as clobbered, so no
                                        ; register survives the call to it
                                        ; below. This was the real bug
                                        ; behind the batch-script garbage
                                        ; output found on hardware
                                        ; 2026-07-15: R9 used to hold this
                                        ; count across that exact call, and
                                        ; file_read stomped it on every
                                        ; single byte read. See CLAUDE.md
                                        ; gotcha #10.

brl_loop:
            ; bounds check BEFORE reading another byte, so LINE_BUF's
            ; 128-byte buffer (see kernel.inc) is never overrun --
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
                                        ; RF/RC untouched, matching the
                                        ; old comment's own reasoning)
            call    file_read           ; RC = bytes read, DF = 0/1
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
            call    file_close
            mov     rf, batch_fcb
            ldi     0
            str     rf                  ; FCB_FLAGS = 0 -- "no batch
                                        ; active" from here on
            call    _batch_args_release ; no-op if %N support was never
                                        ; reserved for this batch --
                                        ; releases the dynamic himem
                                        ; reservation (if any) at the
                                        ; same point the batch itself
                                        ; is torn down, so it can never
                                        ; leak across batches run back
                                        ; to back in one session
brl_inactive:
            stc                         ; DF = 1: no line
            rtn

brl_ioerr:
            ; a real I/O error mid-batch: treat the same as EOF --
            ; close, clear state, report "no line" -- rather than
            ; leaving the batch wedged open with no way to advance
            mov     rd, batch_fcb
            call    file_close
            mov     rf, batch_fcb
            ldi     0
            str     rf
            call    _batch_args_release ; same reasoning as the real
                                        ; EOF path above
            stc
            rtn

            endp

; ----------------------------------------------------------------
; batch_goto: reposition the active batch script to just after a
; labeled line -- see kernel_api.inc's own K_BATCH_GOTO doc comment
; for the full contract.
; Args:    RF = pointer to a null-terminated label name, no leading ':'
; Returns: DF = 0/1 -- see K_BATCH_GOTO's own doc
; Modifies: everything (calls batch_readline repeatedly, which itself
;           has a broad footprint)
; ----------------------------------------------------------------
            proc    batch_goto

            ; copy the label into kernel-resident memory FIRST, before
            ; anything below (file_seek, then batch_readline's own
            ; scan loop) can touch the caller's own buffer -- typically
            ; argv[1], living in the shell's LINE_BUF, which
            ; batch_readline overwrites on every single call
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
            ; before or after the current position; simpler than
            ; tracking direction, and batch scripts are small enough
            ; that a full rescan is cheap
            mov     rd, batch_fcb
            ldi     0
            plo     rc                  ; RC.0 = 0 (SEEK_SET)
            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9                  ; RA:R9 = 0 (offset 0)
            call    file_seek
            lbdf    bg_notfound         ; seek itself failed -- shouldn't
                                        ; normally happen on an already-
                                        ; open file, but there's no
                                        ; other sane response

bg_scan_loop:
            call    batch_readline      ; DF=0: LINE_BUF has the next
                                        ; line; DF=1: real EOF (batch
                                        ; already closed -- see this
                                        ; proc's own header)
            lbdf    bg_notfound

            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char

            ldn     rf
            xri     ':'
            lbnz    bg_scan_loop        ; not a label line: keep going

            inc     rf                  ; RF = label text, right after ':'

            ; case-insensitive whole-word compare against
            ; batch_goto_label. Blind "ani $DF" on BOTH sides -- safe
            ; for realistic label names (letters/digits/underscore/
            ; hyphen: verified by hand that none of those collide under
            ; this mask, since a mask collision only ever pairs a
            ; letter with its own opposite case). NOT safe in general
            ; for arbitrary symbol characters (e.g. '@' and '`' collide
            ; under this mask) -- accepted, unlike the %ERRORLEVEL%
            ; bug this mirrors the shape of: there, the FIXED pattern
            ; itself contained '%', a real, load-bearing character that
            ; broke silently; here, both sides are arbitrary label text
            ; and a collision only mis-jumps to a same-mask label
            ; someone would have to deliberately construct.
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

; ----------------------------------------------------------------
; kernel_batch_args_reserve: K_BATCH_ARGS_RESERVE's jump-table target
; -- %0-%9 batch-argument substitution (2026-07-25). See
; kernel_api.inc's own doc comment for the full contract. Mirrors
; kernel/glob.asm's own kernel_glob_reserve almost exactly, reusing the
; same shared _himem_reserve/_himem_release mechanism (kernel/redir.asm)
; rather than inventing a new reservation routine -- that mechanism is
; already length-parameterized, flag-agnostic, and already proven safe
; with multiple simultaneous callers (this file's own reservation can
; be active at the same time as a per-command dual-redirect or glob
; reservation, nested, with no special handling needed here).
;
; Deliberately NOT idempotent like K_GLOB_RESERVE: this is only ever
; called once per batch, right after K_BATCH_START succeeds, and
; starting a new batch while one is already active is already rejected
; (nested batch) before this could ever be reached twice without a
; release in between.
;
; Population (packing the actual argument text/pointers into the
; reserved block) is deliberately NOT done here -- it happens shell-
; side, in progs/shell.asm's own is_batch:, which already has
; RUN_ARGV_TABLE/RUN_ARGC in hand. This proc's only job is reserving
; the space and handing back where it starts.
;
; Args:    none
; Returns: DF = 0 on success, RD = base address (mem_top + 1); DF = 1
;          if there isn't enough RAM headroom (nothing changed)
; Modifies: RC, RD, RF
; ----------------------------------------------------------------
            proc    kernel_batch_args_reserve

            ldi     high BATCH_ARGS_RESERVE_LEN
            phi     rc
            ldi     low BATCH_ARGS_RESERVE_LEN
            plo     rc
            call    _himem_reserve
            lbdf    kbar_fail

            mov     rf, batch_args_reserved
            ldi     $FF
            str     rf

            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; RD = mem_top + 1
            clc
            rtn

kbar_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; kernel_batch_args_getarg: K_BATCH_ARGS_GETARG's jump-table target.
; See kernel_api.inc's own doc comment for the full contract.
; Bounds-checks the requested index against the reservation's own
; stored count (BATCH_ARGS_ARGC_OFF, populated once by the shell at
; reserve time) BEFORE ever touching the pointer table -- so this can
; never return a pointer into an unpopulated BATCH_ARGV slot, which
; could otherwise hold leftover RAM garbage from before the
; reservation was made.
;
; Args:    D = index (0-9)
; Returns: DF = 0 in every case where a reservation is currently
;          active: RF = the real argument's pointer (index < the
;          stored count), or RF = batch_args_empty (index >= the
;          stored count -- a fixed, always-valid empty string, never a
;          read of the unpopulated slot). DF = 1 only when NO
;          reservation is active at all.
; Modifies: R8, R9, RF
; ----------------------------------------------------------------
            proc    kernel_batch_args_getarg

            plo     r8                  ; R8.0 = the requested index,
                                        ; stashed before D gets reused
                                        ; below (gotcha #4)

            mov     rf, batch_args_reserved
            ldn     rf
            lbz     kbag_inactive

            mov     rf, mem_top
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            inc     r9                  ; R9 = base = mem_top + 1

            ; REAL BUG, found on hardware 2026-07-25: SM computes
            ; D = D - M(R(X)), NOT M(R(X)) - D -- confirmed against
            ; _himem_reserve's own hardware-proven comparison
            ; (kernel/redir.asm), whose own "DF=0 means new_mem_top <
            ; mem_base" comment only makes sense under this polarity.
            ; The first draft staged the MINUEND (index) into M(R2)
            ; and loaded the SUBTRAHEND (count) into D last -- backwards.
            ; That silently computed count-index instead of
            ; index-count, so an IN-RANGE index (count > index, no
            ; borrow) wrongly took the "empty" branch, while the
            ; OUT-OF-RANGE index (count < index, borrow) wrongly fell
            ; into the "real arg" branch and read an uninitialized
            ; BATCH_ARGV slot -- the wild pointer that produced garbled
            ; console output on the very first hardware round. Fixed by
            ; staging the SUBTRAHEND (count) first and loading the
            ; MINUEND (index) last, right before SM. Nothing register-
            ; register (add16/sub16) runs between the str r2 and this
            ; sm -- the add16 right after it is the immediate-constant
            ; form (a plain equ offset), which gotcha #18 doesn't apply
            ; to.
            mov     rf, r9
            add16   rf, BATCH_ARGS_ARGC_OFF
            ldn     rf                  ; D = stored count
            str     r2                  ; M(R2) = count
            glo     r8                  ; D = index (loaded LAST,
                                        ; right before sm)
            sm                          ; D = D - M(R2) = index - count
            lbdf    kbag_empty          ; index >= count (no borrow)

            ; index < count: real arg -- RF = base + ARGV_OFF + index*2
            glo     r8
            plo     rd
            ldi     0
            phi     rd
            shl16   rd                  ; RD = index * 2
            mov     rf, r9
            add16   rf, BATCH_ARGS_ARGV_OFF
            add16   rf, rd              ; RF = &argv_table[index]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9              ; RF = the real arg pointer
            clc
            rtn

kbag_empty:
            mov     rf, batch_args_empty
            clc
            rtn

kbag_inactive:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _batch_args_release: kernel-internal only (no jump-table slot --
; called directly from batch_readline's own EOF and I/O-error close
; paths, same link unit, mirroring kernel/glob.asm's own _glob_release
; shape). No-op if batch_args_reserved isn't set.
;
; Ordering is automatically correct with no special-casing needed: by
; the time batch_readline ever reaches one of these close paths
; (attempting to read what would be the NEXT line), the previous
; command has already fully run and returned, including its own
; per-command _redir_teardown/_glob_release calls inside that
; command's own run_loop iteration -- so this reservation, made before
; any per-line reservation for this batch ever could be, is always
; released after them, LIFO, for free.
;
; Args:    none
; Returns: nothing
; Modifies: RC, RF
; ----------------------------------------------------------------
            proc    _batch_args_release

            mov     rf, batch_args_reserved
            ldn     rf
            lbz     bar_done            ; nothing reserved: no-op
            ldi     0
            str     rf                  ; clear the flag

            ldi     high BATCH_ARGS_RESERVE_LEN
            phi     rc
            ldi     low BATCH_ARGS_RESERVE_LEN
            plo     rc
            call    _himem_release

bar_done:
            rtn

            endp

;------------------------------------------------------------------
; Batch scratch data
;------------------------------------------------------------------
            proc    _batch_data

batch_fcb:      ds      FCB_LEN
batch_iobuf:    ds      SECTOR_SIZE
batch_scratch:  db      0           ; 1-byte read scratch for
                                    ; batch_readline's byte-at-a-time
                                    ; loop
brl_count:      db      0           ; characters written to LINE_BUF so
                                    ; far in the current batch_readline
                                    ; call -- kept in memory rather than
                                    ; a register, since file_read (called
                                    ; once per byte) documents R9 among
                                    ; its clobbered registers
batch_goto_label: ds    BATCH_GOTO_LABEL_LEN   ; batch_goto's own copy
                                    ; of the target label name, taken
                                    ; before its scan loop starts
                                    ; overwriting LINE_BUF (see its own
                                    ; header comment)
batch_args_reserved: db 0          ; set only while a %0-%9 himem
                                    ; reservation is currently active --
                                    ; unrelated to redir_stack_reserved/
                                    ; glob_stack_reserved (kernel/
                                    ; redir.asm, kernel/glob.asm), which
                                    ; track separate, possibly-
                                    ; simultaneous reservations through
                                    ; the same shared _himem_reserve/
                                    ; _himem_release mechanism
batch_args_empty:    db 0          ; a fixed, always-valid empty-string
                                    ; constant -- kernel_batch_args_getarg
                                    ; points here for an out-of-range
                                    ; (but still in-batch) index, never
                                    ; at an unpopulated BATCH_ARGV slot

                public  batch_fcb
                public  batch_iobuf
                public  batch_scratch
                public  brl_count
                public  batch_goto_label
                public  batch_args_reserved
                public  batch_args_empty

            endp
