;
; pwd.asm - print the current directory's full path from root
;
; Usage: PWD
;
; Thin wrapper (2026-07-30) around lib/pathstr.asm's own
; path_print_from_cluster, extracted from what used to be this
; program's entire body once progs/dir.asm also wanted the same
; "cluster -> full path" logic for its own "Directory of <path>"
; header. See that library's own header comment for the full
; algorithm description (FAT stores no parent-name link, so it's
; discovered by walking up via '..' and searching each parent for
; the child cluster it just came from).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   path_print_from_cluster

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            call    K_GETCURDIR         ; RD = current directory cluster
            call    path_print_from_cluster
            lbdf    pwd_err

            call    K_INMSG
            db      13,10,0
            ldi     0
            rtn

pwd_err:
            call    K_INMSG
            db      "Error reading directory structure.",13,10,0
            ldi     1
            rtn

            end     start
