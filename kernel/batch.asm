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

; same-file cross-proc data references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   batch_fcb
            extrn   batch_iobuf
            extrn   batch_handle
            extrn   batch_scratch
            extrn   brl_count

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
            call    file_open           ; D = handle, DF = 0/1
            lbdf    bst_reject

            ; stash the handle BEFORE the mov below clobbers D (gotcha
            ; #4)
            plo     r9
            mov     rf, batch_handle
            glo     r9
            str     rf                  ; batch_handle = handle

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
; Args:    none (uses batch_fcb/batch_handle)
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
            mov     ra, batch_handle    ; RA -> batch_handle (RF/RC
                                        ; must stay untouched by this --
                                        ; use RA, not RF, to reach it)
            ldn     ra                  ; D = handle (fresh, correct --
                                        ; nothing after this clobbers D
                                        ; before the call)
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

            mov     ra, batch_handle
            ldn     ra
            call    file_close
            mov     rf, batch_fcb
            ldi     0
            str     rf                  ; FCB_FLAGS = 0 -- "no batch
                                        ; active" from here on
brl_inactive:
            stc                         ; DF = 1: no line
            rtn

brl_ioerr:
            ; a real I/O error mid-batch: treat the same as EOF --
            ; close, clear state, report "no line" -- rather than
            ; leaving the batch wedged open with no way to advance
            mov     ra, batch_handle
            ldn     ra
            call    file_close
            mov     rf, batch_fcb
            ldi     0
            str     rf
            stc
            rtn

            endp

;------------------------------------------------------------------
; Batch scratch data
;------------------------------------------------------------------
            proc    _batch_data

batch_fcb:      ds      FCB_LEN
batch_iobuf:    ds      SECTOR_SIZE
batch_handle:   db      0           ; fd_table index while a batch's
                                    ; FCB is open
batch_scratch:  db      0           ; 1-byte read scratch for
                                    ; batch_readline's byte-at-a-time
                                    ; loop
brl_count:      db      0           ; characters written to LINE_BUF so
                                    ; far in the current batch_readline
                                    ; call -- kept in memory rather than
                                    ; a register, since file_read (called
                                    ; once per byte) documents R9 among
                                    ; its clobbered registers

                public  batch_fcb
                public  batch_iobuf
                public  batch_handle
                public  batch_scratch
                public  brl_count

            endp
