;
; glob.asm - dynamic himem reservation for the shell's glob-expansion
; buffer
;
; progs/shell.asm's own tokenizer expands `*`/`?` filename patterns
; into multiple argv entries before ever handing a command off to the
; kernel -- see progs/shell.asm's own header for the full design. The
; expanded text has to live somewhere that survives the shell being
; overwritten by whichever child program it resolves to (the same
; reason RUN_PATH/RUN_ARGV_TABLE already live below PROG_BASE rather
; than in the shell's own ordinary data section), but shouldn't cost a
; permanent slice of the tightly-watched headroom below PROG_BASE
; either. Reuses kernel/redir.asm's own dynamic himem-reservation
; mechanism (_himem_reserve/_himem_release, generalized from that
; file's original redirect-only dual-FCB case) instead of a second,
; independent copy of that logic -- see redir.asm's own module header
; for why a shared mechanism matters here, not just code reuse: this
; reservation and a resolved command's own dual-redirect reservation
; can be simultaneously active, nested.
;
; Lifetime: reserved by the shell itself (via K_GLOB_RESERVE), while
; it's tokenizing a command line that needs expansion -- BEFORE the
; resolved child is even loaded. Must stay reserved through that
; child's entire run (it may dereference argv[i] pointers into the
; buffer at any point, not just at entry), so release can't happen
; until AFTER kernel_init's run_loop (kernel/kernel.asm) sees the
; child's own prog_run call return -- _glob_release is called there,
; right alongside the already-existing _redir_teardown call, on both
; of run_loop's post-prog_run paths.
;
; K_GLOB_RESERVE IS IDEMPOTENT: progs/shell.asm's own start: loop can
; attempt several command lines within ONE shell invocation (a bad
; command loops back to start internally, never returning to the
; kernel) before it ever actually returns to run_loop -- so a second
; glob attempt within the same shell run must reuse the existing
; reservation rather than trying to shrink mem_top a second time.
;
; CONFIRMED WORKING ON HARDWARE (2026-07-22) -- see _himem_reserve's
; own header (kernel/redir.asm) for the full incident/redesign
; history: the original design here relied on _himem_reserve/
; _himem_release physically relocating the hardware stack, which
; proved fundamentally broken for a reservation whose lifetime spans a
; call-depth unwind back to a shallower point (exactly this file's own
; case). The current design never touches R2 at all -- the stack lives
; permanently in a fixed margin at the top of RAM (STACK_RESERVE_LEN,
; kernel.inc), and this file's own reservation is just a mem_top
; adjustment, address recomputed as mem_top+1 on demand.
;

#include    include/opcodes.def
#include    include/kernel.inc

            extrn   _himem_reserve
            extrn   _himem_release
            extrn   mem_top

; same-file cross-proc data reference (required even within the same
; file -- see CLAUDE.md gotcha #6)
            extrn   glob_stack_reserved

; ----------------------------------------------------------------
; kernel_glob_reserve: K_GLOB_RESERVE's jump-table target. Called by
; progs/shell.asm only when its own pre-scan finds at least one argv
; token that actually needs glob expansion -- an ordinary command
; never reaches this at all.
;
; Args:    none
; Returns: DF = 0 on success, RD = this reservation's base address
;          (mem_top + 1, recomputed fresh -- never stashed separately,
;          matching _himem_reserve/_himem_release's own convention).
;          DF = 1 if there isn't enough RAM headroom (nothing changed;
;          the caller should abort the whole command line rather than
;          attempt a half-expanded one).
; Modifies: RC, RD, RF
; ----------------------------------------------------------------
            proc    kernel_glob_reserve

            mov     rf, glob_stack_reserved
            ldn     rf
            lbz     kgr_first_reserve   ; not yet active: do the real
                                        ; work below

            ; already active (a prior attempt within the same shell
            ; invocation already reserved it) -- just hand back the
            ; current address, no relocation
            lbr     kgr_addr

kgr_first_reserve:
            ldi     high GLOB_BUF_LEN
            phi     rc
            ldi     low GLOB_BUF_LEN
            plo     rc
            call    _himem_reserve
            lbdf    kgr_fail

            mov     rf, glob_stack_reserved
            ldi     $FF
            str     rf

kgr_addr:
            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; RD = mem_top + 1
            clc
            rtn

kgr_fail:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _glob_release: kernel-internal only (no jump-table slot -- called
; directly from run_loop, same link unit). No-op if
; glob_stack_reserved isn't set.
;
; MUST run AFTER kernel/redir.asm's own _redir_teardown in run_loop --
; a resolved command's own dual-redirect reservation, if any, nests
; INSIDE this one (reserved later, during that command's own prog_run
; call) and must be released first, so releases unwind in the same
; LIFO order the reservations were made in.
;
; Args:    none
; Returns: nothing
; Modifies: RC, RF
; ----------------------------------------------------------------
            proc    _glob_release

            mov     rf, glob_stack_reserved
            ldn     rf
            lbz     gr_done             ; nothing reserved: no-op
            ldi     0
            str     rf                  ; clear the flag

            ldi     high GLOB_BUF_LEN
            phi     rc
            ldi     low GLOB_BUF_LEN
            plo     rc
            call    _himem_release

gr_done:
            rtn

            endp

;------------------------------------------------------------------
; Glob scratch data
;------------------------------------------------------------------
            proc    _glob_data

glob_stack_reserved:    db      0   ; set only while THIS reservation
                                    ; is active -- unrelated to
                                    ; kernel/redir.asm's own
                                    ; redir_stack_reserved, which
                                    ; tracks a separate, possibly-
                                    ; simultaneous reservation through
                                    ; the same shared _himem_reserve/
                                    ; _himem_release mechanism

            public  glob_stack_reserved

            endp
