;
; copy.asm - copy a file
;
; Usage: COPY <source> <destination>
;
; Single file to single file only -- no wildcards, no directory
; trees. <source> must already exist (opened mode 0, read); the
; destination is created if it doesn't exist, or overwritten from
; position 0 if it does (opened mode 1, same create-or-overwrite
; semantics as WTEST), matching classic DOS COPY (not append)
; behavior. Both arguments may be full paths, e.g.
; "COPY /cfg/env.dat backup.dat" -- K_FILE_OPEN already resolves
; paths internally (see K_PATH_RESOLVE), so nothing special is
; needed here for that.
;
; Copying a file onto itself is not specially detected or guarded
; against -- it will open the same file twice, for read and write
; simultaneously, and produce garbled results (this hardware's
; single shared io_buf sector cache means only one FCB's sector can
; be resident at a time). Don't do that.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

COPY_CHUNK_LEN: equ     64

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = command tail = "<source> <destination>"
            ldn     ra
            lbz     usage_error

            ; find the space separating the two arguments
            mov     rf, ra
scan_src_end:
            ldn     rf
            lbz     usage_error         ; only one token: no destination
            xri     ' '
            lbz     have_src_end
            inc     rf
            lbr     scan_src_end
have_src_end:
            ldi     0
            str     rf                  ; null-terminate source in place
            inc     rf

            ; skip any additional spaces before the destination
skip_spaces:
            ldn     rf
            xri     ' '
            lbnz    have_dst
            inc     rf
            lbr     skip_spaces
have_dst:
            ldn     rf
            lbz     usage_error         ; nothing after the spaces

            ; save both pointers in memory: RA is still the (now
            ; null-terminated) source string, RF the destination
            ; string; both get clobbered by the K_FILE_OPEN calls
            ; below, so neither can stay in a register
            mov     rb, src_ptr
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; src_ptr = source string pointer

            mov     rb, dst_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; dst_ptr = destination string ptr

            ; --- open source (mode 0, read) ---
            mov     rf, src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source string
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    src_not_found

            plo     rd                  ; stash FCB index (mov below
                                        ; clobbers D)
            mov     rf, src_fcb
            glo     rd
            str     rf                  ; src_fcb = FCB index

            ; TEMPORARY DIAGNOSTIC: print dst_ptr's string here, in
            ; copy.asm's OWN code, entirely outside the kernel --
            ; bisecting whether the destination name is already
            ; corrupted before the second K_FILE_OPEN call even runs,
            ; or whether it gets corrupted inside file_open/
            ; path_resolve itself (ren8.txt/ren9.txt: destination
            ; shows up as "ini " instead of "init5.rc")
            call    K_INMSG
            db      13,10,"DIAG copy dst_ptr='",0
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            ; --- open destination (mode 1, create-or-overwrite) ---
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination string
            ldi     1                   ; mode = write
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    dst_open_error

            plo     rd
            mov     rf, dst_fcb
            glo     rd
            str     rf                  ; dst_fcb = FCB index

;------------------------------------------------------------------
; Copy loop: read a chunk from source, write the same chunk (exact
; byte count K_FILE_READ actually returned) to destination.
;------------------------------------------------------------------
copy_loop:
            mov     rf, copy_buf
            ldi     COPY_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = chunk size requested
            mov     rd, src_fcb
            ldn     rd                  ; D = FCB index, RF untouched
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    read_error

            glo     rc
            lbnz    have_bytes
            ghi     rc
            lbz     copy_done           ; 0 bytes read: source EOF
have_bytes:
            mov     rf, copy_buf        ; RF = source buffer (RC still
                                        ; holds the byte count from
                                        ; K_FILE_READ -- mov only
                                        ; touches RF/D, not RC)
            mov     rd, dst_fcb
            ldn     rd                  ; D = FCB index, RF untouched
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    write_error

            lbr     copy_loop

copy_done:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "File copied.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

read_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

write_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

dst_open_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            ldi     1
            rtn

src_not_found:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: COPY <source> <destination>",13,10,0
            ldi     1
            rtn

src_ptr:    dw      0
dst_ptr:    dw      0
src_fcb:    db      0
dst_fcb:    db      0
copy_buf:   ds      COPY_CHUNK_LEN

            end     start
