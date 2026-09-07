;
; loader_data.asm - volatile (RAM-resident) data for loader.asm
;
; Split out of loader.asm for the split memory model (volatile RAM data at
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
; Loader scratch data
;
; prog_fcb/prog_iobuf: this kernel's own dedicated, permanently
; resident FCB + 512-byte I/O buffer, used only for loading program
; binaries (see prog_run's own comment on why it can't use a
; program-supplied FCB the way ordinary file I/O does) -- referenced
; directly (RD = prog_fcb) by every file_* call involved in loading,
; no separate handle needed. prun_argv/prun_argc are prog_run's own
; stash for the caller's argv pointer/argc across the load sequence
; (see its own comment).
;------------------------------------------------------------------
            proc    _loader_data

prog_fcb:       ds      FCB_LEN
prog_iobuf:     ds      SECTOR_SIZE
prog_size:      dw      0           ; bytes actually loaded (for mem_base calc)
prun_argv:      dw      0           ; prog_run's own argv-pointer stash
prun_argc:      dw      0           ; prog_run's own argc stash
saved_sp:       dw      0           ; kernel's R2 across _prog_exec_now's call

                public  prog_fcb
                public  prog_iobuf
                public  prog_size
                public  prun_argv
                public  prun_argc
                public  saved_sp

            endp
