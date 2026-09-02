;
; mr.asm - receive one or more files over the serial port
;
; Usage: MR [-u|-b] [<destination>]
;   MR                receive every file the host sends (batch mode),
;                      writing each one under its own transmitted name
;                      into the current directory.
;   MR <directory>     same, but into <directory> instead of the
;                      current directory (checked once, up front, via
;                      K_STAT -- an existing directory selects batch
;                      mode, same pattern this project already uses
;                      for COPY/MOVE/XCOPY's own destination checks).
;   MR <filename>      single-file mode: <filename> does not already
;                      name a directory, so it's used verbatim as the
;                      destination for the FIRST file the host sends,
;                      ignoring that file's own transmitted name. If
;                      the host offers additional files in the same
;                      session (e.g. a batch send aimed at a single-
;                      file MR), they are drained -- read and
;                      discarded, never written anywhere -- so the
;                      session still ends cleanly instead of leaving
;                      the host stuck waiting for an ack that never
;                      comes.
;
; Companion to the host-side max-xfr tool, run as "max-xfr -s" to
; send. See mr_session's own header comment below for the exact wire
; protocol -- a batch-capable extension of ELF-DOS's original MAX-
; derived single-file protocol, adding a per-file header block (name +
; 32-bit size) ahead of each file's data, in the same spirit as
; YMODEM's own extension of XMODEM, but reusing the ORIGINAL block
; mechanism unchanged (same 5-byte echoed header, same un-echoed
; payload, same $AA ack) -- the header block is nothing more than an
; ordinary block whose payload both ends agree to interpret specially.
;
; DEVICE SELECTION (2026-09-01, restored and redesigned from the
; earlier 2026-08-27/09-01 "remove -u/-b entirely" pass -- see the
; retracted reasoning immediately below for why that pass wasn't the
; right call): now that K_TYPE/K_READ are self-modified jump-table
; slots (kernel/redir.asm) reaching whichever device is actually the
; CONSOLE, with no runtime redirect-check branch and no register cost
; over a direct BIOS call, the DEFAULT (no flag) is to use them --
; MR's own transfer then automatically follows whatever the console
; currently is, serial or otherwise. "-u"/"-b" are an explicit,
; deliberate OPT-OUT of that default: they route every byte of THIS
; transfer's own protocol (handshake, header echo, data, acks --
; everything, not just the hot data loop) directly to the hardware
; UART (-u, f_uread/f_utype) or the onboard bit-banged UART (-b,
; f_bread/f_btype), bypassing K_READ/K_TYPE's own vector entirely,
; regardless of what the console is currently routed to. The user's
; own motivation: this lets a transfer run on a DIFFERENT physical
; port than the one being used as the interactive console (e.g. watch
; debug/log output on the console while a transfer runs on the other
; UART, or drive a transfer from outside a terminal emulator entirely
; for easier traffic capture) -- something a console-only design can
; never do, and something the retracted "-u/-b is pointless now"
; reasoning below didn't account for (it only weighed the THROUGHPUT
; argument for bypassing K_READ/K_TYPE, which the self-modified vector
; genuinely does moot -- not this independent, still-real reason to
; target a specific port). mr_getbyte/mr_putbyte (mr_session's own
; local subroutines, below) are the mode-aware dispatch point for
; every PROTOCOL byte; the hot per-byte DATA loop (mr_readbytes) gets
; its own separate, page-aligned, hand-short-branched 3-way dispatch
; for speed, mirroring lib/ymodem.asm's own ym_getbyte/ym_putbyte vs.
; ym_recv_block split exactly -- see mr_readbytes's own header comment.
;
; RETRACTED reasoning, kept for history: the 2026-08-27 self-modifying-
; vector work genuinely did eliminate the THROUGHPUT/register-cost
; argument for "-u"/"-b" (a "call K_READ" now costs one extra 3-byte
; LBR over calling the BIOS routine directly, with identical register
; behavior, since an LBR touches no registers) -- but eliminating that
; ONE argument doesn't mean the flags served no purpose at all; the
; port-independence argument above was never considered until the user
; asked for these flags back with a clarified design (default =
; console-routed, explicit flag = a specific port regardless of the
; console).
;
; The register-liveness caution this file has carried since 2026-07-11
; is UNCHANGED and still governs every call site below: nothing is
; trusted to survive more than one call to mr_getbyte/mr_putbyte (or,
; equivalently, K_READ/K_TYPE directly, in CONSOLE mode) in a
; register -- every value that must survive a call lives in memory
; instead (mr_cnt_hi/mr_cnt_lo and friends), reloaded fresh
; immediately before use. The ONE loop that trusts a register (RC/RF)
; across many repeated per-byte calls -- mr_readbytes, the hot
; transfer loop -- is exactly the same register/call shape this
; project has relied on since mr.asm's very first version (calling
; f_uread/f_bread directly), now just also available through K_READ's
; own self-modified vector in the default (console) case.
;
; mr_session is a real proc/endp block (extrn'd from start, ordinary
; same-file cross-proc convention -- a proc's own entry name needs no
; separate "public" declaration, only DATA labels referenced across a
; proc boundary do) rather than inline in start, purely for size/
; organization -- unlike the old mr_receive, it has no hand-written
; short branches of its own and so needs no page alignment.
; mr_readbytes (the hot per-byte loop) is a SEPARATE, page-aligned
; proc, exactly matching ms.asm's own ms_send/ms_sendbytes split: the
; header/batch-management code ahead of it in mr_session pushes well
; past what a single page-aligned mr_session could still guarantee for
; a hand-written short branch this deep into the file.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   mr_session
            extrn   mr_readbytes
            extrn   fmt_size32

; MAXFER_NAME_MAX: matches DIRENT_NAME's own 127-char cap (kernel_api.inc)
; -- a header block's name field is never expected to exceed this from
; our own ms.asm, but mr_parse_header (mr_session's own local routine)
; still bounds its copy against it defensively.
MAXFER_NAME_MAX:    equ     127

MR_PATH_BUF_LEN:    equ     260     ; a destination-directory argument
                                    ; (up to a whole LINE_BUF-bounded
                                    ; argv token) + '/' + a
                                    ; MAXFER_NAME_MAX name + NUL, with
                                    ; real headroom

; mr_io_mode (start, below): which device every byte of this
; transfer's own protocol goes over -- see this file's own header
; comment for the full design. CONSOLE (0) is the default -- matches
; ordinary K_READ/K_TYPE behavior, automatically following whatever
; the console currently is.
MR_IO_CONSOLE:      equ     0       ; via K_READ/K_TYPE (default)
MR_IO_UART:         equ     1       ; via f_uread/f_utype directly
MR_IO_BITBANG:      equ     2       ; via f_bread/f_btype directly

; mr_session result codes (returned in D; 0 = success)
MRERR_HANDSHAKE:    equ     1       ; sync byte never arrived/matched
MRERR_COMMAND:      equ     2       ; unrecognized per-block command
                                    ; byte, or the final 'x' didn't
                                    ; arrive/match
MRERR_WRITE:        equ     3       ; K_FILE_WRITE failed -- fatal to
                                    ; the whole session (unlike a
                                    ; single file's own open failure,
                                    ; which is recoverable -- see
                                    ; mr_session's own header for why)

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
            ; established "flags precede everything else" convention)
            ; selecting which physical port every byte of this
            ; transfer's own protocol goes over -- see this file's own
            ; header comment. Whatever remains after an optional flag
            ; is the optional destination (a directory for batch mode,
            ; or an exact filename for single mode -- decided below
            ; via K_STAT). At most one flag and one destination, so
            ; argc can be at most 3.
            glo     rc
            smi     4
            lbdf    usage               ; argc >= 4: too many args

            mov     rf, mr_io_mode
            ldi     MR_IO_CONSOLE       ; default
            str     rf

            glo     rc
            smi     1
            lbz     start_no_dest       ; argc == 1: nothing to parse

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    start_have_dest_at_1

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
            lbnz    start_have_dest_at_1  ; not exactly 2 chars after
                                        ; '-': fall back to treating
                                        ; the whole token as a
                                        ; destination instead of
                                        ; guessing/erroring

            glo     r8
            xri     'u'
            lbz     start_flag_uart
            glo     r8
            xri     'b'
            lbz     start_flag_bitbang
            lbr     start_have_dest_at_1   ; unrecognized letter: same
                                        ; fallback

start_flag_uart:
            mov     rf, mr_io_mode
            ldi     MR_IO_UART
            str     rf
            lbr     start_after_flag

start_flag_bitbang:
            mov     rf, mr_io_mode
            ldi     MR_IO_BITBANG
            str     rf

start_after_flag:
            glo     rc
            smi     2
            lbz     start_no_dest       ; argc == 2: flag only, no
                                        ; destination

            ; argc must be 3 here (argc >= 4 was already rejected
            ; above): the destination is argv[2]
            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2]
            lbr     start_have_dest_ptr

start_have_dest_at_1:
            ; RD already holds argv[1]'s own pointer (untouched by the
            ; flag-character checks above) -- no flag was given, so
            ; this must be the ONLY argument
            glo     rc
            smi     2
            lbnz    usage

start_have_dest_ptr:
            mov     rf, mr_dest_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; mr_dest_arg = the destination

            ; is it an existing directory? K_STAT + ATTR_DIR, same
            ; pattern this project already uses elsewhere (e.g.
            ; XCOPY/MOVE's own destination-directory checks)
            mov     rf, rd
            mov     rd, mr_stat_buf
            call    K_STAT              ; DF = 0/1
            lbdf    start_mode_single   ; doesn't exist yet: single-
                                        ; file mode, this exact name

            mov     rf, mr_stat_buf
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     start_mode_single   ; exists, but is a file

            mov     rf, mr_mode
            ldi     1                   ; batch mode, into this dir
            str     rf
            lbr     start_run

start_mode_single:
            mov     rf, mr_mode
            ldi     2                   ; single-file mode
            str     rf
            lbr     start_run

start_no_dest:
            mov     rf, mr_mode
            ldi     0                   ; batch mode, into cwd
            str     rf

start_run:
            call    mr_session          ; prints its own per-file
                                        ; progress and a final summary;
                                        ; D = 0 if the whole run was
                                        ; fully clean (protocol AND
                                        ; every individual file),
                                        ; nonzero otherwise -- DF=0/1
                                        ; matches D
            ; BUG-CLASS GUARD: stash the result before anything below
            ; (a "mov") clobbers D.
            plo     r8                  ; R8.0 = mr_session's result

            glo     r8
            lbz     start_success

            glo     r8
            smi     MRERR_HANDSHAKE
            lbnz    start_exit_err      ; a real error was already
                                        ; fully reported by mr_session
                                        ; itself (a printed summary, or
                                        ; a mid-session abort message)

            call    K_INMSG
            db      "No response from host.",13,10,0

start_exit_err:
            ldi     1
            rtn

start_success:
            ldi     0
            rtn

usage:
            call    K_INMSG
            db      "Usage: MR [-u|-b] [<destination>]",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

mr_dest_arg:    dw      0
mr_stat_buf:    ds      DIRENT_LEN
mr_mode:        db      0
mr_io_mode:     db      0

;==================================================================
; mr_session: receive a batch of one or more files over the console/
; serial port, using ELF-DOS's own MAX-derived batch transfer
; protocol.
;
; Protocol (matches max-xfr's "-s" / send mode):
;   1. Host sends $55 (sync). We ACK with $AA.
;   2. For each file the host has to send:
;      a. HEADER BLOCK, sent via the ordinary block mechanism below:
;         host sends $01 (echoed), a 2-byte big-endian byte count and
;         a 2-byte address field (each echoed as read -- the address
;         field is unused, kept only for wire compatibility with the
;         underlying raw memory-load format this protocol is derived
;         from), then that many un-echoed payload bytes: the file's
;         name (null-terminated) followed by its 32-bit size, big-
;         endian binary (not YMODEM's ASCII-octal convention). We ACK
;         with $AA once the whole block has been received.
;      b. DATA BLOCKS: the same block mechanism, one or more times,
;         carrying the file's actual content.
;      c. End of this file's data: host sends $00 (NOT echoed, exactly
;         like the end-of-block-stream marker in the original single-
;         file protocol). We do NOT expect a trailing 'x' here --
;         that only happens once, at the very end of the whole
;         session (step 3) -- we simply go back to expecting the NEXT
;         file's own header block (step 2a), or the batch terminator
;         (step 3) if there isn't one.
;   3. Once the host has no more files, it sends $00 in the SAME
;      "expecting a header block" state that starts every file --
;      there's no separate empty-name sentinel needed, the state a
;      $00 arrives in is what distinguishes "end of this file's data"
;      (mid-file) from "end of the whole batch" (between files). We
;      then read the host's final 'x' and finish, exactly like the
;      original single-file protocol's own end sequence.
;
; A file's own open failure (bad name from a malformed header, the
; destination directory vanished, disk full, ...) is NOT fatal to the
; session -- that file's data is drained (read and discarded, to stay
; in lock-step with the host) and the batch continues, matching this
; project's established "note the error, keep going" convention for
; DEL/COPY/TOUCH's own multi-argument loops. A genuine PROTOCOL error
; (an unrecognized command byte, a write failure, the trailing 'x'
; missing) IS fatal to the whole session -- the two ends have no way
; to resynchronize once the block-level lock-step is broken.
;
; Prints its own per-file progress line and a final summary
; ("N file(s) received.", plus "M file(s) failed."/"K file(s)
; ignored." when nonzero) before returning, so the caller (start)
; only needs to react to D/DF for its own exit code.
;
; Args:    none
; Returns: D  = 0 if every file was received cleanly and the whole
;          session completed without a protocol error, nonzero
;          otherwise (MRERR_HANDSHAKE if nothing was ever received at
;          all -- the only case with NO summary printed, since there's
;          nothing to summarize -- MRERR_COMMAND/MRERR_WRITE for a
;          mid-session protocol failure, or a nonzero code even though
;          the protocol itself finished cleanly if any individual
;          file's own open failed)
;          DF = 0 on success, DF = 1 on failure (redundant with D,
;          kept for consistency with this project's other calls)
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            proc    mr_session

            mov     rf, mr_ok_count
            ldi     0
            str     rf
            mov     rf, mr_err_count
            ldi     0
            str     rf
            mov     rf, mr_skip_count
            ldi     0
            str     rf
            mov     rf, mr_single_used
            ldi     0
            str     rf
            mov     rf, mr_extra_noted
            ldi     0
            str     rf

;------------------------------------------------------------------
; Handshake: wait for $55 (sync), ACK with $AA.
;------------------------------------------------------------------
            call    mr_getbyte
            xri     $55
            lbz     mrs_shake

            ldi     MRERR_HANDSHAKE
            stc
            rtn                         ; nothing was ever received --
                                        ; start prints its own "No
                                        ; response from host."

mrs_shake:  ldi     $aa
            call    mr_putbyte

;------------------------------------------------------------------
; Outer loop: one iteration per file.
;------------------------------------------------------------------
mrs_outer:
            call    mr_recv_block       ; D = 0 (end marker) / 1
                                        ; (block ready, mr_buf/
                                        ; mr_blk_count filled) / 2
                                        ; (fatal: bad command byte)
            ; BUG-CLASS GUARD: stash D via a register PLO (which
            ; doesn't touch D) before "mov rf, ..." clobbers it.
            plo     rc
            mov     rf, mrb_result
            glo     rc
            str     rf

            ldn     rf
            lbz     mrs_batch_end

            ldn     rf
            smi     2
            lbz     mrs_fatal_command

            ; --- have a HEADER block ---
            call    mr_parse_header     ; DF ignored here -- even a
                                        ; malformed header (DF=1) still
                                        ; leaves a printable
                                        ; placeholder name and a zeroed
                                        ; size, so the rest of this
                                        ; file's handling is identical
                                        ; either way

            mov     rf, mr_mode
            ldn     rf
            lbz     mrs_mode0
            mov     rf, mr_mode
            ldn     rf
            smi     1
            lbz     mrs_mode1
            lbr     mrs_mode2

mrs_mode0:
            ; bare name -- resolves relative to the current directory
            ; on its own, no composition needed
            mov     rf, mr_destpath
            mov     rd, mr_hdrname
mrs_m0_copy:
            lda     rd
            str     rf
            lbz     mrs_have_dest
            inc     rf
            lbr     mrs_m0_copy

mrs_mode1:
            call    mr_build_dirpath    ; mr_destpath = mr_dest_arg +
                                        ; '/' + mr_hdrname
            lbr     mrs_have_dest

mrs_mode2:
            mov     rf, mr_single_used
            ldn     rf
            lbnz    mrs_mode2_extra

            mov     rf, mr_single_used
            ldi     1
            str     rf

            mov     rf, mr_destpath
            mov     rd, mr_dest_arg
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8              ; RD = mr_dest_arg's string
mrs_m2_copy:
            lda     rd
            str     rf
            lbz     mrs_have_dest
            inc     rf
            lbr     mrs_m2_copy

mrs_mode2_extra:
            mov     rf, mr_discard_flag
            ldi     1
            str     rf
            mov     rf, mr_skip_count
            ldn     rf
            adi     1
            str     rf

            mov     rf, mr_extra_noted
            ldn     rf
            lbnz    mrs_inner_start
            mov     rf, mr_extra_noted
            ldi     1
            str     rf
            call    K_INMSG
            db      "Ignoring additional file(s) sent by host (single-file mode).",13,10,0
            lbr     mrs_inner_start

mrs_have_dest:
            mov     rf, mr_discard_flag
            ldi     0
            str     rf

            mov     rf, mr_destpath
            mov     rd, mr_fcb
            mov     ra, mr_iobuf
            ldi     1                   ; mode = write (create/truncate)
            call    K_FILE_OPEN         ; DF = 0/1
            lbnf    mrs_open_ok

            mov     rf, mr_discard_flag
            ldi     1
            str     rf
            call    K_INMSG
            db      "Cannot create ",0
            mov     rf, mr_destpath
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            mov     rf, mr_err_count
            ldn     rf
            adi     1
            str     rf
            lbr     mrs_inner_start

mrs_open_ok:
            call    K_INMSG
            db      "Receiving ",0
            mov     rf, mr_destpath
            call    K_MSG
            call    K_INMSG
            db      " (",0
            mov     rf, mr_hdrsize
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = 32-bit size
            mov     rf, mr_numbuf
            call    fmt_size32
            mov     rf, mr_numbuf
            call    K_MSG
            call    K_INMSG
            db      " bytes)...",13,10,0

mrs_inner_start:
;------------------------------------------------------------------
; Inner loop: one iteration per DATA block of the current file.
;------------------------------------------------------------------
mrs_inner:
            call    mr_recv_block
            ; BUG-CLASS GUARD: same as mrs_outer above.
            plo     rc
            mov     rf, mrb_result
            glo     rc
            str     rf

            ldn     rf
            lbz     mrs_file_end

            ldn     rf
            smi     2
            lbz     mrs_fatal_command_close

            ; --- have a DATA block ---
            mov     rf, mr_discard_flag
            ldn     rf
            lbnz    mrs_inner           ; discarding: don't write

            mov     rf, mr_buf
            mov     r8, mr_blk_count
            lda     r8
            phi     rc
            ldn     r8
            plo     rc                  ; RC = full block byte count
            mov     rd, mr_fcb
            call    K_FILE_WRITE        ; DF = 0/1
            lbnf    mrs_inner

            mov     rd, mr_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     MRERR_WRITE
            lbr     mrs_summarize

mrs_file_end:
            mov     rf, mr_discard_flag
            ldn     rf
            lbnz    mrs_outer           ; discarding: nothing to close

            mov     rd, mr_fcb
            call    K_FILE_CLOSE
            mov     rf, mr_ok_count
            ldn     rf
            adi     1
            str     rf
            lbr     mrs_outer

mrs_fatal_command_close:
            mov     rf, mr_discard_flag
            ldn     rf
            lbnz    mrs_fcc_noclose
            mov     rd, mr_fcb
            call    K_FILE_CLOSE
mrs_fcc_noclose:
            ldi     MRERR_COMMAND
            lbr     mrs_summarize

mrs_fatal_command:
            ldi     MRERR_COMMAND
            lbr     mrs_summarize

mrs_batch_end:
            call    mr_getbyte
            xri     'x'
            lbz     mrs_clean

            ldi     MRERR_COMMAND
            lbr     mrs_summarize

mrs_clean:
            ldi     0

;------------------------------------------------------------------
; mrs_summarize: D already holds the session's own result code (0 or
; an MRERR_* value). Stash it (a register can't survive fmt_size32's
; own "Modifies: everything" -- see lib/fmt32.asm's own header), print
; the ok/err/skip counts, then reload it for the real return.
;------------------------------------------------------------------
mrs_summarize:
            ; BUG-CLASS GUARD: same as mrs_outer above.
            plo     rc
            mov     rf, mrs_result
            glo     rc
            str     rf

            mov     rf, mr_ok_count
            call    mr_print_count
            call    K_INMSG
            db      " file(s) received.",13,10,0

            mov     rf, mr_err_count
            ldn     rf
            lbz     mrs_sum_skip_err
            mov     rf, mr_err_count
            call    mr_print_count
            call    K_INMSG
            db      " file(s) failed.",13,10,0
mrs_sum_skip_err:

            mov     rf, mr_skip_count
            ldn     rf
            lbz     mrs_sum_skip_skip
            mov     rf, mr_skip_count
            call    mr_print_count
            call    K_INMSG
            db      " file(s) ignored.",13,10,0
mrs_sum_skip_skip:

            mov     rf, mrs_result
            ldn     rf
            lbz     mrs_summarize_ok
            stc
            rtn
mrs_summarize_ok:
            clc
            rtn

;------------------------------------------------------------------
; mr_recv_block: read one block's leading command byte and, if it's
; $01, the rest of that block's 5-byte header (count hi/lo, address
; hi/lo -- unused, kept only for wire compatibility) plus its payload,
; via mr_readbytes. Every header field is individually echoed back to
; the sender as it's read, matching the sender's own per-field
; verification. Ordinary intra-proc subroutine (no page alignment
; needed -- no hand-written short branches here).
;
; Returns: D = 0 (command byte was $00 -- not echoed, matches the
;          sender's own convention of not expecting an echo for a
;          terminal marker at any level), 1 (a real block was
;          received: mr_buf holds its payload, mr_blk_count its
;          length), 2 (fatal: the command byte was neither $00 nor
;          $01)
; Modifies: everything
;------------------------------------------------------------------
mr_recv_block:
            call    mr_getbyte
            lbz     mrb_zero

            ; BUG-CLASS GUARD: stash the command byte in memory before
            ; the "mov" below clobbers D.
            plo     rc
            mov     rf, mr_cmdbyte
            glo     rc
            str     rf

            ldn     rf
            call    mr_putbyte              ; echo it

            mov     rf, mr_cmdbyte
            ldn     rf
            smi     1
            lbz     mrb_cmd01

            ldi     2
            rtn

mrb_zero:
            ldi     0
            rtn

mrb_cmd01:
            call    mr_getbyte
            plo     rc
            mov     rf, mr_cnt_hi
            glo     rc
            str     rf
            call    mr_putbyte

            call    mr_getbyte
            plo     rc
            mov     rf, mr_cnt_lo
            glo     rc
            str     rf
            call    mr_putbyte

            call    mr_getbyte              ; address hi (unused)
            call    mr_putbyte

            call    mr_getbyte              ; address lo (unused)
            call    mr_putbyte

            ; reconstruct count from memory (bug-class guard, same as
            ; the original single-file protocol's own mr_cmd01) and
            ; stash it as mr_blk_count for the caller
            mov     rf, mr_cnt_hi
            ldn     rf
            phi     rc
            mov     rf, mr_cnt_lo
            ldn     rf
            plo     rc

            mov     rf, mr_blk_count
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            ; defensive: a genuinely 0-length block can't come from
            ; either of this project's own senders (a header is always
            ; >= 5 bytes, a data block is only ever sent for a nonzero
            ; chunk), but "dec rc" on RC==0 would wrap to $FFFF and
            ; hand mr_readbytes a 65536-iteration loop -- cheap enough
            ; to guard against outright rather than trust that
            ; assumption forever
            ghi     rc
            lbnz    mrb_have_bytes
            glo     rc
            lbz     mrb_ack

mrb_have_bytes:
            mov     rf, mr_buf
            dec     rc                  ; mr_readbytes runs COUNT
                                        ; times when seeded with
                                        ; COUNT-1
            call    mr_readbytes

mrb_ack:
            ldi     $aa
            call    mr_putbyte

            ldi     1
            rtn

;------------------------------------------------------------------
; mr_parse_header: interpret mr_buf[0..mr_blk_count-1] as a header
; block (name, NUL, 4-byte big-endian size) sent ahead of a new file's
; data. Assumes mr_blk_count's own HIGH byte is 0 -- true for any
; well-formed header from this project's own ms.asm (MAXFER_NAME_MAX
; keeps every real header well under 256 bytes); a genuinely malformed
; session (garbage on the wire) is still caught below via the "ran out
; of bytes without finding a NUL" check, which needs no assumption
; about the high byte at all.
;
; Returns: DF = 0 (mr_hdrname filled, NUL-terminated, silently
;          truncated to MAXFER_NAME_MAX chars if the source ran
;          long -- the scan itself still consumes every real byte, to
;          stay in sync; mr_hdrsize filled with the 4 size bytes if
;          they were present, else zeroed), DF = 1 (no NUL was found
;          anywhere in the block -- mr_hdrname is left holding a "?"
;          placeholder, mr_hdrsize zeroed, so the caller still has
;          something sensible to print/use as a destination name)
; Modifies: everything
;------------------------------------------------------------------
mr_parse_header:
            mov     rf, mr_buf          ; RF = scan pointer
            mov     rd, mr_hdrname      ; RD = name write pointer
            ldi     0
            plo     r7                  ; R7.0 = chars written so far
            mov     r8, mr_blk_count
            inc     r8
            ldn     r8
            plo     r9                  ; R9.0 = remaining byte count

mph_scan:
            glo     r9
            lbz     mph_malformed

            lda     rf                  ; D = next raw byte, RF++
            lbz     mph_found_nul

            plo     ra                  ; RA.0 = the byte value
                                        ; (stashed across the cap
                                        ; check below)
            glo     r7
            smi     MAXFER_NAME_MAX
            lbdf    mph_scan_skip       ; already at the cap: keep
                                        ; scanning, but don't write

            glo     ra
            str     rd
            inc     rd
            glo     r7
            adi     1
            plo     r7

mph_scan_skip:
            glo     r9
            smi     1
            plo     r9
            lbr     mph_scan

mph_found_nul:
            ldi     0
            str     rd                  ; NUL-terminate mr_hdrname

            glo     r9
            smi     1                   ; consumed the NUL itself
            plo     r9

            glo     r9
            smi     4
            lbnf    mph_no_size         ; fewer than 4 bytes left

            mov     rd, mr_hdrsize
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            clc
            rtn

mph_no_size:
            mov     rd, mr_hdrsize
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            clc
            rtn

mph_malformed:
            mov     rd, mr_hdrname
            ldi     '?'
            str     rd
            inc     rd
            ldi     0
            str     rd
            mov     rd, mr_hdrsize
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            inc     rd
            ldi     0
            str     rd
            stc
            rtn

;------------------------------------------------------------------
; mr_build_dirpath: mr_destpath = mr_dest_arg + '/' (if not already
; present) + mr_hdrname (already parsed and NUL-terminated). Same
; directory-join pattern this project already uses elsewhere (e.g.
; COPY's own destination-directory composition).
; Modifies: everything
;------------------------------------------------------------------
mr_build_dirpath:
            mov     rf, mr_destpath
            mov     rd, mr_dest_arg
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8              ; RD = mr_dest_arg's string

mbd_copy_dir:
            lda     rd
            lbz     mbd_dir_done
            str     rf
            inc     rf
            lbr     mbd_copy_dir

mbd_dir_done:
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     mbd_have_sep
            ldi     '/'
            str     rf
            inc     rf

mbd_have_sep:
            mov     rd, mr_hdrname
mbd_append_name:
            lda     rd
            str     rf
            lbz     mbd_done
            inc     rf
            lbr     mbd_append_name

mbd_done:
            rtn

;------------------------------------------------------------------
; mr_print_count: print a 1-byte counter's decimal value via
; fmt_size32 + K_MSG.
; Args:    RF = pointer to the 1-byte counter
; Modifies: everything
;------------------------------------------------------------------
mr_print_count:
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = zero-extended count
            ldi     0
            phi     rd
            ldi     0
            plo     rd                  ; RD = 0 (high word)
            mov     rf, mr_numbuf
            call    fmt_size32
            mov     rf, mr_numbuf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; mr_getbyte / mr_putbyte: mode-aware single-byte read/write for
; every PROTOCOL byte in this session (handshake, header-field echo,
; acks, the trailing 'x') -- NOT used for the hot per-byte DATA loop
; (mr_readbytes, a separate page-aligned proc with its own inline
; 3-way dispatch, for speed -- see its own header comment). Reads
; mr_io_mode (flat data, set once by start) fresh every call; see
; this file's own header comment for the full device-selection design.
;------------------------------------------------------------------
mr_getbyte:
            mov     rd, mr_io_mode
            ldn     rd
            xri     MR_IO_BITBANG
            lbz     mgb_bitbang

            ldn     rd
            xri     MR_IO_UART
            lbz     mgb_uart

            call    K_READ
            rtn

mgb_uart:
            call    f_uread
            rtn

mgb_bitbang:
            call    f_bread
            rtn

mr_putbyte:
            plo     rb                  ; stash the byte -- the mov
                                        ; below clobbers D (gotcha #4)
            mov     rd, mr_io_mode
            ldn     rd
            xri     MR_IO_BITBANG
            lbz     mpb_bitbang

            ldn     rd
            xri     MR_IO_UART
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

mr_ok_count:        db      0
mr_err_count:       db      0
mr_skip_count:      db      0
mr_single_used:     db      0
mr_extra_noted:     db      0
mr_discard_flag:    db      0
mrb_result:         db      0
mrs_result:         db      0
mr_cmdbyte:         db      0
mr_cnt_hi:          db      0
mr_cnt_lo:          db      0
mr_blk_count:       dw      0
mr_hdrname:         ds      MAXFER_NAME_MAX+1
mr_hdrsize:         ds      4
mr_destpath:        ds      MR_PATH_BUF_LEN
mr_numbuf:          ds      14
mr_fcb:             ds      FCB_LEN
mr_iobuf:           ds      FCB_IOBUF_LEN
mr_buf:             ds      512

            endp

;==================================================================
; mr_readbytes: the one loop in this whole file that has to be fast --
; runs once per incoming byte with no per-byte handshake from the host
; (only the block-level $AA ack throttles it), so at the top end of
; whichever transport is in use every extra instruction here is real
; risk of an overrun and a dropped byte. A genuine hand-written short
; branch for each loop-back, not an lbnz left for -r to shrink after
; the fact -- safe specifically because of the .link .align page
; below, which guarantees this whole (well under 256 bytes) proc lands
; on a page boundary, so every short branch is always within range of
; its own target regardless of where this proc ends up in the final
; program. Three variants, selected once per call (not per byte) --
; see this file's own header comment for the full device-selection
; design: mr_io_mode is read fresh here rather than trusted to have
; survived from mr_session (a genuinely different proc), matching how
; every other cross-call value in this file already lives in memory,
; never a register.
;
; Args:    RF = buffer, RC = count-1 (pre-decremented, matching the
;          caller's own established convention)
; Returns: nothing meaningful in D/DF
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            .link   .align  page
            proc    mr_readbytes

            mov     rd, mr_io_mode
            ldn     rd
            xri     MR_IO_BITBANG
            lbz     mrb_bitbang
            ldn     rd
            xri     MR_IO_UART
            lbz     mrb_uart

mrb_console:
            call    K_READ
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     mrb_console

            rtn

mrb_uart:
            call    f_uread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     mrb_uart

            rtn

mrb_bitbang:
            call    f_bread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     mrb_bitbang

            rtn

            endp

            end     start
