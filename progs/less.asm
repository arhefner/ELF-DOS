;
; less.asm - page through a file's contents with bi-directional
; scrolling and basic forward search (a scaled-down "less").
;
; Usage: LESS [-N] [-S] <filename>
;
; -N numbers the lines, as in less -N.
; -S chops long lines to the screen width and scrolls sideways with the
;    Left/Right arrows, as in less -S. The default is to WRAP long lines.
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
            ; RA = argv, RC.0 = argc. The argument scan makes no calls,
            ; so it works in registers: R9.0 = index, R7.0 = options,
            ; R8 = the filename (0 until one is found). -N may come
            ; before or after the name.
            ldi     0
            plo     r7
            phi     r8
            plo     r8
            ldi     1
            plo     r9

arg_loop:
            glo     rc
            str     r2
            glo     r9
            sm                          ; index - argc
            lbdf    args_done           ; no borrow: index >= argc

            glo     r9
            shl                         ; 2*index (argc <= 16, fits)
            str     r2
            glo     ra
            add
            plo     rd
            ghi     ra
            adci    0
            phi     rd                  ; RD = &argv[index]
            lda     rd
            phi     rb
            ldn     rd
            plo     rb                  ; RB = argv[index]

            ghi     rb
            phi     rf
            glo     rb
            plo     rf                  ; RF = the same, to walk
            ldn     rf
            xri     '-'
            lbnz    arg_name
            inc     rf                  ; skip the '-'
            ldn     rf
            xri     'N'                 ; -N, as in less (case matters:
            lbz     arg_flag_n          ; less's -n means the opposite)
            ldn     rf
            xri     'S'                 ; -S: chop long lines + sideways scroll
            lbz     arg_flag_s
            lbr     usage
arg_flag_n:
            inc     rf
            ldn     rf
            lbnz    usage               ; "-Nx" and the like
            glo     r7
            ori     1                   ; PAGER_OPT_NUMBERS
            plo     r7
            lbr     arg_next
arg_flag_s:
            inc     rf
            ldn     rf
            lbnz    usage
            glo     r7
            ori     2                   ; PAGER_OPT_NOWRAP
            plo     r7
            lbr     arg_next

arg_name:
            ghi     r8
            lbnz    usage               ; a second filename
            glo     r8
            lbnz    usage
            ghi     rb
            phi     r8
            glo     rb
            plo     r8                  ; R8 = the filename

arg_next:
            glo     r9
            adi     1
            plo     r9
            lbr     arg_loop

args_done:
            ghi     r8
            lbnz    have_name
            glo     r8
            lbz     usage               ; no filename at all
have_name:
            mov     rf, less_opts       ; kept in memory: src_open
            glo     r7                  ; clobbers every register
            str     rf
            mov     rf, r8
            call    src_open            ; the SOURCE owns its own FCB
            lbdf    not_found           ; and learns its own size

            ; The file is open: hand the whole session to the pager and
            ; close up when it comes back. The program opens the source
            ; and the program closes it -- the pager never touches an
            ; FCB, which is exactly what lets a different source (a
            ; memory or sector range, with nothing to open at all) drop
            ; into the same engine.
            mov     rf, less_opts
            ldn     rf
            plo     r9
            mov     rf, less_name       ; shown on the status line
            glo     r9                  ; D = options
            call    pager_run
            call    src_close
            ldi     0                   ; exit code 0 = success
            rtn


;------------------------------------------------------------------
usage:
            call    K_INMSG
            db      "Usage: LESS [-N] [-S] <filename>",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

less_opts:  db      0                   ; pager_run's options
less_name:  db      "LESS",0

            end     start
