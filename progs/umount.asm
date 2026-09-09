;
; umount.asm - detach a drive letter from its partition
;
; UMOUNT <letter>
;
; The counterpart to progs/mount.asm. Clears a drive's presence flag so
; path_resolve/K_SETDRIVE stop accepting it, after making sure nothing
; cached still refers to it.
;
; The order below is the whole point of this program, and it is not
; interchangeable:
;
;   1. Refuse the shell's own drive outright.
;   2. Move cur_drive off the target first, if it is sitting there --
;      otherwise step 4 leaves the "current" drive pointing at a slot
;      that is no longer present, and the next unprefixed path would
;      resolve against an absent partition.
;   3. K_DRIVE_INVALIDATE, which flushes the FAT cache if this drive is
;      the active one. This MUST happen while drive_bpb_table[i] still
;      describes the real partition -- the flush derives its LBAs from
;      the active BPB fields. See kernel/kinit.asm's own
;      kernel_drive_invalidate header for what going out of order costs.
;   4. Only then clear drive_present[i].
;
; The drive's drive_bpb_table entry is deliberately left as-is rather
; than zeroed. Nothing reads it while drive_present[i] is 0, and
; leaving it means a later MOUNT of the same partition writes over a
; block that already held the same values -- one less thing to get
; wrong, and it makes an accidental UMOUNT trivially recoverable by
; remounting the same partition.
;
; See progs/mount.asm's header for the DRIVE_DATA_PTR mechanism these
; two programs share.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

;------------------------------------------------------------------
; 6-byte program header
;------------------------------------------------------------------
            db      'E','D','F'
            db      1                       ; major
            db      0                       ; minor
            db      0                       ; reserved

;------------------------------------------------------------------
; Entry: RA = argv table, RC = argc
;------------------------------------------------------------------
start:
            glo     rc
            smi     2
            lbnf    umt_usage               ; argc < 2
            glo     rc
            smi     3
            lbdf    umt_usage               ; argc > 2

            ; ---- argv[1] = drive letter ----
            mov     rb, ra
            add16   rb, 2                   ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                      ; RF = argv[1]

            lda     rf
            ani     $DF                     ; uppercase-fold (see
                                            ; mount.asm's note on why
                                            ; this is safe for A-Z)
            smi     'C'
            lbnf    umt_bad_drive
            plo     r9                      ; R9.0 = drive index
            glo     r9
            smi     DRIVE_COUNT
            lbdf    umt_bad_drive

            ; a trailing ':' is optional ("D" or "D:")
            lda     rf
            lbz     umt_drive_ok
            xri     ':'
            lbnz    umt_bad_drive
            ldn     rf
            lbnz    umt_bad_drive
umt_drive_ok:
            mov     rf, umt_drive
            glo     r9
            str     rf                      ; umt_drive = 0-3

            ; ---- step 1: never the shell's own drive ----
            call    K_GETSHELLDRIVE         ; D = shell_drive
            str     r2
            mov     rf, umt_shell
            ldn     r2
            str     rf                      ; remember it for step 2
            mov     rf, umt_drive
            ldn     rf
            sm                              ; D = target - shell_drive
            lbz     umt_is_shell

            ; ---- must actually be mounted ----
            call    umt_present_addr        ; RF = &drive_present[target]
            ldn     rf
            lbz     umt_not_mounted

            ; ---- step 2: move cur_drive off the target if needed ----
            call    umt_base                ; R9 = drive_present's address
            mov     rf, r9
            add16   rf, CUR_DRIVE_OFF
            ldn     rf
            str     r2                      ; M(X) = cur_drive
            mov     rf, umt_drive
            ldn     rf
            sm                              ; D = target - cur_drive
            lbnz    umt_cur_ok

            ; cur_drive is the one going away -- switch to the shell's
            ; drive via K_SETDRIVE rather than writing cur_drive raw,
            ; so its drive_present check still gets a say.
            mov     rf, umt_shell
            ldn     rf
            call    K_SETDRIVE
            lbdf    umt_cant_move           ; shell drive not present?
                                            ; refuse rather than strand
                                            ; cur_drive on a dead slot
umt_cur_ok:

            ; ---- step 3: invalidate BEFORE clearing presence ----
            mov     rf, umt_drive
            ldn     rf
            call    K_DRIVE_INVALIDATE

            ; ---- step 4: clear the presence flag ----
            call    umt_present_addr
            ldi     0
            str     rf

            call    K_INMSG
            db      "Unmounted ",0
            mov     rf, umt_drive
            ldn     rf
            adi     'C'
            call    K_TYPE
            call    K_INMSG
            db      ":",13,10,0

            ldi     0
            rtn

;==================================================================
; Error exits
;==================================================================
umt_usage:
            call    K_INMSG
            db      "Usage: UMOUNT <drive letter>",13,10,0
            ldi     1
            rtn

umt_bad_drive:
            call    K_INMSG
            db      "Drive must be C, D, E or F.",13,10,0
            ldi     1
            rtn

umt_is_shell:
            call    K_INMSG
            db      "Cannot unmount the drive the shell was loaded from.",13,10,0
            ldi     1
            rtn

umt_not_mounted:
            call    K_INMSG
            db      "That drive is not mounted.",13,10,0
            ldi     1
            rtn

umt_cant_move:
            call    K_INMSG
            db      "Cannot move off that drive; not unmounted.",13,10,0
            ldi     1
            rtn

;==================================================================
; Helpers (leaf routines, no kernel/BIOS calls of their own)
;==================================================================

;------------------------------------------------------------------
; umt_base: R9 = drive_present's real address
; Modifies: R9, RF, D
;------------------------------------------------------------------
umt_base:
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            rtn

;------------------------------------------------------------------
; umt_present_addr: RF = &drive_present[umt_drive]
; Modifies: R9, RD, RF, D
;------------------------------------------------------------------
umt_present_addr:
            call    umt_base
            mov     rf, umt_drive
            ldn     rf
            plo     rd
            ldi     0
            phi     rd                      ; RD = index, zero-extended
            mov     rf, r9
            add16   rf, rd
            rtn

;==================================================================
; Data
;==================================================================
umt_drive:      db      0           ; target drive index 0-3
umt_shell:      db      0           ; shell_drive, cached at step 1
