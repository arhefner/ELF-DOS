;
; redir_data.asm - volatile (RAM-resident) data for redir.asm
;
; Split out of redir.asm for the split memory model (volatile RAM data at
; $0100, non-volatile ROM-able code at NVK_BASE). Every symbol here is
; already reached through extrn/public by its owning module, so moving
; the proc between files changes nothing about how it is referenced --
; only where the linker places it.
;
; Do NOT move these back inline: the linker lays procs out sequentially
; in command-line/source order, so a data proc sharing a .prg with code
; would land in the ROM region with that code.
;

#include    include/opcodes.def
#include    include/kernel.inc


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
                                    ; to kernel/batch.asm's own
                                    ; batch_args_reserved, which tracks
                                    ; a separate, possibly-simultaneous
                                    ; reservation through the same
                                    ; shared mechanism
redir_scratch:          db      0   ; shared 1-byte I/O scratch for
                                    ; _type_to_file/_read_from_file
                                    ; (never in concurrent use -- this
                                    ; kernel is single-threaded)

redir_ocount:           db      0   ; bytes waiting in redir_obuf
redir_obuf:              ds      REDIR_OBUF_LEN ; redirected output,
                                    ; written to the file a buffer at a
                                    ; time rather than a byte at a time
                                    ; (see _type_to_file)

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

                public  redir_out_active
                public  redir_out_handle
                public  redir_out_null
                public  redir_in_active
                public  redir_in_handle
                public  redir_in_null
                public  redir_stack_reserved
                public  redir_scratch
                public  himem_scratch
                public  redir_ocount
                public  redir_obuf

            endp
