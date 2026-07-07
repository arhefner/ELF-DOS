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
; FCB structure (FCB_LEN = 32 bytes per slot -- only 21 are used,
; padded to the next power of 2 so index*FCB_LEN stays a simple
; 5-shift multiply):
;   FCB_FLAGS   (1)  FCB_F_OPEN / FCB_F_WRITE / FCB_F_DIRTY / FCB_F_SIZECHG
;   FCB_SCLUST  (2)  first cluster of file
;   FCB_CCLUST  (2)  cluster currently being accessed
;   FCB_CSECT   (1)  sector index within current cluster
;   FCB_BOFF    (2)  byte offset within current sector
;   FCB_FSIZE   (4)  file size (big-endian)
;   FCB_FPOS    (4)  current position (big-endian)
;   FCB_ELBA    (3)  directory entry's sector LBA (big-endian)
;   FCB_EOFF    (2)  entry's byte offset within that sector (big-endian)
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
; file_write only extends/overwrites already-existing files (their
; directory entry, and first cluster if non-empty, must already
; exist -- see file_open). It writes through to disk immediately
; rather than buffering via FCB_F_DIRTY/io_buf. If it grows
; FCB_FSIZE past the size recorded at open, FCB_F_SIZECHG is set so
; file_close rewrites the directory entry's size field (at
; FCB_ELBA/FCB_EOFF) before releasing the FCB. Creating a brand-new
; file (no existing directory entry) is not yet supported.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   fcb_table
            extrn   io_buf
            extrn   cur_dir
            extrn   fat_get
            extrn   fat_set
            extrn   fat_alloc
            extrn   fat_flush
            extrn   dir_open
            extrn   dir_read
            extrn   dir_cur_lba
            extrn   dir_last_off
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
            extrn   dirent_patch_buf
            extrn   fcrw_slot
            extrn   _fclose_rewrite_size

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
            ; BUG FIX: this was missing the 4th "inc rb" after the
            ; last "str rb" (4 bytes written, only 3 increments) --
            ; a long-standing bug that was harmless before today,
            ; since FCB_FPOS used to be the last field written and
            ; nothing afterward relied on RB's exact value. Adding
            ; FCB_ELBA/FCB_EOFF after it this session exposed it:
            ; every byte from there on was shifted one position
            ; early, which is why FCB_EOFF read garbage (confirmed
            ; via diagnostic: dir_last_off computed correctly, but
            ; the copy into FCB_EOFF landed one byte off).
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_FPOS written

            ; FCB_ELBA = dir_cur_lba (3 bytes) -- the sector this
            ; entry was found in, remembered so file_close can
            ; rewrite its size field later if file_write grows it
            mov     rf, dir_cur_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_ELBA written

            ; FCB_EOFF = dir_last_off (2 bytes, big-endian)
            mov     rf, dir_last_off
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_EOFF written

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

            ; compute slot address = fcb_table + index*FCB_LEN (FCB_LEN=32)
            glo     rc
            shl
            shl
            shl
            shl
            shl                         ; D = index * 32
            plo     rd
            ldi     0
            phi     rd                  ; RD = index*32
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
            ; if the file grew since it was opened, rewrite the
            ; directory entry's size field before releasing the slot
            mov     rf, rd              ; RF = slot base (FCB_FLAGS)
            ldn     rf
            ani     FCB_F_SIZECHG
            lbz     fclose_no_rewrite

            push    rd                  ; save slot base across the rewrite
            call    _fclose_rewrite_size
            pop     rd
            ; rewrite errors are ignored here -- there's nothing more
            ; to do at close time, and the slot is released either way

fclose_no_rewrite:
            ; mark slot free
            mov     rf, rd              ; RF = slot base
            ldi     0
            str     rf                  ; FCB_FLAGS = 0

            clc
            rtn

fclose_bad_index:
            stc
            rtn

            endp

; ----------------------------------------------------------------
; _fclose_rewrite_size: rewrite an FCB's directory entry size field
; on disk, copying FCB_FSIZE to the entry's DE_SIZE field at the
; sector/offset recorded in FCB_ELBA/FCB_EOFF.
;
; Args:    RD = FCB slot base address
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RC, RD, RF
; ----------------------------------------------------------------
            proc    _fclose_rewrite_size

            mov     rf, fcrw_slot
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fcrw_slot = FCB slot base

            ; load FCB_ELBA into R7/R8 for f_ideread
            mov     rf, rd
            add16   rf, FCB_ELBA
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            ldn     rf                  ; D = bits 7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            mov     rf, dirent_patch_buf
            call    f_ideread
            lbdf    fcrw_err

            ; reload FCB slot base fresh from memory (not a register --
            ; see fcrw_slot's comment)
            mov     rf, fcrw_slot
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FCB slot base

            ; RF = dirent_patch_buf + FCB_EOFF + DE_SIZE
            mov     rf, rd
            add16   rf, FCB_EOFF
            lda     rf                  ; D = eoff high byte
            phi     r9
            ldn     rf                  ; D = eoff low byte
            plo     r9                  ; R9 = FCB_EOFF value

            mov     rf, dirent_patch_buf
            add16   rf, r9              ; RF = entry's address in the buffer
            add16   rf, DE_SIZE         ; RF -> entry's 4-byte size field

            ; copy FCB_FSIZE (4 bytes, big-endian) to DE_SIZE (4
            ; bytes, little-endian on disk) -- byte order reverses
            mov     r9, rd
            add16   r9, FCB_FSIZE       ; R9 -> FCB_FSIZE (big-endian, MSB first)

            lda     r9                  ; D = FSIZE byte 0 (MSB)
            plo     rc
            lda     r9                  ; D = FSIZE byte 1
            phi     rc
            lda     r9                  ; D = FSIZE byte 2
            plo     rd
            ldn     r9                  ; D = FSIZE byte 3 (LSB)
            phi     rd                  ; RC = bytes 0,1; RD = bytes 2,3

            ghi     rd                  ; D = FSIZE byte 3 (LSB) -> write first
            str     rf
            inc     rf
            glo     rd                  ; D = FSIZE byte 2
            str     rf
            inc     rf
            ghi     rc                  ; D = FSIZE byte 1
            str     rf
            inc     rf
            glo     rc                  ; D = FSIZE byte 0 (MSB) -> write last
            str     rf

            ; write the patched sector back -- reload LBA fresh
            mov     rf, fcrw_slot
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FCB slot base
            mov     rf, rd
            add16   rf, FCB_ELBA
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, dirent_patch_buf
            call    f_idewrite
            lbdf    fcrw_err

            clc                         ; DF = 0, success
            rtn

fcrw_err:
            stc                         ; DF = 1, I/O error
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
            shl
            shl                         ; D = index * 32 (FCB_LEN)
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
            ; Mirrors file_read's structure closely (see its comments
            ; for the general chunking/sector-cache approach) with
            ; three differences:
            ;   1. No EOF/file_remaining clamp -- writing extends the
            ;      file rather than stopping at FCB_FSIZE.
            ;   2. Writes through to disk immediately after modifying
            ;      each chunk in io_buf, rather than deferring via
            ;      FCB_F_DIRTY (a future optimization, see kernel.inc).
            ;   3. Crossing a cluster boundary tries fat_get first
            ;      (an existing chain may already continue past this
            ;      point, e.g. overwriting the middle of a file); only
            ;      on end-of-chain does it fat_alloc a new cluster and
            ;      fat_set the link.
            ;
            ; Register usage (stable across the whole loop, protected
            ; with push/pop around calls that clobber registers this
            ; routine depends on):
            ;   RA  source pointer
            ;   RB  FCB slot base address
            ;   RC  bytes remaining to write (the arg, decremented)
            ;   R9  FCB index (only .0 half is meaningful)
            ; R7/R8/RD are scratch, recomputed fresh each iteration.

            plo     r9                  ; R9.0 = FCB index (captured before
                                        ; "mov ra, rf" clobbers D -- see
                                        ; file_read's BUG FIX note)
            mov     ra, rf              ; RA = source pointer

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
            shl
            shl                         ; D = index * 32 (FCB_LEN)
            plo     rd
            ldi     0
            phi     rd
            mov     rb, fcb_table
            add16   rb, rd              ; RB = FCB slot base address

fwrite_loop:
            glo     rc
            lbnz    fwrite_have_more
            ghi     rc
            lbz     fwrite_done
fwrite_have_more:
            ; ---- ensure io_buf holds the sector for (FCB_CCLUST,FCB_CSECT) ----
            ; (read-modify-write: we need the sector's existing
            ; content so bytes outside this chunk are preserved)
            mov     rf, io_owner
            ldn     rf
            str     r2
            glo     r9                  ; D = our FCB index
            sm                          ; D = index - io_owner
            lbz     fwrite_have_sector  ; equal: io_buf already holds our sector

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
            lbdf    fwrite_ioerr_cleanup

            pop     rc
            pop     rb
            pop     ra
            mov     rf, io_owner
            glo     r9
            str     rf                  ; io_owner = our FCB index

fwrite_have_sector:
            ; ---- chunk = min(remaining_requested, sector_remaining) ----
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
            lbdf    fwrite_skip_min1    ; R8 >= R7: keep R7
            mov     r7, r8              ; R8 < R7: take R8
fwrite_skip_min1:
            ; R7 = final chunk size, guaranteed >= 1

            ; ---- copy chunk bytes from source into io_buf+FCB_BOFF ----
            mov     rf, rb
            add16   rf, FCB_BOFF
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FCB_BOFF

            mov     rf, io_buf
            add16   rf, r8              ; RF = io_buf + FCB_BOFF (dest)

            ghi     r7
            phi     r8
            glo     r7
            plo     r8                  ; R8 = copy of chunk (countdown, preserves R7)

fwrite_copy:
            glo     r8
            lbnz    fwrite_copy_have
            ghi     r8
            lbz     fwrite_copy_done
fwrite_copy_have:
            lda     ra                  ; D = source byte, RA++
            str     rf                  ; store into io_buf
            inc     rf
            dec     r8
            lbr     fwrite_copy
fwrite_copy_done:

            ; ---- write the modified sector back immediately ----
            ; BUG FIX: R7 still holds "chunk" here, needed further
            ; down for FCB_BOFF/FCB_FPOS/RC updates -- but
            ; _cluster_to_lba returns its result in R7/R8 (that's its
            ; documented output), so it silently clobbered chunk with
            ; part of the just-computed disk LBA. Every subsequent
            ; "+= chunk"/"-= chunk" then used that garbage instead of
            ; the real byte count, so FCB_BOFF/FCB_FPOS/RC never
            ; actually advanced -- an infinite loop that still hit
            ; the disk every iteration (confirmed via diagnostic
            ; trace: RC/BOFF/CSECT/CCLUST frozen across 250
            ; iterations). R7 must be protected across this call too,
            ; not just RA/RB/RC.
            push    r7
            push    ra
            push    rb
            push    rc

            mov     rf, rb
            add16   rf, FCB_CCLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current cluster
            call    _cluster_to_lba     ; R7/R8 = LBA of first sector of cluster (temporary, restored below)

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
            call    f_idewrite
            lbdf    fwrite_ioerr_cleanup2

            pop     rc
            pop     rb
            pop     ra
            pop     r7                  ; restore chunk (see BUG FIX note)

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

            ; if FCB_FPOS now reaches or exceeds FCB_FSIZE, the file
            ; grew -- update FCB_FSIZE and flag the directory entry
            ; for a size-field rewrite at close
            mov     rf, rb
            add16   rf, FCB_FPOS
            add16   rf, 2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FPOS (low word, just updated)

            mov     rf, rb
            add16   rf, FCB_FSIZE
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FSIZE (low word)

            glo     r8
            str     r2
            glo     rd
            sm                          ; D = FPOS.lo - FSIZE.lo, DF=1 if no borrow
            ghi     r8
            str     r2
            ghi     rd
            smb                         ; D = FPOS.hi - FSIZE.hi - borrow
            lbnf    fwrite_no_grow      ; DF=0: FPOS < FSIZE, no growth

            mov     rf, rb
            add16   rf, FCB_FSIZE
            add16   rf, 2
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; FCB_FSIZE (low word) updated

            mov     rf, rb
            ldn     rf
            ori     FCB_F_SIZECHG
            str     rf                  ; FCB_FLAGS |= FCB_F_SIZECHG

fwrite_no_grow:
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
            lbnz    fwrite_no_sector_wrap
            glo     r8
            lbnz    fwrite_no_sector_wrap

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
            lbnz    fwrite_no_cluster_wrap  ; not equal: still within this cluster

            ; FCB_CSECT == bpb_spc: need the next cluster in the chain
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
            call    fat_get             ; RD = next cluster, or EOC
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fwrite_ioerr        ; I/O error from fat_get

            ; is this end-of-chain? (cluster >= FAT_EOC = $FFF8)
            ghi     rd
            smi     $FF
            lbnf    fwrite_have_next    ; high byte < $FF: valid next cluster
            glo     rd
            smi     $F8
            lbnf    fwrite_have_next    ; < $FFF8: valid next cluster

            ; end of chain: allocate a new cluster and link
            ; old_cluster -> new_cluster via fat_set. fat_alloc
            ; itself calls fat_set to claim the cluster (marking it
            ; end-of-chain), which clobbers RB internally (fat_set
            ; uses RB for its own "value to write" argument) -- our
            ; FCB-base RB must be protected across this call too, not
            ; just R9/RA/RC.
            push    r9
            push    ra
            push    rb
            push    rc
            call    fat_alloc           ; RD = new cluster; DF=0/1
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fwrite_ioerr        ; disk full or I/O error

            ; RD = new cluster. Stash it in R8 (free here) before we
            ; need RD again for the OLD cluster (fat_set's argument).
            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = new cluster

            ; fetch old (current) cluster into RD -- fat_set's arg
            mov     rf, rb
            add16   rf, FCB_CCLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = old cluster

            ; RB is our FCB-base register throughout this loop, but
            ; fat_set also uses RB for its "value to write" argument
            ; -- save FCB base and substitute the new cluster value,
            ; restoring FCB base right after. R8 (new cluster) is
            ; also protected since fat_set clobbers it internally.
            push    rb                  ; save FCB base
            push    r8                  ; save new cluster
            ghi     r8
            phi     rb
            glo     r8
            plo     rb                  ; RB = new cluster (fat_set's value arg)

            push    r9
            push    ra
            push    rc
            call    fat_set             ; RD=old cluster, RB=new cluster; DF=0/1
            pop     rc
            pop     ra
            pop     r9

            pop     r8                  ; restore new cluster
            pop     rb                  ; restore FCB base
            lbdf    fwrite_ioerr

            ; switch to the new cluster: FCB_CCLUST = new cluster (R8)
            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; FCB_CCLUST = new cluster

            lbr     fwrite_no_cluster_wrap

fwrite_have_next:
            ; fat_get returned a valid existing next cluster (RD)
            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; FCB_CCLUST = next cluster

fwrite_no_cluster_wrap:
            ; invalidate io_owner so the next iteration reloads the sector
            mov     rf, io_owner
            ldi     $FF
            str     rf

fwrite_no_sector_wrap:
            lbr     fwrite_loop

fwrite_done:
            call    fwrite_calc_written
            clc                         ; DF = 0, success
            rtn

fwrite_ioerr_cleanup:
            pop     rc
            pop     rb
            pop     ra
            lbr     fwrite_ioerr

fwrite_ioerr_cleanup2:
            ; used only by the write-back block, which pushes one
            ; extra register (R7 = chunk, see its BUG FIX note) that
            ; the sector-cache-load block above doesn't
            pop     rc
            pop     rb
            pop     ra
            pop     r7

fwrite_ioerr:
            call    fwrite_calc_written
            stc                         ; DF = 1, error
            rtn

fwrite_calc_written:
            ; RC = fr_request - RC(remaining)  -->  bytes actually written
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
            phi     r9                  ; R9 = bytes_written

            ghi     r9
            phi     rc
            glo     r9
            plo     rc                  ; RC = bytes_written (return value)
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

            ; compute slot address = fcb_table + index*FCB_LEN (32)
            glo     rc
            shl
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

; dirent_patch_buf/fcrw_slot: scratch for _fclose_rewrite_size.
; A dedicated 512-byte buffer, deliberately NOT io_buf -- reusing
; the shared file-data cache here would corrupt another still-open
; FCB's legitimately cached sector regardless of io_owner, since the
; entry being patched can live in a completely unrelated sector.
dirent_patch_buf: ds    SECTOR_SIZE
fcrw_slot:      dw      0           ; FCB slot base, kept in memory
                                    ; (not a register) across
                                    ; f_ideread/f_idewrite, since only
                                    ; RA/RC/RD are confirmed preserved
                                    ; by those calls

                public  io_owner
                public  file_dirent
                public  fo_name
                public  fo_mode
                public  fo_fcb
                public  fo_handle
                public  fr_request
                public  dirent_patch_buf
                public  fcrw_slot

            endp
