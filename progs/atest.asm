;
; atest.asm - append-mode write-support test utility
;
; Usage: ATEST <filename>
;
; Opens <filename> in append mode (K_FILE_OPEN mode 2) and writes
; REPEAT_COUNT copies of a fixed test line. Creates the file if it
; doesn't exist (same as WTEST's mode 1); if it already exists, the
; new content is appended after whatever's already there, rather
; than overwriting from position 0 -- see kernel/file.asm's
; file_open mode-2 positioning logic.
;
; Run ATEST twice in a row against the same (new or existing) file
; and check with TYPE/DIR: the second run's output should be the
; first run's content followed immediately by a second copy, with
; the final size doubling -- not overwritten, and no gap or overlap
; at the point where the second run's writes begin (which may or may
; not land on a cluster boundary, depending on the first run's final
; size, so this also exercises the append-position math across that
; boundary).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

REPEAT_COUNT:   equ     200
TEST_LINE_LEN:  equ     11

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1] is the filename argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no filename given

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (filename)
            mov     rd, atest_fcb       ; RD = our FCB struct
            mov     ra, atest_iobuf     ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     2                   ; mode = append
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    not_found

            plo     rd                  ; stash handle (mov below clobbers D)
            mov     rf, atest_handle
            glo     rd
            str     rf                  ; atest_handle = handle

            mov     rf, remaining
            ldi     REPEAT_COUNT
            str     rf

write_loop:
            mov     rf, remaining
            ldn     rf
            lbz     write_done

            mov     rf, test_line
            ldi     TEST_LINE_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = byte count

            ; see progs/wtest.asm's own note: RD (not RF) is used to
            ; fetch the handle so RF stays pointed at test_line
            mov     rd, atest_handle
            ldn     rd                  ; D = handle, RF untouched
            call    K_FILE_WRITE        ; RC = bytes written, DF=0/1
            lbdf    write_error

            mov     rf, remaining
            ldn     rf
            smi     1
            str     rf

            lbr     write_loop

write_done:
            mov     rd, atest_handle
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Append test complete.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

write_error:
            mov     rd, atest_handle
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "Open/create failed.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: ATEST <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

test_line:      db      "abcdefghij",10
atest_fcb:      ds      FCB_LEN
atest_iobuf:    ds      FCB_IOBUF_LEN
atest_handle:   db      0
remaining:      db      0

            end     start
