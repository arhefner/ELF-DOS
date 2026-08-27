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
; program via kernel/kernel.asm's own jump table, but the exact
; mechanism differs by slot as of PHASE 2 (self-modifying K_TYPE/K_READ
; vectors):
;
;   - K_TYPE/K_READ's own slot operand is repatched DIRECTLY by
;     _redir_setup/_redir_teardown below -- not a runtime flag check on
;     every call, a genuinely different target routine ("LBR
;     <console/file/discard routine>") depending on what the CURRENT
;     command's redirection needs. Boot-time default (boot/krnboot.asm)
;     is a bare "LBR <real console routine>"; every "call K_TYPE"/
;     "call K_READ" throughout the whole OS -- kernel-internal or
;     program -- automatically does the right thing with zero added
;     branching in the common (not redirected) case.
;   - K_MSG/K_INMSG's own slots are NEVER repatched -- they're
;     ordinary, permanent entries pointing at trivial byte-loops that
;     simply "call K_TYPE" per character (see _redir_msg/_redir_inmsg
;     below), inheriting whatever K_TYPE's own slot currently does with
;     no redirect-awareness of their own.
;   - K_INPUTL is untouched by Phase 2 entirely -- its own dispatcher
;     (_redir_inputl below) still checks redir_in_active/redir_in_null
;     directly, exactly as before.
;
; No new jump-table slots, no calling-convention changes for K_TYPE/
; K_READ/K_MSG/K_INMSG/K_INPUTL: a program that already calls any of
; these gets redirect support automatically.
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
; allocation, that pair is carved dynamically out of RAM by reducing
; mem_top by REDIR_RESERVE_LEN bytes for the duration of that one
; command, then reversed in _redir_teardown. See _himem_reserve/
; _himem_release below for the mechanism, and CLAUDE.md for the full
; design writeup.
;
; _himem_reserve/_himem_release (GENERALIZED 2026-07-21, from this
; file's original redirect-only _redir_reserve/_redir_release; fully
; REDESIGNED 2026-07-22 -- see _himem_reserve's own header for the
; incident that forced it): the same mem_top-adjustment mechanism is
; now also used by kernel/glob.asm's dynamic glob-expansion-buffer
; reservation, so it's a length-parameterized (RC), flag-agnostic PURE
; MECHANISM -- each caller (this file's own _redir_setup/
; _redir_teardown, and kernel/glob.asm) tracks its own "is my
; reservation active" flag and passes its own length. This matters for
; correctness, not just code reuse: a resolved command's own dual-
; redirect reservation can be active NESTED INSIDE an already-active
; glob reservation (glob reserves while the shell runs and writes
; expanded argv text; a dual-redirect reservation for the CHILD
; command that shell resolved to happens later, inside that child's
; own prog_run call) -- both must adjust mem_top relative to whatever
; it CURRENTLY is, never an assumed baseline, which only works
; reliably if both go through one shared routine. The hardware stack
; (R2) is NEVER touched by either routine -- it lives permanently in
; STACK_RESERVE_LEN bytes at the true top of RAM (kernel.inc, set once
; at boot), completely independent of mem_top or of how many
; reservations are currently stacked up beneath it.

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
            extrn   _himem_reserve
            extrn   _himem_release
            extrn   _is_nul_device
            extrn   _redir_close_out_if_open
            extrn   _patch_io_vector
            extrn   _type_to_file
            extrn   _type_discard
            extrn   _read_from_file
            extrn   _read_eof_immediate

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
            extrn   himem_scratch
            extrn   kir_buf
            extrn   kir_max
            extrn   kir_count

; ----------------------------------------------------------------
; _himem_reserve: reduce mem_top by RC bytes, freeing that much RAM at
; the (old) top of the program-visible heap for the caller's own use.
; The freed region's address is simply the new (reduced) mem_top + 1
; -- callers recompute it on demand rather than it being returned/
; stashed separately.
;
; REDESIGNED 2026-07-22, after the original stack-relocation approach
; (copy the hardware stack's live content down by RC bytes, adjust R2
; to match) was found, via real hardware testing, to be fundamentally
; incompatible with a reservation whose lifetime spans a call-depth
; unwind back to a SHALLOWER point than where it was made -- exactly
; glob's own case (reserved deep inside the shell's own call chain;
; released only after the shell fully returns AND a whole separate
; child program has run and returned). R2 naturally rises back toward
; the true top of RAM as calls unwind, and on real hardware it landed
; ABOVE the temporarily-reduced mem_top by release time, wrapping the
; stack_used computation into a huge value and corrupting memory well
; beyond the copy loop's intended range. See CLAUDE.md's own writeup
; of this incident for the full diagnostic trail.
;
; The user's own fix (2026-07-22): stop moving the stack at all. A
; fixed STACK_RESERVE_LEN-byte margin at the true top of RAM is
; permanently reserved for the hardware stack at boot (kernel_init,
; kernel/kernel.asm) and NEVER adjusted again -- R2 always operates in
; exactly that fixed region, completely independent of mem_top or of
; how deep the call chain happens to be at any given moment. Every
; himem buffer (this file's own dual-redirect FCB pair, kernel/
; glob.asm's expansion buffer) simply lives BENEATH the current
; mem_top, addressed via mem_top+1 -- multiple simultaneous
; reservations stack up underneath each other for free, and nothing
; here ever reads or writes R2.
;
; PURE MECHANISM -- no flag of its own (see this file's module header
; for why: kernel/redir.asm's own dual-redirect reservation and
; kernel/glob.asm's glob-buffer reservation can be simultaneously
; active). Each caller tracks its own active flag and is responsible
; for not calling this a second time on top of an already-active
; reservation of its own.
;
; Also republishes the reduced mem_top at LOADER_ARGS+2 -- keeps
; whichever program is about to run (or is currently running, for
; kernel/glob.asm's case) from seeing a stale, too-high heap ceiling
; that could wander into the space just reserved.
;
; Args:    RC = bytes to reserve
; Returns: DF = 0 on success (mem_top reduced), DF = 1 if there isn't
;          enough headroom above mem_base to safely reserve the space
;          (nothing is changed in that case)
; Modifies: R8, RA, RB, RD, RF
; ----------------------------------------------------------------
            proc    _himem_reserve

            mov     rf, mem_top
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top

            ; sanity check computed against mem_base first, so a
            ; rejected reservation touches nothing
            mov     rf, mem_base
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = mem_base

            ; R8 -= RC = new_mem_top. Not done via the register-
            ; register SUB16 macro -- gotcha #18 -- purely out of
            ; caution left over from the incident above; R2 is never
            ; live-relevant to this computation in the new design, but
            ; the SEX-protected scratch path costs almost nothing and
            ; removes any residual doubt.
            mov     ra, himem_scratch
            sex     ra
            glo     rc
            str     ra
            glo     r8
            sm
            plo     r8
            ghi     rc
            str     ra
            ghi     r8
            smb
            phi     r8
            sex     r2                  ; restore X = R2 -- everything
                                        ; else in this codebase assumes
                                        ; X is always R2
                                        ; R8 = new_mem_top

            ; new_mem_top - mem_base -- SEX-protected, same reasoning
            mov     rd, r8
            mov     ra, himem_scratch
            sex     ra
            glo     rb
            str     ra
            glo     rd
            sm
            plo     rd
            ghi     rb
            str     ra
            ghi     rd
            smb
            phi     rd
            sex     r2
            lbnf    rsv_fail            ; DF=0 (borrow): new_mem_top <
                                        ; mem_base -- not enough
                                        ; headroom

            mov     rf, mem_top
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; mem_top = new_mem_top

            ; also republish the reduced value at LOADER_ARGS+2 -- see
            ; this routine's own header for why
            mov     rf, LOADER_ARGS+2
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            clc
            rtn

rsv_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _himem_release: reverse _himem_reserve -- restores mem_top by adding
; RC back. See _himem_reserve's own header for the full 2026-07-22
; redesign history (no stack relocation, no R2 involvement at all).
;
; PURE MECHANISM -- no flag of its own, same reasoning as
; _himem_reserve's own header. The caller must only call this when it
; knows ITS OWN reservation is genuinely active (passing the same RC
; value originally passed to _himem_reserve for it), and -- for
; kernel/redir.asm's own dual-redirect case -- must make sure anything
; living in the reserved region (the dynamically-reserved second FCB)
; is already closed first, since this routine has no way to know
; what's living there.
; Args:    RC = bytes to release
; Returns: nothing
; Modifies: R8, RA, RB, RF
; ----------------------------------------------------------------
            proc    _himem_release

            mov     rf, mem_top
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = current (reduced) mem_top

            ; R8 += RC -- SEX-protected, same caution as
            ; _himem_reserve's own header explains
            mov     ra, himem_scratch
            sex     ra
            glo     rc
            str     ra
            glo     r8
            add
            plo     r8
            ghi     rc
            str     ra
            ghi     r8
            adc
            phi     r8
            sex     r2                  ; R8 = restored mem_top

            mov     rf, mem_top
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            rtn

            endp

; ----------------------------------------------------------------
; kernel_himem_reserve/kernel_himem_release: K_HIMEM_RESERVE/
; K_HIMEM_RELEASE's own jump-table targets (2026-07-31) -- thin,
; general-purpose passthroughs to _himem_reserve/_himem_release above,
; exposed to ordinary programs for the first time. Unlike
; kernel_glob_reserve (a fixed-size, idempotent, single-purpose
; wrapper for exactly one caller), these are PURE MECHANISM, same
; shape as the routines they wrap: no flag, caller-supplied size,
; caller tracks its own reservation state. First real consumer:
; lib/modload.asm's mod_load, which needs a page-aligned region of a
; size that varies per module -- see that file's own header for why a
; general-purpose reservation (not another single-purpose wrapper) is
; the right shape here.
; ----------------------------------------------------------------
; kernel_himem_reserve
; Args:    RC = bytes to reserve
; Returns: DF = 0 on success, RD = this reservation's base address
;          (mem_top + 1, recomputed fresh, matching _himem_reserve's
;          own callers elsewhere in this file). DF = 1 if there isn't
;          enough headroom (nothing changed).
; Modifies: R8, RA, RB, RD, RF
; ----------------------------------------------------------------
            proc    kernel_himem_reserve

            call    _himem_reserve
            lbdf    khr_fail

            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; RD = mem_top + 1
            clc
            rtn

khr_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; kernel_himem_release
; Args:    RC = bytes to release (must match a caller's own prior
;          successful kernel_himem_reserve call)
; Returns: nothing
; Modifies: R8, RA, RB, RF
; ----------------------------------------------------------------
            proc    kernel_himem_release

            call    _himem_release
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
; _redir_close_out_if_open: close redir_out_handle (via file_close)
; if it's genuinely open (redir_out_active set AND redir_out_null
; clear -- a NUL redirect never opened a real FCB, so file_close-ing
; it would operate on a bogus/stale index), then unconditionally
; clear both redir_out_active and redir_out_null. Factored out after
; finding this exact 18-line sequence duplicated verbatim at both of
; its call sites (_redir_setup's own error-unwind path, and
; _redir_teardown's own output half) -- unlike those two sites'
; original code, this version always clears both flags at the end
; rather than skipping the clear entirely when redir_out_active was
; already 0: harmless (an already-0 write is a no-op) and marginally
; safer (redir_out_null can never carry stale value forward from a
; previous command once this returns, matching this project's own
; standing "always reset shared state up front" preference).
;
; Args:    none
; Returns: nothing
; Modifies: R7, R8, R9, RA, RD, RF
; ----------------------------------------------------------------
            proc    _redir_close_out_if_open

            mov     rf, redir_out_active
            ldn     rf
            lbz     rcoo_clear          ; not active: nothing to
                                        ; close, still clear below
                                        ; (harmless no-op if already 0)

            mov     rf, redir_out_null
            ldn     rf
            lbnz    rcoo_clear          ; NUL: nothing to close

            mov     ra, redir_out_handle
            lda     ra
            phi     rd
            ldn     ra
            plo     rd                  ; RD = the FCB pointer
            call    file_close

rcoo_clear:
            mov     rf, redir_out_active
            ldi     0
            str     rf
            mov     rf, redir_out_null
            ldi     0
            str     rf
            rtn

            endp

; ----------------------------------------------------------------
; _patch_io_vector: overwrite a K_TYPE/K_READ-shaped jump-table slot's
; own 2-byte LBR operand to point directly at a new target -- the
; actual Phase 2 self-modification primitive, shared by _redir_setup
; (patches to a file-I/O routine) and _redir_teardown (restores the
; real console routine, previously auto-detected once at boot into
; IO_TYPE_TARGET/IO_READ_TARGET -- see kernel.inc's own header comment
; on those two words for the full design).
; Args:    RF = &slot's operand (e.g. K_TYPE+1 or K_READ+1)
;          RB = new target address
; Returns: nothing
; Modifies: RF, D
; ----------------------------------------------------------------
            proc    _patch_io_vector

            ghi     rb
            str     rf
            inc     rf
            glo     rb
            str     rf
            rtn

            endp

; ----------------------------------------------------------------
; _redir_setup: open whichever of RUN_REDIR_OUT/RUN_REDIR_IN the
; shell's tokenizer set, right before run_loop runs the resolved
; command. A no-op (DF=0) if neither is set -- the common case, only
; two quick zero-checks. Output (if requested) always opens through
; prog_fcb/prog_iobuf, UNLESS the target is the null device ("NUL",
; case-insensitive -- see _is_nul_device), in which case no real FCB
; is touched at all: redir_out_null is set instead, and K_TYPE's own
; jump-table slot is repatched to _type_discard rather than
; _type_to_file (PHASE 2: K_TYPE's slot itself now encodes whether
; output is redirected at all, and to what -- see this file's own
; module header) -- either way the write is discarded and reported as
; success, without ever calling file_write. Input (if requested) also
; uses prog_fcb/prog_iobuf UNLESS output is ALSO using it (a real,
; non-NUL output redirect), in which case input uses a dynamically-
; reserved second FCB+iobuf instead (see _himem_reserve) -- an output
; redirect to NUL does NOT count as "using prog_fcb" for this decision,
; since it never touches it. Input redirected from NUL also skips any
; real FCB and repatches K_READ's own slot to _read_eof_immediate
; instead of _read_from_file -- matching MS-DOS's own "reading from
; NUL returns EOF immediately" convention -- rather than needing any
; new EOF logic of its own.
; Args:    none
; Returns: DF = 0 on success, DF = 1 if any requested open failed (bad
;          path, disk full, the input file doesn't exist, or --
;          extremely rare -- not enough RAM headroom for a dual
;          redirect's second buffer); nothing is left open/reserved,
;          and neither K_TYPE's nor K_READ's slot is repatched, in that
;          case -- the caller should report an error and skip running
;          the child entirely (fail the whole command, not a
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
            call    file_open           ; DF = 0/1 (D unspecified --
                                        ; output redirect always uses
                                        ; prog_fcb, a fixed address,
                                        ; nothing to capture from D)
            lbdf    rs_err
            mov     rf, prog_fcb        ; RF = prog_fcb's own address
            mov     rb, redir_out_handle
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; redir_out_handle = &prog_fcb
            mov     rf, redir_out_active
            ldi     $FF
            str     rf

            ; PHASE 2: repatch K_TYPE's own jump-table slot to
            ; _type_to_file -- from here on, every "call K_TYPE" (by
            ; ANY caller, kernel or program) writes straight to this
            ; redirect file with no runtime flag-check at all.
            ldi     high (K_TYPE+1)
            phi     rf
            ldi     low (K_TYPE+1)
            plo     rf                  ; RF = &K_TYPE's slot operand
            ldi     high _type_to_file
            phi     rb
            ldi     low _type_to_file
            plo     rb                  ; RB = new target
            call    _patch_io_vector
            lbr     rs_in

rs_out_isnull:
            mov     rf, redir_out_active
            ldi     $FF
            str     rf
            mov     rf, redir_out_null
            ldi     $FF
            str     rf

            ; PHASE 2: repatch K_TYPE's slot to _type_discard instead
            ldi     high (K_TYPE+1)
            phi     rf
            ldi     low (K_TYPE+1)
            plo     rf
            ldi     high _type_discard
            phi     rb
            ldi     low _type_discard
            plo     rb
            call    _patch_io_vector
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
            call    file_open           ; DF = 0/1 (D unspecified --
                                        ; prog_fcb again, nothing to
                                        ; capture)
            lbdf    rs_err
            mov     rf, prog_fcb
            mov     rb, redir_in_handle
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; redir_in_handle = &prog_fcb
            mov     rf, redir_in_active
            ldi     $FF
            str     rf

            ; PHASE 2: repatch K_READ's own jump-table slot to
            ; _read_from_file -- from here on, every "call K_READ"
            ; reads straight from this redirect file, no runtime
            ; flag-check.
            ldi     high (K_READ+1)
            phi     rf
            ldi     low (K_READ+1)
            plo     rf                  ; RF = &K_READ's slot operand
            ldi     high _read_from_file
            phi     rb
            ldi     low _read_from_file
            plo     rb                  ; RB = new target
            call    _patch_io_vector
            lbr     rs_ok

rs_in_dual:
            ldi     high REDIR_RESERVE_LEN
            phi     rc
            ldi     low REDIR_RESERVE_LEN
            plo     rc                  ; RC = length to reserve --
                                        ; _himem_reserve is now a
                                        ; shared, length-parameterized
                                        ; mechanism (see its own header)
            call    _himem_reserve
            lbdf    rs_err_maybe_close_out ; not enough headroom

            mov     rf, redir_stack_reserved
            ldi     $FF
            str     rf                  ; flag-setting now lives HERE
                                        ; (the caller), not inside the
                                        ; now flag-agnostic
                                        ; _himem_reserve

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

            ; stash the dynamic FCB's own address into redir_in_handle
            ; NOW, before R9 gets reused as scratch below by the
            ; filename reload -- unlike the fixed-prog_fcb cases above,
            ; this address is only known at runtime, so it can't be
            ; recomputed later the way "mov rf, prog_fcb" can. Safe to
            ; do before file_open even attempts the open: redir_in_handle
            ; is only ever read once redir_in_active is set, which
            ; doesn't happen until file_open actually succeeds below.
            mov     rf, redir_in_handle
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; redir_in_handle = R9 (the
                                        ; dynamic FCB address)

            ; re-read the target filename fresh from memory rather
            ; than trusting a register to have survived the
            ; _himem_reserve call just made (it uses RB internally --
            ; gotcha #10)
            mov     rf, RUN_REDIR_IN
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8

            ldi     0                   ; read
            call    file_open           ; DF = 0/1 (D unspecified)
            lbdf    rs_err_undo_reserve
            mov     rf, redir_in_active
            ldi     $FF
            str     rf

            ; PHASE 2: same K_READ slot repatch as rs_in_single above
            ldi     high (K_READ+1)
            phi     rf
            ldi     low (K_READ+1)
            plo     rf
            ldi     high _read_from_file
            phi     rb
            ldi     low _read_from_file
            plo     rb
            call    _patch_io_vector
            lbr     rs_ok

rs_in_isnull:
            mov     rf, redir_in_active
            ldi     $FF
            str     rf
            mov     rf, redir_in_null
            ldi     $FF
            str     rf

            ; PHASE 2: repatch K_READ's slot to _read_eof_immediate
            ldi     high (K_READ+1)
            phi     rf
            ldi     low (K_READ+1)
            plo     rf
            ldi     high _read_eof_immediate
            phi     rb
            ldi     low _read_eof_immediate
            plo     rb
            call    _patch_io_vector
            lbr     rs_ok

rs_err_undo_reserve:
            ; reached only after rs_in_dual's own _himem_reserve call
            ; already succeeded (redir_stack_reserved is set) and the
            ; dual-redirect's file_open then failed -- RC is reloaded
            ; fresh here rather than trusted to have survived that
            ; call (gotcha #10)
            ldi     high REDIR_RESERVE_LEN
            phi     rc
            ldi     low REDIR_RESERVE_LEN
            plo     rc
            call    _himem_release
            mov     rf, redir_stack_reserved
            ldi     0
            str     rf                  ; clear the flag ourselves --
                                        ; _himem_release no longer does

rs_err_maybe_close_out:
            ; close output if it was opened above, so a failure here
            ; never leaves anything half-open -- see
            ; _redir_close_out_if_open's own header for the real/NUL
            ; distinction
            call    _redir_close_out_if_open

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
; own _redir_setup), reverse any dual-redirect stack reservation, and
; -- PHASE 2 -- unconditionally restore K_TYPE's/K_READ's own jump-
; table slots to the real console routine, regardless of whether
; _redir_setup actually repatched either one. Called unconditionally
; after prog_run returns (success or failure), so a misbehaving child
; can never leave redirection (or a shrunk stack/mem_top, or a
; repatched console vector) silently active for the NEXT command. A
; NUL-device redirect never opened a real FCB, so file_close is skipped
; for it (calling it on redir_out_handle/redir_in_handle's leftover/
; bogus value would be a real bug). Closing must happen before
; _himem_release, since the dynamically-reserved FCB/iobuf (if any)
; live in exactly the memory _himem_release is about to hand back to
; the stack.
; Args:    none
; Returns: nothing
; Modifies: R7, R8, R9, RA, RB, RD, RF
; ----------------------------------------------------------------
            proc    _redir_teardown

            call    _redir_close_out_if_open

rt_in:
            mov     rf, redir_in_active
            ldn     rf
            lbz     rt_release

            mov     rf, redir_in_null
            ldn     rf
            lbnz    rt_in_clear         ; NUL: nothing was opened

            mov     ra, redir_in_handle
            lda     ra
            phi     rd
            ldn     ra
            plo     rd                  ; RD = the FCB pointer
            call    file_close

rt_in_clear:
            mov     rf, redir_in_active
            ldi     0
            str     rf
            mov     rf, redir_in_null
            ldi     0
            str     rf

rt_release:
            mov     rf, redir_stack_reserved
            ldn     rf
            lbz     rt_release_done     ; nothing was reserved this
                                        ; round: no-op (this check used
                                        ; to live inside _redir_release
                                        ; itself; _himem_release is now
                                        ; a flag-agnostic shared
                                        ; mechanism, see its own header)
            ldi     0
            str     rf                  ; clear the flag

            ldi     high REDIR_RESERVE_LEN
            phi     rc
            ldi     low REDIR_RESERVE_LEN
            plo     rc
            call    _himem_release

rt_release_done:
            ; PHASE 2: restore K_TYPE's/K_READ's own jump-table slots to
            ; the real console routine -- unconditionally, regardless
            ; of whether _redir_setup actually repatched either one,
            ; matching this routine's own "always reset shared state,
            ; harmless no-op otherwise" convention. IO_TYPE_TARGET/
            ; IO_READ_TARGET hold the real, boot-detected routine (see
            ; kernel.inc's own header comment on those two words).
            mov     rf, IO_TYPE_TARGET
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = the real TYPE routine
            ldi     high (K_TYPE+1)
            phi     rf
            ldi     low (K_TYPE+1)
            plo     rf
            call    _patch_io_vector

            mov     rf, IO_READ_TARGET
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = the real READ routine
            ldi     high (K_READ+1)
            phi     rf
            ldi     low (K_READ+1)
            plo     rf
            call    _patch_io_vector

            rtn

            endp

; ----------------------------------------------------------------
; _type_to_file: write one character (D) to the currently-open output
; redirect file (redir_out_handle). Reached ONLY via K_TYPE's own
; self-modified jump-table slot ($011E), while output is redirected to
; a real file -- K_TYPE's slot is repatched per command by
; _redir_setup/_redir_teardown, not checked via a runtime flag on every
; call (see this file's own module header for the full Phase 2 design).
;
; MUST preserve RF/RC/RA -- same hardware-found-bug caution as the old
; _redir_type this replaces (2026-07-16): this routine uses all three
; as its own internal scratch for the file_write call, and real callers
; (progs/type.asm's own hot loop) depend on RF/RC surviving a "call
; K_TYPE" regardless of which routine that slot currently targets.
;
; Args:    D = character to write
; Returns: whatever file_write itself returns (unexamined by every
;          existing caller, matching the old _redir_type's own contract)
; ----------------------------------------------------------------
            proc    _type_to_file

            plo     r7                  ; stash the incoming character
                                        ; FIRST -- every mov/push below
                                        ; clobbers D (gotcha #4)

            push    rf
            push    rc
            push    ra

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
            lda     ra
            phi     rd
            ldn     ra
            plo     rd                  ; RD = the FCB pointer (loaded
                                        ; via RA scratch, leaving RF/RC
                                        ; untouched)
            call    file_write

            pop     ra
            pop     rc
            pop     rf
            rtn

            endp

; ----------------------------------------------------------------
; _type_discard: discard the character in D and report success. Reached
; ONLY via K_TYPE's own self-modified slot while output is redirected
; to the NUL device. Zero scratch use -- trivially safe, no register
; protection needed at all.
; Args:    D = character (ignored)
; Returns: nothing meaningful (matching the old _redir_type's own
;          "discard, report success" NUL-device behavior)
; ----------------------------------------------------------------
            proc    _type_discard

            rtn

            endp

; ----------------------------------------------------------------
; _redir_msg: K_MSG's own jump-table target -- unlike K_TYPE/K_READ,
; this slot is NEVER self-modified (the user's own explicit choice):
; since K_TYPE's own vector now already does the right thing (console,
; file, or discard) depending on what's currently patched into it,
; K_MSG needs no redirect-awareness of its own at all -- it just
; transfers the string to K_TYPE, one byte at a time. No separate byte
; count or other bookkeeping: the loop drives entirely off RF, fetching
; and advancing it each iteration.
;
; DELIBERATE CONTRACT CHANGE from the old _redir_msg (Phase 2): RF is
; now left pointing at the string's terminating NUL when this returns,
; not preserved at its original (start-of-string) value -- confirmed
; via a repo-wide scan of every "call K_MSG" site that nothing relies
; on RF surviving unchanged (every real call site either doesn't touch
; RF again afterward, or resets it explicitly before its next use).
;
; RA is still protected (push/pop) -- the one other promise the old
; contract made that this design keeps, since nothing establishes it's
; safe to drop (mr.asm/ms.asm's own 2026-07-11 hardware finding: RA
; specifically does NOT survive repeated calls through K_TYPE/K_READ's
; jump-table slots) and the cost is one push/pop pair per call, not per
; byte. RC/R9 are not protected: neither is part of K_MSG's documented
; calling convention, and RF/RC surviving REPEATED K_TYPE calls is
; already independently proven safe (progs/type.asm's own hot loop) --
; this loop relies on that same proven property for RF, needing no
; extra protection of its own.
;
; Args:    RF = pointer to a null-terminated string
; Returns: RF left pointing at the string's terminating NUL
; ----------------------------------------------------------------
            proc    _redir_msg

            push    ra

rmsg_loop:
            ldn     rf
            lbz     rmsg_done           ; NUL: done, RF left pointing
                                        ; at it
            inc     rf                  ; advance BEFORE the call (D
                                        ; still holds the character --
                                        ; inc rf doesn't touch D)
            call    K_TYPE
            lbr     rmsg_loop

rmsg_done:
            pop     ra
            rtn

            endp

; ----------------------------------------------------------------
; _redir_inmsg: K_INMSG's own jump-table target -- unlike K_TYPE/K_READ,
; this slot is NEVER self-modified (same reasoning as _redir_msg
; above): K_TYPE's own vector already does the right thing (console,
; file, or discard), so K_INMSG just transfers each byte to K_TYPE as
; it scans:
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
; No separate byte count or resume-address bookkeeping needed anymore
; (Phase 2): "lda r6" both fetches and advances R6 in one instruction,
; so scanning to the NUL automatically leaves R6 at the correct resume
; point, with nothing further to compute or restore.
;
; Protects RF/RC/R9/RA/RD around the WHOLE scan -- not because this
; routine uses any of them as scratch anymore (R6 alone drives the
; loop now), but because K_INMSG's own EXISTING, hardware-confirmed
; caller contract already promises all five survive a "call K_INMSG"
; (progs/echo.asm's own real dependency on RD, hardware-found bug
; 2026-07-16), and nothing establishes that a repeated "call K_TYPE"
; preserves R9/RA/RD (RA specifically is confirmed NOT to, per
; mr.asm/ms.asm's 2026-07-11 hardware finding) -- so this routine still
; needs to guarantee the contract itself, regardless of what K_TYPE
; does internally to those three. RF/RC are separately proven safe
; across repeated K_TYPE calls (progs/type.asm's own hot loop) and
; aren't used as scratch here either, but are protected anyway for
; consistency with the rest of the guarantee -- the cost is one
; push/pop pair each, once per call, not once per byte.
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
            push    rd

kim_loop:
            lda     r6                  ; D = next inline byte, R6++
            lbz     kim_done            ; NUL: done, R6 already at the
                                        ; correct resume point
            call    K_TYPE
            lbr     kim_loop

kim_done:
            pop     rd
            pop     ra
            pop     r9
            pop     rc
            pop     rf
            rtn

            endp

; ----------------------------------------------------------------
; _read_from_file: read one byte from the currently-open input redirect
; file (redir_in_handle); D=0 at EOF or on an I/O error, same
; convention K_READ has always had -- every current K_READ caller
; (COPY's Y/N overwrite prompt) already treats "not Y" as cancel, so
; this degrades safely to "no." Every subsequent call after EOF keeps
; returning 0 (file_read's own "0 bytes transferred" result naturally
; repeats past EOF, so no extra state is needed here to remember EOF
; was hit). Reached ONLY via K_READ's own self-modified jump-table slot
; ($0157), while input is redirected to a real file -- see this file's
; own module header for the full Phase 2 design.
;
; f_read's own confirmed contract is "D = char in, no other side
; effects" (see CLAUDE.md's COPY overwrite-prompt writeup) -- so this
; routine preserves RF/RC/RA unconditionally too, same hardware-found-
; bug caution as _type_to_file above and the old _redir_read this
; replaces.
;
; Args:    none
; Returns: D = the character read (0 at EOF/error), matching K_READ's
;          existing, unchanged "D = char in" contract
; ----------------------------------------------------------------
            proc    _read_from_file

            push    rf
            push    rc
            push    ra

            mov     rf, redir_scratch
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     ra, redir_in_handle
            lda     ra
            phi     rd
            ldn     ra
            plo     rd                  ; RD = the FCB pointer
            call    file_read           ; RC = bytes actually read
            lbdf    rff_eof             ; I/O error: treat like EOF
            glo     rc
            lbz     rff_eof             ; 0 bytes: EOF

            mov     rf, redir_scratch
            ldn     rf
            plo     r7                  ; stash the result -- the pops
                                        ; below clobber D
            lbr     rff_popret

rff_eof:
            ldi     0
            plo     r7                  ; stash "0" the same way the
                                        ; success path stashes its real
                                        ; byte, so both can share one
                                        ; physical pop+return tail

rff_popret:
            pop     ra
            pop     rc
            pop     rf
            glo     r7
            rtn

            endp

; ----------------------------------------------------------------
; _read_eof_immediate: D=0 immediately (matching K_READ's existing EOF
; convention). Reached ONLY via K_READ's own self-modified slot while
; input is redirected to the NUL device -- matches MS-DOS's own
; "reading from NUL returns EOF immediately" convention. Zero scratch
; use -- trivially safe, no register protection needed.
; Args:    none
; Returns: D = 0
; ----------------------------------------------------------------
            proc    _read_eof_immediate

            ldi     0
            rtn

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
            lda     ra
            phi     rd
            ldn     ra
            plo     rd                  ; RD = the FCB pointer
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
            ; indefinitely past real EOF (see _read_from_file's own
            ; header note), so this can't loop forever re-accumulating
            ; stale partial content.
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
redir_out_handle:      dw      0   ; the real FCB pointer (prog_fcb, or
                                    ; the dynamically-reserved dual-
                                    ; redirect address) -- 2 bytes,
                                    ; unlike the old small-int handle,
                                    ; since it's used directly as a
                                    ; K_FILE_* argument now
redir_out_null:        db      0   ; set when the output target is the
                                    ; NUL device -- redir_out_handle is
                                    ; meaningless in that case, no real
                                    ; FCB was ever opened
redir_in_active:        db      0
redir_in_handle:        dw      0   ; same as redir_out_handle, input side
redir_in_null:          db      0   ; same as redir_out_null, input side
redir_stack_reserved:   db      0   ; set only while a dual-redirect's
                                    ; dynamic stack reservation is
                                    ; active (see _himem_reserve) --
                                    ; this file's OWN flag; unrelated
                                    ; to kernel/glob.asm's own
                                    ; glob_stack_reserved, which tracks
                                    ; a separate, possibly-simultaneous
                                    ; reservation through the same
                                    ; shared mechanism
redir_scratch:          db      0   ; shared 1-byte I/O scratch for
                                    ; _type_to_file/_read_from_file/
                                    ; _redir_inputl (never in
                                    ; concurrent use -- this kernel is
                                    ; single-threaded)

himem_scratch:           dw      0   ; scratch word used by
                                    ; _himem_reserve/_himem_release's
                                    ; SEX-protected 16-bit arithmetic
                                    ; (see either routine's own
                                    ; comments) -- kept out of M(R2)
                                    ; purely out of caution left over
                                    ; from the 2026-07-22 stack-
                                    ; relocation incident; R2 is never
                                    ; touched by either routine at all
                                    ; in the current design

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
                public  himem_scratch
                public  kir_buf
                public  kir_max
                public  kir_count

            endp
