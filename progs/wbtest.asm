;
; wbtest.asm - large deterministic write test
;
; Usage: WBTEST <filename>
;
; Writes a new file, 63828 bytes total, in 64-byte chunks (997 full
; chunks + one final 20-byte chunk) -- matching COPY's own
; COPY_CHUNK_LEN and the exact total size of the file that triggered
; a hardware-observed corruption (fsck found the destination's
; cluster chain short by exactly one cluster vs. its recorded size,
; 2026-07-12). Deliberately bypasses COPY and file_read entirely --
; a synthetic, deterministic fill pattern (an incrementing byte
; counter, wrapping mod 256, continuous across the whole file, not
; reset per chunk) written directly via repeated K_FILE_WRITE calls.
;
; RESULT (2026-07-13): file_write's own cluster-allocation logic is
; confirmed correct -- repeated runs on a clean filename complete and
; pass fsck cleanly. The one run that showed a short cluster chain
; was a duplicate-directory-entry artifact from an earlier, unrelated
; run, not a file_write bug. Kept as a standalone regression test for
; large sequential writes, independent of COPY/file_read.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

CHUNK_LEN:          equ     64      ; matches COPY_CHUNK_LEN
LAST_CHUNK_LEN:     equ     20      ; 63828 - (997*64) = 20

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
            mov     rd, wbtest_fcb      ; RD = our FCB struct
            mov     ra, wbtest_iobuf    ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     1                   ; mode = write (create/truncate)
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    open_error

            plo     r8                  ; R8.0 = handle (temp, mov
                                        ; below clobbers D)
            mov     rf, saved_handle
            glo     r8
            str     rf                  ; saved_handle = handle

            mov     rf, fill_byte
            ldi     0
            str     rf                  ; fill_byte starts at 0,
                                        ; persists across all chunks

            mov     rf, chunks_left_hi
            ldi     $03
            str     rf
            mov     rf, chunks_left_lo
            ldi     $E5
            str     rf                  ; chunks_left = 997 ($03E5)

;------------------------------------------------------------------
; Write 997 full 64-byte chunks.
;------------------------------------------------------------------
wb_full_loop:
            mov     rf, wb_buf
            mov     rd, fill_byte
            ldn     rd
            plo     r7                  ; R7.0 = running fill byte
            ldi     CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = 64 (fill count)
wb_fill_loop:
            glo     r7
            str     rf
            inc     rf
            adi     1
            plo     r7                  ; fill byte++, wraps mod 256
            dec     rc
            glo     rc
            lbnz    wb_fill_loop
            ghi     rc
            lbnz    wb_fill_loop

            mov     rf, fill_byte
            glo     r7
            str     rf                  ; save running fill byte for
                                        ; the next chunk

            mov     rf, wb_buf
            ldi     CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = 64 (write count)
            mov     rd, saved_handle
            ldn     rd                  ; D = handle, RF/RC untouched
            call    K_FILE_WRITE        ; DF = 0/1
            lbdf    write_error

            ; chunks_left -= 1 (16-bit)
            mov     rf, chunks_left_lo
            ldn     rf
            smi     1
            str     rf
            lbdf    wb_full_no_borrow
            mov     rf, chunks_left_hi
            ldn     rf
            smi     1
            str     rf
wb_full_no_borrow:
            mov     rf, chunks_left_hi
            ldn     rf
            lbnz    wb_full_loop
            mov     rf, chunks_left_lo
            ldn     rf
            lbnz    wb_full_loop

;------------------------------------------------------------------
; Write the final 20-byte partial chunk.
;------------------------------------------------------------------
            mov     rf, wb_buf
            mov     rd, fill_byte
            ldn     rd
            plo     r7
            ldi     LAST_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
wb_last_fill_loop:
            glo     r7
            str     rf
            inc     rf
            adi     1
            plo     r7
            dec     rc
            glo     rc
            lbnz    wb_last_fill_loop
            ghi     rc
            lbnz    wb_last_fill_loop

            mov     rf, wb_buf
            ldi     LAST_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
            mov     rd, saved_handle
            ldn     rd
            call    K_FILE_WRITE
            lbdf    write_error

;------------------------------------------------------------------
; Close and report.
;------------------------------------------------------------------
            mov     rd, saved_handle
            ldn     rd
            call    K_FILE_CLOSE        ; result intentionally ignored

            call    K_INMSG
            db      "Write complete (63828 bytes). Run fsck to check.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

open_error:
            call    K_INMSG
            db      "Cannot create file.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: WBTEST <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

write_error:
            mov     rd, saved_handle
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

wbtest_fcb:         ds      FCB_LEN
wbtest_iobuf:       ds      FCB_IOBUF_LEN
saved_handle:       db      0
fill_byte:          db      0
chunks_left_hi:     db      0
chunks_left_lo:     db      0
wb_buf:             ds      CHUNK_LEN

            end     start
