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
            ; RA = command tail = the filename argument
            ldn     ra
            lbnz    have_name

            call    K_INMSG
            db      "Usage: TYPE <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = filename
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    not_found

            ; BUG FIX: "mov rf, type_fcb" itself clobbers D (its final
            ; LDI leaves D = type_fcb's own low address byte), so the
            ; FCB index just returned in D would not survive to the
            ; "str rf" below unless stashed first.
            plo     rd                  ; stash FCB index (mov below clobbers D)
            mov     rf, type_fcb
            glo     rd                  ; D = FCB index (reloaded)
            str     rf                  ; type_fcb = FCB index (see note
                                        ; below on why this isn't kept
                                        ; in a register)

;------------------------------------------------------------------
; Read/print loop.
;
; type_fcb (not a register) holds the FCB index across K_FILE_READ
; calls: file_read uses R9 as its own internal scratch and leaves it
; holding unrelated data (the bytes-read count) on return, so nothing
; kept in a register here would survive the call.
;------------------------------------------------------------------
read_loop:
            mov     rf, type_buf
            ldi     TYPE_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = chunk size requested
            ; BUG FIX: file_read needs RF pointed at the destination
            ; buffer (type_buf, set above) AND D = FCB index at the same
            ; time -- fetching the index via "mov rf, type_fcb" would
            ; clobber RF away from type_buf, so RD is used instead.
            mov     rd, type_fcb
            ldn     rd                  ; D = FCB index, RF untouched
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
            mov     rf, type_fcb
            ldn     rf                  ; D = FCB index
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success
            rtn

io_error:
            mov     rf, type_fcb
            ldn     rf
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

type_fcb:       db      0
type_buf:       ds      TYPE_CHUNK_LEN

            end     start
