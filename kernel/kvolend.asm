;
; kvolend.asm - end-of-volatile-region marker
;
; Must be the LAST volatile object in the link order. Its single byte
; marks where the volatile (RAM) image ends, which the build needs for
; two reasons:
;
;   - tools/split_kernel.py slices the single linked image into its
;     volatile and non-volatile halves, and needs an authoritative end
;     address rather than guessing by trimming trailing zero bytes --
;     a data proc may legitimately END in zeros (an initialized-to-zero
;     field, or a "ds" reservation), and trimming those would silently
;     truncate the image.
;
;   - a "ds" reservation emits no bytes at all (Link/02 just advances
;     its cursor), so without a real byte after them the linker's own
;     "Highest address" would stop short of the reserved space. This
;     marker forces the volatile image to span every byte it owns.
;
; kvol_end is deliberately a real, emitted byte rather than an equ:
; the whole point is to move Link/02's "highest address" watermark.
;

#include    include/opcodes.def

            proc    _kvol_end
kvol_end:   db      0
            public  kvol_end
            endp
