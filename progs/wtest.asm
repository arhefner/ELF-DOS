;
; wtest.asm - write-support test utility
;
; Usage: WTEST <filename>
;
; Writes REPEAT_COUNT copies of a fixed test line to an EXISTING
; file (file_write only extends/overwrites already-existing files --
; see kernel/file.asm), starting from the beginning. Enough total
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
            ldn     ra
            lbnz    have_name

            call    K_INMSG
            db      "Usage: WTEST <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = filename
            ldi     1                   ; mode = read/write
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    not_found

            plo     rd                  ; stash FCB index (mov below clobbers D)
            mov     rf, wtest_fcb
            glo     rd
            str     rf                  ; wtest_fcb = FCB index

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

            ; BUG FIX (see progs/type.asm): file_write needs RF
            ; pointed at the source buffer (test_line, set above) AND
            ; D = FCB index at the same time -- fetching the index
            ; via "mov rf, wtest_fcb" would clobber RF away from
            ; test_line, so RD is used instead.
            mov     rd, wtest_fcb
            ldn     rd                  ; D = FCB index, RF untouched
            call    K_FILE_WRITE        ; RC = bytes written, DF=0/1
            lbdf    write_error

            mov     rf, remaining
            ldn     rf
            smi     1
            str     rf

            lbr     write_loop

write_done:
            mov     rd, wtest_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write test complete.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

write_error:
            mov     rd, wtest_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

test_line:      db      "0123456789",10
wtest_fcb:      db      0
remaining:      db      0

            end     start
