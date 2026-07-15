;
; more.asm - page through a file's contents, stopping every screenful
;
; Usage: MORE <filename>
;
; Prints the file exactly like TYPE, but pauses after every
; MORE_PAGE_LINES lines with a "-- More --" prompt; any key continues,
; 'Q'/'q' quits early (closes the file and exits cleanly, not an
; error). Line counting is based on LF ('\n', $0A) bytes only, so both
; bare-LF and CRLF-terminated files page correctly (a lone CR is never
; counted, and is printed like any other byte via K_TYPE).
;
; There's no way to query the console's actual terminal height on this
; hardware/BIOS, so MORE_PAGE_LINES is a fixed, conservative guess (23
; lines, leaving room for the prompt itself on a common 24-line
; terminal) -- adjust below if your terminal is a different size.
;
; The line counter and the mid-chunk RF/RC save are all kept in memory
; rather than registers across K_TYPE/K_READ/K_TTY/K_INMSG -- this
; project has only confirmed R9's survival across f_msg/f_inmsg
; (CLAUDE.md gotcha #8), and none of those four calls have been
; separately audited for any other register, so a register stash
; across any of them would be an unverified assumption (see
; progs/copy.asm's own Y/N prompt for the same reasoning, reused
; here). RF/RC are the one exception -- progs/type.asm's own hot loop
; already proves both survive a K_TYPE call, hardware-confirmed.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

MORE_CHUNK_LEN:  equ    64
MORE_PAGE_LINES: equ    23

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
            db      "Usage: MORE <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = filename
            mov     rd, more_fcb        ; RD = our FCB struct
            mov     ra, more_iobuf      ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    not_found

            plo     rd                  ; stash handle (mov below
                                        ; clobbers D)
            mov     rf, more_handle
            glo     rd
            str     rf                  ; more_handle = handle

            mov     rf, more_lines
            ldi     0
            str     rf                  ; more_lines = 0

read_loop:
            mov     rf, more_buf
            ldi     MORE_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = chunk size requested
            mov     rd, more_handle
            ldn     rd                  ; D = handle, RF untouched
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    io_error

            glo     rc
            lbnz    have_bytes
            ghi     rc
            lbz     done                ; 0 bytes: EOF
have_bytes:
            mov     rf, more_buf
print_loop:
            glo     rc
            lbnz    print_have
            ghi     rc
            lbz     read_loop           ; chunk exhausted: read the next one
print_have:
            ldn     rf                  ; D = next byte (peek only --
                                        ; RF unchanged so far)
            xri     10                  ; LF?
            lbnz    pl_print

            mov     rb, more_lines      ; bump the line counter --
            ldn     rb                  ; kept in memory, not a
            adi     1                   ; register, so nothing needs
            str     rb                  ; to survive across K_TYPE below

pl_print:
            lda     rf                  ; D = the byte, RF++ (fresh
                                        ; read -- the xri/adi above may
                                        ; have destroyed D)
            call    K_TYPE
            dec     rc

            mov     rb, more_lines
            ldn     rb
            smi     MORE_PAGE_LINES
            lbnf    print_loop          ; not yet a full page

            ; a full page has been printed -- save the mid-chunk
            ; position (RF/RC) before the pause prompt, since none of
            ; K_INMSG/K_READ/K_TTY are audited for what they clobber
            mov     rb, more_save_rf
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            mov     rb, more_save_rc
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            call    K_INMSG
            db      "-- More --",0
            call    K_READ              ; D = key pressed (blocking)

            plo     rc                  ; very short-lived stash, not
                                        ; across a call -- just to
                                        ; survive "mov rf, more_key"'s
                                        ; own D-clobber (gotcha #4)
            mov     rf, more_key
            glo     rc
            str     rf                  ; more_key = key pressed

            mov     rf, more_key
            ldn     rf
            call    K_TTY               ; echo it back
            call    K_INMSG
            db      13,10,0

            mov     rf, more_lines
            ldi     0
            str     rf                  ; reset the page counter

            mov     rf, more_key
            ldn     rf
            ani     $DF                 ; uppercase-fold
            xri     'Q'
            lbz     quit

            ; restore the mid-chunk position and keep printing
            mov     rb, more_save_rf
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rb, more_save_rc
            lda     rb
            phi     rc
            ldn     rb
            plo     rc
            lbr     print_loop

done:
            mov     rf, more_handle
            ldn     rf
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success
            rtn

quit:
            mov     rf, more_handle
            ldn     rf
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 -- quitting early
                                        ; isn't an error
            rtn

io_error:
            mov     rf, more_handle
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

more_fcb:       ds      FCB_LEN
more_iobuf:     ds      FCB_IOBUF_LEN
more_handle:    db      0
more_buf:       ds      MORE_CHUNK_LEN
more_lines:     db      0
more_key:       db      0
more_save_rf:   dw      0
more_save_rc:   dw      0

            end     start
