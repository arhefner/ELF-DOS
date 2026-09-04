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
; NO MID-SESSION CONSOLE OUTPUT (2026-09-04, found via a real hardware
; hang): mr_session prints NOTHING between the handshake and the final
; summary -- no per-file "Receiving..." line, no "Cannot create ..."
; error, no "Ignoring additional file(s)..." notice. This looks like a
; regression from earlier versions of this file, but it's deliberate:
; in the DEFAULT (console) mode, K_INMSG/K_MSG route through the exact
; same physical channel mr_getbyte/mr_putbyte use for the transfer
; itself (K_TYPE/K_READ's self-modified vector) -- there is no ELF-DOS
; equivalent of a separate stderr stream the way max-xfr.c has on the
; host side. Printing "Receiving ihex.c (3,178 bytes)..." mid-transfer
; means the far end's next blocking read -- expecting a real $AA ack --
; instead reads 'R' (0x52), exactly the failure this project hit
; running MR through minicom's own external-protocol launcher (which
; necessarily shares minicom's own already-open serial connection):
; the host reported "Error waiting for payload ack (ack = 52)", aborted,
; and MR then hung forever waiting for bytes the host would never send
; again. This isn't specific to minicom or to any one mode (-u/-b would
; hit the identical problem whenever their target happens to be the
; same physical wire as the console, which there is no reliable way for
; a userland program to detect) -- so nothing prints until mrs_summarize,
; reached only once the whole session's own wire protocol has fully
; finished (the trailing 'x' already read). The aggregate ok/err/skip
; counts still survive to that point and print there; only the per-file
; name/size detail and the specific "Cannot create.../Ignoring..."
; messages are lost, in exchange for genuinely never being able to
; corrupt an in-progress transfer.
;
; Companion to the host-side max-xfr tool, run as "max-xfr -s" to
; send. See mr_session's own header comment below for the exact wire
; protocol -- a length-prefixed, doubly-acknowledged chunk protocol
; (2026-09-04 redesign, replacing the earlier command-byte/address-
; field framing entirely): every chunk the sender writes is preceded
; by its own 2-byte length and followed by waiting for an explicit
; ack, and -- critically -- that ack is sent only once the receiver
; has FINISHED its own processing of the chunk (a disk write, or
; opening the destination file), not merely once the bytes are off
; the wire. This closes a real hardware bug found the same day: the
; OLD protocol's un-echoed, un-acknowledged end-of-file/end-of-batch
; marker bytes were being silently dropped on a receiver with no
; hardware UART FIFO, since nothing throttled the sender from writing
; them back-to-back right after the receiver's slowest step (a real
; disk write for the file's last data block). Every OTHER byte in the
; old protocol was already naturally throttled (echo-verified header
; fields, or a per-byte "-d" delay for payload) -- this redesign
; extends that same "the sender never gets ahead of the receiver"
; guarantee to cover the whole protocol uniformly, with no exceptions
; left, instead of just tuning a delay to paper over the one gap.
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
; transfer's own protocol (handshake, chunk length/ack, data, the
; trailing 'x' -- everything, not just the hot data loop) directly to
; the hardware UART (-u, f_uread/f_utype) or the onboard bit-banged
; UART (-b, f_bread/f_btype), bypassing K_READ/K_TYPE's own vector
; entirely, regardless of what the console is currently routed to.
; The user's own motivation: this lets a transfer run on a DIFFERENT
; physical port than the one being used as the interactive console
; (e.g. watch debug/log output on the console while a transfer runs on
; the other UART, or drive a transfer from outside a terminal emulator
; entirely for easier traffic capture) -- something a console-only
; design can never do, and something the retracted "-u/-b is
; pointless now" reasoning below didn't account for (it only weighed
; the THROUGHPUT argument for bypassing K_READ/K_TYPE, which the
; self-modified vector genuinely does moot -- not this independent,
; still-real reason to target a specific port). mr_getbyte/mr_putbyte
; (mr_session's own local subroutines, below) are the mode-aware
; dispatch point for every PROTOCOL byte; the hot per-byte DATA loop
; (mr_readbytes) gets its own separate, page-aligned, hand-short-
; branched 3-way dispatch for speed, mirroring lib/ymodem.asm's own
; ym_getbyte/ym_putbyte vs. ym_recv_block split exactly -- see
; mr_readbytes's own header comment.
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
; -- a header chunk's name field is never expected to exceed this from
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
MRERR_COMMAND:      equ     2       ; a chunk's own length was too
                                    ; large to fit our buffer (a
                                    ; genuinely malformed/desynced
                                    ; session), or the final 'x'
                                    ; didn't arrive/match
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
; serial port, using ELF-DOS's own length-prefixed, doubly-
; acknowledged chunk protocol (matches max-xfr's "-s" / send mode).
;
; Protocol:
;   1. Host sends $55 (sync). We ACK with $AA.
;   2. Every further exchange is a CHUNK: the host writes a 2-byte
;      big-endian LENGTH. If LENGTH is nonzero, we ACK it immediately
;      with $AA (this ack means only "length received," not "chunk
;      fully processed"), the host then writes that many un-echoed
;      payload bytes (paced by its own "-d" delay), and we send a
;      SECOND $AA -- but only once we've actually finished doing
;      something with that payload (see below), not just once the
;      bytes are off the wire. If LENGTH is 0, the chunk is over right
;      there -- no payload follows -- but we do NOT ack it immediately:
;      the ack is deferred until whatever processing a zero-length
;      chunk implies on our end (closing the file we were just writing
;      to, most of the time) has actually finished. Both deferrals
;      exist for the identical reason: they're what makes the whole
;      protocol self-throttling -- the host can never get more than
;      one length-field ahead of what we've actually finished
;      processing, on hardware with no UART FIFO to absorb it if it
;      does. This closes two real hardware bugs, found on two
;      different days: the original protocol's un-acknowledged end-of-
;      file/end-of-batch markers being silently dropped (2026-09-04,
;      fixed by this whole chunk redesign), and then a second,
;      narrower miss found the same day in the redesign's own first
;      draft -- the zero-length chunk's ack was being sent
;      unconditionally, immediately upon reading the length, which is
;      safe on its own but let the host race ahead and write the NEXT
;      thing (another file's header, or the outer batch-end marker)
;      while we were still busy closing the current file, exactly
;      recreating the class of bug the redesign exists to close, just
;      one step later. Fixed by moving the zero-length chunk's ack out
;      of mr_recv_block entirely and into whichever caller actually
;      knows when its own processing is done (mrs_file_end,
;      mrs_batch_end).
;   3. A simple two-state machine, driven purely by "was this chunk's
;      length zero":
;        expecting a HEADER: a nonzero-length chunk's payload is the
;        file's name (null-terminated) followed by its 32-bit size,
;        big-endian binary -- open (or discard) the destination, ack
;        once that's decided, and switch to expecting DATA. A zero-
;        length chunk here means the whole batch is over -- ack it
;        (nothing more to do before the final 'x' below), then proceed
;        to step 4.
;        expecting DATA: a nonzero-length chunk's payload is the
;        file's actual content -- write it (or discard it), ack once
;        the write has actually completed, and stay in this state. A
;        zero-length chunk here means this file's data is done --
;        close it (or, if discarding, there's nothing to close), ack,
;        then switch back to expecting a HEADER.
;   4. Once the batch-ending zero-length header chunk has been ack'd,
;      read the host's final 'x' and finish, exactly like the
;      original single-file protocol's own end sequence.
;
; A file's own open failure (bad name from a malformed header, the
; destination directory vanished, disk full, ...) is NOT fatal to the
; session -- that file's data is drained (read and discarded, to stay
; in lock-step with the host) and the batch continues, matching this
; project's established "note the error, keep going" convention for
; DEL/COPY/TOUCH's own multi-argument loops. A genuine PROTOCOL error
; (a chunk too large to fit our buffer, a write failure, the trailing
; 'x' missing) IS fatal to the whole session -- the two ends have no
; way to resynchronize once the chunk-level lock-step is broken.
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
            call    mr_recv_block       ; D = 0 (end-of-batch marker,
                                        ; ack NOT yet sent -- see
                                        ; mrs_batch_end below) / 1
                                        ; (header ready in mr_buf/
                                        ; mr_blk_count, payload ack not
                                        ; yet sent -- see
                                        ; mrs_inner_start below) / 2
                                        ; (fatal: chunk too large)
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

            ; --- have a HEADER chunk (payload ack owed -- see
            ; mrs_inner_start) ---
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

            lbr     mrs_inner_start     ; already noted (mr_skip_count
                                        ; bumped above) -- the specific
                                        ; "ignoring extra file(s)"
                                        ; detail is deliberately not
                                        ; printed here (see this file's
                                        ; own header comment: NOTHING
                                        ; prints mid-session, since
                                        ; console output and the
                                        ; transfer's own wire are the
                                        ; identical channel in console
                                        ; mode -- the aggregate skip
                                        ; count still shows up in
                                        ; mrs_summarize, once the wire
                                        ; is genuinely idle)

mrs_have_dest:
            mov     rf, mr_discard_flag
            ldi     0
            str     rf

            mov     rf, mr_destpath
            mov     rd, mr_fcb
            mov     ra, mr_iobuf
            ldi     1                   ; mode = write (create/truncate)
            call    K_FILE_OPEN         ; DF = 0/1
            lbnf    mrs_inner_start     ; opened cleanly -- nothing to
                                        ; print mid-session (see
                                        ; mrs_mode2_extra's own comment
                                        ; above), go straight to data

            mov     rf, mr_discard_flag
            ldi     1
            str     rf
            mov     rf, mr_err_count
            ldn     rf
            adi     1
            str     rf
            ; deliberately no "Cannot create ..." print here -- see
            ; mrs_mode2_extra's own comment above; mr_err_count alone
            ; carries this forward to mrs_summarize

mrs_inner_start:
            call    mr_send_ack         ; header's payload ack -- sent
                                        ; only now that we're genuinely
                                        ; ready for data (file opened,
                                        ; a "cannot create" error
                                        ; already noted and discarding,
                                        ; or an extra file in single-
                                        ; file mode already noted and
                                        ; discarding -- every path
                                        ; above converges here)
;------------------------------------------------------------------
; Inner loop: one iteration per DATA chunk of the current file.
;------------------------------------------------------------------
mrs_inner:
            call    mr_recv_block       ; D = 0 (end-of-file marker,
                                        ; ack NOT yet sent -- see
                                        ; mrs_file_end below) / 1 (data
                                        ; ready in mr_buf/mr_blk_count,
                                        ; payload ack not yet sent) / 2
                                        ; (fatal: chunk too large)
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

            ; --- have a DATA chunk (payload ack owed) ---
            mov     rf, mr_discard_flag
            ldn     rf
            lbnz    mrs_inner_discard

            mov     rf, mr_buf
            mov     r8, mr_blk_count
            lda     r8
            phi     rc
            ldn     r8
            plo     rc                  ; RC = full chunk byte count
            mov     rd, mr_fcb
            call    K_FILE_WRITE        ; DF = 0/1
            lbdf    mrs_write_err

            call    mr_send_ack         ; ack AFTER the write
                                        ; completes -- the whole point
                                        ; of this redesign: the sender
                                        ; genuinely waits for the disk
                                        ; write, not just the wire read
            lbr     mrs_inner

mrs_inner_discard:
            call    mr_send_ack         ; still ack even when
                                        ; discarding -- we just skip
                                        ; the write itself
            lbr     mrs_inner

mrs_write_err:
            mov     rd, mr_fcb
            call    K_FILE_CLOSE
            ldi     MRERR_WRITE         ; deliberately no "Write error."
                                        ; print here -- see this file's
                                        ; own header comment; mrs_result
                                        ; still carries this to start's
                                        ; own D/DF return, so the exit
                                        ; code reflects it either way
            lbr     mrs_summarize       ; no ack sent -- fatal, the
                                        ; sender is left waiting (same
                                        ; policy this protocol has
                                        ; always had for this exact
                                        ; case: there's nothing left to
                                        ; recover once a write fails
                                        ; mid-session)

mrs_file_end:
            mov     rf, mr_discard_flag
            ldn     rf
            lbnz    mrs_file_end_discard  ; discarding: nothing to
                                        ; close, ack right away

            mov     rd, mr_fcb
            call    K_FILE_CLOSE
            mov     rf, mr_ok_count
            ldn     rf
            adi     1
            str     rf
            call    mr_send_ack         ; end-of-file ack, deliberately
                                        ; deferred until AFTER the
                                        ; close -- see mr_recv_block's
                                        ; own header comment for why:
                                        ; K_FILE_CLOSE is real disk I/O,
                                        ; and acking any earlier would
                                        ; let the sender race ahead and
                                        ; write the next thing (another
                                        ; file's header, or the outer
                                        ; batch-end marker) before we're
                                        ; genuinely back to reading --
                                        ; exactly the class of bug this
                                        ; whole protocol redesign exists
                                        ; to close, just relocated to a
                                        ; spot the first pass missed
                                        ; (found via a real hardware
                                        ; hang, 2026-09-04)
            lbr     mrs_outer

mrs_file_end_discard:
            call    mr_send_ack
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
            call    mr_send_ack         ; batch-end ack, deferred from
                                        ; mr_recv_block -- nothing slow
                                        ; follows here (just the
                                        ; trailing 'x' read below), so
                                        ; sending it right away is safe
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
; mr_recv_block: read one chunk's 2-byte big-endian length. If the
; length is 0, that's the WHOLE exchange -- no payload follows, and NO
; ack is sent here: the caller sends it (via mr_send_ack, below) only
; once it has finished whatever processing a zero-length chunk implies
; on ITS end (closing the just-received file, for instance) -- see
; this file's own header comment for why that distinction matters
; (K_FILE_CLOSE is real disk I/O; acking before it completes would let
; the sender race ahead and write the next thing while we're not yet
; back to listening, on hardware with no UART FIFO to absorb it --
; found via a real hardware hang, 2026-09-04). If the length is
; nonzero, send the length ack (safe immediately here, since nothing
; slow happens before the payload starts flowing) and read that many
; payload bytes into mr_buf via mr_readbytes -- but do NOT send the
; payload's own ack. The caller sends that one too, only once it has
; finished its own processing of the payload (a disk write, or opening
; the destination file). Ordinary intra-proc subroutine (no page
; alignment needed -- no hand-written short branches here).
;
; Returns: D = 0 (length was 0 -- an end marker; NO ack sent, caller
;          must call mr_send_ack once ready), 1 (a real chunk: mr_buf
;          holds its payload, mr_blk_count its length; the length ack
;          has already been sent, but the PAYLOAD ack has not --
;          caller must call mr_send_ack once its own processing of
;          this chunk is complete), 2 (fatal: the length was too large
;          to fit mr_buf -- a genuinely malformed/desynced session; no
;          ack sent, matching the length=0 case)
; Modifies: everything
;------------------------------------------------------------------
mr_recv_block:
            call    mr_getbyte
            plo     rc
            mov     rf, mr_cnt_hi
            glo     rc
            str     rf

            call    mr_getbyte
            plo     rc
            mov     rf, mr_cnt_lo
            glo     rc
            str     rf

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

            ghi     rc
            lbnz    mrb_have_len
            glo     rc
            lbz     mrb_len_zero

mrb_have_len:
            ; defensive: reject a chunk too large for mr_buf (512
            ; bytes) -- can't happen from either of this project's own
            ; senders (a header maxes out at MAXFER_NAME_MAX+5=132
            ; bytes, a data chunk at BLOCK_BUF_LEN=512), but a
            ; genuinely malformed/desynced session shouldn't be
            ; allowed to overrun mr_buf
            ghi     rc
            smi     3
            lbdf    mrb_too_big         ; RC.hi >= 3 -> RC >= 768

            ghi     rc
            xri     2
            lbnz    mrb_size_ok         ; RC.hi is 0 or 1 -> RC <= 511

            glo     rc
            lbnz    mrb_too_big         ; RC.hi == 2, RC.lo != 0 ->
                                        ; RC > 512

mrb_size_ok:
            call    mr_send_ack         ; length ack -- safe right
                                        ; away here, since nothing slow
                                        ; happens before the payload
                                        ; itself starts flowing

            mov     rf, mr_buf
            dec     rc                  ; mr_readbytes runs COUNT
                                        ; times when seeded with
                                        ; COUNT-1
            call    mr_readbytes

            ldi     1
            rtn

mrb_len_zero:
            ldi     0
            rtn                         ; NO ack sent -- see this
                                        ; proc's own header comment

mrb_too_big:
            ldi     2
            rtn

;------------------------------------------------------------------
; mr_send_ack: write a single $AA ack byte.
; Modifies: everything (via mr_putbyte)
;------------------------------------------------------------------
mr_send_ack:
            ldi     $aa
            call    mr_putbyte
            rtn

;------------------------------------------------------------------
; mr_parse_header: interpret mr_buf[0..mr_blk_count-1] as a header
; chunk (name, NUL, 4-byte big-endian size) sent ahead of a new file's
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
; every PROTOCOL byte in this session (handshake, chunk length/ack,
; the trailing 'x') -- NOT used for the hot per-byte DATA loop
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
mr_discard_flag:    db      0
mrb_result:         db      0
mrs_result:         db      0
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
; runs once per incoming payload byte with no per-byte handshake from
; the host (only the chunk-level $AA acks throttle it), so at the top
; end of whichever transport is in use every extra instruction here is
; real risk of an overrun and a dropped byte. A genuine hand-written
; short branch for each loop-back, not an lbnz left for -r to shrink
; after the fact -- safe specifically because of the .link .align page
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
