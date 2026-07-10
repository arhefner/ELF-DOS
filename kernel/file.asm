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
            extrn   dir_clust
            extrn   dir_sect
            extrn   dir_eptr
            extrn   dir_buf
            extrn   path_resolve
            extrn   _cluster_to_lba
            extrn   _dir_next_sector
            extrn   _dir_chksum
            extrn   bpb_spc
            extrn   bpb_spc_shift
            extrn   rtc_refresh
            extrn   _pack_fat_datetime

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
            extrn   _file_create
            extrn   _delete_located_entry
            extrn   _mark_entry_deleted
            extrn   fc_elba
            extrn   fc_eoff
            extrn   fc_diag_last_lba
            extrn   fc_diag_last_off
            extrn   diag_lb_buf
            extrn   fc_shortname
            extrn   fc_needs_lfn
            extrn   fc_namelen
            extrn   fc_lfncount
            extrn   fc_checksum
            extrn   fc_target_lba
            extrn   fc_target_off
            extrn   fc_new_attr
            extrn   fc_new_cluster
            extrn   fc_new_size
            extrn   _gen_short_name
            extrn   _classify_char
            extrn   _lfn_fill_segment
            extrn   fa_boff
            extrn   fa_cluster_idx
            extrn   fa_sector_in_clust
            extrn   fdel_next_clust
            extrn   fdel_chksum
            extrn   dle_diag_char
            extrn   dcr_parent
            extrn   dcr_new_clust
            extrn   dcr_sect_lba
            extrn   drm_parent
            extrn   drm_saved_clust
            extrn   drm_saved_off
            extrn   drm_saved_lba
            extrn   ren_new_name
            extrn   ren_parent
            extrn   ren_old_off
            extrn   ren_old_lba

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
; file_open: open a file by path
; Args:   RF = pointer to null-terminated path string. May be a bare
;              filename (looked up in the current directory), a
;              relative path ("cfg/env.dat"), or an absolute path
;              ("/cfg/env.dat") -- see path_resolve in path.asm.
;         D  = 0 for read, 1 for read/write
; Returns: D  = FCB index (0..FCB_COUNT-1) on success
;          DF = 0 on success, DF = 1 on error (not found, an
;               intermediate path component isn't a directory, the
;               path names a directory rather than a file, or no
;               free FCB slots)
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

            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF right at file_open's
            ; very entry, before path_resolve/dir_open/the scan loop
            ; run at all -- finer-grained bracket than the existing
            ; pre-scan/post-match dumps, to pin down whether
            ; corruption (ren8.txt-ren13.txt) happens during THIS
            ; call's own path_resolve/dir_open, or happened already,
            ; during the PREVIOUS file_open call's return/cleanup path
            ; (ren13.txt showed attempt 1 "copy" clean throughout, but
            ; attempt 2 "copy.EXE" already corrupted by its own
            ; pre-scan point -- this narrows which side of that
            ; boundary it's on). SAFE dump pattern (CLAUDE.md gotcha
            ; #14): scratch buffer + single f_msg, no per-char BIOS
            ; calls in a loop.
            mov     rf, LINE_BUF
            mov     rb, diag_lb_buf
            ldi     24
            plo     rc
diag_lb0_loop:
            lda     rf
            lbnz    diag_lb0_have
            ldi     '.'
diag_lb0_have:
            str     rb
            inc     rb
            dec     rc
            glo     rc
            lbnz    diag_lb0_loop
            ldi     0
            str     rb

            call    f_inmsg
            db      13,10,"DIAG linebuf entry ='",0
            mov     rf, diag_lb_buf
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

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

            ; --- resolve the (possibly multi-component) path ---
            ; RD = cur_dir, used as path_resolve's base cluster for
            ; relative paths; a leading '/' in the name overrides it
            ; and resolves from the root instead (see path.asm).
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster

            mov     ra, fo_name         ; RA = address of fo_name (scratch,
                                        ; distinct from RF so RF is free
                                        ; to receive the pointer value)
            lda     ra
            phi     rf
            ldn     ra
            plo     rf                  ; RF = name/path pointer
            call    path_resolve        ; RD = parent cluster, RF = final
                                        ; component (in path_resolve's
                                        ; own scratch, not fo_name's
                                        ; original string)
            lbdf    fopen_err           ; bad intermediate component

            ; an empty final component means the path named a
            ; directory itself ("/cfg/", "/", ...) -- not a file
            ldn     rf
            lbz     fopen_err

            ; save the resolved final-component pointer into fo_name,
            ; using RB (not RF) as the store-address register so RD
            ; (still the resolved parent cluster from path_resolve)
            ; and RF (the pointer value being saved) survive untouched
            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = final component pointer

            ; TEMPORARY DIAGNOSTIC: print fo_name right after
            ; path_resolve, before the exists-scan (dir_open/dir_read/
            ; _dir_next_sector) runs -- bracketed against _file_create's
            ; own entry print (fc entry name=) to narrow down whether
            ; corruption (COPY's destination showing up as "ini "
            ; instead of "init5.rc", ren8.txt) happens during
            ; path_resolve's own copy, or during the exists-scan that
            ; follows. RD (parent cluster, needed by dir_open right
            ; after) is protected in RB across the diagnostic calls.
            ghi     rd
            phi     rb
            glo     rd
            plo     rb                  ; RB = parent cluster (stashed)

            call    f_inmsg
            db      13,10,"DIAG fopen post-resolve name='",0
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0

            ghi     rb
            phi     rd
            glo     rb
            plo     rd                  ; RD = parent cluster (restored)
            ; END TEMPORARY DIAGNOSTIC

            ; RD is still the resolved parent cluster from path_resolve
            call    dir_open

            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF's first 24 bytes
            ; (NUL shown as '.') right after dir_open, before the scan
            ; loop runs -- bracketed against an identical dump right
            ; after a match is found (below), to catch exactly when
            ; LINE_BUF gets corrupted during a "found" (mode 0)
            ; file_open call. ren10.txt/ren11.txt proved COPY's
            ; destination string is already corrupted ("init5.rc" ->
            ; "ini ") by the time copy.asm reads it right after the
            ; SOURCE's own file_open call returns. SAFE pattern this
            ; time (see CLAUDE.md gotcha #14): copy into a scratch
            ; buffer using only str/lda (no BIOS call inside the
            ; loop), then a single f_msg call -- the previous attempt
            ; at this used a tight lda/call-f_tty loop and corrupted
            ; subsequent shell input on hardware (ren12.txt).
            mov     rf, LINE_BUF
            mov     rb, diag_lb_buf
            ldi     24
            plo     rc
diag_lb1_loop:
            lda     rf
            lbnz    diag_lb1_have
            ldi     '.'
diag_lb1_have:
            str     rb
            inc     rb
            dec     rc
            glo     rc
            lbnz    diag_lb1_loop
            ldi     0
            str     rb

            call    f_inmsg
            db      13,10,"DIAG linebuf pre-scan ='",0
            mov     rf, diag_lb_buf
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

fopen_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    fopen_notfound      ; end of directory: no match --
                                        ; dir_eptr/dir_cur_lba/dir_clust/
                                        ; dir_sect now describe the '$00'
                                        ; terminator's sector, reused
                                        ; directly by _file_create below

            ; compare entry name against fo_name (now the final
            ; path component resolved above, not the raw input)
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = saved name pointer
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    fopen_loop          ; no match: keep looking

            ; TEMPORARY DIAGNOSTIC: same LINE_BUF dump, now right
            ; after a match is found (before FCB population) -- see
            ; the bracket comment above dir_open's own dump
            mov     rf, LINE_BUF
            mov     rb, diag_lb_buf
            ldi     24
            plo     rc
diag_lb2_loop:
            lda     rf
            lbnz    diag_lb2_have
            ldi     '.'
diag_lb2_have:
            str     rb
            inc     rb
            dec     rc
            glo     rc
            lbnz    diag_lb2_loop
            ldi     0
            str     rb

            call    f_inmsg
            db      13,10,"DIAG linebuf post-match='",0
            mov     rf, diag_lb_buf
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

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

            ; BUG FIX: the old sequence was "ldi FCB_F_OPEN" then
            ; "mov rf, fo_mode" -- but that mov itself clobbers D
            ; (gotcha #4), and the following "ldn rf" overwrites D
            ; again with the raw MODE value, not FCB_F_OPEN. For mode 1
            ; this self-corrected by coincidence (mode value 1 happens
            ; to equal FCB_F_OPEN's own bit, and ORing FCB_F_WRITE onto
            ; it lands on the right answer), which is exactly why this
            ; went unnoticed through WTEST/ATEST. Mode 0 has no such
            ; luck: it branched straight to the store with D = 0, so
            ; every mode-0 open of an already-existing file left
            ; FCB_FLAGS = 0 -- the slot looked instantly free again,
            ; even while still legitimately open. Invisible with a
            ; single FCB in flight (TYPE), but COPY's second (mode 1)
            ; open then reused that "free" slot for the destination,
            ; silently aliasing both files onto one FCB. Fixed by
            ; computing the final flags value fresh via "ldi" in each
            ; branch, with no mov in between to clobber it.
            mov     rf, fo_mode
            ldn     rf
            lbz     fopen_mode_read     ; mode 0 = read-only
            ldi     FCB_F_OPEN | FCB_F_WRITE
            lbr     fopen_flags_done
fopen_mode_read:
            ldi     FCB_F_OPEN
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

            ; --- mode 2 (append): reposition FCB_CCLUST/CSECT/BOFF/
            ; FPOS to end-of-file, so writes append rather than
            ; overwrite from the start. No-op for an empty file
            ; (FSIZE == 0): position 0 is already correct there, and
            ; is exactly what file_write's own "no cluster yet"
            ; first-write branch expects (see file_write).
            mov     rf, fo_mode
            ldn     rf
            smi     2
            lbnz    fopen_no_append     ; not append mode

            mov     rf, fo_fcb
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = fcb slot base

            mov     rf, rb
            add16   rf, FCB_FSIZE
            add16   rf, 2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FSIZE (low word)

            glo     rd
            lbnz    fopen_append_have_size
            ghi     rd
            lbz     fopen_no_append     ; FSIZE == 0: nothing to do
fopen_append_have_size:
            sub16   rd, 1               ; RD = last_byte_index

            ; sector_index (0-127) = last_byte_index >> 9
            ;                       = (last_byte_index.hi) >> 1
            ghi     rd
            shr
            plo     rc                  ; RC.0 = sector_index

            ; boff (0-511) = last_byte_index & 511
            glo     rd
            plo     r8
            ghi     rd
            ani     1
            phi     r8                  ; R8 = boff
            mov     rf, fa_boff
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; fa_boff = boff (stashed --
                                        ; R8 is needed as scratch again
                                        ; below, before fat_get's own
                                        ; clobber makes this moot anyway)

            ; cluster_index (0-127) = sector_index >> spc_shift
            ;
            ; BUG FIX: this loop used to carry the partially-shifted
            ; value through D across iterations ("glo rc" once before
            ; the loop, then just "shr" each time) -- but the loop's
            ; OWN condition check ("glo r9", reading the shift
            ; counter) clobbers D on every iteration, including the
            ; first, before "shr" ever runs. So "shr" always ended up
            ; shifting the DECREMENTING COUNTER's own value, not
            ; sector_index, and since that counter always reaches 0
            ; through the very same shifts+decrements, the loop
            ; always produced cluster_index=0 regardless of the true
            ; sector_index -- for every spc value, not just spc=1
            ; (confirmed via a hardware diagnostic trace: sclust and
            ; the computed target cluster came out identical, i.e.
            ; zero hops, on a file whose size clearly needed
            ; several). Fixed by keeping the shifting value in a real
            ; register instead of D, reloading it into D fresh
            ; immediately before each "shr" and storing the result
            ; straight back, so the loop-condition check's own D
            ; clobber in between iterations can't touch it.
            ; RC.0 (sector_index) is still needed below, for
            ; sector_in_clust -- so R8 (free here; the earlier boff
            ; computation that used it has already been stashed to
            ; fa_boff in memory) is the shift accumulator instead,
            ; leaving RC untouched.
            mov     rf, bpb_spc_shift
            ldn     rf
            plo     r9                  ; R9.0 = spc_shift (loop count)
            glo     rc                  ; D = sector_index
            plo     r8                  ; R8.0 = shift accumulator
fa_cidx_shr:
            glo     r9
            lbz     fa_cidx_done
            glo     r8                  ; D = accumulator (reloaded
                                        ; fresh, not carried through
                                        ; the loop-condition check)
            shr
            plo     r8                  ; R8.0 = shifted value
            dec     r9
            lbr     fa_cidx_shr
fa_cidx_done:
            glo     r8                  ; D = cluster_index
            ; BUG FIX: "mov rf, fa_cluster_idx" itself clobbers D (its
            ; own final LDI leaves D = fa_cluster_idx's low address
            ; byte), so the shifted cluster_index just computed in D
            ; would not survive to "str rf" below unless stashed
            ; first -- same class of bug as _file_create's checksum
            ; fix. R9 is free here (its job as the shift-loop counter
            ; is done, having reached 0).
            plo     r9                  ; stash cluster_index
            mov     rf, fa_cluster_idx
            glo     r9                  ; D = cluster_index (reloaded)
            str     rf                  ; fa_cluster_idx = cluster_index

            ; sector_in_clust = sector_index & (spc-1)
            mov     rf, bpb_spc
            ldn     rf
            smi     1
            str     r2                  ; [R2] = spc-1 (mask)
            glo     rc                  ; D = sector_index (still in RC)
            and
            ; BUG FIX: same as above -- stash the AND result (RC's
            ; old sector_index value isn't needed again) before the
            ; "mov rf, fa_sector_in_clust" that would otherwise
            ; clobber D first.
            plo     rc
            mov     rf, fa_sector_in_clust
            glo     rc                  ; D = result (reloaded)
            str     rf                  ; fa_sector_in_clust = result

            ; --- walk fat_get fa_cluster_idx times from FCB_SCLUST ---
            mov     rf, rb
            add16   rf, FCB_SCLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FCB_SCLUST

            mov     rf, fa_cluster_idx
            ldn     rf
            plo     rc                  ; RC.0 = hops remaining
fa_walk_loop:
            glo     rc
            lbz     fa_walk_done
            push    r9
            push    ra
            push    rb
            push    rc
            call    fat_get             ; RD = next cluster
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fopen_no_append     ; I/O error: leave the FCB at
                                        ; its default position-0 state
            dec     rc
            lbr     fa_walk_loop
fa_walk_done:
            ; RD = target cluster

            ; --- new position = one past the last valid byte ---
            mov     rf, fa_boff
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = boff
            add16   r8, 1               ; R8 = new_boff (1-512)

            mov     rf, fa_sector_in_clust
            ldn     rf
            plo     r9                  ; R9.0 = new_csect

            ghi     r8
            xri     2
            lbnz    fa_no_sector_wrap
            glo     r8
            lbnz    fa_no_sector_wrap
            ldi     0
            phi     r8
            plo     r8                  ; new_boff wrapped to 0
            glo     r9
            adi     1
            plo     r9                  ; new_csect += 1
fa_no_sector_wrap:
            ; RD = target cluster, R9.0 = new_csect, R8 = new_boff

            mov     rf, fo_fcb
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = fcb slot base (reload --
                                        ; the fat_get walk clobbered it)

            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; FCB_CCLUST = target cluster

            mov     rf, rb
            add16   rf, FCB_CSECT
            glo     r9
            str     rf                  ; FCB_CSECT = new_csect

            mov     rf, rb
            add16   rf, FCB_BOFF
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; FCB_BOFF = new_boff

            mov     rf, rb
            add16   rf, FCB_FSIZE
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = FSIZE (low word)
            mov     rf, rb
            add16   rf, FCB_FPOS
            add16   rf, 2
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; FCB_FPOS (low word) = FSIZE

fopen_no_append:
            mov     rf, fo_handle
            ldn     rf                  ; D = FCB index (handle)
            clc                         ; DF = 0, success
            rtn

fopen_notfound:
            ; not found -- attempt to create a new, empty file if the
            ; open mode allows it (mode 0 = read-only: no creation)
            mov     rf, fo_mode
            ldn     rf
            lbz     fopen_err

            ; _file_create writes whatever attribute/initial-cluster/
            ; size fc_new_attr/fc_new_cluster/fc_new_size hold --
            ; file_open always wants a plain, empty file (ATTR_ARCHIVE,
            ; cluster 0 = lazily allocated on first write, size 0).
            ; dir_create (MD) and file_rename (REN) reuse the same
            ; entry-insertion machinery with different values.
            mov     rf, fc_new_attr
            ldi     ATTR_ARCHIVE
            str     rf
            mov     rf, fc_new_cluster
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, fc_new_size
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            call    _file_create        ; DF = 0/1; on success,
                                        ; fc_elba/fc_eoff = the new
                                        ; short entry's location
            lbdf    fopen_err

            ; --- populate the FCB for the newly created, empty file
            ; -- SCLUST/CCLUST/CSECT/BOFF/FSIZE/FPOS are simply zero,
            ; nothing to read back from disk. Mode 2 (append) needs no
            ; special positioning here either: end-of-file on a
            ; brand-new empty file IS position 0. ---
            mov     rf, fo_fcb
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = fcb slot base pointer

            ldi     FCB_F_OPEN
            ori     FCB_F_WRITE
            str     rb
            inc     rb                  ; FCB_FLAGS

            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_SCLUST = 0

            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_CCLUST = 0

            str     rb
            inc     rb                  ; FCB_CSECT = 0

            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_BOFF = 0

            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_FSIZE = 0

            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_FPOS = 0

            mov     rf, fc_elba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_ELBA = fc_elba

            mov     rf, fc_eoff
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_EOFF = fc_eoff

            mov     rf, fo_handle
            ldn     rf
            clc
            rtn

fopen_err:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; _classify_char: classify+transform one character for 8.3 short-
; name generation.
;
; Args:    D  = input character
; Returns: D  = transformed character (uppercased if it was a-z,
;               '_' if it was anything else outside the safe set,
;               otherwise unchanged)
;          DF = 0 if the character was already safe/clean (A-Z,
;               0-9, '_', '-'), DF = 1 if it forced a transform
;               (lowercase, or replaced with '_')
; Modifies: nothing but D/DF (uses [R2] as scratch -- the byte just
; below the current stack top, per this codebase's established
; str-r2-as-scratch convention; safe even when called from inside
; another call, since R2 always points at the next FREE slot, never
; at live pushed data)
; ----------------------------------------------------------------
            proc    _classify_char

            str     r2                  ; [R2] = original char

            ; lowercase a-z?
            smi     'a'
            lbnf    cc_check_upper      ; D < 'a'
            ldn     r2
            smi     'z'+1
            lbdf    cc_check_upper      ; D > 'z'
            ldn     r2
            smi     $20                 ; uppercase it
            stc
            rtn

cc_check_upper:
            ldn     r2
            smi     'A'
            lbnf    cc_check_digit
            ldn     r2
            smi     'Z'+1
            lbdf    cc_check_digit
            ldn     r2
            clc
            rtn

cc_check_digit:
            ldn     r2
            smi     '0'
            lbnf    cc_check_special
            ldn     r2
            smi     '9'+1
            lbdf    cc_check_special
            ldn     r2
            clc
            rtn

cc_check_special:
            ldn     r2
            xri     '_'
            lbz     cc_safe_asis
            ldn     r2
            xri     '-'
            lbz     cc_safe_asis
            ldi     '_'
            stc
            rtn

cc_safe_asis:
            ldn     r2
            clc
            rtn

            endp

; ----------------------------------------------------------------
; _lfn_fill_segment: fill one 2-byte-per-char field of an LFN entry
; (UTF-16LE, ASCII-only: high byte always 0) from the name, tracking
; state shared across the 3 segments (5+6+2 chars) of one entry.
;
; Args:    RF = destination (this segment's start within the entry)
;          RD.0 = segment length (5, 6, or 2)
;          RA = source name pointer (advances as real chars are used)
;          RC.0 = real characters remaining for this whole entry
;          R9.0 = 1 once the U+0000 terminator has been emitted
;                 (0 the first time this is called for a given entry)
; Returns: RA/RC.0/R9.0 updated, ready for the next segment call
; Modifies: RD.0, RF (RD.1/RA/RC.0/R9.0 are the "returned" state)
; ----------------------------------------------------------------
            proc    _lfn_fill_segment

lfs_loop:
            glo     rd
            lbz     lfs_done

            glo     rc
            lbz     lfs_after_real

            lda     ra                  ; D = next real char, RA++
            str     rf
            inc     rf
            ldi     0
            str     rf
            inc     rf
            dec     rc
            lbr     lfs_next

lfs_after_real:
            glo     r9
            lbnz    lfs_pad

            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            ldi     1
            plo     r9
            lbr     lfs_next

lfs_pad:
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            inc     rf

lfs_next:
            dec     rd
            lbr     lfs_loop

lfs_done:
            rtn

            endp

; ----------------------------------------------------------------
; _gen_short_name: generate an 11-byte 8.3 short name from an
; arbitrary (possibly long/lowercase/multi-dot) source name.
;
; Splits at the LAST '.' for name/extension. If the name already
; fits cleanly as an uppercase 8.3 name (name part 1-8 chars,
; extension 0-3 chars, single dot, only A-Z/0-9/_/- characters),
; fc_shortname is exactly that, space-padded, and fc_needs_lfn = 0.
; Otherwise fc_needs_lfn = 1 and fc_shortname is a best-effort
; fallback (first 8/3 safe characters, uppercased, unsafe chars
; replaced with '_'). Deliberately does NOT check the generated
; short name against existing entries for uniqueness -- see
; _file_create's header comment for why that's safe to skip here
; (this system never looks up files by their raw short name, only
; by dir_read's LFN-preferred name).
;
; Two passes over the name/extension: the first only classifies
; characters (to finish deciding fc_needs_lfn, since a character
; found partway through could still force it even if the lengths
; were fine); the second copies/transforms using that final,
; settled decision. Kept as two separate passes deliberately --
; interleaving a mid-copy write to fc_needs_lfn while D still held
; a just-classified character to copy would clobber it before the
; copy's own str, the same class of bug as CLAUDE.md's mov/add16-
; clobbers-D gotcha applied to a call instead.
;
; Args:    RD = pointer to source name (null-terminated)
; Returns: RD = source name length (namelen)
;          fc_shortname (11 bytes) and fc_needs_lfn set
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    _gen_short_name

            ; --- scan the whole name once: compute namelen and the
            ; position of the LAST '.' (if any, into RB) ---
            mov     ra, rd              ; RA = name start
            mov     rf, rd              ; RF = scan cursor
            ldi     0
            plo     r9                  ; R9.0 = 1 once a '.' is seen
gsn_scan:
            ldn     rf
            lbz     gsn_scan_done
            xri     '.'
            lbnz    gsn_scan_next
            mov     rb, rf              ; remember the (so far) last '.'
            ldi     1
            plo     r9
gsn_scan_next:
            inc     rf
            lbr     gsn_scan
gsn_scan_done:
            ; RF = one past the last char (points at the null)
            mov     rd, rf
            sub16   rd, ra              ; RD = namelen

            ; --- split into namepart [RA,RC) and ext [R9,R8) ---
            glo     r9
            lbz     gsn_no_dot

            mov     rc, rb
            sub16   rc, ra              ; RC = namepart_len
            mov     r9, rb
            inc     r9                  ; R9 = ext start
            mov     r8, rf
            sub16   r8, r9              ; R8 = ext_len
            lbr     gsn_have_parts

gsn_no_dot:
            mov     rc, rd              ; RC = namepart_len = namelen
            mov     r9, rf              ; R9 = ext start (empty ext)
            ldi     0
            phi     r8
            plo     r8                  ; R8 = ext_len = 0

gsn_have_parts:
            ; RA = namepart start, RC = namepart_len
            ; R9 = ext start,      R8 = ext_len
            ; RD = namelen (preserved as the return value throughout)

            mov     rf, fc_needs_lfn
            ldi     0
            str     rf

            glo     rc
            lbz     gsn_force_lfn       ; namepart_len == 0 (e.g. ".foo")
            ghi     rc
            lbnz    gsn_force_lfn
            glo     rc
            smi     9
            lbdf    gsn_force_lfn       ; namepart_len > 8

            ghi     r8
            lbnz    gsn_force_lfn
            glo     r8
            smi     4
            lbdf    gsn_force_lfn       ; ext_len > 3

            lbr     gsn_lengths_ok

gsn_force_lfn:
            mov     rf, fc_needs_lfn
            ldi     1
            str     rf

gsn_lengths_ok:
            ; --- Pass 1: does any character force needs_lfn, beyond
            ; what the length checks above already decided? Skip
            ; entirely if already forced. ---
            mov     rf, fc_needs_lfn
            ldn     rf
            lbnz    gsn_skip_charscan

            push    ra
            push    rc

            mov     rb, ra              ; RB = scan cursor (namepart)
            ghi     rc
            phi     r7
            glo     rc
            plo     r7                  ; R7 = namepart_len (countdown)
gsn_scan_name_chars:
            glo     r7
            lbnz    gsn_scan_name_have
            ghi     r7
            lbz     gsn_scan_name_done
gsn_scan_name_have:
            lda     rb
            call    _classify_char      ; DF = forced?
            lbnf    gsn_scan_name_next
            mov     rf, fc_needs_lfn
            ldi     1
            str     rf
gsn_scan_name_next:
            dec     r7
            lbr     gsn_scan_name_chars
gsn_scan_name_done:

            mov     rb, r9              ; RB = scan cursor (ext)
            ghi     r8
            phi     r7
            glo     r8
            plo     r7                  ; R7 = ext_len (countdown)
gsn_scan_ext_chars:
            glo     r7
            lbnz    gsn_scan_ext_have
            ghi     r7
            lbz     gsn_scan_ext_done
gsn_scan_ext_have:
            lda     rb
            call    _classify_char
            lbnf    gsn_scan_ext_next
            mov     rf, fc_needs_lfn
            ldi     1
            str     rf
gsn_scan_ext_next:
            dec     r7
            lbr     gsn_scan_ext_chars
gsn_scan_ext_done:

            pop     rc
            pop     ra

gsn_skip_charscan:
            ; --- Pass 2: build fc_shortname using the now-settled
            ; needs_lfn (no further writes to it from here on, so
            ; each char's transformed value can go straight from
            ; _classify_char's D into the destination) ---
            mov     rf, fc_shortname

            mov     rb, ra              ; RB = namepart cursor
            ghi     rc
            phi     r7
            glo     rc
            plo     r7                  ; R7 = namepart_len (countdown)
            ldi     8
            plo     rc                  ; RC.0 = slots remaining (8)
gsn_build_name:
            glo     rc
            lbz     gsn_build_name_done
            glo     r7
            lbnz    gsn_build_name_have
            ghi     r7
            lbz     gsn_build_name_pad
gsn_build_name_have:
            lda     rb
            call    _classify_char      ; D = transformed char
            str     rf
            inc     rf
            dec     r7
            dec     rc
            lbr     gsn_build_name
gsn_build_name_pad:
            ldi     ' '
            str     rf
            inc     rf
            dec     rc
            lbr     gsn_build_name
gsn_build_name_done:

            mov     rb, r9              ; RB = ext cursor
            ghi     r8
            phi     r7
            glo     r8
            plo     r7                  ; R7 = ext_len (countdown)
            ldi     3
            plo     rc                  ; RC.0 = slots remaining (3)
gsn_build_ext:
            glo     rc
            lbz     gsn_build_ext_done
            glo     r7
            lbnz    gsn_build_ext_have
            ghi     r7
            lbz     gsn_build_ext_pad
gsn_build_ext_have:
            lda     rb
            call    _classify_char
            str     rf
            inc     rf
            dec     r7
            dec     rc
            lbr     gsn_build_ext
gsn_build_ext_pad:
            ldi     ' '
            str     rf
            inc     rf
            dec     rc
            lbr     gsn_build_ext
gsn_build_ext_done:

            rtn                         ; RD (namelen) still valid,
                                        ; untouched since computed

            endp

; ----------------------------------------------------------------
; _file_create: create a new, empty directory entry for fo_name
; within the CURRENT directory search state, generating LFN entries
; if the name isn't already a clean uppercase 8.3 name.
;
; Called only when file_open's own directory scan (fopen_loop) just
; reached end-of-directory (dir_read returned DF=1) without a match
; -- at that exact moment dir_eptr/dir_cur_lba/dir_clust/dir_sect
; describe the sector holding the '$00' end-of-directory terminator
; (see dir.asm), which is reused directly as the insertion point
; rather than re-scanning the directory a second time. This is also
; why no parent-cluster argument is needed here: dir_clust already
; holds it (and, for a multi-cluster subdirectory, correctly holds
; whichever cluster in the chain the terminator actually landed in,
; not necessarily the first one).
;
; New entries always go at/after that terminator, never reusing an
; earlier deleted ('$E5') slot -- a deliberate simplification: this
; system has no DEL/REN yet, so no such gap can currently exist from
; ELF-DOS's own use (only conceivably from an external tool, in
; which case the slot is simply never reclaimed).
;
; The generated short name is also not checked against existing
; entries for uniqueness (no numeric-tail collision handling like
; real DOS's "NAME~1.EXT"). This is safe here specifically because
; this system never looks up a file by its raw short name -- every
; lookup (file_open, CD, path_resolve) compares against dir_read's
; LFN-preferred name, and dir_read never cross-associates an LFN set
; with the wrong short entry (each short entry's checksum is only
; ever compared against the LFN group immediately preceding it on
; disk), so two different names coincidentally generating the same
; short name doesn't create any lookup ambiguity in ELF-DOS itself
; -- only a (currently moot) compatibility wrinkle for hypothetical
; strict-8.3 external tools.
;
; If the N entries needed (LFN + short) don't fit in the remaining
; space of the terminator's own sector, this moves to the START of
; the NEXT sector instead (wasting the small remainder of the old
; one, which stays zero and harmless) rather than splitting a write
; across a sector boundary -- always safe since N is at most 11
; entries (127-char name) and a sector holds 16. For a subdirectory,
; if the terminator's sector was the last one in the chain, a new
; cluster is allocated and linked. For the root directory (fixed
; size, cannot grow), running out of space is a hard failure.
;
; A sector immediately following the terminator's sector -- whether
; already part of the chain or a freshly allocated cluster -- is
; trusted to be entirely zero already (the same invariant a '$00'
; terminator always relies on); freshly allocated clusters are
; explicitly zeroed here since nothing else has, but an existing
; already-allocated-but-unused sector is trusted as-is, matching how
; every well-behaved FAT tool (this one included) maintains that
; invariant.
;
; Args:    none (reads fo_name, and dir.asm's current traversal
;          state, directly)
; Returns: DF = 0 on success (fc_elba/fc_eoff = the new short
;          entry's on-disk sector LBA + byte offset, for
;          FCB_ELBA/FCB_EOFF -- same convention as dir_cur_lba/
;          dir_last_off)
;          DF = 1 on error (directory full, or I/O error)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    _file_create

            ; --- generate the 8.3 short name + namelen ---
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    _gen_short_name     ; fc_shortname/fc_needs_lfn set;
                                        ; RD = namelen
            mov     rf, fc_namelen
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- lfn_count = needs_lfn ? ceil(namelen/13) : 0 ---
            mov     rf, fc_needs_lfn
            ldn     rf
            lbz     fc_no_lfn

            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = namelen remaining
            ldi     0
            plo     r9                  ; R9.0 = lfn_count accumulator
fc_count_loop:
            ghi     r8
            lbnz    fc_count_more
            glo     r8
            smi     13
            lbnf    fc_count_last       ; remaining < 13: last entry
            lbz     fc_count_last       ; remaining == 13: last entry
fc_count_more:
            ghi     r8
            phi     rd
            glo     r8
            plo     rd
            sub16   rd, 13
            ghi     rd
            phi     r8
            glo     rd
            plo     r8
            glo     r9
            adi     1
            plo     r9
            lbr     fc_count_loop
fc_count_last:
            glo     r9
            adi     1
            plo     r9
            lbr     fc_have_count

fc_no_lfn:
            ldi     0
            plo     r9

fc_have_count:
            mov     rf, fc_lfncount
            glo     r9
            str     rf                  ; fc_lfncount = lfn_count

            ; N = lfn_count + 1 (32-byte slots needed); stash at [R2]
            glo     r9
            adi     1
            str     r2

            ; --- does N fit in the terminator's own sector? ---
            ; sum = term_off + N*32
            ldi     0
            phi     rd
            ldn     r2                  ; D = N
            plo     rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd                  ; RD = N*32

            mov     rf, dir_eptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = dir_eptr
            mov     rf, dir_buf
            sub16   r8, rf              ; R8 = term_off
            add16   rd, r8              ; RD = term_off + N*32 (sum)

            mov     r8, rd              ; R8 = sum
            ldi     2
            phi     rd
            ldi     0
            plo     rd                  ; RD = 512
            sub16   rd, r8              ; RD = 512 - sum, DF=1 if it fits
            lbnf    fc_next_sector      ; doesn't fit

;------------------------------------------------------------------
; Fits: use the already-loaded dir_buf directly at term_off
;------------------------------------------------------------------
fc_use_current:
            mov     rf, dir_eptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dir_eptr value
            mov     rf, dir_buf
            sub16   rd, rf              ; RD = term_off
            mov     rf, fc_target_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, dir_cur_lba
            mov     rb, fc_target_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            lbr     fc_write_entries

;------------------------------------------------------------------
; Doesn't fit: advance to the next sector (following the chain, or
; allocating+linking a new cluster if at end-of-chain; root can't
; grow, so failure there is final)
;------------------------------------------------------------------
fc_next_sector:
            ; BUG FIX: a '$00' terminator means "end of directory"
            ; wherever a scan (dir_read) meets it -- including in an
            ; EARLIER sector than the one we're about to write into.
            ; Moving to the next sector while leaving the old
            ; terminator (and everything after it in THIS sector)
            ; untouched made every future scan stop right there,
            ; before ever reaching the next sector -- confirmed: the
            ; new entry was written successfully (per the diagnostic
            ; trace) but was permanently invisible to DIR/TYPE/
            ; file_open afterward. Fix: overwrite the rest of this
            ; sector, from the old terminator onward, with '$E5'
            ; (deleted-entry markers, which dir_read explicitly skips
            ; over rather than treating as "end") before advancing.
            mov     rf, dir_eptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dir_eptr value
            mov     rf, dir_buf
            sub16   rd, rf              ; RD = term_off
            mov     rf, dir_buf
            add16   rf, rd              ; RF = dir_buf + term_off

            mov     r8, rd
            ldi     2
            phi     rd
            ldi     0
            plo     rd                  ; RD = 512
            sub16   rd, r8              ; RD = 512 - term_off (count)
fc_mark_deleted:
            ghi     rd
            lbnz    fc_mark_have
            glo     rd
            lbz     fc_mark_done
fc_mark_have:
            ldi     $E5
            str     rf
            inc     rf
            sub16   rd, 1
            lbr     fc_mark_deleted
fc_mark_done:
            ; write the patched old sector back before moving on
            mov     rf, dir_cur_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, dir_buf
            call    f_idewrite
            lbdf    fc_full

            call    _dir_next_sector    ; DF=0: dir_buf/dir_cur_lba
                                        ; hold the next sector's real
                                        ; content (trusted all-zero);
                                        ; DF=1: end of chain / root
                                        ; bound reached
            lbnf    fc_next_ok

            mov     rf, dir_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dir_clust (0 = root)
            ghi     rd
            lbnz    fc_grow
            glo     rd
            lbz     fc_full             ; dir_clust == 0: root is full

fc_grow:
            ; RD = dir_clust = the last (old) cluster of the chain
            call    fat_alloc           ; RD = new cluster; DF=0/1
            lbdf    fc_full

            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = new cluster

            mov     rf, dir_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = old cluster

            ghi     r8
            phi     rb
            glo     r8
            plo     rb                  ; RB = new cluster (fat_set's
                                        ; value arg)
            call    fat_set             ; RD=old, RB=new; DF=0/1
            lbdf    fc_full

            mov     rf, dir_clust
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; dir_clust = new cluster

            mov     rf, dir_sect
            ldi     0
            str     rf                  ; dir_sect = 0

            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = new cluster
            call    _cluster_to_lba     ; R7/R8 = LBA

            mov     rf, dir_cur_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; dir_cur_lba = new LBA

            ; BUG FIX: flush the FAT immediately, the same way
            ; dir_create (MD) already does after its own fat_alloc --
            ; fat_alloc's "claim" (marking the new cluster end-of-chain)
            ; and fat_set's link only live in the single-sector FAT
            ; cache until flushed. If anything later in this same
            ; session needs a DIFFERENT FAT sector before this one is
            ; flushed, the cache evicts it unwritten, silently
            ; reverting the claim -- so the next fat_alloc scan sees
            ; this cluster as free again and can hand it out a SECOND
            ; time. Confirmed on hardware via fsck: "/cfg and
            ; /cfg/env3.dat share clusters" and a duplicate
            ; /wordle/wordlist.txt entry, both after a directory grew
            ; past its first cluster (fc_grow) during a REN/COPY/WTEST
            ; test session -- this path was very likely never
            ; exercised on real hardware before that session, since it
            ; only fires once a directory's own entries fill an entire
            ; sector. Placed here, after dir_clust/dir_sect/dir_cur_lba
            ; are ALL already safely committed to memory and R7/R8 are
            ; no longer needed, rather than right after fat_set -- an
            ; earlier draft of this fix called it there, before
            ; realizing fat_flush's own documented clobber list
            ; (R7/R8/R9/RB/RC/RD/RF) includes R8, which still held the
            ; new cluster number needed for the dir_clust/LBA steps
            ; just above.
            call    fat_flush
            lbdf    fc_full

            ; zero-fill dir_buf: a freshly allocated cluster holds
            ; disk garbage, not zero, until something writes it
            mov     rf, dir_buf
            ldi     $02
            phi     rc
            ldi     $00
            plo     rc                  ; RC = 512 = SECTOR_SIZE
fc_zero_loop:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            ghi     rc
            lbnz    fc_zero_loop
            glo     rc
            lbnz    fc_zero_loop

            mov     rf, fc_target_off
            ldi     0
            str     rf
            inc     rf
            str     rf

            mov     rf, dir_cur_lba
            mov     rb, fc_target_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            lbr     fc_write_entries

fc_next_ok:
            mov     rf, fc_target_off
            ldi     0
            str     rf
            inc     rf
            str     rf

            mov     rf, dir_cur_lba
            mov     rb, fc_target_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            lbr     fc_write_entries

fc_full:
            stc                         ; DF = 1, directory full / error
            rtn

;------------------------------------------------------------------
; Write the LFN entries (if any, highest sequence number first,
; starting at fc_target_off) followed by the short entry, a fresh
; terminator, then write the sector back.
;------------------------------------------------------------------
fc_write_entries:
            ; TEMPORARY DIAGNOSTIC: compare THIS call's target
            ; location (fc_target_lba/fc_target_off) against the
            ; PREVIOUS _file_create call's -- investigating whether
            ; consecutive calls (e.g. REN's insertion followed by a
            ; later WTEST) land at the same spot
            mov     rf, fc_diag_last_lba
            lda     rf
            str     r2
            mov     rd, fc_target_lba
            ldn     rd
            sm
            lbnz    diag_fc_lba_diff

            mov     rf, fc_diag_last_lba
            inc     rf
            ldn     rf
            str     r2
            mov     rd, fc_target_lba
            inc     rd
            ldn     rd
            sm
            lbnz    diag_fc_lba_diff

            mov     rf, fc_diag_last_lba
            add16   rf, 2
            ldn     rf
            str     r2
            mov     rd, fc_target_lba
            add16   rd, 2
            ldn     rd
            sm
            lbnz    diag_fc_lba_diff

            call    f_inmsg
            db      13,10,"DIAG fc: lba SAME-as-last",0
            lbr     diag_fc_lba_done
diag_fc_lba_diff:
            call    f_inmsg
            db      13,10,"DIAG fc: lba diff-from-last",0
diag_fc_lba_done:
            mov     rf, fc_diag_last_off
            lda     rf
            str     r2
            mov     rd, fc_target_off
            ldn     rd
            sm
            lbnz    diag_fc_off_diff

            mov     rf, fc_diag_last_off
            inc     rf
            ldn     rf
            str     r2
            mov     rd, fc_target_off
            inc     rd
            ldn     rd
            sm
            lbnz    diag_fc_off_diff

            call    f_inmsg
            db      " off SAME-as-last",13,10,0
            lbr     diag_fc_off_done
diag_fc_off_diff:
            call    f_inmsg
            db      " off diff-from-last",13,10,0
diag_fc_off_done:
            ; update the "last" stored values for next time
            mov     rf, fc_target_lba
            mov     rb, fc_diag_last_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            mov     rf, fc_target_off
            mov     rb, fc_diag_last_off
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            ; END TEMPORARY DIAGNOSTIC

            mov     rf, fc_shortname
            call    _dir_chksum         ; D = checksum
            ; BUG FIX: "mov rf, fc_checksum" itself clobbers D (its
            ; own final LDI leaves D = fc_checksum's low address
            ; byte), so the checksum just returned in D would not
            ; survive to "str rf" below unless stashed first -- the
            ; same class of bug as drd_got_name's attribute write and
            ; _dir_chksum's own internal fix (see dir.asm). This
            ; silently wrote a byte derived from fc_checksum's own
            ; address instead of the real checksum, so every LFN
            ; entry's stored checksum never matched the short entry
            ; it belonged with -- dir_read's checksum validation
            ; always failed and silently fell back to the raw 8.3
            ; short name (confirmed: DIR/TYPE only ever saw the
            ; uppercase short name, never the real lowercase/long
            ; name, for any newly created file needing an LFN).
            plo     rc                  ; stash checksum (RC free here)
            mov     rf, fc_checksum
            glo     rc                  ; D = checksum (reloaded)
            str     rf

            mov     rf, dir_buf
            mov     r8, rf
            mov     rf, fc_target_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   r8, rd              ; R8 = dir_buf + fc_target_off

            mov     rf, fc_lfncount
            ldn     rf
            lbz     fc_write_short      ; lfn_count == 0: no LFN needed
            plo     rb                  ; RB.0 = seq (starts = lfn_count)

fc_lfn_loop:
            ; --- char_offset (RD) = (seq-1)*13 ---
            glo     rb
            smi     1
            plo     rc
            ldi     0
            phi     rd
            plo     rd
fc_mul13:
            glo     rc
            lbz     fc_mul13_done
            add16   rd, 13
            dec     rc
            lbr     fc_mul13
fc_mul13_done:
            ; RD = char_offset

            ; --- zero this entry's 32 bytes ---
            mov     rf, r8
            ldi     32
            plo     rc
fc_zero_entry:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    fc_zero_entry

            ; --- chars_in_this_entry = min(13, namelen-char_offset) ---
            mov     rf, fc_namelen
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = namelen
            sub16   r7, rd              ; R7 = namelen - char_offset
            glo     r7
            smi     13
            lbnf    fc_chars_ok
            ghi     r7
            lbnz    fc_chars_ok
            ldi     13
            plo     r7
fc_chars_ok:
            glo     r7
            plo     rc                  ; RC.0 = chars_in_this_entry

            ; --- RA = name pointer + char_offset ---
            mov     rf, fo_name
            lda     rf
            phi     ra
            ldn     rf
            plo     ra
            add16   ra, rd

            ; --- LFN_SEQ (with LFN_LAST on the highest seq, i.e. the
            ; first entry written) ---
            mov     rf, r8
            add16   rf, LFN_SEQ
            mov     r9, fc_lfncount
            ldn     r9
            str     r2
            glo     rb
            sm                          ; D = seq - lfn_count
            lbnz    fc_seq_notlast
            glo     rb
            ori     LFN_LAST
            lbr     fc_seq_store
fc_seq_notlast:
            glo     rb
fc_seq_store:
            str     rf

            mov     rf, r8
            add16   rf, LFN_ATTR
            ldi     ATTR_LFN
            str     rf

            mov     rf, r8
            add16   rf, LFN_CHKSUM
            mov     r9, fc_checksum
            ldn     r9
            str     rf

            ldi     0
            plo     r9                  ; emitted_null = 0 (fresh
                                        ; per entry)
            mov     rf, r8
            add16   rf, LFN_NAME1
            ldi     5
            plo     rd
            call    _lfn_fill_segment

            mov     rf, r8
            add16   rf, LFN_NAME2
            ldi     6
            plo     rd
            call    _lfn_fill_segment

            mov     rf, r8
            add16   rf, LFN_NAME3
            ldi     2
            plo     rd
            call    _lfn_fill_segment

            add16   r8, 32
            glo     rb
            smi     1
            plo     rb
            lbnz    fc_lfn_loop

fc_write_short:
            ; R8 = address of the short entry's 32 bytes in dir_buf
            mov     rf, r8
            ldi     32
            plo     rc
fc_zero_short:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    fc_zero_short

            mov     rf, r8
            mov     ra, fc_shortname
            ldi     11
            plo     rc
fc_copy_shortname:
            lda     ra
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    fc_copy_shortname

            mov     rf, r8
            add16   rf, DE_ATTR
            mov     r9, fc_new_attr
            ldn     r9
            str     rf

            ; --- DE_CLUSTER (2 bytes, little-endian on disk) from
            ; fc_new_cluster (big-endian in memory, same convention as
            ; every other scratch cluster field in this file). Files
            ; leave this 0 (file_write lazily allocates the first
            ; cluster on first write); dir_create (MD) sets it to the
            ; already-allocated, already-initialized cluster. RA is
            ; free here -- its later reuse (packed-time stash) is well
            ; after this point. ---
            mov     rf, r8
            add16   rf, DE_CLUSTER
            mov     r9, fc_new_cluster
            lda     r9
            phi     ra
            ldn     r9
            plo     ra                  ; RA = fc_new_cluster
            glo     ra                  ; D = cluster low byte (LE first)
            str     rf
            inc     rf
            ghi     ra                  ; D = cluster high byte
            str     rf

            ; --- DE_SIZE (4 bytes, little-endian on disk) from
            ; fc_new_size (big-endian in memory, same convention as
            ; FCB_FSIZE/_fclose_rewrite_size's own copy). Files and
            ; newly created directories both leave this 0; file_rename
            ; (REN) sets it to the renamed entry's existing size,
            ; preserving it across the delete+recreate. RC/RD are free
            ; here (their earlier use as loop counters above is done). ---
            mov     r9, fc_new_size
            lda     r9                  ; D = size byte 0 (MSB)
            plo     rc
            lda     r9                  ; D = size byte 1
            phi     rc
            lda     r9                  ; D = size byte 2
            plo     rd
            ldn     r9                  ; D = size byte 3 (LSB)
            phi     rd                  ; RC = bytes 0,1; RD = bytes 2,3

            mov     rf, r8
            add16   rf, DE_SIZE
            ghi     rd                  ; D = size byte 3 (LSB) -> first
            str     rf
            inc     rf
            glo     rd                  ; D = size byte 2
            str     rf
            inc     rf
            ghi     rc                  ; D = size byte 1
            str     rf
            inc     rf
            glo     rc                  ; D = size byte 0 (MSB) -> last
            str     rf

            ; --- write time/date (DE_WRTTIME/DE_WRTDATE, 2+2 bytes,
            ; little-endian) with the current time ---
            push    r8                  ; entry base -- rtc_refresh/
                                        ; _pack_fat_datetime clobber
                                        ; registers freely
            call    rtc_refresh
            call    _pack_fat_datetime  ; RD = packed date, R8 = packed time
            mov     r9, rd              ; R9 = packed date (stash)
            mov     ra, r8              ; RA = packed time (stash; RA's
                                        ; earlier use as the shortname-copy
                                        ; cursor is long done by this point)
            pop     r8                  ; R8 = entry base (restored)

            mov     rf, r8
            add16   rf, DE_WRTTIME
            glo     ra                  ; D = packed time low byte
            str     rf
            inc     rf
            ghi     ra                  ; D = packed time high byte
            str     rf                  ; DE_WRTTIME (LE) written

            mov     rf, r8
            add16   rf, DE_WRTDATE
            glo     r9                  ; D = packed date low byte
            str     rf
            inc     rf
            ghi     r9                  ; D = packed date high byte
            str     rf                  ; DE_WRTDATE (LE) written

            ; --- record the short entry's on-disk location ---
            mov     rf, fc_target_lba
            mov     rd, fc_elba
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd

            mov     rf, dir_buf
            mov     rd, r8
            sub16   rd, rf              ; RD = short entry's offset
            mov     rf, fc_eoff
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- fresh '$00' terminator right after, unless our
            ; entries exactly filled the sector (offset == 512) ---
            add16   r8, 32
            mov     rf, dir_buf
            mov     rd, r8
            sub16   rd, rf              ; RD = offset just past our entries
            ghi     rd
            xri     2
            lbnz    fc_write_term
            glo     rd
            lbnz    fc_write_term
            lbr     fc_no_term
fc_write_term:
            ldi     0
            str     r8
fc_no_term:

            ; --- write the sector back ---
            mov     rf, fc_target_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, dir_buf
            call    f_idewrite
            lbdf    fc_full

            clc                         ; DF = 0, success
            rtn

            endp

; ----------------------------------------------------------------
; file_close: flush and release an FCB slot
; Args:   D = FCB index
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------

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
                                        ; (_fclose_rewrite_size's own
                                        ; header documents RD as one of
                                        ; the registers it clobbers)
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
; _fclose_rewrite_size: rewrite an FCB's directory entry size,
; first-cluster, and write-time/date fields on disk, copying
; FCB_FSIZE to DE_SIZE, FCB_SCLUST to DE_CLUSTER, and the current
; time (via rtc_refresh/_pack_fat_datetime) to DE_WRTTIME/DE_WRTDATE,
; at the sector/offset recorded in FCB_ELBA/FCB_EOFF.
;
; DE_CLUSTER is rewritten unconditionally alongside DE_SIZE whenever
; FCB_F_SIZECHG is set, even though most of the time (a plain append/
; overwrite of an already-existing file) FCB_SCLUST hasn't actually
; changed -- rewriting it to the same value it already holds is
; harmless. This covers file_write's "FCB_CCLUST was 0" first-write
; branch (a newly created file's first cluster, allocated lazily)
; without needing a second flag to distinguish the two cases.
;
; Args:    RD = FCB slot base address
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RB, RC, RD, RF
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

            ; --- also patch DE_CLUSTER (2 bytes, little-endian) from
            ; FCB_SCLUST (2 bytes, big-endian) -- reload everything
            ; fresh, since RF/RD/R9 above are all stale for this ---
            mov     rf, fcrw_slot
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FCB slot base

            mov     r9, rd
            add16   r9, FCB_EOFF
            lda     r9
            phi     r8
            ldn     r9
            plo     r8                  ; R8 = FCB_EOFF value

            mov     rf, dirent_patch_buf
            add16   rf, r8
            add16   rf, DE_CLUSTER      ; RF -> entry's 2-byte cluster field

            mov     r9, rd
            add16   r9, FCB_SCLUST      ; R9 -> FCB_SCLUST (big-endian)
            lda     r9                  ; D = SCLUST high byte, R9 -> low byte
            plo     rc                  ; RC.0 = SCLUST high byte (stash)
            ldn     r9                  ; D = SCLUST low byte
            str     rf                  ; DE_CLUSTER low byte (LE)
            inc     rf
            glo     rc                  ; D = SCLUST high byte (reloaded)
            str     rf                  ; DE_CLUSTER high byte (LE)

            ; --- also patch DE_WRTTIME/DE_WRTDATE (2+2 bytes, LE) with
            ; the current time ---
            call    rtc_refresh
            call    _pack_fat_datetime  ; RD = packed date, R8 = packed time
            mov     r9, rd              ; R9 = packed date (stash)
            mov     rc, r8              ; RC = packed time (stash -- its
                                        ; earlier use above as the SCLUST
                                        ; high-byte stash is long done)

            mov     rf, fcrw_slot
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = FCB slot base

            mov     rf, rb
            add16   rf, FCB_EOFF
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = FCB_EOFF value

            mov     rf, dirent_patch_buf
            add16   rf, rd
            add16   rf, DE_WRTTIME      ; RF -> entry's WrtTime field
                                        ; (WrtDate immediately follows)

            glo     rc                  ; D = packed time low byte
            str     rf
            inc     rf
            ghi     rc                  ; D = packed time high byte
            str     rf                  ; DE_WRTTIME (LE) written
            inc     rf                  ; RF -> DE_WRTDATE

            glo     r9                  ; D = packed date low byte
            str     rf
            inc     rf
            ghi     r9                  ; D = packed date high byte
            str     rf                  ; DE_WRTDATE (LE) written

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
; file_delete: delete a file (not a directory -- rejected; see RD
; for that, once it exists)
;
; Order of operations is deliberately crash-safe: the directory
; entry is marked deleted ('$E5') and written to disk BEFORE the
; cluster chain is freed. If interrupted between the two steps (e.g.
; power loss), the worst case is a cluster leak (recoverable via
; fsck) rather than a live directory entry pointing at clusters the
; FAT has already marked free and could hand out to a different new
; file -- the same cross-link corruption class fsck caught from the
; append-position bug earlier this project.
;
; fat_flush is called explicitly at the end rather than relying on a
; future fat operation to evict the dirty FAT cache sector -- without
; it, freed clusters could stay marked allocated on disk indefinitely
; if DEL happens to be the last filesystem operation before power-off
; (a latent gap in fat_set's write-back-only design that predates
; this routine; not fixed elsewhere since nothing forced the issue
; until a routine -- this one -- for which "did the delete actually
; take" matters on its own, without a subsequent operation to paper
; over it).
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (not found, is a
;          directory, or an intermediate path component is invalid)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    file_delete

            mov     rd, rf              ; RD = name/path pointer
            mov     rf, fo_name
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fo_name = name/path pointer
                                        ; (reusing file_open's own
                                        ; scratch field -- file_delete
                                        ; is never called while a
                                        ; file_open is mid-flight)

            ; --- resolve the (possibly multi-component) path ---
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster

            mov     ra, fo_name
            lda     ra
            phi     rf
            ldn     ra
            plo     rf                  ; RF = name/path pointer
            call    path_resolve        ; RD = parent cluster, RF = final
                                        ; component
            lbdf    fdel_err            ; bad intermediate component

            ; an empty final component means the path named a
            ; directory itself -- not a file to delete
            ldn     rf
            lbz     fdel_err

            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = final component ptr

            ; RD is still the resolved parent cluster from path_resolve
            call    dir_open

fdel_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    fdel_err            ; end of directory: not found

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = saved name pointer
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    fdel_loop           ; no match: keep looking

            ; must NOT be a directory
            mov     rf, file_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    fdel_err            ; it's a directory: reject

            ; capture the first cluster now, from file_dirent (a copy,
            ; independent of dir_buf) -- safe to read even after
            ; dir_buf itself gets modified below
            mov     rf, file_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     r9
            ldn     rf                  ; D = cluster low byte
            plo     r9                  ; R9 = first cluster (0 = none)

            call    _delete_located_entry
            rtn

fdel_err:
            stc                         ; DF = 1, error
            rtn

; ----------------------------------------------------------------
; _mark_entry_deleted: marks the already-located directory entry (and
; any preceding LFN entries) deleted on disk. Does NOT free its
; cluster chain -- shared by _delete_located_entry (DEL/RD's tail,
; which frees the chain right after) and file_rename (REN, which
; deliberately does NOT free it, since a rename re-points a NEW entry
; at the SAME chain rather than discarding the data).
;
; Factored out so dir_remove's own empty-check scan (which needs to
; dir_open/dir_read the TARGET directory, clobbering dir.asm's live
; scan state) can run and be undone BEFORE this logic sees
; dir_last_off/dir_cur_lba/dir_buf, without touching file_delete's own
; already-hardware-confirmed code path at all -- file_delete's normal
; case never does anything between locating the entry and calling here,
; so it needs no save/restore of its own.
;
; Args:    R9 = target's first cluster (0 = none)
;          dir_last_off/dir_cur_lba/dir_buf = the located entry's
;          parent-directory sector (dir.asm's live scan state, same
;          convention _file_create itself relies on)
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    _mark_entry_deleted

            ; stash it in memory, not just R9 -- f_idewrite below is only
            ; confirmed to preserve RA/RC/RD (see CLAUDE.md gotcha #10),
            ; not R9, so a register alone isn't safe across that call
            mov     rf, fdel_next_clust
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; --- mark the directory entry deleted, on disk, first ---
            mov     rf, dir_last_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = short entry's own byte
                                        ; offset within dir_buf

            ; compute this file's LFN checksum from its still-intact
            ; short name, before the name's first byte is overwritten
            ; with $E5 below -- _file_create stamps this same
            ; checksum into every LFN entry it writes (fc_checksum),
            ; so it's how we tell this file's preceding LFN entries
            ; apart from an unrelated adjacent file's
            mov     rf, dir_buf
            add16   rf, rd              ; RF = short entry base
                                        ; (DE_NAME is offset 0 -- exactly
                                        ; what _dir_chksum wants)
            call    _dir_chksum         ; D = checksum (clobbers
                                        ; RC.0/RF/RB.0)
            plo     rb                  ; stash checksum in RB.0 -- BUG
                                        ; FIX: "mov rf, fdel_chksum"
                                        ; itself clobbers D (its own
                                        ; final side effect leaves D =
                                        ; fdel_chksum's own address low
                                        ; byte, per gotcha #4), so the
                                        ; real checksum just returned in
                                        ; D would not survive to "str
                                        ; rf" below without this stash.
                                        ; _dir_chksum already documents
                                        ; RB.0 as one of its own clobber
                                        ; targets, so reusing it here
                                        ; costs nothing extra.
            mov     rf, fdel_chksum
            glo     rb                  ; D = checksum (reloaded, safe)
            str     rf                  ; fdel_chksum = checksum byte

            ; --- walk backward through this file's LFN entries,
            ; marking each $E5 too -- _file_create always writes a
            ; file's LFN run immediately before its short entry, in
            ; the SAME sector (see its sector-fit check before
            ; writing), so this never crosses a sector/cluster
            ; boundary. Without this, DEL leaves the LFN entries
            ; behind pointing at a short entry that's now gone -- the
            ; "Orphaned long file name part" class fsck flags. RC is
            ; the walk cursor, kept separate from RD (which still
            ; holds the SHORT entry's own offset, needed again below
            ; once the walk is done, and must survive untouched).
            mov     rf, dir_last_off
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = walk cursor, starts at
                                        ; the short entry's own offset
                                        ; (reloaded fresh -- _dir_chksum's
                                        ; effect on RC isn't documented)

dle_lfn_loop:
            ghi     rc
            lbnz    dle_lfn_step_back
            glo     rc
            lbz     dle_mark_short     ; cursor == 0: start of the
                                        ; sector, nothing precedes it
dle_lfn_step_back:
            sub16   rc, DIR_ENT_SIZE    ; RC = previous entry's offset

            mov     rf, dir_buf
            add16   rf, rc              ; RF = candidate entry base
            add16   rf, DE_ATTR
            ldn     rf                  ; D = candidate's attribute byte
            xri     ATTR_LFN
            lbnz    dle_mark_short     ; not an LFN entry: this
                                        ; file's run ends here, stop

            mov     rf, dir_buf
            add16   rf, rc
            add16   rf, LFN_CHKSUM
            ldn     rf                  ; D = candidate's checksum byte
            str     r2                  ; [R2] = candidate's checksum
                                        ; (one-shot scratch slot -- same
                                        ; idiom used by the io_owner
                                        ; check earlier in this file)
            mov     rf, fdel_chksum
            ldn     rf                  ; D = this file's checksum
            sm                          ; D = fdel_chksum - candidate
            lbnz    dle_mark_short     ; mismatch: a different file's
                                        ; LFN run, stop walking

            mov     rf, dir_buf
            add16   rf, rc
            ldi     $E5
            str     rf                  ; mark this LFN entry deleted

            lbr     dle_lfn_loop       ; keep walking backward

dle_mark_short:
            mov     rf, dir_buf
            add16   rf, rd              ; RF = short entry base (RD is
                                        ; untouched by the walk above)

            ; TEMPORARY DIAGNOSTIC: print the entry's first byte as a
            ; character before overwriting it -- confirms exactly
            ; which entry is about to be marked deleted
            ldn     rf                  ; D = first byte (peek only,
                                        ; ldn doesn't advance rf)
            plo     rb                  ; stash it
            mov     r9, dle_diag_char
            glo     rb
            str     r9
            inc     r9
            ldi     0
            str     r9
            call    f_inmsg
            db      13,10,"DIAG mark-deleting: '",0
            mov     rf, dle_diag_char
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            mov     rf, dir_buf
            add16   rf, rd              ; RF = short entry base (recomputed
                                        ; -- the diagnostic calls above
                                        ; clobbered it)
            ldi     $E5
            str     rf                  ; mark deleted in memory

            mov     rf, dir_cur_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, dir_buf
            call    f_idewrite
            lbdf    med_err

            clc                         ; DF = 0, success
            rtn

med_err:
            stc                         ; DF = 1, error
            rtn

; ----------------------------------------------------------------
; _delete_located_entry: marks the located entry deleted (via
; _mark_entry_deleted above) and then frees its cluster chain --
; the DEL/RD tail. file_rename (REN) calls _mark_entry_deleted
; directly instead, skipping this cluster-free step entirely, since
; a rename re-points a NEW entry at the SAME cluster chain rather
; than discarding it.
;
; Args:    R9 = target's first cluster (0 = none)
;          dir_last_off/dir_cur_lba/dir_buf = the located entry's
;          parent-directory sector (same as _mark_entry_deleted)
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    _delete_located_entry

            call    _mark_entry_deleted
            lbdf    dle_err

            ; --- free the cluster chain, now that the entry is safely
            ; marked deleted -- reload from memory, not the R9 passed
            ; in, since _mark_entry_deleted's own f_idewrite call may
            ; have clobbered it (its preservation of R9 is unconfirmed)
            mov     rf, fdel_next_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = first cluster (reloaded)

            ghi     r9
            lbnz    dle_free_loop
            glo     r9
            lbz     dle_flush          ; first cluster == 0: nothing
                                        ; to free

dle_free_loop:
            mov     rd, r9              ; RD = current cluster
            push    rd                  ; save it across fat_get, which
                                        ; overwrites RD with the NEXT
                                        ; cluster
            call    fat_get             ; RD = next cluster; DF=0/1
            mov     rf, fdel_next_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fdel_next_clust = next cluster
                                        ; (kept in memory, not a
                                        ; register -- fat_set below may
                                        ; clobber almost anything)
            pop     rd                  ; RD = current cluster (restored)
            lbdf    dle_err            ; I/O error (stack already
                                        ; balanced by the pop above)

            ldi     0
            phi     rb
            plo     rb                  ; RB = 0 (FAT_FREE)
            call    fat_set             ; marks the current cluster free
            lbdf    dle_err

            ; is the next cluster end-of-chain? reload fresh from
            ; memory into R9 (fat_set may have clobbered any register)
            mov     rf, fdel_next_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = next cluster

            ghi     r9
            smi     $FF
            lbnf    dle_free_loop      ; hi < $FF: valid, keep freeing
            glo     r9
            smi     $F8
            lbnf    dle_free_loop      ; < $FFF8: still valid, keep going

dle_flush:
            call    fat_flush
            lbdf    dle_err

            clc                         ; DF = 0, success
            rtn

dle_err:
            stc                         ; DF = 1, error
            rtn

; ----------------------------------------------------------------
; dir_create: create a new, empty subdirectory (MD)
;
; Allocates and zeros a fresh cluster, writes '.' (self) and '..'
; (parent -- or 0 for root, the same "root=0" sentinel this project
; already uses everywhere else, so no special-casing is needed)
; entries into it, flushes the FAT allocation immediately (before the
; new cluster is ever referenced from a directory entry -- same
; crash-safety ordering as file_delete: a half-finished MD should
; leave at worst an orphaned allocated cluster, recoverable via fsck,
; never a live parent entry pointing at a cluster that was never
; actually initialized), then reuses _file_create's own
; entry-insertion machinery (LFN generation, terminator handling,
; sector spillover) to add the new directory's entry into the parent
; -- parameterized via fc_new_attr/fc_new_cluster instead of
; _file_create's usual file-creation defaults (ATTR_ARCHIVE / a lazily
; allocated 0).
;
; Single-level only: the parent must already exist (no implicit
; intermediate directory creation, matching classic DOS MD).
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (already exists, an
;          intermediate path component is invalid, or disk full)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    dir_create

            mov     rd, rf
            mov     rf, fo_name
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fo_name = path pointer (reusing
                                        ; file_open's own scratch field
                                        ; -- dir_create is never called
                                        ; while a file_open/file_delete
                                        ; is mid-flight)

            ; --- resolve the (possibly multi-component) path ---
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster

            mov     ra, fo_name
            lda     ra
            phi     rf
            ldn     ra
            plo     rf                  ; RF = path pointer
            call    path_resolve        ; RD = parent cluster, RF = final
                                        ; component
            lbdf    dcr_err             ; bad intermediate component

            ; save BOTH return values into memory immediately, using RB
            ; (untouched by path_resolve) as the destination pointer for
            ; each -- BUG FIX: an earlier version of this used RF/RD
            ; themselves as the destination pointer partway through,
            ; which destroys the very value being saved; and the "." /
            ; ".." guard further below calls f_strcmp, which clobbers
            ; RD, so both must be safely in memory before that runs.
            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = final component ptr

            mov     rb, dcr_parent
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; dcr_parent = parent cluster

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = final component pointer
            ldn     rd
            lbz     dcr_err             ; empty final component: no name
                                        ; given ("MD /", "MD foo/", ...)

            ; reject creating a directory literally named "." or ".."
            ; -- the root directory has no such entries (it's a fixed
            ; region, not a normal cluster-chain directory), so the
            ; collision scan below wouldn't otherwise catch this there
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dcr_dot
            call    f_strcmp
            lbz     dcr_err

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dcr_dotdot
            call    f_strcmp
            lbz     dcr_err

            ; reload the parent cluster fresh from memory -- RD has
            ; been clobbered several times since path_resolve returned
            mov     rf, dcr_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    dir_open

dcr_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    dcr_notfound        ; end of directory: no collision
                                        ; -- dir_eptr/dir_cur_lba/
                                        ; dir_clust/dir_sect now describe
                                        ; the '$00' terminator's sector,
                                        ; reused by _file_create below
                                        ; (same convention file_open's
                                        ; fopen_notfound relies on)

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = saved name pointer
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    dcr_loop            ; no match: keep looking

            ; name already exists (file or directory): reject
            lbr     dcr_err

dcr_notfound:
            ; --- allocate the new directory's first cluster ---
            call    fat_alloc           ; RD = new cluster, DF=0/1
            lbdf    dcr_err

            mov     rf, dcr_new_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dcr_new_clust = new cluster
                                        ; (kept in memory, not a
                                        ; register -- across several
                                        ; calls below, same reasoning as
                                        ; file_delete's fdel_next_clust)

            call    fat_flush           ; persist the allocation now
            lbdf    dcr_err

            ; --- build the first sector: '.' and '..' entries, rest
            ; zero. dir_buf is borrowed as scratch here -- nothing else
            ; needs its CURRENT content until it's restored below, right
            ; before _file_create needs it back. ---
            mov     rf, dir_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc                  ; RC = 512 (byte count)
dcr_zero1:
            ldi     0
            str     rf
            inc     rf
            sub16   rc, 1
            ghi     rc
            lbnz    dcr_zero1
            glo     rc
            lbnz    dcr_zero1

            ; '.' entry at dir_buf+0 -- DE_NAME is 11 bytes total:
            ; 1 dot + 10 trailing spaces
            mov     rf, dir_buf
            ldi     '.'
            str     rf
            inc     rf
            ldi     10
            plo     r9
dcr_dot_pad:
            ldi     ' '
            str     rf
            inc     rf
            dec     r9
            glo     r9
            lbnz    dcr_dot_pad

            mov     rf, dir_buf
            add16   rf, DE_ATTR
            ldi     ATTR_DIR
            str     rf

            mov     rf, dir_buf
            add16   rf, DE_CLUSTER
            mov     r9, dcr_new_clust
            lda     r9
            phi     ra
            ldn     r9
            plo     ra                  ; RA = new cluster (self)
            glo     ra
            str     rf
            inc     rf
            ghi     ra
            str     rf

            ; '..' entry at dir_buf+32 -- DE_NAME is 11 bytes total:
            ; 2 dots + 9 trailing spaces
            mov     rf, dir_buf
            add16   rf, DIR_ENT_SIZE
            ldi     '.'
            str     rf
            inc     rf
            ldi     '.'
            str     rf
            inc     rf
            ldi     9
            plo     r9
dcr_dotdot_pad:
            ldi     ' '
            str     rf
            inc     rf
            dec     r9
            glo     r9
            lbnz    dcr_dotdot_pad

            mov     rf, dir_buf
            add16   rf, DIR_ENT_SIZE
            add16   rf, DE_ATTR
            ldi     ATTR_DIR
            str     rf

            mov     rf, dir_buf
            add16   rf, DIR_ENT_SIZE
            add16   rf, DE_CLUSTER
            mov     r9, dcr_parent
            lda     r9
            phi     ra
            ldn     r9
            plo     ra                  ; RA = parent cluster (0 = root)
            glo     ra
            str     rf
            inc     rf
            ghi     ra
            str     rf

            ; --- write/date-stamp both entries with the current time ---
            call    rtc_refresh
            call    _pack_fat_datetime  ; RD = packed date, R8 = packed time
            mov     r9, rd              ; R9 = packed date (stash)
            mov     ra, r8              ; RA = packed time (stash)

            mov     rf, dir_buf
            add16   rf, DE_WRTTIME
            glo     ra
            str     rf
            inc     rf
            ghi     ra
            str     rf
            mov     rf, dir_buf
            add16   rf, DE_WRTDATE
            glo     r9
            str     rf
            inc     rf
            ghi     r9
            str     rf

            mov     rf, dir_buf
            add16   rf, DIR_ENT_SIZE
            add16   rf, DE_WRTTIME
            glo     ra
            str     rf
            inc     rf
            ghi     ra
            str     rf
            mov     rf, dir_buf
            add16   rf, DIR_ENT_SIZE
            add16   rf, DE_WRTDATE
            glo     r9
            str     rf
            inc     rf
            ghi     r9
            str     rf

            ; --- write this sector to the new cluster's first sector ---
            ; LBA memory convention (matches every other 3-byte stored
            ; LBA in this codebase, e.g. dir_cur_lba/fdel_next_clust's
            ; use): byte0 = bits 23-16 (R8.lo), byte1 = bits 15-8
            ; (R7.hi), byte2 = bits 7-0 (R7.lo) -- confirmed against
            ; _cluster_to_lba's own accumulator setup in dir.asm.
            mov     rf, dcr_new_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    _cluster_to_lba     ; R7/R8 = LBA of cluster's 1st
                                        ; sector (clobbers R7/R8/R9/RA/
                                        ; RB/RC/RD/RF -- nothing we still
                                        ; need survives it unprotected)
            mov     rf, dcr_sect_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; dcr_sect_lba = first sector's
                                        ; LBA (kept in memory across the
                                        ; write calls below)

            mov     rf, dcr_sect_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, dir_buf
            call    f_idewrite
            lbdf    dcr_err

            ; --- zero any remaining sectors in the cluster ---
            mov     rf, bpb_spc
            ldn     rf
            smi     1
            lbz     dcr_restore         ; spc == 1: nothing more to do

            plo     r9                  ; R9.0 = remaining sector count

            mov     rf, dir_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc
dcr_zero2:
            ldi     0
            str     rf
            inc     rf
            sub16   rc, 1
            ghi     rc
            lbnz    dcr_zero2
            glo     rc
            lbnz    dcr_zero2

dcr_zero_loop:
            ; byte2 (offset dcr_sect_lba+2) is bits 7-0 -- incrementing
            ; just that byte is enough since bpb_spc (a single byte,
            ; max 255) bounds how many sectors a cluster can ever have,
            ; so sector-within-cluster addressing never needs to carry
            ; into the higher LBA bytes
            mov     rf, dcr_sect_lba
            add16   rf, 2
            ldn     rf
            adi     1
            str     rf                  ; dcr_sect_lba's low byte += 1

            mov     rf, dcr_sect_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, dir_buf
            call    f_idewrite
            lbdf    dcr_err

            dec     r9
            glo     r9
            lbnz    dcr_zero_loop

dcr_restore:
            ; --- restore dir_buf: it was borrowed as scratch above,
            ; but _file_create needs it to hold the parent directory's
            ; terminator sector again (dir_cur_lba/dir_eptr are
            ; untouched by any of the above, so a plain re-read puts
            ; dir_buf back exactly where _file_create expects it) ---
            mov     rf, dir_cur_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, dir_buf
            call    f_ideread
            lbdf    dcr_err

            mov     rf, fc_new_attr
            ldi     ATTR_DIR
            str     rf

            mov     rf, dcr_new_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, fc_new_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, fc_new_size     ; a freshly created directory
            ldi     0                   ; always reports size 0 in its
            str     rf                  ; own entry
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            call    _file_create
            rtn                         ; DF from _file_create passed
                                        ; straight through

dcr_err:
            stc
            rtn

; local literal strings for the "." / ".." name-collision guard above
; -- placed here, after every reachable code path in this proc already
; terminated via rtn, so control flow never falls through into them
dcr_dot:        db      ".",0
dcr_dotdot:     db      "..",0

; ----------------------------------------------------------------
; dir_remove: remove an EMPTY subdirectory (RD)
;
; Locates the entry in its parent (must be a directory, must not be
; "." or ".." or the root), scans the TARGET directory itself to
; confirm it holds nothing but "." and ".." (refusing non-empty
; directories, matching classic DOS RD -- no recursive delete), then
; calls the same _delete_located_entry tail file_delete (DEL) uses to
; mark the parent's entry deleted (and clean up its LFN run) and free
; the target's cluster chain.
;
; The empty-check scan needs its own dir_open/dir_read pass over the
; TARGET directory, which clobbers dir.asm's live scan state
; (dir_last_off/dir_cur_lba/dir_buf) -- state _delete_located_entry
; depends on to still describe the PARENT's located entry. That state
; is saved into dedicated scratch fields before the empty-check scan
; and restored (dir_buf via a fresh re-read, since dir_cur_lba alone
; isn't the sector's actual content) right before calling
; _delete_located_entry, so that already-hardware-confirmed shared
; tail sees exactly what it always expects -- zero changes needed to
; file_delete's own code path.
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (not found, not a
;          directory, not empty, is "."/".."/root, or an intermediate
;          path component is invalid)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    dir_remove

            mov     rd, rf              ; RD = path pointer
            mov     rf, fo_name
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fo_name = path pointer

            ; --- resolve the (possibly multi-component) path ---
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster

            mov     ra, fo_name
            lda     ra
            phi     rf
            ldn     ra
            plo     rf                  ; RF = path pointer
            call    path_resolve        ; RD = parent cluster, RF = final
                                        ; component
            lbdf    drm_err             ; bad intermediate component

            ; save BOTH return values into memory immediately, using RB
            ; (untouched by path_resolve) as the destination pointer for
            ; each -- the "." / ".." guard below calls f_strcmp, which
            ; clobbers RD (confirmed the hard way during dir_create's
            ; own bug hunt -- see its header comment), so both must be
            ; safely in memory, not left in RD/RF, before that runs.
            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = final component ptr

            mov     rb, drm_parent
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; drm_parent = parent cluster

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = final component pointer
            ldn     rd
            lbz     drm_err             ; empty final component: no
                                        ; name given

            ; reject "." and ".." as the target -- these aren't real,
            ; independently removable entries
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, drm_dot
            call    f_strcmp
            lbz     drm_err

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, drm_dotdot
            call    f_strcmp
            lbz     drm_err

            mov     rf, drm_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = parent cluster (reloaded
                                        ; fresh)
            call    dir_open

drm_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    drm_err             ; end of directory: not found

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = saved name pointer
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    drm_loop            ; no match: keep looking

            ; must BE a directory
            mov     rf, file_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     drm_err             ; not a directory: reject

            ; capture the target's first cluster now, from file_dirent
            ; (a copy, independent of dir_buf) -- safe to read even
            ; after the empty-check scan below overwrites dir_buf
            mov     rf, file_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     r9
            ldn     rf                  ; D = cluster low byte
            plo     r9                  ; R9 = target's first cluster

            ; cluster 0 is the root sentinel, never a real allocated
            ; cluster a target could legitimately be -- refuse it
            ; defensively (root has no directory entry of its own to
            ; remove in the first place)
            ghi     r9
            lbnz    drm_have_target
            glo     r9
            lbz     drm_err
drm_have_target:

            ; --- save the parent's located-entry position before the
            ; empty-check scan below clobbers dir.asm's live state ---
            mov     rf, drm_saved_clust
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, dir_last_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, drm_saved_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, dir_cur_lba
            mov     rb, drm_saved_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            ; --- confirm the target directory is empty (only '.' and
            ; '..') before removing it ---
            mov     rd, r9              ; RD = target's cluster
            call    dir_open

drm_empty_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    drm_restore         ; end of directory: empty,
                                        ; proceed with removal

            mov     rd, file_dirent
            mov     rf, drm_dot
            call    f_strcmp
            lbz     drm_empty_loop      ; matches "."

            mov     rd, file_dirent
            mov     rf, drm_dotdot
            call    f_strcmp
            lbz     drm_empty_loop      ; matches ".."

            ; anything else: not empty
            lbr     drm_err

drm_restore:
            ; --- restore dir.asm's live state to describe the
            ; PARENT's located entry again, exactly as
            ; _delete_located_entry expects ---
            mov     rf, drm_saved_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dir_last_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, drm_saved_lba
            mov     rb, dir_cur_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            mov     rf, dir_cur_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, dir_buf
            call    f_ideread           ; dir_buf = parent's sector
                                        ; content again
            lbdf    drm_err

            mov     rf, drm_saved_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = target's first cluster
                                        ; (reloaded fresh)

            call    _delete_located_entry
            rtn                         ; DF passed straight through

drm_err:
            stc                         ; DF = 1, error
            rtn

; local literal strings for the "." / ".." checks above -- placed
; here, after every reachable code path in this proc already
; terminated via rtn, so control flow never falls through into them
drm_dot:        db      ".",0
drm_dotdot:     db      "..",0

; ----------------------------------------------------------------
; file_rename: rename a file or directory within the SAME parent
; directory (no cross-directory move)
;
; The new name must be a bare name (no path separator) -- it always
; applies within the OLD path's own resolved parent. Works on either
; files or directories (no ATTR_DIR check either way, unlike DEL/RD).
;
; Deliberately always inserts a brand-new directory entry (reusing
; _file_create, parameterized via fc_new_attr/fc_new_cluster/
; fc_new_size to carry over the target's existing attribute, cluster
; chain, and size exactly) rather than attempting an in-place short-
; name/LFN edit -- simpler, and avoids comparing old vs. new LFN slot
; counts. The new entry is inserted BEFORE the old one is removed, and
; the new-name collision check happens before either: if anything
; fails partway, the worst case is a harmless duplicate entry (both
; names pointing at the same data), never a lost one -- the same
; "safe/reversible step before the destructive one" ordering this
; project already uses for DEL/MD. The old entry is removed via
; _mark_entry_deleted only (NOT _delete_located_entry) -- its cluster
; chain must NOT be freed, since the new entry now points at it.
;
; Args:    RF = pointer to null-terminated OLD path string
;          RD = pointer to null-terminated NEW name (bare name, no
;          path separator)
; Returns: DF = 0 on success, DF = 1 on error (old not found, new
;          name already exists or is invalid, old or new name is
;          "."/"..", or an intermediate component of the old path is
;          invalid)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
; ----------------------------------------------------------------
            endp

            proc    file_rename

            ; save both incoming pointers immediately, using RB as the
            ; store-address register -- path_resolve (below) clobbers
            ; RD and needs RF free
            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = old path pointer

            mov     rb, ren_new_name
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ren_new_name = new name ptr

            ; --- validate the new name: not empty, no path
            ; separator, not "." or ".." ---
            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = new name pointer
            ldn     rd
            lbz     ren_err             ; empty new name

            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = new name pointer (reload)
ren_check_sep:
            ldn     rd
            lbz     ren_check_sep_done  ; reached the null: no separator
            xri     PATH_SEP
            lbz     ren_err             ; new name contains '/'
            inc     rd
            lbr     ren_check_sep
ren_check_sep_done:

            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ren_dot
            call    f_strcmp
            lbz     ren_err             ; new name is "."

            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ren_dotdot
            call    f_strcmp
            lbz     ren_err             ; new name is ".."

            ; --- resolve the (possibly multi-component) OLD path ---
            mov     rf, cur_dir
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current directory cluster

            mov     ra, fo_name
            lda     ra
            phi     rf
            ldn     ra
            plo     rf                  ; RF = old path pointer
            call    path_resolve        ; RD = parent cluster, RF = final
                                        ; component
            lbdf    ren_err             ; bad intermediate component

            ; save both return values into memory immediately (the
            ; "." / ".." guard below calls f_strcmp, confirmed to
            ; clobber RD -- see dir_create's own header comment)
            mov     rb, fo_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; fo_name = old final component

            mov     rb, ren_parent
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ren_parent = parent cluster

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = old final component
            ldn     rd
            lbz     ren_err             ; empty final component: no
                                        ; name given

            ; reject renaming "." or ".." -- these aren't real,
            ; independently renamable entries
            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ren_dot
            call    f_strcmp
            lbz     ren_err

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ren_dotdot
            call    f_strcmp
            lbz     ren_err

            ; --- scan the parent for the OLD name ---
            mov     rf, ren_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = parent cluster (reloaded)
            call    dir_open

ren_old_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    ren_err             ; end of directory: not found

            mov     rf, fo_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = old final component
            mov     rf, file_dirent     ; RF = entry name
            call    f_strcmp
            lbnz    ren_old_loop        ; no match: keep looking

            ; --- capture attr/cluster/size now, from file_dirent (a
            ; copy, independent of dir_buf) -- straight into
            ; fc_new_attr/fc_new_cluster/fc_new_size, since nothing
            ; else touches those until _file_create reads them below ---
            mov     rf, file_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            plo     rb                  ; stash it -- BUG FIX: "mov r9,
                                        ; fc_new_attr" below itself
                                        ; clobbers D (gotcha #4), so the
                                        ; attribute byte just loaded
                                        ; would not survive to "str r9"
                                        ; without this stash
            mov     r9, fc_new_attr
            glo     rb                  ; D = attribute byte (reloaded)
            str     r9

            mov     rf, file_dirent
            add16   rf, DIRENT_CLUST
            mov     r9, fc_new_cluster
            lda     rf
            str     r9
            inc     r9
            ldn     rf
            str     r9

            mov     rf, file_dirent
            add16   rf, DIRENT_SIZE
            mov     r9, fc_new_size
            lda     rf
            str     r9
            inc     r9
            lda     rf
            str     r9
            inc     r9
            lda     rf
            str     r9
            inc     r9
            ldn     rf
            str     r9

            ; --- save the OLD entry's location before the new-name
            ; collision scan below clobbers dir.asm's live state ---
            mov     rf, dir_last_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ren_old_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, dir_cur_lba
            mov     rb, ren_old_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            ; --- scan the parent AGAIN, fresh, for a NEW-name
            ; collision. If none, this naturally leaves dir.asm's live
            ; state describing the '$00' terminator -- exactly what
            ; _file_create needs -- so it's used immediately below,
            ; before anything else can disturb it. ---
            mov     rf, ren_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    dir_open

ren_new_loop:
            mov     rf, file_dirent
            call    dir_read
            lbdf    ren_insert          ; end of directory: no
                                        ; collision, proceed

            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, file_dirent
            call    f_strcmp
            lbnz    ren_new_loop        ; no match: keep looking

            ; new name already exists: reject (nothing destructive
            ; has happened yet)
            lbr     ren_err

ren_insert:
            ; fo_name = new name pointer, for _file_create to read
            mov     rf, ren_new_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rb, fo_name
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            call    _file_create        ; DF = 0/1
            lbdf    ren_err             ; failed: nothing destructive
                                        ; happened, safe to just report

            ; TEMPORARY DIAGNOSTIC: compare where env2.dat's OLD entry
            ; lives (ren_old_lba/ren_old_off) against where
            ; _file_create just inserted the NEW entry
            ; (fc_target_lba/fc_target_off) -- investigating corruption
            ; seen after REN followed by a same-directory short-only
            ; (no-LFN) insertion
            mov     rf, ren_old_lba
            lda     rf
            str     r2
            mov     rd, fc_target_lba
            ldn     rd
            sm
            lbnz    diag_lba_diff       ; byte 0 differs

            mov     rf, ren_old_lba
            inc     rf
            ldn     rf
            str     r2
            mov     rd, fc_target_lba
            inc     rd
            ldn     rd
            sm
            lbnz    diag_lba_diff       ; byte 1 differs

            mov     rf, ren_old_lba
            add16   rf, 2
            ldn     rf
            str     r2
            mov     rd, fc_target_lba
            add16   rd, 2
            ldn     rd
            sm
            lbnz    diag_lba_diff       ; byte 2 differs

            call    f_inmsg
            db      13,10,"DIAG ren: lba SAME",0
            lbr     diag_lba_done
diag_lba_diff:
            call    f_inmsg
            db      13,10,"DIAG ren: lba DIFF",0
diag_lba_done:
            mov     rf, ren_old_off
            lda     rf
            str     r2
            mov     rd, fc_target_off
            ldn     rd
            sm
            lbnz    diag_off_diff

            mov     rf, ren_old_off
            inc     rf
            ldn     rf
            str     r2
            mov     rd, fc_target_off
            inc     rd
            ldn     rd
            sm
            lbnz    diag_off_diff

            call    f_inmsg
            db      " off SAME",13,10,0
            lbr     diag_off_done
diag_off_diff:
            call    f_inmsg
            db      " off DIFF",13,10,0
diag_off_done:
            ; END TEMPORARY DIAGNOSTIC

            ; --- restore dir.asm's live state to the OLD entry's
            ; location, exactly as _mark_entry_deleted expects ---
            mov     rf, ren_old_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dir_last_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ren_old_lba
            mov     rb, dir_cur_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            mov     rf, dir_cur_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, dir_buf
            call    f_ideread           ; dir_buf = OLD entry's parent
                                        ; sector content again
            lbdf    ren_err

            ; R9 = the OLD entry's own cluster -- still sitting in
            ; fc_new_cluster (big-endian in memory), since we just set
            ; it ourselves above and nothing else has touched it
            mov     rf, fc_new_cluster
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

            call    _mark_entry_deleted ; does NOT free the cluster
                                        ; chain -- the new entry now
                                        ; points at it
            rtn                         ; DF passed straight through

ren_err:
            stc                         ; DF = 1, error
            rtn

; local literal strings for the "." / ".." checks above -- placed
; here, after every reachable code path in this proc already
; terminated via rtn, so control flow never falls through into them
ren_dot:        db      ".",0
ren_dotdot:     db      "..",0

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
            ;   4. Before any of that: if FCB_CCLUST is still 0 (a
            ;      freshly created, never-written file -- see
            ;      file_open's fopen_notfound/_file_create), the
            ;      first cluster is allocated here too, on the first
            ;      byte written, and FCB_SCLUST/FCB_F_SIZECHG are
            ;      updated so file_close rewrites the directory
            ;      entry's first-cluster field alongside its size.
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

            ; ---- if this file has no cluster yet (freshly created,
            ; never written), allocate its first cluster before the
            ; main loop begins. FCB_CCLUST is only ever 0 in exactly
            ; this case -- a real chain never contains cluster 0
            ; (that means "free" in the FAT table), so this check
            ; only ever fires once per file, on its first-ever write. ----
            mov     rf, rb
            add16   rf, FCB_CCLUST
            lda     rf                  ; D = FCB_CCLUST high byte
            lbnz    fwrite_have_cluster
            ldn     rf                  ; D = FCB_CCLUST low byte
            lbnz    fwrite_have_cluster

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

            ; FCB_SCLUST = FCB_CCLUST = new cluster
            mov     rf, rb
            add16   rf, FCB_SCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, rb
            add16   rf, FCB_CCLUST
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; the directory entry's first-cluster field now needs
            ; rewriting at close too -- _fclose_rewrite_size patches
            ; DE_CLUSTER from FCB_SCLUST unconditionally alongside
            ; DE_SIZE whenever FCB_F_SIZECHG is set, so no separate
            ; flag is needed for "cluster changed" vs. "size changed"
            mov     rf, rb
            ldn     rf
            ori     FCB_F_SIZECHG
            str     rf

            ; BUG FIX: flush the FAT immediately after this fat_alloc,
            ; same reasoning as fc_grow's own fix (see its comment) --
            ; an unflushed allocation can be silently reverted if the
            ; single-sector FAT cache gets evicted for a different
            ; sector before this one is written, letting a later
            ; fat_alloc hand out the same cluster again. fat_flush
            ; documents R7/R8/R9/RB/RC/RD/RF as clobbered -- R9/RA/RB/RC
            ; are this routine's own stable loop registers (see its
            ; header comment), so all of R9/RA/RB/RC are protected here
            ; (RA isn't in fat_flush's own clobber list, but protecting
            ; it too costs nothing and matches the surrounding
            ; fat_alloc/fat_set calls' own style).
            push    r9
            push    ra
            push    rb
            push    rc
            call    fat_flush
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fwrite_ioerr

fwrite_have_cluster:
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

            ; BUG FIX: flush the FAT immediately after this fat_alloc,
            ; same reasoning as fc_grow's own fix (see its comment) --
            ; an unflushed allocation can be silently reverted if the
            ; single-sector FAT cache gets evicted for a different
            ; sector before this one is written. fat_flush documents
            ; R7/R8/R9/RB/RC/RD/RF as clobbered -- R9/RA/RB/RC are this
            ; routine's own stable loop registers, so all four are
            ; protected here (matching the surrounding fat_alloc/
            ; fat_set calls' own style).
            push    r9
            push    ra
            push    rb
            push    rc
            call    fat_flush
            pop     rc
            pop     rb
            pop     ra
            pop     r9
            lbdf    fwrite_ioerr

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

; fc_*: scratch for _file_create/_gen_short_name (new-file creation).
; fc_shortname/fc_needs_lfn/fc_namelen/fc_lfncount/fc_checksum hold
; the generated short name and its derived bookkeeping; fc_target_lba/
; fc_target_off are the sector/offset the new entries are about to be
; written to (may differ from the terminator's own original sector --
; see _file_create); fc_elba/fc_eoff are the final short entry's
; location, handed back to file_open for FCB_ELBA/FCB_EOFF, mirroring
; dir_cur_lba/dir_last_off's role for an already-existing entry.
fc_shortname:   ds      11
fc_needs_lfn:   db      0
fc_namelen:     dw      0
fc_lfncount:    db      0
fc_checksum:    db      0
fc_target_lba:  ds      LBA_SIZE
fc_target_off:  dw      0
fc_elba:        ds      LBA_SIZE
fc_eoff:        dw      0

; TEMPORARY DIAGNOSTIC scratch: last call's fc_target_lba/fc_target_off,
; for comparing consecutive _file_create calls. Non-zero sentinel init
; so the first call doesn't spuriously read as a match.
fc_diag_last_lba:   db      $FF,$FF,$FF
fc_diag_last_off:   dw      $FFFF

; TEMPORARY DIAGNOSTIC scratch: LINE_BUF dump buffer, used by
; file_open's pre-scan/post-match prints (see fopen_loop above)
diag_lb_buf:    ds      25

; fc_new_attr/fc_new_cluster/fc_new_size: parameterize _file_create's
; short-entry write -- file_open's fopen_notfound always sets
; ATTR_ARCHIVE/0/0 (a plain file, first cluster lazily allocated on
; first write, size starts empty); dir_create (MD) sets ATTR_DIR and
; an already-allocated cluster (size stays 0). file_rename (REN) sets
; all three to the renamed entry's existing attr/cluster/size, so a
; rename preserves them exactly across its delete+recreate.
; fc_new_cluster/fc_new_size are big-endian in memory, same convention
; as every other scratch cluster/size field in this file.
fc_new_attr:    db      0
fc_new_cluster: dw      0
fc_new_size:    dw      0,0             ; 4 bytes, big-endian

; fa_*: scratch for file_open's mode-2 (append) end-of-file
; positioning -- see the append block in file_open. Kept in memory
; (not registers) across the fat_get chain-walk loop, which clobbers
; R7/R8/R9/RB/RC (via a possible nested fat_flush).
fa_boff:            dw      0
fa_cluster_idx:     db      0
fa_sector_in_clust: db      0

; fdel_next_clust: scratch for file_delete's cluster-freeing loop --
; kept in memory (not a register) across the fat_set call, which may
; clobber almost anything.
fdel_next_clust:    dw      0

; fdel_chksum: scratch for file_delete's LFN-entry cleanup walk --
; the short entry's LFN checksum (same value _file_create stamps into
; every LFN entry belonging to this file), computed once and kept in
; memory since _dir_chksum's own clobber footprint (RC.0/RF/RB.0) and
; effect on any other register isn't documented beyond its own args.
fdel_chksum:        db      0

; TEMPORARY DIAGNOSTIC scratch: single-char print buffer for
; _mark_entry_deleted's investigation
dle_diag_char:      db      0,0

; dcr_*: scratch for dir_create (MD) -- kept in memory, not registers,
; across the several fat_alloc/fat_flush/_cluster_to_lba/f_idewrite/
; f_ideread calls between allocating the new cluster and finally
; handing it to _file_create (same reasoning as fdel_next_clust).
dcr_parent:         dw      0           ; parent directory's cluster
                                        ; (0 = root, for the '..' entry)
dcr_new_clust:      dw      0           ; newly allocated cluster
dcr_sect_lba:       ds      LBA_SIZE    ; current sector's LBA while
                                        ; zeroing the new cluster

; drm_*: scratch for dir_remove (RD) -- the empty-check scan (its own
; dir_open/dir_read pass over the TARGET directory) clobbers dir.asm's
; live scan state, so the PARENT's located-entry position is saved
; here first and restored afterward, before _delete_located_entry
; (shared with DEL) runs. Kept in memory, not registers, across that
; scan for the same reasoning as fdel_next_clust/dcr_*.
drm_parent:         dw      0           ; resolved parent cluster
drm_saved_clust:    dw      0           ; target directory's own first
                                        ; cluster
drm_saved_off:      dw      0           ; parent's dir_last_off, saved
drm_saved_lba:      ds      LBA_SIZE    ; parent's dir_cur_lba, saved

; ren_*: scratch for file_rename (REN) -- same reasoning as drm_*: the
; new-name collision scan (a fresh dir_open/dir_read pass) clobbers
; dir.asm's live scan state, so the OLD entry's location is saved here
; first and restored afterward, before _mark_entry_deleted runs.
ren_new_name:       dw      0           ; new name pointer
ren_parent:         dw      0           ; resolved parent cluster
ren_old_off:        dw      0           ; OLD entry's dir_last_off, saved
ren_old_lba:        ds      LBA_SIZE    ; OLD entry's dir_cur_lba, saved

                public  io_owner
                public  file_dirent
                public  fo_name
                public  fo_mode
                public  fo_fcb
                public  fo_handle
                public  fr_request
                public  dirent_patch_buf
                public  fcrw_slot
                public  fc_shortname
                public  fc_needs_lfn
                public  fc_namelen
                public  fc_lfncount
                public  fc_checksum
                public  fc_target_lba
                public  fc_target_off
                public  fc_elba
                public  fc_new_attr
                public  fc_new_cluster
                public  fc_new_size
                public  fc_eoff
                public  fc_diag_last_lba
                public  fc_diag_last_off
                public  diag_lb_buf
                public  fa_boff
                public  fa_cluster_idx
                public  fa_sector_in_clust
                public  fdel_next_clust
                public  fdel_chksum
                public  dle_diag_char
                public  dcr_parent
                public  dcr_new_clust
                public  dcr_sect_lba
                public  drm_parent
                public  drm_saved_clust
                public  drm_saved_off
                public  drm_saved_lba
                public  ren_new_name
                public  ren_parent
                public  ren_old_off
                public  ren_old_lba

            endp
