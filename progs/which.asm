;
; which.asm - show which file a command name would run
;
; Usage: WHICH <command> [command...]
;
; For each argument, searches exactly as progs/shell.asm's own command
; resolution does (scan_slash/no_slash/check_variants there) and prints
; the full path of the file the shell would run, or "<name>: not found".
; Keep the two in step: if the shell's search order ever changes, this
; program has to change with it.
;
;   - A name containing '/' is an explicit path: no search.
;   - Otherwise: the current directory, then <shell_drive>:/bin, then
;     each PATH entry, left to right.
;   - In each place, a name whose last component has no '.' is tried
;     as typed, then with ".bat".
;
; The same 64-byte candidate limit (RUN_PATH_LEN) and 128-byte PATH
; limit the shell uses apply here, so an over-long name or PATH entry
; behaves identically.
;
; IF, GOTO, REM and a bare drive change ("D:") are handled by the shell
; itself, not by a file; they are reported as "shell built-in".
;
; The path is printed in full (drive, directory, on-disk name): the
; found candidate is resolved again with K_PATH_RESOLVE, its directory
; named with lib/pathstr.asm's path_print_from_cluster, and the file's
; own name taken from K_STAT's directory entry. If that naming fails,
; the candidate is printed as searched.
;
; Exit code: 0 if every name was found, 1 otherwise.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   env_getenv
            extrn   drive_letter_of
            extrn   path_print_from_cluster

WH_PATH_MAX:    equ     128             ; = the shell's SH_PATH_MAX

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv, RC = argc -- to memory at once, since nothing
            ; below keeps them in registers across a kernel call
            mov     rf, wh_argc
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            mov     rf, wh_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, wh_fail
            ldi     0
            str     rf
            mov     rf, wh_i
            ldi     1
            str     rf

            ; argc < 2: usage (argc never exceeds ARGV_MAX_ARGS, so its
            ; high byte is always 0)
            mov     rf, wh_argc+1
            ldn     rf
            smi     2
            lbdf    wh_arg_loop

            call    K_INMSG
            db      "Usage: WHICH <command> [command...]",13,10,0
            ldi     1
            rtn

wh_arg_loop:
            ; i < argc?
            mov     rf, wh_argc+1
            ldn     rf
            str     r2
            mov     rf, wh_i
            ldn     rf
            sm                          ; D = i - argc
            lbdf    wh_all_done         ; i >= argc

            ; sh_name = argv[i]
            ldn     rf                  ; D = i
            shl                         ; i*2 (i <= 15, no carry)
            plo     r8
            ldi     0
            phi     r8
            mov     rf, wh_argv
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, r8              ; RD = &argv[i]
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = argv[i]
            mov     rb, sh_name
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            call    which_one

            mov     rf, wh_i
            ldn     rf
            adi     1
            str     rf
            lbr     wh_arg_loop

wh_all_done:
            mov     rf, wh_fail
            ldn     rf                  ; D = exit code (0 or 1)
            rtn

;------------------------------------------------------------------
; which_one: look up sh_name and report it.
; Modifies: everything
;------------------------------------------------------------------
which_one:
            call    check_builtin
            lbdf    wo_search

            call    print_name
            call    K_INMSG
            db      ": shell built-in",13,10,0
            rtn

wo_search:
            ; name containing '/': an explicit path, no search
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
wo_scan:
            ldn     rf
            lbz     no_slash
            xri     '/'
            lbz     have_slash
            inc     rf
            lbr     wo_scan

have_slash:
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    set_noext
            mov     rb, sh_name
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = name
            mov     rf, wh_path
            ldi     RUN_PATH_LEN - 1
            plo     rc
copy_path_loop:
            glo     rc
            lbz     force_term_path
            lda     rd
            str     rf
            lbz     check_path
            inc     rf
            dec     rc
            lbr     copy_path_loop
force_term_path:
            ldi     0
            str     rf
check_path:
            call    check_variants
            lbnf    report_found
            lbr     report_missing

no_slash:
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    set_noext

            ; ---- candidate 1: the current directory ----
            mov     rf, wh_path
            ldi     RUN_PATH_LEN - 1
            plo     rc
            call    sh_append_name
            call    check_variants
            lbnf    report_found

            ; ---- candidate 2: <shell_drive>:/bin/<name> ----
            call    K_GETSHELLDRIVE     ; D = shell_drive
            call    drive_letter_of     ; D = its letter (clobbers RF)
            plo     rb
            mov     rf, wh_path
            glo     rb
            str     rf
            inc     rf
            ldi     ':'
            str     rf
            inc     rf
            ldi     RUN_PATH_LEN - 3
            plo     rc
            call    write_bin_name
            call    check_variants
            lbnf    report_found

            ; ---- candidate 3..n: each PATH entry ----
            mov     rf, sh_pathvar
            call    env_getenv          ; RF = value, or 0 if unset
            ghi     rf
            lbnz    sh_path_copy
            glo     rf
            lbz     report_missing

sh_path_copy:
            mov     rd, sh_pathbuf
            ldi     WH_PATH_MAX - 1
            plo     rc
sh_pc_loop:
            glo     rc
            lbz     sh_pc_term
            lda     rf
            str     rd
            lbz     sh_pc_done
            inc     rd
            dec     rc
            lbr     sh_pc_loop
sh_pc_term:
            ldi     0
            str     rd
sh_pc_done:
            mov     rf, sh_path_cur
            mov     rd, sh_pathbuf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

sh_path_loop:
            mov     rf, sh_path_cur
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            ldn     rd
            lbz     report_missing      ; end of PATH
            xri     ';'
            lbnz    sh_entry
            inc     rd                  ; empty entry: skip it
            lbr     sh_save_cursor

sh_entry:
            ; entry that would overflow is skipped, as in the shell
            mov     rf, sh_ovf
            ldi     0
            str     rf

            mov     rf, wh_path
            ldi     RUN_PATH_LEN - 1
            plo     rc
sh_ent_copy:
            ldn     rd
            lbz     sh_ent_end
            xri     ';'
            lbz     sh_ent_end
            glo     rc
            lbnz    sh_ent_room
            mov     rb, sh_ovf
            ldi     1
            str     rb
            inc     rd
            lbr     sh_ent_copy
sh_ent_room:
            ldn     rd
            str     rf
            inc     rf
            inc     rd
            dec     rc
            lbr     sh_ent_copy

sh_ent_end:
            mov     rb, sh_wpos
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ldn     rd
            lbz     sh_save_cursor      ; NUL: leave the cursor on it
            inc     rd
sh_save_cursor:
            mov     rf, sh_path_cur
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, sh_ovf
            ldn     rf
            lbnz    sh_path_loop

            mov     rb, sh_wpos
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = just past the entry
            glo     rc
            lbz     sh_path_loop        ; no room for the separator
            dec     rf
            ldn     rf
            inc     rf
            xri     '/'
            lbz     sh_have_sep
            ldi     '/'
            str     rf
            inc     rf
            dec     rc
sh_have_sep:
            call    sh_append_name
            call    check_variants
            lbnf    report_found
            lbr     sh_path_loop

report_missing:
            call    print_name
            call    K_INMSG
            db      ": not found",13,10,0
            mov     rf, wh_fail
            ldi     1
            str     rf
            rtn

report_found:
            ; wh_stat holds the found file's own directory entry (the
            ; last check_exists was the one that succeeded)
            mov     rf, wh_path
            call    K_PATH_RESOLVE      ; RD = parent, RC.0 = drive
            lbdf    rf_raw
            mov     rf, wh_parent
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, wh_drive
            glo     rc
            str     rf

            ldn     rf                  ; D = drive (reloaded after mov)
            call    path_print_from_cluster
            lbdf    rf_raw              ; nothing printed on failure

            ; the root prints as "X:/", a subdirectory without the
            ; trailing '/'
            mov     rf, wh_parent
            lda     rf
            lbnz    rf_slash
            ldn     rf
            lbz     rf_name
rf_slash:
            call    K_INMSG
            db      "/",0
rf_name:
            mov     rf, wh_stat+DIRENT_NAME
            call    K_MSG
            lbr     rf_crlf

rf_raw:
            mov     rf, wh_path
            call    K_MSG
rf_crlf:
            call    K_INMSG
            db      13,10,0
            rtn

;------------------------------------------------------------------
; print_name: print sh_name.
;------------------------------------------------------------------
print_name:
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            lbr     K_MSG               ; tail call

;------------------------------------------------------------------
; check_builtin: is sh_name one the shell handles itself?
; Returns: DF = 0 if so (IF, GOTO, REM, or "X:"), DF = 1 if not
; Modifies: RB, RD, RF, R7
;------------------------------------------------------------------
check_builtin:
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf

            ; "X:" -- two characters, the second a colon
            ldn     rf
            lbz     cb_no
            inc     rf
            ldn     rf
            xri     ':'
            lbnz    cb_words
            inc     rf
            ldn     rf
            lbz     cb_yes
cb_words:
            mov     rd, pat_if
            call    word_eq
            lbnf    cb_yes
            mov     rd, pat_goto
            call    word_eq
            lbnf    cb_yes
            mov     rd, pat_rem
            call    word_eq
            lbnf    cb_yes
cb_no:
            stc
            rtn
cb_yes:
            clc
            rtn

; word_eq: sh_name equals the uppercase-letters pattern at RD, case-
; insensitively? DF = 0 if so. Modifies RB, RF, RD.
word_eq:
            mov     rb, sh_name
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
we_loop:
            ldn     rd
            lbz     we_end              ; pattern done: name must be too
            str     r2
            ldn     rf
            ani     $DF
            xor
            lbnz    we_no
            inc     rd
            inc     rf
            lbr     we_loop
we_end:
            ldn     rf
            lbnz    we_no
            clc
            rtn
we_no:
            stc
            rtn

;------------------------------------------------------------------
; The routines below are copies of progs/shell.asm's own, working on
; wh_path in place of RUN_PATH.
;------------------------------------------------------------------

; sh_append_name: append sh_name at RF, bounded by RC.0
sh_append_name:
            mov     rb, sh_name
            lda     rb
            phi     rd
            ldn     rb
            plo     rd
            lbr     wbn_name_loop

; write_bin_name: append "/bin/" + sh_name at RF, bounded by RC.0
write_bin_name:
            mov     rd, bin_prefix
wbn_prefix_loop:
            glo     rc
            lbz     wbn_term
            lda     rd
            lbz     wbn_prefix_done
            str     rf
            inc     rf
            dec     rc
            lbr     wbn_prefix_loop
wbn_prefix_done:
            mov     rb, sh_name
            lda     rb
            phi     rd
            ldn     rb
            plo     rd
wbn_name_loop:
            glo     rc
            lbz     wbn_term
            lda     rd
            str     rf
            lbz     wbn_done
            inc     rf
            dec     rc
            lbr     wbn_name_loop
wbn_term:
            ldi     0
            str     rf
wbn_done:
            rtn

; check_exists: DF = 0 if wh_path names an existing file (not a
; directory); wh_stat then holds its directory entry
check_exists:
            mov     rf, wh_path
            mov     rd, wh_stat
            call    K_STAT
            lbdf    chk_no
            mov     rf, wh_stat+DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    chk_no
            clc
            rtn
chk_no:
            stc
            rtn

; check_variants: wh_path as built, then -- if the name had no
; extension -- wh_path + ".bat". Args: RF = wh_path's NUL, RC.0 = room
check_variants:
            mov     rb, sh_endpos
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            mov     rb, sh_room
            glo     rc
            str     rb

            call    check_exists
            lbnf    cv_found

            mov     rf, sh_noext
            ldn     rf
            lbz     cv_fail
            mov     rf, sh_room
            ldn     rf
            smi     4                   ; room for ".bat"?
            lbnf    cv_fail

            mov     rd, sh_ext_bat
            mov     rb, sh_endpos
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
cvt_loop:
            lda     rd
            str     rf
            inc     rf
            lbnz    cvt_loop
            lbr     check_exists        ; tail call: its DF is ours
cv_fail:
            stc
            rtn
cv_found:
            clc
            rtn

; set_noext: sh_noext = 1 if the last component of the string at RF
; has no '.'. Modifies RF, R8.0, R9.0
set_noext:
            ldi     1
            plo     r9
sne_loop:
            lda     rf
            lbz     sne_done
            plo     r8
            xri     '/'
            lbnz    sne_notslash
            ldi     1
            plo     r9
            lbr     sne_loop
sne_notslash:
            glo     r8
            xri     '.'
            lbnz    sne_loop
            ldi     0
            plo     r9
            lbr     sne_loop
sne_done:
            mov     rf, sh_noext
            glo     r9
            str     rf
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
pat_if:     db      "IF",0
pat_goto:   db      "GOTO",0
pat_rem:    db      "REM",0
bin_prefix: db      "/bin/",0
sh_ext_bat: db      ".bat",0
sh_pathvar: db      "PATH",0

wh_argc:    dw      0
wh_argv:    dw      0
wh_i:       db      0
wh_fail:    db      0
wh_parent:  dw      0
wh_drive:   db      0
sh_name:    dw      0
sh_noext:   db      0
sh_endpos:  dw      0
sh_room:    db      0
sh_ovf:     db      0
sh_wpos:    dw      0
sh_path_cur: dw     0
wh_path:    ds      RUN_PATH_LEN
sh_pathbuf: ds      WH_PATH_MAX
wh_stat:    ds      DIRENT_LEN

            end     start
