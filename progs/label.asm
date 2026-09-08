;
; label.asm - show, set, or remove the FAT16 volume label
;
; Usage: LABEL [drive:] [text | -d]
;
;   LABEL                 show the current drive's volume label
;   LABEL D:              show drive D:'s volume label
;   LABEL MYDISK           set the current drive's volume label
;   LABEL D: MYDISK        set drive D:'s volume label
;   LABEL -d               remove the current drive's volume label
;   LABEL D: -d            remove drive D:'s volume label
;
; The actual volume-label read/create-or-update/remove mechanism lives
; in lib/vollabel.asm (extracted 2026-07-30, once progs/dir.asm became
; a second caller wanting to print a "Volume in drive C is MYDISK"
; header the way MS-DOS's own DIR always has -- see that library's own
; header for the full design, including why it operates on whichever
; drive is currently ACTIVE with no drive-switching logic of its own).
; This program is just argv parsing, drive activation (the one part
; that's genuinely specific to LABEL's own "drive:" argument -- DIR
; needs none of this, since its own first instruction already leaves
; the right drive active before it ever calls into the library), and
; turning the library's DF/D results into messages.
;
; No drive given uses whichever drive the SHELL considers active
; (K_GETCURDIR's own real drive, not necessarily whatever the last path
; operation happened to leave active -- K_GETCURDIR reactivates it as a
; proven side effect, kernel/kernel.asm's own 2026-07-14/15 fix). An
; explicit drive is activated the same way XCOPY's own cross-drive fix
; already established: a K_STAT call on "X:/" purely for its
; path_resolve-internal _switch_drive side effect, discarding the
; result -- deliberately NOT K_SETDRIVE, which would permanently change
; the shell's own active/prompt drive, a surprising side effect this
; command has no business causing.
;

#include    include/opcodes.def
#include    include/kernel_api.inc
#include    include/vollabel.inc

            extrn   vol_label_get
            extrn   vol_label_set
            extrn   vol_label_delete

LBL_MODE_SHOW:    equ   0
LBL_MODE_SET:     equ   1
LBL_MODE_DELETE:  equ   2

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rf, lbl_mode
            ldi     LBL_MODE_SHOW
            str     rf

            mov     rf, lbl_has_drive
            ldi     0
            str     rf

            glo     rc
            smi     2
            lbnf    lbl_dispatch        ; argc < 2: bare LABEL, SHOW
                                        ; mode, no drive -- nothing more
                                        ; to parse

            ; argv[1], read directly from RA -- still fresh, no calls
            ; have happened yet
            mov     rb, ra
            add16   rb, 2
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1]

            mov     rf, lbl_arg1
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; lbl_arg1 = argv[1]

            ; stash argc/argv now too, in case argv[2] is needed below
            ; (lbl_check_drive_prefix makes no calls of its own, so RA/
            ; RC would still be safe across just that one call, but
            ; stashing here once is simpler than reasoning about it twice)
            mov     rf, lbl_argc
            glo     rc
            str     rf
            mov     rf, lbl_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, rd              ; RF = argv[1] (still fresh in RD)
            call    lbl_check_drive_prefix
            lbnf    lbl_have_drive      ; DF=0: argv[1] IS a drive prefix

            ; not a drive prefix: argv[1] itself is the text/flag
            ; argument -- but if there's STILL another argument after
            ; it (argc > 2), the line is ambiguous rather than a real
            ; multi-word label ("LABEL c foobar" -- "c" alone looks
            ; like a forgotten drive-colon typo, not genuine label
            ; text) -- reject outright instead of silently using
            ; argv[1] and discarding the rest. A real hardware-found
            ; bug (2026-07-30): this used to fall straight through,
            ; so a bare drive letter typo like "LABEL c foobar" set
            ; the CURRENT drive's own label to "C" with no warning at
            ; all -- exactly the mistake the user asked to be guarded
            ; against.
            mov     rf, lbl_argc
            ldn     rf
            smi     3
            lbdf    lbl_too_many        ; argc >= 3: too many args
                                        ; when argv[1] isn't a drive

            mov     rf, lbl_arg2
            mov     rb, lbl_arg1
            lda     rb
            str     rf
            inc     rf
            ldn     rb
            str     rf                  ; lbl_arg2 = lbl_arg1
            lbr     lbl_have_text_arg

lbl_have_drive:
            ; D still holds lbl_check_drive_prefix's own returned
            ; letter here (lbnf is a branch, doesn't touch D) -- but
            ; "mov rf, lbl_drive_letter" right below clobbers D as its
            ; own side effect (gotcha #4), so it must be stashed first
            plo     r9
            mov     rf, lbl_drive_letter
            glo     r9
            str     rf                  ; lbl_drive_letter = the
                                        ; uppercased letter
            mov     rf, lbl_has_drive
            ldi     1
            str     rf

            mov     rf, lbl_argc
            ldn     rf
            smi     3
            lbnf    lbl_dispatch        ; argc < 3: "LABEL X:" alone,
                                        ; SHOW mode

            mov     rf, lbl_argc
            ldn     rf
            smi     4
            lbdf    lbl_too_many        ; argc >= 4: "LABEL X: text
                                        ; EXTRA" -- reject rather than
                                        ; silently ignoring EXTRA

            mov     rf, lbl_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = argv table base
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2]
            mov     rf, lbl_arg2
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; lbl_arg2 = argv[2]

lbl_have_text_arg:
            ; lbl_arg2 holds either "-d"/"-D" or the label text --
            ; check for the delete flag first
            mov     rf, lbl_arg2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = the text/flag argument

            ldn     rf
            xri     '-'
            lbnz    lbl_mode_is_set     ; doesn't start with '-': SET

            inc     rf
            ldn     rf
            ani     $DF                 ; uppercase-fold (safe: only
                                        ; letters alias under this mask)
            xri     'D'
            lbnz    lbl_mode_is_set     ; not "-d"/"-D": treat the whole
                                        ; token as SET text instead (an
                                        ; 8-char label starting with '-'
                                        ; would fail charset validation
                                        ; anyway, giving a clear error
                                        ; rather than being silently
                                        ; eaten as a flag)

            inc     rf
            ldn     rf
            lbnz    lbl_mode_is_set     ; more characters after "-d":
                                        ; not exactly the flag

            mov     rf, lbl_mode
            ldi     LBL_MODE_DELETE
            str     rf
            lbr     lbl_dispatch

lbl_mode_is_set:
            mov     rf, lbl_mode
            ldi     LBL_MODE_SET
            str     rf
            lbr     lbl_dispatch

lbl_too_many:
            call    K_INMSG
            db      "Usage: LABEL [drive:] [text | -d]",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; lbl_dispatch: activate the right drive's BPB, then act according to
; lbl_mode.
;------------------------------------------------------------------
lbl_dispatch:
            mov     rf, lbl_has_drive
            ldn     rf
            lbz     lbl_use_curdrive

            ; explicit drive: build "X:/" and K_STAT it purely for the
            ; path_resolve-internal _switch_drive side effect -- the
            ; returned DIRENT is discarded, and cur_drive itself is
            ; deliberately left untouched (see this file's own header
            ; comment)
            mov     rf, lbl_drivepath
            mov     rb, lbl_drive_letter
            ldn     rb
            str     rf
            mov     rf, lbl_drivepath
            mov     rd, lbl_statbuf
            call    K_STAT              ; DF result discarded
            lbr     lbl_have_drive_active

lbl_use_curdrive:
            call    K_GETCURDIR         ; D = cur_drive (0-3); also
                                        ; reactivates cur_drive's own
                                        ; BPB as an already-proven side
                                        ; effect
            adi     'C'                 ; D = 'C'+cur_drive
            plo     r9                  ; stash it -- "mov rf,
                                        ; lbl_drive_letter" right below
                                        ; clobbers D as its own side
                                        ; effect (gotcha #4)
            mov     rf, lbl_drive_letter
            glo     r9
            str     rf                  ; lbl_drive_letter = 'C'+cur_drive

lbl_have_drive_active:
            mov     rf, lbl_mode
            ldn     rf
            lbz     lbl_do_show
            smi     1
            lbz     lbl_do_set
            lbr     lbl_do_delete

;------------------------------------------------------------------
; lbl_do_show
;------------------------------------------------------------------
lbl_do_show:
            mov     rd, lbl_name_buf
            call    vol_label_get       ; DF = 0/1
            lbdf    lbl_show_none

            call    K_INMSG
            db      "Volume in drive ",0
            mov     rf, lbl_drive_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      " is ",0
            mov     rf, lbl_name_buf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            ldi     0
            rtn

lbl_show_none:
            call    K_INMSG
            db      "Volume in drive ",0
            mov     rf, lbl_drive_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      " has no label.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; lbl_do_set
;------------------------------------------------------------------
lbl_do_set:
            mov     rf, lbl_arg2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = label text pointer

            call    vol_label_set       ; DF = 0/1, D = VOL_ERR_* if 1
            lbnf    lbl_set_ok

            plo     r9                  ; stash the reason code -- it's
                                        ; checked twice below

            glo     r9
            xri     VOL_ERR_INVALID
            lbz     lbl_set_bad

            glo     r9
            xri     VOL_ERR_FULL
            lbz     lbl_set_full

            ; else: VOL_ERR_IO
            call    K_INMSG
            db      "I/O error writing the volume label.",13,10,0
            ldi     1
            rtn

lbl_set_bad:
            call    K_INMSG
            db      "Invalid label -- use 1-11 letters, digits, '_', or '-'.",13,10,0
            ldi     1
            rtn

lbl_set_full:
            call    K_INMSG
            db      "Root directory full -- cannot create a volume label.",13,10,0
            ldi     1
            rtn

lbl_set_ok:
            ldi     0
            rtn

;------------------------------------------------------------------
; lbl_do_delete
;------------------------------------------------------------------
lbl_do_delete:
            call    vol_label_delete    ; DF = 0/1, D = VOL_ERR_* if 1
            lbnf    lbl_delete_ok

            xri     VOL_ERR_NONE
            lbz     lbl_delete_none

            call    K_INMSG
            db      "I/O error removing the volume label.",13,10,0
            ldi     1
            rtn

lbl_delete_none:
            call    K_INMSG
            db      "No volume label to remove.",13,10,0
            ldi     1
            rtn

lbl_delete_ok:
            ldi     0
            rtn

;------------------------------------------------------------------
; lbl_check_drive_prefix: does the string at RF spell exactly a bare
; "X:" (a letter, a colon, then NUL)?
; Args:    RF = pointer to a null-terminated string
; Returns: DF = 0 -- it is; D = the letter, uppercased.
;          DF = 1 -- it isn't (RF/D unspecified)
; Modifies: nothing but D/DF/R9.0 (internal scratch)
;------------------------------------------------------------------
lbl_check_drive_prefix:
            ldn     rf
            smi     'A'
            lbnf    lbl_cdp_lower_check
            ldn     rf
            smi     'Z'+1
            lbnf    lbl_cdp_have_letter
lbl_cdp_lower_check:
            ldn     rf
            smi     'a'
            lbnf    lbl_cdp_no
            ldn     rf
            smi     'z'+1
            lbdf    lbl_cdp_no

lbl_cdp_have_letter:
            ldn     rf
            ani     $DF                 ; uppercase-fold (safe: only
                                        ; letters reach here)
            plo     r9                  ; R9.0 = uppercased letter (stash)
            inc     rf
            ldn     rf                  ; D = char1
            xri     ':'
            lbnz    lbl_cdp_no
            inc     rf
            ldn     rf                  ; D = char2, must be NUL
            lbnz    lbl_cdp_no

            glo     r9
            clc                         ; DF = 0, is a drive prefix
            rtn

lbl_cdp_no:
            stc                         ; DF = 1, not a drive prefix
            rtn

lbl_mode:           db      0
lbl_has_drive:      db      0
lbl_drive_letter:   db      0
lbl_argc:           db      0
lbl_argv:           dw      0
lbl_arg1:           dw      0
lbl_arg2:           dw      0
lbl_drivepath:      db      "X:/",0
lbl_statbuf:        ds      DIRENT_LEN
lbl_name_buf:       ds      12

            end     start
