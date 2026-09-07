;
; path_data.asm - volatile (RAM-resident) data for path.asm
;
; Split out of path.asm for the split memory model (volatile RAM data at
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


;==================================================================
; Path resolver scratch state
;==================================================================

            proc    _path_data

path_buf:       ds      PATH_BUF_LEN    ; mutable copy of the input path
path_dirent:    ds      DIRENT_LEN      ; dir_read result buffer (private --
                                        ; not shared with file.asm's or
                                        ; a program's own buffer)
presolve_ptr:   dw      0               ; scan position: start of the next
                                        ; unprocessed component
presolve_clust: dw      0               ; parent cluster resolved so far
presolve_comp:  dw      0               ; start of the component currently
                                        ; being looked up -- dir_open/
                                        ; dir_read clobber RA, so this
                                        ; can't just live in a register
                                        ; across them
presolve_drive: db      0               ; resolved target drive (0-3) --
                                        ; kept in memory (not a register)
                                        ; across dir_open/dir_read/
                                        ; _switch_drive calls; loaded
                                        ; into RC.0 only at the final
                                        ; return
presolve_start: dw      0               ; path_buf position where real
                                        ; parsing starts -- path_buf
                                        ; itself, or path_buf+2 if a
                                        ; drive prefix was present and
                                        ; skipped

                public  path_buf
                public  path_dirent
                public  presolve_ptr
                public  presolve_clust
                public  presolve_comp
                public  presolve_drive
                public  presolve_start

                endp
