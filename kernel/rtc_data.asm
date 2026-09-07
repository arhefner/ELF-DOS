;
; rtc_data.asm - volatile (RAM-resident) data for rtc.asm
;
; Split out of rtc.asm for the split memory model (volatile RAM data at
; $0100, non-volatile ROM-able code at NVK_BASE). Every symbol here is
; already reached through extrn/public by its owning module, so moving
; the proc between files changes nothing about how it is referenced --
; only where the linker places it.
;
; Do NOT move these back inline: the linker lays procs out sequentially
; in command-line/source order, so a data proc sharing a .prg with code
; would land in the ROM region with that code.
;

#include    include/opcodes.def
#include    include/kernel.inc


;==================================================================
; Shared current-time buffer
;==================================================================

            proc    _rtc_data

; month, day, year(0=1972), hour, minute, second -- see header comment.
; Default: midnight, January 1 2000 (year 28 = 2000 - 1972).
cur_time:       db      1, 1, 28, 0, 0, 0

                public  cur_time

            endp
