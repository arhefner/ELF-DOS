;
; shell.asm - ELF-DOS command shell
;
; Provides:
;   shell_main   -- prints banner, falls through to shell_prompt
;   shell_prompt -- prompt/read/dispatch loop (never returns)
;
; Built-in commands:
;   VER  -- print OS version
;   DIR  -- list current directory
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   dir_open
            extrn   dir_read
            extrn   cur_dir
            extrn   line_buf

; same-file proc references (required even in the same file)
            extrn   cmd_ver
            extrn   cmd_dir
            extrn   dir_result

.link       .align  page

;==================================================================
; shell_main: print banner, then fall through to shell_prompt
;==================================================================

            proc    shell_main

            call    f_inmsg
            db      "Type VER or DIR.",13,10,0

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

            ; --- VER ---
            mov     rd, ra
            mov     rf, cmd_ver
            call    f_strcmp
            lbz     do_ver

            ; --- DIR ---
            mov     rd, ra              ; RESTORE input pointer
            mov     rf, cmd_dir
            call    f_strcmp
            lbz     do_dir

            ; unknown command
            call    f_inmsg
            db      "Bad command.",13,10,0
            lbr     shell_prompt

;------------------------------------------------------------------
; VER: print version string
;------------------------------------------------------------------
do_ver:
            call    f_inmsg
            db      "ELF-DOS v0.1",13,10,0
            lbr     shell_prompt

;------------------------------------------------------------------
; DIR: list current directory
;
; Each entry is printed as:
;   "  <DIR>  name"   for subdirectories
;   "XXXXXXXX name"   for files (8 hex digits = 32-bit size)
;------------------------------------------------------------------
do_dir:
            ; open current directory cluster
            mov     rf, cur_dir
            lda     rf                  ; D = cur_dir high byte
            phi     rd
            ldn     rf                  ; D = cur_dir low byte
            plo     rd                  ; RD = current directory cluster
            call    dir_open

dir_loop:
            mov     rf, dir_result      ; RF = result buffer
            call    dir_read
            lbdf    dir_done            ; DF=1 = end of directory

            ; check ATTR_DIR bit
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    dir_is_dir

            ; ---- file: print 8 hex digit size ----
            mov     rf, dir_result
            add16   rf, DIRENT_SIZE
            lda     rf                  ; D = size byte 3 (MSB)
            phi     rd
            lda     rf                  ; D = size byte 2
            plo     rd
            call    f_hexout4           ; print high word as 4 hex digits

            lda     rf                  ; D = size byte 1
            phi     rd
            ldn     rf                  ; D = size byte 0 (LSB)
            plo     rd
            call    f_hexout4           ; print low word as 4 hex digits

            call    f_inmsg
            db      " ",0
            lbr     dir_print_name

            ; ---- directory: print label ----
dir_is_dir:
            call    f_inmsg
            db      "  <DIR>  ",0

dir_print_name:
            mov     rf, dir_result      ; RF = DIRENT_NAME (at offset 0)
            call    f_msg
            call    f_inmsg
            db      13,10,0
            lbr     dir_loop

dir_done:
            lbr     shell_prompt

            endp

;------------------------------------------------------------------
; Command strings and static dir result buffer
;------------------------------------------------------------------

            proc    _shell_data

cmd_ver:    db      "VER",0
cmd_dir:    db      "DIR",0
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for dir_read

            public  cmd_ver
            public  cmd_dir
            public  dir_result

            endp
