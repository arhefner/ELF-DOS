;
; batch_data.asm - volatile (RAM-resident) data for batch.asm
;
; Split out of batch.asm for the split memory model (volatile RAM data at
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
