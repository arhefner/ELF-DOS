;
; dir.asm - FAT16 directory traversal
;
; Provides:
;   dir_open  -- initialize directory iterator for a cluster
;   dir_read  -- read next valid directory entry into caller's buffer
;
; Both root and subdirectory cluster chains are handled.
; Long File Names (LFN) are assembled and verified against the
; 8.3 checksum.  8.3 names are used as fallback when no valid
; LFN is present.
;
; Result buffer layout (DIRENT_LEN bytes, caller-provided):
;   [DIRENT_NAME]    null-terminated filename (up to 127 chars)
;   [DIRENT_ATTR]    FAT attribute byte
;   [DIRENT_CLUST]   first cluster, 2 bytes, big-endian
;   [DIRENT_SIZE]    file size, 4 bytes, big-endian
;   [DIRENT_WRTTIME] last-write time, 2 bytes, big-endian, packed FAT format
;   [DIRENT_WRTDATE] last-write date, 2 bytes, big-endian, packed FAT format
;
; dir_read skips:
;   deleted entries (first byte = $E5)
;   volume label entries (ATTR_VOLID set but not LFN)
;   the '.' and '..' entries ARE returned (they are valid entries)
;
; Register conventions used within this module:
;   R9   saved result buffer pointer (across the main loop)
;   RA   current directory entry pointer in dir_buf
;   RB   destination pointer (in name-building helpers)
;   RC   loop counter / scratch
;   RD   cluster / data word
;   RF   general-purpose pointer
;   R7/R8 LBA for f_ideread (set just before each call)
;
; dir_sect is initialised to $FF by dir_open so that the first
; call to _dir_next_sector increments it to 0 (the first sector).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   dir_buf
            extrn   fat_get
            extrn   bpb_spc
            extrn   bpb_spc_shift
            extrn   bpb_root_lba
            extrn   bpb_root_ents
            extrn   bpb_data_lba

; same-file proc and data references (required even within the same file)
            extrn   dir_clust
            extrn   dir_sect
            extrn   dir_eptr
            extrn   dir_eleft
            extrn   dir_lfn
            extrn   dir_lfn_chk
            extrn   dir_lfn_ok
            extrn   dir_cur_lba
            extrn   dir_last_off
            extrn   dns_diag_buf        ; TEMPORARY DIAGNOSTIC
            extrn   dns_diag_lb         ; TEMPORARY DIAGNOSTIC
            extrn   _dir_next_sector
            extrn   _cluster_to_lba
            extrn   _dir_fmt83
            extrn   _dir_proc_lfn
            extrn   _dir_chksum
            extrn   _lfn_extract

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

; TEMPORARY DIAGNOSTIC scratch: 2 hex digits + null, used by
; _dir_next_sector to print dir_clust's low byte every time it loads
; a new sector -- see CLAUDE.md's REN bullet / ren5.txt for why
; (investigating a phantom duplicate-entry display bug that does not
; appear when the same disk is checked on the host machine).
dns_diag_buf:   ds      3

; TEMPORARY DIAGNOSTIC scratch: LINE_BUF dump buffer (24 chars + null),
; used by _dir_next_sector's own clust= print above
dns_diag_lb:    ds      25

                public  dir_clust
                public  dir_sect
                public  dir_eptr
                public  dir_eleft
                public  dir_lfn
                public  dir_lfn_chk
                public  dir_lfn_ok
                public  dir_cur_lba
                public  dir_last_off
                public  dns_diag_buf
                public  dns_diag_lb

                endp

;==================================================================
; dir_open: initialise directory iterator
;
; Args:   RD = starting cluster (0 for FAT16 root directory)
; Returns: nothing
;==================================================================

            proc    dir_open

            ; store starting cluster (big-endian)
            mov     rf, dir_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; dir_sect = $FF so first _dir_next_sector call loads sector 0
            mov     rf, dir_sect
            ldi     $FF
            str     rf

            ; dir_eleft = 0 forces sector load on first dir_read call
            mov     rf, dir_eleft
            ldi     0
            str     rf

            ; clear LFN state
            ; BUG FIX: this was missing "ldi 0" before the str -- "mov
            ; rf, dir_lfn_ok" itself clobbers D (gotcha #4), so this
            ; stored dir_lfn_ok's own address low byte ($49, confirmed
            ; nonzero via the linked symbol table) instead of 0, every
            ; time dir_open ran. Every other write to dir_lfn_ok in
            ; this file correctly reloads D fresh right before the str
            ; (see lines below) -- this one was an isolated slip.
            mov     rf, dir_lfn_ok
            ldi     0
            str     rf

            rtn

;==================================================================
; dir_read: fetch the next valid directory entry
;
; Args:   RF = pointer to caller's DIRENT_LEN-byte result buffer
; Returns: DF = 0 and result buffer filled with entry data
;          DF = 1 if end of directory or I/O error
;==================================================================

            endp

            proc    dir_read

            mov     r9, rf              ; save result buffer in R9

            ; load current entry pointer into RA
            mov     rf, dir_eptr
            lda     rf                  ; D = eptr high byte
            phi     ra
            ldn     rf                  ; D = eptr low byte
            plo     ra                  ; RA = current entry pointer

;------------------------------------------------------------------
; Main loop: advance entry pointer, load new sector if needed
;------------------------------------------------------------------
drd_loop:
            ; if no entries remain in the current sector, load the next
            mov     rf, dir_eleft
            ldn     rf
            lbnz    drd_check_entry

            call    _dir_next_sector    ; load next sector into dir_buf
            lbdf    drd_eof             ; end of directory or I/O error

            ; reset entry pointer and count for the new sector
            mov     ra, dir_buf
            mov     rf, dir_eleft
            ldi     DIR_ENT_PER_SEC
            str     rf                  ; dir_eleft = 16

;------------------------------------------------------------------
; Examine the entry RA points to
;------------------------------------------------------------------
drd_check_entry:
            ldn     ra                  ; D = first byte of entry (peek)
            lbz     drd_eof             ; $00 = end of directory marker

            ; check for deleted entry ($E5)
            xri     $E5
            lbz     drd_skip_no_lfn     ; skip deleted, clear LFN state

            ; read attribute byte (at offset DE_ATTR = 11)
            mov     rf, ra
            add16   rf, DE_ATTR
            ldn     rf                  ; D = attribute byte
            plo     rc                  ; save attribute in RC.0

            ; is this an LFN entry? (attr == ATTR_LFN = $0F)
            xri     ATTR_LFN
            lbz     drd_is_lfn

            ; reload attribute and check for volume label
            glo     rc
            ani     ATTR_VOLID
            lbnz    drd_skip_no_lfn     ; skip volume labels, clear LFN

;------------------------------------------------------------------
; Valid 8.3 directory entry -- build the result
;------------------------------------------------------------------
            ; compute 8.3 name checksum
            mov     rf, ra              ; RF = entry base (name is at offset 0)
            call    _dir_chksum         ; D = computed checksum
            plo     rc                  ; RC.0 = computed checksum

            ; use LFN name if available and checksum matches
            mov     rf, dir_lfn_ok
            ldn     rf
            lbz     drd_use83           ; no LFN available

            mov     rf, dir_lfn_chk
            ldn     rf                  ; D = expected checksum from LFN entries
            str     r2                  ; [R2] = expected checksum
            glo     rc                  ; D = computed checksum
            sm                          ; D = computed - expected
            lbnz    drd_use83           ; mismatch: fall back to 8.3 name

            ; LFN is valid: copy dir_lfn to result[DIRENT_NAME]
            ; (confirmed: f_strcpy only touches RF/RD/D, so ra/r9
            ; need no protection here)
            mov     rf, dir_lfn         ; RF = LFN source
            mov     rd, r9              ; RD = result buffer (name at offset 0)
            call    f_strcpy

            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF right after
            ; f_strcpy returns, before drd_got_name's own field-copy
            ; operations run -- copy14.txt narrowed corruption to
            ; somewhere between _dir_proc_lfn finishing (clean) and
            ; the fully-decoded entry being returned (corrupted), and
            ; this is the one call in between whose own register/
            ; memory contract was assumed rather than fully verified
            ; (comment above: "confirmed... RF/RD/D" -- this checks
            ; that assumption directly). RA/R9 protected via push/pop
            ; since if the assumption is wrong, clobbering them here
            ; would introduce a SECOND bug on top of this one.
            push    ra
            push    r9
            call    f_inmsg
            db      13,10,"DIAG post-strcpy lb='",0
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8
drd_sc_lb_loop:
            lda     rf
            lbnz    drd_sc_lb_have
            ldi     '.'
drd_sc_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    drd_sc_lb_loop
            ldi     0
            str     rb
            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            pop     r9
            pop     ra
            ; END TEMPORARY DIAGNOSTIC

            lbr     drd_got_name

drd_use83:  ; format 8.3 name into result[DIRENT_NAME]
            mov     rf, ra              ; RF = entry (name at offset 0)
            mov     rd, r9              ; RD = result name buffer
            call    _dir_fmt83

drd_got_name:
            ; write attribute to result[DIRENT_ATTR]
            ;
            ; BUG FIX: "mov rf, r9" and "add16 rf, CONST" both clobber D
            ; as a side effect of their own internal arithmetic (mov's
            ; final GLO leaves D = source.lo; add16's carry-propagating
            ; ADCI leaves D = the computed address's final high byte) --
            ; so the attribute byte read below did NOT survive across
            ; them, and this was silently storing a byte derived from
            ; dir_result's own address instead of the real attribute.
            ; The cluster/size writes just below don't have this bug:
            ; they stash the value in RD/RB/RC and explicitly reload it
            ; after the address computation, which this now also does.
            mov     rf, ra
            add16   rf, DE_ATTR
            ldn     rf                  ; D = attribute byte
            plo     rc                  ; stash it (see BUG FIX note)
            mov     rf, r9
            add16   rf, DIRENT_ATTR
            glo     rc                  ; D = attribute byte (reloaded)
            str     rf                  ; result[DIRENT_ATTR] = attr

            ; write first cluster to result[DIRENT_CLUST] (big-endian)
            ; cluster is stored little-endian at DE_CLUSTER (offset 26)
            mov     rf, ra
            add16   rf, DE_CLUSTER
            lda     rf                  ; D = cluster low byte (LE byte 0)
            plo     rd                  ; RD.0 = cluster low
            ldn     rf                  ; D = cluster high byte (LE byte 1)
            phi     rd                  ; RD.1 = cluster high
            mov     rf, r9
            add16   rf, DIRENT_CLUST
            ghi     rd
            str     rf                  ; result[DIRENT_CLUST]   = cluster high
            inc     rf
            glo     rd
            str     rf                  ; result[DIRENT_CLUST+1] = cluster low

            ; write file size to result[DIRENT_SIZE] (big-endian)
            ; size is 4 bytes little-endian at DE_SIZE (offset 28)
            mov     rf, ra
            add16   rf, DE_SIZE
            lda     rf                  ; D = size byte 0 (LSB)
            plo     rb                  ; save
            lda     rf                  ; D = size byte 1
            phi     rb                  ; save
            lda     rf                  ; D = size byte 2
            plo     rc                  ; save
            ldn     rf                  ; D = size byte 3 (MSB)
            phi     rc                  ; RC.1:RC.0:RB.1:RB.0 = size
            mov     rf, r9
            add16   rf, DIRENT_SIZE
            ghi     rc                  ; MSB first
            str     rf
            inc     rf
            glo     rc
            str     rf
            inc     rf
            ghi     rb
            str     rf
            inc     rf
            glo     rb
            str     rf                  ; LSB last

            ; write last-write time to result[DIRENT_WRTTIME] (big-endian)
            ; time is 2 bytes little-endian at DE_WRTTIME (offset 22)
            mov     rf, ra
            add16   rf, DE_WRTTIME
            lda     rf                  ; D = time low byte (LE byte 0)
            plo     rd
            ldn     rf                  ; D = time high byte (LE byte 1)
            phi     rd
            mov     rf, r9
            add16   rf, DIRENT_WRTTIME
            ghi     rd
            str     rf                  ; result[DIRENT_WRTTIME]   = high
            inc     rf
            glo     rd
            str     rf                  ; result[DIRENT_WRTTIME+1] = low

            ; write last-write date to result[DIRENT_WRTDATE] (big-endian)
            ; date is 2 bytes little-endian at DE_WRTDATE (offset 24)
            mov     rf, ra
            add16   rf, DE_WRTDATE
            lda     rf                  ; D = date low byte (LE byte 0)
            plo     rd
            ldn     rf                  ; D = date high byte (LE byte 1)
            phi     rd
            mov     rf, r9
            add16   rf, DIRENT_WRTDATE
            ghi     rd
            str     rf                  ; result[DIRENT_WRTDATE]   = high
            inc     rf
            glo     rd
            str     rf                  ; result[DIRENT_WRTDATE+1] = low

            ; clear LFN state
            mov     rf, dir_lfn_ok
            ldi     0
            str     rf

            ; record this entry's byte offset within the current
            ; sector (dir_cur_lba), before RA advances past it --
            ; see dir_last_off's comment in _dir_data
            mov     rf, dir_buf
            glo     rf
            str     r2
            glo     ra
            sm                          ; D = ra.lo - dir_buf.lo, DF=1 if no borrow
            plo     rb                  ; RB.0 = offset low byte
            ghi     rf
            str     r2
            ghi     ra
            smb                         ; D = ra.hi - dir_buf.hi - borrow
            phi     rb                  ; RB = byte offset within dir_buf

            mov     rf, dir_last_off
            ghi     rb
            str     rf
            inc     rf
            glo     rb
            str     rf                  ; dir_last_off stored

            ; advance entry pointer past this entry
            add16   ra, DIR_ENT_SIZE    ; RA += 32
            mov     rf, dir_eleft
            ldn     rf
            smi     1
            str     rf                  ; dir_eleft -= 1

            ; save updated entry pointer for next call
            mov     rf, dir_eptr
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            ; TEMPORARY DIAGNOSTIC: print the entry name just decoded
            ; (R9 = result buffer, DIRENT_NAME at offset 0, still
            ; valid here) alongside a LINE_BUF dump -- copy12.txt
            ; proved corruption happens somewhere while decoding
            ; cluster D2's own entries (init4.rc, TEST.BIN), between
            ; the clean clust=D2 print and the corrupted drd_eof
            ; print. This fires once per successfully-decoded entry,
            ; correlating "which entry" with "already corrupted?".
            call    f_inmsg
            db      13,10,"DIAG drd entry='",0
            mov     rf, r9
            call    f_msg
            call    f_inmsg
            db      "' lb='",0
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8
drd_entry_lb_loop:
            lda     rf
            lbnz    drd_entry_lb_have
            ldi     '.'
drd_entry_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    drd_entry_lb_loop
            ldi     0
            str     rb
            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            clc                         ; DF = 0 = success
            rtn

;------------------------------------------------------------------
; LFN entry: process it and loop to next entry
;------------------------------------------------------------------
drd_is_lfn:
            push    ra                  ; save entry pointer (proc modifies RA)
            call    _dir_proc_lfn       ; RA = entry pointer (already set)

            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF right after
            ; _dir_proc_lfn returns, before drd_got_name's own
            ; processing of the FOLLOWING short entry runs -- splits
            ; "corruption during THIS LFN entry's own processing" from
            ; "corruption during the next short entry's processing"
            ; (copy13.txt showed corruption already present by the
            ; time env3.dat's short entry finishes decoding, but not
            ; whether it happened here, during its OWN preceding LFN
            ; entry, or in drd_got_name right after).
            call    f_inmsg
            db      13,10,"DIAG post-lfn lb='",0
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8
drd_lfn_lb_loop:
            lda     rf
            lbnz    drd_lfn_lb_have
            ldi     '.'
drd_lfn_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    drd_lfn_lb_loop
            ldi     0
            str     rb
            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            pop     ra                  ; restore entry pointer
            lbr     drd_advance         ; advance and loop

;------------------------------------------------------------------
; Skip entry, clear LFN state (deleted / volume label)
;------------------------------------------------------------------
drd_skip_no_lfn:
            mov     rf, dir_lfn_ok
            ldi     0
            str     rf                  ; dir_lfn_ok = 0

;------------------------------------------------------------------
; Advance entry pointer and loop
;------------------------------------------------------------------
drd_advance:
            add16   ra, DIR_ENT_SIZE    ; RA += 32
            mov     rf, dir_eleft
            ldn     rf
            smi     1
            str     rf                  ; dir_eleft -= 1
            lbr     drd_loop

;------------------------------------------------------------------
; End of directory or I/O error
;------------------------------------------------------------------
drd_eof:
            ; save current entry pointer so a resumed call works
            mov     rf, dir_eptr
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF right when dir_read
            ; itself hits a literal '$00' terminator byte mid-cluster
            ; (the MORE likely EOF path here, vs. _dir_next_sector's
            ; own dns_end -- cluster D2 was zero-filled by fc_grow
            ; when it was first allocated, so it very likely has a
            ; genuine $00 terminator right after its live entries,
            ; never needing a 4th _dir_next_sector call at all). RA
            ; holds the entry pointer, already saved to dir_eptr above
            ; -- safe to clobber RF/RB/R8 freely here since nothing
            ; else survives a DF=1 return.
            call    f_inmsg
            db      13,10,"DIAG drd_eof lb='",0
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8
drd_eof_lb_loop:
            lda     rf
            lbnz    drd_eof_lb_have
            ldi     '.'
drd_eof_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    drd_eof_lb_loop
            ldi     0
            str     rb

            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            stc                         ; DF = 1
            rtn

;==================================================================
; _dir_next_sector: advance to and load the next directory sector
;
; Increments dir_sect; for subdirectories, follows the cluster
; chain via fat_get when dir_sect reaches bpb_spc.
;
; Returns: DF = 0 and dir_buf filled with the new sector
;          DF = 1 at end of directory or on I/O error
;==================================================================

            endp

            proc    _dir_next_sector

            ; increment sector index
            mov     rf, dir_sect
            ldn     rf
            adi     1
            str     rf                  ; dir_sect++
            plo     rc                  ; RC.0 = new dir_sect

            ; is this the root directory? (dir_clust == 0)
            mov     rf, dir_clust
            lda     rf                  ; D = dir_clust high byte
            lbnz    dns_subdir
            ldn     rf                  ; D = dir_clust low byte
            lbnz    dns_subdir

;------------------------------------------------------------------
; Root directory: fixed region at bpb_root_lba
;------------------------------------------------------------------
dns_root:
            ; check dir_sect < root_sector_count
            ; root_sector_count = bpb_root_ents / 16 (shift right 4)
            mov     rf, bpb_root_ents
            lda     rf                  ; D = root_ents high byte
            phi     rd
            ldn     rf                  ; D = root_ents low byte
            plo     rd                  ; RD = root_entry_count (big-endian)
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = root_sector_count

            ; if root_sector_count > 255, dir_sect (byte) can't reach it
            ghi     rd
            lbnz    dns_root_ok         ; high byte set: more than 255 sectors

            glo     rd                  ; D = root_sector_count (fits in byte)
            str     r2                  ; [R2] = root_sector_count
            glo     rc                  ; D = dir_sect
            sm                          ; D = dir_sect - root_sector_count
            lbdf    dns_end             ; dir_sect >= count: end of root dir

dns_root_ok:
            ; LBA = bpb_root_lba + dir_sect
            mov     rf, bpb_root_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits  7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0

            ; add dir_sect (single byte, carry into R7.1 and R8.0)
            glo     rc                  ; D = dir_sect
            str     r2
            glo     r7
            add                         ; R7.0 += dir_sect, DF = carry
            plo     r7
            ghi     r7
            adci    0
            phi     r7
            glo     r8
            adci    0
            plo     r8
            lbr     dns_read

;------------------------------------------------------------------
; Subdirectory: cluster chain, follow via fat_get at cluster end
;------------------------------------------------------------------
dns_subdir:
            ; compare dir_sect against bpb_spc
            mov     rf, bpb_spc
            ldn     rf                  ; D = sectors per cluster
            str     r2                  ; [R2] = bpb_spc
            glo     rc                  ; D = dir_sect
            sm                          ; D = dir_sect - bpb_spc
            lbnf    dns_in_cluster      ; dir_sect < bpb_spc: still same cluster

            ; need the next cluster in the chain
            mov     rf, dir_sect
            ldi     0
            str     rf                  ; dir_sect = 0
            plo     rc                  ; RC.0 = 0 (sector 0 of new cluster)

            ; load current cluster into RD and call fat_get
            mov     rf, dir_clust
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd                  ; RD = current cluster

            call    fat_get             ; RD = next cluster
            lbdf    dns_err             ; I/O error

            ; check for end-of-chain (cluster >= FAT_EOC = $FFF8)
            ghi     rd
            smi     $FF
            lbnf    dns_not_eoc         ; high byte < $FF: not EOC
            glo     rd
            smi     $F8
            lbdf    dns_end             ; cluster >= $FFF8: end of chain

dns_not_eoc:
            ; save new cluster
            mov     rf, dir_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

dns_in_cluster:
            ; compute LBA of (dir_clust, dir_sect)
            mov     rf, dir_clust
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd                  ; RD = cluster number

            call    _cluster_to_lba     ; R7/R8 = LBA of first sector

            ; add dir_sect within cluster
            glo     rc                  ; D = dir_sect
            str     r2
            glo     r7
            add                         ; R7.0 += dir_sect, DF = carry
            plo     r7
            ghi     r7
            adci    0
            phi     r7
            glo     r8
            adci    0
            plo     r8

dns_read:
            ; record the LBA we're about to load, so dir_read can
            ; tell callers exactly where an entry in this sector
            ; lives on disk (see dir_cur_lba's comment in _dir_data)
            mov     rf, dir_cur_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; dir_cur_lba stored

            ; read the sector into dir_buf
            mov     rf, dir_buf
            call    f_ideread
            lbdf    dns_err

            ; TEMPORARY DIAGNOSTIC: print dir_clust's low byte as 2 hex
            ; digits every time a new sector is loaded, to directly
            ; observe the cluster-visitation sequence during a scan
            ; (investigating the phantom duplicate-entry display bug --
            ; see CLAUDE.md's REN bullet / ren5.txt).
            ; NOTE: R9 holds dir_read's saved result-buffer pointer
            ; across this call -- must not be touched here. Use RB
            ; instead (unused elsewhere in this proc).
            mov     rf, dir_clust
            inc     rf
            ldn     rf                  ; D = dir_clust low byte
            plo     rb                  ; stash byte to convert

            mov     rf, dns_diag_buf

            glo     rb                  ; D = byte
            shr
            shr
            shr
            shr                         ; D = high nibble
            smi     10
            lbnf    dns_diag_hi_digit   ; nibble < 10 (borrow, DF=0)
            adi     'A'                 ; nibble >= 10: D = nibble-10
            lbr     dns_diag_hi_store
dns_diag_hi_digit:
            adi     10+'0'
dns_diag_hi_store:
            str     rf
            inc     rf

            glo     rb                  ; D = byte
            ani     $0F                 ; D = low nibble
            smi     10
            lbnf    dns_diag_lo_digit
            adi     'A'
            lbr     dns_diag_lo_store
dns_diag_lo_digit:
            adi     10+'0'
dns_diag_lo_store:
            str     rf
            inc     rf

            ldi     0
            str     rf                  ; null-terminate dns_diag_buf

            call    f_inmsg
            db      13,10,"DIAG scan: clust=",0

            mov     rf, dns_diag_buf
            call    f_msg

            ; TEMPORARY DIAGNOSTIC: also dump LINE_BUF's first 24
            ; bytes (NUL shown as '.') at every sector load, to
            ; bisect a SEPARATE bug -- LINE_BUF getting clobbered
            ; during a mode-0 "not found" scan (confirmed happening
            ; somewhere between file_open's pre-scan and post-return
            ; points, ren8.txt-copy9.txt), narrowing down whether it
            ; happens on the cluster-10 sector, the cluster-D2 sector,
            ; or the _dir_next_sector chain-follow between them. WIDTH
            ; FIX: a first attempt at 16 bytes was too narrow -- the
            ; corruption sits at LINE_BUF offset 16 (copy10.txt), one
            ; past a 16-byte window's last visible index (0-15), so
            ; every dump looked identically clean regardless of
            ; whether the corruption had already happened. Widened to
            ; 24 to match file_open's own dumps and actually cover it.
            ; RB still free here (used above, not needed again).
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8                  ; R8.0 = loop count (R7/R8
                                        ; free here, LBA already
                                        ; consumed by f_ideread above)
dns_diag_lb_loop:
            lda     rf
            lbnz    dns_diag_lb_have
            ldi     '.'
dns_diag_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    dns_diag_lb_loop
            ldi     0
            str     rb

            call    f_inmsg
            db      " lb='",0
            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

            clc
            rtn

dns_end:
            ; TEMPORARY DIAGNOSTIC: dump LINE_BUF right when
            ; end-of-chain is detected (fat_get returned an EOC
            ; marker) -- this is a code path the success-path dump
            ; above (dns_read) NEVER exercises, since it only fires
            ; after a SUCCESSFUL sector load. copy11.txt showed
            ; LINE_BUF still clean immediately after both the
            ; cluster-10 and cluster-D2 sector loads during a
            ; not-found scan, with corruption only visible by the
            ; NEXT file_open call's entry -- meaning it happens
            ; somewhere between D2's own entries being processed and
            ; the scan concluding, and THIS end-of-chain detection
            ; (reached once D2's entries are exhausted with no match)
            ; is the one remaining untested step in that window.
            call    f_inmsg
            db      13,10,"DIAG dns_end lb='",0
            mov     rf, LINE_BUF
            mov     rb, dns_diag_lb
            ldi     24
            plo     r8
dns_end_lb_loop:
            lda     rf
            lbnz    dns_end_lb_have
            ldi     '.'
dns_end_lb_have:
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    dns_end_lb_loop
            ldi     0
            str     rb

            mov     rf, dns_diag_lb
            call    f_msg
            call    f_inmsg
            db      "'",13,10,0
            ; END TEMPORARY DIAGNOSTIC

dns_err:
            stc
            rtn

;==================================================================
; _cluster_to_lba: convert a cluster number to its starting LBA
;
; Args:   RD = cluster number (must be >= 2)
; Returns: R7/R8 set for f_ideread (first sector of that cluster)
; Modifies: R7, R8, RC, RD, RF, RA, RB
;
; Formula: LBA = bpb_data_lba + (cluster - 2) << bpb_spc_shift
;==================================================================

            endp

            proc    _cluster_to_lba

            ; RD = cluster - 2
            dec     rd
            dec     rd

            ; initialise 24-bit accumulator R7:R8.0 from RD
            ghi     rd
            phi     r7
            glo     rd
            plo     r7
            ldi     0
            plo     r8                  ; R8.0 = 0 (bits 23-16)

            ; shift left bpb_spc_shift times (multiply by sectors/cluster)
            mov     rf, bpb_spc_shift
            ldn     rf
            plo     rc                  ; RC.0 = shift count
            glo     rc
            lbz     clba_done           ; shift count 0: no multiplication

clba_shift:
            shl16   r7                  ; R7 <<= 1, DF = old bit 15
            glo     r8
            shlc                        ; R8.0 = (R8.0 << 1) | DF
            plo     r8
            dec     rc
            glo     rc
            lbnz    clba_shift

clba_done:
            ; add bpb_data_lba (3 bytes: [bits23-16, bits15-8, bits7-0])
            ; load into RA.1 (hi), RC.1 (mid), and add low byte directly
            mov     rf, bpb_data_lba
            lda     rf                  ; D = bits 23-16
            phi     ra                  ; RA.1 = bpb_data_lba bits 23-16
            lda     rf                  ; D = bits 15-8
            phi     rc                  ; RC.1 = bpb_data_lba bits 15-8
            ldn     rf                  ; D = bits  7-0

            ; add low bytes (no carry in)
            str     r2                  ; [R2] = bpb_data_lba bits 7-0
            glo     r7
            add                         ; R7.0 += bpb_data_lba.lo, DF = carry
            plo     r7

            ; add middle bytes (carry in from low add)
            ghi     rc                  ; D = bpb_data_lba bits 15-8
            str     r2
            ghi     r7
            adc                         ; R7.1 += bpb_data_lba.mid + DF
            phi     r7

            ; add high bytes (carry in from middle add)
            ghi     ra                  ; D = bpb_data_lba bits 23-16
            str     r2
            glo     r8
            adc                         ; R8.0 += bpb_data_lba.hi + DF
            plo     r8

            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)
            rtn

;==================================================================
; _dir_fmt83: format an 8.3 name from a raw directory entry
;
; Args:   RF = pointer to directory entry (name at offset 0)
;         RD = destination buffer
; Returns: null-terminated name in [RD]
; Modifies: RF, RD, RB, RC
;
; Formats as NAME.EXT with trailing spaces stripped from each
; part.  The dot is omitted when the extension is all spaces.
; The '.' and '..' entries format correctly as-is.
;==================================================================

            endp

            proc    _dir_fmt83

            ; --- Copy and trim 8-character name field ---
            mov     rb, rd              ; RB = dest start (trim boundary ref)
            ldi     8
            plo     rc                  ; RC.0 = 8 char count

fmt83_name:
            lda     rf                  ; D = name byte, RF advances
            str     rd                  ; copy to dest
            inc     rd
            dec     rc
            glo     rc
            lbnz    fmt83_name
            ; RF now points at the first extension byte (offset 8)
            ; RD points one past the 8th name char

            ; trim trailing spaces from name: back up RD while [RD-1] == ' '
            push    rf                  ; save extension pointer
fmt83_trim_name:
            dec     rd                  ; point to last written char
            ldn     rd                  ; D = that char
            xri     ' '
            lbnz    fmt83_trim_name_done ; non-space: advance RD past it and stop
            ; it's a space: continue backing up while RD >= RB
            ghi     rb
            str     r2
            ghi     rd
            sm                          ; D = rd.1 - rb.1, DF=1 if rd.1 >= rb.1
            lbnz    fmt83_trim_name     ; high bytes differ (rd.1 > rb.1): keep going
            glo     rb
            str     r2
            glo     rd
            sm                          ; D = rd.0 - rb.0, DF=1 if rd.0 >= rb.0
            lbdf    fmt83_trim_name     ; RD >= RB: keep backing up
            ; RD < RB: all 8 chars were spaces (empty name -- shouldn't happen)
            inc     rd                  ; restore RD to RB
            lbr     fmt83_no_ext
fmt83_trim_name_done:
            inc     rd                  ; advance past the non-space char

            ; --- Check whether extension has any non-space chars ---
            pop     rf                  ; restore extension pointer
            push    rf                  ; save again for the copy below
            push    rd                  ; save dest pointer (for dot removal)

            ldi     3
            plo     rc
fmt83_ext_scan:
            lda     rf                  ; D = ext byte
            xri     ' '
            lbnz    fmt83_has_ext       ; found a non-space
            dec     rc
            glo     rc
            lbnz    fmt83_ext_scan

            ; all extension bytes were spaces: clean up and finish
            pop     rd                  ; restore dest (discard dot-anchor)
            pop     rf                  ; discard extension pointer
            lbr     fmt83_null

fmt83_has_ext:
            pop     rd                  ; restore dest pointer (for dot)
            pop     rf                  ; restore extension pointer

            ; write the dot
            ldi     '.'
            str     rd
            inc     rd

            ; copy and trim 3-char extension
            mov     rb, rd              ; RB = ext dest start
            ldi     3
            plo     rc
fmt83_ext:
            lda     rf                  ; D = ext byte
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    fmt83_ext

            ; trim trailing spaces from extension
fmt83_trim_ext:
            dec     rd
            ldn     rd
            xri     ' '
            lbnz    fmt83_trim_ext_done
            ghi     rb
            str     r2
            ghi     rd
            sm                          ; D = rd.1 - rb.1, DF=1 if rd.1 >= rb.1
            lbnz    fmt83_trim_ext      ; high bytes differ (rd.1 > rb.1): keep going
            glo     rb
            str     r2
            glo     rd
            sm                          ; D = rd.0 - rb.0, DF=1 if rd.0 >= rb.0
            lbdf    fmt83_trim_ext      ; RD >= RB: keep backing up
            ; all extension spaces: remove the dot we added
            dec     rd                  ; back over the dot
            lbr     fmt83_null
fmt83_trim_ext_done:
            inc     rd                  ; past the non-space

fmt83_no_ext:
fmt83_null:
            ldi     0
            str     rd                  ; null terminator
            rtn

;==================================================================
; _dir_proc_lfn: accumulate one LFN entry into dir_lfn buffer
;
; Args:   RA = pointer to the LFN directory entry in dir_buf
; Returns: nothing (dir_lfn, dir_lfn_chk, dir_lfn_ok updated)
; Modifies: RA, RB, RC, RD, RF
;
; LFN entries arrive in descending sequence-number order (highest
; first in the directory), so each entry fills a known slice of
; the name buffer directly without reordering.
;
; Only the low byte of each UTF-16LE character is stored (ASCII
; range).  Extraction stops at U+0000 (end of name) or $FF
; (unused slot padding).
;==================================================================

            endp

            proc    _dir_proc_lfn

            ; read sequence number byte
            ldn     ra                  ; D = sequence number
            plo     rd                  ; RD.0 = seq# byte (save for later)

            ; if bit 6 (LFN_LAST = $40) is set, this is the first LFN
            ; entry we encounter in directory order (highest seq#).
            ; It establishes the checksum and clears the name buffer.
            ani     LFN_LAST
            lbz     lfn_check_valid

            ; --- First LFN entry seen (0x40 flag present) ---
            ; save checksum
            ;
            ; BUG FIX: same class of bug as drd_got_name's attribute
            ; write (see project memory) -- "mov rf, dir_lfn_chk" itself
            ; clobbers D (its own final LDI leaves D = dir_lfn_chk's low
            ; address byte), so by the time "str rf" ran, D no longer
            ; held the checksum at all. This meant dir_lfn_chk always
            ; ended up holding a byte derived from its own address,
            ; never matching the real computed checksum, so the LFN
            ; long name was never used -- always fell back to the 8.3
            ; short name. Now stashed in RB.0 across the mov.
            mov     rf, ra
            add16   rf, LFN_CHKSUM
            ldn     rf                  ; D = checksum byte
            plo     rb                  ; stash it (see BUG FIX note)
            mov     rf, dir_lfn_chk
            glo     rb                  ; D = checksum byte (reloaded)
            str     rf

            ; mark LFN as being assembled
            mov     rf, dir_lfn_ok
            ldi     1
            str     rf

            ; clear entire LFN buffer
            mov     rf, dir_lfn
            ldi     LFN_BUFLEN
            plo     rc
lfn_clear:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    lfn_clear
            lbr     lfn_get_chars

lfn_check_valid:
            ; if not building a sequence, ignore this entry
            mov     rf, dir_lfn_ok
            ldn     rf
            lbz     lfn_exit

            ; ---- Compute byte position in dir_lfn ----
            ; position = (seq# & $3F - 1) * LFN_CHARS (= * 13)
lfn_get_chars:
            glo     rd                  ; D = saved seq# byte
            ani     $3F                 ; strip LFN_LAST flag
            smi     1                   ; D = 0-based index, DF=0 if seq# was 0
            lbnf    lfn_invalid         ; seq# was 0: malformed
            plo     rc                  ; RC.0 = 0-based index

            ; multiply by LFN_CHARS (13) via repeated addition into RD
            ldi     0
            plo     rd
            phi     rd                  ; RD = 0 (position accumulator)
lfn_mul:
            glo     rc
            lbz     lfn_mul_done
            add16   rd, LFN_CHARS       ; RD += 13
            dec     rc
            lbr     lfn_mul
lfn_mul_done:
            ; RD = byte offset in dir_lfn for this entry's chars

            ; bounds check: position must fit in our buffer
            ghi     rd
            lbnz    lfn_exit            ; offset >= 256, skip
            glo     rd
            smi     LFN_BUFLEN - LFN_CHARS
            lbdf    lfn_exit            ; offset would overflow buffer

            ; RB = dir_lfn + position (destination for chars)
            mov     rf, dir_lfn
            add16   rf, rd
            mov     rb, rf              ; RB = destination pointer

            ; --- Extract chars from the three LFN name fields ---
            ; Each field: read low byte of each UTF-16LE pair, skip high byte
            ; Stop at U+0000 (null) or $FF (unused padding)

            ; Field 1: 5 chars at RA + LFN_NAME1 (offset 1)
            mov     rf, ra
            add16   rf, LFN_NAME1
            ldi     5
            plo     rc
            call    _lfn_extract
            lbdf    lfn_exit            ; null found: name complete

            ; Field 2: 6 chars at RA + LFN_NAME2 (offset 14)
            mov     rf, ra
            add16   rf, LFN_NAME2
            ldi     6
            plo     rc
            call    _lfn_extract
            lbdf    lfn_exit

            ; Field 3: 2 chars at RA + LFN_NAME3 (offset 28)
            mov     rf, ra
            add16   rf, LFN_NAME3
            ldi     2
            plo     rc
            call    _lfn_extract        ; DF result not needed after last field

lfn_exit:
            rtn

lfn_invalid:
            ; clear LFN state on malformed sequence
            mov     rf, dir_lfn_ok
            ldi     0
            str     rf
            rtn

;==================================================================
; _lfn_extract: copy RC.0 UTF-16LE chars (low bytes) from RF to RB
;
; Args:   RF = source (LFN name field, UTF-16LE)
;         RB = destination (dir_lfn buffer)
;         RC.0 = character count
; Returns: RF and RB advanced
;          DF = 0 if all chars written normally
;          DF = 1 if a null or $FF terminator was found
; Modifies: RC.0, RF, RB, D
;==================================================================

            endp

            proc    _lfn_extract

lfe_loop:
            glo     rc
            lbz     lfe_done_ok         ; all chars processed, DF already 0
            lda     rf                  ; D = low byte of UTF-16 char
            lbz     lfe_null            ; U+0000 = end of name
            xri     $FF
            lbz     lfe_null            ; $FF = unused padding slot
            xri     $FF                 ; restore D (double XOR)
            str     rb                  ; store char in LFN buffer
            inc     rb
            inc     rf                  ; skip high byte of UTF-16 unit
            dec     rc
            lbr     lfe_loop

lfe_null:
            ; write null terminator and signal end-of-name
            ldi     0
            str     rb
            stc                         ; DF = 1
            rtn

lfe_done_ok:
            inc     rf                  ; skip high byte of last char
            clc                         ; DF = 0
            rtn

;==================================================================
; _dir_chksum: compute the FAT LFN checksum of an 8.3 short name
;
; Args:   RF = pointer to 11-byte short name field
; Returns: D = checksum
; Modifies: RC.0, RF, RB.0
;
; Algorithm: for each of the 11 bytes:
;   checksum = rotate_right(checksum) + byte
; where rotate_right is: (checksum >> 1) | ((checksum & 1) << 7)
;
; BUG FIX: the loop used to test the counter via "glo rc", which
; clobbers D -- but D is where the running checksum lives between
; iterations, so it was being discarded every time, and the function
; always returned 0 (the counter's final value) instead of the real
; checksum. Now stashed in RB.0 around the counter check instead.
;==================================================================

            endp

            proc    _dir_chksum

            ldi     11
            plo     rc                  ; RC.0 = 11 (byte count)
            ldi     0                   ; D = 0 (initial checksum)

dcs_loop:
            shr                         ; D = D >> 1, DF = old bit 0
            lbdf    dcs_setb7
            lbr     dcs_add
dcs_setb7:  ori     $80                 ; put old bit 0 into bit 7
dcs_add:
            str     r2                  ; [R2] = rotated checksum
            lda     rf                  ; D = next name byte
            add                         ; D = name byte + rotated checksum
            plo     rb                  ; stash running checksum (see BUG FIX note)
            dec     rc
            glo     rc
            lbz     dcs_done            ; counter reached 0: stop
            glo     rb                  ; D = running checksum (restored)
            lbr     dcs_loop

dcs_done:
            glo     rb                  ; D = final checksum
            rtn

            endp
