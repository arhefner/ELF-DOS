;
; reboot.asm - warm-reboot the machine
;
; Usage: REBOOT
;
; Calls the BIOS boot vector directly (K_BOOT -> f_boot), which reloads
; the MBR/krnboot/kernel fresh from disk -- unlike jumping back into
; krnboot's own code, which no longer works once PROG_BASE has been
; lowered to reclaim krnboot's dead sector (see kernel.inc): krnboot's
; bytes may well have been overwritten by whatever program last ran.
; f_boot re-reads everything from disk instead of relying on any of it
; still being resident, so this is safe regardless.
;
; f_boot is a standard Elf/OS BIOS entry point; its exact contract
; (whether it ever returns) hasn't been independently confirmed on
; this hardware, so a halt loop follows the call just in case.
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
            call    K_BOOT              ; reboot from disk; should not return

halt:       lbr     halt                ; safety net if it ever does

            end     start
