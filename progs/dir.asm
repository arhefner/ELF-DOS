;
; dir.asm - list a directory
;
; Usage: DIR [path]
;
; With no argument, lists the current directory. With a path argument
; (bare name, relative path, or absolute path starting with '/'),
; lists that directory instead -- without changing the current
; directory, since K_DIR_OPEN/K_DIR_READ only drive this program's
; own listing traversal and never touch cur_dir (only CD's
; K_SETCURDIR does that). See K_PATH_RESOLVE in kernel_api.inc.
;
; Each entry is printed as a fixed-width line:
;   columns 1-5:   right-justified decimal byte count (files) or
;                  blank (directories) -- low 16 bits only, since
;                  this hardware's RAM makes files over 64K moot,
;                  see kernel/file.asm's own FCB_FSIZE/FCB_FPOS
;                  ceiling
;   columns 6-12:  " <DIR> " for subdirectories, blank for files
;   columns 13-31: last-write date/time, "MM/DD/YYYY HH:MM  "
;                  (unpacked from DIRENT_WRTDATE/DIRENT_WRTTIME's
;                  packed FAT bit fields -- see kernel/rtc.asm)
;   columns 32+:   the file/directory name
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
            call    K_GETCURDIR         ; RD = current directory cluster

            ldn     ra                  ; D = first byte of command tail
            lbz     dir_open_target     ; empty: list current directory

            mov     rf, ra              ; RF = path argument
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, DF = 0/1
            lbdf    not_found           ; bad intermediate component

            ; an empty final component means the path itself named
            ; the target directory ("/", "cfg/", ...) -- the resolved
            ; parent cluster IS the target already
            ldn     rf
            lbz     dir_open_target

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

dir_find:
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
            lbnz    dir_find            ; no match: keep looking

            ; must be a directory
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     not_dir

            ; RD = the matched entry's first cluster -- falls through
            ; to dir_open_target below, same as the "empty final
            ; component" shortcuts above
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd

dir_open_target:
            call    K_DIR_OPEN

dir_loop:
            mov     rf, dir_result      ; RF = result buffer
            call    K_DIR_READ
            lbdf    dir_done            ; DF=1 = end of directory

            ; check ATTR_DIR bit
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    dir_is_dir

            ; ---- file: right-justified 5-column decimal size ----
            mov     rf, dir_result
            add16   rf, DIRENT_SIZE
            add16   rf, 2               ; skip to the low word (bytes 2,3)
            lda     rf                  ; D = size byte 2 (low word MSB)
            phi     rd
            ldn     rf                  ; D = size byte 3 (low word LSB)
            plo     rd                  ; RD = size (0-65535)

            mov     rf, size_buf
            call    f_uintout           ; writes decimal ASCII into *rf, advances rf
            ldi     0
            str     rf                  ; null-terminate

            ; count digits written, to right-justify in 5 columns
            mov     rf, size_buf
            ldi     0
            plo     rc                  ; RC.0 = digit count
count_loop:
            ldn     rf
            lbz     count_done
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     count_loop
count_done:
            ; leading spaces = a substring of the 5-space buffer,
            ; starting "digit count" chars in (fewer spaces needed
            ; the more digits there are; always <= 5 digits since
            ; the value is at most 65535)
            mov     rf, spaces5
            add16   rf, rc
            call    K_MSG

            mov     rf, size_buf
            call    K_MSG               ; the digits themselves

            mov     rf, tag_blank       ; blank 7-column directory tag
            call    K_MSG
            lbr     dir_print_datetime

            ; ---- directory: blank size + " <DIR> " tag ----
dir_is_dir:
            mov     rf, spaces5         ; blank 5-column size field
            call    K_MSG
            mov     rf, dir_tag
            call    K_MSG

dir_print_datetime:
            ; ---- unpack last-write date into day/month/year ----
            mov     rf, dir_result
            add16   rf, DIRENT_WRTDATE
            lda     rf                  ; D = date high byte
            phi     rd
            ldn     rf                  ; D = date low byte
            plo     rd                  ; RD = packed date

            ; BUG FIX: "mov rf, wr_day" itself clobbers D (its own
            ; final LDI leaves D = wr_day's low address byte), so the
            ; masked day value just computed in D would not survive
            ; to "str rf" below unless the mov happens first, with D
            ; recomputed fresh right before the store -- the same
            ; class of bug this project has hit repeatedly (see
            ; CLAUDE.md gotcha #4). Confirmed on hardware: every
            ; entry showed the identical (wrong) "122/00 ... 125:126"
            ; -- wr_day/wr_month/wr_hour/wr_minute's own low address
            ; bytes, constant regardless of the real per-entry value,
            ; since only wr_year's store happened to reload D (via
            ; ghi/glo) after its own mov and so wasn't affected.
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
            mov     rf, dir_result
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

            ; ---- print "MM/DD/YYYY HH:MM  " ----
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
            mov     rf, size_buf        ; reuse size_buf -- this entry's
                                        ; size has already been printed
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, size_buf
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
            db      "  ",0

dir_print_name:
            mov     rf, dir_result      ; RF = DIRENT_NAME (at offset 0)
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     dir_loop

dir_done:
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

; ----------------------------------------------------------------
; print2digit: print RD (0-99) as two zero-padded decimal digits
; (e.g. 3 -> "03", 14 -> "14"). Used for month/day/hour/minute.
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

arg_ptr:    dw      0
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for K_DIR_READ
size_buf:   ds      6                   ; decimal size scratch (max "65535"+null)
spaces5:    db      "     ",0           ; 5 spaces -- blank size field, and
                                        ; (via pointer offset) padding
                                        ; source for right-justifying sizes
dir_tag:    db      " <DIR> ",0         ; 7-column directory tag
tag_blank:  db      "       ",0        ; 7 spaces -- blank tag field for files
digit_buf:  ds      3                   ; scratch for print2digit ("99"+null)

wr_day:     db      0
wr_month:   db      0
wr_year:    dw      0
wr_hour:    db      0
wr_minute:  db      0

            end     start
