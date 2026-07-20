;
; redir.asm - I/O redirection (>, >>, <)
;
; The shell's tokenizer (progs/shell.asm) recognizes `>`/`>>`/`<` and
; writes the target filename (a pointer into LINE_BUF, plus an append
; flag for `>>`) into RUN_REDIR_OUT/RUN_REDIR_OUT_APPEND/RUN_REDIR_IN
; (see include/kernel.inc's own comment on these) instead of an
; ordinary argv entry. kernel_init's run_loop (kernel/kernel.asm) reads
; those relay slots and calls _redir_setup right before running the
; resolved command, and _redir_teardown right after -- see each
; routine's own header below.
;
; Redirection itself is made transparent to every existing and future
; program by rewriting K_TYPE/K_MSG/K_INMSG/K_READ/K_INPUTL's own
; jump-table targets (kernel/kernel.asm) to the dispatchers below,
; instead of the bare BIOS passthroughs they used to be -- each checks
; whether redirection is active and, if not, falls straight through to
; the original BIOS call with no added overhead. No new jump-table
; slots, no calling-convention changes: a program that already calls
; K_TYPE/K_MSG/etc gets redirect support automatically.
;
; MEMORY COST, BY DESIGN (the user's own proposal, 2026-07-16): output-
; only or input-only redirection -- overwhelmingly the common cases --
; cost ZERO permanent kernel-resident bytes, by reusing
; kernel/loader.asm's prog_fcb/prog_iobuf (provably idle for the
; child's entire run -- prog_run's own _prog_finish_load closes
; prog_fcb's handle before _prog_exec_now ever jumps to the child's
; entry point). Only the rare case of redirecting BOTH output and
; input on the same command line needs a second, simultaneously-open
; FCB+iobuf pair -- rather than a second permanent 544-byte
; allocation, that pair is carved dynamically out of the top of RAM by
; relocating the hardware stack (R2) and mem_top down by
; REDIR_RESERVE_LEN bytes for the duration of that one command, then
; reversed in _redir_teardown. See _redir_reserve/_redir_release below
; for the mechanism, and CLAUDE.md for the full design writeup.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; REDIR_RESERVE_LEN: size of the dynamically-reserved second FCB+iobuf
; pair, only ever carved out for the rare dual-redirect case. Both
; terms are plain absolute equ constants, so this expression is fully
; resolved at assemble time -- no relocation involved.
REDIR_RESERVE_LEN: equ  FCB_LEN + SECTOR_SIZE

            extrn   file_open
            extrn   file_read
            extrn   file_write
            extrn   file_close
            extrn   prog_fcb
            extrn   prog_iobuf
            extrn   mem_top
            extrn   mem_base

; same-file cross-proc routine references (required even within the
; same file -- see CLAUDE.md gotcha #6)
            extrn   _redir_reserve
            extrn   _redir_release
            extrn   _is_nul_device

; same-file cross-proc data references (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   redir_out_active
            extrn   redir_out_handle
            extrn   redir_out_null
            extrn   redir_in_active
            extrn   redir_in_handle
            extrn   redir_in_null
            extrn   redir_stack_reserved
            extrn   redir_scratch
            extrn   kim_start
            extrn   kim_resume
            extrn   kim_ptr
            extrn   kim_remaining
            extrn   kir_buf
            extrn   kir_max
            extrn   kir_count

; ----------------------------------------------------------------
; _redir_reserve: relocate the hardware stack (R2) down by
; REDIR_RESERVE_LEN bytes and reduce mem_top to match, freeing that
; much RAM at the (old) top of RAM for a second FCB+iobuf pair -- used
; only for the rare case of a single command redirecting BOTH output
; and input at once (see the module header; the common single-
; direction case reuses prog_fcb/prog_iobuf instead, at no extra RAM
; cost). The freed region's address is simply the new (reduced)
; mem_top + 1 -- callers recompute it on demand rather than it being
; stashed separately.
;
; Copies however many bytes are currently on the stack (mem_top - R2,
; computed fresh here, never assumed) from their current locations
; down to REDIR_RESERVE_LEN-lower locations, then adjusts R2 to match
; -- a plain byte-copy loop with no calls of its own, so nothing can
; grow the stack out from under the byte count computed at the top of
; this routine. Assumes the source/destination ranges don't overlap,
; i.e. the stack in use here is under REDIR_RESERVE_LEN (544) bytes
; deep -- true by a wide margin this shallow into the call chain
; (kernel_init -> run_loop -> prog_run -> _redir_setup ->
; _redir_reserve). Also assumes nothing else can push onto the stack
; asynchronously during the copy (no interrupt-driven activity during
; normal kernel/program execution on this hardware, per the project's
; own established BIOS conventions elsewhere) -- flagged here since
; it's the one assumption this routine can't itself verify.
;
; Also republishes the reduced mem_top at LOADER_ARGS+2 -- this now
; runs from inside prog_run (see kernel/loader.asm), AFTER
; _prog_finish_load has already published the OLD, un-reduced mem_top
; there for the child to read, so without this a dual-redirected
; child's own heap code would see a stale, too-high ceiling and could
; wander into the space just reserved for the second FCB.
;
; Args:    none
; Returns: DF = 0 on success (mem_top/R2 both reduced,
;          redir_stack_reserved set), DF = 1 if there isn't enough
;          headroom above mem_base to safely reserve the space
;          (nothing is changed in that case)
; Modifies: R7, R8, R9, RB, RD, RF
; ----------------------------------------------------------------
            proc    _redir_reserve

            mov     rf, mem_top
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top

            mov     r9, r2              ; R9 = current stack pointer

            ; sanity check: new_mem_top = mem_top - RESERVE must stay
            ; above mem_base
            mov     rf, mem_base
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = mem_base

            mov     r7, r8
            sub16   r7, REDIR_RESERVE_LEN ; R7 = new_mem_top
            mov     rd, r7
            sub16   rd, rb              ; RD = new_mem_top - mem_base,
                                        ; DF=1 if new_mem_top >= mem_base
            lbnf    rsv_fail            ; not enough headroom

            ; stack_used = mem_top - R2
            mov     rd, r8
            sub16   rd, r9

            ; copy stack_used bytes from [R9+1 .. mem_top] down to
            ; [R9+1-RESERVE .. mem_top-RESERVE]
            mov     rf, r9
            inc     rf                  ; RF = lowest used stack byte
            mov     rb, rf
            sub16   rb, REDIR_RESERVE_LEN ; RB = matching destination

rsv_copy:
            glo     rd
            lbnz    rsv_copy_have
            ghi     rd
            lbz     rsv_copy_done       ; stack_used bytes copied
rsv_copy_have:
            ldn     rf
            str     rb
            inc     rf
            inc     rb
            sub16   rd, 1
            lbr     rsv_copy

rsv_copy_done:
            mov     rf, r2
            sub16   rf, REDIR_RESERVE_LEN
            mov     r2, rf              ; R2 -= RESERVE

            mov     rf, mem_top
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; mem_top = new_mem_top

            ; also republish the reduced value at LOADER_ARGS+2 --
            ; _prog_finish_load already wrote the OLD mem_top there
            ; before this routine ever runs (this now runs from inside
            ; prog_run, after the child's binary has loaded but before
            ; it starts executing), so without this the child's own
            ; heap code would see a stale, too-high ceiling and could
            ; wander into the space just reserved for the second FCB
            mov     rf, LOADER_ARGS+2
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

            mov     rf, redir_stack_reserved
            ldi     $FF
            str     rf

            clc
            rtn

rsv_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _redir_release: reverse _redir_reserve -- copies the stack's current
; contents back up by REDIR_RESERVE_LEN bytes, restores R2, and
; restores mem_top (by adding the same fixed amount back). A no-op if
; redir_stack_reserved isn't set. Must run AFTER both redirect FCBs
; have already been closed (see _redir_teardown) -- the dynamically-
; reserved FCB/iobuf live in exactly the memory this routine is about
; to hand back to the stack, so file_close needs to run first while
; that memory still holds a valid FCB.
; Args:    none
; Returns: nothing
; Modifies: R7, R8, R9, RB, RD, RF
; ----------------------------------------------------------------
            proc    _redir_release

            mov     rf, redir_stack_reserved
            ldn     rf
            lbz     rel_done            ; nothing was reserved: no-op
            ldi     0
            str     rf                  ; clear the flag

            mov     rf, mem_top
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = current (reduced) mem_top

            mov     r9, r2              ; R9 = current (reduced) stack
                                        ; pointer

            mov     rd, r8
            sub16   rd, r9              ; RD = stack_used

            ; copy stack_used bytes from [R9+1 .. mem_top] UP to
            ; [R9+1+RESERVE .. mem_top+RESERVE] -- walk from the
            ; highest used address down to the lowest, the mirror
            ; image of _redir_reserve's own ascending copy
            mov     rf, r8              ; RF = mem_top (highest used
                                        ; source address)
            mov     rb, rf
            add16   rb, REDIR_RESERVE_LEN ; RB = matching destination

rel_copy:
            glo     rd
            lbnz    rel_copy_have
            ghi     rd
            lbz     rel_copy_done
rel_copy_have:
            ldn     rf
            str     rb
            dec     rf
            dec     rb
            sub16   rd, 1
            lbr     rel_copy

rel_copy_done:
            mov     rf, r2
            add16   rf, REDIR_RESERVE_LEN
            mov     r2, rf              ; R2 += RESERVE

            mov     rf, r8
            add16   rf, REDIR_RESERVE_LEN ; RF = restored mem_top
            mov     rb, mem_top
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

rel_done:
            rtn

            endp

; ----------------------------------------------------------------
; _is_nul_device: does the string at RF spell "NUL" (case-insensitive,
; e.g. "NUL"/"nul"/"Nul"), exactly, with nothing else following?
; Matches DOS's own reserved-device-name convention -- used by
; _redir_setup to recognize `>NUL`/`<NUL` as the null device instead of
; a real filename.
; Args:    RF = pointer to a null-terminated string
; Returns: DF = 0 if it's exactly "NUL" (any case), DF = 1 otherwise
; Modifies: RF (advanced), D
; ----------------------------------------------------------------
            proc    _is_nul_device

            ldn     rf
            ani     $DF                 ; uppercase-fold (safe: only
                                        ; 'n'/'N' alias to 'N' under
                                        ; this mask, same reasoning as
                                        ; the shell's own drive-letter
                                        ; check)
            xri     'N'
            lbnz    ind_no
            inc     rf
            ldn     rf
            ani     $DF
            xri     'U'
            lbnz    ind_no
            inc     rf
            ldn     rf
            ani     $DF
            xri     'L'
            lbnz    ind_no
            inc     rf
            ldn     rf
            lbnz    ind_no              ; must be NUL-terminated right
                                        ; after "NUL" -- not a prefix
                                        ; match like "NULfoo"
            clc
            rtn

ind_no:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _redir_setup: open whichever of RUN_REDIR_OUT/RUN_REDIR_IN the
; shell's tokenizer set, right before run_loop runs the resolved
; command. A no-op (DF=0) if neither is set -- the common case, only
; two quick zero-checks. Output (if requested) always opens through
; prog_fcb/prog_iobuf, UNLESS the target is the null device ("NUL",
; case-insensitive -- see _is_nul_device), in which case no real FCB
; is touched at all: redir_out_null is set instead, and the 3 output
; dispatchers (_redir_type/_redir_msg/_redir_inmsg) discard the write
; and report success without ever calling file_write. Input (if
; requested) also uses prog_fcb/prog_iobuf UNLESS output is ALSO using
; it (a real, non-NUL output redirect), in which case input uses a
; dynamically-reserved second FCB+iobuf instead (see _redir_reserve)
; -- an output redirect to NUL does NOT count as "using prog_fcb" for
; this decision, since it never touches it. Input redirected from NUL
; also skips any real FCB and sets redir_in_null instead; the 2 input
; dispatchers (_redir_read/_redir_inputl) short-circuit straight to
; their own existing EOF handling -- matching MS-DOS's own "reading
; from NUL returns EOF immediately" convention -- rather than needing
; any new EOF logic of their own.
; Args:    none
; Returns: DF = 0 on success, DF = 1 if any requested open failed (bad
;          path, disk full, the input file doesn't exist, or --
;          extremely rare -- not enough RAM headroom for a dual
;          redirect's second buffer); nothing is left open/reserved in
;          that case, the caller should report an error and skip
;          running the child entirely (fail the whole command, not a
;          half-working redirect)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    _redir_setup

            ; --- output redirect, if requested -- always via
            ; prog_fcb/prog_iobuf regardless of whether input is also
            ; requested ---
            mov     rf, RUN_REDIR_OUT
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = RUN_REDIR_OUT's value
            ghi     r9
            lbnz    rs_out_open
            glo     r9
            lbnz    rs_out_open
            lbr     rs_in               ; RUN_REDIR_OUT == 0: nothing
                                        ; to open for output

rs_out_open:
            mov     rf, r9
            call    _is_nul_device
            lbnf    rs_out_isnull

            mov     rf, r9
            mov     rd, prog_fcb
            mov     ra, prog_iobuf
            mov     rb, RUN_REDIR_OUT_APPEND
            ldn     rb
            lbz     rs_out_trunc
            ldi     2                   ; append
            lbr     rs_out_domode
rs_out_trunc:
            ldi     1                   ; write (create/truncate)
rs_out_domode:
            call    file_open           ; D = handle, DF = 0/1
            lbdf    rs_err
            plo     r9                  ; stash handle (mov below
                                        ; clobbers D -- gotcha #4)
            mov     rf, redir_out_handle
            glo     r9
            str     rf
            mov     rf, redir_out_active
            ldi     $FF
            str     rf
            lbr     rs_in

rs_out_isnull:
            mov     rf, redir_out_active
            ldi     $FF
            str     rf
            mov     rf, redir_out_null
            ldi     $FF
            str     rf
                                        ; falls through to rs_in

rs_in:
            ; --- input redirect, if requested ---
            mov     rf, RUN_REDIR_IN
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    rs_in_open
            glo     r9
            lbnz    rs_in_open
            lbr     rs_ok               ; RUN_REDIR_IN == 0: done

rs_in_open:
            mov     rf, r9
            call    _is_nul_device
            lbnf    rs_in_isnull        ; DF is consumed immediately,
                                        ; not held across anything that
                                        ; might clobber it

            ; R9 = target filename pointer. Decide which FCB/iobuf to
            ; use: prog_fcb/prog_iobuf if output isn't ALSO using a
            ; real FCB -- either no output redirect at all, or an
            ; output redirect to NUL (which never touches prog_fcb/
            ; prog_iobuf either) -- or a dynamically-reserved second
            ; pair if output IS using prog_fcb/prog_iobuf (a real,
            ; non-NUL output redirect: the true dual-redirect case).
            mov     rb, redir_out_active
            ldn     rb
            lbz     rs_in_single        ; output not redirected at all

            mov     rb, redir_out_null
            ldn     rb
            lbnz    rs_in_single        ; output redirected, but to
                                        ; NUL: prog_fcb still free

            lbr     rs_in_dual

rs_in_single:
            mov     rf, r9
            mov     rd, prog_fcb
            mov     ra, prog_iobuf
            ldi     0                   ; read
            call    file_open
            lbdf    rs_err
            plo     r9
            mov     rf, redir_in_handle
            glo     r9
            str     rf
            mov     rf, redir_in_active
            ldi     $FF
            str     rf
            lbr     rs_ok

rs_in_dual:
            call    _redir_reserve
            lbdf    rs_err_maybe_close_out ; not enough headroom

            mov     rf, mem_top
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            inc     r9                  ; R9 = mem_top+1 = dynamic
                                        ; FCB base (mem_top already
                                        ; reflects the reservation
                                        ; just made)
            mov     rd, r9              ; RD = dynamic FCB
            mov     ra, r9
            add16   ra, FCB_LEN         ; RA = dynamic iobuf, right
                                        ; after the FCB

            ; re-read the target filename fresh from memory rather
            ; than trusting a register to have survived the
            ; _redir_reserve call just made (it uses RB internally --
            ; gotcha #10)
            mov     rf, RUN_REDIR_IN
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8

            ldi     0                   ; read
            call    file_open
            lbdf    rs_err_undo_reserve
            plo     r9
            mov     rf, redir_in_handle
            glo     r9
            str     rf
            mov     rf, redir_in_active
            ldi     $FF
            str     rf
            lbr     rs_ok

rs_in_isnull:
            mov     rf, redir_in_active
            ldi     $FF
            str     rf
            mov     rf, redir_in_null
            ldi     $FF
            str     rf
            lbr     rs_ok

rs_err_undo_reserve:
            call    _redir_release

rs_err_maybe_close_out:
            ; close output if it was opened above, so a failure here
            ; never leaves anything half-open -- but only if it's a
            ; real FCB (NUL output never opened one, so file_close-ing
            ; redir_out_handle here would operate on a bogus/stale
            ; index)
            mov     rf, redir_out_active
            ldn     rf
            lbz     rs_err

            mov     rf, redir_out_null
            ldn     rf
            lbnz    rs_err_out_clear    ; NUL: nothing to close

            mov     ra, redir_out_handle
            ldn     ra
            call    file_close

rs_err_out_clear:
            mov     rf, redir_out_active
            ldi     0
            str     rf
            mov     rf, redir_out_null
            ldi     0
            str     rf

rs_err:
            stc
            rtn

rs_ok:
            clc
            rtn

            endp

; ----------------------------------------------------------------
; _redir_teardown: close whichever of the output/input redirect FCBs
; _redir_setup opened, clear both active flags (and both null-device
; flags -- always, so neither can leak stale into the next command's
; own _redir_setup), and reverse any dual-redirect stack reservation --
; called unconditionally after prog_run returns (success or failure),
; so a misbehaving child can never leave redirection (or a shrunk
; stack/mem_top) silently active for the NEXT command. A NUL-device
; redirect never opened a real FCB, so file_close is skipped for it
; (calling it on redir_out_handle/redir_in_handle's leftover/bogus
; value would be a real bug). Closing must happen before
; _redir_release, since the dynamically-reserved FCB/iobuf (if any)
; live in exactly the memory _redir_release is about to hand back to
; the stack.
; Args:    none
; Returns: nothing
; Modifies: R7, R8, R9, RA, RB, RD, RF
; ----------------------------------------------------------------
            proc    _redir_teardown

            mov     rf, redir_out_active
            ldn     rf
            lbz     rt_in

            mov     rf, redir_out_null
            ldn     rf
            lbnz    rt_out_clear        ; NUL: nothing was opened,
                                        ; don't file_close a bogus
                                        ; handle

            mov     ra, redir_out_handle
            ldn     ra
            call    file_close

rt_out_clear:
            mov     rf, redir_out_active
            ldi     0
            str     rf
            mov     rf, redir_out_null
            ldi     0
            str     rf

rt_in:
            mov     rf, redir_in_active
            ldn     rf
            lbz     rt_release

            mov     rf, redir_in_null
            ldn     rf
            lbnz    rt_in_clear         ; NUL: nothing was opened

            mov     ra, redir_in_handle
            ldn     ra
            call    file_close

rt_in_clear:
            mov     rf, redir_in_active
            ldi     0
            str     rf
            mov     rf, redir_in_null
            ldi     0
            str     rf

rt_release:
            call    _redir_release      ; no-op if nothing was
                                        ; reserved this round
            rtn

            endp

; ----------------------------------------------------------------
; _redir_type: redirect-aware replacement for the bare "lbr f_type"
; K_TYPE used to be.
;
; MUST preserve RF/RC across itself, whether or not it ends up
; redirecting -- hardware-found bug (2026-07-16): the first version of
; this routine used RF/RC as ordinary scratch and returned with them
; clobbered. progs/type.asm's own hot loop (its read_loop/print_loop)
; depends on RF (the read cursor into type_buf, advanced via "lda rf"
; immediately before each "call K_TYPE" and read again next iteration)
; and RC (the remaining-byte counter) surviving the call -- confirmed
; as the one exception to "assume clobbered" by progs/hexdump.asm's
; own comment ("RF/RC across K_TYPE is the one exception, proven by
; progs/type.asm's own hot loop"). The old bare "lbr f_type" never
; touched them; this dispatcher must not either, from the caller's
; perspective, regardless of which internal path it takes. Broke
; TYPE's output on the very first hardware round (truncated to 1-2
; garbage characters, no trailing newline) -- R7/RA are preserved too
; out of the same caution, since nothing establishes they're safe to
; clobber either.
;
; Args:    D = character to print
; Returns: whatever f_type itself returns (unexamined by every
;          existing caller)
; ----------------------------------------------------------------
            proc    _redir_type

            plo     r7                  ; stash the incoming character
                                        ; FIRST -- every mov/push below
                                        ; clobbers D (gotcha #4)

            push    rf
            push    rc
            push    ra

            mov     rf, redir_out_active
            ldn     rf
            lbz     rty_console

            mov     rf, redir_out_null
            ldn     rf
            lbnz    rty_discard         ; NUL device: discard the
                                        ; byte, report success

            mov     rf, redir_scratch   ; RF = &redir_scratch -- also
                                        ; file_write's own source
                                        ; buffer argument below, no
                                        ; need to reload it
            glo     r7                  ; D = the character (reloaded
                                        ; from R7, stashed above)
            str     rf                  ; redir_scratch = character

            ldi     0
            phi     rc
            ldi     1
            plo     rc                  ; RC = 1 (one byte)
            mov     ra, redir_out_handle
            ldn     ra                  ; D = handle (loaded last --
                                        ; every mov above clobbers D)
            call    file_write

            pop     ra
            pop     rc
            pop     rf
            rtn

rty_discard:
            pop     ra
            pop     rc
            pop     rf
            rtn

rty_console:
            pop     ra
            pop     rc
            pop     rf
            glo     r7                  ; D = the character (restored)
            lbr     f_type

            endp

; ----------------------------------------------------------------
; _redir_msg: redirect-aware replacement for "lbr f_msg". Computes the
; string's length once and issues a single file_write for the whole
; thing when redirected -- cheaper than _redir_type's byte-at-a-time
; path, and correctness-equivalent.
;
; Preserves RF/RC/RA across itself (same caution as _redir_type,
; hardware-found bug 2026-07-16) -- R9 is never touched at all here, so
; it survives naturally, matching the confirmed "R9 survives f_msg"
; contract (gotcha #8).
;
; Args:    RF = pointer to a null-terminated string
; Returns: whatever f_msg itself returns (unexamined by every existing
;          caller)
; ----------------------------------------------------------------
            proc    _redir_msg

            mov     r7, rf              ; R7 = the string pointer

            push    rf
            push    rc
            push    ra

            mov     rf, redir_out_active
            ldn     rf
            lbz     rmsg_console

            mov     rf, redir_out_null
            ldn     rf
            lbnz    rmsg_discard        ; NUL device: discard the
                                        ; whole string, report success

            ; compute the string's length into RC
            mov     rf, r7              ; RF = scan cursor
            ldi     0
            phi     rc
            plo     rc                  ; RC = 0 (length so far)
rmsg_scan:
            ldn     rf
            lbz     rmsg_scandone
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbnz    rmsg_scan
            ghi     rc
            adi     1
            phi     rc
            lbr     rmsg_scan

rmsg_scandone:
            mov     rf, r7              ; RF = the string, back to its
                                        ; start (file_write's own
                                        ; source buffer argument)
            mov     ra, redir_out_handle
            ldn     ra                  ; D = handle (loaded last)
            call    file_write

            pop     ra
            pop     rc
            pop     rf
            rtn

rmsg_discard:
            pop     ra
            pop     rc
            pop     rf
            rtn

rmsg_console:
            pop     ra
            pop     rc
            pop     rf
            mov     rf, r7              ; RF restored
            lbr     f_msg

            endp

; ----------------------------------------------------------------
; _redir_inmsg: redirect-aware replacement for the real BIOS inmsg
; routine:
;
;   inmsglp:    sep   scall
;               dw    type
;   inmsg:      lda   r6
;               bnz   inmsglp
;               sep   sret
;
; Reached via a plain lbr from kernel.asm's k_inmsg jump-table entry,
; NOT a nested call -- critical, since R6 is set up by the ORIGINAL
; caller's own "call K_INMSG" (the outer SCRT call mechanism sets R6 to
; point at the inline text immediately following that call), and a
; nested call here would reset it before this routine ever got a
; chance to read it.
;
; Scans the whole inline message first (a pure lda r6/lbnz loop, no
; calls at all during the scan, so nothing can clobber R6 mid-scan),
; stashing R6's starting value and its final (correct post-NUL resume)
; value to memory. Then dispatches: one file_write call if redirected
; (cheaper than the original byte-at-a-time shape), or the original
; byte-at-a-time f_type loop if not, matching today's console timing
; exactly -- and finally reloads R6 from the stashed resume value
; before returning, rather than assuming it survives the dispatch
; call(s) (gotcha #8/#10's standing "don't trust a register across an
; unaudited call" discipline).
;
; A single inline message is assumed to fit in 255 bytes (an
; extremely safe assumption for a compile-time string literal in this
; project) -- kim_remaining below is a single byte.
;
; Also preserves RF/RC/R9/RA/RD across itself, same caution as
; _redir_type/_redir_msg (hardware-found bug 2026-07-16) -- R9
; specifically is confirmed to survive f_inmsg (gotcha #8), and this
; routine already uses R9 as its own internal scratch (kim_start's
; value), so without this it would break that contract for any real
; caller relying on it, exactly like the RF/RC bug did for K_TYPE. RD
; protection was a SECOND, later hardware-found bug (also 2026-07-16,
; found chasing ECHO's redirected-append corruption): the redirected
; path below calls file_write, which documents RD as scratch, and
; progs/echo.asm's loop depends on RD (holding its own loop index)
; surviving a "call K_INMSG" for its separator -- silent when not
; redirected, since the console path here never touches RD either.
;
; Args:    none (R6 already points at the caller's inline text)
; Returns: matches the real BIOS inmsg's own contract (resumes past
;          the inline text via R6)
; ----------------------------------------------------------------
            proc    _redir_inmsg

            push    rf
            push    rc
            push    r9
            push    ra
            push    rd                  ; BUG FIX (hardware-found,
                                        ; 2026-07-16): RD was NOT
                                        ; protected here, but the
                                        ; redirected path below calls
                                        ; file_write, whose own header
                                        ; documents RD as scratch
                                        ; ("R7/R8/R9/RD are scratch,
                                        ; recomputed fresh each
                                        ; iteration"). progs/echo.asm's
                                        ; loop calls K_INMSG for its
                                        ; separator, then immediately
                                        ; computes &argv[echo_i] via
                                        ; "shl16 rd", relying on RD
                                        ; (holding echo_i) surviving
                                        ; that call -- exactly like
                                        ; K_TYPE's RF/RC exception
                                        ; (see _redir_type's own
                                        ; header). Silent when NOT
                                        ; redirected (the kim_console
                                        ; path below never touches RD),
                                        ; only breaking once real
                                        ; hardware exercised a multi-
                                        ; argument ECHO through actual
                                        ; redirection: the first
                                        ; argument (no separator/no
                                        ; K_INMSG call before it) always
                                        ; printed correctly, every
                                        ; later one resolved to the
                                        ; SAME wrong address once RD
                                        ; came back clobbered by
                                        ; file_write's own internal use
                                        ; of it.

            mov     rf, kim_start
            ghi     r6
            str     rf
            inc     rf
            glo     r6
            str     rf                  ; kim_start = R6 (scan start)

kim_scan:
            lda     r6                  ; D = next inline byte, R6++
            lbnz    kim_scan            ; not the NUL yet: keep going

            mov     rf, kim_resume
            ghi     r6
            str     rf
            inc     rf
            glo     r6
            str     rf                  ; kim_resume = R6 (now one
                                        ; past the NUL -- the correct
                                        ; resume point)

            ; length = kim_resume - kim_start - 1 (exclude the NUL)
            mov     rf, kim_resume
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = kim_resume
            mov     rf, kim_start
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = kim_start
            sub16   rc, r9              ; RC = kim_resume - kim_start
            sub16   rc, 1               ; RC -= 1 (exclude the NUL)

            mov     rf, redir_out_active
            ldn     rf
            lbz     kim_console

            mov     rf, redir_out_null
            ldn     rf
            lbnz    kim_restore         ; NUL device: discard, skip
                                        ; straight to R6 restoration --
                                        ; needed regardless of output
                                        ; disposition

            ; --- redirected: one file_write call for the whole run ---
            mov     rf, r9              ; RF = kim_start (still in R9)
            mov     ra, redir_out_handle
            ldn     ra                  ; D = handle (loaded last)
            call    file_write
            lbr     kim_restore

kim_console:
            ; --- not redirected: print each byte via f_type, matching
            ; the original byte-at-a-time console behavior/timing.
            ; kim_ptr/kim_remaining are memory-resident and reloaded
            ; fresh around every f_type call -- its own clobber
            ; footprint isn't confirmed (gotcha #8) ---
            mov     rf, kim_ptr
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; kim_ptr = kim_start

            mov     rf, kim_remaining
            glo     rc
            str     rf                  ; kim_remaining = length (low
                                        ; byte -- see the header note
                                        ; on the 255-byte assumption)

kim_print_loop:
            mov     rf, kim_remaining
            ldn     rf
            lbz     kim_restore         ; nothing left: done

            mov     rf, kim_ptr
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = kim_ptr
            mov     rf, r9
            ldn     rf                  ; D = the byte to print
            call    f_type

            ; kim_ptr += 1 (high byte stored first at kim_ptr, low
            ; byte at kim_ptr+1 -- same convention as every other
            ; word in this codebase)
            mov     rf, kim_ptr
            inc     rf                  ; RF -> kim_ptr's low byte
            ldn     rf
            adi     1
            str     rf
            lbnf    kim_ptr_hidone      ; no carry: done
            dec     rf                  ; RF -> kim_ptr's high byte
            ldn     rf
            adi     1
            str     rf
kim_ptr_hidone:
            mov     rf, kim_remaining
            ldn     rf
            smi     1
            str     rf
            lbr     kim_print_loop

kim_restore:
            mov     rf, kim_resume
            lda     rf
            phi     r6
            ldn     rf
            plo     r6                  ; R6 = kim_resume (restored
                                        ; explicitly, not assumed to
                                        ; survive the dispatch call(s)
                                        ; made above)

            pop     rd
            pop     ra
            pop     r9
            pop     rc
            pop     rf
            rtn

            endp

; ----------------------------------------------------------------
; _redir_read: redirect-aware replacement for "lbr f_read". Reads one
; byte from the input redirect file when active; returns D=0 (NUL) at
; EOF or on a read error -- every current K_READ caller (COPY's Y/N
; overwrite prompt) already treats "not Y" as cancel, so this degrades
; safely to "no." Every subsequent call after EOF keeps returning 0
; (file_read's own "0 bytes transferred" result naturally repeats past
; EOF, so no extra state is needed here to remember EOF was hit).
; f_read's own confirmed contract is "D = char in, no other side
; effects" (see CLAUDE.md's COPY overwrite-prompt writeup) -- the
; strongest of the five, so this dispatcher preserves RF/RC/RA
; unconditionally (same hardware-found-bug caution as the other four).
;
; Args:    none
; Returns: D = the character read (0 at EOF/error), matching f_read's
;          own "D = char in" contract
; ----------------------------------------------------------------
            proc    _redir_read

            push    rf
            push    rc
            push    ra

            mov     rf, redir_in_active
            ldn     rf
            lbz     rrd_console

            mov     rf, redir_in_null
            ldn     rf
            lbnz    rrd_eof             ; NUL device: EOF immediately,
                                        ; matching MS-DOS's own
                                        ; convention

            mov     rf, redir_scratch
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     ra, redir_in_handle
            ldn     ra                  ; D = handle (loaded last)
            call    file_read           ; RC = bytes actually read
            lbdf    rrd_eof             ; I/O error: treat like EOF
            glo     rc
            lbz     rrd_eof             ; 0 bytes: EOF

            mov     rf, redir_scratch
            ldn     rf
            plo     r7                  ; stash the result -- the pops
                                        ; below clobber D
            pop     ra
            pop     rc
            pop     rf
            glo     r7
            rtn

rrd_eof:
            pop     ra
            pop     rc
            pop     rf
            ldi     0
            rtn

rrd_console:
            pop     ra
            pop     rc
            pop     rf
            lbr     f_read

            endp

; ----------------------------------------------------------------
; _redir_inputl: redirect-aware replacement for "lbr f_inputl". Reads
; from the input redirect file into RF, stopping at a newline (CR/LF
; handling mirrors kernel/batch.asm's batch_readline, which already
; solves exactly this "read a line from an open file, strip line
; endings" problem), NUL-terminated, no console echo. Does NOT close
; the input FCB (that's _redir_teardown's job, since a program might
; legitimately call this again later in the same run).
;
; A single line is assumed to fit in 255 bytes (kir_max/kir_count
; below are single bytes, matching this codebase's own K_INPUTL
; callers -- the shell's prompt read and edlin's own three, all
; 127-byte buffers); a caller passing a length over 255 has it
; silently capped at 255.
;
; Preserves RF/RC/RA/R8/R9/RB across itself, same hardware-found-bug
; caution as the other four dispatchers (2026-07-16) -- nothing
; establishes any of these are safe for a caller to lose across
; K_INPUTL, so none of them are trusted to be fair game.
;
; DF NOW HAS A REAL, DEFINED MEANING (2026-07-17, gap found by the
; user testing `edlin file <NUL`): DF=0 means RF's buffer holds a real
; line (possibly empty -- a blank Enter at a live console, or a
; genuinely blank line in a redirected file); DF=1 means the
; redirected input source is EXHAUSTED (immediate EOF from `<NUL`, or
; a real file that's been fully read) -- RF's buffer is still written
; as an empty string in that case too, but DF now lets a caller
; distinguish "really nothing left" from "a normal blank line," which
; nothing before this could. Before this fix, EVERY caller ignored DF
; (there was nothing meaningful to check), so redefining it here is
; safe for existing behavior. Non-redirected (console) input ALWAYS
; reports DF=0 -- forced explicitly after a real `call f_inputl`
; (not the previous tail `lbr`), since the real BIOS routine's own DF
; behavior isn't confirmed and a live keyboard structurally can never
; hit "redirected EOF." A caller that wants EOF-aware behavior (e.g.
; edlin, to avoid spinning forever re-reading nothing from `<NUL`)
; must now check DF after K_INPUTL; a caller that doesn't (unchanged
; from before) still works exactly as it always has.
;
; Args:    RF = destination buffer, RC = max length
; Returns: DF = 0 (real line, RF's buffer valid) or 1 (EOF, RF's
;          buffer is an empty string)
; ----------------------------------------------------------------
            proc    _redir_inputl

            mov     r7, rf              ; R7 = destination buffer
                                        ; (unprotected scratch, same
                                        ; convention as the other
                                        ; dispatchers)

            push    rf
            push    rc
            push    ra
            push    r8
            push    r9
            push    rb

            mov     rf, redir_in_active
            ldn     rf
            lbz     kir_console

            mov     rf, kir_buf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; kir_buf = R7 (dest buffer)
                                        ; -- needed by kir_term below
                                        ; regardless of which path
                                        ; follows

            mov     rf, redir_in_null
            ldn     rf
            lbnz    kir_null_eof        ; NUL device: EOF immediately
                                        ; -- an empty line, exactly
                                        ; what kir_term already writes
                                        ; when kir_count is 0

            mov     rf, kir_max
            glo     rc
            str     rf                  ; kir_max = RC's low byte

            mov     rf, kir_count
            ldi     0
            str     rf                  ; kir_count = 0

kir_loop:
            ; stop with room for the NUL terminator: branch when
            ; kir_count >= kir_max - 1 (same shape as
            ; batch_readline's own "smi 126 / lbdf brl_term" bound
            ; check, just with the limit read from memory instead of
            ; a compile-time constant)
            mov     rf, kir_max
            ldn     rf
            smi     1
            str     r2                  ; [R2] = kir_max - 1 (one-shot
                                        ; scratch-via-stack-pointer,
                                        ; same idiom rtc.asm's
                                        ; _pack_fat_datetime already
                                        ; uses -- X is R2 by default,
                                        ; per gotcha #7)
            mov     rf, kir_count
            ldn     rf                  ; D = kir_count
            sm                          ; D = kir_count - (kir_max-1),
                                        ; DF=1 if no borrow
            lbdf    kir_line_done       ; buffer full -- real content,
                                        ; not EOF

            mov     rf, redir_scratch
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     ra, redir_in_handle
            ldn     ra                  ; D = handle (loaded last)
            call    file_read
            lbdf    kir_eof             ; I/O error: treat like EOF

            glo     rc
            lbz     kir_eof             ; 0 bytes: EOF

            mov     rf, redir_scratch
            ldn     rf
            xri     13                  ; CR? skip silently (handles
                                        ; both bare-LF and CRLF, same
                                        ; as batch_readline)
            lbz     kir_loop

            mov     rf, redir_scratch
            ldn     rf                  ; D = the byte (reload -- xri
                                        ; above clobbered it)
            xri     10                  ; LF? line complete
            lbz     kir_line_done       ; real content, not EOF

            ; append the byte at kir_buf[kir_count]
            ldi     0
            phi     r9
            mov     rb, kir_count
            ldn     rb
            plo     r9                  ; R9 = kir_count (widened to
                                        ; a word for add16 below)
            mov     rf, kir_buf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = kir_buf's base address
            mov     rf, r8
            add16   rf, r9              ; RF = kir_buf + kir_count
            mov     rb, redir_scratch
            ldn     rb                  ; D = the byte (reload --
                                        ; add16 clobbered it)
            str     rf
            mov     rb, kir_count
            ldn     rb
            adi     1
            str     rb                  ; kir_count += 1
            lbr     kir_loop

kir_line_done:
            ; a real line was read (possibly empty, e.g. two
            ; consecutive newlines in the file) -- NOT end-of-file.
            ; R7 is free scratch from this point on (its only earlier
            ; use, staging the destination buffer into kir_buf, is
            ; long done)
            ldi     0
            plo     r7                  ; R7.0 = 0: not EOF
            lbr     kir_term

kir_null_eof:
            mov     rf, kir_count
            ldi     0
            str     rf
            ldi     1
            plo     r7                  ; R7.0 = 1: true EOF (NUL
                                        ; device)
            lbr     kir_term

kir_eof:
            ; real file_read EOF/error. If any characters were
            ; accumulated THIS call, return them as a final line --
            ; real content, not EOF (same "partial final line" idea as
            ; batch_readline). Only a call that reads ZERO new bytes
            ; before hitting EOF (kir_count still 0 -- either the very
            ; first call against an already-empty/exhausted source, or
            ; a repeat call after a prior partial-final-line call
            ; already consumed everything) is reported as true EOF.
            ; file_read's own "0 bytes" result is confirmed to repeat
            ; indefinitely past real EOF (see _redir_read's own header
            ; note), so this can't loop forever re-accumulating stale
            ; partial content.
            mov     rf, kir_count
            ldn     rf
            lbnz    kir_line_done       ; nonzero: partial final line,
                                        ; treat as real content
            ldi     1
            plo     r7                  ; R7.0 = 1: true EOF, nothing
                                        ; read this call
            lbr     kir_term

kir_term:
            ldi     0
            phi     r9
            mov     rb, kir_count
            ldn     rb
            plo     r9
            mov     rf, kir_buf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            add16   rf, r9
            ldi     0
            str     rf                  ; null-terminate

            glo     r7
            lbnz    kir_term_eof
            clc                         ; DF = 0: real line
            lbr     kir_term_ret
kir_term_eof:
            stc                         ; DF = 1: true EOF
kir_term_ret:
            pop     rb
            pop     r9
            pop     r8
            pop     ra
            pop     rc
            pop     rf
            rtn

kir_console:
            pop     rb
            pop     r9
            pop     r8
            pop     ra
            pop     rc
            pop     rf
            call    f_inputl            ; a real call, not a tail lbr
                                        ; -- needed so DF can be forced
                                        ; below regardless of whatever
                                        ; f_inputl itself leaves it as
                                        ; (its own DF contract isn't
                                        ; confirmed anywhere in this
                                        ; codebase -- gotcha #8).
                                        ; f_inputl has no R6-based
                                        ; inline-message mechanism like
                                        ; f_inmsg does, so a real
                                        ; call/return pair here is
                                        ; completely safe.
            clc                         ; DF = 0: console input can
                                        ; never be "redirected EOF" --
                                        ; every caller can now safely
                                        ; treat DF=1 as meaning ONLY
                                        ; that
            rtn

            endp

;------------------------------------------------------------------
; Redirect scratch data
;------------------------------------------------------------------
            proc    _redir_data

redir_out_active:      db      0
redir_out_handle:      db      0
redir_out_null:        db      0   ; set when the output target is the
                                    ; NUL device -- redir_out_handle is
                                    ; meaningless in that case, no real
                                    ; FCB was ever opened
redir_in_active:        db      0
redir_in_handle:        db      0
redir_in_null:          db      0   ; same as redir_out_null, input side
redir_stack_reserved:   db      0   ; set only while a dual-redirect's
                                    ; dynamic stack reservation is
                                    ; active (see _redir_reserve)
redir_scratch:          db      0   ; shared 1-byte I/O scratch for
                                    ; _redir_type/_redir_read/
                                    ; _redir_inputl (never in
                                    ; concurrent use -- this kernel is
                                    ; single-threaded)

kim_start:              dw      0   ; _redir_inmsg's own scan-start R6
                                    ; value
kim_resume:              dw      0   ; _redir_inmsg's own post-NUL
                                    ; resume R6 value
kim_ptr:                dw      0   ; _redir_inmsg's console-path
                                    ; print cursor
kim_remaining:           db      0   ; _redir_inmsg's console-path
                                    ; remaining-byte countdown

kir_buf:                 dw      0   ; _redir_inputl's destination
                                    ; buffer
kir_max:                 db      0   ; _redir_inputl's max length (low
                                    ; byte of the caller's RC)
kir_count:               db      0   ; _redir_inputl's running byte
                                    ; count

                public  redir_out_active
                public  redir_out_handle
                public  redir_out_null
                public  redir_in_active
                public  redir_in_handle
                public  redir_in_null
                public  redir_stack_reserved
                public  redir_scratch
                public  kim_start
                public  kim_resume
                public  kim_ptr
                public  kim_remaining
                public  kir_buf
                public  kir_max
                public  kir_count

            endp
