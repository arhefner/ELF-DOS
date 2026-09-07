;
; dir_data.asm - volatile (RAM-resident) data for dir.asm
;
; Split out of dir.asm for the split memory model (volatile RAM data at
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
; Directory iterator state
;==================================================================

            proc    _dir_data

dir_clust:      dw      0           ; current cluster (0 = FAT16 root)
dir_sect:       db      0           ; sector index ($FF = before first)
dir_eptr:       dw      0           ; pointer to next entry in dir_buf
dir_eleft:      db      0           ; entries remaining in current sector
dir_lfn:        ds      LFN_BUFLEN  ; assembled LFN name buffer
dir_lfn_chk:    db      0           ; checksum from LFN entries
dir_lfn_ok:     db      0           ; non-zero if a valid LFN is ready

; dir_cur_lba/dir_last_off: on-disk location of the entry most
; recently returned by dir_read, for callers (file_open) that need
; to find their way back to it later (e.g. to rewrite its size
; after file_write extends a file). dir_cur_lba is the absolute LBA
; of the currently-loaded sector (set by _dir_next_sector each time
; it loads one -- stable across multiple dir_read calls returning
; entries from the same sector). dir_last_off is the entry's byte
; offset within that sector (0/32/.../480), set fresh by dir_read
; every time it returns a valid entry.
dir_cur_lba:    ds      LBA_SIZE
dir_last_off:   dw      0

                public  dir_clust
                public  dir_sect
                public  dir_eptr
                public  dir_eleft
                public  dir_lfn
                public  dir_lfn_chk
                public  dir_lfn_ok
                public  dir_cur_lba
                public  dir_last_off

                endp
