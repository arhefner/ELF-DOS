;
; stat.asm - show a file or directory's metadata
;
; Usage: STAT <path>
;
; Prints the target's type (file/directory), size (files only), first
; cluster, and last-write date/time -- the same fields progs/dir.asm's
; own listing already shows per entry, but for a single named target,
; via K_STAT (kernel/file.asm's file_stat) instead of a directory scan.
; See K_STAT's own header comment in kernel_api.inc for why this
; exists as a real kernel primitive rather than a third hand-rolled
; path_resolve+dir_open/dir_read+f_strcmp loop (progs/copy.asm and
; progs/sys.asm each already had one inline before K_STAT existed).
;
; Date/time unpacking and print2digit are copied from progs/dir.asm
; verbatim (same packed FAT bit-field format, same hardware-confirmed
; routine) rather than shared -- this project's own established
; precedent for a routine this small (see e.g. mr.asm/ms.asm's
; largely-parallel structure) over introducing a shared library.
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
            plo     rf                  ; RF = argv[1] (path)
            mov     rd, stat_result     ; RD = result buffer
            call    K_STAT              ; DF = 0/1, buffer filled on success
            lbdf    stat_not_found

            ; ---- Name: ----
            call    K_INMSG
            db      "Name:    ",0
            mov     rf, stat_result     ; DIRENT_NAME at offset 0
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            ; ---- Type: ----
            mov     rf, stat_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    stat_is_dir

            call    K_INMSG
            db      "Type:    File",13,10,0

            ; ---- Size: (files only) ----
            call    K_INMSG
            db      "Size:    ",0
            mov     rf, stat_result
            add16   rf, DIRENT_SIZE
            add16   rf, 2               ; skip to the low word (bytes 2,3)
            lda     rf                  ; D = size byte 2 (low word MSB)
            phi     rd
            ldn     rf                  ; D = size byte 3 (low word LSB)
            plo     rd                  ; RD = size (0-65535)
            mov     rf, num_buf
            call    f_uintout           ; writes decimal ASCII into *rf,
                                        ; advances rf, does NOT
                                        ; null-terminate itself
            ldi     0
            str     rf                  ; null-terminate
            mov     rf, num_buf
            call    K_MSG
            call    K_INMSG
            db      " bytes",13,10,0
            lbr     stat_cluster

stat_is_dir:
            call    K_INMSG
            db      "Type:    Directory",13,10,0

stat_cluster:
            ; ---- Cluster: ----
            call    K_INMSG
            db      "Cluster: ",0
            mov     rf, stat_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd                  ; RD = first cluster
            mov     rf, num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, num_buf
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            ; ---- Written: MM/DD/YYYY HH:MM ----
            call    K_INMSG
            db      "Written: ",0

            ; ---- unpack last-write date into day/month/year ----
            mov     rf, stat_result
            add16   rf, DIRENT_WRTDATE
            lda     rf                  ; D = date high byte
            phi     rd
            ldn     rf                  ; D = date low byte
            plo     rd                  ; RD = packed date

            mov     rf, wr_day
            glo     rd
            ani     $1F                 ; day = bits 4-0
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_date >> 5
            mov     rf, wr_month
            glo     rd
            ani     $0F                 ; month = bits 8-5 (now bits 3-0)
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_date >> 9 (year-1980)
            add16   rd, 1980
            mov     rf, wr_year
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; ---- unpack last-write time into hour/minute ----
            mov     rf, stat_result
            add16   rf, DIRENT_WRTTIME
            lda     rf                  ; D = time high byte
            phi     rd
            ldn     rf                  ; D = time low byte
            plo     rd                  ; RD = packed time

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_time >> 5
            mov     rf, wr_minute
            glo     rd
            ani     $3F                 ; minute = bits 10-5 (now bits 5-0)
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_time >> 11 (hour)
            mov     rf, wr_hour
            glo     rd
            str     rf

            ; ---- print "MM/DD/YYYY HH:MM" ----
            mov     rf, wr_month
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, wr_day
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, wr_year
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, num_buf         ; reuse num_buf -- size/cluster
                                        ; have already been printed
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, num_buf
            call    K_MSG

            call    K_INMSG
            db      " ",0

            mov     rf, wr_hour
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      ":",0

            mov     rf, wr_minute
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      13,10,0

            ldi     0                   ; exit code 0 = success
            rtn

usage:
            call    K_INMSG
            db      "Usage: STAT <path>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

stat_not_found:
            call    K_INMSG
            db      "Not found.",13,10,0
            ldi     1
            rtn

; ----------------------------------------------------------------
; print2digit: print RD (0-99) as two zero-padded decimal digits
; (e.g. 3 -> "03", 14 -> "14"). Copied from progs/dir.asm verbatim.
; Args:   RD = value (0-99)
; Returns: nothing
; ----------------------------------------------------------------
print2digit:
            glo     rd
            smi     10
            lbdf    p2d_use_uintout     ; value >= 10: two digits already

            glo     rd
            adi     '0'
            plo     rc                  ; stash the single digit's char
            mov     rf, digit_buf
            ldi     '0'
            str     rf
            inc     rf
            glo     rc
            str     rf
            inc     rf
            ldi     0
            str     rf
            lbr     p2d_print

p2d_use_uintout:
            mov     rf, digit_buf
            call    f_uintout
            ldi     0
            str     rf

p2d_print:
            mov     rf, digit_buf
            call    K_MSG
            rtn

stat_result: ds     DIRENT_LEN          ; 139-byte result buffer for K_STAT
num_buf:     ds      6                  ; decimal scratch (max "65535"+null)
digit_buf:   ds      3                  ; scratch for print2digit ("99"+null)

wr_day:      db      0
wr_month:    db      0
wr_year:     dw      0
wr_hour:     db      0
wr_minute:   db      0

            end     start
