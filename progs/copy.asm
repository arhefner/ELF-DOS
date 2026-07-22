;
; copy.asm - copy a file
;
; Usage: COPY <source> <destination>
;
; Single file to single file only -- no wildcards, no directory
; trees. <source> must already exist (opened mode 0, read). Both
; arguments may be full paths, e.g. "COPY /cfg/env.dat backup.dat"
; -- K_FILE_OPEN already resolves paths internally (see
; K_PATH_RESOLVE), so nothing special is needed here for that.
;
; If <destination> is an existing directory, the source is copied
; into it under its own basename (e.g. "COPY ../foo ." copies to
; "./foo") -- checked via the same K_PATH_RESOLVE/K_DIR_OPEN/
; K_DIR_READ/ATTR_DIR pattern CD uses to recognize a directory.
;
; If the resolved destination file already exists, the user is
; prompted to confirm the overwrite (Y/N -- anything but Y/y
; cancels); otherwise it's created directly, same as WTEST.
;
; Copying a file onto itself is not specially detected or guarded
; against -- it will open the same file twice, for read and write
; simultaneously (each with its own independent FCB and I/O buffer,
; 2026-07-15), but the mode-1 destination open truncates the file to
; empty immediately (see file_open's own mode-1 semantics), which
; destroys the source's real content out from under the read side
; regardless of separate buffers. Don't do that.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

COPY_CHUNK_LEN: equ     512     ; matches the sector size -- was 64,
                                ; bumped once the underlying directory-
                                ; growth bug (fc_grow's unprotected R8
                                ; across fat_set) was found and fixed;
                                ; changing it earlier would have shifted
                                ; the cluster-boundary alignment of the
                                ; test cases that exposed that bug.
                                ; At the time this was bumped, it also
                                ; cut real disk I/O, not just call
                                ; overhead: file_read/file_write used to
                                ; share a SINGLE io_buf slot across all
                                ; FCBs, so every alternation between the
                                ; src and dst FCBs evicted the other's
                                ; cached sector -- at the old 64-byte
                                ; chunk size, copying one 512-byte sector
                                ; took 8 iterations x 3 real disk ops
                                ; each = 24 total. One 512-byte chunk
                                ; per sector cut that to 3. Since
                                ; 2026-07-15, src/dst each have their own
                                ; independent FCB and I/O buffer (see
                                ; below), so this specific thrashing no
                                ; longer applies either way -- but 512
                                ; still means 8x fewer K_FILE_READ/
                                ; K_FILE_WRITE round-trips than 64 did,
                                ; so the chunk size stayed as-is.
DST_BUF_LEN:    equ     132

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
            ; program's own name; argv[1] = source, argv[2] =
            ; destination -- the shell's own tokenizer already handles
            ; quoting/escaping and multiple/trailing spaces, so no
            ; hand-rolled splitting is needed here anymore.
            glo     rc
            smi     3
            lbnf    usage_error         ; argc < 3: source and/or
                                        ; destination missing

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] (source)
            mov     rf, src_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; src_ptr = source pointer

            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (destination)
            mov     rf, dst_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dst_ptr = destination pointer

;------------------------------------------------------------------
; If dst_ptr names an existing directory, redirect the real
; destination to <dst_ptr>/<basename of src_ptr> instead. real_dst
; defaults to dst_ptr unchanged; only overwritten if this check
; confirms a directory.
;------------------------------------------------------------------
            mov     rb, real_dst
            mov     rf, dst_ptr
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; real_dst = dst_ptr (default)

            ; load dst_ptr's string value into RC, then RF, for
            ; K_PATH_RESOLVE (which no longer takes a base-cluster
            ; argument -- it determines that, and the target drive,
            ; internally now; see kernel_api.inc)
            mov     rf, dst_ptr
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = destination string pointer

            mov     rf, rc              ; RF = destination path
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, RC.0 = resolved
                                        ; drive (unused here), DF = 0/1
            lbdf    dst_not_dir         ; bad intermediate component, or
                                        ; an "X:" prefix named an
                                        ; unmounted drive

            ; an empty final component means dst_ptr itself named a
            ; directory ("/", "cfg/", ...) -- no further lookup needed
            ldn     rf
            lbz     dst_is_dir

            ; save the final-component pointer in memory: K_DIR_READ
            ; clobbers R9/RA/RB/RC/RD/RF internally, so nothing
            ; survives in a register across the search loop below
            mov     rb, dstchk_arg
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE
            call    K_DIR_OPEN

dstchk_loop:
            mov     rf, dstchk_result
            call    K_DIR_READ
            lbdf    dst_not_dir         ; end of directory: no match,
                                        ; dst_ptr doesn't exist as this
                                        ; name -- not a directory

            mov     rf, dstchk_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dstchk_result
            call    f_strcmp
            lbnz    dstchk_loop         ; no match: keep looking

            ; found it -- must be a directory
            mov     rf, dstchk_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     dst_not_dir         ; exists but is a file

dst_is_dir:
            ; build dst_final = dst_ptr + '/' (if not already present)
            ; + basename(src_ptr), then point real_dst at it.
            ; BUG FIX: re-read dst_ptr fresh from memory here rather
            ; than relying on RC (stashed with dst_ptr's value earlier)
            ; to have survived -- K_PATH_RESOLVE's own header documents
            ; RC as one of its clobbered registers, so by this point
            ; (reached after a K_PATH_RESOLVE call, possibly also a
            ; K_DIR_OPEN/K_DIR_READ/f_strcmp chain) RC no longer holds
            ; what was stashed there before the call.
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dst_ptr's string pointer
                                        ; (reloaded from memory)
            mov     rf, dst_final
copy_dst_loop:
            lda     rd
            lbz     copy_dst_done
            str     rf
            inc     rf
            lbr     copy_dst_loop
copy_dst_done:
            ; RF = one past the last copied char; peek the previous
            ; char to avoid a doubled '/' if dst_ptr already ends in one
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     have_sep
            ldi     '/'
            str     rf
            inc     rf
have_sep:
            ; find basename(src_ptr): scan forward, remembering the
            ; position right after the LAST '/' seen (defaults to the
            ; string's own start if none found). RF (dst_final's
            ; current write position, set above) must survive this
            ; whole block untouched -- BUG FIX: an earlier draft used
            ; RF itself as scratch for the src_ptr indirection load
            ; below, silently losing the write position (RF was left
            ; pointing at src_ptr+1, not dst_final's real position).
            ; RC is free here (not used anywhere in this block) so the
            ; indirection uses that instead.
            mov     rc, src_ptr
            lda     rc
            phi     rd
            ldn     rc
            plo     rd                  ; RD = source string pointer
            mov     r8, rd              ; R8 = scan pointer
            mov     r9, rd              ; R9 = basename pointer (updated
                                        ; on each '/' seen)
basename_scan:
            ldn     r8
            lbz     basename_done
            xri     '/'
            lbnz    basename_next
            inc     r8
            mov     r9, r8              ; R9 = position right after '/'
            lbr     basename_scan
basename_next:
            inc     r8
            lbr     basename_scan
basename_done:
            ; RF still holds dst_final's write position (from have_sep
            ; above -- not touched by the basename scan)
            mov     rd, r9              ; RD = basename source pointer
append_basename_loop:
            lda     rd
            str     rf
            lbz     append_basename_done
            inc     rf
            lbr     append_basename_loop
append_basename_done:

            mov     rb, real_dst
            mov     rf, dst_final
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; real_dst = dst_final

dst_not_dir:
; NOTE: reached two ways -- as an explicit jump target when dst_ptr
; is NOT a directory (real_dst still holds its default, dst_ptr
; unchanged), and by plain fallthrough right after the dst_is_dir
; block above finishes building dst_final and repointing real_dst at
; it. Either way, real_dst already holds the correct value by the
; time this runs.
;------------------------------------------------------------------
; If real_dst already exists, confirm the overwrite before touching
; anything. Checked before either file is opened, so a "no" here
; needs no cleanup.
;------------------------------------------------------------------
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination path string
            mov     rd, dst_fcb         ; RD = our dst_fcb struct (reused
                                        ; below for the REAL destination
                                        ; open too -- this existence-
                                        ; check FCB is always closed
                                        ; before that happens, so the
                                        ; memory is free to reuse; movs
                                        ; before the mode load since mov
                                        ; itself clobbers D, gotcha #4)
            mov     ra, dst_iobuf       ; RA = our dst_iobuf buffer
            ldi     0                   ; mode = read (existence check)
            call    K_FILE_OPEN         ; DF = 0/1 (D unspecified)
            lbdf    dst_check_done      ; not found (or a directory):
                                        ; proceed directly, nothing to
                                        ; close

            mov     rd, dst_fcb
            call    K_FILE_CLOSE

            call    K_INMSG
            db      "Overwrite ",0
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      "? (Y/N) ",0

            call    K_READ              ; D = character read (blocking)
            ; stash in memory, not a register, across the K_TTY/
            ; K_INMSG calls below -- this project only has R9's
            ; survival confirmed across f_msg/f_inmsg (CLAUDE.md
            ; gotcha #8), and neither call has been separately
            ; audited for any other register, so a register stash
            ; across THEM would be an unverified assumption. RC is
            ; only used here as a very short-lived stash to survive
            ; "mov rf, answer_char"'s own D-clobber (gotcha #4) --
            ; not across any call.
            plo     rc
            mov     rf, answer_char
            glo     rc                  ; D = character (reloaded)
            str     rf                  ; answer_char = character

            call    K_TTY               ; echo it back to the console
            call    K_INMSG
            db      13,10,0

            mov     rf, answer_char
            ldn     rf                  ; D = the character read
            ani     $DF                 ; fold lowercase to uppercase
            xri     'Y'
            lbnz    copy_cancelled      ; anything but Y/y: cancel

dst_check_done:
            ; --- open source (mode 0, read) ---
            mov     rf, src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source string
            mov     rd, src_fcb         ; RD = our src_fcb struct
            mov     ra, src_iobuf       ; RA = our src_iobuf buffer
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; src_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    src_not_found

            ; --- open destination (mode 1, create-or-overwrite) ---
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination string
            mov     rd, dst_fcb         ; RD = our dst_fcb struct (same
                                        ; memory as the existence check
                                        ; above -- already closed there)
            mov     ra, dst_iobuf       ; RA = our dst_iobuf buffer
            ldi     1                   ; mode = write
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; dst_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    dst_open_error

;------------------------------------------------------------------
; Copy loop: read a chunk from source, write the same chunk (exact
; byte count K_FILE_READ actually returned) to destination.
;------------------------------------------------------------------
copy_loop:
            mov     rf, copy_buf
            ldi     low COPY_CHUNK_LEN
            plo     rc
            ldi     high COPY_CHUNK_LEN
            phi     rc                  ; RC = chunk size requested (512
                                        ; doesn't fit ldi's 8-bit
                                        ; immediate directly -- low/high
                                        ; split, same pattern loader.asm
                                        ; already uses for PROG_BASE)
            mov     rd, src_fcb         ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at copy_buf)
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    read_error

            glo     rc
            lbnz    have_bytes
            ghi     rc
            lbz     copy_done           ; 0 bytes read: source EOF
have_bytes:
            mov     rf, copy_buf        ; RF = source buffer (RC still
                                        ; holds the byte count from
                                        ; K_FILE_READ -- mov only
                                        ; touches RF/D, not RC)
            mov     rd, dst_fcb         ; RD = FCB pointer (fixed)
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    write_error

            lbr     copy_loop

copy_done:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention (2026-07-21)
            rtn

read_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

write_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

dst_open_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            ldi     1
            rtn

src_not_found:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            ldi     1
            rtn

copy_cancelled:
            ldi     0                   ; exit code 0 -- user's own
                                        ; choice, not an error; silent,
                                        ; per this project's "no news
                                        ; is good news" convention
                                        ; (2026-07-21)
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: COPY <source> <destination>",13,10,0
            ldi     1
            rtn

src_ptr:    dw      0
dst_ptr:    dw      0
real_dst:   dw      0

; CALLER-ALLOCATED FCBs (2026-07-15), FCB POINTER IS THE HANDLE
; (2026-07-21): src_fcb/dst_fcb are the real FCB memory (K_FILE_OPEN's
; RD arg), each with its own private FCB_IOBUF_LEN I/O buffer (RA arg)
; -- this is the whole point for COPY specifically, since src and dst
; no longer share and thrash a single kernel-resident buffer. Both are
; fixed addresses, referenced directly (RD = src_fcb / dst_fcb) by
; every K_FILE_READ/WRITE/CLOSE call site -- no separate handle
; variable needed. dst_fcb/dst_iobuf are reused for both the
; destination-exists check and the real destination open -- the first
; is always closed before the second happens.
src_fcb:    ds      FCB_LEN
src_iobuf:  ds      FCB_IOBUF_LEN
dst_fcb:    ds      FCB_LEN
dst_iobuf:  ds      FCB_IOBUF_LEN

dstchk_arg: dw      0
dstchk_result: ds   DIRENT_LEN
dst_final:  ds      DST_BUF_LEN
answer_char: db     0
copy_buf:   ds      COPY_CHUNK_LEN

            end     start
