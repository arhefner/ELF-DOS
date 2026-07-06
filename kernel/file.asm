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
; io_owner tracks which FCB index (if any) currently backs it.
;
; file_read/file_write support file sizes and positions up to 64K
; (only the low 16 bits of FCB_FSIZE/FCB_FPOS are used) -- this
; hardware's RAM makes anything larger moot in practice.
;
; file_write is not yet implemented (needs fat_alloc/fat_set, which
; are themselves still stubs in fat.asm).
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
            extrn   bpb_spc

; same-file data references (required even within the same file)
            extrn   io_owner
            extrn   file_dirent
            extrn   fo_name
            extrn   fo_mode
            extrn   fo_handle
            extrn   fo_fcb
            extrn   fr_request

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
            lbnz    finit_pad           ; advance RF past rest of slot

            inc     rf                  ; skip to next slot's flags byte
            dec     rc
            glo     rc
            lbnz    finit_loop

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

            ; save incoming args (RF=name ptr, D=mode) before RF/D
            ; get reused by the free-slot scan below
            plo     rc                  ; RC.0 = mode (temp)
            mov     rd, rf              ; RD = name pointer
            mov     rf, fo_name
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fo_name = name pointer

            mov     rf, fo_mode
            glo     rc
            str     rf                  ; fo_mode = mode

            ; --- find a free FCB slot ---
            ldi     0
            plo     rc                  ; RC.0 = index = 0
            mov     rf, fcb_table       ; RF = current slot pointer

fopen_scan:
            glo     rc
            xri     FCB_COUNT
            lbz     fopen_no_slot       ; index == FCB_COUNT: no free slot

            ldn     rf                  ; D = FCB_FLAGS of this slot
            lbz     fopen_found         ; 0 = free slot found

            add16   rf, FCB_LEN         ; advance to next slot
            glo     rc
            adi     1
            plo     rc                  ; index++
            lbr     fopen_scan

fopen_no_slot:
            stc                         ; DF = 1, no free slot
            rtn

fopen_found:
            ; RF = base address of the free slot, RC.0 = its index
            mov     rd, rf
            mov     rf, fo_fcb
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fo_fcb = slot base address

            mov     rf, fo_handle
            glo     rc
            str     rf                  ; fo_handle = index

            ; BUG FIX: invalidate the shared io_buf cache if it currently
            ; claims to hold a sector for this slot index. FCB indices
            ; are reused once freed, so a stale io_owner match from a
            ; PREVIOUS file that happened to use this same index would
            ; otherwise make file_read believe the old file's cached
            ; sector still belongs to this newly-opened file, serving
            ; up the wrong file's data until the first real sector wrap
            ; forces a fresh disk read (observed: TYPE printed the
            ; previously-loaded program's own binary/strings as the
            ; first ~350 bytes of an unrelated file's content).
            mov     rf, io_owner
            ldn     rf
            str     r2
            glo     rc                  ; D = our index
            sm                          ; D = index - io_owner
            lbnz    fopen_no_invalidate
            ldi     $FF
            str     rf                  ; io_owner = $FF (invalidate)
fopen_no_invalidate:

            ; --- search current directory for a matching file ---
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster
            call    dir_open

fopen_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    fopen_err           ; end of directory: no match

            ; compare entry name against fo_name
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = saved name pointer
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    fopen_loop          ; no match: keep looking

            ; must NOT be a directory
            mov     rf, file_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    fopen_err           ; it's a directory: reject

            ; --- populate the chosen FCB slot ---
            mov     rf, fo_fcb
            lda     rf                  ; D = fcb slot address high byte
            phi     rb
            ldn     rf                  ; D = fcb slot address low byte
            plo     rb                  ; RB = fcb slot base pointer

            ldi     FCB_F_OPEN
            mov     rf, fo_mode
            ldn     rf
            lbz     fopen_flags_done    ; mode 0 = read-only
            ori     FCB_F_WRITE
fopen_flags_done:
            str     rb                  ; FCB_FLAGS
            inc     rb

            ; FCB_SCLUST = first cluster from dirent
            mov     rf, file_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            str     rb
            inc     rb
            ldn     rf                  ; D = cluster low byte
            str     rb
            inc     rb                  ; FCB_SCLUST written

            ; FCB_CCLUST = same start cluster
            mov     rf, file_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_CCLUST written

            ; FCB_CSECT = 0
            ldi     0
            str     rb
            inc     rb

            ; FCB_BOFF = 0 (2 bytes)
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb
            inc     rb

            ; FCB_FSIZE = size from dirent (4 bytes, big-endian copy)
            mov     rf, file_dirent
            add16   rf, DIRENT_SIZE
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_FSIZE written

            ; FCB_FPOS = 0 (4 bytes)
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb                  ; FCB_FPOS written

            mov     rf, fo_handle
            ldn     rf                  ; D = FCB index (handle)
            clc                         ; DF = 0, success
            rtn

fopen_err:
            stc                         ; DF = 1, error
            rtn

; ----------------------------------------------------------------
; file_close: flush and release an FCB slot
; Args:   D = FCB index
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            endp

            proc    file_close

            plo     rc                  ; RC.0 = FCB index

            glo     rc
            smi     FCB_COUNT
            lbdf    fclose_bad_index    ; index >= FCB_COUNT: error

            ; compute slot address = fcb_table + index*FCB_LEN (FCB_LEN=16)
            glo     rc
            shl
            shl
            shl
            shl                         ; D = index * 16
            plo     rd
            ldi     0
            phi     rd                  ; RD = index*16
            mov     rf, fcb_table
            add16   rf, rd              ; RF = slot base address
            mov     rd, rf              ; RD = slot base (survives io_owner check)

            ; if io_owner is this fcb, invalidate the shared io_buf
            mov     rf, io_owner
            ldn     rf
            str     r2
            glo     rc                  ; D = our index
            sm                          ; D = our_index - io_owner
            lbnz    fclose_no_invalidate
            ldi     $FF
            str     rf                  ; io_owner = $FF (invalidate)
fclose_no_invalidate:

            ; mark slot free
            mov     rf, rd              ; RF = slot base
            ldi     0
            str     rf                  ; FCB_FLAGS = 0

            clc
            rtn

fclose_bad_index:
            stc
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
            ; NOTE: this layer supports file sizes/positions up to 64K
            ; (only the low 16 bits of FCB_FSIZE/FCB_FPOS are used).
            ; FAT16 itself allows larger files, but this hardware's RAM
            ; makes a 64K read moot in practice.
            ;
            ; Register usage (stable across the whole loop, protected
            ; with push/pop around _cluster_to_lba and fat_get, which
            ; both clobber registers this routine depends on):
            ;   RA  destination pointer
            ;   RB  FCB slot base address
            ;   RC  bytes remaining to read (the arg, decremented)
            ;   R9  FCB index (only .0 half is meaningful)
            ; R7/R8/RD are scratch, recomputed fresh each iteration.

            ; BUG FIX: "mov ra, rf" itself clobbers D (its final GLO RF
            ; leaves D = RF's low byte -- part of the destination buffer
            ; address), so the real FCB index passed in D at entry would
            ; not survive to "plo r9" unless captured first. This is why
            ; prog_load's own call (RF=PROG_BASE, low byte 0) coincidentally
            ; worked while any other destination buffer corrupted R9.0 into
            ; a bogus FCB-slot index, reading/writing essentially random
            ; memory for the rest of the call.
            plo     r9                  ; R9.0 = FCB index (captured first)
            mov     ra, rf              ; RA = destination pointer

            mov     rf, fr_request
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; fr_request = original byte count

            glo     r9
            shl
            shl
            shl
            shl                         ; D = index * 16 (FCB_LEN)
            plo     rd
            ldi     0
            phi     rd
            mov     rb, fcb_table
            add16   rb, rd              ; RB = FCB slot base address

fread_loop:
            glo     rc
            lbnz    fread_check_eof
            ghi     rc
            lbz     fread_done
fread_check_eof:
            ; ---- file_remaining = FSIZE - FPOS (low word only) ----
            mov     rf, rb
            add16   rf, FCB_FSIZE
            add16   rf, 2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FSIZE (low word)

            mov     rf, rb
            add16   rf, FCB_FPOS
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FPOS (low word)

            glo     r8
            str     r2
            glo     rd
            sm                          ; D = FSIZE.lo - FPOS.lo, DF=1 if no borrow
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            smb                         ; D = FSIZE.hi - FPOS.hi - borrow
            phi     rd                  ; RD = file_remaining
            lbnf    fread_done          ; DF=0: FPOS>FSIZE (shouldn't happen) -- stop
            glo     rd
            lbnz    fread_have_remaining
            ghi     rd
            lbz     fread_done          ; file_remaining == 0: EOF
fread_have_remaining:
            ; RD = file_remaining (>= 1)

            ; ---- ensure io_buf holds the sector for (FCB_CCLUST,FCB_CSECT) ----
            mov     rf, io_owner
            ldn     rf
            str     r2
            glo     r9                  ; D = our FCB index
            sm                          ; D = index - io_owner
            lbz     fread_have_sector   ; equal: io_buf already holds our sector

            push    rd                  ; save file_remaining across the calls below
            push    ra
            push    rb
            push    rc

            mov     rf, rb
            add16   rf, FCB_CCLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current cluster
            call    _cluster_to_lba     ; R7/R8 = LBA of first sector of cluster

            mov     rf, rb
            add16   rf, FCB_CSECT
            ldn     rf                  ; D = FCB_CSECT
            str     r2
            glo     r7
            add
            plo     r7
            ghi     r7
            adci    0
            phi     r7
            glo     r8
            adci    0
            plo     r8

            mov     rf, io_buf
            call    f_ideread
            lbdf    fread_ioerr_cleanup

            pop     rc
            pop     rb
            pop     ra
            pop     rd                  ; restore file_remaining
            mov     rf, io_owner
            glo     r9
            str     rf                  ; io_owner = our FCB index

fread_have_sector:
            ; RD = file_remaining (valid whether just-loaded or already-cached)

            ; ---- chunk = min(remaining_requested, sector_remaining, file_remaining) ----
            push    rd                  ; save file_remaining while computing sector_remaining

            mov     rf, rb
            add16   rf, FCB_BOFF
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FCB_BOFF

            glo     r8
            str     r2
            ldi     $00
            sm                          ; D = 0x00 - BOFF.lo, DF=1 if BOFF.lo==0
            plo     r8
            ghi     r8
            str     r2
            ldi     $02
            smb                         ; D = 0x02 - BOFF.hi - borrow
            phi     r8                  ; R8 = sector_remaining (512 - BOFF)

            pop     rd                  ; RD = file_remaining again

            ghi     rc
            phi     r7
            glo     rc
            plo     r7                  ; R7 = remaining requested (initial chunk)

            ; clamp by sector_remaining (R8)
            glo     r7
            str     r2
            glo     r8
            sm                          ; DF=1 if R8 >= R7 (no borrow)
            ghi     r7
            str     r2
            ghi     r8
            smb
            lbdf    fread_skip_min1     ; R8 >= R7: keep R7
            mov     r7, r8              ; R8 < R7: take R8
fread_skip_min1:

            ; clamp by file_remaining (RD)
            glo     r7
            str     r2
            glo     rd
            sm
            ghi     r7
            str     r2
            ghi     rd
            smb
            lbdf    fread_skip_min2     ; RD >= R7: keep R7
            mov     r7, rd              ; RD < R7: take RD
fread_skip_min2:
            ; R7 = final chunk size, guaranteed >= 1

            ; ---- copy chunk bytes from io_buf+FCB_BOFF to dest ----
            mov     rf, rb
            add16   rf, FCB_BOFF
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FCB_BOFF

            mov     rf, io_buf
            add16   rf, r8              ; RF = io_buf + FCB_BOFF (source)

            ghi     r7
            phi     r8
            glo     r7
            plo     r8                  ; R8 = copy of chunk (countdown, preserves R7)

fread_copy:
            glo     r8
            lbnz    fread_copy_have
            ghi     r8
            lbz     fread_copy_done
fread_copy_have:
            lda     rf                  ; D = source byte, RF++
            str     ra                  ; store to dest
            inc     ra                  ; dest++
            dec     r8
            lbr     fread_copy
fread_copy_done:

            ; FCB_BOFF += chunk
            mov     rf, rb
            add16   rf, FCB_BOFF
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, r7
            mov     rf, rb
            add16   rf, FCB_BOFF
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; FCB_BOFF updated

            ; FCB_FPOS += chunk (low word)
            mov     rf, rb
            add16   rf, FCB_FPOS
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, r7
            mov     rf, rb
            add16   rf, FCB_FPOS
            add16   rf, 2
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; FCB_FPOS (low word) updated

            ; RC -= chunk
            glo     r7
            str     r2
            glo     rc
            sm
            plo     rc
            ghi     r7
            str     r2
            ghi     rc
            smb
            phi     rc                  ; RC -= chunk

            ; ---- did we cross a sector boundary? (FCB_BOFF == 512) ----
            mov     rf, rb
            add16   rf, FCB_BOFF
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FCB_BOFF (post-update)

            ghi     r8
            xri     $02
            lbnz    fread_no_sector_wrap
            glo     r8
            lbnz    fread_no_sector_wrap

            ; FCB_BOFF == 512 exactly: wrap to the next sector
            mov     rf, rb
            add16   rf, FCB_BOFF
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; FCB_BOFF = 0

            mov     rf, rb
            add16   rf, FCB_CSECT
            ldn     rf
            adi     1
            str     rf                  ; FCB_CSECT++

            ; did we also cross a cluster boundary?
            mov     rf, rb
            add16   rf, FCB_CSECT
            ldn     rf                  ; D = new FCB_CSECT
            str     r2
            mov     rf, bpb_spc
            ldn     rf                  ; D = bpb_spc
            sm                          ; D = bpb_spc - FCB_CSECT
            lbnz    fread_no_cluster_wrap   ; not equal: still within this cluster

            ; FCB_CSECT == bpb_spc: advance to the next cluster in the chain
            mov     rf, rb
            add16   rf, FCB_CSECT
            ldi     0
            str     rf                  ; FCB_CSECT = 0

            push    r9
            push    ra
            push    rb
            push    rc
            mov     rf, rb
            add16   rf, FCB_CCLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current cluster
            call    fat_get             ; RD = next cluster
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fread_ioerr         ; I/O error from fat_get

            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; FCB_CCLUST = next cluster
            ; if this is now an end-of-chain marker, the next iteration's
            ; FCB_FPOS/FCB_FSIZE check stops the loop before we'd ever
            ; try to load a sector from it, provided the directory
            ; entry's size is consistent with its cluster chain

fread_no_cluster_wrap:
            ; invalidate io_owner so the next iteration reloads the sector
            mov     rf, io_owner
            ldi     $FF
            str     rf

fread_no_sector_wrap:
            lbr     fread_loop

fread_done:
            call    fread_calc_read
            clc                         ; DF = 0, success
            rtn

fread_ioerr_cleanup:
            pop     rc
            pop     rb
            pop     ra
            pop     rd
fread_ioerr:
            call    fread_calc_read
            stc                         ; DF = 1, error
            rtn

fread_calc_read:
            ; RC = fr_request - RC(remaining)  -->  bytes actually read
            mov     rf, fr_request
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = original requested count

            glo     rc
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     rc
            str     r2
            ghi     rd
            smb
            phi     r9                  ; R9 = bytes_read

            ghi     r9
            phi     rc
            glo     r9
            plo     rc                  ; RC = bytes_read (return value)
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

            plo     rc                  ; RC.0 = FCB index

            glo     rc
            smi     FCB_COUNT
            lbdf    fseek_bad_index     ; index >= FCB_COUNT: error

            ; compute slot address = fcb_table + index*FCB_LEN (16)
            glo     rc
            shl
            shl
            shl
            shl
            plo     rd
            ldi     0
            phi     rd
            mov     rb, fcb_table
            add16   rb, rd              ; RB = FCB slot base address

            ; FCB_CCLUST = FCB_SCLUST (rewind to the file's start cluster)
            mov     rf, rb
            add16   rf, FCB_SCLUST
            lda     rf                  ; D = start cluster high byte
            phi     rd
            ldn     rf                  ; D = start cluster low byte
            plo     rd

            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; FCB_CCLUST = FCB_SCLUST

            ; FCB_CSECT = 0
            mov     rf, rb
            add16   rf, FCB_CSECT
            ldi     0
            str     rf

            ; FCB_BOFF = 0 (2 bytes)
            mov     rf, rb
            add16   rf, FCB_BOFF
            ldi     0
            str     rf
            inc     rf
            str     rf

            ; FCB_FPOS = 0 (4 bytes)
            mov     rf, rb
            add16   rf, FCB_FPOS
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            ; if io_owner is this fcb, invalidate the shared io_buf --
            ; the buffered sector no longer matches the rewound position
            mov     rf, io_owner
            ldn     rf
            str     r2
            glo     rc
            sm
            lbnz    fseek_done
            ldi     $FF
            str     rf                  ; io_owner = $FF

fseek_done:
            clc
            rtn

fseek_bad_index:
            stc
            rtn

            endp

;------------------------------------------------------------------
; File-layer scratch data
;
; io_owner:    FCB index currently backing the shared io_buf sector,
;              or $FF if none.
; file_dirent: scratch DIRENT_LEN buffer for file_open's directory
;              search (private to this module, unlike shell.asm's
;              dir_result).
; fo_*:        file_open's saved arguments and chosen FCB slot --
;              needed because dir_open/dir_read clobber R9/RA/RB/RC/
;              RD/RF internally, so nothing survives in a register
;              across the directory-search loop.
; fr_request:  file_read's original requested byte count, needed to
;              compute the actual bytes-read return value at the end.
;------------------------------------------------------------------
            proc    _file_data

io_owner:       db      $FF
file_dirent:    ds      DIRENT_LEN
fo_name:        dw      0
fo_mode:        db      0
fo_fcb:         dw      0
fo_handle:      db      0
fr_request:     dw      0

                public  io_owner
                public  file_dirent
                public  fo_name
                public  fo_mode
                public  fo_fcb
                public  fo_handle
                public  fr_request

            endp
