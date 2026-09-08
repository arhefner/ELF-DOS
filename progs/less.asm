;
; less.asm - page through a file's contents with bi-directional
; scrolling and basic forward search (a scaled-down "less").
;
; Usage: LESS <filename>
;
; As of 2026-09-08 this is a thin main program: it parses argv, opens
; the file, hands control to the reusable pager, and closes the file
; when the pager returns. Everything else lives in two libraries:
;
;   lib/pager.asm    - the paging engine: terminal handling, the sliding
;                      window of visible lines, the history stack,
;                      scrolling, search, and the key dispatch loop. Its
;                      header documents the SOURCE CONTRACT it needs.
;   lib/src_file.asm - the FILE implementation of that contract: lines
;                      split at LF, with a bounded backward scan.
;   lib/pos32.asm    - the 32-bit position helpers both of them use.
;
; The split exists so the same pager can front other kinds of data --
; a hex view, a disk-sector browser -- by pairing it with a different
; source. A position is an opaque 4-byte token to the pager, so a
; source is free to mean whatever it likes by one.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   pager_run
            extrn   src_close
            extrn   src_open

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[1] is the filename.
            glo     rc
            smi     2
            lbnf    usage

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (filename)
            call    src_open            ; the SOURCE owns its own FCB
            lbdf    not_found           ; and learns its own size

            ; The file is open: hand the whole session to the pager and
            ; close up when it comes back. The program opens the source
            ; and the program closes it -- the pager never touches an
            ; FCB, which is exactly what lets a different source (a
            ; memory or sector range, with nothing to open at all) drop
            ; into the same engine.
            call    pager_run
            call    src_close
            ldi     0                   ; exit code 0 = success
            rtn


;------------------------------------------------------------------
usage:
            call    K_INMSG
            db      "Usage: LESS <filename>",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

            end     start
