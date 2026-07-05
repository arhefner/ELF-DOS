;
; file.asm - File handle (FCB) layer
;
; Provides:
;   file_init   -- clear all FCB slots at boot
;   file_open   -- open a file by path, return FCB index
;   file_close  -- flush and release an FCB
;   file_read   -- read bytes from an open file
;   file_write  -- write bytes to an open file
;   file_seek   -- move file position (sequential only for now)
;
; FCB structure (FCB_LEN = 16 bytes per slot):
;   FCB_FLAGS   (1)  FCB_F_OPEN / FCB_F_WRITE / FCB_F_DIRTY
;   FCB_SCLUST  (2)  first cluster of file
;   FCB_CCLUST  (2)  cluster currently being accessed
;   FCB_CSECT   (1)  sector index within current cluster
;   FCB_BOFF    (2)  byte offset within current sector
;   FCB_FSIZE   (4)  file size (big-endian)
;   FCB_FPOS    (4)  current position (big-endian)
;
; The kernel has one shared 512-byte io_buf sector buffer.
; Only one file can have an active sector in that buffer at a
; time -- sufficient for single-tasking sequential file access.
;
; TO BE IMPLEMENTED
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   fcb_table
            extrn   io_buf
            extrn   cur_dir
            extrn   fat_get
            extrn   fat_flush
            extrn   dir_open
            extrn   dir_read
            extrn   _cluster_to_lba

; same-file data references (required even within the same file)
            extrn   io_owner
            extrn   file_dirent
            extrn   fo_name
            extrn   fo_mode
            extrn   fo_handle
            extrn   fo_fcb
            extrn   fr_saved_rd
            extrn   fr_chunk

.link       .align  page

; ----------------------------------------------------------------
; file_init: mark all FCB slots as free
; Called once at boot before the shell starts.
; ----------------------------------------------------------------
            proc    file_init

            mov     rf, fcb_table
            ldi     FCB_COUNT
            plo     rc                  ; RC.0 = slot count

finit_loop: ldi     0
            str     rf                  ; FCB_FLAGS = 0 (free)
            ldi     FCB_LEN - 1
            plo     rd

finit_pad:  inc     rf
            dec     rd
            glo     rd
            bnz     finit_pad           ; advance RF past rest of slot

            inc     rf                  ; skip to next slot's flags byte
            dec     rc
            glo     rc
            bnz     finit_loop

            rtn

; ----------------------------------------------------------------
; file_open: open a file by name in the current directory
; Args:   RF = pointer to null-terminated filename string
;         D  = 0 for read, 1 for read/write
; Returns: D  = FCB index (0..FCB_COUNT-1) on success
;          DF = 0 on success, DF = 1 on error (not found / no slots)
; ----------------------------------------------------------------
            endp

            proc    file_open
            ; TODO
            stc
            rtn

; ----------------------------------------------------------------
; file_close: flush and release an FCB slot
; Args:   D = FCB index
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            endp

            proc    file_close
            ; TODO
            clc
            rtn

; ----------------------------------------------------------------
; file_read: read bytes from an open file into a buffer
; Args:   D  = FCB index
;         RF = destination buffer
;         RC = byte count
; Returns: RC = bytes actually read (may be less at EOF)
;          DF = 0 on success, DF = 1 on I/O error
; ----------------------------------------------------------------
            endp

            proc    file_read
            ; TODO
            ldi     0
            plo     rc
            phi     rc
            clc
            rtn

; ----------------------------------------------------------------
; file_write: write bytes from a buffer into an open file
; Args:   D  = FCB index
;         RF = source buffer
;         RC = byte count
; Returns: DF = 0 on success, DF = 1 on error (disk full / I/O)
; ----------------------------------------------------------------
            endp

            proc    file_write
            ; TODO
            stc
            rtn

; ----------------------------------------------------------------
; file_seek: set file position to start of file (rewind)
; More general seeking to be added when needed.
; Args:   D = FCB index
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            endp

            proc    file_seek
            ; TODO
            clc
            rtn

            endp
