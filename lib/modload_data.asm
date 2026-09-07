;
; modload_data.asm - volatile (RAM-resident) data for modload.asm
;
; Split out of modload.asm for the split memory model (volatile RAM data at
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
#include    include/modformat.inc


;------------------------------------------------------------------
; Shared data
;------------------------------------------------------------------
            proc    _modload_data

ml_fcb_ptr:         dw      0           ; caller-supplied FCB pointer,
                                        ; reloaded fresh at every
                                        ; K_FILE_* call site (nothing
                                        ; survives the intervening
                                        ; calls) -- NOT an owned FCB;
                                        ; see this file's own header
                                        ; comment for why
ml_header:          ds      MOD_HEADER_LEN
ml_code_size:       dw      0
ml_body_size:       dw      0
ml_base:            dw      0
ml_fixup_count:     dw      0
ml_fixup_entry:     dw      0
ml_scratch:         db      0

                public  ml_fcb_ptr
                public  ml_header
                public  ml_code_size
                public  ml_body_size
                public  ml_base
                public  ml_fixup_count
                public  ml_fixup_entry
                public  ml_scratch

            endp
