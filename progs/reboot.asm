;
; reboot.asm - warm-reboot the machine
;
; Usage: REBOOT [unit]
;
; Restarts ELF-DOS from block device <unit> (0-7), by default the unit
; this instance booted from (BOOT_UNIT).
;
; It does what a BIOS's disk boot does -- read sector 0 to $0100, set
; up a small stack at $00FF, and jump to $0106 with the unit in R8.1 --
; rather than calling f_boot. f_boot always boots the BIOS's own default
; disk (EDOS-mbios's forces unit 0; an Elf/OS BIOS has no way to be told
; a unit), so after booting from unit 1 it would have come back up on
; unit 0. Doing the read here needs only f_ideread, which every
; Elf/OS-compatible BIOS has. ELF-DOS's MBR takes it from there exactly
; as at power-on: it moves the stack to the top of RAM, resets the disk
; subsystem, and loads krnboot and the kernel from the same unit.
;
; Before anything is overwritten, the unit is checked: LBA 1 must carry
; a kernel ('KRN', the header SYS writes) and sector 0 ELF-DOS's boot
; code ('MBR'), so a unit without them is refused with a message instead
; of being jumped into. Sector 0 is read into this program's own buffer
; first and only copied to $0100 once everything checks out: $0100 is
; the kernel's volatile region, jump table included, so no kernel call
; can be made after the copy.
;
; SCRT (R4/R5) is left as the BIOS set it up at power-on, which is what
; the MBR expects. Nothing is re-probed: like f_boot, this is not a
; reset (see CLAUDE.md -- use a real reset after a possible wild write).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

BOOT_SECTOR:    equ     $0100       ; where a BIOS loads sector 0
BOOT_ENTRY:     equ     $0106       ; and enters it
BOOT_STACK:     equ     $00FF       ; the BIOS's boot-time stack

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Entry: RA = argv table, RC = argc
;------------------------------------------------------------------
start:
            mov     rf, BOOT_UNIT       ; default: the unit we booted from
            ldn     rf
            plo     rb
            mov     rf, rb_unit
            glo     rb
            str     rf

            glo     rc
            smi     2
            lbnf    have_unit           ; no argument
            glo     rc
            smi     3
            lbdf    usage               ; more than one
            inc     ra                  ; RA -> argv[1]
            inc     ra
            lda     ra
            phi     rf
            ldn     ra
            plo     rf
            lda     rf                  ; a single digit 0-7
            smi     '0'
            lbnf    usage
            plo     rb
            smi     8
            lbdf    usage
            ldn     rf
            lbnz    usage
            mov     rf, rb_unit
            glo     rb
            str     rf

have_unit:
            ; ---- LBA 1: a kernel? ----
            ldi     1
            call    read_sector
            lbdf    unreadable
            mov     rf, rb_buf
            lda     rf
            xri     'K'
            lbnz    no_kernel
            lda     rf
            xri     'R'
            lbnz    no_kernel
            ldn     rf
            xri     'N'
            lbnz    no_kernel

            ; ---- LBA 0: ELF-DOS's boot code? (read last: it stays in
            ; the buffer to be copied) ----
            ldi     0
            call    read_sector
            lbdf    unreadable
            mov     rf, rb_buf
            lda     rf
            xri     'M'
            lbnz    no_mbr
            lda     rf
            xri     'B'
            lbnz    no_mbr
            ldn     rf
            xri     'R'
            lbnz    no_mbr

            call    K_INMSG
            db      "Rebooting from unit ",0
            call    print_unit
            call    K_INMSG
            db      "...",13,10,0

            ; ==== no kernel calls from here on ====
            ; the unit, as a BIOS passes it: drive/head bits $E0 + unit
            mov     rf, rb_unit
            ldn     rf
            ori     $E0
            phi     r8

            mov     rf, rb_buf          ; copy sector 0 to $0100
            mov     rd, BOOT_SECTOR
            mov     rc, 512
copy:
            lda     rf
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    copy
            ghi     rc
            lbnz    copy

            mov     r2, BOOT_STACK      ; the BIOS's boot-time stack
            sex     r2
            lbr     BOOT_ENTRY

;------------------------------------------------------------------
; read_sector: read LBA D (0 or 1) of rb_unit into rb_buf. DF=1 on error.
;------------------------------------------------------------------
read_sector:
            plo     r7
            ldi     0
            phi     r7
            plo     r8
            mov     rf, rb_unit
            ldn     rf
            phi     r8
            mov     rf, rb_buf
            lbr     K_SECREAD

print_unit:
            mov     rf, rb_unit
            ldn     rf
            adi     '0'
            lbr     K_TYPE

usage:
            call    K_INMSG
            db      "Usage: REBOOT [unit 0-7]",13,10,0
            ldi     1
            rtn

unreadable:
            call    K_INMSG
            db      "Cannot read unit ",0
            call    print_unit
            call    K_INMSG
            db      ".",13,10,0
            ldi     1
            rtn

no_kernel:
            call    K_INMSG
            db      "Unit ",0
            call    print_unit
            call    K_INMSG
            db      " has no ELF-DOS kernel (install one with SYS).",13,10,0
            ldi     1
            rtn

no_mbr:
            call    K_INMSG
            db      "Unit ",0
            call    print_unit
            call    K_INMSG
            db      " has no ELF-DOS boot code (install it with SYS ",0
            call    print_unit
            call    K_INMSG
            db      " mbr.bin).",13,10,0
            ldi     1
            rtn

rb_unit:    db      0
rb_buf:     ds      512

            end     start
