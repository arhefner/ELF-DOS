            org     0ffd8h

callbr:     glo   r3
            plo   r6

            lda   r6                    ; get subroutine address
            phi   r3                    ; and put into r3
            lda   r6
            plo   r3

            glo   re
            sep   r3                    ; jump to called routine

            org 0ffe0h

            ; Entry point for CALL here.

call:       plo   re                    ; Save D
            sex   r2

            glo   r6                    ; save last R[6] to stack
            stxd
            ghi   r6
            stxd

            ghi   r3                    ; copy R[3] to R[6]
            phi   r6

            br    callbr                ; transfer control to subroutine
