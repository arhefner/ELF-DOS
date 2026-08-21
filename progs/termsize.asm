;
; termsize.asm - detect the console terminal's row/column count and
; record it as the ROWS/COLUMNS environment variables
;
; Usage: TERMSIZE [-u|-b]
;
; No argument defaults to UART mode (matching MR/MS/YR/YS's own
; default); "-u"/"-b" select UART/bit-bang explicitly, same convention
; and same argument shape as those four programs -- reuses their own
; shared lib/ymodem.asm mode-aware I/O primitives (ym_putbyte/
; ym_getbyte_timeout/ym_io_mode) rather than duplicating the direct-
; BIOS-call plumbing a third time. A caller who keeps a "which serial
; port am I on" choice in an environment variable (e.g. "export
; SERIAL=-u") can just run "termsize $SERIAL" and let the shell's own
; $VAR expansion supply the flag -- no special support needed here
; beyond accepting the flag as an ordinary argument, which this
; already does.
;
; Sequence: send ESC[9999;9999H (an out-of-range absolute cursor
; position -- every real terminal clamps this to its own actual last
; row/column instead of erroring), then ESC[6n (DSR, "report cursor
; position"). The terminal's own reply comes back as
; ESC[<row>;<col>R -- parsed directly out of the incoming byte stream
; (no line-buffering, no K_INPUTL) into ROWS/COLUMNS via env_setenv.
; Meant to be run once from autoexec.bat (so every ROWS/COLUMNS-aware
; utility -- LS/MORE/EDLIN, see lib/env.asm's own env_parse_uint
; comment -- picks up the real terminal size automatically at boot)
; and again by hand any time the user resizes their terminal window.
;
; Register-liveness discipline: identical to MR/MS/YR/YS's own
; hard-won rule (see progs/yr.asm's header for the full history) --
; nothing survives more than one call to ym_putbyte/ym_getbyte_timeout.
; Every byte sent or received here goes through exactly one such call
; with all of this program's own state (send offset, receive budget,
; digit-buffer write position) kept in memory and reloaded fresh
; immediately before each call, never trusted in a register across it.
; This matters more here than almost anywhere else in the project:
; parsing an incoming CSI response byte-by-byte is precisely the kind
; of "escape sequence parsing" that has already produced real,
; hardware-only-reproducible bugs in this codebase (progs/shell.asm's
; own arrow-key handling, and the toolchain-level forward-branch bug
; that masqueraded as one for a while -- see CLAUDE.md gotcha #21) --
; so this file leans on the same defensive, fully memory-backed style
; those fixes ended up needing, from the start rather than after a
; failed hardware round.
;
; The receive side is bounded two ways: TS_POLL_BUDGET (a per-byte
; timeout, in UART mode only -- see ym_getbyte_timeout's own header
; for why bit-bang mode has no non-blocking "byte waiting" primitive
; and just blocks there, matching MR/MS/YR/YS's own accepted
; limitation) and TS_TOTAL_BUDGET (a cap on the total number of bytes
; examined across the whole response, so a terminal that never sends
; a well-formed ESC[row;colR reply -- e.g. one that doesn't support
; DSR at all -- fails cleanly in bounded time rather than hanging or
; looping forever on stray/incidental bytes).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/ymodem.inc

            extrn   ym_putbyte
            extrn   ym_getbyte_timeout
            extrn   ym_io_mode
            extrn   env_setenv

; Per-byte poll budget (UART mode only, iteration count not calibrated
; wall-clock time -- same value and same reasoning as YM_POLL_BUDGET,
; include/ymodem.inc, just restated here since this program doesn't
; otherwise need any of the real YMODEM protocol constants from that
; file). Total-response budget is a plain byte count, generous enough
; for a real ESC[25;80R (9 bytes) plus some incidental slack, but
; nowhere near enough to hang around forever on a non-responding
; terminal.
TS_POLL_BUDGET:     equ     20000
TS_TOTAL_BUDGET:    equ     64
TS_DIGIT_MAX:       equ     5           ; digits per field before
                                        ; treating it as a malformed/
                                        ; runaway response

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[0] is this program's
            ; own name; argv[1], if present, must be exactly "-u" or
            ; "-b" -- no positional argument at all, closer to YR/YS's
            ; own shape than MR/MS's (which require a filename).
            mov     rf, ym_io_mode
            ldi     YM_IO_UART          ; default
            str     rf

            glo     rc
            smi     2
            lbnf    send_sequence       ; argc < 2: no flag given

            glo     rc
            smi     3
            lbdf    usage               ; argc > 2: too many arguments

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1]

            ldn     rf
            xri     '-'
            lbnz    usage

            inc     rf
            ldn     rf
            plo     r8                  ; R8.0 = flag letter

            inc     rf
            ldn     rf                  ; must be NUL for a bare 2-char
                                        ; flag
            lbnz    usage

            glo     r8
            xri     'u'
            lbz     flag_uart
            glo     r8
            xri     'b'
            lbz     flag_bitbang
            lbr     usage               ; unrecognized flag letter

flag_uart:
            mov     rf, ym_io_mode
            ldi     YM_IO_UART
            str     rf
            lbr     send_sequence

flag_bitbang:
            mov     rf, ym_io_mode
            ldi     YM_IO_BITBANG
            str     rf
            lbr     send_sequence

usage:
            call    K_INMSG
            db      "Usage: TERMSIZE [-u|-b]",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; Send the save/move/query/restore sequence, then parse the reply.
;
; BUG FIX (2026-08-21, hardware-reported): the original single ESC[
; sequence used here, "[9999;9999H", never actually reached the
; terminal intact -- Asm/02's own comment-stripping treats ';' as a
; comment start EVEN INSIDE a double-quoted db string, silently
; discarding everything on the rest of that source line (see this
; project's own isolated test: db "A;B",0 emits only the single byte
; 'A'). The compiled ts_seq_move ended up holding just ESC"[9999" with
; no terminator of its own, so ts_send_str's byte-at-a-time loop ran
; straight past it into whatever data happened to sit next in memory
; until it hit the FIRST real NUL, sending extra garbage bytes after
; the truncated "[9999" -- exactly matching the user's own hardware
; capture ("I just saw <ESC>[9999 in the log. The ;9999H isn't
; there.") and explaining why COLUMNS always came back 1 (the cursor
; never actually moved, so the query just reported wherever it already
; was -- typically column 1, right after a prompt/newline). Fixed by
; splitting the ';' out into its own single-quoted CHARACTER literal,
; ';', rather than embedding it in the "..." string -- confirmed via
; the same isolated test that a lone ';' item is NOT subject to this
; bug (only ';' appearing inside a "..." string is). Every db string
; below with a literal ';' in it follows this pattern now. The root
; cause was also fixed upstream the same day (Asm/02, gotcha #24) --
; the workaround here is kept anyway; see the data section's own
; comment for why.
;
; DESIGN CHANGE (same report, the user's own proposal): rather than
; relying on the caller to have no reason to care where the cursor
; was before this program ran, explicitly save it first (ESC[s) and
; restore it last (ESC[u) around the move/query pair -- standard ANSI
; cursor save/restore, leaves the terminal exactly as this program
; found it. 999;999 (not the original 9999;9999) per the user's own
; "999,999 should be good enough" -- comfortably beyond any real
; terminal's actual size while still keeping every sent sequence
; shorter.
;------------------------------------------------------------------
send_sequence:
            mov     rf, ts_seq_save
            call    ts_send_str

            mov     rf, ts_seq_move
            call    ts_send_str

            mov     rf, ts_seq_query
            call    ts_send_str

            call    ts_read_response    ; DF=0: ts_rows_buf/ts_cols_buf
                                        ; hold digit text; DF=1: no
                                        ; usable reply arrived

            ; Materialize DF into a plain 0/1 D value BEFORE calling
            ; ts_send_str again for the restore sequence below (its own
            ; "Modifies: everything" would otherwise clobber DF along
            ; with every register) -- the standard idiom already used
            ; elsewhere in this project for exactly this need: LDI 0
            ; doesn't touch DF, so it's still the real value from
            ; ts_read_response when SHLC runs; SHLC shifts that DF bit
            ; into D's own bit 0, giving D=0 (success) or D=1 (failure).
            ldi     0
            shlc
            plo     r9                  ; R9.0 = 0/1 result, free here
            mov     rf, ts_parse_failed
            glo     r9
            str     rf                  ; ts_parse_failed = 0/1

            mov     rf, ts_seq_restore  ; always restore the cursor,
            call    ts_send_str         ; regardless of success/failure

            mov     rf, ts_parse_failed
            ldn     rf
            lbnz    no_response

            mov     rf, ts_rows_name
            mov     rd, ts_rows_buf
            ldi     1                   ; overwrite -- set LAST (mov
                                        ; clobbers D, gotcha #4)
            call    env_setenv
            lbdf    set_failed

            mov     rf, ts_cols_name
            mov     rd, ts_cols_buf
            ldi     1
            call    env_setenv
            lbdf    set_failed

            ldi     0                   ; silent success, matching this
                                        ; project's own "no news is
                                        ; good news" convention (EXPORT/
                                        ; COPY/MD/RD/REN/...)
            rtn

no_response:
            call    K_INMSG
            db      "No response from terminal (does it support cursor",13,10
            db      "position reports? try -u/-b if the wrong port was",13,10
            db      "used).",13,10,0
            ldi     1
            rtn

set_failed:
            call    K_INMSG
            db      "Could not set ROWS/COLUMNS (is /cfg on a writable",13,10
            db      "drive?).",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; ts_send_str: send every byte of the NUL-terminated string at RF via
; ym_putbyte. RF is NOT trusted to survive the call (see this file's
; own header comment) -- the string's base address and a running byte
; offset both live in memory instead, and the current byte's address
; is recomputed fresh each iteration.
; Args:    RF = string pointer
; Returns: nothing
; Modifies: everything
;------------------------------------------------------------------
ts_send_str:
            mov     rb, ts_send_base
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ts_send_base = RF

            mov     rb, ts_send_off
            ldi     0
            str     rb                  ; ts_send_off = 0

tss_loop:
            mov     rf, ts_send_base
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = base

            mov     rf, ts_send_off
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = offset (zero-extended)

            mov     rf, r8
            add16   rf, r9              ; RF = base + offset
            ldn     rf                  ; D = byte at that position
                                        ; (no advance -- recomputed
                                        ; fresh next time around)
            lbz     tss_done

            call    ym_putbyte          ; sends D

            mov     rf, ts_send_off
            ldn     rf
            adi     1
            str     rf                  ; ts_send_off++
            lbr     tss_loop

tss_done:
            rtn

;------------------------------------------------------------------
; ts_read_response: wait for and parse "ESC[<rows>;<cols>R" from the
; wire, byte by byte. Every piece of state (parse position, budgets,
; digit-buffer write cursors) lives in memory -- see this file's own
; header comment for why nothing here is trusted in a register across
; a call to ym_getbyte_timeout.
; Args:    none
; Returns: DF = 0 -- ts_rows_buf/ts_cols_buf hold null-terminated
;          decimal digit text (ready to hand straight to env_setenv
;          as a value, no numeric parse/reformat needed). DF = 1 --
;          per-byte timeout, total budget exhausted, a non-digit where
;          a digit was expected, an empty digit field, or more digits
;          than TS_DIGIT_MAX in one field (a malformed or runaway
;          reply either way).
; Modifies: everything
;------------------------------------------------------------------
ts_read_response:
            mov     rb, ts_total_left
            ldi     TS_TOTAL_BUDGET
            str     rb                  ; ts_total_left = TS_TOTAL_BUDGET

;--- state 0: wait for ESC, discarding anything else (e.g. incidental
;    keystrokes the user typed at the same moment) -----------------
trr_wait_esc:
            call    trr_getbyte         ; DF=1: propagated straight
                                        ; through by trr_getbyte itself
            lbdf    trr_fail
            xri     $1B                 ; ESC
            lbnz    trr_wait_esc

;--- state 1: want '[' -- anything else here is a real protocol
;    violation, not incidental noise, so fail immediately rather than
;    loop back to state 0 -----------------------------------------
            call    trr_getbyte
            lbdf    trr_fail
            xri     '['
            lbnz    trr_fail

;--- state 2: accumulate row digits into ts_rows_buf until ';' ------
            mov     rb, ts_digit_idx
            ldi     0
            str     rb                  ; ts_digit_idx = 0

trr_rows_loop:
            call    trr_getbyte
            lbdf    trr_fail
            xri     ';'
            lbz     trr_rows_done

            call    trr_check_digit     ; re-derives the byte from
                                        ; ts_last_byte -- see its own
                                        ; header; DF=1: not '0'-'9'
            lbdf    trr_fail

            mov     rf, ts_digit_idx
            ldn     rf
            smi     TS_DIGIT_MAX
            lbdf    trr_fail            ; already at the cap: runaway
                                        ; field, give up

            call    trr_store_digit     ; appends ts_last_byte to
                                        ; ts_rows_buf at ts_digit_idx,
                                        ; ts_digit_idx++
            lbr     trr_rows_loop

trr_rows_done:
            mov     rf, ts_digit_idx
            ldn     rf
            lbz     trr_fail            ; empty field ("ESC[;...") --
                                        ; malformed

            mov     rf, ts_digit_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, ts_rows_buf
            add16   rf, r8
            ldi     0
            str     rf                  ; ts_rows_buf[idx] = 0 (NUL)

;--- state 3: accumulate column digits into ts_cols_buf until 'R' ---
            mov     rb, ts_digit_idx
            ldi     0
            str     rb                  ; ts_digit_idx = 0 (reused --
                                        ; the rows field is already
                                        ; safely terminated in its own
                                        ; buffer)

trr_cols_loop:
            call    trr_getbyte
            lbdf    trr_fail
            xri     'R'
            lbz     trr_cols_done

            call    trr_check_digit
            lbdf    trr_fail

            mov     rf, ts_digit_idx
            ldn     rf
            smi     TS_DIGIT_MAX
            lbdf    trr_fail

            call    trr_store_digit_cols
            lbr     trr_cols_loop

trr_cols_done:
            mov     rf, ts_digit_idx
            ldn     rf
            lbz     trr_fail            ; empty field ("...;R")

            mov     rf, ts_digit_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, ts_cols_buf
            add16   rf, r8
            ldi     0
            str     rf                  ; ts_cols_buf[idx] = 0 (NUL)

            clc
            rtn

trr_fail:
            stc
            rtn

;------------------------------------------------------------------
; trr_getbyte: read one byte via ym_getbyte_timeout, decrementing and
; checking the total-response budget first. Stashes the byte itself
; into ts_last_byte (memory) as well as returning it in D, since
; several callers above need to test it more than once (the digit-
; range check, then the store) and nothing may be trusted in a
; register across the ym_getbyte_timeout call that produced it.
; Args:    none
; Returns: DF = 0, D = byte read (also in ts_last_byte); DF = 1 on a
;          budget exhaustion or per-byte timeout
; Modifies: everything
;------------------------------------------------------------------
trr_getbyte:
            mov     rf, ts_total_left
            ldn     rf
            lbnz    trg_have_budget
            stc
            rtn

trg_have_budget:
            mov     rf, ts_total_left
            ldn     rf
            smi     1
            str     rf                  ; ts_total_left--

            ldi     high TS_POLL_BUDGET
            phi     rd
            ldi     low TS_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout  ; DF=0 D=byte / DF=1 timeout
            lbdf    trg_timeout

            plo     r9                  ; stash the byte immediately --
                                        ; R9 is free here and PLO does
                                        ; NOT touch D (unlike the mov
                                        ; below, gotcha #4)
            mov     rf, ts_last_byte
            glo     r9                  ; D = byte, reloaded fresh
                                        ; right before the store
            str     rf                  ; ts_last_byte = byte
            clc
            rtn

trg_timeout:
            stc
            rtn

;------------------------------------------------------------------
; trr_check_digit: is ts_last_byte in '0'-'9'?
; Args:    none (reads ts_last_byte)
; Returns: DF = 0 if a digit, DF = 1 if not
; Modifies: RF (and D, DF)
;------------------------------------------------------------------
trr_check_digit:
            mov     rf, ts_last_byte
            ldn     rf
            smi     '0'
            lbnf    tcd_no              ; < '0'
            smi     10
            lbdf    tcd_no              ; > '9'
            clc
            rtn
tcd_no:
            stc
            rtn

;------------------------------------------------------------------
; trr_store_digit / trr_store_digit_cols: append ts_last_byte to
; ts_rows_buf/ts_cols_buf at ts_digit_idx, then ts_digit_idx++. Two
; near-identical copies (rather than a shared routine taking the
; target buffer as an argument) so neither has to trust a "which
; buffer" argument surviving a register across trr_getbyte's own call
; to ym_getbyte_timeout in between successive digits -- the buffer
; choice is baked into which of the two labels the caller reaches,
; not carried as state across a call boundary.
; Args:    none (reads ts_last_byte/ts_digit_idx)
; Returns: nothing
; Modifies: R8, RF (and D)
;------------------------------------------------------------------
trr_store_digit:
            mov     rf, ts_digit_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = idx (zero-extended)
            mov     rf, ts_rows_buf
            add16   rf, r8              ; RF = &ts_rows_buf[idx]
            mov     r8, ts_last_byte
            ldn     r8                  ; D = the byte
            str     rf                  ; ts_rows_buf[idx] = byte

            mov     rf, ts_digit_idx
            ldn     rf
            adi     1
            str     rf                  ; ts_digit_idx++
            rtn

trr_store_digit_cols:
            mov     rf, ts_digit_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, ts_cols_buf
            add16   rf, r8              ; RF = &ts_cols_buf[idx]
            mov     r8, ts_last_byte
            ldn     r8
            str     rf

            mov     rf, ts_digit_idx
            ldn     rf
            adi     1
            str     rf
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
; NOTE: a literal ';' is kept split out of these "..." string
; literals as its own single-quoted CHARACTER item (e.g.
; "[999",';',"999H" rather than "[999;999H") even though the root
; cause -- Asm/02's own comment-stripping treating ';' as a comment
; start inside a quoted string -- was found and fixed upstream the
; same day (~/projects/elf/Asm-02 asm.c, gotcha #24). Left this way
; deliberately: it's already hardware-confirmed correct, and unlike
; reverting to the natural form, it stays correct regardless of
; whether the fixed asm02 has actually been installed to /opt/elfc
; yet on any given machine building this file.
ts_seq_save:         db      27,"[s",0
ts_seq_move:         db      27,"[999",';',"999H",0
ts_seq_query:        db      27,"[6n",0
ts_seq_restore:      db      27,"[u",0
ts_rows_name:        db      "ROWS",0
ts_cols_name:        db      "COLUMNS",0

ts_send_base:        dw      0
ts_send_off:         db      0

ts_total_left:       db      0
ts_digit_idx:        db      0
ts_last_byte:        db      0
ts_parse_failed:     db      0

ts_rows_buf:         ds      TS_DIGIT_MAX+1
ts_cols_buf:         ds      TS_DIGIT_MAX+1

            end     start
