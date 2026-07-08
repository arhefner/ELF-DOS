;
; path.asm - path resolution (multi-component paths, absolute/relative)
;
; Provides:
;   path_resolve -- resolve a path string to (parent directory
;                   cluster, final path component)
;
; A path is a sequence of PATH_SEP ('/')-separated components. A
; leading PATH_SEP means resolve from the FAT16 root (cluster 0);
; otherwise resolution starts from the caller-supplied base cluster
; (normally cur_dir, or K_GETCURDIR's result for a program). Every
; component except the last is looked up as a directory via
; dir_open/dir_read, exactly like a normal filename lookup -- '.'
; and '..' need no special-casing since FAT directories store them
; as real entries (see dir.asm). The last component is NOT looked up
; here; callers decide what to do with it (file_open searches for a
; FILE; CD searches for a DIRECTORY).
;
; The input string is copied into a kernel-owned scratch buffer
; (path_buf) before parsing, so the caller's own string is never
; modified. The returned final-component pointer points INTO that
; scratch buffer -- like the RA command-tail pointer programs already
; receive at entry, it's a plain pointer into kernel memory (this
; machine has no memory protection), valid until the next call that
; reuses path_buf (i.e. the next path_resolve call).
;
; Register conventions: dir_open/dir_read are used internally and
; clobber R9/RA/RB/RC/RD/RF (see dir.asm's own header comment), so
; none of the walk state below is kept in registers across those
; calls -- only in the presolve_* scratch variables.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

; cross-file references
            extrn   dir_open
            extrn   dir_read

; same-file data references (required even within the same file)
            extrn   path_buf
            extrn   path_dirent
            extrn   presolve_ptr
            extrn   presolve_clust
            extrn   presolve_comp

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

                public  path_buf
                public  path_dirent
                public  presolve_ptr
                public  presolve_clust
                public  presolve_comp

                endp

;==================================================================
; path_resolve: resolve a path to (parent directory cluster, final
; path component)
;
; Args:   RF = pointer to null-terminated path string (caller's own
;              buffer; not modified)
;         RD = base cluster for relative resolution (ignored if the
;              path has a leading PATH_SEP; use 0 for the FAT16 root)
; Returns: RD = resolved parent directory cluster
;          RF = pointer to the final path component, null-terminated,
;               inside path_buf (empty string if the path was empty,
;               "/", or ended in a separator -- callers decide what
;               an empty final component means for them)
;          DF = 0 on success, DF = 1 if an intermediate component was
;               not found, or was found but is not a directory
; Modifies: R9, RA, RB, RC, RD, RF
;==================================================================

            proc    path_resolve

            ; --- copy the caller's path into path_buf ---
            ; RD currently holds the base cluster -- stash it in RB
            ; across the copy (which needs RD as the copy source ptr)
            ghi     rd
            phi     rb
            glo     rd
            plo     rb                  ; RB = base cluster (stashed)

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

            ; --- determine starting cluster and first component ---
            mov     rf, path_buf
            ldn     rf
            xri     PATH_SEP
            lbnz    presolve_relative

            ; leading separator: start from root, skip past it
            inc     rf                  ; RF -> path_buf + 1
            ldi     0
            phi     rd
            plo     rd                  ; RD = 0 (root)
            lbr     presolve_have_start

presolve_relative:
            ; RF already = path_buf (no leading separator to skip)
            ghi     rb
            phi     rd
            glo     rb
            plo     rd                  ; RD = base cluster (restored)

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
            mov     rf, path_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     presolve_err        ; not a directory: reject

            ; advance presolve_clust to this entry's cluster
            mov     rf, path_dirent
            add16   rf, DIRENT_CLUST
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
