;
; loader.asm - User program loader
;
; Provides:
;   prog_load -- load a program file (at an exact, already-resolved
;                path) to PROG_BASE
;   prog_exec -- jump to loaded program, return when it exits
;
; Program binary format (mirrors the kernel's own header convention):
;   $00-$02   magic bytes 'EDF'
;   $03       program major version
;   $04-$05   reserved
;   $06+      code (entry point is always at load_address + $06)
;
; As of the shell-as-a-program move, prog_load no longer searches for
; the program itself -- that's now progs/shell.asm's job (bare name ->
; "/bin/"+name; a name containing '/' -> used as-is), communicated via
; the fixed RUN_PATH address (see kernel.inc). prog_load just opens
; the exact path it's given. This dropped the old 6-attempt search
; (current directory then root, three name variants each) and its two
; 132-byte scratch buffers entirely -- the bulk of this session's
; kernel-size reduction.
;
; The loader:
;   1. Opens the given path via file_open
;   2. Reads the entire file to PROG_BASE using file_read
;   3. Sets mem_base = PROG_BASE + file_size (rounded to 16 bytes)
;      so the program's heap library can use the remaining RAM
;   4. Passes mem_base and mem_top to the program via a fixed
;      two-word block at a known address (LOADER_ARGS)
;   5. Calls the program entry at PROG_BASE + $06
;   6. On return, restores kernel state
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   file_open
            extrn   file_close
            extrn   file_read
            extrn   mem_base
            extrn   mem_top

; same-file data references (required even within the same file)
            extrn   prog_fcb
            extrn   prog_size
            extrn   saved_sp

; ----------------------------------------------------------------
; prog_load: load a program at an exact path into RAM
; Args:   RF = pointer to null-terminated path, already fully
;              resolved by the caller -- no searching is done here
; Returns: DF = 0 on success (program is at PROG_BASE, ready to run)
;          DF = 1 on error (not found, load error, bad magic)
; ----------------------------------------------------------------
            proc    prog_load

            ldi     0                   ; mode = read
            call    file_open           ; D = FCB index, DF=0/1
            lbdf    pload_err           ; not found

            ; BUG FIX pattern preserved from the pre-simplification
            ; code: "mov rf, prog_fcb" itself clobbers D (gotcha #4),
            ; so the FCB index file_open just returned in D has to be
            ; stashed in a spare register first, or it doesn't survive
            ; to the "str rf" below.
            plo     r9                  ; stash FCB index
            mov     rf, prog_fcb
            glo     r9                  ; D = FCB index (reloaded)
            str     rf                  ; prog_fcb = FCB index

            ; count = mem_top - PROG_BASE
            ;
            ; BUG FIX HISTORY: this used to hardcode PROG_BASE's high
            ; byte as a plain literal ($20, then $40, then $3E across
            ; PROG_BASE's successive moves) -- silently stale, and
            ; silently overestimated available program RAM by 8KB the
            ; first time it was missed entirely. Now uses `high
            ; PROG_BASE`/`low PROG_BASE` instead: confirmed via an
            ; isolated Asm/02 test (2026-07-10) that `high`/`low`
            ; correctly re-evaluate a symbol's `equ` value at assemble
            ; time (this was wrongly assumed unsupported -- gotcha #2's
            ; claim about compound `symbol+CONST` expressions turned
            ; out not to reproduce in testing either; see the gotcha
            ; list for the full retraction). This literal now updates
            ; itself automatically whenever PROG_BASE moves again.
            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top

            ldi     low PROG_BASE
            str     r2
            glo     rd
            sm                          ; D = mem_top.lo - PROG_BASE.lo
            plo     rc
            ldi     high PROG_BASE
            str     r2
            ghi     rd
            smb                         ; D = mem_top.hi - PROG_BASE.hi - borrow
            phi     rc                  ; RC = available space (mem_top - PROG_BASE)

            mov     rf, prog_fcb
            ldn     rf                  ; D = FCB index
            plo     r9                  ; stash it (mov below clobbers D)
            mov     rf, PROG_BASE       ; RF = destination
            glo     r9                  ; D = FCB index (reloaded, correct)
            call    file_read           ; RC = bytes read, DF=0/1
            lbdf    pload_read_err

            mov     rf, prog_size
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; prog_size = bytes loaded

            mov     rf, prog_fcb
            ldn     rf                  ; D = FCB index
            call    file_close

            ; validate the 'EDF' magic header
            mov     rf, PROG_BASE
            lda     rf
            xri     'E'
            lbnz    pload_bad_magic
            lda     rf
            xri     'D'
            lbnz    pload_bad_magic
            lda     rf
            xri     'F'
            lbnz    pload_bad_magic

            ; mem_base = PROG_BASE + prog_size, rounded up to 16 bytes
            mov     rf, prog_size
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = prog_size

            glo     rd                  ; round up: (size + 15) & ~15
            adi     15
            plo     rd
            ghi     rd
            adci    0
            phi     rd
            glo     rd
            ani     $F0
            plo     rd

            ghi     rd                  ; PROG_BASE's low byte is 0, so
            adi     high PROG_BASE      ; adding it is just += PROG_BASE's
            phi     rd                  ; own high byte -- RD = mem_base

            mov     rf, mem_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; mem_base updated

            ; publish mem_base/mem_top at the fixed LOADER_ARGS address
            ; for the program to read (see kernel.inc)
            mov     rf, LOADER_ARGS
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; LOADER_ARGS+0,1 = mem_base

            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            mov     rf, LOADER_ARGS
            add16   rf, 2
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; LOADER_ARGS+2,3 = mem_top

            clc                         ; DF = 0, success
            rtn

pload_read_err:
            ; file_read failed: still need to close what file_open opened
            mov     rf, prog_fcb
            ldn     rf
            call    file_close
pload_bad_magic:
pload_err:
            stc                         ; DF = 1, error
            rtn

; ----------------------------------------------------------------
; prog_exec: execute the program currently at PROG_BASE
; The caller is responsible for calling prog_load first.
; Args:   RA = pointer to the null-terminated command tail (see
;              include/kernel_api.inc) -- passed straight through
;              untouched, since this proc has no reason to use RA
;              itself; the caller must set it immediately before
;              calling, since anything else called in between (like
;              prog_load) may clobber it.
; Returns: D = program exit code (convention to be defined)
;          DF = 0 normally
;
; Saves/restores R2 (the stack pointer) around the call as a defensive
; measure -- a normal call/rtn pair already balances R2 on its own,
; but this guards against a misbehaving program leaving it corrupted.
; ----------------------------------------------------------------
            endp

            proc    prog_exec

            mov     rf, saved_sp
            ghi     r2
            str     rf
            inc     rf
            glo     r2
            str     rf                  ; saved_sp = R2

            call    PROG_BASE+6         ; jump to program entry; D = exit
                                        ; code by convention on return
            plo     rd                  ; save exit code while restoring R2

            mov     rf, saved_sp
            lda     rf
            phi     r2
            ldn     rf
            plo     r2                  ; restore kernel stack pointer

            glo     rd                  ; D = exit code
            clc                         ; DF = 0
            rtn

            endp

;------------------------------------------------------------------
; Loader scratch data
;------------------------------------------------------------------
            proc    _loader_data

prog_fcb:       db      0           ; FCB index of the file being loaded
prog_size:      dw      0           ; bytes actually loaded (for mem_base calc)
saved_sp:       dw      0           ; kernel's R2 across prog_exec's call

                public  prog_fcb
                public  prog_size
                public  saved_sp

            endp
