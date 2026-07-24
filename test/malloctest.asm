;
; malloctest.asm - exercises lib/heap_malloc.asm against real memory
;
; Usage: MALLOCTEST
;
; Initializes the general-purpose allocator over [mem_base..mem_top]
; (read from LOADER_ARGS, the same bounds a real caller would use --
; see lib/heap_malloc.asm's own header), then runs an 11-check battery
; covering: basic allocation, data-integrity/no-overlap (fill each
; block with a distinct byte pattern and verify it survives later
; allocations untouched), free+realloc slot reuse, and -- the part
; that actually exercises the coalescing logic, not just declares it
; -- freeing three adjacent blocks in an order specifically chosen to
; hit forward coalescing, then a combined backward+forward 3-way
; merge, then proving the WHOLE heap is one contiguous block again by
; successfully allocating its full original size back. Prints
; PASS/FAIL per check plus a final summary.
;
; Links against lib/heap_malloc.prg -- this is NOT a self-contained
; single-file program like most of progs/*.asm; see the Makefile's
; own dedicated rule for it.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   heap_init
            extrn   heap_alloc
            extrn   heap_free

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rb, mt_fail_count
            ldi     0
            str     rb                  ; mt_fail_count = 0

            call    K_INMSG
            db      "MALLOCTEST starting.",13,10,0

            ; --- init over the real [mem_base..mem_top] range ---
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rb, mt_base
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; mt_base = mem_base

            mov     rf, LOADER_ARGS
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top
            mov     rb, mt_top
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb                  ; mt_top = mem_top

            ; total_usable = mem_top - mem_base - 1 (same arithmetic
            ; as heap_init's own: (top-base+1)-2)
            mov     rd, r8              ; RD = mem_top
            mov     rb, mt_base
            lda     rb
            phi     ra
            ldn     rb
            plo     ra                  ; RA = mem_base
            sub16   rd, ra
            sub16   rd, 1               ; RD = total_usable
            mov     rb, mt_total
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; mt_total = total_usable

            ; heap_init(RD=base, RF=top) -- reload both fresh
            mov     rf, mt_base
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rb, mt_top
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = mem_top
            call    heap_init

            ; --- checks 1-3: three basic allocations succeed ---
            call    K_INMSG
            db      "check1 (alloc 50 succeeds): ",0
            ldi     0
            phi     rc
            ldi     50
            plo     rc
            call    heap_alloc          ; RF = p1
            mov     rb, mt_p1
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; mt_p1 = RF
            mov     rd, rf
            call    mt_check_nonzero

            call    K_INMSG
            db      "check2 (alloc 30 succeeds): ",0
            ldi     0
            phi     rc
            ldi     30
            plo     rc
            call    heap_alloc          ; RF = p2
            mov     rb, mt_p2
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; mt_p2 = RF
            mov     rd, rf
            call    mt_check_nonzero

            call    K_INMSG
            db      "check3 (alloc 20 succeeds): ",0
            ldi     0
            phi     rc
            ldi     20
            plo     rc
            call    heap_alloc          ; RF = p3
            mov     rb, mt_p3
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; mt_p3 = RF
            mov     rd, rf
            call    mt_check_nonzero

            ; --- checks 4-6: fill each block with a distinct
            ; pattern, verify it reads back intact (no overlap
            ; between adjacent blocks) ---
            call    K_INMSG
            db      "check4 (p1 pattern intact): ",0
            mov     rb, mt_p1
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     50
            plo     rc
            ldi     $AA
            call    mt_fill
            mov     rb, mt_p1
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     50
            plo     rc
            ldi     $AA
            call    mt_check_verify

            call    K_INMSG
            db      "check5 (p2 pattern intact): ",0
            mov     rb, mt_p2
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     30
            plo     rc
            ldi     $BB
            call    mt_fill
            mov     rb, mt_p2
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     30
            plo     rc
            ldi     $BB
            call    mt_check_verify

            call    K_INMSG
            db      "check6 (p3 pattern intact): ",0
            mov     rb, mt_p3
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     20
            plo     rc
            ldi     $CC
            call    mt_fill
            mov     rb, mt_p3
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     20
            plo     rc
            ldi     $CC
            call    mt_check_verify

            ; --- check 7: free p2, realloc the same size, expect the
            ; exact same address back (p2's slot has no free neighbor
            ; yet -- p1/p3 are both still allocated -- so it can't
            ; have coalesced into anything bigger; first-fit should
            ; find this exact slot again) ---
            call    K_INMSG
            db      "check7 (free+realloc reuses p2 slot): ",0
            mov     rb, mt_p2
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = mt_p2
            call    heap_free

            ldi     0
            phi     rc
            ldi     30
            plo     rc
            call    heap_alloc          ; RF = p4
            mov     rb, mt_p4
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; mt_p4 = RF

            mov     rb, mt_p2
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = mt_p2 (expected)
            mov     rb, mt_p4
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = mt_p4 (actual)
            call    mt_check_eq

            ; --- checks 8-9: p1/p3's own patterns must still be
            ; intact after check7's free+realloc churn (proves that
            ; churn didn't corrupt either neighbor) ---
            call    K_INMSG
            db      "check8 (p1 pattern still intact): ",0
            mov     rb, mt_p1
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     50
            plo     rc
            ldi     $AA
            call    mt_check_verify

            call    K_INMSG
            db      "check9 (p3 pattern still intact): ",0
            mov     rb, mt_p3
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            ldi     0
            phi     rc
            ldi     20
            plo     rc
            ldi     $CC
            call    mt_check_verify

            ; --- check 10: free p1, then p3, then p4 (p2's slot),
            ; in that specific order -- freeing p3 first coalesces it
            ; FORWARD with the still-free "remainder" block beyond it
            ; (never touched since heap_init); freeing p4 last then
            ; coalesces BACKWARD into p1 AND FORWARD into the
            ; already-merged p3+remainder in one go, a 3-way merge.
            ; If this all worked, the ENTIRE original heap is one
            ; free block again -- proven by successfully allocating
            ; its full original size back, at the original base
            ; address. ---
            call    K_INMSG
            db      "check10 (full coalesce: whole heap allocatable again): ",0

            mov     rb, mt_p1
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = mt_p1
            call    heap_free

            mov     rb, mt_p3
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = mt_p3
            call    heap_free

            mov     rb, mt_p4
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = mt_p4
            call    heap_free

            mov     rf, mt_total
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = total_usable
            call    heap_alloc          ; RF = p5
            mov     rb, mt_p5
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; mt_p5 = RF

            mov     rb, mt_p5
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = mt_p5 (actual)

            ; expected: a heap_alloc'd DATA pointer is always
            ; block+2, and since the fully-coalesced block spans the
            ; WHOLE heap, its own block address is exactly mt_base
            mov     rb, mt_base
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = mt_base
            add16   r8, 2               ; R8 = expected data pointer
                                        ; (mt_base + 2)
            call    mt_check_eq

            ; --- check 11: heap is now fully consumed by that one
            ; allocation -- even a 1-byte request must fail ---
            call    K_INMSG
            db      "check11 (heap now fully consumed): ",0
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            call    heap_alloc
            ldi     0
            phi     r8
            plo     r8                  ; R8 = 0 (expected: failure)
            mov     rd, rf              ; RD = actual result
            call    mt_check_eq

            ; --- summary ---
            mov     rb, mt_fail_count
            ldn     rb
            lbz     mt_all_pass
            call    K_INMSG
            db      "MALLOCTEST: SOME CHECKS FAILED.",13,10,0
            ldi     1
            rtn

mt_all_pass:
            call    K_INMSG
            db      "MALLOCTEST: all checks passed.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; mt_check_nonzero: PASS if RD != 0, FAIL if RD == 0. Prints
; "PASS"/"FAIL" + CRLF; increments mt_fail_count on failure.
; Args:    RD = value to check
; Returns: nothing
;------------------------------------------------------------------
mt_check_nonzero:
            ghi     rd
            lbnz    mtcn_pass
            glo     rd
            lbnz    mtcn_pass
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, mt_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

mtcn_pass:
            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; mt_check_eq: compare RD (actual) against R8 (expected); print
; "PASS"/"FAIL" + CRLF; increment mt_fail_count on failure.
; Args:    RD = actual value, R8 = expected value
; Returns: nothing
;------------------------------------------------------------------
mt_check_eq:
            glo     r8
            str     r2
            glo     rd
            xor
            lbnz    mtce_fail
            ghi     r8
            str     r2
            ghi     rd
            xor
            lbnz    mtce_fail

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

mtce_fail:
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, mt_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

;------------------------------------------------------------------
; mt_fill: fill RC bytes starting at RF with the byte in D.
; Args:    RF = pointer, RC = length, D = fill byte
; Returns: nothing
; Modifies: RF, RC, RA (and D)
;------------------------------------------------------------------
mt_fill:
            plo     ra                  ; RA.0 = fill byte

mtf_loop:
            ghi     rc
            lbnz    mtf_have
            glo     rc
            lbz     mtf_done
mtf_have:
            glo     ra
            str     rf
            inc     rf
            sub16   rc, 1
            lbr     mtf_loop

mtf_done:
            rtn

;------------------------------------------------------------------
; mt_verify: check RC bytes starting at RF all equal the byte in D.
; Args:    RF = pointer, RC = length, D = expected byte
; Returns: DF = 0 if all match, DF = 1 on the first mismatch
; Modifies: RF, RC, RA (and D)
;------------------------------------------------------------------
mt_verify:
            plo     ra                  ; RA.0 = expected byte

mtv_loop:
            ghi     rc
            lbnz    mtv_have
            glo     rc
            lbz     mtv_done            ; RC == 0: all matched
mtv_have:
            glo     ra
            str     r2
            ldn     rf
            xor
            lbnz    mtv_fail
            inc     rf
            sub16   rc, 1
            lbr     mtv_loop

mtv_done:
            clc
            rtn

mtv_fail:
            stc
            rtn

;------------------------------------------------------------------
; mt_check_verify: calls mt_verify and reports PASS/FAIL.
; Args:    RF = pointer, RC = length, D = expected byte
; Returns: nothing
;------------------------------------------------------------------
mt_check_verify:
            call    mt_verify
            lbdf    mtcv_fail
            call    K_INMSG
            db      "PASS",13,10,0
            rtn

mtcv_fail:
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, mt_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

mt_fail_count:  db      0
mt_base:        dw      0
mt_top:         dw      0
mt_total:       dw      0
mt_p1:          dw      0
mt_p2:          dw      0
mt_p3:          dw      0
mt_p4:          dw      0
mt_p5:          dw      0

            end     start
