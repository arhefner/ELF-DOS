;
; file_data.asm - volatile (RAM-resident) data for file.asm
;
; Split out of file.asm for the split memory model (volatile RAM data at
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


; ----------------------------------------------------------------
; _shared_scratch's own storage -- see the big comment above.
; ----------------------------------------------------------------
            proc    _shared_scratch_data

_shared_scratch:    ds      9

                public  _shared_scratch

            endp


;------------------------------------------------------------------
; File-layer scratch data
;
; file_dirent: scratch DIRENT_LEN buffer for file_open's directory
;              search (private to this module, unlike shell.asm's
;              dir_result).
; fo_*:        file_open's saved arguments -- needed because dir_open/
;              dir_read clobber R9/RA/RB/RC/RD/RF internally, so
;              nothing survives in a register across the directory-
;              search loop. fo_fcb/fo_iobuf are the caller-supplied
;              FCB/I-O-buffer pointers (2026-07-15, caller-allocated
;              FCBs) -- the caller already has fo_fcb's own value, so
;              unlike the old fd_table design there's no separate
;              handle to allocate or return.
; fr_request:  file_read's original requested byte count, needed to
;              compute the actual bytes-read return value at the end.
;------------------------------------------------------------------
            proc    _file_data

file_dirent:    ds      DIRENT_LEN
fo_name:        dw      0
fo_mode:        db      0
fo_fcb:         dw      0
fo_iobuf:       dw      0
fo_drive:       db      0           ; path_resolve's resolved drive
                                    ; (RC.0), stashed to memory right
                                    ; after the call since dir_open/
                                    ; dir_read below clobber RC --
                                    ; written into FCB_DRIVE once the
                                    ; FCB is populated (both the
                                    ; found-existing-file and newly-
                                    ; created-file paths)
fr_request:     dw      0

; fcrw_slot/fcrw_iobuf: scratch for _fclose_rewrite_size. No dedicated
; 512-byte buffer here -- the routine reuses the closing FCB's own
; IOBUF instead, safe only because file_write in this project always
; writes through immediately (no deferred-dirty-buffer design), so by
; the time file_close reaches here the FCB's iobuf can only hold a
; stale read cache, and nothing reads through the FCB again once this
; returns. fcrw_iobuf holds that resolved buffer address, kept in
; memory (not a register) across the several BIOS/kernel calls in
; this routine, none of which are proven to preserve any given
; register -- same reasoning as fcrw_slot itself.
fcrw_slot:      dw      0           ; FCB slot base, kept in memory
                                    ; (not a register) across
                                    ; f_ideread/f_idewrite, since only
                                    ; RA/RC/RD are confirmed preserved
                                    ; by those calls
fcrw_iobuf:     dw      0           ; this FCB's own IOBUF address,
                                    ; resolved once at entry, reused
                                    ; instead of a dedicated buffer

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

; fc_grow_lba: fc_grow's own walking LBA while zeroing sectors 1..
; spc-1 of a newly allocated cluster (see fc_grow's own BUG FIX
; comment, 2026-08-22) -- a dedicated memory field, reloaded fresh
; before every f_idewrite call rather than trusted in a register
; across it, matching every other LBA field in this file (nothing
; here has ever confirmed f_idewrite preserves R7/R8).
fc_grow_lba:    ds      LBA_SIZE
fc_elba:        ds      LBA_SIZE
fc_eoff:        dw      0

; fc_base8/fc_namepart_len/fc_suffix_n/fc_collision and the
; fc_saved_*/fc_scan_* fields below support _check_shortname_collision
; and _file_create's own ~1-~9 numeric-tail retry loop (2026-07-25) --
; _gen_short_name's fallback truncation has no uniqueness check of its
; own (see its header), so two unrelated long names truncating to the
; identical first-8-characters silently produced two directory entries
; with the same raw 11-byte short name -- a real FAT16 spec violation
; that fsck.fat correctly (and destructively) "fixes" by auto-renaming
; one of them, discovered via a real hardware fsck report ("Duplicate
; directory entry", test_args1.bat/test_args2.bat both truncating to
; "TEST_ARG"). fc_base8 is the ORIGINAL (unmutated) 8-byte name part,
; captured once before any ~N is applied; fc_namepart_len is the count
; of real (non-space-padding) characters in it, 0-8.
fc_base8:       ds      8
fc_namepart_len: db     0
fc_suffix_n:    db      0
fc_suffix_tens: db      0
fc_suffix_ones: db      0
fc_collision:   db      0
fc_saved_sect:  db      0
fc_saved_eptr:  dw      0
fc_saved_eleft: db      0
fc_saved_lba:   ds      LBA_SIZE
fc_saved_lfnok: db      0

; csc_sector_count: _check_shortname_collision's own once-per-sector
; cap counter -- see the hard-cap comment in that proc's own scan loop.
csc_sector_count: db    0

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

; fa_*/fdel_*/dcr_*/drm_*/ren_*: now #define aliases into
; _shared_scratch, declared near the top of this file (right before
; file_init) -- see that declaration's own big comment for the full
; reasoning. No storage lives here anymore.

; fsk_*: scratch for file_seek (2026-07-20). Args stashed to memory
; immediately on entry (fsk_whence/fsk_off_hi/fsk_off_lo/fsk_fcb),
; since _switch_drive and fat_get both clobber broadly. fsk_target is
; the resolved absolute position (widened 2->4 bytes, 2026-07-26,
; >64K support). fsk_boff/fsk_cluster_idx/fsk_sector_in_clust (their
; own separate, permanently-allocated fields, mirroring fa_boff/
; fa_cluster_idx/fa_sector_in_clust's identical role in file_open's own
; append-mode positioning) REMOVED 2026-07-27 -- both copies of that
; positioning math were consolidated into the shared _fcb_seek_to,
; whose own fst_boff/fst_cluster_idx/fst_sector_in_clust now live in
; _shared_scratch instead (see this file's own #define block, and
; _fcb_seek_to's own header for why consolidating was judged safe:
; both copies had already been independently hardware-bug-hunted and
; fixed identically twice, meaning nothing had diverged between them).
fsk_whence:         db      0
fsk_off_hi:         dw      0
fsk_off_lo:         dw      0
fsk_fcb:            dw      0
fsk_target:         dw      0,0             ; 4 bytes, big-endian

                public  file_dirent
                public  fo_name
                public  fo_mode
                public  fo_fcb
                public  fo_iobuf
                public  fo_drive
                public  fr_request
                public  fcrw_slot
                public  fcrw_iobuf
                public  fc_shortname
                public  fc_needs_lfn
                public  fc_namelen
                public  fc_lfncount
                public  fc_checksum
                public  fc_target_lba
                public  fc_grow_lba
                public  fc_target_off
                public  fc_elba
                public  fc_new_attr
                public  fc_new_cluster
                public  fc_new_size
                public  fc_eoff
                public  fc_base8
                public  fc_namepart_len
                public  fc_suffix_n
                public  fc_suffix_tens
                public  fc_suffix_ones
                public  fc_collision
                public  fc_saved_sect
                public  fc_saved_eptr
                public  fc_saved_eleft
                public  fc_saved_lba
                public  fc_saved_lfnok
                public  csc_sector_count
                public  fsk_whence
                public  fsk_off_hi
                public  fsk_off_lo
                public  fsk_fcb
                public  fsk_target

            endp
