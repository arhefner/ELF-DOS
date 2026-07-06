;
; shell.asm - ELF-DOS command shell
;
; Provides:
;   shell_main   -- prints banner, falls through to shell_prompt
;   shell_prompt -- prompt/read/dispatch loop (never returns)
;
; No built-in commands -- every command line is resolved as an
; external .EXE via prog_load/prog_exec. See include/kernel_api.inc
; for the K_GETCURDIR/K_SETCURDIR/K_GETVERSION/K_DIR_OPEN/K_DIR_READ
; calls those programs use instead of reaching into kernel internals.
;

#include    include/opcodes.def
#include    include/bios.inc

; cross-file references
            extrn   line_buf
            extrn   prog_load
            extrn   prog_exec

;==================================================================
; shell_main: print banner, then fall through to shell_prompt
;==================================================================

            proc    shell_main

            call    f_inmsg
            db      "Type a command.",13,10,0

            ; fall through into shell_prompt

;==================================================================
; shell_prompt: prompt, read, dispatch -- never returns
;==================================================================

shell_prompt:
            call    f_inmsg
            db      "C:/> ",0

            mov     rf, line_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc                  ; RC = 127 (buffer length for f_inputl)
            call    f_inputl

            call    f_inmsg
            db      13,10,0

            ; skip leading whitespace
            mov     rf, line_buf
            call    f_ltrim             ; RF = first non-space char

            ; empty line?
            ldn     rf
            lbz     shell_prompt

            ; save the input pointer so we can restore RD before
            ; each f_strcmp call (f_strcmp advances both RF and RD)
            mov     ra, rf              ; RA = saved input pointer

            ; try to load and run it as a program -- RA holds the start
            ; of the trimmed input line.
            ; find the end of the program name (first space or NUL)
            mov     rf, ra
cmd_name_scan:
            ldn     rf
            lbz     cmd_name_end
            xri     ' '
            lbz     cmd_name_end
            inc     rf
            lbr     cmd_name_scan
cmd_name_end:
            ; RF -> the space or NUL right after the program name
            ldn     rf
            lbz     cmd_have_tail       ; NUL: no arguments, RF already there (empty tail)

            ; there's a space: null-terminate the program name in place
            ; (line_buf is scratch for this one command line anyway) and
            ; advance past it to the argument text
            ldi     0
            str     rf
            inc     rf
            call    f_ltrim             ; RF = start of the trimmed command tail

cmd_have_tail:
            ; RF = pointer to the command tail (possibly an empty string).
            ; Save it across prog_load, which clobbers RF/RA and other
            ; registers internally (via dir_read's directory search) --
            ; it gets loaded into RA right before prog_exec, which
            ; passes it through to the program untouched (see
            ; include/kernel_api.inc: RA at entry = command tail).
            push    rf

            mov     rf, ra              ; RF = program name, now null-terminated
            call    prog_load
            lbdf    cmd_load_failed     ; not found / bad magic / no free FCB slot

            pop     ra                  ; RA = command tail, for the program
            call    prog_exec           ; run it; D = exit code (unused for now)
            lbr     shell_prompt

cmd_load_failed:
            pop     rf                  ; discard the saved tail pointer
            call    f_inmsg
            db      "Bad command.",13,10,0
            lbr     shell_prompt

            endp
