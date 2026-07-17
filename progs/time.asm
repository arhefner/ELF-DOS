;
; time.asm - display or set the system time of day
;
; Usage: TIME [HH:MM[:SS]]
;
; With no argument, just displays the current time ("HH:MM:SS", 24-hour).
; With an argument, reads the RTC's own time-of-day buffer (K_GETTOD/
; f_gettod's 6-byte format: month/day/year(0=1972)/hour/minute/second,
; all plain binary -- see kernel/rtc.asm's own header comment), overwrites
; just the time fields, and writes it straight back (K_SETTOD/f_settod
; requires the whole buffer -- date and time can't be set independently).
; Seconds are optional -- "HH:MM" alone leaves the second field exactly
; as K_GETTOD returned it. Every argument is parsed and validated BEFORE
; the K_GETTOD call, so the gap between reading and writing the buffer is
; as small as possible.
;
; Deliberately uses only K_GETTOD/K_SETTOD (confirmed on hardware --
; kernel/rtc.asm's rtc_refresh already calls f_gettod this same way) plus
; a hand-rolled decimal parser/printer -- see progs/date.asm's own
; header comment for the full reasoning (not f_astodt/f_dttoas/f_atoi,
; none of which have ever been exercised anywhere in this codebase).
; Parsed hour/minute/second fields are kept in MEMORY (not registers)
; across the K_GETTOD call, matching date.asm's own established
; practice -- kernel/rtc.asm documents a known BIOS bug where f_gettod
; clobbers RC's high byte despite being "documented to preserve every
; register but RF".
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
                                        ; display the current time

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (time string) --
                                        ; RF is now the parse cursor
                                        ; for the rest of parsing; RB
                                        ; is free again

            call    parse_uint          ; RD = hour, RF -> separator
            mov     rb, st_hour
            glo     rd
            str     rb                  ; st_hour = hour

            ldn     rf                  ; D = the separator character
            xri     ':'
            lbnz    bad_format
            inc     rf                  ; RF -> minute digits

            call    parse_uint          ; RD = minute, RF -> terminator
            mov     rb, st_min
            glo     rd
            str     rb                  ; st_min = minute

            ldn     rf
            lbz     no_seconds          ; NUL: no seconds field given
            xri     ':'
            lbnz    bad_format
            inc     rf                  ; RF -> second digits

            call    parse_uint          ; RD = second, RF -> terminator
            ldn     rf
            lbnz    bad_format          ; must be NUL after seconds

            mov     rb, st_sec
            glo     rd
            str     rb                  ; st_sec = second
            mov     rb, st_has_sec
            ldi     1
            str     rb
            lbr     time_parsed

no_seconds:
            mov     rb, st_has_sec
            ldi     0
            str     rb

time_parsed:
            ; validate hour (0-23)
            mov     rb, st_hour
            ldn     rb
            smi     24
            lbdf    bad_range           ; hour >= 24

            ; validate minute (0-59)
            mov     rb, st_min
            ldn     rb
            smi     60
            lbdf    bad_range           ; minute >= 60

            ; validate second (0-59), only if given
            mov     rb, st_has_sec
            ldn     rb
            lbz     time_valid
            mov     rb, st_sec
            ldn     rb
            smi     60
            lbdf    bad_range           ; second >= 60

time_valid:
            ; --- read-modify-write, minimal gap between K_GETTOD and
            ; K_SETTOD: no parsing/validation happens in between, just
            ; a few memory-to-memory byte copies ---
            mov     rf, dt_buf
            call    K_GETTOD

            mov     rf, dt_buf
            add16   rf, 3               ; RF -> dt_buf[3] (hour)
            mov     rb, st_hour
            ldn     rb
            str     rf                  ; dt_buf[3] = hour
            inc     rf
            mov     rb, st_min
            ldn     rb
            str     rf                  ; dt_buf[4] = minute
            inc     rf

            mov     rb, st_has_sec
            ldn     rb
            lbz     skip_sec_write      ; no seconds given: leave
                                        ; dt_buf[5] exactly as K_GETTOD
                                        ; returned it
            mov     rb, st_sec
            ldn     rb
            str     rf                  ; dt_buf[5] = second

skip_sec_write:
            mov     rf, dt_buf
            call    K_SETTOD

show_only:
            mov     rf, dt_buf
            call    K_GETTOD
            call    print_time
            ldi     0                   ; exit code 0 = success
            rtn

bad_format:
bad_range:
            call    K_INMSG
            db      "Usage: TIME [HH:MM[:SS]]",13,10,0
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
            smi     10                  ; D = candidate - 10, DF=1 if
                                        ; candidate >= 10 (no borrow)
            lbdf    pu_done             ; not a valid digit

            mov     r8, rd
            shl16   r8
            shl16   r8
            shl16   r8                  ; R8 = RD*8
            shl16   rd                  ; RD = RD*2 -- BUG FIX
                                        ; (2026-07-17): same bug as
                                        ; date.asm's own parse_uint --
                                        ; this used to be TWO shl16
                                        ; calls (RD*4), making the
                                        ; whole routine compute
                                        ; value*12+digit instead of
                                        ; value*10+digit. Invisible for
                                        ; a leading '0' digit, caught
                                        ; on hardware via "12"->H=14
                                        ; (1*12+2), exactly matching.
            add16   rd, r8              ; RD = RD*10
            add16   rd, r9              ; RD += digit
            inc     rf
            lbr     pu_loop

pu_done:
            rtn

; ----------------------------------------------------------------
; print_time: print dt_buf's time fields as "HH:MM:SS", CRLF
; Args:    none (reads dt_buf)
; Returns: nothing
; ----------------------------------------------------------------
print_time:
            mov     rf, dt_buf
            add16   rf, 3
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit         ; hour

            call    K_INMSG
            db      ":",0

            mov     rf, dt_buf
            add16   rf, 4
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit         ; minute

            call    K_INMSG
            db      ":",0

            mov     rf, dt_buf
            add16   rf, 5
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit         ; second

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

st_hour:    db      0
st_min:     db      0
st_sec:     db      0
st_has_sec: db      0
dt_buf:     ds      6                   ; K_GETTOD/K_SETTOD's own
                                        ; 6-byte buffer
digit_buf:  ds      3                   ; scratch for print2digit
                                        ; ("99"+null)

            end     start
