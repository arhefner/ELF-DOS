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
;   1. Searches for the named file: as typed, then with ".EXE" and
;      ".exe" appended (LFN entries preserve whatever case a file
;      was created with, unlike 8.3 short names, so both are tried),
;      in the current directory, then (if not found in any of those
;      forms there) the same three names again in the root directory
;      -- so utilities can live in one place (root) and still be run
;      regardless of which directory the user has CD'd into, without
;      a full PATH search. Matching itself is still case-sensitive
;      (an exact f_strcmp) -- this only broadens which exact forms
;      get tried, it doesn't fold case generally.
;   2. Opens the file via file_open
;   3. Reads the entire file to PROG_BASE using file_read
;   4. Sets mem_base = PROG_BASE + file_size (rounded to 16 bytes)
;      so the program's heap library can use the remaining RAM
;   5. Passes mem_base and mem_top to the program via a fixed
;      two-word block at a known address (loader_args below)
;   6. Calls the program entry at PROG_BASE + $06
;   7. On return, restores kernel state
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   file_open
            extrn   file_close
            extrn   file_read
            extrn   mem_base
            extrn   mem_top
            extrn   cur_dir

; same-file data references (required even within the same file)
            extrn   prog_fcb
            extrn   prog_size
            extrn   saved_sp
            extrn   prog_name
            extrn   prog_name_ext
            extrn   prog_name_ext_lc
            extrn   prog_saved_dir
            extrn   ext_suffix
            extrn   ext_suffix_lc

; ----------------------------------------------------------------
; prog_load: search for and load a program into RAM
; Args:   RF = pointer to null-terminated program name
; Returns: DF = 0 on success (program is at PROG_BASE, ready to run)
;          DF = 1 on error (not found, load error, bad magic)
; ----------------------------------------------------------------
            proc    prog_load

            ; save the name so it can be tried more than once (below),
            ; since file_open/dir_read consume/clobber RF internally
            mov     rd, rf
            mov     rf, prog_name
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; prog_name = name pointer

            ; build prog_name_ext = name + ".EXE"
            mov     rf, prog_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = name pointer
            mov     rf, prog_name_ext
pload_copy_name:
            lda     rd
            lbz     pload_copy_name_done
            str     rf
            inc     rf
            lbr     pload_copy_name
pload_copy_name_done:
            mov     rd, ext_suffix
pload_append_ext:
            lda     rd
            str     rf
            lbz     pload_append_ext_done
            inc     rf
            lbr     pload_append_ext
pload_append_ext_done:

            ; build prog_name_ext_lc = name + ".exe" -- LFN entries preserve
            ; whatever case the file was created with (unlike 8.3 short
            ; names, always uppercase), so a lowercase-named program like
            ; "type.exe" needs a lowercase fallback too, not just ".EXE"
            mov     rf, prog_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = name pointer
            mov     rf, prog_name_ext_lc
pload_copy_name2:
            lda     rd
            lbz     pload_copy_name2_done
            str     rf
            inc     rf
            lbr     pload_copy_name2
pload_copy_name2_done:
            mov     rd, ext_suffix_lc
pload_append_ext2:
            lda     rd
            str     rf
            lbz     pload_append_ext2_done
            inc     rf
            lbr     pload_append_ext2
pload_append_ext2_done:

            ; ---- attempt 1: name as-is, in the current directory ----
            mov     rf, prog_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            ldi     0                   ; mode = read
            call    file_open           ; D = FCB index, DF=0/1
            lbnf    pload_opened        ; DF=0: found it

            ; ---- attempt 2: name+".EXE", in the current directory ----
            mov     rf, prog_name_ext
            ldi     0
            call    file_open
            lbnf    pload_opened

            ; ---- attempt 3: name+".exe", in the current directory ----
            mov     rf, prog_name_ext_lc
            ldi     0
            call    file_open
            lbnf    pload_opened

            ; ---- attempt 4: name as-is, in the root directory ----
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, prog_saved_dir
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; prog_saved_dir = cur_dir

            mov     rf, cur_dir
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; cur_dir = 0 (root), temporarily

            mov     rf, prog_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            ldi     0
            call    file_open
            plo     r9                  ; save D (FCB index if DF=0) -- the
                                        ; cur_dir restore below would
                                        ; otherwise clobber it
            lbnf    pload_restore_dir   ; DF=0: found it (skips attempts 5/6)

            ; ---- attempt 5: name+".EXE", in the root directory ----
            ; (cur_dir is already root from attempt 4, no need to reset it)
            mov     rf, prog_name_ext
            ldi     0
            call    file_open
            plo     r9                  ; save D (FCB index if DF=0)
            lbnf    pload_restore_dir   ; DF=0: found it (skips attempt 6)

            ; ---- attempt 6: name+".exe", in the root directory ----
            mov     rf, prog_name_ext_lc
            ldi     0
            call    file_open
            plo     r9                  ; save D (FCB index if DF=0)

pload_restore_dir:
            ; restore cur_dir -- none of these instructions affect DF, so
            ; the last file_open's DF is still intact when we check it below
            mov     rf, prog_saved_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, cur_dir
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; cur_dir restored

            lbdf    pload_err           ; DF=1: not found in any form
            glo     r9                  ; D = FCB index

pload_opened:
            ; BUG FIX: "mov rf, prog_fcb" itself clobbers D (gotcha #4),
            ; so the real FCB index just returned by file_open (in D,
            ; either straight from the fast-path "lbnf pload_opened"
            ; above or via "glo r9" just above for the root-fallback
            ; path) would not survive to "str rf" below without this
            ; stash. This left prog_fcb permanently holding a garbage
            ; constant (part of its own address, $92) instead of the
            ; real index -- invisible before the file_open FCB_FLAGS
            ; fix, since every open always landed on slot 0 anyway
            ; (the old bug made every slot look free regardless), but
            ; now that slots are tracked correctly, every subsequent
            ; file_read/file_close call using this garbage index
            ; either hits file_close's bounds check (silently doing
            ; nothing, leaking the real FCB every load) or corrupts
            ; unrelated memory via file_read's unchecked index math.
            plo     r9                  ; stash FCB index (R9 is free
                                        ; here -- its only other use,
                                        ; carrying the index across the
                                        ; cur_dir restore, is already
                                        ; consumed by the "glo r9" above)
            mov     rf, prog_fcb
            glo     r9                  ; D = FCB index (reloaded)
            str     rf                  ; prog_fcb = FCB index

            ; count = mem_top - PROG_BASE ($2000: hi=$20, lo=$00)
            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top

            ldi     $00
            str     r2
            glo     rd
            sm                          ; D = mem_top.lo - $00
            plo     rc
            ldi     $20
            str     r2
            ghi     rd
            smb                         ; D = mem_top.hi - $20 - borrow
            phi     rc                  ; RC = available space (mem_top - PROG_BASE)

            ; BUG FIX: the old comment here claimed "D unaffected" by
            ; "mov rf, PROG_BASE", but mov always clobbers D (gotcha
            ; #4) -- it left D = PROG_BASE's own low byte ($00, since
            ; PROG_BASE=$4000), not the real FCB index just loaded on
            ; the line above. file_read has therefore always effectively
            ; been called with a hardcoded index of 0 -- invisible only
            ; because slot 0 has always happened to be the one actually
            ; in use (sequential single-program loading naturally keeps
            ; reusing it once closed properly). Fixed by stashing the
            ; real index in R9 (free here) across the mov, same pattern
            ; as pload_opened's fix above.
            mov     rf, prog_fcb
            ldn     rf                  ; D = FCB index
            plo     r9                  ; stash it
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
            adi     $20                 ; adding it is just += $20 on the high byte
            phi     rd                  ; RD = mem_base

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

prog_name:      dw      0           ; caller's name pointer (tried as-is)
prog_name_ext:  ds      132         ; name + ".EXE" (see prog_load)
prog_name_ext_lc: ds    132         ; name + ".exe" (see prog_load)
prog_saved_dir: dw      0           ; cur_dir, saved during the root-dir attempts
ext_suffix:     db      ".EXE",0
ext_suffix_lc:  db      ".exe",0

                public  prog_fcb
                public  prog_size
                public  saved_sp
                public  prog_name
                public  prog_name_ext
                public  prog_name_ext_lc
                public  prog_saved_dir
                public  ext_suffix
                public  ext_suffix_lc

            endp
