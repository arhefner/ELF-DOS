;
; pwd.asm - print the current directory's full path from root
;
; Usage: PWD
;
; FAT stores no "my own name" or "path from root" anywhere -- a
; directory only knows its own cluster and its parent's cluster (via
; its '..' entry). To print a path, PWD walks UP from the current
; directory to the root, and at each level finds "my own name" by
; searching the PARENT directory for the entry whose first cluster
; matches the cluster just come from (the only place that name is
; actually recorded -- the mirror image of K_PATH_RESOLVE, which
; goes name -> cluster; this goes cluster -> name).
;
; Path components are discovered leaf-to-root but need to print
; root-to-leaf, so the path is assembled backwards: cursor starts at
; the end of path_buf (on the null terminator) and each level's
; "/name" is prepended by moving cursor left, one level per loop.
;
; depth_left bounds the walk (see PWD_MAX_DEPTH) so a corrupted
; filesystem with a directory cycle in '..' can't loop forever --
; it does NOT fully bound path_buf usage against pathological long
; LFN names at every level, which is a known, accepted simplification
; (128 bytes is generous for realistic directory names/depths).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

PATH_BUF_LEN:   equ     128
PWD_MAX_DEPTH:  equ     16

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            call    K_GETCURDIR         ; RD = current directory cluster

            mov     rf, clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; clust = cur_dir

            ; already at root?
            ghi     rd
            lbnz    pwd_walk
            glo     rd
            lbnz    pwd_walk

            call    K_INMSG
            db      "/",13,10,0
            ldi     0
            rtn

pwd_walk:
            ; cursor = path_buf + PATH_BUF_LEN - 1, null-terminated --
            ; the path is assembled backwards from here
            mov     rf, path_buf
            add16   rf, PATH_BUF_LEN - 1
            ldi     0
            str     rf
            mov     rb, cursor
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; cursor = pointer to the null

            mov     rf, depth_left
            ldi     PWD_MAX_DEPTH
            str     rf

pwd_loop:
            mov     rf, depth_left
            ldn     rf
            lbz     pwd_toodeep
            smi     1
            str     rf                  ; depth_left -= 1

            ; --- open clust, find its '..' entry -> parent cluster ---
            mov     rf, clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = clust
            call    K_DIR_OPEN

pwd_find_dotdot:
            mov     rf, dir_result
            call    K_DIR_READ
            lbdf    pwd_ioerr           ; ran out of entries: shouldn't
                                        ; happen for a real subdirectory

            mov     rf, dir_result      ; RF = entry name
            mov     rd, dotdot          ; RD = ".."
            call    f_strcmp
            lbnz    pwd_find_dotdot

            ; parent = this entry's DIRENT_CLUST
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd
            mov     rf, parent
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; parent = RD

            ; --- open parent, find the entry whose cluster == clust ---
            call    K_DIR_OPEN          ; RD is still = parent

pwd_find_self:
            mov     rf, dir_result
            call    K_DIR_READ
            lbdf    pwd_ioerr           ; ran out: shouldn't happen --
                                        ; clust must appear once in
                                        ; its own parent's listing

            ; compare this entry's cluster (dir_result+DIRENT_CLUST)
            ; against clust, high byte then low byte (same SM-based
            ; equality idiom as file.asm's io_owner check)
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = entry cluster high byte,
                                        ; RF -> entry cluster low byte
            str     r2
            mov     rb, clust
            ldn     rb                  ; D = clust high byte
            sm                          ; D = clust.hi - entry.hi
            lbnz    pwd_find_self       ; mismatch: keep looking

            ldn     rf                  ; D = entry cluster low byte
            str     r2
            inc     rb                  ; RB -> clust low byte
            ldn     rb                  ; D = clust low byte
            sm                          ; D = clust.lo - entry.lo
            lbnz    pwd_find_self       ; mismatch: keep looking

            ; match: dir_result's name is this level's path component

            ; --- prepend "/" + name to path_buf ---
            mov     ra, dir_result      ; RA = name start
            mov     rf, ra
pwd_namelen:
            ldn     rf
            lbz     pwd_namelen_done
            inc     rf
            lbr     pwd_namelen
pwd_namelen_done:
            ; RF = pointer to the name's null terminator
            mov     rc, rf
            sub16   rc, ra              ; RC = namelen

            mov     rf, cursor
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = cursor
            sub16   rd, rc              ; RD = cursor - namelen (name dest)

            mov     rb, rd              ; RB = copy destination
pwd_copy_name:
            glo     rc
            lbz     pwd_copy_done
            lda     ra                  ; D = source char, RA++
            str     rb
            inc     rb
            dec     rc
            lbr     pwd_copy_name
pwd_copy_done:
            dec     rd                  ; make room for the separator
            ldi     '/'
            str     rd

            mov     rf, cursor
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; cursor = RD (new position)

            ; --- move up one level: clust = parent ---
            mov     rf, parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; clust = parent

            ; if we just reached root, we're done -- otherwise walk
            ; up another level (RD is still = parent from just above)
            ghi     rd
            lbnz    pwd_loop
            glo     rd
            lbnz    pwd_loop

            mov     rf, cursor
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = cursor (start of the path)
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            ldi     0
            rtn

pwd_ioerr:
            call    K_INMSG
            db      "Error reading directory structure.",13,10,0
            ldi     1
            rtn

pwd_toodeep:
            call    K_INMSG
            db      "Path too deep.",13,10,0
            ldi     1
            rtn

clust:      dw      0
parent:     dw      0
cursor:     dw      0
depth_left: db      0
dotdot:     db      "..",0
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for K_DIR_READ
path_buf:   ds      PATH_BUF_LEN

            end     start
