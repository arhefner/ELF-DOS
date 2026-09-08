;
; mem.asm - print the current top-of-memory address and how much
; program+data space remains above PROG_BASE
;
; Usage: MEM
;
; mem_top (read fresh from LOADER_ARGS+2 -- see kernel_api.inc) is
; the last usable RAM byte for THIS specific run, not a fixed
; constant: it shrinks whenever something reserves space out of high
; memory for the duration of one command, via the kernel's own
; _himem_reserve mechanism (kernel/redir.asm) -- the loadable batch
; module (kernel/batch_mod.asm, reserved for as long as a .bat script
; is running, via K_BATCH_START) and a dual-redirect's second
; FCB+iobuf pair (needed only when a single command redirects BOTH
; input and output at once) both carve their own space out of high
; memory this same way, then give it back once no longer needed.
; Running MEM from inside a .bat script, or with both stdin and
; stdout redirected on the same command line, is expected to print a
; SMALLER "available" figure than running it plain and interactively
; -- that's the intended behavior, not a bug: this command's whole
; job is showing the real, current budget a program actually has
; right now, not a fixed build-time constant.
;
; "Available" is computed as the plain difference mem_top - PROG_BASE
; (both are absolute addresses; mem_top is the highest usable byte,
; PROG_BASE is the lowest a program/its data can use), matching
; kernel/loader.asm's own _prog_finish_load, which computes a loaded
; program's own available space the exact same way.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; The BIOS's own view of the last usable RAM byte, captured
            ; FIRST so nothing else has run yet. This is the hardware
            ; ceiling; mem_top below is the kernel's, which is lower --
            ; the gap holds the stack and, under the split memory model,
            ; the non-volatile kernel (see include/memmap.inc).
            ;
            ; Stashed immediately: f_freemem's register footprint beyond
            ; "RF = result" is not documented anywhere in this codebase,
            ; so nothing is trusted to survive it.
            call    f_freemem           ; RF = address of last RAM byte
            mov     rb, ram_top_val     ; dest pointer FIRST -- "mov"
                                        ; clobbers D (gotcha #4)
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ram_top_val = f_freemem result

            call    K_INMSG
            db      "Top of RAM (f_freemem):      ",0

            mov     rf, ram_top_val
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    hex4
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            ; mem_top = LOADER_ARGS word 1 (word 0 is mem_base, not
            ; needed here) -- read fresh every run, never cached,
            ; since it's only meaningful for THIS specific invocation
            ; (see this file's own header comment)
            mov     rf, LOADER_ARGS
            inc     rf
            inc     rf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            mov     rb, mem_top_val
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; mem_top_val = mem_top

            call    K_INMSG
            db      "Top of memory:               ",0

            mov     rf, mem_top_val
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    hex4                ; RD -> "$xxxx",0 in mem_buf
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            call    K_INMSG
            db      "PROG_BASE:                   ",0

            ldi     high PROG_BASE
            phi     rd
            ldi     low PROG_BASE
            plo     rd
            call    hex4                ; RD -> "$xxxx",0 in mem_buf
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            ; available = mem_top - PROG_BASE (plain difference,
            ; matching kernel/loader.asm's own _prog_finish_load).
            ; sub16 with an immediate constant expands to SMI/SMBI --
            ; it never touches M(R2), so this is safe regardless of
            ; what precedes it (gotcha #18 only applies to the
            ; register-register form).
            mov     rf, mem_top_val
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            sub16   rd, PROG_BASE       ; RD = mem_top - PROG_BASE

            call    K_INMSG
            db      "Available for program+data:  ",0

            mov     rf, mem_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      " bytes",13,10,0

            ldi     0                   ; exit code 0 = success
            rtn

;------------------------------------------------------------------
; hex4: format RD as "$xxxx",0 into mem_buf.
;
; Hand-rolled rather than calling the BIOS's own f_hexout4: that
; routine has never been exercised anywhere in this codebase, so its
; register contract is unconfirmed -- the same reason progs/hexdump.asm
; hand-rolls its own hex output instead. hex_byte/hex_nibble below are
; that file's routines, copied rather than shared (small-helper
; duplication is this project's established DIR/STAT precedent).
;
; Lowercase digits, matching hexdump.asm, so the project has one hex
; convention rather than two. The "$" prefix is added here because
; these are single values in a labelled report, where hexdump omits it
; to keep a dense byte column readable.
;
; Args:     RD = value to format
; Returns:  mem_buf holds "$xxxx",0
; Modifies: D, DF, RB, RC, RF (RD is preserved via hex_val, since
;           hex_byte's own scratch use of RC/RF makes trusting any
;           register across it a gotcha #10 waiting to happen)
;------------------------------------------------------------------
hex4:
            mov     rb, hex_val         ; set the destination pointer
                                        ; BEFORE loading the value --
                                        ; "mov" clobbers D (gotcha #4)
            ghi     rd
            str     rb                  ; hex_val.hi = RD.hi
            inc     rb
            glo     rd
            str     rb                  ; hex_val.lo = RD.lo

            mov     rf, mem_buf
            ldi     '$'
            str     rf
            inc     rf

            mov     rb, hex_val
            ldn     rb
            call    hex_byte            ; high byte -> 2 digits at RF

            ; Re-derive the low-byte pointer from memory rather than
            ; keeping it in RB across the call. hex_byte does not in
            ; fact touch RB today, but its documented footprint is
            ; D/DF/RC.0/RF and relying on anything beyond that is
            ; exactly the assumption gotcha #10 keeps punishing. RF is
            ; deliberately NOT reloaded: hex_byte advancing it past the
            ; digits it wrote is its contract, and that is what puts
            ; the next two digits in the right place.
            mov     rb, hex_val
            inc     rb
            ldn     rb
            call    hex_byte            ; low byte -> 2 digits at RF

            ldi     0
            str     rf                  ; null-terminate
            rtn

;------------------------------------------------------------------
; hex_byte: write D as two lowercase hex digits at *RF, advancing RF.
; Modifies: D, DF, RC.0, RF
;------------------------------------------------------------------
hex_byte:
            plo     rc                  ; RC.0 = byte (stash across the
                                        ; two hex_nibble calls)
            glo     rc
            shr
            shr
            shr
            shr                         ; D = high nibble (SHR always
                                        ; zero-fills, so four give a
                                        ; clean >>4 with no DF
                                        ; dependency)
            call    hex_nibble
            str     rf
            inc     rf

            glo     rc
            ani     $0F                 ; D = low nibble
            call    hex_nibble
            str     rf
            inc     rf
            rtn

;------------------------------------------------------------------
; hex_nibble: D (0-15) -> its lowercase ASCII hex digit.
;------------------------------------------------------------------
hex_nibble:
            smi     10
            lbnf    hn_digit            ; DF=0 (borrow): nibble < 10
            adi     'a'                 ; nibble >= 10: D = 'a' +
                                        ; (nibble-10)
            rtn
hn_digit:
            adi     10 + '0'            ; D = (nibble-10) + 10 + '0'
                                        ; = nibble + '0'
            rtn

ram_top_val:    dw      0               ; f_freemem's answer
mem_top_val:    dw      0
hex_val:        dw      0               ; hex4's own copy of RD, held in
                                        ; memory across its hex_byte
                                        ; calls
mem_buf:        ds      8               ; scratch: "$xxxx"+null (6) for
                                        ; hex4, "65535"+null (6) for
                                        ; f_uintout -- 8 for headroom

            end     start
