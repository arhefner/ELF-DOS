;
; type.asm - display the contents of a file
;
; Usage: TYPE <filename>
;
; Reads the file in small chunks and writes each byte straight to
; the console via K_TYPE -- no line-ending translation, matching
; classic TYPE/cat behavior (the file is expected to already use
; whatever line endings the console wants, typically CR+LF).
;

#include    include/opcodes.def
#include    include/kernel_api.inc

TYPE_CHUNK_LEN: equ     64

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
            mov     rd, type_fcb        ; RD = our FCB struct
            mov     ra, type_iobuf      ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; type_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    not_found

;------------------------------------------------------------------
; Read/print loop.
;------------------------------------------------------------------
read_loop:
            mov     rf, type_buf
            ldi     TYPE_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = chunk size requested
            mov     rd, type_fcb        ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at type_buf)
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    io_error            ; check DF first, before anything below

            ; done if 0 bytes were read (EOF)
            glo     rc
            lbnz    have_bytes
            ghi     rc
            lbz     done
have_bytes:
            mov     rf, type_buf
print_loop:
            glo     rc
            lbnz    print_have
            ghi     rc
            lbz     read_loop           ; chunk exhausted: read the next one
print_have:
            lda     rf                  ; D = next byte, RF++
            call    K_TYPE
            dec     rc
            lbr     print_loop

done:
            mov     rd, type_fcb
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success
            rtn

io_error:
            mov     rd, type_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: TYPE <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

type_fcb:       ds      FCB_LEN
type_iobuf:     ds      FCB_IOBUF_LEN
type_buf:       ds      TYPE_CHUNK_LEN

            end     start
