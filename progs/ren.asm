;
; ren.asm - rename a file or directory
;
; Usage: REN <path> <newname>
;
; Same-directory rename only -- <newname> must be a bare name (no
; path separators); it always applies within <path>'s own parent
; directory (no cross-directory move). <path> may be a full path,
; e.g. "REN /cfg/old.dat new.dat" -- resolved internally by
; K_FILE_RENAME (see K_PATH_RESOLVE). Works on either a file or a
; directory.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = command tail = "<path> <newname>"
            ldn     ra
            lbz     usage_error

            ; find the space separating the two arguments
            mov     rf, ra
scan_path_end:
            ldn     rf
            lbz     usage_error         ; only one token: no newname
            xri     ' '
            lbz     have_path_end
            inc     rf
            lbr     scan_path_end
have_path_end:
            ldi     0
            str     rf                  ; null-terminate path in place
            inc     rf

            ; skip any additional spaces before the newname
skip_spaces:
            ldn     rf
            xri     ' '
            lbnz    have_newname
            inc     rf
            lbr     skip_spaces
have_newname:
            ldn     rf
            lbz     usage_error         ; nothing after the spaces

            mov     rd, rf              ; RD = newname pointer
            mov     rf, ra              ; RF = path pointer
            call    K_FILE_RENAME       ; DF = 0/1
            lbdf    ren_error

            call    K_INMSG
            db      "Renamed.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

ren_error:
            call    K_INMSG
            db      "Cannot rename (not found, name already exists, or invalid).",13,10,0
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: REN <path> <newname>",13,10,0
            ldi     1
            rtn

            end     start
