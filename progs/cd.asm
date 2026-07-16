;
; cd.asm - change a drive's current directory
;
; Usage: CD <path>
;        CD ..            -- parent directory (the '..' entry already
;                             stores the correct parent cluster, 0 for
;                             the FAT16 root, so no special-casing needed)
;        CD /cfg/sub       -- absolute, multi-component path
;        CD cfg/sub        -- relative, multi-component path
;        CD /               -- root
;        CD D:\games        -- an optional 2-char drive prefix (C:-F:)
;                             names a different drive's directory to
;                             change -- see below
;        CD D:              -- drive-only argument: prints/no-ops on
;                             that drive's current directory rather
;                             than changing anything (same as bare CD
;                             on the current drive would)
;
; Path resolution (drive-prefix parsing, leading '/' = absolute,
; '.'/'..' handled as real directory entries, multi-component walking)
; is done by K_PATH_RESOLVE -- see include/kernel_api.inc. CD only has
; to search the resolved parent directory for the final component and
; confirm it's a directory, exactly as before multi-drive support
; existed.
;
; CD NEVER changes which drive is active -- classic MS-DOS semantics
; (adopted deliberately, 2026-07-13): "CD D:\games" while C: is
; active updates D:'s own remembered directory without switching to
; it. The only way to change the active drive is a bare "C:"/"D:"/
; "E:"/"F:" command line, handled directly by the shell (see
; progs/shell.asm) -- not by this program.
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
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1] is the path argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no path given

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (the path argument)

            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, RC.0 = resolved
                                        ; drive, DF = 0/1
            lbdf    not_found           ; bad intermediate component,
                                        ; or an "X:" prefix named an
                                        ; unmounted drive

            ; persist the resolved drive now -- K_DIR_OPEN/K_DIR_READ
            ; below clobber RC
            mov     rb, cd_drive
            glo     rc
            str     rb                  ; cd_drive = resolved drive

            ; an empty final component means the path itself named
            ; the target directory ("/", "cfg/", "D:", ...) -- the
            ; resolved parent cluster IS the target, no further
            ; lookup needed
            ldn     rf
            lbnz    have_component
            mov     rf, cd_drive
            ldn     rf                  ; D = resolved drive (RD, the
                                        ; resolved cluster from
                                        ; K_PATH_RESOLVE, is untouched
                                        ; by mov/ldn)
            call    K_SETCURDIR         ; D = drive, RD = cluster
            ldi     0
            rtn

have_component:
            ; save the final-component pointer in memory (not a
            ; register): K_DIR_READ uses R9/RA/RB/RC/RD/RF internally
            ; (see kernel/dir.asm), so nothing in a register would
            ; survive the search loop below.
            mov     rb, arg_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; arg_ptr = final component pointer

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE (untouched by the arg_ptr store above)
            call    K_DIR_OPEN

cd_loop:
            mov     rf, dir_result
            call    K_DIR_READ
            lbdf    not_found           ; end of directory: no match

            ; compare entry name against the saved argument
            mov     rf, arg_ptr
            lda     rf                  ; D = argument pointer high byte
            phi     rd
            ldn     rf                  ; D = argument pointer low byte
            plo     rd                  ; RD = argument pointer
            mov     rf, dir_result      ; RF = entry name
            call    f_strcmp
            lbnz    cd_loop             ; no match: keep looking

            ; must be a directory
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     not_dir

            ; set the current directory to the entry's first cluster
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd                  ; RD = entry's cluster

            mov     rf, cd_drive
            ldn     rf                  ; D = resolved drive (RD
                                        ; untouched by mov/ldn)
            call    K_SETCURDIR         ; D = drive, RD = cluster

            ldi     0                   ; exit code 0 = success
            rtn

not_found:
            call    K_INMSG
            db      "Directory not found.",13,10,0
            ldi     1
            rtn

not_dir:
            call    K_INMSG
            db      "Not a directory.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: CD <directory>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

arg_ptr:    dw      0
cd_drive:   db      0                   ; K_PATH_RESOLVE's resolved
                                        ; drive (RC.0), stashed here
                                        ; since K_DIR_OPEN/K_DIR_READ
                                        ; below clobber RC
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for K_DIR_READ

            end     start
