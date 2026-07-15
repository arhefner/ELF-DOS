;
; mon.asm - drop straight into the ROM monitor
;
; Usage: MON
;
; Sets R1 to the ROM monitor's fixed entry point (MONITOR_ENTRY,
; $F034) and executes a BRKPT (see include/opcodes.def -- expands to
; the fixed 2-byte sequence 79 D1), transferring control there
; directly. A quick way to reach the monitor for low-level debugging
; without a hardware reset.
;
; Confirmed on hardware (2026-07-14): the monitor's own "continue"
; command hands control back cleanly, resuming right after BRKPT --
; unlike progs/reboot.asm's K_BOOT (which reloads everything from
; disk and was never expected to return), this program's own normal
; exit path is what actually runs once the user is done in the
; monitor, so it just falls through to it -- no halt loop needed.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

MONITOR_ENTRY:  equ     $F034

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     r1, MONITOR_ENTRY
            brkpt                       ; transfers control to the
                                        ; monitor; resumes here on
                                        ; "continue" (confirmed on
                                        ; hardware)

            ldi     0                   ; exit code 0 = success
            rtn

            end     start
