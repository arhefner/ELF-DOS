;
; ys.asm - send one or more files via YMODEM-CRC batch transfer
;
; Usage: YS [-u|-b] [-k] [-y] [-q] <filename> [filename...]
;
; Companion to a host-side YMODEM receiver (e.g. "rz -b" from lrzsz),
; or to this project's own progs/yr.asm. Sends every named file (or
; every match of a "*"/"?" wildcard) as one continuous YMODEM batch,
; finishing with the null/terminator header that tells the receiver
; the transfer is complete -- see progs/yr.asm's own header comment
; for the matching receive-side account of the whole protocol.
;
; Flags (must precede the filename list -- the first argv token that
; isn't an exact "-u"/"-b"/"-k"/"-y"/"-q" match ends flag parsing and
; starts the filename list; at least one filename is required):
;   -u          use the disk-board UART directly (f_uread/f_utype) --
;               the default.
;   -b          use the onboard bit-bang serial port directly
;               (f_bread/f_btype) instead.
;   -k          send 1024-byte (STX) data blocks instead of the
;               default 128-byte (SOH) blocks. Header blocks are
;               always 128 bytes regardless of this flag -- matches
;               standard YMODEM convention.
;   -y          accepted, but a NO-OP for YS -- see below.
;   -q          quiet -- suppress the per-file progress line, print
;               only the final summary.
;
; -y is accepted for symmetry with YR (and with real DOS/Unix tools'
; own "-y"/"-f" force-overwrite conventions) but does nothing here:
; unlike YR, which is the one side actually creating/overwriting a
; local file and so has something real to confirm, YS only ever READS
; local files to send -- there is nothing local for -y to protect.
; Confirmed with the user before implementation.
;
; -u/-b select which BIOS routines lib/ymodem.asm's own I/O primitives
; call directly, bypassing K_READ/K_TYPE's own kernel-jump-table/RAM-
; vector indirection -- same reasoning as progs/yr.asm's identical
; flags (see its header comment for the full account).
;
; Wildcard support via lib/file_glob.asm's is_glob/glob_init/glob_next,
; same pattern as DEL/COPY/MOVE/ATTRIB/TOUCH -- a plain filename is
; sent directly; a "*"/"?" pattern is expanded and every match sent
; individually. A pattern matching zero files falls back to attempting
; the literal, unexpanded text (nullglob-off), which will then simply
; report "Not found" like any other missing literal path. A source
; naming a directory is skipped with its own error, same as a missing
; file -- YMODEM sends files, not directory trees.
;
; Sent filenames are always just the basename (e.g. "foo.txt"), never
; the resolved full/glob-matched path -- matches standard YMODEM
; convention (the receiver decides where the file lands) and matches
; how YR itself treats whatever name arrives, unmodified, as the
; destination filename.
;
; A LOCAL failure before any wire bytes for a given file have gone out
; (file not found, is a directory, can't open) prints its own error,
; sets the final exit code, and moves on to the next file in the list
; -- matches TOUCH/ATTRIB/DEL's own "note and continue" convention for
; purely local errors. A WIRE/protocol failure (the receiver sends
; CAN, or a handshake/block retry budget is exhausted) is different:
; the two ends are now permanently out of lock-step, so it aborts the
; ENTIRE batch immediately, not just the current file -- matches
; progs/yr.asm's own yrb_fatal shape. On any such abort (or a local
; file-read error partway through an already-started file, which is
; treated the same way since there is no mid-file abort signal in
; YMODEM short of ending the whole session), YS sends a courtesy
; double-CAN so the receiver doesn't have to wait out its own timeout
; -- except when the fatal condition WAS a CAN received from the
; receiver itself, where echoing one back would be pointless.
;
; Data blocks: the final (short) read of a file is padded out to the
; full block size with $1A (classic XMODEM/YMODEM SUB/pad byte,
; matching real sender convention) before its CRC is computed and it
; is sent -- the receiving end is expected to truncate using the size
; field from the header block instead (see progs/yr.asm's own
; header-comment account of that truncation), not by looking for $1A
; in the data, but padding with the conventional byte keeps this
; sender compatible with receivers (including non-YMODEM-CRC-aware
; ones) that do scan for it.
;
; This project implements YMODEM-CRC only, not the older plain-
; checksum variant -- YS only ever waits for 'C' (the CRC-mode probe)
; before sending a header, never a plain NAK. A documented, accepted
; scope limit (matches progs/yr.asm's own equivalent CRC-only design),
; not aimed at full interop with a receiver that only speaks the
; original checksum variant.
;
; Register-liveness discipline: see progs/yr.asm's own header comment
; -- the identical rule applies here (nothing survives more than one
; call to ym_getbyte/ym_getbyte_timeout/ym_putbyte/K_FILE_READ in a
; register; everything that needs to survive lives in memory).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/ymodem.inc
#include    include/file_glob.inc

            extrn   ym_crc16
            extrn   ym_fmt_uint32
            extrn   ym_getbyte_timeout
            extrn   ym_putbyte
            extrn   ym_send_block
            extrn   ym_io_mode

            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

; how many bytes of a matched/literal path's basename we'll copy into
; a header block before forcing a NUL -- generous headroom is left in
; the 128-byte block for the ASCII decimal size field that follows
; (see ys_send_header)
YS_MAX_NAME_IN_BLOCK:   equ     100

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[0] is this program's
            ; own name; argv[1..] is zero or more of -u/-b/-k/-y/-q
            ; (in any order, but all before the filename list), then
            ; one or more filenames.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            mov     rf, ym_io_mode
            ldi     YM_IO_UART          ; default
            str     rf
            mov     rf, ys_use1024
            ldi     0
            str     rf
            mov     rf, ys_quiet
            ldi     0
            str     rf

            mov     rf, ys_i
            ldi     1
            str     rf

flag_loop:
            mov     rf, ys_i
            ldn     rf
            str     r2                  ; M(X) = ys_i
            glo     rc
            xor                         ; D = argc XOR ys_i
            lbz     no_files            ; ys_i == argc: ran out with
                                        ; no filenames at all

            ; RF = argv[ys_i] (dereferenced)
            mov     rf, ys_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ys_i (zero-extended)
            shl16   r8                  ; R8 = ys_i * 2
            mov     rb, ra
            add16   rb, r8              ; RB = &argv[ys_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[ys_i]
            mov     rf, rd              ; RF = argv[ys_i] (dereferenced)

            ldn     rf
            xri     '-'
            lbnz    files_start         ; doesn't start with '-': this
                                        ; is the first filename

            inc     rf
            ldn     rf
            plo     r9                  ; R9.0 = flag letter
            inc     rf
            ldn     rf                  ; must be NUL for a clean
                                        ; 2-char flag
            lbnz    files_start         ; not a clean "-X" token:
                                        ; treat as the first filename
                                        ; (same graceful fallback
                                        ; mr.asm's own not_flag uses)

            glo     r9
            xri     'u'
            lbz     pf_uart
            glo     r9
            xri     'b'
            lbz     pf_bitbang
            glo     r9
            xri     'k'
            lbz     pf_1024
            glo     r9
            xri     'y'
            lbz     pf_next             ; -y: accepted, no-op
            glo     r9
            xri     'q'
            lbz     pf_quiet
            lbr     files_start         ; unrecognized flag letter:
                                        ; treat as the first filename

pf_uart:
            mov     rf, ym_io_mode
            ldi     YM_IO_UART
            str     rf
            lbr     pf_next
pf_bitbang:
            mov     rf, ym_io_mode
            ldi     YM_IO_BITBANG
            str     rf
            lbr     pf_next
pf_1024:
            mov     rf, ys_use1024
            ldi     1
            str     rf
            lbr     pf_next
pf_quiet:
            mov     rf, ys_quiet
            ldi     1
            str     rf

pf_next:
            mov     rf, ys_i
            ldn     rf
            adi     1
            str     rf
            lbr     flag_loop

no_files:
            lbr     usage

files_start:
            ; ys_i already indexes the first filename argv entry --
            ; stash it, along with argv/argc, before ys_run_batch's
            ; own loop makes any calls (is_glob/glob_init/glob_next/
            ; ys_send_one_file all document a broad clobber footprint,
            ; so RA/RC can't be trusted to survive even one of them)
            mov     rb, ys_i
            mov     rf, ys_first_file_i
            ldn     rb
            str     rf

            mov     rf, ys_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, ys_argc
            glo     rc
            str     rf

            call    ys_run_batch        ; D = 0 success, 1 failure
            rtn

usage:
            call    K_INMSG
            db      "Usage: YS [-u|-b] [-k] [-y] [-q] <filename> [filename...]",13,10,0
            ldi     1
            rtn

ys_i:               db      0
ys_use1024:         db      0
ys_quiet:           db      0
ys_argv:            dw      0
ys_argc:            db      0
ys_first_file_i:    db      0

;==================================================================
; ys_run_batch: send every filename argv[ys_first_file_i..argc-1]
; (each glob-expanded if it's a wildcard), then send the terminator
; header that ends the batch.
; Returns: D = 0 (all files sent cleanly) or 1 (at least one local
;          error, or the whole batch was aborted by a protocol
;          failure)
;==================================================================
ys_run_batch:
            mov     rf, ys_any_error
            ldi     0
            str     rf

            mov     rf, ys_i
            mov     rb, ys_first_file_i
            ldn     rb
            str     rf                  ; ys_i = ys_first_file_i

ysrb_loop:
            mov     rf, ys_i
            ldn     rf
            str     r2                  ; M(X) = ys_i
            mov     rf, ys_argc
            ldn     rf                  ; D = argc
            xor                         ; D = argc XOR ys_i
            lbz     ysrb_files_done     ; ys_i == argc: file list done

            ; ys_cur_argtext = argv[ys_i], stashed to memory --
            ; never trusted in a register across is_glob/glob_init/
            ; glob_next/ys_send_one_file (all document a broad
            ; clobber footprint), matching touch.asm's own established
            ; per-argument glob loop exactly
            mov     rf, ys_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ys_i (zero-extended)
            shl16   r8                  ; R8 = ys_i * 2
            mov     rb, ys_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = ys_argv (base, reloaded
                                        ; fresh every iteration)
            add16   rf, r8              ; RF = &argv[ys_i]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv[ys_i]
            mov     rf, ys_cur_argtext
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, ys_cur_argtext
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = ys_cur_argtext (deref)
            call    is_glob
            lbdf    ysrb_literal        ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, ys_cur_argtext
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, ys_glob_ctx
            call    glob_init
            lbdf    ysrb_bad_path       ; bad prefix path: this
                                        ; argv entry's own error

            mov     rf, ys_glob_found
            ldi     0
            str     rf

ysrb_glob_loop:
            mov     rd, ys_glob_ctx
            call    glob_next
            lbdf    ysrb_glob_done      ; exhausted

            ; same RF-vs-ys_glob_found collision TOUCH/DEL's own
            ; history already found and fixed -- stash the match
            ; pointer in R9 before "mov rf, ys_glob_found" below would
            ; silently overwrite it
            mov     r9, rf              ; R9 = matched full path

            mov     rf, ys_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    ys_send_one_file    ; DF = 0/1 (1 = fatal, abort
                                        ; the whole batch)
            lbdf    ysrb_aborted
            lbr     ysrb_glob_loop

ysrb_glob_done:
            mov     rf, ys_glob_found
            ldn     rf
            lbnz    ysrb_next           ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, ys_cur_argtext
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ys_send_one_file
            lbdf    ysrb_aborted
            lbr     ysrb_next

ysrb_bad_path:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, ys_cur_argtext
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, ys_any_error
            ldi     $FF
            str     rf
            lbr     ysrb_next

ysrb_literal:
            mov     rf, ys_cur_argtext
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ys_send_one_file
            lbdf    ysrb_aborted

ysrb_next:
            mov     rf, ys_i
            ldn     rf
            adi     1
            str     rf
            lbr     ysrb_loop

;------------------------------------------------------------------
; ysrb_files_done: every filename argv entry has been processed --
; send the terminator header (empty basename) to end the batch.
;------------------------------------------------------------------
ysrb_files_done:
            mov     rf, ys_basename
            ldi     0
            str     rf                  ; empty basename signals the
                                        ; terminator header to
                                        ; ys_send_header

            call    ys_wait_for_c
            lbdf    ysrb_aborted

            call    ys_send_header
            lbdf    ysrb_aborted

            mov     rf, ys_any_error
            ldn     rf
            lbnz    ysrb_report_err

            mov     rf, ys_quiet
            ldn     rf
            lbnz    ysrb_ok_silent

            call    K_INMSG
            db      "Transfer complete.",13,10,0

ysrb_ok_silent:
            ldi     0
            rtn

ysrb_report_err:
            call    K_INMSG
            db      "Transfer completed with errors.",13,10,0
            ldi     1
            rtn

ysrb_aborted:
            call    K_INMSG
            db      "Transfer aborted (protocol error).",13,10,0
            ldi     1
            rtn

ys_any_error:       db      0
ys_cur_argtext:      dw      0
ys_glob_found:       db      0
ys_glob_ctx:          ds      GLOB_CTX_LEN

;==================================================================
; ys_send_one_file: send a single already-resolved file (full/matched
; path in RF) as one complete YMODEM file transfer (header, data,
; EOT).
; Args:    RF = path (full glob match, or the literal argv text)
; Returns: DF = 0 (sent, or a local error was printed and this file
;          was simply skipped -- ys_any_error is set in the latter
;          case), DF = 1 (a wire/protocol failure occurred -- the
;          WHOLE batch must abort, not just this file)
;==================================================================
ys_send_one_file:
            mov     rb, ys_cur_path
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ys_cur_path = RF (this
                                        ; call's own path -- for a
                                        ; glob match this is the
                                        ; specific matched path, not
                                        ; ys_cur_argtext's original
                                        ; pattern text)

            ; RF still holds this proc's own incoming path argument,
            ; untouched by the stash above (nothing there wrote RF) --
            ; K_STAT's own "RF = path" requirement is already met
            mov     rd, ys_statbuf
            call    K_STAT              ; DF = 0: exists
            lbdf    ysof_not_found

            mov     rf, ys_statbuf
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    ysof_is_dir

            ; stash the size (DIRENT_SIZE, 4 bytes big-endian) for
            ; the header block and the data-padding math
            mov     rf, ys_statbuf
            add16   rf, DIRENT_SIZE
            mov     rb, ys_cur_size_hi
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            mov     rf, ys_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = ys_cur_path (deref)
            mov     rd, ys_fcb
            mov     ra, ys_iobuf
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF = 0/1
            lbdf    ysof_open_failed

            ; extract basename(ys_cur_path): scan forward, remembering
            ; the position right after the LAST '/' seen (defaults to
            ; the string's own start if none found) -- same idiom
            ; progs/copy.asm's own co_basename_scan already established
            mov     rf, ys_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ys_cur_path (deref)
            mov     r8, rd              ; R8 = scan pointer
            mov     r9, rd              ; R9 = basename pointer
                                        ; (updated on each '/' seen)
ysof_bn_scan:
            ldn     r8
            lbz     ysof_bn_done
            xri     '/'
            lbnz    ysof_bn_next
            inc     r8
            mov     r9, r8              ; R9 = position right after '/'
            lbr     ysof_bn_scan
ysof_bn_next:
            inc     r8
            lbr     ysof_bn_scan
ysof_bn_done:
            mov     rf, r9              ; RF = basename source pointer
            mov     rb, ys_basename
            ldi     127
            plo     rc                  ; RC.0 = real copies remaining
                                        ; before a forced stop (same
                                        ; bounded-copy defense as
                                        ; progs/yr.asm's own filename
                                        ; receive)
ysof_bn_copy:
            lda     rf
            str     rb
            lbz     ysof_bn_copied      ; wrote a real NUL: stop
            inc     rb
            glo     rc
            smi     1
            plo     rc
            lbz     ysof_bn_force
            lbr     ysof_bn_copy
ysof_bn_force:
            inc     rb
            ldi     0
            str     rb
ysof_bn_copied:
            call    ys_wait_for_c
            lbdf    ysof_close_fatal

            call    ys_send_header
            lbdf    ysof_close_fatal

            call    ys_wait_for_c       ; second 'C': send data now
            lbdf    ysof_close_fatal

            call    ys_send_file_data
            lbdf    ysof_close_fatal

            mov     rd, ys_fcb
            call    K_FILE_CLOSE

            mov     rf, ys_quiet
            ldn     rf
            lbnz    ysof_ok

            call    K_INMSG
            db      "Sent ",0
            mov     rf, ys_basename
            call    K_MSG
            call    K_INMSG
            db      13,10,0

ysof_ok:
            clc
            rtn

ysof_close_fatal:
            mov     rd, ys_fcb
            call    K_FILE_CLOSE
            stc
            rtn

ysof_not_found:
            call    K_INMSG
            db      "Not found: ",0
            lbr     ysof_local_err

ysof_is_dir:
            call    K_INMSG
            db      "Not a file: ",0
            lbr     ysof_local_err

ysof_open_failed:
            call    K_INMSG
            db      "Cannot open: ",0

ysof_local_err:
            mov     rf, ys_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, ys_any_error
            ldi     $FF
            str     rf
            clc                         ; local error: not fatal to
                                        ; the whole batch
            rtn

ys_cur_path:         dw      0
ys_cur_size_hi:       dw      0
ys_cur_size_lo:       dw      0
ys_basename:          ds      128
ys_fcb:               ds      FCB_LEN
ys_iobuf:             ds      FCB_IOBUF_LEN
ys_statbuf:           ds      DIRENT_LEN

;==================================================================
; ys_wait_for_c: wait for the receiver's 'C' (CRC-mode probe),
; retrying (via ym_getbyte_timeout's own per-attempt poll budget) up
; to YM_HANDSHAKE_TRIES total attempts. A byte that's neither 'C' nor
; CAN is silently ignored but still counts against the retry budget,
; bounding the worst-case total wait.
; Returns: DF = 0 ('C' received), DF = 1 (fatal: CAN received, or the
;          retry budget was exhausted)
;==================================================================
ys_wait_for_c:
            mov     rf, ys_retry
            ldi     YM_HANDSHAKE_TRIES
            str     rf

ywfc_wait:
            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    ywfc_next_try       ; timeout

            plo     r8
            glo     r8
            xri     YM_CAN
            lbz     ywfc_fatal_no_can   ; already got a CAN -- no need
                                        ; to echo one back

            glo     r8
            xri     YM_C
            lbz     ywfc_got_c

            lbr     ywfc_next_try       ; unrecognized byte: ignore

ywfc_next_try:
            mov     rf, ys_retry
            ldn     rf
            smi     1
            str     rf
            lbz     ywfc_fatal
            lbr     ywfc_wait

ywfc_got_c:
            clc
            rtn

ywfc_fatal:
            call    ys_send_cancel
ywfc_fatal_no_can:
            stc
            rtn

ys_retry:            db      0
ys_crc_hi:           db      0           ; must stay immediately
                                        ; before ys_crc_lo -- both
                                        ; CRC-send sites write these
                                        ; via a single mov+inc pair
ys_crc_lo:           db      0

;==================================================================
; ys_send_header: build and send a header block from ys_basename
; (empty string = the batch terminator) and ys_cur_size_hi/lo,
; retrying on NAK/timeout up to YM_BLOCK_TRIES times.
; Returns: DF = 0 (ACKed), DF = 1 (fatal: CAN received, or the retry
;          budget was exhausted)
;==================================================================
ys_send_header:
            mov     rf, ys_block_buf
            ldi     0
            phi     rc
            ldi     128
            plo     rc
ysh_zero_loop:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            ghi     rc
            lbnz    ysh_zero_loop
            glo     rc
            lbnz    ysh_zero_loop

            mov     rf, ys_basename
            mov     rb, ys_block_buf
            ldi     YS_MAX_NAME_IN_BLOCK
            plo     r9                  ; R9.0 = real copies remaining
                                        ; before a forced stop

ysh_copy_name:
            lda     rf
            str     rb
            lbz     ysh_name_done       ; wrote a real NUL: RB still
                                        ; points AT it
            inc     rb
            glo     r9
            smi     1
            plo     r9
            lbz     ysh_name_forced
            lbr     ysh_copy_name

ysh_name_forced:
            inc     rb
            ldi     0
            str     rb                  ; RB now points AT a forced
                                        ; NUL, same as the natural case

ysh_name_done:
            inc     rb                  ; RB = write cursor, just past
                                        ; the NUL

            ; terminator (empty basename)? skip the size field --
            ; the rest of the block stays all-zero
            mov     rf, ys_basename
            ldn     rf
            lbz     ysh_have_block

            mov     rf, ys_cur_size_hi
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = size
            mov     rf, rb              ; RF = write cursor
            call    ym_fmt_uint32       ; writes decimal digits + NUL

ysh_have_block:
            mov     rf, ys_retry
            ldi     YM_BLOCK_TRIES
            str     rf

ysh_send_attempt:
            ldi     YM_SOH
            call    ym_putbyte
            ldi     0
            call    ym_putbyte          ; blockno = 0
            ldi     255
            call    ym_putbyte          ; ~blockno = $FF

            mov     rf, ys_block_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc
            call    ym_send_block

            mov     rf, ys_block_buf
            ldi     0
            phi     rc
            ldi     128
            plo     rc
            call    ym_crc16            ; RD = CRC

            ; ym_putbyte's own header documents RD as clobbered -- it
            ; can't be trusted to still hold the CRC's low byte after
            ; the high byte's own call returns, so both bytes are
            ; stashed to memory first (caught during a post-assembly
            ; register-liveness re-trace, before ever reaching
            ; hardware: unlike progs/yr.asm's own back-to-back ghi rd/
            ; glo rd CRC checks, which never call anything in between,
            ; this path calls ym_putbyte between the two reads)
            mov     rf, ys_crc_hi
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ys_crc_hi
            ldn     rf
            call    ym_putbyte
            mov     rf, ys_crc_lo
            ldn     rf
            call    ym_putbyte

            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    ysh_retry           ; timeout

            plo     r8
            glo     r8
            xri     YM_ACK
            lbz     ysh_ok

            glo     r8
            xri     YM_CAN
            lbz     ysh_fatal_no_can

            ; NAK or anything else: retry (resend the same header)
ysh_retry:
            mov     rf, ys_retry
            ldn     rf
            smi     1
            str     rf
            lbz     ysh_fatal
            lbr     ysh_send_attempt

ysh_ok:
            clc
            rtn

ysh_fatal:
            call    ys_send_cancel
ysh_fatal_no_can:
            stc
            rtn

;==================================================================
; ys_send_file_data: send ys_fcb's remaining content as one or more
; data blocks (128 or 1024 bytes, per ys_use1024), then EOT. The
; final (short) read is padded to the full block size with $1A before
; its CRC is computed -- see this file's own top-of-file header
; comment.
; Returns: DF = 0 (all data sent and EOT ACKed), DF = 1 (fatal)
;==================================================================
ys_send_file_data:
            mov     rf, ys_blockno
            ldi     1
            str     rf

ysd_next_block:
            mov     rf, ys_use1024
            ldn     rf
            lbnz    ysd_size_1024
            mov     rf, ys_block_len
            ldi     0
            str     rf
            inc     rf
            ldi     YM_BLKLEN_128
            str     rf
            lbr     ysd_have_size
ysd_size_1024:
            mov     rf, ys_block_len
            ldi     high YM_BLKLEN_1024
            str     rf
            inc     rf
            ldi     low YM_BLKLEN_1024
            str     rf

ysd_have_size:
            mov     rf, ys_block_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            mov     rf, ys_block_buf
            mov     rd, ys_fcb
            call    K_FILE_READ         ; RC = bytes actually read,
                                        ; DF = 0/1
            lbdf    ysd_read_err

            mov     rf, ys_real_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            ghi     rc
            lbnz    ysd_have_data
            glo     rc
            lbnz    ysd_have_data
            lbr     ysd_send_eot        ; nothing left: finish

ysd_have_data:
            mov     rf, ys_real_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = real_len
            mov     rf, ys_block_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = block_len

            ghi     rd
            str     r2
            ghi     r8
            xor
            lbnz    ysd_do_pad
            glo     rd
            str     r2
            glo     r8
            xor
            lbz     ysd_send_block      ; real_len == block_len:
                                        ; nothing to pad

ysd_do_pad:
            ; pad_count = block_len - real_len (16-bit subtract)
            glo     rd
            str     r2
            glo     r8
            sm
            plo     r9
            ghi     rd
            str     r2
            ghi     r8
            smb
            phi     r9                  ; R9 = pad_count

            mov     r8, ys_block_buf
            add16   r8, rd              ; R8 = &block_buf[real_len]
                                        ; (block_len's own copy in R8
                                        ; is no longer needed)

ysd_pad_loop:
            ghi     r9
            lbnz    ysd_pad_have
            glo     r9
            lbz     ysd_send_block      ; pad_count == 0: done

ysd_pad_have:
            ldi     $1A
            str     r8
            inc     r8
            dec     r9
            lbr     ysd_pad_loop

ysd_send_block:
            mov     rf, ys_retry
            ldi     YM_BLOCK_TRIES
            str     rf

ysd_block_attempt:
            mov     rf, ys_use1024
            ldn     rf
            lbnz    ysdb_stx
            ldi     YM_SOH
            lbr     ysdb_type_sent
ysdb_stx:
            ldi     YM_STX
ysdb_type_sent:
            call    ym_putbyte

            mov     rf, ys_blockno
            ldn     rf
            call    ym_putbyte

            mov     rf, ys_blockno
            ldn     rf
            xri     255
            call    ym_putbyte          ; ~blockno

            mov     rf, ys_block_buf
            mov     rd, ys_block_len
            lda     rd
            phi     rc
            ldn     rd
            plo     rc
            sub16   rc, 1               ; ym_send_block's own
                                        ; pre-decremented convention
            call    ym_send_block

            mov     rf, ys_block_buf
            mov     rd, ys_block_len
            lda     rd
            phi     rc
            ldn     rd
            plo     rc
            call    ym_crc16            ; RD = CRC

            ; same RD-clobbered-by-ym_putbyte fix as ys_send_header's
            ; own identical CRC send -- see its comment for the full
            ; reasoning
            mov     rf, ys_crc_hi
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ys_crc_hi
            ldn     rf
            call    ym_putbyte
            mov     rf, ys_crc_lo
            ldn     rf
            call    ym_putbyte

            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    ysdb_retry          ; timeout

            plo     r8
            glo     r8
            xri     YM_ACK
            lbz     ysdb_acked

            glo     r8
            xri     YM_CAN
            lbz     ysd_fatal_no_can

ysdb_retry:
            mov     rf, ys_retry
            ldn     rf
            smi     1
            str     rf
            lbz     ysd_fatal
            lbr     ysd_block_attempt

ysdb_acked:
            mov     rf, ys_blockno
            ldn     rf
            adi     1
            str     rf
            lbr     ysd_next_block

;------------------------------------------------------------------
; ysd_send_eot: send EOT, expecting the classic double-EOT dance
; (matches progs/yr.asm's own yrd_got_eot from the opposite side: the
; receiver NAKs the first EOT, then ACKs regardless of what -- if
; anything -- follows) -- a NAK here just means "send EOT again".
;------------------------------------------------------------------
ysd_send_eot:
            mov     rf, ys_retry
            ldi     YM_BLOCK_TRIES
            str     rf

ysd_eot_attempt:
            ldi     YM_EOT
            call    ym_putbyte

            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    ysd_eot_retry       ; timeout: retry

            plo     r8
            glo     r8
            xri     YM_ACK
            lbz     ysd_eot_ok

            glo     r8
            xri     YM_CAN
            lbz     ysd_fatal_no_can

            ; NAK, or a second EOT, or anything else: send EOT again
ysd_eot_retry:
            mov     rf, ys_retry
            ldn     rf
            smi     1
            str     rf
            lbz     ysd_fatal
            lbr     ysd_eot_attempt

ysd_eot_ok:
            clc
            rtn

ysd_read_err:
            ldi     YM_CAN
            call    ym_putbyte
            ldi     YM_CAN
            call    ym_putbyte
            stc
            rtn

ysd_fatal:
            call    ys_send_cancel
ysd_fatal_no_can:
            stc
            rtn

ys_blockno:          db      0
ys_block_len:        dw      0
ys_real_len:         dw      0
ys_block_buf:        ds      1024

;==================================================================
; ys_send_cancel: send the classic double-CAN abort signal. Called
; from every fatal-exit path EXCEPT one that was itself triggered by
; receiving a CAN (no point echoing one back).
;==================================================================
ys_send_cancel:
            ldi     YM_CAN
            call    ym_putbyte
            ldi     YM_CAN
            call    ym_putbyte
            rtn

            end     start
