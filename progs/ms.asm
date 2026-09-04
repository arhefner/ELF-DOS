;
; ms.asm - send one or more files via the MAX protocol
;
; Usage: MS [-u|-b] <filename> [filename...]
;
; Companion to the host-side max-xfr tool (Elf-xfer/max-xfr), run as
; "max-xfr -r" to receive. mr and ms are two directions of the same
; batch-capable protocol; see mr.asm's own header comment for the full
; account of the length-prefixed, doubly-acknowledged chunk design
; (2026-09-04 redesign, replacing the earlier command-byte/address-
; field framing entirely) and ms_session's own header comment below for
; this direction's exact byte sequence.
;
; Each argument may be a plain filename or a "*"/"?" wildcard, expanded
; via lib/file_glob.asm's is_glob/glob_init/glob_next -- same pattern
; this project already uses for COPY/MOVE/DEL/ATTRIB/TOUCH. A pattern
; matching zero files falls back to attempting the literal, unexpanded
; text (nullglob-off), which then simply reports "Not found" like any
; other missing literal path. Every sent filename is just the
; basename (e.g. "foo.txt"), never the resolved full/glob-matched
; path -- matches YMODEM's own convention (the receiver decides where
; the file lands) and matches how mr.asm itself treats whatever name
; arrives as, at most, informational (see its own header comment for
; when it's used and when it's ignored).
;
; A LOCAL failure for one file (not found, is a directory, can't open,
; a read error partway through) prints its own message and moves on to
; the next file -- matches TOUCH/ATTRIB/DEL's own "note and continue"
; convention. A WIRE/PROTOCOL failure (an echoed header/block field
; that doesn't match, a missing block ack, or the final
; acknowledgment never arriving) is different: the two ends are now
; permanently out of lock-step, so it aborts the WHOLE batch
; immediately, not just the current file -- there is no retry/cancel
; signal in this minimal protocol (unlike YMODEM's CAN byte), matching
; this project's own original single-file ms_send, which already
; treated any echo mismatch as fully fatal.
;
; DEVICE SELECTION (2026-09-01, restored and redesigned -- see
; mr.asm's own header comment for the full account, including the
; retracted "-u/-b is pointless now" reasoning this replaces): now
; that K_TYPE/K_READ are self-modified jump-table slots reaching
; whichever device is actually the CONSOLE, with no runtime redirect-
; check branch and no register cost over a direct BIOS call, the
; DEFAULT (no flag) is to use them -- MS's own transfer then
; automatically follows whatever the console currently is. "-u"/"-b"
; are an explicit opt-out: they route every byte of THIS session's own
; protocol directly to the hardware UART (-u) or the onboard bit-
; banged UART (-b), bypassing K_TYPE/K_READ's own vector entirely, so
; a transfer can run on a DIFFERENT physical port than the console
; (watch debug/log output on the console while a transfer runs
; elsewhere, or drive a transfer from outside a terminal emulator
; entirely). ms_getbyte/ms_putbyte (ms_session's own local
; subroutines, below) are the mode-aware dispatch point for every
; PROTOCOL byte; the hot per-byte DATA loop (ms_sendbytes) gets its
; own separate, page-aligned, hand-short-branched 3-way dispatch for
; speed, mirroring lib/ymodem.asm's own ym_getbyte/ym_putbyte vs.
; ym_send_block split exactly.
;
; The register-liveness caution this file has carried since 2026-07-11
; is UNCHANGED: nothing is trusted to survive more than one call to
; ms_getbyte/ms_putbyte (or, equivalently, K_READ/K_TYPE directly, in
; CONSOLE mode) in a register -- every value that must survive a call
; lives in memory instead (ms_blk_buf/ms_blk_count and friends), reloaded
; fresh immediately before use. The ONE loop that trusts a register
; (RC/RF) across many repeated per-byte calls -- ms_sendbytes, the hot
; per-byte transfer loop -- is exactly the same register/call shape
; this project has relied on since ms.asm's very first version.
;
; ms_session is a real proc/endp block (extrn'd from start, ordinary
; same-file cross-proc convention) rather than inline in start, purely
; for size/organization -- it has no hand-written short branches of
; its own and so needs no page alignment. ms_sendbytes (the hot
; per-byte loop) is a SEPARATE, page-aligned proc, exactly matching the
; original file's own ms_send/ms_sendbytes split: the handshake/
; header-echo/batch-management code ahead of it in ms_session pushes
; well past what a single page-aligned ms_session could still
; guarantee for a hand-written short branch this deep into the file.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/file_glob.inc

            extrn   ms_session
            extrn   ms_sendbytes
            extrn   fmt_size32
            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

XFER_BUF_LEN:       equ     512

; MAXFER_NAME_MAX: matches DIRENT_NAME's own 127-char cap
; (kernel_api.inc) and mr.asm's own identical bound on the receive
; side.
MAXFER_NAME_MAX:    equ     127

; ms_process_file's own return convention (D). ms_session's overall
; return code (checked by start) is a separate, simpler generic
; 0/1/2 -- see ms_session's own header comment for that one.
MSF_OK:             equ     0       ; file sent cleanly
MSF_LOCAL_ERR:      equ     1       ; local error (not found, is a
                                    ; directory, can't open, a read
                                    ; error) -- already printed, the
                                    ; batch continues
MSF_FATAL:          equ     2       ; wire/protocol error -- already
                                    ; printed, the whole batch must
                                    ; stop

; ms_io_mode (start, below): which device every byte of this session's
; own protocol goes over -- see this file's own header comment for the
; full design. CONSOLE (0) is the default.
MS_IO_CONSOLE:      equ     0       ; via K_READ/K_TYPE (default)
MS_IO_UART:         equ     1       ; via f_uread/f_utype directly
MS_IO_BITBANG:      equ     2       ; via f_bread/f_btype directly

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[1], if present, may
            ; be "-u"/"-b" (must come first, matching YR/YS's own
            ; convention) selecting which physical port every byte of
            ; this session's own protocol goes over -- see this file's
            ; own header comment. Filenames start right after any
            ; flag; at least one is always required.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            mov     rf, ms_io_mode
            ldi     MS_IO_CONSOLE       ; default
            str     rf

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    start_no_flag

            mov     rf, rd
            inc     rf
            ldn     rf                  ; D = argv[1][1]
            plo     r8                  ; R8.0 = flag letter (temp)

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be
                                        ; NUL for "-u"/"-b" to be
                                        ; exactly this whole token
            lbnz    start_no_flag       ; not exactly 2 chars after
                                        ; '-': fall back to treating
                                        ; argv[1] as a filename

            glo     r8
            xri     'u'
            lbz     start_flag_uart
            glo     r8
            xri     'b'
            lbz     start_flag_bitbang
            lbr     start_no_flag       ; unrecognized letter: same
                                        ; fallback

start_flag_uart:
            mov     rf, ms_io_mode
            ldi     MS_IO_UART
            str     rf
            lbr     start_after_flag

start_flag_bitbang:
            mov     rf, ms_io_mode
            ldi     MS_IO_BITBANG
            str     rf

start_after_flag:
            ; a flag was consumed as argv[1] -- at least one filename
            ; must remain (argc >= 3), starting at argv[2]
            glo     rc
            smi     3
            lbnf    usage
            mov     rf, ms_files_start
            ldi     2
            str     rf
            lbr     start_have_files

start_no_flag:
            mov     rf, ms_files_start
            ldi     1
            str     rf

start_have_files:
            mov     rf, ms_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf                  ; ms_argv = RA

            mov     rf, ms_argc
            glo     rc
            str     rf                  ; ms_argc = RC.0

            call    ms_session          ; prints its own per-file
                                        ; progress and a final summary;
                                        ; D = 0/1/2 -- see ms_session's
                                        ; own header comment
            plo     r8                  ; BUG-CLASS GUARD: stash the
                                        ; result before anything below
                                        ; (a "mov") clobbers D

            glo     r8
            lbz     start_success
            ldi     1
            rtn

start_success:
            ldi     0
            rtn

usage:
            call    K_INMSG
            db      "Usage: MS [-u|-b] <filename> [filename...]",13,10,0
            ldi     1
            rtn

ms_argv:        dw      0
ms_argc:        db      0
ms_files_start: db      0
ms_io_mode:     db      0

;==================================================================
; ms_session: send one or more files over the console/serial port,
; using ELF-DOS's own length-prefixed, doubly-acknowledged chunk
; protocol (matches max-xfr's "-r" / receive mode).
;
; Protocol:
;   1. Wait for $AA (sync) from the host. Reply with $55. Deferred
;      until the FIRST file that actually opens successfully (a purely
;      local failure -- e.g. every argument on the command line is a
;      typo -- never touches the wire at all).
;   2. Every further exchange is a CHUNK: we write a 2-byte big-endian
;      LENGTH, then wait for a $AA ack (this ack just means "length
;      received," not "chunk fully processed"). If LENGTH is nonzero,
;      we then write that many un-echoed payload bytes (via
;      ms_sendbytes below), and wait for a SECOND $AA -- sent by the
;      far end only once it has genuinely finished doing something
;      with that payload (a disk write, or opening the destination
;      file), not just once the bytes are off the wire, which is what
;      makes this protocol self-throttling: we can never get more than
;      one length-field ahead of what the far end has actually
;      finished processing. A LENGTH of 0 needs only the one ack -- no
;      payload phase at all -- and is how a "no more data"/"no more
;      files" end marker is sent (ms_send_end_marker below); there is
;      no separate command byte or address field anywhere in this
;      protocol.
;   3. For each file that opens successfully:
;      a. HEADER CHUNK: the file's basename (null-terminated) followed
;         by its 32-bit size, big-endian binary (not YMODEM's ASCII-
;         octal convention) -- read straight out of K_STAT's own
;         DIRENT_SIZE field, already in the exact byte order this
;         header needs.
;      b. DATA CHUNKS: the file's actual content, one or more times.
;      c. End of this file's data: a zero-length chunk, moving
;         straight on to the NEXT file's own header chunk (step 3a).
;   4. Once every file has been sent, a zero-length chunk in the SAME
;      "starting a new file" state every header chunk starts from --
;      that's what distinguishes "end of this file's data" (mid-file)
;      from "end of the whole batch" (between files). Then reads the
;      host's final 'x' (written unconditionally by max-xfr's own
;      main() once receive_batch() returns, matching the original
;      single-file protocol's own end sequence).
;
; Args:    none (reads ms_argv/ms_argc, set by start)
; Returns: D  = 0 (every file sent cleanly, whole session completed
;          without a protocol error), 1 (the protocol completed
;          cleanly but at least one individual file failed locally),
;          2 (a wire/protocol error aborted the whole session)
;          DF = 0 on success, DF = 1 on failure (redundant with D,
;          kept for consistency with this project's other calls)
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            proc    ms_session

            mov     rf, ms_ok_count
            ldi     0
            str     rf
            mov     rf, ms_err_count
            ldi     0
            str     rf
            mov     rf, ms_handshake_done
            ldi     0
            str     rf
            mov     rf, ms_abort
            ldi     0
            str     rf

            mov     rf, ms_i
            mov     rd, ms_files_start
            ldn     rd
            str     rf                  ; ms_i = ms_files_start (1, or
                                        ; 2 if a "-u"/"-b" flag was
                                        ; consumed as argv[1])

;------------------------------------------------------------------
; Outer loop: one iteration per argv entry (a literal filename or a
; wildcard pattern).
;------------------------------------------------------------------
mss_loop:
            mov     rf, ms_abort
            ldn     rf
            lbnz    mss_loop_done       ; a fatal error already ended
                                        ; the session

            mov     rf, ms_i
            ldn     rf
            str     r2                  ; M(X) = ms_i (subtrahend)
            mov     rf, ms_argc
            ldn     rf                  ; D = ms_argc (minuend)
            sm                          ; D = ms_argc - ms_i
            lbnf    mss_loop_done       ; ms_argc < ms_i: every
                                        ; argument handled

            ; RD = argv[ms_i]
            mov     rf, ms_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = ms_i * 2
            mov     rf, ms_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = ms_argv (base)
            add16   rb, r8              ; RB = &argv[ms_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[ms_i]

            mov     rf, ms_cur_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ms_cur_arg = argv[ms_i]

            mov     rf, ms_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    is_glob             ; DF = 0/1
            lbdf    mss_literal         ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, ms_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, ms_glob_ctx
            call    glob_init           ; DF = 0/1
            lbdf    mss_glob_bad_path

            mov     rf, ms_glob_found
            ldi     0
            str     rf

mss_glob_loop:
            mov     rf, ms_abort
            ldn     rf
            lbnz    mss_glob_done

            mov     rd, ms_glob_ctx
            call    glob_next           ; DF = 0/1, RF = match
            lbdf    mss_glob_done       ; exhausted

            ; BUG-CLASS GUARD (copy.asm's own established precedent):
            ; stash the match pointer in R9 before anything below (a
            ; "mov") clobbers RF.
            mov     r9, rf

            mov     rf, ms_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    ms_process_file     ; D = MSF_*
            call    ms_handle_result
            lbr     mss_glob_loop

mss_glob_done:
            mov     rf, ms_glob_found
            ldn     rf
            lbnz    mss_next            ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, ms_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ms_process_file
            call    ms_handle_result
            lbr     mss_next

mss_glob_bad_path:
            call    K_INMSG
            db      "Source file not found: ",0
            mov     rf, ms_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            mov     rf, ms_err_count
            ldn     rf
            adi     1
            str     rf
            lbr     mss_next

mss_literal:
            mov     rf, ms_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ms_process_file
            call    ms_handle_result

mss_next:
            mov     rf, ms_i
            ldn     rf
            adi     1
            str     rf
            lbr     mss_loop

mss_loop_done:
            mov     rf, ms_abort
            ldn     rf
            lbnz    mss_had_fatal

            mov     rf, ms_handshake_done
            ldn     rf
            lbz     mss_result_check    ; nothing was ever sent at
                                        ; all (every argument was a
                                        ; purely local failure) --
                                        ; nothing to close out on the
                                        ; wire

            ; --- outer "no more files" terminator + final ack ---
            call    ms_send_end_marker
            lbdf    mss_final_err

            call    ms_getbyte
            xri     'x'
            lbz     mss_result_check

mss_final_err:
            call    K_INMSG
            db      "Protocol error: no final acknowledgment from host.",13,10,0
            ldi     MSF_FATAL
            lbr     mss_summarize

mss_result_check:
            mov     rf, ms_err_count
            ldn     rf
            lbz     mss_fully_clean
            ldi     1
            lbr     mss_summarize

mss_fully_clean:
            ldi     0
            lbr     mss_summarize

mss_had_fatal:
            ldi     MSF_FATAL

;------------------------------------------------------------------
; mss_summarize: D already holds the session's own result code.
; Stash it (a register can't survive fmt_size32's own "Modifies:
; everything" -- see lib/fmt32.asm's own header), print the ok/err
; counts, then reload it for the real return.
;------------------------------------------------------------------
mss_summarize:
            plo     rc                  ; BUG-CLASS GUARD: stash D via
                                        ; a register PLO (which
                                        ; doesn't touch D) before "mov
                                        ; rf, ..." clobbers it.
            mov     rf, ms_result
            glo     rc
            str     rf

            mov     rf, ms_ok_count
            call    ms_print_count
            call    K_INMSG
            db      " file(s) sent.",13,10,0

            mov     rf, ms_err_count
            ldn     rf
            lbz     mss_sum_skip_err
            mov     rf, ms_err_count
            call    ms_print_count
            call    K_INMSG
            db      " file(s) failed.",13,10,0
mss_sum_skip_err:

            mov     rf, ms_result
            ldn     rf
            lbz     mss_summarize_ok
            stc
            rtn
mss_summarize_ok:
            clc
            rtn

;------------------------------------------------------------------
; ms_process_file: send one already-resolved file (a literal argv
; entry, or one glob match) as a single header block + data blocks +
; per-file EOF marker. Performs the session's ONE-TIME handshake
; itself, the first time it's ever called with a file that actually
; opens for reading.
; Args:    RF = source path
; Returns: D = MSF_OK / MSF_LOCAL_ERR / MSF_FATAL (see the equ's
;          above) -- every outcome has already printed its own
;          message
; Modifies: everything
;------------------------------------------------------------------
ms_process_file:
            mov     rd, ms_cur_path
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd                  ; ms_cur_path = RF

            ; --- K_STAT: existence + directory check + size ---
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, ms_stat_buf
            call    K_STAT              ; DF = 0/1
            lbdf    mpf_not_found

            mov     rf, ms_stat_buf
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    mpf_is_dir

            ; --- open for read ---
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, ms_fcb
            mov     ra, ms_iobuf
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF = 0/1
            lbdf    mpf_cannot_open

            ; --- one-time session handshake ---
            mov     rf, ms_handshake_done
            ldn     rf
            lbnz    mpf_have_shake

            call    ms_getbyte
            xri     $aa
            lbz     mpf_shake_ok

            mov     rd, ms_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "No response from host.",13,10,0
            ldi     MSF_FATAL
            rtn

mpf_shake_ok:
            ldi     $55
            call    ms_putbyte
            mov     rf, ms_handshake_done
            ldi     1
            str     rf

mpf_have_shake:
            call    ms_basename         ; ms_basename_buf = basename
                                        ; of ms_cur_path, bounded to
                                        ; MAXFER_NAME_MAX chars

            ; --- build the header payload: basename + NUL + 4-byte
            ; big-endian size (copied straight from K_STAT's own
            ; DIRENT_SIZE field -- already the exact byte order this
            ; header needs, no repacking) ---
            mov     rf, ms_hdr_buf
            mov     rd, ms_basename_buf
mpf_hdr_copy:
            lda     rd
            str     rf
            lbz     mpf_hdr_have_nul
            inc     rf
            lbr     mpf_hdr_copy

mpf_hdr_have_nul:
            inc     rf                  ; RF = one past the NUL just
                                        ; written
            mov     r8, rf              ; R8 = size-field write cursor
            mov     rd, ms_stat_buf
            add16   rd, DIRENT_SIZE
            lda     rd
            str     r8
            inc     r8
            lda     rd
            str     r8
            inc     r8
            lda     rd
            str     r8
            inc     r8
            ldn     rd
            str     r8                  ; R8 now points at the last
                                        ; size byte written

            ; header payload length = (R8 - ms_hdr_buf) + 1
            mov     rf, r8
            mov     rd, ms_hdr_buf
            sub16   rf, rd              ; RF = R8 - ms_hdr_buf
            mov     rc, rf
            add16   rc, 1

            mov     rf, ms_hdr_buf
            call    ms_send_block       ; DF = 0/1
            lbdf    mpf_fatal_close

;------------------------------------------------------------------
; Data blocks.
;------------------------------------------------------------------
mpf_data_loop:
            mov     rf, ms_databuf
            ldi     low XFER_BUF_LEN
            plo     rc
            ldi     high XFER_BUF_LEN
            phi     rc
            mov     rd, ms_fcb
            call    K_FILE_READ         ; RC = bytes actually read,
                                        ; DF = 0/1
            lbdf    mpf_read_err

            glo     rc
            lbnz    mpf_have_chunk
            ghi     rc
            lbz     mpf_data_eof

mpf_have_chunk:
            mov     rf, ms_databuf      ; RF = buffer; RC still holds
                                        ; the real byte count from
                                        ; K_FILE_READ -- untouched by
                                        ; the zero-check or this mov
            call    ms_send_block       ; DF = 0/1
            lbdf    mpf_fatal_close
            lbr     mpf_data_loop

mpf_data_eof:
            call    ms_send_end_marker      ; per-file EOF marker: a
                                        ; zero-length chunk, genuinely
                                        ; ack'd -- unlike the original
                                        ; single-file protocol, this
                                        ; does NOT wait for the host's
                                        ; 'x' here, only for the chunk's
                                        ; own ack; 'x' only happens
                                        ; once, at the very end of the
                                        ; whole batch (see ms_session's
                                        ; own header comment)
            lbdf    mpf_fatal_close

            mov     rd, ms_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Sent ",0
            mov     rf, ms_basename_buf
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     MSF_OK
            rtn

mpf_read_err:
            mov     rd, ms_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error: ",0
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     MSF_FATAL           ; the receiver is already
                                        ; mid-file, expecting more
                                        ; data blocks we can no longer
                                        ; produce -- there's no mid-
                                        ; file abort signal in this
                                        ; protocol, so the whole
                                        ; session has to stop (matches
                                        ; the original single-file
                                        ; ms_send's own identical
                                        ; treatment of this case)
            rtn

mpf_fatal_close:
            mov     rd, ms_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Protocol error talking to host.",13,10,0
            ldi     MSF_FATAL
            rtn

mpf_not_found:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     MSF_LOCAL_ERR
            rtn

mpf_is_dir:
            call    K_INMSG
            db      "Is a directory: ",0
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     MSF_LOCAL_ERR
            rtn

mpf_cannot_open:
            call    K_INMSG
            db      "Cannot open ",0
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     MSF_LOCAL_ERR
            rtn

;------------------------------------------------------------------
; ms_send_block: send one chunk (header OR data -- identical wire
; shape either way): a 2-byte big-endian length, wait for the length
; ack, then the payload bytes (via ms_sendbytes), then wait for the
; payload ack. The far end sends the payload ack only once it has
; genuinely finished processing this chunk (a disk write, or opening
; the destination file) -- not merely once the bytes are off the wire
; -- which is what makes the whole protocol self-throttling; nothing
; special is needed here to benefit from that, we just wait for the
; ack as always.
; Args:    RF = payload buffer, RC = payload byte count (must be > 0
;          -- every caller already only calls this with a real,
;          nonzero chunk; a zero-length "no more data" marker goes
;          through ms_send_end_marker instead)
; Returns: DF = 0 (sent and acked), DF = 1 (an ack mismatch -- fatal
;          to the whole session, the two ends are now out of
;          lock-step)
; Modifies: everything
;------------------------------------------------------------------
ms_send_block:
            mov     rd, ms_blk_buf
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd                  ; ms_blk_buf = RF (payload)

            mov     rd, ms_blk_count
            ghi     rc
            str     rd
            inc     rd
            glo     rc
            str     rd                  ; ms_blk_count = RC (length)

            mov     rf, ms_blk_count
            ldn     rf                  ; D = count high byte
            call    ms_putbyte
            mov     rf, ms_blk_count
            inc     rf
            ldn     rf                  ; D = count low byte
            call    ms_putbyte

            call    ms_getbyte              ; length ack
            xri     $aa
            lbnz    msb_err

            ; --- send the payload bytes via ms_sendbytes ---
            mov     rf, ms_blk_buf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = payload buffer

            mov     rc, ms_blk_count
            lda     rc
            phi     r8
            ldn     rc
            plo     r8
            mov     rc, r8              ; RC = payload count
            dec     rc                  ; ms_sendbytes runs COUNT
                                        ; times when seeded with
                                        ; COUNT-1
            call    ms_sendbytes

            call    ms_getbyte              ; payload ack
            xri     $aa
            lbnz    msb_err

            clc
            rtn

msb_err:
            stc
            rtn

;------------------------------------------------------------------
; ms_send_end_marker: send a zero-length chunk (2-byte length=0) and
; wait for its ack -- used both for "no more data for THIS file" and,
; separately, for "no more files at all" (matches mr.asm's own
; symmetric design: the SAME zero-length exchange, distinguished only
; by which state the far end is in when it arrives).
; Returns: DF = 0 (ack received), DF = 1 (ack mismatch -- fatal)
; Modifies: everything
;------------------------------------------------------------------
ms_send_end_marker:
            ldi     0
            call    ms_putbyte
            ldi     0
            call    ms_putbyte

            call    ms_getbyte
            xri     $aa
            lbnz    msem_err

            clc
            rtn

msem_err:
            stc
            rtn

;------------------------------------------------------------------
; ms_handle_result: given ms_process_file's own D return value, update
; the running ok/err counters, or set ms_abort on a fatal result.
; Args:    D = MSF_OK / MSF_LOCAL_ERR / MSF_FATAL
; Modifies: everything
;------------------------------------------------------------------
ms_handle_result:
            plo     rc                  ; BUG-CLASS GUARD: stash D via
                                        ; PLO before "mov" clobbers it
            mov     rf, mhr_val
            glo     rc
            str     rf

            ldn     rf
            lbz     mhr_ok
            ldn     rf
            smi     MSF_FATAL
            lbz     mhr_fatal

            mov     rf, ms_err_count
            ldn     rf
            adi     1
            str     rf
            rtn

mhr_ok:
            mov     rf, ms_ok_count
            ldn     rf
            adi     1
            str     rf
            rtn

mhr_fatal:
            mov     rf, ms_abort
            ldi     1
            str     rf
            rtn

;------------------------------------------------------------------
; ms_basename: extract the basename (text after the last '/', or the
; whole string if none) of ms_cur_path into ms_basename_buf, bounded
; to MAXFER_NAME_MAX chars -- matches mr.asm's own identical cap on
; the receive side.
; Modifies: everything
;------------------------------------------------------------------
ms_basename:
            mov     rf, ms_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     r8, rd              ; R8 = scan pointer
            mov     r9, rd              ; R9 = basename start pointer

msbn_scan:
            ldn     r8
            lbz     msbn_scan_done
            xri     '/'
            lbnz    msbn_scan_next
            inc     r8
            mov     r9, r8
            lbr     msbn_scan
msbn_scan_next:
            inc     r8
            lbr     msbn_scan

msbn_scan_done:
            mov     rd, r9              ; RD = basename source pointer
            mov     rf, ms_basename_buf
            ldi     0
            plo     r7                  ; R7.0 = chars written

msbn_copy:
            ldn     rd
            lbz     msbn_copy_done

            glo     r7
            smi     MAXFER_NAME_MAX
            lbdf    msbn_copy_skip

            ldn     rd
            str     rf
            inc     rf
            glo     r7
            adi     1
            plo     r7

msbn_copy_skip:
            inc     rd
            lbr     msbn_copy

msbn_copy_done:
            ldi     0
            str     rf
            rtn

;------------------------------------------------------------------
; ms_print_count: print a 1-byte counter's decimal value via
; fmt_size32 + K_MSG.
; Args:    RF = pointer to the 1-byte counter
; Modifies: everything
;------------------------------------------------------------------
ms_print_count:
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = zero-extended count
            ldi     0
            phi     rd
            ldi     0
            plo     rd                  ; RD = 0 (high word)
            mov     rf, ms_numbuf
            call    fmt_size32
            mov     rf, ms_numbuf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; ms_getbyte / ms_putbyte: mode-aware single-byte read/write for
; every PROTOCOL byte in this session (handshake, header-field echo,
; acks) -- NOT used for the hot per-byte DATA loop (ms_sendbytes, a
; separate page-aligned proc with its own inline 3-way dispatch, for
; speed -- see its own header comment). Reads ms_io_mode (flat data,
; set once by start) fresh every call; see this file's own header
; comment for the full device-selection design.
;------------------------------------------------------------------
ms_getbyte:
            mov     rd, ms_io_mode
            ldn     rd
            xri     MS_IO_BITBANG
            lbz     mgb_bitbang

            ldn     rd
            xri     MS_IO_UART
            lbz     mgb_uart

            call    K_READ
            rtn

mgb_uart:
            call    f_uread
            rtn

mgb_bitbang:
            call    f_bread
            rtn

ms_putbyte:
            plo     rb                  ; stash the byte -- the mov
                                        ; below clobbers D (gotcha #4)
            mov     rd, ms_io_mode
            ldn     rd
            xri     MS_IO_BITBANG
            lbz     mpb_bitbang

            ldn     rd
            xri     MS_IO_UART
            lbz     mpb_uart

            glo     rb
            call    K_TYPE
            rtn

mpb_uart:
            glo     rb
            call    f_utype
            rtn

mpb_bitbang:
            glo     rb
            call    f_btype
            rtn

ms_ok_count:         db      0
ms_err_count:        db      0
ms_handshake_done:   db      0
ms_abort:            db      0
ms_i:                db      0
ms_cur_arg:          dw      0
ms_cur_path:         dw      0
ms_glob_found:       db      0
ms_glob_ctx:         ds      GLOB_CTX_LEN
ms_result:           db      0
mhr_val:             db      0
ms_blk_buf:          dw      0
ms_blk_count:        dw      0
ms_basename_buf:     ds      MAXFER_NAME_MAX+1
ms_hdr_buf:           ds     MAXFER_NAME_MAX+5
ms_numbuf:            ds     14
ms_stat_buf:          ds     DIRENT_LEN
ms_fcb:               ds     FCB_LEN
ms_iobuf:             ds     FCB_IOBUF_LEN
ms_databuf:           ds     XFER_BUF_LEN

            endp

;==================================================================
; ms_sendbytes: send one data block, byte by byte. Split out into its
; own proc (rather than living inline in ms_send_block above)
; specifically so it can carry its own ".link .align page" --
; ms_session's own page alignment (if it had any) would only guarantee
; a page-aligned proc *start*, and by the time control reaches this
; send loop, the handshake and the five-field header-echo exchange
; ahead of it have already pushed too far into the page for a single
; guarantee to still cover a hand-written short branch this deep --
; confirmed the hard way in the original single-file file (linking
; without this split hit Link/02's own out-of-page short-branch
; abort). A second, independent proc gets its own fresh page anchor.
; Three variants, selected once per call (not per byte) -- see this
; file's own header comment for the full device-selection design;
; ms_io_mode is read fresh here rather than trusted to have survived
; from ms_session (a genuinely different proc), matching how every
; other cross-call value in this file already lives in memory, never
; a register.
;
; Args:    RF = buffer, RC = count-1 (pre-decremented, matching the
;          caller's own established convention)
; Returns: nothing meaningful in D/DF
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            .link   .align  page
            proc    ms_sendbytes

            mov     rd, ms_io_mode
            ldn     rd
            xri     MS_IO_BITBANG
            lbz     sb_bitbang
            ldn     rd
            xri     MS_IO_UART
            lbz     sb_uart

sb_console:
            lda     rf
            call    K_TYPE

            dec     rc
            ghi     rc
            xri     $ff
            bnz     sb_console

            rtn

sb_uart:
            lda     rf
            call    f_utype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     sb_uart

            rtn

sb_bitbang:
            lda     rf
            call    f_btype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     sb_bitbang

            rtn

            endp

            end     start
