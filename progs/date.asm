;
; date.asm - display or set the system date
;
; Usage: DATE [MM/DD/YYYY]
;
; With no argument, just displays the current date (same "MM/DD/YYYY"
; format progs/dir.asm already uses for file timestamps). With an
; argument, reads the RTC's own time-of-day buffer (K_GETTOD/f_gettod's
; 6-byte format: month(1-12)/day(1-31)/year(0=1972)/hour/minute/second,
; all plain binary -- see kernel/rtc.asm's own header comment),
; overwrites just the date fields, and writes it straight back
; (K_SETTOD/f_settod requires the whole buffer -- date and time can't
; be set independently). Every argument is parsed and validated BEFORE
; the K_GETTOD call, so the gap between reading and writing the buffer
; is as small as possible: the time fields, carried through unchanged
; from what K_GETTOD just returned, can't go stale enough by the time
; K_SETTOD runs to make the clock look like it moved backward.
;
; Deliberately uses only K_GETTOD/K_SETTOD (confirmed on hardware --
; kernel/rtc.asm's rtc_refresh already calls f_gettod this same way)
; plus a hand-rolled decimal parser/printer -- not f_astodt/f_dttoas
; or f_atoi, none of which have ever been exercised anywhere in this
; codebase, so their exact register contracts aren't confirmed. The
; parsed month/day/year fields are kept in MEMORY (not registers)
; across the K_GETTOD call specifically -- kernel/rtc.asm's own header
; documents a known BIOS bug where f_gettod clobbers RC's high byte
; despite being "documented to preserve every register but RF", and
; rtc_refresh's own established defensive practice is to not trust any
; part of that register across the call, not just the affected half.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            glo     rc
            smi     2
            lbnf    show_only           ; argc < 2: no argument, just
                                        ; display the current date

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (date string) --
                                        ; RF is now the parse cursor
                                        ; for the rest of parsing; RB
                                        ; is free again

            call    parse_uint          ; RD = month, RF -> separator
            mov     rb, sd_month
            glo     rd
            str     rb                  ; sd_month = month

            ldn     rf                  ; D = the separator character
            xri     '/'
            lbnz    bad_format
            inc     rf                  ; RF -> day digits

            call    parse_uint          ; RD = day, RF -> separator
            mov     rb, sd_day
            glo     rd
            str     rb                  ; sd_day = day

            ldn     rf
            xri     '/'
            lbnz    bad_format
            inc     rf                  ; RF -> year digits

            call    parse_uint          ; RD = year (full value, e.g.
                                        ; 2026)

            ; validate month (1-12)
            mov     rb, sd_month
            ldn     rb
            smi     1
            lbnf    bad_range
            mov     rb, sd_month
            ldn     rb
            smi     13
            lbdf    bad_range           ; month >= 13

            ; validate day (1-31)
            mov     rb, sd_day
            ldn     rb
            smi     1
            lbnf    bad_range
            mov     rb, sd_day
            ldn     rb
            smi     32
            lbdf    bad_range           ; day >= 32

            ; validate year: 1972-2227 (year-1972 must fit one byte,
            ; matching cur_time's own "0 = 1972" single-byte encoding)
            sub16   rd, 1972
            lbnf    bad_range           ; year < 1972
            ghi     rd
            lbnz    bad_range           ; year > 2227

            mov     rb, sd_year0
            glo     rd
            str     rb                  ; sd_year0 = year - 1972

            ; --- read-modify-write, minimal gap between K_GETTOD and
            ; K_SETTOD: no parsing/validation happens in between, just
            ; three memory-to-memory byte copies ---
            mov     rf, dt_buf
            call    K_GETTOD

            mov     rf, dt_buf
            mov     rb, sd_month
            ldn     rb
            str     rf                  ; dt_buf[0] = month
            inc     rf
            mov     rb, sd_day
            ldn     rb
            str     rf                  ; dt_buf[1] = day
            inc     rf
            mov     rb, sd_year0
            ldn     rb
            str     rf                  ; dt_buf[2] = year (0=1972) --
                                        ; dt_buf[3..5] (hour/minute/
                                        ; second) left exactly as
                                        ; K_GETTOD returned them

            mov     rf, dt_buf
            call    K_SETTOD

show_only:
            mov     rf, dt_buf
            call    K_GETTOD
            call    print_date
            ldi     0                   ; exit code 0 = success
            rtn

bad_format:
bad_range:
            call    K_INMSG
            db      "Usage: DATE [MM/DD/YYYY]",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

; ----------------------------------------------------------------
; parse_uint: parse decimal digits at *RF into RD, stopping at the
; first non-digit character.
; Args:    RF = pointer to the first digit
; Returns: RD = parsed value (0 if no leading digit was found), RF =
;          pointer to the first non-digit character
; Modifies: R8, R9
; ----------------------------------------------------------------
parse_uint:
            ldi     0
            phi     rd
            plo     rd                  ; RD = 0

pu_loop:
            ldn     rf
            smi     '0'
            lbnf    pu_done             ; *RF < '0': not a digit
            plo     r9                  ; R9.0 = candidate digit value
                                        ; (0..whatever *RF-'0' is)
            smi     10                  ; D = candidate - 10, DF=1 if
                                        ; candidate >= 10 (no borrow)
            lbdf    pu_done             ; not a valid digit (R9 still
                                        ; holds the last VALID digit
                                        ; from the previous iteration,
                                        ; untouched -- this iteration's
                                        ; invalid candidate is simply
                                        ; never used below)

            mov     r8, rd
            shl16   r8
            shl16   r8
            shl16   r8                  ; R8 = RD*8
            shl16   rd                  ; RD = RD*2 -- BUG FIX
                                        ; (2026-07-17): this used to be
                                        ; TWO shl16 calls, computing
                                        ; RD*4 instead of RD*2 -- the
                                        ; whole routine silently
                                        ; computed value*12+digit
                                        ; instead of value*10+digit.
                                        ; Invisible for the first digit
                                        ; of any number starting with
                                        ; '0' (0*12 == 0*10 == 0, which
                                        ; is why "07" for month always
                                        ; parsed correctly) -- caught
                                        ; on real hardware via a
                                        ; diagnostic print showing
                                        ; "16"->18 and "2026"->3486,
                                        ; both exactly matching a *12
                                        ; accumulation. A byte-level
                                        ; .lst trace earlier had
                                        ; confirmed the assembled bytes
                                        ; matched this (buggy) source
                                        ; faithfully -- it never
                                        ; questioned whether the source
                                        ; itself was arithmetically
                                        ; correct.
            add16   rd, r8              ; RD = RD*10
            add16   rd, r9              ; RD += digit
            inc     rf
            lbr     pu_loop

pu_done:
            rtn

; ----------------------------------------------------------------
; print_date: print dt_buf's date fields as "MM/DD/YYYY", CRLF
; Args:    none (reads dt_buf)
; Returns: nothing
; ----------------------------------------------------------------
print_date:
            mov     rf, dt_buf
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit         ; month

            call    K_INMSG
            db      "/",0

            mov     rf, dt_buf
            inc     rf
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit         ; day

            call    K_INMSG
            db      "/",0

            mov     rf, dt_buf
            add16   rf, 2
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            add16   rd, 1972            ; full year
            mov     rf, year_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, year_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0
            rtn

; ----------------------------------------------------------------
; print2digit: print RD (0-99) as two zero-padded decimal digits
; (e.g. 3 -> "03", 14 -> "14").
; Args:    RD = value (0-99)
; Returns: nothing
; ----------------------------------------------------------------
print2digit:
            glo     rd
            smi     10
            lbdf    p2d_use_uintout     ; value >= 10: two digits already

            glo     rd
            adi     '0'
            plo     rc                  ; stash the single digit's char
            mov     rf, digit_buf
            ldi     '0'
            str     rf
            inc     rf
            glo     rc
            str     rf
            inc     rf
            ldi     0
            str     rf
            lbr     p2d_print

p2d_use_uintout:
            mov     rf, digit_buf
            call    f_uintout
            ldi     0
            str     rf

p2d_print:
            mov     rf, digit_buf
            call    K_MSG
            rtn

sd_month:   db      0
sd_day:     db      0
sd_year0:   db      0                   ; year - 1972, kept in memory
                                        ; across K_GETTOD (see header
                                        ; comment)
dt_buf:     ds      6                   ; K_GETTOD/K_SETTOD's own
                                        ; 6-byte buffer
digit_buf:  ds      3                   ; scratch for print2digit
                                        ; ("99"+null)
year_buf:   ds      6                   ; decimal year scratch

            end     start
