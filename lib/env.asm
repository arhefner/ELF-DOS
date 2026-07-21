;
; env.asm - environment variable library (getenv/setenv/unsetenv)
;
; NOT a standalone program -- no EDF header, no org PROG_BASE, no
; entry point of its own. Assembled separately (lib/env.prg) and
; linked alongside a program that wants it, the same way
; lib/heap_bump.asm/lib/heap_malloc.asm already do. A calling program
; declares "extrn env_getenv" / "extrn env_setenv" / "extrn
; env_unsetenv" and calls them like any other routine.
;
; Direct port of Elf/OS's own C implementation (getenv.c/setenv.c/
; unsetenv.c in this project's own root, plus their two helpers
; _env_read_line.c/_env_split_line.c and the shared constants, all in
; ~/projects/Elf/ELFC/src/clib/stdlib/). On-disk store: a flat text
; file of "NAME=VALUE\n" lines at /cfg/env.dat (already an
; established path in this project's own history -- see
; progs/copy.asm's own header comment). setenv/unsetenv both work by
; streaming the existing file into /cfg/env.tmp (copying every line
; through unchanged except the one being changed/dropped), then
; swapping the temp file into place via K_FILE_DELETE+K_FILE_RENAME
; (this kernel's own rename refuses to overwrite an existing
; destination, so delete-then-rename is required, exactly matching
; why the C reference does the same thing with remove()+rename()) --
; same small crash-safety caveat the C reference already accepts: a
; crash between the delete and the rename briefly leaves no env.dat.
;
; Calling convention (register-passed, RF for the primary string
; pointer -- matching K_FILE_DELETE/DEL/REN's own use of RF for path
; args):
;   env_getenv:   Args RF=name. Returns RF=pointer to the value (an
;                 internal static buffer, valid until the next
;                 env_getenv/env_setenv/env_unsetenv call -- matching
;                 the real getenv's own contract), or RF=0 if not
;                 found or the env file doesn't exist yet.
;   env_setenv:   Args RF=name, RD=value, D=overwrite (0 = leave an
;                 existing value untouched, nonzero = replace).
;                 Returns DF=0/1 (error: name contains '=', can't
;                 create the temp file, or the final rename failed).
;   env_unsetenv: Args RF=name. Returns DF=0/1 -- DF=0 even if the
;                 variable was never set, matching the real
;                 unsetenv's idempotent success.
;
; None of the three high-level routines are safe to call re-entrantly
; or concurrently (they share one set of internal scratch/FCBs) -- not
; a concern on this single-threaded kernel, same assumption
; kernel/redir.asm's own _redir_reserve already documents.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

ENV_LINE_MAX:   equ     64          ; bounds NAME=VALUE\0, matching
                                    ; the C reference's own constant

            extrn   env_line_buf
            extrn   env_namebuf
            extrn   env_in_fcb
            extrn   env_in_iobuf
            extrn   env_out_fcb
            extrn   env_out_iobuf
            extrn   env_name
            extrn   env_value
            extrn   env_overwrite
            extrn   env_in_handle
            extrn   env_out_handle
            extrn   env_found
            extrn   env_len
            extrn   env_eq_byte
            extrn   env_nl_byte
            extrn   env_file_path
            extrn   env_tmp_path
            extrn   env_dat_name
            extrn   env_split_line
            extrn   env_read_line
            extrn   _env_streq
            extrn   _env_write_line

; ----------------------------------------------------------------
; env_read_line: read one line (up to '\n' or EOF) from an open file
; handle into a buffer, stripping the trailing newline, null-
; terminating the result. Truncates (silently drops the remainder
; of) a line longer than maxlen-1, matching the C reference's own
; behavior.
; Args:    D = handle, RF = buffer, RC = maxlen (RC.0 only -- this
;          library only ever calls it with ENV_LINE_MAX=64, so one
;          byte's range is more than enough)
; Returns: DF = 0 on a real line (RC = length stored, 0..maxlen-1,
;          buffer null-terminated), DF = 1 at true EOF with nothing
;          read at all this call (matches K_INPUTL's own DF-based EOF
;          contract from this same project, not the C reference's -1
;          return -- a final line with no trailing newline is still
;          returned once, DF=0, before the FOLLOWING call reports
;          true EOF).
; Modifies: R7, R8, R9, RB, RC, RF (and D) -- K_FILE_READ's own
;          clobber footprint is broad and undocumented beyond
;          D-in/RC-out/DF-out, so nothing here is trusted to survive
;          it in a register; every value needed across the call is
;          stashed to memory first.
; ----------------------------------------------------------------
            proc    env_read_line

            plo     r9                  ; stash handle (D) -- safe
                                        ; only across the mov+str
                                        ; immediately below
            mov     rb, erl_handle
            glo     r9
            str     rb                  ; erl_handle = handle

            mov     rb, erl_wptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; erl_wptr = buffer pointer

            mov     rb, erl_maxlen
            glo     rc
            str     rb                  ; erl_maxlen = maxlen (low
                                        ; byte)

            mov     rb, erl_count
            ldi     0
            str     rb                  ; erl_count = 0

            mov     rb, erl_got
            ldi     0
            str     rb                  ; erl_got = 0

erl_loop:
            mov     rf, erl_scratch
            ldi     0
            phi     rc
            ldi     1
            plo     rc                  ; RC = 1
            mov     rb, erl_handle
            ldn     rb                  ; D = handle -- loaded LAST,
                                        ; immediately before the call
                                        ; (the earlier draft loaded it
                                        ; first, then a later "mov rf,
                                        ; erl_scratch" clobbered it --
                                        ; gotcha #4, caught during the
                                        ; manual register trace)
            call    K_FILE_READ
            lbdf    erl_check_got       ; I/O error -- treat the same
                                        ; as EOF (matches the C
                                        ; reference's "r <= 0" merge)

            glo     rc
            lbnz    erl_got_byte        ; RC != 0: got a real byte
                                        ; (a 1-byte request can only
                                        ; ever return 0 or 1)

erl_check_got:
            mov     rf, erl_got
            ldn     rf
            lbnz    erl_terminate       ; already had content this
                                        ; call: EOF is the natural end
                                        ; of this (unterminated) line
            stc                         ; nothing read at all: true
                                        ; EOF
            rtn

erl_got_byte:
            mov     rf, erl_got
            ldi     1
            str     rf                  ; erl_got = 1

            mov     rf, erl_scratch
            ldn     rf                  ; D = the byte just read
            smi     10                  ; '\n' ?
            lbz     erl_terminate

            ; not a newline -- room for it? (count < maxlen - 1)
            mov     rf, erl_maxlen
            ldn     rf
            smi     1                   ; D = maxlen - 1
            str     r2                  ; [R2] = maxlen - 1
            mov     rf, erl_count
            ldn     rf                  ; D = count
            sm                          ; D = count - (maxlen - 1),
                                        ; DF = 1 iff count >= maxlen-1
            lbdf    erl_loop            ; full: silently drop this
                                        ; byte, keep reading

            ; room available: *wptr++ = byte; count++
            mov     rf, erl_wptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = wptr
            mov     rf, erl_scratch
            ldn     rf                  ; D = the byte
            str     r8                  ; *wptr = byte
            inc     r8                  ; wptr++
            mov     rf, erl_wptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; erl_wptr = wptr

            mov     rf, erl_count
            ldn     rf
            adi     1
            str     rf                  ; erl_count++

            lbr     erl_loop

erl_terminate:
            mov     rf, erl_wptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = wptr (== buf + count)
            ldi     0
            str     r8                  ; *wptr = 0 (null terminator)

            mov     rf, erl_count
            ldn     rf
            plo     rc
            ldi     0
            phi     rc                  ; RC = count (return value)
            clc
            rtn

; ----------------------------------------------------------------
; Proc-private scratch -- nothing outside env_read_line ever
; references these, so no extrn/public wiring is needed.
; ----------------------------------------------------------------
erl_handle:     db      0
erl_wptr:       dw      0
erl_maxlen:     db      0
erl_count:      db      0
erl_got:        db      0
erl_scratch:    db      0

            endp

; ----------------------------------------------------------------
; env_split_line: given a "NAME=VALUE" line, locate the '='
; separator, replace it with '\0' in place, so the NAME portion
; becomes its own null-terminated string at the start of the buffer.
; Args:    RF = line (mutated in place)
; Returns: RD = pointer to the VALUE portion (the byte after the old
;          '='), or RD = 0 if no '=' was found (RF's own content is
;          left untouched in that case)
; Modifies: RF (and D)
; ----------------------------------------------------------------
            proc    env_split_line

esl_loop:
            ldn     rf                  ; D = *RF
            lbz     esl_notfound        ; '\0': reached end, no '='
            smi     '='
            lbz     esl_found
            inc     rf
            lbr     esl_loop

esl_found:
            ldi     0
            str     rf                  ; *RF = '\0' (replaces '=')
            inc     rf
            mov     rd, rf              ; RD = pointer just past the
                                        ; old '=' (the value portion)
            rtn

esl_notfound:
            ldi     0
            phi     rd
            plo     rd                  ; RD = 0
            rtn

            endp

; ----------------------------------------------------------------
; _env_streq: byte-by-byte string equality check (not full strcmp
; ordering -- only equality is ever needed by this library). Hand-
; rolled rather than the BIOS's f_strcmp, whose clobber contract
; beyond its own documented args isn't confirmed for use outside the
; kernel.
; Args:    RF = str1, RD = str2
; Returns: DF = 0 if equal, DF = 1 if not equal
; Modifies: RF, RD (and D)
; ----------------------------------------------------------------
            proc    _env_streq

es_loop:
            ldn     rf                  ; D = *str1 (no advance yet)
            str     r2                  ; stage it (no register-
                                        ; register add16/sub16 runs
                                        ; before the xor below --
                                        ; gotcha #18)
            ldn     rd                  ; D = *str2
            xor                         ; D = *str1 XOR *str2
            lbnz    es_notequal

            ldn     rf                  ; D = *str1 again (reload --
                                        ; xor clobbered D): check for
                                        ; the terminator
            lbz     es_equal            ; both were NUL: fully matched

            inc     rf
            inc     rd
            lbr     es_loop

es_equal:
            clc
            rtn

es_notequal:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _env_write_line: write env_line_buf's current content (env_len
; bytes, as measured by the most recent env_read_line call) plus a
; trailing '\n' to env_out_handle. Shared by env_setenv and
; env_unsetenv for their "copy this line through unchanged" case.
; Args:    none (reads env_line_buf/env_len/env_out_handle directly)
; Returns: nothing
; Modifies: R7, R8, R9, RB, RC, RF (and D)
; ----------------------------------------------------------------
            proc    _env_write_line

            mov     rf, env_line_buf
            mov     rb, env_len
            lda     rb
            phi     rc
            ldn     rb
            plo     rc                  ; RC = env_len
            mov     rb, env_out_handle
            ldn     rb                  ; D = handle
            call    K_FILE_WRITE

            mov     rf, env_nl_byte
            ldi     0
            phi     rc
            ldi     1
            plo     rc                  ; RC = 1
            mov     rb, env_out_handle
            ldn     rb                  ; D = handle
            call    K_FILE_WRITE
            rtn

            endp

; ----------------------------------------------------------------
; env_getenv: look up an environment variable's value in the on-disk
; store.
; Args:    RF = name (null-terminated)
; Returns: RF = pointer to the value (an internal static buffer,
;          valid until the next env_getenv/env_setenv/env_unsetenv
;          call), or RF = 0 if not found or the env file doesn't
;          exist yet.
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF (and D) -- broad, via the
;          K_FILE_* calls this makes.
; ----------------------------------------------------------------
            proc    env_getenv

            mov     rb, env_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; env_name = name pointer

            mov     rf, env_file_path
            mov     rd, env_in_fcb
            mov     ra, env_in_iobuf
            ldi     0                   ; mode 0 = read -- set LAST,
                                        ; mov clobbers D (gotcha #4)
            call    K_FILE_OPEN
            lbdf    ge_notfound         ; can't open: no file yet

            plo     r9                  ; stash handle (D)
            mov     rb, env_in_handle
            glo     r9
            str     rb                  ; env_in_handle = handle

ge_loop:
            mov     rf, env_line_buf
            ldi     high ENV_LINE_MAX
            phi     rc
            ldi     low ENV_LINE_MAX
            plo     rc
            mov     rb, env_in_handle
            ldn     rb                  ; D = handle
            call    env_read_line
            lbdf    ge_eof              ; EOF: not found

            mov     rf, env_line_buf
            call    env_split_line      ; RD = value ptr or 0
            ghi     rd
            lbnz    ge_have_value
            glo     rd
            lbz     ge_loop             ; RD == 0: no '=' in this
                                        ; line, skip it (malformed)

ge_have_value:
            mov     rb, env_value
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; env_value = value ptr
                                        ; (stashed -- _env_streq below
                                        ; clobbers RD)

            mov     rf, env_line_buf    ; RF = str1 (the name portion,
                                        ; now null-terminated at the
                                        ; old '=' position)
            mov     rd, env_name
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8              ; RD = str2 (target name,
                                        ; reloaded fresh from memory)
            call    _env_streq
            lbdf    ge_loop             ; DF=1: no match, keep
                                        ; scanning

            ; match! close the file and return the stashed value ptr
            mov     rb, env_in_handle
            ldn     rb                  ; D = handle
            call    K_FILE_CLOSE

            mov     rb, env_value
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = value ptr (reloaded
                                        ; fresh -- K_FILE_CLOSE's own
                                        ; clobber footprint isn't
                                        ; trusted)
            rtn

ge_eof:
            mov     rb, env_in_handle
            ldn     rb
            call    K_FILE_CLOSE
ge_notfound:
            ldi     0
            phi     rf
            plo     rf
            rtn

            endp

; ----------------------------------------------------------------
; env_setenv: set (or update) an environment variable in the on-disk
; store.
; Args:    RF = name, RD = value, D = overwrite (0 = leave an
;          existing value untouched, nonzero = replace)
; Returns: DF = 0 on success, DF = 1 on error (name contains '=',
;          can't create the temp file, or the final rename failed)
; Modifies: broad -- everything but the caller's own registers before
;          the call; nothing survives across this routine's many
;          K_FILE_* calls except via the env_* scratch fields.
; ----------------------------------------------------------------
            proc    env_setenv

            plo     r9                  ; stash overwrite flag (D)
                                        ; immediately -- R9 is free
                                        ; here
            mov     rb, env_overwrite
            glo     r9
            str     rb                  ; env_overwrite = D

            mov     rb, env_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; env_name = name

            mov     rb, env_value
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; env_value = value

            ; reject a name containing '='
            mov     rf, env_name
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = name (reloaded fresh)
se_rej_loop:
            ldn     rf
            lbz     se_name_ok          ; reached NUL: no '=' found
            smi     '='
            lbz     se_reject
            inc     rf
            lbr     se_rej_loop

se_reject:
            stc
            rtn

se_name_ok:
            ; open the temp file for write (mode 1 = create/
            ; overwrite, always truncates fresh -- confirmed via this
            ; project's own file_open history)
            mov     rf, env_tmp_path
            mov     rd, env_out_fcb
            mov     ra, env_out_iobuf
            ldi     1                   ; set LAST (mov clobbers D,
                                        ; gotcha #4)
            call    K_FILE_OPEN
            lbdf    se_reject           ; can't create temp file

            plo     r9
            mov     rb, env_out_handle
            glo     r9
            str     rb                  ; env_out_handle = handle

            mov     rb, env_found
            ldi     0
            str     rb                  ; env_found = 0

            ; open the source file for read -- failure here is NOT
            ; fatal, it just means there's no existing env file yet
            mov     rf, env_file_path
            mov     rd, env_in_fcb
            mov     ra, env_in_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    se_no_source        ; open failed: skip the copy
                                        ; loop entirely

            plo     r9
            mov     rb, env_in_handle
            glo     r9
            str     rb                  ; env_in_handle = handle

se_copy_loop:
            mov     rf, env_line_buf
            ldi     high ENV_LINE_MAX
            phi     rc
            ldi     low ENV_LINE_MAX
            plo     rc
            mov     rb, env_in_handle
            ldn     rb
            call    env_read_line
            lbdf    se_close_in         ; EOF: done copying

            mov     rb, env_len
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb                  ; env_len = length (needed by
                                        ; _env_write_line below)

            ; preserve the pristine line: copy env_line_buf into
            ; env_namebuf, then split THAT copy (env_split_line
            ; mutates in place), so env_line_buf survives intact for
            ; a possible unchanged-copy-through write
            mov     rf, env_line_buf
            mov     rd, env_namebuf
se_cpy_loop:
            lda     rf
            str     rd
            lbnz    se_cpy_next
            lbr     se_cpy_done
se_cpy_next:
            inc     rd
            lbr     se_cpy_loop
se_cpy_done:

            mov     rf, env_namebuf
            call    env_split_line      ; RD = value ptr or 0
            ghi     rd
            lbnz    se_check_name
            glo     rd
            lbz     se_copy_through     ; RD == 0: no '=', copy
                                        ; through unchanged

se_check_name:
            mov     rf, env_namebuf
            mov     rd, env_name
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8              ; RD = target name
            call    _env_streq
            lbdf    se_copy_through     ; DF=1: no match, copy through

            ; match found
            mov     rb, env_found
            ldi     1
            str     rb                  ; env_found = 1

            mov     rb, env_overwrite
            ldn     rb
            lbz     se_write_old        ; overwrite==0: keep the
                                        ; original line verbatim

            call    se_write_nv         ; overwrite: write
                                        ; name=value\n
            lbr     se_copy_loop

se_write_old:
            call    _env_write_line
            lbr     se_copy_loop

se_copy_through:
            call    _env_write_line
            lbr     se_copy_loop

se_close_in:
            mov     rb, env_in_handle
            ldn     rb
            call    K_FILE_CLOSE

se_no_source:
            ; if not found, append name=value\n before closing the
            ; output file
            mov     rb, env_found
            ldn     rb
            lbnz    se_close_out

            call    se_write_nv

se_close_out:
            mov     rb, env_out_handle
            ldn     rb
            call    K_FILE_CLOSE

            ; swap the temp file into place
            mov     rf, env_file_path
            call    K_FILE_DELETE       ; DF ignored -- may not exist

            mov     rf, env_tmp_path
            mov     rd, env_dat_name
            call    K_FILE_RENAME       ; DF = overall return value
            rtn

; ----------------------------------------------------------------
; se_write_nv: write env_name + '=' + env_value + '\n' to
; env_out_handle. Internal to env_setenv only (called via a plain
; `call` from within this same proc -- no extrn/public needed, unlike
; genuinely cross-proc routines).
; ----------------------------------------------------------------
se_write_nv:
            mov     rf, env_name
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = name pointer
            call    se_strlen           ; RC = length, RF unchanged
                                        ; (se_strlen never touches RF)
            mov     rb, env_out_handle
            ldn     rb                  ; D = handle
            call    K_FILE_WRITE

            mov     rf, env_eq_byte
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     rb, env_out_handle
            ldn     rb
            call    K_FILE_WRITE

            mov     rf, env_value
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = value pointer
            call    se_strlen
            mov     rb, env_out_handle
            ldn     rb
            call    K_FILE_WRITE

            mov     rf, env_nl_byte
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     rb, env_out_handle
            ldn     rb
            call    K_FILE_WRITE
            rtn

; ----------------------------------------------------------------
; se_strlen: Args RF = str (left UNCHANGED -- scans with its own
; private copy in R8, never touching the caller's RF). Returns
; RC = length. Makes no calls of its own, so this is provably safe
; by direct inspection, not merely documented.
; ----------------------------------------------------------------
se_strlen:
            mov     r8, rf              ; R8 = scan pointer (copy)
            ldi     0
            phi     rc
            plo     rc                  ; RC = 0
se_strlen_loop:
            ldn     r8
            lbz     se_strlen_done
            inc     r8
            inc     rc
            lbr     se_strlen_loop
se_strlen_done:
            rtn

            endp

; ----------------------------------------------------------------
; env_unsetenv: remove an environment variable from the on-disk
; store.
; Args:    RF = name
; Returns: DF = 0 on success (including when the variable was not
;          set to begin with, matching the real unsetenv), DF = 1 on
;          error (name contains '=', can't create the temp file, or
;          the final rename failed)
; Modifies: broad, via this routine's many K_FILE_* calls.
; ----------------------------------------------------------------
            proc    env_unsetenv

            mov     rb, env_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; env_name = name

            mov     rf, env_name
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
ue_rej_loop:
            ldn     rf
            lbz     ue_name_ok
            smi     '='
            lbz     ue_reject
            inc     rf
            lbr     ue_rej_loop

ue_reject:
            stc
            rtn

ue_name_ok:
            mov     rf, env_tmp_path
            mov     rd, env_out_fcb
            mov     ra, env_out_iobuf
            ldi     1
            call    K_FILE_OPEN
            lbdf    ue_reject

            plo     r9
            mov     rb, env_out_handle
            glo     r9
            str     rb

            mov     rf, env_file_path
            mov     rd, env_in_fcb
            mov     ra, env_in_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    ue_close_out        ; no source file: nothing to
                                        ; copy, just finish up

            plo     r9
            mov     rb, env_in_handle
            glo     r9
            str     rb

ue_copy_loop:
            mov     rf, env_line_buf
            ldi     high ENV_LINE_MAX
            phi     rc
            ldi     low ENV_LINE_MAX
            plo     rc
            mov     rb, env_in_handle
            ldn     rb
            call    env_read_line
            lbdf    ue_close_in

            mov     rb, env_len
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            mov     rf, env_line_buf
            mov     rd, env_namebuf
ue_cpy_loop:
            lda     rf
            str     rd
            lbnz    ue_cpy_next
            lbr     ue_cpy_done
ue_cpy_next:
            inc     rd
            lbr     ue_cpy_loop
ue_cpy_done:

            mov     rf, env_namebuf
            call    env_split_line
            ghi     rd
            lbnz    ue_check_name
            glo     rd
            lbz     ue_copy_through

ue_check_name:
            mov     rf, env_namebuf
            mov     rd, env_name
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8
            call    _env_streq
            lbdf    ue_copy_through     ; no match: copy through

            ; match: drop the line (don't write it), just loop
            lbr     ue_copy_loop

ue_copy_through:
            call    _env_write_line
            lbr     ue_copy_loop

ue_close_in:
            mov     rb, env_in_handle
            ldn     rb
            call    K_FILE_CLOSE

ue_close_out:
            mov     rb, env_out_handle
            ldn     rb
            call    K_FILE_CLOSE

            mov     rf, env_file_path
            call    K_FILE_DELETE

            mov     rf, env_tmp_path
            mov     rd, env_dat_name
            call    K_FILE_RENAME
            rtn

            endp

; ----------------------------------------------------------------
; Shared data -- reused across env_getenv/env_setenv/env_unsetenv/
; _env_write_line, never active concurrently within one caller (see
; this file's own header comment).
; ----------------------------------------------------------------
            proc    _env_data

env_line_buf:       ds      ENV_LINE_MAX
env_namebuf:        ds      ENV_LINE_MAX
env_in_fcb:         ds      FCB_LEN
env_in_iobuf:       ds      FCB_IOBUF_LEN
env_out_fcb:        ds      FCB_LEN
env_out_iobuf:      ds      FCB_IOBUF_LEN
env_name:           dw      0
env_value:          dw      0
env_overwrite:      db      0
env_in_handle:      db      0
env_out_handle:     db      0
env_found:          db      0
env_len:            dw      0
env_eq_byte:        db      '='
env_nl_byte:        db      10
env_file_path:      db      "/cfg/env.dat",0
env_tmp_path:       db      "/cfg/env.tmp",0
env_dat_name:       db      "env.dat",0

                public  env_line_buf
                public  env_namebuf
                public  env_in_fcb
                public  env_in_iobuf
                public  env_out_fcb
                public  env_out_iobuf
                public  env_name
                public  env_value
                public  env_overwrite
                public  env_in_handle
                public  env_out_handle
                public  env_found
                public  env_len
                public  env_eq_byte
                public  env_nl_byte
                public  env_file_path
                public  env_tmp_path
                public  env_dat_name

            endp
