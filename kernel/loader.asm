;
; loader.asm - User program loader
;
; Provides:
;   prog_load -- find a program file and load it to PROG_BASE ($2000)
;   prog_exec -- jump to loaded program, return when it exits
;
; Program binary format (mirrors the kernel's own header convention):
;   $00-$02   magic bytes 'EDF'
;   $03       program major version
;   $04-$05   reserved
;   $06+      code (entry point is always at load_address + $06)
;
; The loader:
;   1. Searches the current directory for the named file
;   2. Opens the file via file_open
;   3. Reads the entire file to PROG_BASE using file_read
;   4. Sets mem_base = PROG_BASE + file_size (rounded to 16 bytes)
;      so the program's heap library can use the remaining RAM
;   5. Passes mem_base and mem_top to the program via a fixed
;      two-word block at a known address (loader_args below)
;   6. Calls the program entry at PROG_BASE + $06
;   7. On return, restores kernel state
;
; TO BE IMPLEMENTED
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   file_open, file_close, file_read
            extrn   mem_base, mem_top
            extrn   cur_dir

.link       .align  page

; ----------------------------------------------------------------
; prog_load: search for and load a program into RAM
; Args:   RF = pointer to null-terminated program name
; Returns: DF = 0 on success (program is at PROG_BASE, ready to run)
;          DF = 1 on error (not found, load error, etc.)
; ----------------------------------------------------------------
            proc    prog_load
            ; TODO
            stc
            rtn

; ----------------------------------------------------------------
; prog_exec: execute the program currently at PROG_BASE
; The caller is responsible for calling prog_load first.
; Returns: D = program exit code (convention to be defined)
;          DF = 0 normally
; ----------------------------------------------------------------
            endp

            proc    prog_exec
            ; TODO
            clc
            rtn

            endp
