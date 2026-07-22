;
; wtest.asm - write-support test utility
;
; Usage: WTEST <filename>
;
; Writes REPEAT_COUNT copies of a fixed test line, starting from the
; beginning (mode 1 -- overwrite-and-extend, not append; see ATEST
; for append-mode testing). If <filename> doesn't already exist,
; file_open now creates it (see kernel/file.asm's fopen_notfound/
; _file_create); if it does, this overwrites its content from
; position 0, same as before file creation existed. Enough total
; bytes are written to span several clusters on a small-cluster test
; filesystem, exercising fat_alloc's chain-extension path end to
; end. Verify afterward with TYPE (content should read back with no
; gaps or corruption across cluster boundaries) and DIR (size should
; equal REPEAT_COUNT * 11).
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
            mov     rd, wtest_fcb       ; RD = our FCB struct
            mov     ra, wtest_iobuf     ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     1                   ; mode = read/write
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; wtest_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    not_found

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

            mov     rd, wtest_fcb       ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at test_line)
            call    K_FILE_WRITE        ; RC = bytes written, DF=0/1
            lbdf    write_error

            mov     rf, remaining
            ldn     rf
            smi     1
            str     rf

            lbr     write_loop

write_done:
            mov     rd, wtest_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write test complete.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

write_error:
            mov     rd, wtest_fcb
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
            db      "Usage: WTEST <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

test_line:      db      "0123456789",10
wtest_fcb:      ds      FCB_LEN
wtest_iobuf:    ds      FCB_IOBUF_LEN
remaining:      db      0

            end     start
