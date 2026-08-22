;
; dirgrowtest.asm - stress-test directory-cluster-chain growth
;
; Motivated by real, hardware-reported corruption in /cfg (2026-08-21)
; after heavy EXPORT/UNSET activity while testing TERMSIZE. lib/env.asm's
; own temp-file-then-delete-then-rename pattern (K_FILE_OPEN create +
; K_FILE_DELETE + K_FILE_RENAME) never reuses a deleted directory-entry
; slot -- new entries are only ever appended after the terminator -- so
; repeated create/delete/rename cycles permanently consume directory-
; entry space, even though the real file count stays flat. Enough of
; that activity plausibly pushed /cfg past its first cluster for the
; first time this card ever saw, landing in kernel/file.asm's fc_grow
; path (the directory-cluster-chain-extension code inside
; dir_create/_file_create) -- which has two already-documented,
; already-fixed historical bugs (a register clobber, a FAT-flush-
; timing issue) whose fsck symptoms matched what was actually observed
; closely. This test reproduces the EXACT SAME kernel-call sequence
; env_setenv/env_unsetenv use, at whatever volume is requested, against
; a disposable SCRATCH directory (never /cfg, never anything real) so
; the result can be fsck'd without risking real data.
;
; Usage: DIRGROWTEST [iterations]
;   iterations defaults to DGT_DEFAULT_ITER if omitted or not a valid
;   positive number.
;
; Creates "dirgrow" as a subdirectory of the CURRENT directory --
; fails loudly and does nothing else if it already exists (remove any
; leftover "dirgrow" from a prior run first, or cd somewhere
; disposable before running). Each iteration:
;   1. K_FILE_OPEN("dirgrow/tmp.dat", mode=1) -- create/overwrite
;   2. K_FILE_WRITE a small fixed 4-byte pattern (non-empty, matching
;      env.tmp's own real usage)
;   3. K_FILE_CLOSE
;   4. K_FILE_DELETE("dirgrow/old.dat") -- DF ignored, may not exist
;      yet (true on iteration 1, matching env.dat's own "may not
;      exist" precedent in lib/env.asm)
;   5. K_FILE_RENAME("dirgrow/tmp.dat" -> "old.dat")
; -- exactly mirroring env_setenv's own real operation sequence, using
; the same kernel primitives, at real volume.
;
; Stops immediately and reports the exact iteration/step on any
; unexpected failure (step 1 or step 5 -- step 4 ignores DF, matching
; env.asm's own precedent), rather than continuing into what might
; already be a corrupted state. On completing every requested
; iteration successfully, prints a summary and a reminder to fsck now.
;
; This may take a real while on hardware (each iteration is 5 kernel
; calls plus real disk I/O) -- progress is printed periodically so a
; long run doesn't look hung.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

DGT_DEFAULT_ITER:   equ     2000
DGT_PROGRESS_EVERY: equ     100

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; --- parse the optional iteration-count argument ---
            ghi     rc
            lbnz    dgt_have_arg        ; argc > 255: certainly has an
                                        ; argument (practically
                                        ; impossible, handled defensively)
            glo     rc
            smi     2
            lbnf    dgt_use_default     ; argc < 2: no argument given

dgt_have_arg:
            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1]
            call    dgt_parse_uint      ; RD = parsed value (0 if no
                                        ; valid digits at all)
            ghi     rd
            lbnz    dgt_iter_set
            glo     rd
            lbnz    dgt_iter_set
            ; parsed to exactly 0 (empty/non-numeric argument) -- fall
            ; back to the default rather than running zero iterations

dgt_use_default:
            ldi     high DGT_DEFAULT_ITER
            phi     rd
            ldi     low DGT_DEFAULT_ITER
            plo     rd

dgt_iter_set:
            mov     rf, dgt_remaining
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dgt_remaining = iteration count

            mov     rf, dgt_i
            ldi     0
            str     rf
            inc     rf
            ldi     0
            str     rf                  ; dgt_i = 0

            mov     rf, dgt_progress_ctr
            ldi     0
            str     rf                  ; dgt_progress_ctr = 0

            call    K_INMSG
            db      "dirgrowtest: creating scratch directory 'dirgrow' and stress-testing directory-entry growth. This may take a while on real hardware -- progress prints every ",0
            ldi     high DGT_PROGRESS_EVERY
            phi     rd
            ldi     low DGT_PROGRESS_EVERY
            plo     rd
            mov     rf, dgt_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, dgt_num_buf
            call    K_MSG
            call    K_INMSG
            db      " iterations.",13,10,0

            ; --- create the scratch directory ---
            mov     rf, dgt_dirname
            call    K_DIR_CREATE
            lbnf    dgt_dir_ok

            call    K_INMSG
            db      "Could not create 'dirgrow' -- it may already exist from a prior run (remove it first) or the current directory may be full. Stopping.",13,10,0
            ldi     1
            rtn

dgt_dir_ok:
;------------------------------------------------------------------
; Main loop -- checks dgt_remaining first (so a requested count of 0
; correctly does nothing), decrements after each real iteration.
;------------------------------------------------------------------
dgt_loop:
            mov     rf, dgt_remaining
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = dgt_remaining
            ghi     r8
            lbnz    dgt_do_iteration
            glo     r8
            lbnz    dgt_do_iteration
            lbr     dgt_all_done        ; both bytes zero: finished

dgt_do_iteration:
            ; --- step 1: create/overwrite tmp.dat ---
            mov     rf, dgt_tmp_path
            mov     rd, dgt_fcb
            mov     ra, dgt_iobuf
            ldi     1                   ; mode 1, set LAST (mov
                                        ; clobbers D, gotcha #4)
            call    K_FILE_OPEN
            lbdf    dgt_fail_open

            ; --- step 2: write a small fixed 4-byte pattern ---
            mov     rf, dgt_pattern
            ldi     0
            phi     rc
            ldi     4
            plo     rc                  ; RC = 4
            mov     rd, dgt_fcb
            call    K_FILE_WRITE

            ; --- step 3: close ---
            mov     rd, dgt_fcb
            call    K_FILE_CLOSE

            ; --- step 4: delete old.dat (DF ignored -- may not exist
            ; yet, matches env.dat's own "may not exist" precedent) ---
            mov     rf, dgt_old_path
            call    K_FILE_DELETE

            ; --- step 5: rename tmp.dat -> old.dat ---
            mov     rf, dgt_tmp_path
            mov     rd, dgt_old_name
            call    K_FILE_RENAME
            lbdf    dgt_fail_rename

            ; --- dgt_i++ (total completed, for progress/summary) ---
            mov     rf, dgt_i
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            inc     r8
            mov     rf, dgt_i
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; dgt_i++

            ; --- progress_ctr++; print+reset at the threshold ---
            mov     rf, dgt_progress_ctr
            ldn     rf
            adi     1
            str     rf                  ; dgt_progress_ctr++ (D still
                                        ; holds the new value here)
            smi     DGT_PROGRESS_EVERY
            lbnz    dgt_no_progress     ; not yet at the threshold

            mov     rf, dgt_progress_ctr
            ldi     0
            str     rf                  ; reset to 0
            call    dgt_print_progress
dgt_no_progress:

            ; --- dgt_remaining -= 1 (immediate form -- no M(R2)
            ; staging involved, safe regardless of gotcha #18) ---
            mov     rf, dgt_remaining
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dgt_remaining
            sub16   rd, 1
            mov     rf, dgt_remaining
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dgt_remaining = RD

            lbr     dgt_loop

dgt_fail_open:
            call    K_INMSG
            db      "FAILED: K_FILE_OPEN(dirgrow/tmp.dat) at iteration ",0
            lbr     dgt_print_fail_count

dgt_fail_rename:
            call    K_INMSG
            db      "FAILED: K_FILE_RENAME(tmp.dat -> old.dat) at iteration ",0

dgt_print_fail_count:
            mov     rf, dgt_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dgt_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, dgt_num_buf
            call    K_MSG
            call    K_INMSG
            db      " (iterations completed successfully before this one). Stopping -- fsck 'dirgrow' now.",13,10,0
            ldi     1
            rtn

dgt_all_done:
            call    K_INMSG
            db      "dirgrowtest: completed ",0
            mov     rf, dgt_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dgt_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, dgt_num_buf
            call    K_MSG
            call    K_INMSG
            db      " iterations with no kernel-reported errors. Run fsck now to check 'dirgrow' for on-disk corruption.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; dgt_print_progress: print "  <dgt_i> iterations..." to the console.
; Args: none (reads dgt_i directly). Returns: nothing.
;------------------------------------------------------------------
dgt_print_progress:
            call    K_INMSG
            db      "  ",0
            mov     rf, dgt_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dgt_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, dgt_num_buf
            call    K_MSG
            call    K_INMSG
            db      " iterations...",13,10,0
            rtn

;------------------------------------------------------------------
; dgt_parse_uint: parse a decimal string into an unsigned integer,
; stopping at the first non-digit character. Direct copy of
; lib/env.asm's own hardware-confirmed env_parse_uint (itself moved
; there from progs/date.asm's own hard-won-correct parse_uint,
; including its own *2-not-*4 bugfix history) -- not linked from
; lib/env.asm since this program is deliberately self-contained, no
; lib/ dependencies.
; Args:    RF = string pointer
; Returns: RD = parsed value (0 if the string starts with a
;          non-digit), RF = pointer to the first non-digit character
; Modifies: R8, R9, RD, RF (and D)
;------------------------------------------------------------------
dgt_parse_uint:
            ldi     0
            phi     rd
            plo     rd                  ; RD = 0

dgt_pu_loop:
            ldn     rf
            smi     '0'
            lbnf    dgt_pu_done         ; *RF < '0': not a digit
            plo     r9                  ; R9.0 = candidate digit value
            smi     10                  ; D = candidate - 10, DF=1 if
                                        ; candidate >= 10 (no borrow)
            lbdf    dgt_pu_done         ; not a valid digit

            mov     r8, rd
            shl16   r8
            shl16   r8
            shl16   r8                  ; R8 = RD*8
            shl16   rd                  ; RD = RD*2
            add16   rd, r8              ; RD = RD*10
            add16   rd, r9              ; RD += digit
            inc     rf
            lbr     dgt_pu_loop

dgt_pu_done:
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
dgt_dirname:        db      "dirgrow",0
dgt_tmp_path:       db      "dirgrow/tmp.dat",0
dgt_old_path:       db      "dirgrow/old.dat",0
dgt_old_name:       db      "old.dat",0     ; bare name, no separator
                                            ; -- K_FILE_RENAME's own
                                            ; documented contract
dgt_pattern:        db      "test"          ; exactly 4 bytes, no NUL
                                            ; needed (K_FILE_WRITE
                                            ; writes exactly RC bytes)

dgt_fcb:            ds      FCB_LEN
dgt_iobuf:          ds      FCB_IOBUF_LEN
dgt_num_buf:        ds      6               ; decimal scratch for
                                            ; f_uintout (max "65535"+0)
dgt_i:              dw      0               ; iterations completed so
                                            ; far (counts UP)
dgt_remaining:      dw      0               ; iterations left to run
                                            ; (counts DOWN to 0)
dgt_progress_ctr:   db      0

            end     start
