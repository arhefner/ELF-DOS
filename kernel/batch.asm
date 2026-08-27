;
; batch.asm - kernel-resident batch-script dispatcher, plus %0-%9
; batch-argument substitution (unaffected by the split below)
;
; REDESIGNED 2026-07-30 (loadable batch module, phase 1), THEN AGAIN
; 2026-07-31 (phase 2, genuine relocation): the actual line-reading/
; GOTO-scanning logic (what used to live directly in this file as
; batch_start/batch_readline/batch_goto) moved out into
; kernel/batch_mod.asm, a standalone, separately-built module that
; lands on disk as /bin/batch.mod and is loaded fresh into RAM every
; single time K_BATCH_START runs -- now via lib/modload.asm's
; mod_load, which finds a page-aligned home for it wherever
; K_HIMEM_RESERVE can, instead of Phase 1's fixed BATCHMOD_BASE
; ($D000). Since the module's own base address is only known at
; runtime, this file reaches its entry points via lib/icall.asm's
; indirect call rather than a plain LBR to a compile-time constant.
; See kernel/batch_mod.asm's own header comment, lib/modload.asm's own
; header comment, and the project's own design plan for the full
; mechanism.
;
; What THIS file still owns, unchanged by the split: the K_BATCH_*
; jump-table entry points keep the exact same names/addresses/
; contracts as before (batch_start/batch_readline/batch_goto), but
; they're now DISPATCHERS -- check a kernel-resident "is a batch
; active" flag, load/call into/clean up after the module as needed --
; not the line-reading logic itself. kernel_batch_args_reserve/
; kernel_batch_args_getarg/_batch_args_release (the %0-%9 substitution
; machinery) are completely untouched: a clean, already-small, already-
; separate concern with no dependency on anything that moved.
;
; Why the "is a batch active" flag has to live here, not be inferred
; from the module's own batch_fcb (as the pre-split code did, via
; FCB_F_OPEN): this file's own dispatchers reload the module COMPLETELY
; FRESH from disk on every single K_BATCH_START call -- so batch_fcb's
; in-RAM content right before a reload can't be trusted to reflect
; "no batch currently active" even when that's true (a short/partial
; disk read wouldn't necessarily overwrite every ds-reserved byte with
; fresh zeros). This flag is the single, kernel-resident source of
; truth instead: checked BEFORE ever touching $D000 (so a nested
; ".bat calls another .bat" attempt is rejected without reloading over
; a batch that's still genuinely running), and cleared -- along with
; restoring mem_top and releasing any %N reservation -- only once the
; module itself reports real batch-end (DF=1) from an ALREADY-active
; state. See batch_mod_teardown below.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc
#include    include/batchmod.inc

; cross-file references into lib/modload.asm and lib/icall.asm --
; batch_mod_load/batch_mod_unclamp below are now thin wrappers around
; these, replacing the old file_stat/file_open/file_read/file_close/
; prog_fcb/prog_iobuf-based Phase 1 loading logic entirely (no longer
; referenced anywhere in this file).
            extrn   mod_load
            extrn   mod_release
            extrn   icall

; cross-file references into kernel/redir.asm -- the same shared
; himem-adjacent primitive kernel/glob.asm already reuses too.
; Only used by kernel_batch_args_reserve/_release below (unchanged) --
; the module's own memory now goes through mod_load/mod_release (which
; call K_HIMEM_RESERVE/K_HIMEM_RELEASE internally), not this file's own
; direct _himem_reserve/_himem_release calls the way Phase 1 did.
            extrn   _himem_reserve
            extrn   _himem_release
            extrn   mem_top

; cross-file references into kernel/loader.asm -- mod_load's own
; caller-supplied-FCB/iobuf convention (see its own header comment)
; reuses these exactly the way the old Phase 1 loader did: provably
; idle at every point batch_mod_load can be called from (no program
; load is ever in flight while a batch is starting/reading a line).
; BUG FIX (2026-08-01, hardware-found boot hang): batch_mod_load below
; originally called mod_load with ONLY RF set, never RD/RA at all --
; mod_load's very first real action, K_FILE_OPEN, therefore ran
; against whatever garbage happened to be sitting in RD/RA at that
; point in boot, not a real FCB/iobuf pair. A targeted diagnostic
; ([K1]/[B1] printed, [M1] -- placed right before mod_load's own
; fixup loop, well after the file-open/header-read/reserve steps --
; never did) pinpointed the corruption to mod_load's very first
; operation, exactly matching this gap.
            extrn   prog_fcb
            extrn   prog_iobuf

; same-file cross-proc data references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   batch_mod_active
            extrn   batch_mod_base
            extrn   batch_mod_reserve_size
            extrn   batch_args_reserved
            extrn   batch_args_empty

; same-file cross-proc CODE references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   batch_mod_load
            extrn   batch_mod_unclamp
            extrn   batch_mod_teardown
            extrn   _batch_args_release

; ----------------------------------------------------------------
; batch_start: K_BATCH_START's jump-table target. Begin executing a
; batch script.
; Args:    RF = pointer to a null-terminated path, already resolved
;          (and confirmed to exist) by the caller -- see
;          progs/shell.asm's own K_STAT check before calling this.
; Returns: DF = 0 on success (a batch is now active; the next call to
;          K_BATCH_READLINE will return its first line), DF = 1 if a
;          batch is already active (nesting isn't supported), the
;          module couldn't be loaded (see batch_mod_load), or the
;          .bat file itself couldn't be opened.
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_start

            mov     rd, batch_mod_active
            ldn     rd
            lbnz    bst_reject          ; already active: reject
                                        ; WITHOUT ever touching the
                                        ; module -- a batch is
                                        ; genuinely still running there

            ; stash the caller's own path argument -- batch_mod_load
            ; below needs RF as scratch for its own file_stat/
            ; file_open calls, and won't return for a while
            mov     rd, bst_path
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd

            call    batch_mod_load      ; DF=0/1 -- (re)loads the
                                        ; module fresh, wherever
                                        ; mod_load finds room; on DF=1
                                        ; nothing was changed at all
            lbdf    bst_reject

            ; module is now resident -- compute the icall target
            ; (batch_mod_base + MOD_START_OFF) FIRST, using RF as
            ; scratch to read batch_mod_base from memory, THEN restore
            ; the caller's own path argument into RF LAST, right
            ; before the call -- reversing this order would let the
            ; target computation clobber the path argument, since both
            ; need RF at different points
            mov     rf, batch_mod_base
            lda     rf
            phi     rb
            ldn     rf
            plo     rb
            ; RB += MOD_START_OFF (6 repeated INCs, not ADD16 -- 6
            ; bytes vs 8 for a constant this small, and INC never
            ; touches D/DF; matches this project's own established
            ; preference)
            inc     rb
            inc     rb
            inc     rb
            inc     rb
            inc     rb
            inc     rb                  ; RB = batch_mod_base+MOD_START_OFF

            mov     rf, bst_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = path (restored, LAST)

            call    icall
            lbdf    bst_mod_open_failed ; the .bat file itself
                                        ; couldn't be opened -- unwind
                                        ; the reservation; nothing
                                        ; was ever marked active

            mov     rf, batch_mod_active
            ldi     $FF
            str     rf

            ; a NEW batch never inherits a PREVIOUS batch's echo-off
            ; mode is already handled inside the module's own
            ; batch_start (RUN_BATCH_ECHO_OFF reset) -- nothing more
            ; needed here
            clc
            rtn

bst_mod_open_failed:
            call    batch_mod_unclamp
            stc
            rtn

bst_reject:
            stc
            rtn

bst_path:      dw      0           ; local to this proc only -- see
                                    ; header comment above

            endp

; ----------------------------------------------------------------
; batch_mod_load: (re)load the batch module fresh from /bin/batch.mod,
; wherever lib/modload.asm's mod_load can find room. Does NOT call
; into the module -- batch_start above does that once this returns
; DF=0. Thin wrapper (2026-07-31, Phase 2) -- all the size validation,
; magic checking, and headroom bookkeeping that used to live directly
; in this proc now lives in mod_load itself, shared with any other
; caller that wants a relocatable module loaded.
; Args:    none
; Returns: DF = 0 on success: batch_mod_base/batch_mod_reserve_size
;          are populated (the module's real load address, and the
;          reservation size batch_mod_unclamp must pass back later).
;          DF = 1 on any failure (mod_load already guarantees nothing
;          was left reserved or open in that case).
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_mod_load

            mov     rf, batchmod_path
            mov     rd, prog_fcb        ; BUG FIX (2026-08-01): mod_load
                                        ; requires a caller-supplied
                                        ; FCB/iobuf (RD/RA) -- this call
                                        ; site never set them before,
                                        ; see the extrn block above for
                                        ; the full incident
            mov     ra, prog_iobuf
            call    mod_load            ; DF=0/1, RD=base, RC=reserve
                                        ; size (see lib/modload.asm)
            lbdf    bml_fail

            mov     rf, batch_mod_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, batch_mod_reserve_size
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            clc
            rtn

bml_fail:
            stc
            rtn

batchmod_path:      db      "/bin/batch.mod",0

            endp

; ----------------------------------------------------------------
; batch_mod_unclamp: reverse batch_mod_load's reservation via
; mod_release. Kept as its own proc/name (2026-07-31, Phase 2 -- was
; "restore mem_top from a saved absolute value" in Phase 1) since
; every existing caller already calls it at exactly the right moments.
; Args:    none
; Returns: nothing
; Modifies: whatever mod_release/K_HIMEM_RELEASE modifies
; ----------------------------------------------------------------
            proc    batch_mod_unclamp

            mov     rf, batch_mod_reserve_size
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            call    mod_release
            rtn

            endp

; ----------------------------------------------------------------
; batch_mod_teardown: called once batch_readline/batch_goto's own
; dispatcher wrapper below sees DF=1 come back from the module WHILE a
; batch was already known active -- i.e. the batch just genuinely
; ended (EOF, an I/O error, or GOTO-to-an-undefined-label, all of
; which the module itself already reports as DF=1 the same way).
; Clears the "batch active" flag, restores mem_top, and releases any
; active %0-%9 reservation -- all three are kernel-resident concerns
; the module has no business touching directly (see this file's own
; top-of-file header comment).
; Args:    none
; Returns: nothing
; Modifies: RC, RD, RF
; ----------------------------------------------------------------
            proc    batch_mod_teardown

            mov     rf, batch_mod_active
            ldi     0
            str     rf

            call    batch_mod_unclamp

            call    _batch_args_release ; no-op if %N support was never
                                        ; reserved for this batch
            rtn

            endp

; ----------------------------------------------------------------
; batch_readline: K_BATCH_READLINE's jump-table target. Fast-paths to
; DF=1 with the module completely untouched when no batch is active --
; this runs on EVERY shell command cycle (batch active or not), so
; that path has to stay cheap.
; Args:    none
; Returns: DF = 0 with LINE_BUF holding the next line (null-
;          terminated, CR/LF stripped) if a batch is active and a line
;          was available; DF = 1 if no batch is active, or the batch
;          just reached EOF (torn down via batch_mod_teardown in that
;          case, so the caller's very next command cycle goes back to
;          reading from the console automatically)
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_readline

            mov     rd, batch_mod_active
            ldn     rd
            lbz     brl_disp_inactive   ; no batch active: DF=1, the
                                        ; module is never touched

            mov     rf, batch_mod_base
            lda     rf
            phi     rb
            ldn     rf
            plo     rb
            add16   rb, MOD_READLINE_OFF

            call    icall
            lbdf    brl_disp_ended

            clc                         ; DF=0: real line, LINE_BUF
                                        ; already holds it
            rtn

brl_disp_ended:
            call    batch_mod_teardown
            stc
            rtn

brl_disp_inactive:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; batch_goto: K_BATCH_GOTO's jump-table target. Same fast-path shape
; as batch_readline above.
; Args:    RF = pointer to a null-terminated label name, no leading ':'
; Returns: DF = 0/1 -- see kernel_api.inc's own K_BATCH_GOTO doc
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_goto

            mov     rd, batch_mod_active
            ldn     rd
            lbz     bg_disp_inactive

            ; stash the caller's own label-name argument FIRST -- RF
            ; is about to be used as scratch to compute the icall
            ; target (same ordering concern as batch_start's own
            ; dispatch tail above)
            mov     rd, bg_label_arg
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd

            mov     rf, batch_mod_base
            lda     rf
            phi     rb
            ldn     rf
            plo     rb
            add16   rb, MOD_GOTO_OFF

            mov     rf, bg_label_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = label name (restored, LAST)

            call    icall
            lbdf    bg_disp_ended

            clc
            rtn

bg_disp_ended:
            call    batch_mod_teardown
            stc
            rtn

bg_disp_inactive:
            stc
            rtn

bg_label_arg:  dw      0           ; local to this proc only

            endp

; ----------------------------------------------------------------
; kernel_batch_args_reserve: K_BATCH_ARGS_RESERVE's jump-table target
; -- %0-%9 batch-argument substitution (2026-07-25). UNCHANGED by the
; 2026-07-30 loadable-module split -- see kernel_api.inc's own doc
; comment for the full contract. Mirrored kernel/glob.asm's own
; kernel_glob_reserve almost exactly at the time both existed (that
; file was later removed as dead code -- see kernel_api.inc's own
; removal note); reuses the same shared _himem_reserve/_himem_release
; mechanism (kernel/redir.asm) rather than inventing a new reservation
; routine -- that mechanism is already length-parameterized, flag-
; agnostic, and already proven safe with multiple simultaneous callers
; (this file's own reservation can be active at the same time as a
; per-command dual-redirect reservation, nested, with no special
; handling needed here).
;
; Deliberately NOT idempotent the way kernel_glob_reserve used to be:
; this is only ever called once per batch, right after K_BATCH_START
; succeeds, and starting a new batch while one is already active is
; already rejected (nested batch) before this could ever be reached
; twice without a release in between.
;
; Population (packing the actual argument text/pointers into the
; reserved block) is deliberately NOT done here -- it happens shell-
; side, in progs/shell.asm's own is_batch:, which already has
; RUN_ARGV_TABLE/RUN_ARGC in hand. This proc's only job is reserving
; the space and handing back where it starts.
;
; Args:    none
; Returns: DF = 0 on success, RD = base address (mem_top + 1); DF = 1
;          if there isn't enough RAM headroom (nothing changed)
; Modifies: RC, RD, RF
; ----------------------------------------------------------------
            proc    kernel_batch_args_reserve

            ldi     high BATCH_ARGS_RESERVE_LEN
            phi     rc
            ldi     low BATCH_ARGS_RESERVE_LEN
            plo     rc
            call    _himem_reserve
            lbdf    kbar_fail

            mov     rf, batch_args_reserved
            ldi     $FF
            str     rf

            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; RD = mem_top + 1
            clc
            rtn

kbar_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; kernel_batch_args_getarg: K_BATCH_ARGS_GETARG's jump-table target.
; UNCHANGED by the 2026-07-30 loadable-module split. See
; kernel_api.inc's own doc comment for the full contract.
; Bounds-checks the requested index against the reservation's own
; stored count (BATCH_ARGS_ARGC_OFF, populated once by the shell at
; reserve time) BEFORE ever touching the pointer table -- so this can
; never return a pointer into an unpopulated BATCH_ARGV slot, which
; could otherwise hold leftover RAM garbage from before the
; reservation was made.
;
; Args:    D = index (0-9)
; Returns: DF = 0 in every case where a reservation is currently
;          active: RF = the real argument's pointer (index < the
;          stored count), or RF = batch_args_empty (index >= the
;          stored count -- a fixed, always-valid empty string, never a
;          read of the unpopulated slot). DF = 1 only when NO
;          reservation is active at all.
; Modifies: R8, R9, RF
; ----------------------------------------------------------------
            proc    kernel_batch_args_getarg

            plo     r8                  ; R8.0 = the requested index,
                                        ; stashed before D gets reused
                                        ; below (gotcha #4)

            mov     rf, batch_args_reserved
            ldn     rf
            lbz     kbag_inactive

            mov     rf, mem_top
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            inc     r9                  ; R9 = base = mem_top + 1

            ; SM computes D = D - M(R(X)), NOT M(R(X)) - D -- subtrahend
            ; (count) staged first, minuend (index) loaded right before
            ; sm. Nothing register-register (add16/sub16) runs between
            ; the str r2 and this sm -- the add16 right after it is the
            ; immediate-constant form (a plain equ offset), which
            ; gotcha #18 doesn't apply to.
            mov     rf, r9
            add16   rf, BATCH_ARGS_ARGC_OFF
            ldn     rf                  ; D = stored count
            str     r2                  ; M(R2) = count
            glo     r8                  ; D = index (loaded LAST,
                                        ; right before sm)
            sm                          ; D = D - M(R2) = index - count
            lbdf    kbag_empty          ; index >= count (no borrow)

            ; index < count: real arg -- RF = base + ARGV_OFF + index*2
            glo     r8
            plo     rd
            ldi     0
            phi     rd
            shl16   rd                  ; RD = index * 2
            mov     rf, r9
            add16   rf, BATCH_ARGS_ARGV_OFF
            add16   rf, rd              ; RF = &argv_table[index]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9              ; RF = the real arg pointer
            clc
            rtn

kbag_empty:
            mov     rf, batch_args_empty
            clc
            rtn

kbag_inactive:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _batch_args_release: kernel-internal only (no jump-table slot --
; called from batch_mod_teardown above, same link unit; mirrored
; kernel/glob.asm's own _glob_release shape at the time that file
; still existed -- see kernel_api.inc's own removal note). UNCHANGED
; by the 2026-07-30 loadable-module split, other than its caller: it
; used to
; be called directly from batch_readline's own EOF/I/O-error close
; paths; now it's called once, centrally, from batch_mod_teardown --
; same net effect (still runs exactly once per real batch-end), but
; from kernel-resident code instead of code that used to live inline
; in the same routine that has since moved into the module. No-op if
; batch_args_reserved isn't set.
;
; Ordering is automatically correct with no special-casing needed: by
; the time a real batch-end is ever detected (attempting to read what
; would be the NEXT line, or a GOTO that can't find its label), the
; previous command has already fully run and returned, including its
; own per-command _redir_teardown call inside that command's own
; run_loop iteration -- so this reservation, made before any per-line
; reservation for this batch ever could be, is always released after
; it, LIFO, for free.
;
; Args:    none
; Returns: nothing
; Modifies: RC, RF
; ----------------------------------------------------------------
            proc    _batch_args_release

            mov     rf, batch_args_reserved
            ldn     rf
            lbz     bar_done            ; nothing reserved: no-op
            ldi     0
            str     rf                  ; clear the flag

            ldi     high BATCH_ARGS_RESERVE_LEN
            phi     rc
            ldi     low BATCH_ARGS_RESERVE_LEN
            plo     rc
            call    _himem_release

bar_done:
            rtn

            endp

;------------------------------------------------------------------
; Batch-dispatch scratch data (2026-07-30, extended 2026-07-31 for
; Phase 2 relocation) -- the "is a batch active" flag and the module's
; own runtime location, both cross-proc within this file (see
; CLAUDE.md gotcha #6).
;------------------------------------------------------------------
            proc    _batch_dispatch_data

batch_mod_active:       db      0   ; 0 = no batch active (the module
                                    ; is never touched); nonzero = a
                                    ; batch is active, the module is
                                    ; currently resident at
                                    ; batch_mod_base
batch_mod_base:         dw      0   ; the module's actual (page-
                                    ; aligned) load address, as
                                    ; returned by mod_load -- only
                                    ; meaningful while batch_mod_active
                                    ; is set
batch_mod_reserve_size: dw      0   ; the himem reservation size
                                    ; mod_load returned, which must be
                                    ; passed back to mod_release
                                    ; unchanged (see lib/modload.asm)

                public  batch_mod_active
                public  batch_mod_base
                public  batch_mod_reserve_size

            endp

;------------------------------------------------------------------
; %0-%9 batch-argument substitution scratch data -- UNCHANGED by the
; 2026-07-30 loadable-module split (batch_fcb/batch_iobuf/
; batch_scratch/brl_count/batch_goto_label all moved to
; kernel/batch_mod.asm instead).
;------------------------------------------------------------------
            proc    _batch_data

batch_args_reserved: db 0          ; set only while a %0-%9 himem
                                    ; reservation is currently active --
                                    ; unrelated to kernel/redir.asm's
                                    ; own redir_stack_reserved, which
                                    ; tracks a separate, possibly-
                                    ; simultaneous reservation through
                                    ; the same shared _himem_reserve/
                                    ; _himem_release mechanism
                                    ; (kernel/glob.asm's own
                                    ; glob_stack_reserved used to be a
                                    ; third such flag, before that
                                    ; whole file was removed as dead
                                    ; code -- see kernel_api.inc's own
                                    ; removal note)
batch_args_empty:    db 0          ; a fixed, always-valid empty-string
                                    ; constant -- kernel_batch_args_getarg
                                    ; points here for an out-of-range
                                    ; (but still in-batch) index, never
                                    ; at an unpopulated BATCH_ARGV slot

                public  batch_args_reserved
                public  batch_args_empty

            endp
