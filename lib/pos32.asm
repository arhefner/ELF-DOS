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
