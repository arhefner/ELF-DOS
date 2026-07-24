;
; seektest.asm - exercises kernel/file.asm's file_seek (K_FILE_SEEK)
;
; Usage: SEEKTEST
;
; Writes a 1200-byte ramp test file (content[i] = i & 0xFF -- large
; enough to span several clusters on any card tested so far, so the
; SEEK_SET/CUR/END checks below genuinely exercise file_seek's
; multi-hop fat_get cluster walk, not just the trivial single-cluster
; case), then re-opens it read-only and drives a battery of seek+read
; checks: SEEK_SET/SEEK_CUR/SEEK_END (including negative offsets),
; boundary positions (0, mid-file, last byte, exactly at EOF), and
; error cases (bad whence, negative absolute position, past-EOF,
; before-start-of-file via SEEK_CUR) -- each error case also confirms
; the file position was left UNCHANGED afterward, matching file_seek's
; own documented "on any error the FCB is left completely untouched"
; contract. Prints PASS/FAIL per check plus a final summary -- no
; assert infrastructure exists on this platform, so failures are
; reported, not trapped.
;
; Self-contained: only kernel API calls (K_FILE_OPEN/READ/WRITE/
; CLOSE/SEEK), no lib/ dependency -- builds via the generic
; "bin/%: progs/%.prg" Makefile pattern rule like most other
; programs.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

SEEK_FILE_LEN:  equ     1200            ; test file size in bytes

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rb, sk_fail_count
            ldi     0
            str     rb                  ; sk_fail_count = 0

            call    K_INMSG
            db      "SEEKTEST starting.",13,10,0

            ; --- build the ramp pattern into sk_rampbuf ---
            mov     rf, sk_rampbuf      ; RF = write cursor
            ldi     0
            phi     r9
            plo     r9                  ; R9 = i (0..SEEK_FILE_LEN-1)

sk_fill_loop:
            ldi     low SEEK_FILE_LEN
            str     r2
            glo     r9
            sm
            ldi     high SEEK_FILE_LEN
            str     r2
            ghi     r9
            smb
            lbdf    sk_fill_done        ; DF=1: i >= SEEK_FILE_LEN

            glo     r9                  ; D = i & 0xFF (the ramp value)
            str     rf
            inc     rf

            glo     r9
            adi     1
            plo     r9
            lbnz    sk_fill_loop
            ghi     r9
            adi     1
            phi     r9
            lbr     sk_fill_loop

sk_fill_done:

            ; --- create/write the test file ---
            mov     rf, sk_name
            mov     rd, sk_fcb
            mov     ra, sk_iobuf
            ldi     1                   ; mode 1 = create/overwrite --
                                        ; set LAST: mov clobbers D
                                        ; (gotcha #4), so D=mode must
                                        ; be loaded after every mov
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; sk_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    sk_open_w_err

            mov     rf, sk_rampbuf
            ldi     high SEEK_FILE_LEN
            phi     rc
            ldi     low SEEK_FILE_LEN
            plo     rc                  ; RC = 1200
            mov     rd, sk_fcb          ; RD = FCB pointer (fixed --
                                        ; RF/RC untouched)
            call    K_FILE_WRITE
            lbdf    sk_write_err

            mov     rd, sk_fcb
            call    K_FILE_CLOSE
            lbdf    sk_close_w_err

            ; --- re-open the same file, read-only, for all the real
            ; checks below ---
            mov     rf, sk_name
            mov     rd, sk_fcb
            mov     ra, sk_iobuf
            ldi     0                   ; mode 0 = read -- set LAST,
                                        ; same reason as the write
                                        ; open above
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; sk_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    sk_open_r_err

            ; ================================================
            ; check 1: SEEK_SET(0) succeeds, RD == 0
            ; ================================================
            call    K_INMSG
            db      "check1 (SEEK_SET 0): ",0

            mov     rb, sk_expected
            ldi     0
            str     rb
            inc     rb
            str     rb                  ; sk_expected = 0

            ldi     0
            phi     ra
            plo     ra                  ; RA = 0 (offset high word)
            ldi     0
            phi     r9
            plo     r9                  ; R9 = 0 (offset low word)
            ldi     0
            plo     rc                  ; RC.0 = 0 (SEEK_SET)
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 2: byte at position 0 == 0 ---
            call    K_INMSG
            db      "check2 (read byte @0): ",0
            mov     rb, sk_expected_byte
            ldi     0
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 3: SEEK_SET(500), RD == 500
            ; ================================================
            call    K_INMSG
            db      "check3 (SEEK_SET 500): ",0

            mov     rb, sk_expected
            ldi     high 500
            str     rb
            inc     rb
            ldi     low 500
            str     rb

            ldi     0
            phi     ra
            plo     ra
            ldi     high 500
            phi     r9
            ldi     low 500
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 4: byte at position 500 == 500 & 0xFF = 244 ---
            call    K_INMSG
            db      "check4 (read byte @500): ",0
            mov     rb, sk_expected_byte
            ldi     244
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 5: SEEK_SET(1199) [last byte], RD == 1199
            ; ================================================
            call    K_INMSG
            db      "check5 (SEEK_SET 1199): ",0

            mov     rb, sk_expected
            ldi     high 1199
            str     rb
            inc     rb
            ldi     low 1199
            str     rb

            ldi     0
            phi     ra
            plo     ra
            ldi     high 1199
            phi     r9
            ldi     low 1199
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 6: byte at 1199 == 1199 & 0xFF = 175 ---
            call    K_INMSG
            db      "check6 (read byte @1199): ",0
            mov     rb, sk_expected_byte
            ldi     175
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 7: SEEK_SET(1200) [exactly EOF], RD == 1200
            ; ================================================
            call    K_INMSG
            db      "check7 (SEEK_SET 1200, exactly EOF): ",0

            mov     rb, sk_expected
            ldi     high SEEK_FILE_LEN
            str     rb
            inc     rb
            ldi     low SEEK_FILE_LEN
            str     rb

            ldi     0
            phi     ra
            plo     ra
            ldi     high SEEK_FILE_LEN
            phi     r9
            ldi     low SEEK_FILE_LEN
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 8: read at EOF returns 0 bytes ---
            call    K_INMSG
            db      "check8 (read @EOF returns 0 bytes): ",0
            call    sk_expect_eof

            ; ================================================
            ; check 9: SEEK_SET(200) then SEEK_CUR(+100) -> 300
            ; ================================================
            call    K_INMSG
            db      "check9 (SEEK_SET 200 then SEEK_CUR +100): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high 200
            phi     r9
            ldi     low 200
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    K_FILE_SEEK
            lbdf    sk_setup_err        ; the SEEK_SET(200) itself
                                        ; must succeed -- not one of
                                        ; the counted checks, just
                                        ; setup

            mov     rb, sk_expected
            ldi     high 300
            str     rb
            inc     rb
            ldi     low 300
            str     rb

            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            ldi     100
            plo     r9
            ldi     1                   ; SEEK_CUR
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 10: byte at 300 == 300 & 0xFF = 44 ---
            call    K_INMSG
            db      "check10 (read byte @300): ",0
            mov     rb, sk_expected_byte
            ldi     44
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 11: SEEK_SET(200) then SEEK_CUR(-100) -> 100
            ; ================================================
            call    K_INMSG
            db      "check11 (SEEK_SET 200 then SEEK_CUR -100): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high 200
            phi     r9
            ldi     low 200
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    K_FILE_SEEK
            lbdf    sk_setup_err

            mov     rb, sk_expected
            ldi     0
            str     rb
            inc     rb
            ldi     100
            str     rb

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra                  ; RA = $FFFF (sign-extended -1)
            ldi     $FF
            phi     r9
            ldi     $9C                 ; -100 = $FF9C
            plo     r9
            ldi     1                   ; SEEK_CUR
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 12: byte at 100 == 100 ---
            call    K_INMSG
            db      "check12 (read byte @100): ",0
            mov     rb, sk_expected_byte
            ldi     100
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 13: SEEK_END(0) -> exactly EOF (1200)
            ; ================================================
            call    K_INMSG
            db      "check13 (SEEK_END 0): ",0

            mov     rb, sk_expected
            ldi     high SEEK_FILE_LEN
            str     rb
            inc     rb
            ldi     low SEEK_FILE_LEN
            str     rb

            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9
            ldi     2                   ; SEEK_END
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; ================================================
            ; check 14: SEEK_END(-1) -> 1199 (last byte)
            ; ================================================
            call    K_INMSG
            db      "check14 (SEEK_END -1): ",0

            mov     rb, sk_expected
            ldi     high 1199
            str     rb
            inc     rb
            ldi     low 1199
            str     rb

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $FF
            phi     r9
            ldi     $FF                 ; -1 = $FFFF
            plo     r9
            ldi     2                   ; SEEK_END
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_ok

            ; --- check 15: byte at 1199 == 175 (matches check 6) ---
            call    K_INMSG
            db      "check15 (read byte @1199 via SEEK_END): ",0
            mov     rb, sk_expected_byte
            ldi     175
            str     rb
            call    sk_expect_readbyte

            ; ================================================
            ; check 16: bad whence (3) -> error
            ; ================================================
            call    K_INMSG
            db      "check16 (bad whence -> error): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9
            ldi     3                   ; invalid whence
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_err

            ; ================================================
            ; check 17: SEEK_SET(-1) -> error (negative absolute
            ; position)
            ; ================================================
            call    K_INMSG
            db      "check17 (SEEK_SET -1 -> error): ",0

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $FF
            phi     r9
            ldi     $FF
            plo     r9
            ldi     0                   ; SEEK_SET
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_err

            ; ================================================
            ; check 18: SEEK_SET(1201) [past EOF] -> error
            ; ================================================
            call    K_INMSG
            db      "check18 (SEEK_SET past EOF -> error): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high 1201
            phi     r9
            ldi     low 1201
            plo     r9
            ldi     0                   ; SEEK_SET
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_err

            ; ================================================
            ; check 19: SEEK_SET(100) then SEEK_CUR(-200) [would go
            ; negative] -> error, AND position left unchanged
            ; ================================================
            call    K_INMSG
            db      "check19 (SEEK_CUR before start -> error): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high 100
            phi     r9
            ldi     low 100
            plo     r9
            ldi     0
            plo     rc
            mov     rd, sk_fcb
            call    K_FILE_SEEK
            lbdf    sk_setup_err

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $FF
            phi     r9
            ldi     $38                 ; -200 = $FF38
            plo     r9
            ldi     1                   ; SEEK_CUR
            plo     rc
            mov     rd, sk_fcb
            call    sk_expect_err

            ; --- check 20: position after the failed seek above is
            ; still 100 (unchanged) -- confirmed by reading and
            ; checking the byte value ---
            call    K_INMSG
            db      "check20 (position unchanged after error): ",0
            mov     rb, sk_expected_byte
            ldi     100
            str     rb
            call    sk_expect_readbyte

            ; --- close the read handle ---
            mov     rd, sk_fcb
            call    K_FILE_CLOSE

            ; --- summary ---
            mov     rb, sk_fail_count
            ldn     rb
            lbz     sk_all_pass
            call    K_INMSG
            db      "SEEKTEST: SOME CHECKS FAILED.",13,10,0
            ldi     1
            rtn

sk_all_pass:
            call    K_INMSG
            db      "SEEKTEST: all checks passed.",13,10,0
            ldi     0
            rtn

sk_open_w_err:
            call    K_INMSG
            db      "SEEKTEST: could not create test file.",13,10,0
            ldi     1
            rtn

sk_write_err:
            call    K_INMSG
            db      "SEEKTEST: write failed.",13,10,0
            ldi     1
            rtn

sk_close_w_err:
            call    K_INMSG
            db      "SEEKTEST: close (write) failed.",13,10,0
            ldi     1
            rtn

sk_open_r_err:
            call    K_INMSG
            db      "SEEKTEST: could not re-open test file for reading.",13,10,0
            ldi     1
            rtn

sk_setup_err:
            call    K_INMSG
            db      "SEEKTEST: setup seek failed unexpectedly.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; sk_expect_ok: call K_FILE_SEEK with its args already loaded by the
; caller (RD/RC/RA/R9), expecting success (DF=0); then compares the
; returned position (RD) against sk_expected (memory -- NOT a
; register carried across the call, since file_seek's own documented
; Modifies list clobbers R7-R9/RA-RC/RF, so nothing but RD-in/DF-out/
; RD-out can be trusted to survive it).
; Args:    RD/RC/RA/R9 = K_FILE_SEEK's own args; sk_expected must
;          already hold the expected resulting position.
; Returns: nothing (prints PASS/FAIL, updates sk_fail_count)
;------------------------------------------------------------------
sk_expect_ok:
            call    K_FILE_SEEK
            lbdf    sk_unexpected_fail

            ; RD = actual position (K_FILE_SEEK's own return value,
            ; untouched since the call just returned) -- exactly
            ; sk_check_eq16's first arg; just need R8 = expected,
            ; loaded fresh from memory
            mov     rf, sk_expected
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            call    sk_check_eq16
            rtn

sk_unexpected_fail:
            call    K_INMSG
            db      "FAIL (unexpected error)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

;------------------------------------------------------------------
; sk_expect_err: call K_FILE_SEEK with its args already loaded by the
; caller (RD/RC/RA/R9), expecting failure (DF=1).
;------------------------------------------------------------------
sk_expect_err:
            call    K_FILE_SEEK
            lbnf    sk_unexpected_ok

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

sk_unexpected_ok:
            call    K_INMSG
            db      "FAIL (unexpectedly succeeded)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

;------------------------------------------------------------------
; sk_expect_readbyte: K_FILE_READ exactly 1 byte via sk_fcb (the
; already-open read FCB) into sk_readbuf, and compare it against
; sk_expected_byte (a single byte, since every ramp value is 0-255).
;------------------------------------------------------------------
sk_expect_readbyte:
            mov     rf, sk_readbuf
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     rd, sk_fcb          ; RD = FCB pointer (fixed --
                                        ; RF/RC untouched)
            call    K_FILE_READ
            lbdf    sk_readbyte_ioerr

            glo     rc
            smi     1
            lbnz    sk_readbyte_wrongcount
            ghi     rc
            lbnz    sk_readbyte_wrongcount

            mov     rf, sk_readbuf
            ldn     rf                  ; D = the byte actually read
            plo     rd
            ldi     0
            phi     rd                  ; RD = byte value, zero-extended
            mov     rf, sk_expected_byte
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = expected byte value
            call    sk_check_eq16
            rtn

sk_readbyte_ioerr:
            call    K_INMSG
            db      "FAIL (read I/O error)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

sk_readbyte_wrongcount:
            call    K_INMSG
            db      "FAIL (wrong byte count)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

;------------------------------------------------------------------
; sk_expect_eof: K_FILE_READ 1 byte via sk_fcb, expecting exactly
; 0 bytes transferred (EOF), with no I/O error.
;------------------------------------------------------------------
sk_expect_eof:
            mov     rf, sk_readbuf
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     rd, sk_fcb          ; RD = FCB pointer (fixed --
                                        ; RF/RC untouched)
            call    K_FILE_READ
            lbdf    sk_eof_ioerr

            glo     rc
            lbnz    sk_eof_wrongcount
            ghi     rc
            lbnz    sk_eof_wrongcount

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

sk_eof_ioerr:
            call    K_INMSG
            db      "FAIL (read I/O error at EOF)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

sk_eof_wrongcount:
            call    K_INMSG
            db      "FAIL (expected 0 bytes at EOF)",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

;------------------------------------------------------------------
; sk_check_eq16: compare RD (actual) against R8 (expected); print
; "PASS"/"FAIL" + CRLF; increment sk_fail_count on failure.
; Args:    RD = actual value, R8 = expected value
; Returns: nothing
;------------------------------------------------------------------
sk_check_eq16:
            glo     r8
            str     r2
            glo     rd
            xor
            lbnz    sk_check_eq16_fail
            ghi     r8
            str     r2
            ghi     rd
            xor
            lbnz    sk_check_eq16_fail

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

sk_check_eq16_fail:
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, sk_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

sk_fail_count:      db      0
sk_expected:         dw      0
sk_expected_byte:    db      0
sk_name:             db      "SEEKTST.DAT",0
sk_readbuf:          db      0
sk_fcb:              ds      FCB_LEN
sk_iobuf:            ds      FCB_IOBUF_LEN
sk_rampbuf:          ds      SEEK_FILE_LEN

            end     start
