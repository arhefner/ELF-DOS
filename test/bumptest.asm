;
; bumptest.asm - exercises lib/heap_bump.asm against real memory
;
; Usage: BUMPTEST
;
; Initializes the bump allocator over [mem_base..mem_top] (read from
; LOADER_ARGS, the same bounds a real caller would use -- see
; lib/heap_bump.asm's own header), then runs a battery of checks:
; monotonically-advancing allocation addresses, mark/release
; (allocate, mark, allocate more, release back to the mark, confirm
; the next allocation reuses exactly the marked address), and
; exhaustion (a request bigger than what's left must fail cleanly).
; Prints PASS/FAIL per check plus a final summary -- no assert
; infrastructure exists on this platform, so failures are reported,
; not trapped.
;
; Links against lib/heap_bump.prg -- this is NOT a self-contained
; single-file program like most of progs/*.asm; see the Makefile's
; own dedicated rule for it.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   bump_init
            extrn   bump_alloc
            extrn   bump_mark
            extrn   bump_release

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rb, bt_fail_count
            ldi     0
            str     rb                  ; bt_fail_count = 0

            call    K_INMSG
            db      "BUMPTEST starting.",13,10,0

            ; --- init over the real [mem_base..mem_top] range ---
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rb, bt_base
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; bt_base = mem_base

            mov     rf, LOADER_ARGS
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top

            ; RD is still mem_base -- bump_init's own args
            mov     rf, r8              ; RF = mem_top
            call    bump_init

            ; --- check 1: first alloc returns exactly bt_base ---
            call    K_INMSG
            db      "check1 (first alloc == base): ",0

            ldi     0
            phi     rc
            ldi     50
            plo     rc                  ; RC = 50
            call    bump_alloc          ; RF = pointer
            mov     rb, bt_p1
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; bt_p1 = RF

            mov     rb, bt_p1
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = bt_p1 (actual)
            mov     rb, bt_base
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = bt_base (expected)
            call    bt_check_eq

            ; --- check 2: second alloc == first + 50 ---
            call    K_INMSG
            db      "check2 (second alloc == first+50): ",0

            ldi     0
            phi     rc
            ldi     30
            plo     rc                  ; RC = 30
            call    bump_alloc
            mov     rb, bt_p2
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; bt_p2 = RF

            mov     rb, bt_p1
            lda     rb
            phi     rd
            ldn     rb
            plo     rd
            add16   rd, 50               ; RD = bt_p1 + 50 (expected)
            mov     rb, bt_p2
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = bt_p2 (actual)
            call    bt_check_eq

            ; --- check 3: mark/alloc/release/alloc reuses the mark ---
            call    K_INMSG
            db      "check3 (release then alloc reuses mark): ",0

            call    bump_mark           ; RF = current pointer
            mov     rb, bt_mark
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; bt_mark = RF

            ldi     0
            phi     rc
            ldi     200
            plo     rc                  ; RC = 200 (temporary --
                                        ; result unused, just
                                        ; advancing the pointer so
                                        ; there's something real for
                                        ; release to undo)
            call    bump_alloc

            mov     rb, bt_mark
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = bt_mark
            call    bump_release

            ldi     0
            phi     rc
            ldi     10
            plo     rc                  ; RC = 10
            call    bump_alloc
            mov     rb, bt_p3
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; bt_p3 = RF

            mov     rb, bt_mark
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = bt_mark (expected)
            mov     rb, bt_p3
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = bt_p3 (actual)
            call    bt_check_eq

            ; --- check 4: a request larger than what's left fails
            ; cleanly (returns 0) ---
            call    K_INMSG
            db      "check4 (huge request fails cleanly): ",0

            ldi     $FF
            phi     rc
            ldi     $FF
            plo     rc                  ; RC = 65535 -- certainly
                                        ; larger than any real heap
                                        ; on this hardware
            call    bump_alloc
            ldi     0
            phi     r8
            plo     r8                  ; R8 = 0 (expected: failure)
            mov     rd, rf              ; RD = actual result
            call    bt_check_eq

            ; --- summary ---
            mov     rb, bt_fail_count
            ldn     rb
            lbz     bt_all_pass
            call    K_INMSG
            db      "BUMPTEST: SOME CHECKS FAILED.",13,10,0
            ldi     1
            rtn

bt_all_pass:
            call    K_INMSG
            db      "BUMPTEST: all checks passed.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; bt_check_eq: compare RD (actual) against R8 (expected); print
; "PASS"/"FAIL" + CRLF; increment bt_fail_count on failure.
; Args:    RD = actual value, R8 = expected value
; Returns: nothing
;------------------------------------------------------------------
bt_check_eq:
            glo     r8
            str     r2
            glo     rd
            xor
            lbnz    bt_check_eq_fail
            ghi     r8
            str     r2
            ghi     rd
            xor
            lbnz    bt_check_eq_fail

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

bt_check_eq_fail:
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, bt_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

bt_fail_count:  db      0
bt_base:        dw      0
bt_p1:          dw      0
bt_p2:          dw      0
bt_p3:          dw      0
bt_mark:        dw      0

            end     start
