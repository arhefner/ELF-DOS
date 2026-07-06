;
; ver.asm - print the ELF-DOS kernel version
;
; Usage: VER
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
            ; read the kernel version directly from its fixed header
            ; address (see kernel_api.inc: KERNEL_HDR_VER) -- no kernel
            ; call needed, since $0100's header layout never shifts
            ; across kernel rebuilds, same as PROG_BASE/LOADER_ARGS.
            ; RD is set to the destination first, since "mov" itself
            ; clobbers D (see project notes) -- reading it afterward
            ; via lda/ldn is safe either way.
            mov     rd, ver_major
            mov     rf, KERNEL_HDR_VER
            lda     rf                  ; D = major version byte, RF++
            str     rd                  ; ver_major = major byte
            inc     rd
            ldn     rf                  ; D = minor version byte
            str     rd                  ; ver_minor = minor byte

            call    K_INMSG
            db      "ELF-DOS v",0

            mov     rf, ver_major
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, ver_buf
            call    f_uintout           ; writes decimal ASCII into *rf, advances rf
            ldi     0
            str     rf                  ; null-terminate
            mov     rf, ver_buf
            call    K_MSG

            call    K_INMSG
            db      ".",0

            mov     rf, ver_minor
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, ver_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ver_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            ldi     0                   ; exit code 0 = success
            rtn

ver_major:  db      0
ver_minor:  db      0
ver_buf:    ds      6                   ; decimal scratch (max "65535"+null)

            end     start
