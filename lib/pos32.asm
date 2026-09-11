;
; pos32.asm - 32-bit position/value helpers shared by the pager and by
; whatever data source it is linked against.
;
; Deliberately its own module rather than living in either of them: a
; data source must not depend on the pager, and the pager must not
; depend on a particular source, so the few routines both need sit
; below both. Same granularity as lib/fmt32.asm.
;
; Makes no kernel or BIOS calls, so ordinary straight-line register
; rules apply -- none of this project's "does a register survive a
; call" gotchas are in play for a caller.
;

#include    include/opcodes.def


            proc    copy4bytes
;------------------------------------------------------------------
; copy4bytes: copies 4 bytes from [RF] to [RD] (both advanced).
;------------------------------------------------------------------
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            rtn
            endp

            proc    copy4bytes_to_r8
;------------------------------------------------------------------
; copy4bytes_to_r8: copies 4 bytes from [RF] to [R8] (both advanced) --
; a separate entry point from copy4bytes purely because several
; callers (less_push_offset, draw_page's own less_visible[] snapshot,
; less_shift_visible_left's insert step) already have their
; destination address computed into R8, with RD needed for something
; else moments later -- avoids a spurious extra register shuffle at
; each of those call sites.
;------------------------------------------------------------------
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8
            rtn
            endp

            proc    zero4bytes
;------------------------------------------------------------------
; zero4bytes: zeroes the 4 bytes at [RF] (advanced).
;------------------------------------------------------------------
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            rtn
            endp

;------------------------------------------------------------------
; shl32: the 4-byte big-endian value at [RF] <<= 1.
; Args: RF = pointer.  Modifies: R7, D, DF
;------------------------------------------------------------------
            proc    shl32
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; -> byte 3 (LSB)
            ldn     r7
            shl                         ; DF = carry out
            str     r7
            dec     r7
            ldn     r7
            shlc
            str     r7
            dec     r7
            ldn     r7
            shlc
            str     r7
            dec     r7
            ldn     r7
            shlc
            str     r7
            rtn
            endp

;------------------------------------------------------------------
; add32: the 4-byte big-endian value at [RF] += the one at [RD].
; LSB first with carry propagated -- the same byte-chain shape the
; kernel's own 32-bit arithmetic uses (a 16-bit ADD16 on each half
; would NOT carry across the halves).
; Args: RF = destination pointer, RD = addend pointer
; Modifies: R7, R8, D, DF
;------------------------------------------------------------------
            proc    add32
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; -> dest LSB
            mov     r8, rd
            inc     r8
            inc     r8
            inc     r8                  ; -> addend LSB

            ldn     r8
            str     r2
            ldn     r7
            add
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7
            rtn
            endp

;------------------------------------------------------------------
; addbyte32: the 4-byte big-endian value at [RF] += D (unsigned byte).
; Args: RF = pointer, D = the byte.  Modifies: R7, R8, D, DF
;------------------------------------------------------------------
            proc    addbyte32
            plo     r8                  ; stash the byte -- "plo" leaves
                                        ; D alone, "mov" would not
                                        ; (gotcha #4)
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; -> LSB

            glo     r8
            str     r2
            ldn     r7
            add
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7
            rtn
            endp

;------------------------------------------------------------------
; sub32: the 4-byte big-endian value at [RF] -= the one at [RD].
; LSB first with borrow propagated, the subtrahend byte staged in M(R2)
; immediately before each SM/SMB that consumes it.
; Args: RF = destination pointer, RD = subtrahend pointer
; Returns: DF=1 no borrow ([RF] was >= [RD]), DF=0 borrow
; Modifies: R7, R8, D, DF
;------------------------------------------------------------------
            proc    sub32
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; -> dest LSB
            mov     r8, rd
            inc     r8
            inc     r8
            inc     r8                  ; -> subtrahend LSB

            ldn     r8
            str     r2
            ldn     r7
            sm
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7
            rtn
            endp

;------------------------------------------------------------------
; subbyte32: the 4-byte big-endian value at [RF] -= D (unsigned byte).
; Args: RF = pointer, D = the byte
; Returns: DF=1 no borrow, DF=0 borrow
; Modifies: R7, R8, D, DF
;------------------------------------------------------------------
            proc    subbyte32
            plo     r8                  ; stash the byte (gotcha #4)
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; -> LSB

            glo     r8
            str     r2
            ldn     r7
            sm
            str     r7

            dec     r7
            ldn     r7
            smbi    0
            str     r7

            dec     r7
            ldn     r7
            smbi    0
            str     r7

            dec     r7
            ldn     r7
            smbi    0
            str     r7
            rtn
            endp
