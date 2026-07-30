;
; batch.asm - kernel-resident batch-script dispatcher, plus %0-%9
; batch-argument substitution (unaffected by the split below)
;
; REDESIGNED 2026-07-30 (loadable batch module, phase 1): the actual
; line-reading/GOTO-scanning logic (what used to live directly in this
; file as batch_start/batch_readline/batch_goto) moved out into
; kernel/batch_mod.asm, a standalone, separately-built module that
; lands on disk as /bin/batch.mod and is loaded fresh into RAM at a
; FIXED address (BATCHMOD_BASE, $D000, include/batchmod.inc) every
; single time K_BATCH_START runs. See kernel/batch_mod.asm's own
; header comment for the full design and PHASE 1 vs PHASE 2 scoping
; (this only works on a machine with enough real RAM above
; BATCHMOD_BASE -- test-machine-only for now, not for release).
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

            extrn   file_stat
            extrn   file_open
            extrn   file_read
            extrn   file_close

; cross-file references into kernel/loader.asm: prog_fcb/prog_iobuf,
; reused here rather than declaring a second, dedicated FCB+iobuf pair
; -- batch_mod_load's own file_stat/file_open/file_read/file_close
; sequence always runs strictly BEFORE prog_run would next use these
; for loading an ordinary program (K_BATCH_START is called either at
; boot, before run_loop has ever called prog_run at all, or from
; progs/shell.asm's own is_batch:, itself only reachable while the
; shell is running -- and prog_run's own _prog_finish_load already
; closes prog_fcb's handle before ever jumping into the shell's own
; entry point, so it's provably idle both times). Saves 544 bytes of
; kernel-resident data (FCB_LEN+SECTOR_SIZE) versus a second pair.
; prog_iobuf doubles as file_stat's own DIRENT_LEN-sized result buffer
; too (512 bytes is plenty of room for a 139-byte result) -- read
; before file_open ever needs the same buffer for its real purpose,
; same "borrow an idle buffer for a strictly-earlier, non-overlapping
; use" pattern already established elsewhere in this project (e.g.
; dir_create/dir_remove's own borrowing of dir_buf).
            extrn   prog_fcb
            extrn   prog_iobuf

; cross-file references into kernel/redir.asm -- the same shared
; himem-adjacent primitives kernel/glob.asm already reuses too.
; _himem_reserve/_himem_release themselves are only used by
; kernel_batch_args_reserve/_release below (unchanged) -- the module's
; own memory is NOT taken from that shared pool at all (its address is
; a fixed constant, not a dynamic reservation), but the bounds-check
; arithmetic in batch_mod_load below deliberately mirrors
; _himem_reserve's own SEX-protected SM/SMB comparison idiom exactly,
; reusing its scratch word too, since this is the same class of
; mem_top-adjacent computation this project has been burned on before.
            extrn   _himem_reserve
            extrn   _himem_release
            extrn   mem_top
            extrn   himem_scratch

; same-file cross-proc data references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   batch_mod_active
            extrn   batch_mod_saved_memtop
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
                                        ; WITHOUT ever touching
                                        ; BATCHMOD_BASE -- a batch is
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
                                        ; module fresh into
                                        ; BATCHMOD_BASE, clamping
                                        ; mem_top; on DF=1 nothing was
                                        ; changed at all
            lbdf    bst_reject

            ; module is now resident -- call its own batch_start entry
            ; (via the fixed header offset table) with the caller's
            ; original path argument
            mov     rf, bst_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = path (restored)
            call    BATCHMOD_BASE+MOD_START_OFF
            lbdf    bst_mod_open_failed ; the .bat file itself
                                        ; couldn't be opened -- unwind
                                        ; the mem_top clamp; nothing
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
; batch_mod_load: (re)load the batch module fresh from /bin/batch.mod
; into BATCHMOD_BASE, clamping mem_top to protect it for the duration
; a batch is active. Does NOT call into the module -- batch_start
; above does that once this returns DF=0.
;
; Refuses cleanly (mem_top left COMPLETELY UNCHANGED) rather than
; clamping to a smaller value and proceeding anyway, if the module
; wouldn't entirely fit at or below the CURRENT mem_top -- anything at
; or above BATCHMOD_BASE right now, under the OLD mem_top, is
; legitimately claimed by something else (a redirect/glob/%N
; reservation active for the very command line that's invoking this
; .bat file) and must not be overwritten.
;
; Args:    none
; Returns: DF = 0 on success (module loaded and validated,
;          BATCHMOD_BASE onward now holds its real content, mem_top
;          clamped to BATCHMOD_MEMTOP_CLAMP, the real prior value
;          saved in batch_mod_saved_memtop); DF = 1 on any failure
;          (module file missing, wrong size read back, bad magic, or
;          not enough RAM currently free above BATCHMOD_BASE).
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_mod_load

            ; prog_iobuf temporarily doubles as file_stat's own
            ; DIRENT_LEN-sized result buffer here -- see this proc's
            ; own header comment on why that's safe (strictly before
            ; file_open below ever needs the same buffer for its real
            ; purpose)
            mov     rf, batchmod_path
            mov     rd, prog_iobuf
            call    file_stat
            lbdf    bml_fail            ; /bin/batch.mod itself is
                                        ; missing

            ; real_size = DIRENT_SIZE (4 bytes, big-endian). Only the
            ; low 16 bits matter -- a batch module is nowhere near
            ; 64K -- but the high word must be EXACTLY zero for a real
            ; module; checked explicitly rather than assumed, so a
            ; wildly-wrong file on this path is rejected cleanly
            ; instead of silently truncated.
            mov     rf, prog_iobuf
            add16   rf, DIRENT_SIZE
            ldn     rf
            lbnz    bml_fail
            inc     rf
            ldn     rf
            lbnz    bml_fail
            inc     rf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = real_size (low word)

            mov     rf, batchmod_size
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; batchmod_size = real_size --
                                        ; stashed to memory, needed
                                        ; again below after several
                                        ; more calls

            ; needed_top = (BATCHMOD_BASE-1) + real_size -- immediate-
            ; constant add16 (not register-register), gotcha #18
            ; doesn't apply
            mov     rd, r8
            add16   rd, BATCHMOD_MEMTOP_CLAMP  ; RD = needed_top

            mov     rf, mem_top
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = mem_top (current, real)

            ; refuse unless mem_top >= needed_top -- SEX-protected SM,
            ; mirroring _himem_reserve's own hardware-proven idiom
            ; exactly (kernel/redir.asm): subtrahend (needed_top)
            ; staged first via str, minuend (mem_top) loaded right
            ; before sm/smb. DF=0 (borrow) means mem_top < needed_top.
            mov     ra, himem_scratch
            sex     ra
            glo     rd
            str     ra
            glo     r9
            sm
            ghi     rd
            str     ra
            ghi     r9
            smb
            sex     r2                  ; restore X = R2 -- everything
                                        ; else in this codebase assumes
                                        ; X is always R2
            lbnf    bml_fail            ; DF=0: mem_top < needed_top --
                                        ; not enough room, refuse,
                                        ; nothing changed yet

            ; safe to proceed -- save the REAL current mem_top before
            ; touching it
            mov     rf, batch_mod_saved_memtop
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, mem_top
            ldi     high BATCHMOD_MEMTOP_CLAMP
            str     rf
            inc     rf
            ldi     low BATCHMOD_MEMTOP_CLAMP
            str     rf

            ; open + read the module's real bytes into BATCHMOD_BASE --
            ; prog_iobuf now reused for its own REAL purpose (file_open's
            ; RA argument), safe since batchmod_size was already
            ; stashed to memory well before this point and nothing
            ; still needs prog_iobuf's earlier stat-scratch content
            mov     rf, batchmod_path
            mov     rd, prog_fcb
            mov     ra, prog_iobuf
            ldi     0                   ; mode = read
            call    file_open
            lbdf    bml_unclamp_fail    ; open failing right after a
                                        ; successful stat shouldn't
                                        ; normally happen, but there's
                                        ; no sane response if it does

            mov     rd, prog_fcb
            mov     rf, BATCHMOD_BASE
            mov     rb, batchmod_size
            lda     rb
            phi     rc
            ldn     rb
            plo     rc                  ; RC = real_size
            call    file_read           ; RC = bytes actually read,
                                        ; DF = 0/1
            lbdf    bml_close_unclamp_fail

            ; confirm the FULL file was read -- a short read means
            ; something is wrong (truncated/corrupt module, or it
            ; somehow changed size between the stat and the read)
            mov     rb, batchmod_size
            lda     rb
            str     r2
            ghi     rc
            xor
            lbnz    bml_close_unclamp_fail
            ldn     rb
            str     r2
            glo     rc
            xor
            lbnz    bml_close_unclamp_fail

            mov     rd, prog_fcb
            call    file_close

            ; validate the magic -- catches loading a garbage/wrong
            ; file cheaply, before ever calling into it
            mov     rf, BATCHMOD_BASE
            ldn     rf
            xri     'B'
            lbnz    bml_unclamp_fail
            inc     rf
            ldn     rf
            xri     'M'
            lbnz    bml_unclamp_fail
            inc     rf
            ldn     rf
            xri     'D'
            lbnz    bml_unclamp_fail

            clc
            rtn

bml_close_unclamp_fail:
            mov     rd, prog_fcb
            call    file_close

bml_unclamp_fail:
            call    batch_mod_unclamp

bml_fail:
            stc
            rtn

batchmod_path:      db      "/bin/batch.mod",0
batchmod_size:      dw      0

            endp

; ----------------------------------------------------------------
; batch_mod_unclamp: restore mem_top from batch_mod_saved_memtop.
; Args:    none
; Returns: nothing
; Modifies: RD, RF
; ----------------------------------------------------------------
            proc    batch_mod_unclamp

            mov     rf, batch_mod_saved_memtop
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, mem_top
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
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
            lbz     brl_disp_inactive   ; no batch active: DF=1,
                                        ; BATCHMOD_BASE never touched

            call    BATCHMOD_BASE+MOD_READLINE_OFF
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
; Args:    RF = pointer to a null-terminated label name, no leading
;          ':' -- untouched by the "is a batch active" check below,
;          so it survives correctly into the module call either way
; Returns: DF = 0/1 -- see kernel_api.inc's own K_BATCH_GOTO doc
; Modifies: everything
; ----------------------------------------------------------------
            proc    batch_goto

            mov     rd, batch_mod_active
            ldn     rd
            lbz     bg_disp_inactive

            call    BATCHMOD_BASE+MOD_GOTO_OFF
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

            endp

; ----------------------------------------------------------------
; kernel_batch_args_reserve: K_BATCH_ARGS_RESERVE's jump-table target
; -- %0-%9 batch-argument substitution (2026-07-25). UNCHANGED by the
; 2026-07-30 loadable-module split -- see kernel_api.inc's own doc
; comment for the full contract. Mirrors kernel/glob.asm's own
; kernel_glob_reserve almost exactly, reusing the same shared
; _himem_reserve/_himem_release mechanism (kernel/redir.asm) rather
; than inventing a new reservation routine -- that mechanism is
; already length-parameterized, flag-agnostic, and already proven safe
; with multiple simultaneous callers (this file's own reservation can
; be active at the same time as a per-command dual-redirect or glob
; reservation, nested, with no special handling needed here).
;
; Deliberately NOT idempotent like K_GLOB_RESERVE: this is only ever
; called once per batch, right after K_BATCH_START succeeds, and
; starting a new batch while one is already active is already rejected
; (nested batch) before this could ever be reached twice without a
; release in between.
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
; called from batch_mod_teardown above, same link unit, mirroring
; kernel/glob.asm's own _glob_release shape). UNCHANGED by the
; 2026-07-30 loadable-module split, other than its caller: it used to
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
; own per-command _redir_teardown/_glob_release calls inside that
; command's own run_loop iteration -- so this reservation, made before
; any per-line reservation for this batch ever could be, is always
; released after them, LIFO, for free.
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
; Batch-dispatch scratch data (new, 2026-07-30) -- the "is a batch
; active" flag and the saved mem_top value, both cross-proc within
; this file (see CLAUDE.md gotcha #6).
;------------------------------------------------------------------
            proc    _batch_dispatch_data

batch_mod_active:       db      0   ; 0 = no batch active (the module
                                    ; is never touched); nonzero = a
                                    ; batch is active, the module is
                                    ; currently resident at
                                    ; BATCHMOD_BASE, and mem_top is
                                    ; currently clamped
batch_mod_saved_memtop: dw      0   ; the real mem_top value from just
                                    ; before batch_mod_load's own
                                    ; clamp -- restored verbatim by
                                    ; batch_mod_unclamp, whatever it
                                    ; was (never assumed)

                public  batch_mod_active
                public  batch_mod_saved_memtop

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
                                    ; unrelated to redir_stack_reserved/
                                    ; glob_stack_reserved (kernel/
                                    ; redir.asm, kernel/glob.asm), which
                                    ; track separate, possibly-
                                    ; simultaneous reservations through
                                    ; the same shared _himem_reserve/
                                    ; _himem_release mechanism
batch_args_empty:    db 0          ; a fixed, always-valid empty-string
                                    ; constant -- kernel_batch_args_getarg
                                    ; points here for an out-of-range
                                    ; (but still in-batch) index, never
                                    ; at an unpopulated BATCH_ARGV slot

                public  batch_args_reserved
                public  batch_args_empty

            endp
