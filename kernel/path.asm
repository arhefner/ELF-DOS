;
; path.asm - path resolution (multi-component paths, absolute/relative,
; drive-letter prefixes)
;
; Provides:
;   path_resolve -- resolve a path string to (parent directory
;                   cluster, final path component, resolved drive)
;
; A path may start with a 2-character drive prefix ("C:"-"F:", case-
; insensitive); if present, that names the target drive, and it is
; skipped for the rest of parsing. If absent, the target drive is
; cur_drive (the shell's currently active drive -- see kernel.asm).
; After any drive prefix, a leading PATH_SEP ('/') means resolve from
; that drive's FAT16 root (cluster 0); otherwise resolution starts
; from that drive's OWN remembered current directory
; (drive_cur_dir[target] -- NOT necessarily cur_drive's directory,
; since a path can legally name a different drive than the one that's
; currently active, e.g. "CD D:\games" while C: is active. Classic
; DOS semantics, adopted deliberately -- see kernel_setcurdir's own
; header comment in kernel.asm). Every component except the last is
; looked up as a directory via dir_open/dir_read, exactly like a
; normal filename lookup -- '.' and '..' need no special-casing since
; FAT directories store them as real entries (see dir.asm). The last
; component is NOT looked up here; callers decide what to do with it
; (file_open searches for a FILE; CD searches for a DIRECTORY).
;
; _switch_drive (fat.asm) is called as soon as the target drive is
; known, before any directory lookup -- it makes that drive's BPB
; fields and FAT cache the active ones dir_open/dir_read/fat_get read
; directly, and is a cheap no-op if that drive is already active.
; This is the single place in the whole kernel that determines "which
; drive" a path operation targets; every caller (file_open,
; dir_create, file_rename, CD, ...) gets multi-drive support for free
; through this one routine.
;
; The input string is copied into a kernel-owned scratch buffer
; (path_buf) before parsing, so the caller's own string is never
; modified. The returned final-component pointer points INTO that
; scratch buffer -- like the RA command-tail pointer programs already
; receive at entry, it's a plain pointer into kernel memory (this
; machine has no memory protection), valid until the next call that
; reuses path_buf (i.e. the next path_resolve call).
;
; Register conventions: dir_open/dir_read/_switch_drive are used
; internally and may clobber R9/RA/RB/RC/RD/RF, so none of the walk
; state below is kept in registers across those calls -- only in the
; presolve_* scratch variables. The resolved drive index is likewise
; kept in presolve_drive (memory), not a register, across the same
; calls, and only loaded into RC.0 for the final return.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   dir_open
            extrn   dir_read
            extrn   _switch_drive
            extrn   cur_drive
            extrn   drive_cur_dir

; same-file data references (required even within the same file)
            extrn   path_buf
            extrn   path_dirent
            extrn   presolve_ptr
            extrn   presolve_clust
            extrn   presolve_comp
            extrn   presolve_drive
            extrn   presolve_start

PATH_BUF_LEN:   equ     128

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

;==================================================================
; path_resolve: resolve a path to (parent directory cluster, final
; path component, resolved drive)
;
; Args:   RF = pointer to null-terminated path string (caller's own
;              buffer; not modified)
; Returns: RD = resolved parent directory cluster
;          RF = pointer to the final path component, null-terminated,
;               inside path_buf (empty string if the path was empty,
;               "/", or ended in a separator -- callers decide what
;               an empty final component means for them)
;          RC.0 = resolved drive index (0-3, 0=C..3=F)
;          DF = 0 on success, DF = 1 if an intermediate component was
;               not found, was found but is not a directory, or an
;               explicit "X:" prefix named a drive with no mounted
;               partition
; Modifies: R9, RA, RB, RC, RD, RF
;==================================================================

            proc    path_resolve

            ; --- copy the caller's path into path_buf ---
            mov     rd, rf              ; RD = source (caller's path)
            mov     rf, path_buf        ; RF = dest
            ldi     PATH_BUF_LEN - 1
            plo     rc                  ; RC.0 = max chars to copy

presolve_copy:
            lda     rd                  ; D = source byte, RD++
            str     rf                  ; copy to dest
            lbz     presolve_copy_done  ; copied the null terminator: stop
            inc     rf
            dec     rc
            glo     rc
            lbnz    presolve_copy
            ldi     0
            str     rf                  ; ran out of room: force-terminate

presolve_copy_done:

            ; --- check for a 2-char drive prefix ("C:"-"F:", case-
            ; insensitive) at the start of path_buf ---
            mov     rf, path_buf
            ldn     rf
            ani     $DF                 ; uppercase-fold. Safe: the only
                                        ; byte values that alias into
                                        ; the 'C'-'F' range checked below
                                        ; via this mask are 'C'/'c',
                                        ; 'D'/'d', 'E'/'e', 'F'/'f'
                                        ; themselves -- no other byte
                                        ; value collides.
            smi     'C'
            lbnf    presolve_no_prefix  ; < 'C': not a drive letter
            smi     4
            lbdf    presolve_no_prefix  ; >= 'C'+4 ('G' and up): not
                                        ; a drive letter

            mov     rf, path_buf
            inc     rf
            ldn     rf
            xri     ':'
            lbnz    presolve_no_prefix  ; no ':' following: not a prefix

            ; valid prefix -- recompute its drive index (0-3) fresh
            ; (the smi chain above already destroyed D) and persist
            ; it, then set presolve_start to skip past the 2-char
            ; prefix
            mov     rf, presolve_drive  ; RF -> presolve_drive (mov
                                        ; first, since it clobbers D --
                                        ; gotcha #4)
            mov     ra, path_buf
            ldn     ra
            ani     $DF
            smi     'C'
            str     rf                  ; presolve_drive = index (0-3)

            mov     rf, presolve_start
            mov     ra, path_buf
            inc     ra
            inc     ra                  ; RA -> path_buf + 2
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf                  ; presolve_start = path_buf + 2
            lbr     presolve_drive_done

presolve_no_prefix:
            mov     rf, presolve_drive  ; RF -> presolve_drive
            mov     ra, cur_drive
            ldn     ra
            str     rf                  ; presolve_drive = cur_drive

            mov     rd, path_buf        ; RD = path_buf (no prefix to
                                        ; skip)
            mov     rf, presolve_start
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; presolve_start = path_buf

presolve_drive_done:
            ; switch the active BPB/FAT-cache to the resolved drive
            ; before any lookup that depends on it
            mov     rd, presolve_drive
            ldn     rd
            call    _switch_drive       ; D = target drive index
            lbdf    presolve_err        ; drive not present

            ; --- determine starting cluster and first component ---
            mov     rf, presolve_start
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; RA = presolve_start value
                                        ; (path position after any
                                        ; drive prefix)
            mov     rf, ra              ; RF = same pointer

            ldn     rf
            xri     PATH_SEP
            lbnz    presolve_relative

            ; leading separator: start from that drive's root, skip
            ; past it
            inc     rf                  ; RF -> component after the '/'
            ldi     0
            phi     rd
            plo     rd                  ; RD = 0 (root)
            lbr     presolve_have_start

presolve_relative:
            ; RF already = start of path (no leading separator);
            ; base cluster = drive_cur_dir[target drive]. Uses RB/R9
            ; as scratch for the array-index arithmetic so RF (the
            ; component pointer) is left untouched.
            mov     rb, drive_cur_dir
            mov     r9, presolve_drive
            ldn     r9
            shl                         ; D = target_drive * 2 (entry
                                        ; size)
            plo     r9
            ldi     0
            phi     r9                  ; R9 = target_drive * 2
            add16   rb, r9              ; RB = &drive_cur_dir[target]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = drive_cur_dir[target]

presolve_have_start:
            ; store starting cluster into presolve_clust
            push    rf                  ; preserve component pointer
            mov     rf, presolve_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            pop     rf                  ; RF restored = component pointer

            ; store component pointer into presolve_ptr
            mov     rb, presolve_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

;------------------------------------------------------------------
; Main loop: scan one component, either finish (final component) or
; look it up as a subdirectory and continue
;------------------------------------------------------------------
presolve_loop:
            ; RA = start of the current component (reload from memory)
            mov     rf, presolve_ptr
            lda     rf
            phi     ra
            ldn     rf
            plo     ra

            ; scan for PATH_SEP or NUL, starting at RA
            mov     rf, ra
presolve_scan:
            ldn     rf
            lbz     presolve_final      ; NUL: this is the final component
            xri     PATH_SEP
            lbz     presolve_sep        ; separator: intermediate component
            inc     rf
            lbr     presolve_scan

presolve_final:
            ; RA = final component pointer; RD = resolved parent cluster
            mov     rf, presolve_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, presolve_drive
            ldn     rf
            plo     rc                  ; RC.0 = resolved drive
            mov     rf, ra              ; RF = final component pointer
            clc
            rtn

presolve_sep:
            ; RF -> the separator byte; null-terminate this component
            ldi     0
            str     rf
            inc     rf                  ; RF -> start of next component

            ; save it for the next outer-loop iteration
            mov     rb, presolve_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ; save this component's start (RA) for the strcmp below --
            ; dir_open/dir_read clobber RA
            mov     rb, presolve_comp
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb

            ; open presolve_clust as a directory and search it
            mov     rf, presolve_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    dir_open

presolve_find:
            mov     rf, path_dirent
            call    dir_read
            lbdf    presolve_err        ; end of directory: not found

            mov     rf, presolve_comp
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = component name pointer
            mov     rf, path_dirent     ; RF = entry name (DIRENT_NAME)
            call    f_strcmp
            lbnz    presolve_find       ; no match: keep scanning

            ; must be a directory
            mov     rf, path_dirent+DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     presolve_err        ; not a directory: reject

            ; advance presolve_clust to this entry's cluster
            mov     rf, path_dirent+DIRENT_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, presolve_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     presolve_loop       ; continue with the next component

presolve_err:
            stc
            rtn

            endp
