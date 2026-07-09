;
; rtc.asm - real-time clock access and FAT date/time packing
;
; Provides:
;   rtc_refresh         -- refresh cur_time from the RTC, if present
;   _pack_fat_datetime  -- pack cur_time into FAT's on-disk date/time format
;
; cur_time is a shared, kernel-owned 6-byte buffer holding the last known
; wall-clock time, in f_gettod's own format: [0]=month(1-12),
; [1]=day(1-31), [2]=year (0 = 1972), [3]=hour(0-23), [4]=minute(0-59),
; [5]=second(0-59) -- all plain binary, not BCD (per the BIOS's actual
; documented contract, confirmed by the user, not guessed). It starts
; out holding a fixed default (midnight, January 1 2000) baked into the
; kernel image, and is refreshed from the RTC (when present) by
; rtc_refresh, called fresh every time a caller needs "now" rather than
; just once at boot, so timestamps reflect the actual moment of each
; file operation instead of staying frozen at boot time.
;
; No RTC hardware is required: f_getdev's device-flags result (returned
; in RF) is checked first -- bit 4 of the low byte set means an RTC is
; present -- and f_gettod is only called when it is. Without an RTC,
; cur_time simply keeps whatever it last held (the boot default,
; forever, until a future SETTIME command exists to let the user
; override it -- deliberately out of scope here, see CLAUDE.md).
;
; f_gettod has a known bug in some BIOS versions: it clobbers the high
; byte of RC despite being documented to preserve every register but RF.
; Worked around here by push/pop-ing RC around the call unconditionally,
; since that's harmless even once the underlying bug is fixed.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; same-file data reference (required even within the same file)
            extrn   cur_time

;==================================================================
; Shared current-time buffer
;==================================================================

            proc    _rtc_data

; month, day, year(0=1972), hour, minute, second -- see header comment.
; Default: midnight, January 1 2000 (year 28 = 2000 - 1972).
cur_time:       db      1, 1, 28, 0, 0, 0

                public  cur_time

            endp

;==================================================================
; rtc_refresh: refresh cur_time from the RTC, if one is present
;
; Args:    none
; Returns: nothing (cur_time updated if an RTC was found, otherwise
;          left unchanged)
; Modifies: R7, R8, R9, RF (RC is protected internally against
; f_gettod's known bug, so callers don't need to worry about it)
;==================================================================

            proc    rtc_refresh

            call    f_getdev            ; RF = device flags
            glo     rf
            ani     $10                 ; bit 4 = RTC present
            lbz     rtc_no_rtc

            mov     rf, cur_time
            push    rc                  ; work around f_gettod's RC.1-
                                        ; clobbering bug on older BIOS
                                        ; versions (harmless once fixed)
            call    f_gettod
            pop     rc

rtc_no_rtc:
            rtn

            endp

;==================================================================
; _pack_fat_datetime: pack cur_time into FAT's on-disk date/time
; format.
;
; FAT date (16 bits): bits 15-9 = year-1980, bits 8-5 = month,
; bits 4-0 = day.
; FAT time (16 bits): bits 15-11 = hour, bits 10-5 = minute,
; bits 4-0 = seconds/2 (2-second resolution).
;
; cur_time's year is "0 = 1972"; FAT's is "0 = 1980" -- converted by
; subtracting 8, clamped to 0 if that would go negative (a date before
; 1980, which FAT can't represent anyway).
;
; Args:    none (reads cur_time)
; Returns: RD = packed date, R8 = packed time
; Modifies: R7, R9, RD, RF (R8 is the second return value, not scratch)
;==================================================================

            proc    _pack_fat_datetime

            ; --- packed date = ((year-8) << 9) | (month << 5) | day ---
            mov     rf, cur_time
            add16   rf, 2
            ldn     rf                  ; D = cur_time[2] (year, 0=1972)
            smi     8                   ; D = year - 8 (FAT epoch 1980)
            lbdf    pfd_year_ok         ; DF=1: no borrow, year >= 1980
            ldi     0                   ; clamp: pre-1980 dates -> 0
pfd_year_ok:
            plo     rd
            ldi     0
            phi     rd                  ; RD = year field (0-127)
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd                  ; RD = year field << 9 (9 shifts)

            mov     rf, cur_time
            ldn     rf                  ; D = cur_time[0] (month, 1-12)
            plo     r7
            ldi     0
            phi     r7                  ; R7 = month
            shl16   r7
            shl16   r7
            shl16   r7
            shl16   r7
            shl16   r7                  ; R7 = month << 5 (5 shifts)

            ghi     r7
            str     r2
            ghi     rd
            or
            phi     rd
            glo     r7
            str     r2
            glo     rd
            or
            plo     rd                  ; RD |= (month << 5)

            mov     rf, cur_time
            inc     rf
            ldn     rf                  ; D = cur_time[1] (day, 1-31)
            str     r2
            glo     rd
            or
            plo     rd                  ; RD |= day -- RD = packed date

            ; stash packed date in R9 while packed time is built below
            ; (also using RD as working scratch)
            mov     r9, rd

            ; --- packed time = (hour<<11) | (minute<<5) | (sec>>1) ---
            mov     rf, cur_time
            add16   rf, 3
            ldn     rf                  ; D = cur_time[3] (hour, 0-23)
            plo     rd
            ldi     0
            phi     rd                  ; RD = hour
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd                  ; RD = hour << 11 (11 shifts)

            mov     rf, cur_time
            add16   rf, 4
            ldn     rf                  ; D = cur_time[4] (minute, 0-59)
            plo     r7
            ldi     0
            phi     r7                  ; R7 = minute
            shl16   r7
            shl16   r7
            shl16   r7
            shl16   r7
            shl16   r7                  ; R7 = minute << 5 (5 shifts)

            ghi     r7
            str     r2
            ghi     rd
            or
            phi     rd
            glo     r7
            str     r2
            glo     rd
            or
            plo     rd                  ; RD |= (minute << 5)

            mov     rf, cur_time
            add16   rf, 5
            ldn     rf                  ; D = cur_time[5] (second, 0-59)
            shr                         ; D = second >> 1 (0-29)
            str     r2
            glo     rd
            or
            plo     rd                  ; RD |= (sec>>1) -- RD = packed time

            mov     r8, rd              ; R8 = packed time (return value)
            mov     rd, r9              ; RD = packed date (restored,
                                        ; return value)
            rtn

            endp
