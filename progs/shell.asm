;
; shell.asm - ELF-DOS command shell
;
; Loaded and run repeatedly by the kernel's own run_loop (see
; kernel_init in kernel/kernel.asm) -- each time this program runs, it
; prompts for and resolves exactly ONE command line, then returns. It
; CANNOT call K_PROG_LOAD/K_PROG_EXEC itself to run the resolved
; command directly: this program lives at PROG_BASE, the same fixed
; address any loaded command also loads to, so loading a command here
; would overwrite this program's own currently-executing code before
; it could safely return. Instead, this program's only job is: read a
; command line, resolve it to a path (bare name -> "/bin/"+name; a
; name containing '/' -> used as-is, loaded directly), write that path
; plus the tail's location into the fixed RUN_PATH/RUN_TAIL_PTR
; addresses, and return -- the kernel's own run_loop does the actual
; loading and running, safely, from kernel memory. See kernel.inc's
; own comment on RUN_PATH/RUN_TAIL_PTR for the full protocol.
;
; No built-in commands -- every command line is resolved as an
; external program via this same hand-off. See include/kernel_api.inc
; for the K_GETCURDIR/K_SETCURDIR/K_DIR_OPEN/K_DIR_READ calls other
; programs use instead of reaching into kernel internals.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            call    print_prompt

            mov     rf, LINE_BUF
            ldi     127
            plo     rc
            ldi     0
            phi     rc                  ; RC = 127 (buffer length for K_INPUTL)
            call    K_INPUTL

            call    K_INMSG
            db      13,10,0

            ; skip leading whitespace
            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char

            ; empty line? just re-prompt -- no kernel round-trip needed
            ldn     rf
            lbz     start

            mov     ra, rf              ; RA = start of the program name

            ; find the end of the program name (first space or NUL)
            mov     rf, ra
name_scan:
            ldn     rf
            lbz     name_end
            xri     ' '
            lbz     name_end
            inc     rf
            lbr     name_scan
name_end:
            ; RF -> the space or NUL right after the program name
            ldn     rf
            lbz     have_tail           ; NUL: no arguments, RF already there

            ; there's a space: null-terminate the program name in place
            ; (LINE_BUF is scratch for this one command line anyway) and
            ; advance past it to the argument text
            ldi     0
            str     rf
            inc     rf
            call    f_ltrim             ; RF = start of the trimmed command tail

have_tail:
            ; RF = pointer to the command tail (possibly an empty
            ; string). Publish it now, before RF/RD get reused as
            ; scratch below for path resolution.
            mov     rb, RUN_TAIL_PTR
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; RUN_TAIL_PTR = tail pointer

;------------------------------------------------------------------
; Resolve RA (the null-terminated program name) into RUN_PATH: a name
; containing '/' is used as-is (a full path, loaded directly per the
; user's own instruction); otherwise "/bin/" + name. Both copy loops
; are bounds-checked against RUN_PATH_LEN so an unusually long name
; truncates safely instead of overrunning past RUN_PATH's own 64-byte
; allocation (which sits just below RUN_TAIL_PTR -- an unbounded copy
; here would silently corrupt the tail pointer just written above).
;------------------------------------------------------------------
            mov     rf, ra
scan_slash:
            ldn     rf
            lbz     no_slash            ; reached NUL: no '/' found
            xri     '/'
            lbz     have_slash
            inc     rf
            lbr     scan_slash

have_slash:
            ; full path given -- copy it as-is into RUN_PATH
            mov     rd, ra
            mov     rf, RUN_PATH
            ldi     RUN_PATH_LEN - 1    ; leave room for the forced NUL
            plo     rc
copy_path_loop:
            glo     rc
            lbz     force_term
            lda     rd
            str     rf
            lbz     resolved
            inc     rf
            dec     rc
            lbr     copy_path_loop

no_slash:
            ; bare name -- write "/bin/" then the name
            mov     rf, RUN_PATH
            ldi     RUN_PATH_LEN - 1
            plo     rc
            mov     rd, bin_prefix
copy_prefix_loop:
            glo     rc
            lbz     force_term
            lda     rd
            lbz     copy_prefix_done    ; end of "/bin/" -- don't copy
                                        ; its own NUL, the name follows
            str     rf
            inc     rf
            dec     rc
            lbr     copy_prefix_loop
copy_prefix_done:
            mov     rd, ra
copy_name_loop:
            glo     rc
            lbz     force_term
            lda     rd
            str     rf
            lbz     resolved
            inc     rf
            dec     rc
            lbr     copy_name_loop

force_term:
            ldi     0
            str     rf                  ; truncate: RC reaching 0 means
                                        ; RUN_PATH_LEN-1 bytes were
                                        ; already written, so RF is
                                        ; exactly at the last in-bounds
                                        ; byte here
resolved:
            ldi     0                   ; exit code 0
            rtn

bin_prefix: db      "/bin/",0

;------------------------------------------------------------------
; print_prompt: print "C:/> " at root, "C:/<name>> " one level under
; root, or "C:.../<name>> " deeper -- <name> is always just the
; current directory's own name, never the full path (kept short and
; cheap on purpose; PWD already exists for the full path). Reuses
; PWD's own "find my own name" trick (open current dir, find '..' to
; get the parent's cluster, open the parent, scan for the entry whose
; DIRENT_CLUST matches) but only ONE level -- pwd.asm's own header
; explains why FAT records no "my own name"/"path from root" anywhere,
; only each directory's parent link.
;
; Args:    none
; Returns: nothing (prints the prompt directly)
; Modifies: everything (R7-RD) -- called once at the very top of
;           start, before any other state exists to protect.
;------------------------------------------------------------------
print_prompt:
            call    K_GETCURDIR         ; RD = current directory cluster

            ; already at root?
            ghi     rd
            lbnz    pp_not_root
            glo     rd
            lbnz    pp_not_root

            call    K_INMSG
            db      "C:/> ",0
            rtn

pp_not_root:
            mov     rf, pp_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; pp_clust = cur_dir

            ; --- open cur_dir, find its '..' entry -> parent cluster ---
            call    K_DIR_OPEN          ; RD still = cur_dir

pp_find_dotdot:
            mov     rf, pp_dirent
            call    K_DIR_READ
            lbdf    pp_ioerr            ; ran out of entries: shouldn't
                                        ; happen for a real subdirectory

            mov     rf, pp_dirent       ; RF = entry name
            mov     rd, pp_dotdot       ; RD = ".."
            call    f_strcmp
            lbnz    pp_find_dotdot

            ; parent = this entry's DIRENT_CLUST
            mov     rf, pp_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd
            mov     rf, pp_parent
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; pp_parent = RD

            ; --- open parent, find the entry whose cluster == pp_clust ---
            call    K_DIR_OPEN          ; RD is still = parent

pp_find_self:
            mov     rf, pp_dirent
            call    K_DIR_READ
            lbdf    pp_ioerr            ; ran out: shouldn't happen --
                                        ; pp_clust must appear once in
                                        ; its own parent's listing

            ; compare this entry's cluster against pp_clust, high byte
            ; then low byte (same SM-based equality idiom pwd.asm uses)
            mov     rf, pp_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = entry cluster high byte,
                                        ; RF -> entry cluster low byte
            str     r2
            mov     rb, pp_clust
            ldn     rb                  ; D = pp_clust high byte
            sm                          ; D = pp_clust.hi - entry.hi
            lbnz    pp_find_self        ; mismatch: keep looking

            ldn     rf                  ; D = entry cluster low byte
            str     r2
            inc     rb                  ; RB -> pp_clust low byte
            ldn     rb                  ; D = pp_clust low byte
            sm                          ; D = pp_clust.lo - entry.lo
            lbnz    pp_find_self        ; mismatch: keep looking

            ; match: pp_dirent's name is our own name. Reload pp_parent
            ; fresh from memory (not any register -- the scan above
            ; used RD/RF/RB freely) to decide which prompt form to use.
            mov     rf, pp_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = pp_parent

            ghi     rd
            lbnz    pp_deep
            glo     rd
            lbnz    pp_deep

            ; parent is root: "C:/<name>> "
            call    K_INMSG
            db      "C:/",0
            mov     rf, pp_dirent
            call    K_MSG
            call    K_INMSG
            db      "> ",0
            rtn

pp_deep:
            ; parent is itself a subdirectory: "C:.../<name>> "
            call    K_INMSG
            db      "C:.../",0
            mov     rf, pp_dirent
            call    K_MSG
            call    K_INMSG
            db      "> ",0
            rtn

pp_ioerr:
            ; shouldn't happen for a real directory -- fall back to a
            ; plain, always-safe prompt rather than fail the whole
            ; command loop over a cosmetic feature
            call    K_INMSG
            db      "C:> ",0
            rtn

pp_dotdot:  db      "..",0
pp_clust:   dw      0
pp_parent:  dw      0
pp_dirent:  ds      DIRENT_LEN

            end     start
