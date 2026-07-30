;
; yr.asm - receive one or more files via YMODEM-CRC batch transfer
;
; Usage: YR [-u|-b] [-y] [-q]
;
; Companion to a host-side YMODEM sender (e.g. "sz -b" from lrzsz), or
; to this project's own progs/ys.asm. Unlike MR (which receives a
; single, caller-named file), YR takes no filename at all -- YMODEM's
; own batch header block carries the sender's filename (and size) for
; each file, so YR just keeps receiving files, under whatever names
; the sender gives them, until the sender signals the batch is
; complete (an empty/null header block).
;
; Flags:
;   -u          use the disk-board UART directly (f_uread/f_utype) --
;               the default.
;   -b          use the onboard bit-bang serial port directly
;               (f_bread/f_btype) instead.
;   -y          overwrite existing files without asking.
;   -q          quiet -- suppress the per-file progress line, print
;               only the final summary.
;
; -u/-b select which BIOS routines lib/ymodem.asm's own I/O primitives
; call directly, bypassing K_READ/K_TYPE's own kernel-jump-table/RAM-
; vector indirection -- same reasoning, same two device options, as
; progs/mr.asm/progs/ms.asm's own identical flags (see either file's
; header comment for the full account). UART mode additionally gets
; real timeout/retry via f_utest polling; bit-bang mode cannot (see
; lib/ymodem.asm's own header comment for why) and simply blocks,
; matching mr.asm/ms.asm's own pre-existing, accepted limitation.
;
; Register-liveness discipline follows mr.asm/ms.asm's own hardware-
; confirmed rule: nothing survives more than one call to K_READ/K_TYPE
; (or here, ym_getbyte/ym_getbyte_timeout/ym_putbyte, which reach the
; same class of BIOS entry points) in a register -- everything that
; needs to survive lives in memory instead. This program makes FAR
; more such calls per block than mr.asm ever did (CRC computation,
; block-header parsing, retry bookkeeping), so this discipline is
; applied uniformly throughout, not just at the specific spots
; mr.asm/ms.asm's own bug hunts identified.
;
; File-size truncation: YMODEM blocks are fixed-size (128 or 1024
; bytes), so the final block of a file almost always contains trailing
; pad bytes past the real end of file. The header block's own size
; field is the source of truth for exactly how many bytes are real --
; each data block's real (non-pad) byte count is computed as
; min(block_len, target_size - bytes_written_so_far) before writing,
; so the file this ends up with is byte-exact, never padded. If a
; sender omits the size (rare, legacy senders only), the size parses
; as 0 and every block is written in full with no truncation --
; classic XMODEM-style behavior, the only sane fallback when the true
; size isn't known.
;
; Declining an overwrite (or a failed K_FILE_OPEN) doesn't drop out of
; the batch -- YMODEM has no way to tell the sender "skip this file
; but keep going," so the data blocks are still received and ACKed
; normally to keep the wire protocol in lock-step; yr_skip_file just
; suppresses the K_FILE_WRITE calls, discarding the bytes instead of
; saving them.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/ymodem.inc

            extrn   ym_crc16
            extrn   ym_parse_uint32
            extrn   ym_getbyte
            extrn   ym_getbyte_timeout
            extrn   ym_putbyte
            extrn   ym_recv_block
            extrn   ym_io_mode

; yr_get_header's own result codes
YR_HDR_OK:      equ     0           ; got a real file header
YR_HDR_DONE:    equ     1           ; null header -- batch complete
YR_HDR_ERR:     equ     2           ; handshake/protocol failure

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[0] is this program's
            ; own name; every argv[1..argc-1] must be one of -u/-b/-y/
            ; -q (YR takes no positional arguments at all, unlike
            ; mr.asm's own single required filename).
            mov     rf, ym_io_mode
            ldi     YM_IO_UART          ; default
            str     rf
            mov     rf, yr_noask
            ldi     0
            str     rf
            mov     rf, yr_quiet
            ldi     0
            str     rf

            mov     rf, yr_i
            ldi     1
            str     rf

parse_loop:
            mov     rf, yr_i
            ldn     rf
            str     r2                  ; M(X) = yr_i
            glo     rc
            xor                         ; D = argc XOR yr_i
            lbz     parse_done          ; yr_i == argc: done

            mov     rf, yr_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = yr_i (zero-extended)
            shl16   r8                  ; R8 = yr_i * 2
            mov     rb, ra
            add16   rb, r8              ; RB = &argv[yr_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[yr_i]
            mov     rf, rd              ; RF = argv[yr_i] (dereferenced)

            ldn     rf
            xri     '-'
            lbnz    usage               ; not even a flag: usage error

            inc     rf
            ldn     rf
            plo     r9                  ; R9.0 = flag letter
            inc     rf
            ldn     rf                  ; must be NUL for a 2-char flag
            lbnz    usage

            glo     r9
            xri     'u'
            lbz     pf_uart
            glo     r9
            xri     'b'
            lbz     pf_bitbang
            glo     r9
            xri     'y'
            lbz     pf_noask
            glo     r9
            xri     'q'
            lbz     pf_quiet
            lbr     usage               ; unrecognized flag letter

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
pf_noask:
            mov     rf, yr_noask
            ldi     1
            str     rf
            lbr     pf_next
pf_quiet:
            mov     rf, yr_quiet
            ldi     1
            str     rf

pf_next:
            mov     rf, yr_i
            ldn     rf
            adi     1
            str     rf
            lbr     parse_loop

parse_done:
            call    yr_run_batch        ; D = 0 success, 1 failure
            rtn

usage:
            call    K_INMSG
            db      "Usage: YR [-u|-b] [-y] [-q]",13,10,0
            ldi     1
            rtn

yr_i:           db      0
yr_noask:       db      0
yr_quiet:       db      0

;==================================================================
; yr_run_batch: the main receive loop -- get a header block, receive
; that file's data, repeat until the sender's null/terminator header
; signals the batch is complete.
; Returns: D = 0 (all files received cleanly) or 1 (a fatal protocol
;          error ended the batch early, or at least one file's own
;          K_FILE_WRITE failed)
;==================================================================
yr_run_batch:
            mov     rf, yr_any_error
            ldi     0
            str     rf
            mov     rf, yr_files_done
            ldi     0
            str     rf
            inc     rf
            str     rf

yrb_loop:
            call    yr_get_header       ; D = YR_HDR_OK(0)/DONE(1)/ERR(2)
            lbz     yrb_have_file       ; D==0: OK, got a real header
            smi     1
            lbz     yrb_done            ; D was 1: DONE (batch complete)
            lbr     yrb_fatal           ; D was 2: ERR

yrb_have_file:
            call    yr_prepare_file     ; sets yr_skip_file/yr_fcb_open;
                                        ; opens yr_fcb unless skipping
            call    yr_receive_data     ; DF = 0/1
            lbdf    yrb_fatal

            mov     rf, yr_fcb_open
            ldn     rf
            lbz     yrb_progress        ; FCB was never opened (skipped
                                        ; or open failed): nothing to
                                        ; close
            mov     rd, yr_fcb
            call    K_FILE_CLOSE

yrb_progress:
            mov     rf, yr_quiet
            ldn     rf
            lbnz    yrb_next

            call    K_INMSG
            db      "Received ",0
            mov     rf, yr_filename
            call    K_MSG
            call    K_INMSG
            db      13,10,0

yrb_next:
            mov     rf, yr_files_done
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, yr_files_done
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     yrb_loop

yrb_fatal:
            mov     rf, yr_any_error
            ldi     1
            str     rf

yrb_done:
            mov     rf, yr_any_error
            ldn     rf
            lbnz    yrb_report_err

            mov     rf, yr_quiet
            ldn     rf
            lbnz    yrb_ok_silent

            call    K_INMSG
            db      "Transfer complete.",13,10,0

yrb_ok_silent:
            ldi     0
            rtn

yrb_report_err:
            call    K_INMSG
            db      "Transfer completed with errors.",13,10,0
            ldi     1
            rtn

yr_any_error:   db      0
yr_files_done:  dw      0

;==================================================================
; yr_get_header: probe with 'C' (retrying on timeout, up to
; YM_HANDSHAKE_TRIES), receive and validate the next header block,
; and either parse it (filename+size, into yr_filename/
; yr_target_size_hi/lo) or recognize it as the batch terminator (an
; empty filename).
; Returns: D = YR_HDR_OK / YR_HDR_DONE / YR_HDR_ERR
;==================================================================
yr_get_header:
            mov     rf, yr_retry
            ldi     YM_HANDSHAKE_TRIES
            str     rf

yrgh_retry:
            ldi     YM_C
            call    ym_putbyte

            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout  ; DF=0 D=byte / DF=1 timeout
            lbdf    yrgh_retry_or_err

            plo     r8                  ; R8.0 = the byte (no call
                                        ; before it's used just below)
            glo     r8
            xri     YM_CAN
            lbz     yrgh_err

            glo     r8
            xri     YM_SOH
            lbz     yrgh_got_soh

yrgh_retry_or_err:
            mov     rf, yr_retry
            ldn     rf
            smi     1
            str     rf
            lbz     yrgh_err
            lbr     yrgh_retry

yrgh_err:
            ldi     YR_HDR_ERR
            rtn

yrgh_got_soh:
            call    ym_getbyte          ; blockno (expected 0, not
                                        ; strictly validated)
            call    ym_getbyte          ; ~blockno (expected $FF)

            mov     rf, yr_block_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc                  ; RC = 127 (128-1, ym_recv_
                                        ; block's own pre-decremented
                                        ; convention)
            call    ym_recv_block

            call    ym_getbyte
            plo     r8
            mov     rf, yr_crc_hi
            glo     r8
            str     rf

            call    ym_getbyte
            plo     r8
            mov     rf, yr_crc_lo
            glo     r8
            str     rf

            mov     rf, yr_block_buf
            ldi     0
            phi     rc
            ldi     128
            plo     rc
            call    ym_crc16            ; RD = computed CRC

            mov     rf, yr_crc_hi
            ldn     rf
            str     r2
            ghi     rd
            xor
            lbnz    yrgh_bad_crc
            mov     rf, yr_crc_lo
            ldn     rf
            str     r2
            glo     rd
            xor
            lbnz    yrgh_bad_crc

            ; valid header block -- null/terminator (first byte 0) or
            ; a real file?
            mov     rf, yr_block_buf
            ldn     rf
            lbnz    yrgh_real_file

            ldi     YM_ACK
            call    ym_putbyte
            ldi     YR_HDR_DONE
            rtn

yrgh_bad_crc:
            ldi     YM_NAK
            call    ym_putbyte
            mov     rf, yr_retry
            ldn     rf
            smi     1
            str     rf
            lbz     yrgh_err
            lbr     yrgh_retry

;------------------------------------------------------------------
; yrgh_real_file: copy the filename (bounded, always leaving room for
; a forced NUL -- a corrupted/pathological header with no real NUL
; anywhere in its 128 bytes must not be able to overrun yr_filename)
; and parse the size field that follows it.
;------------------------------------------------------------------
yrgh_real_file:
            mov     rf, yr_block_buf
            mov     rb, yr_filename
            ldi     127
            plo     rc                  ; RC.0 = real copies remaining
                                        ; before a forced stop

yrgh_copy_name:
            lda     rf
            str     rb
            lbz     yrgh_name_done      ; wrote a real NUL: stop (RF
                                        ; already points past it)
            inc     rb
            glo     rc
            smi     1
            plo     rc
            lbz     yrgh_name_force_term
            lbr     yrgh_copy_name

yrgh_name_force_term:
            inc     rb
            ldi     0
            str     rb                  ; force a NUL -- always in
                                        ; bounds (yr_filename is 128
                                        ; bytes, at most 127 real
                                        ; copies happened above)
            mov     rb, yr_target_size_hi
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb                  ; no sane size field to parse
                                        ; in this pathological case --
                                        ; default to 0 (no truncation)
            lbr     yrgh_have_name

yrgh_name_done:
            call    ym_parse_uint32     ; RF already correct (points
                                        ; past the filename's NUL);
                                        ; RD:R8 = parsed size
            mov     rb, yr_target_size_hi
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb

yrgh_have_name:
            ldi     YM_ACK
            call    ym_putbyte
            ldi     YR_HDR_OK
            rtn

yr_retry:           db      0
yr_crc_hi:          db      0
yr_crc_lo:          db      0
yr_target_size_hi:  dw      0
yr_target_size_lo:  dw      0

;==================================================================
; yr_prepare_file: decide whether to actually save this file (check
; for an existing file, prompt unless -y) and open it if so. A
; declined overwrite or a failed open just sets yr_skip_file -- see
; this file's own top-of-file header comment for why that doesn't
; abort the batch.
; Sets:    yr_skip_file, yr_fcb_open
;==================================================================
yr_prepare_file:
            mov     rf, yr_skip_file
            ldi     0
            str     rf
            mov     rf, yr_fcb_open
            ldi     0
            str     rf

            mov     rf, yr_noask
            ldn     rf
            lbnz    yrpf_open           ; -y: skip the existence check

            mov     rf, yr_filename
            mov     rd, yr_statbuf
            call    K_STAT              ; DF=0: exists
            lbdf    yrpf_open           ; doesn't exist: open directly

            call    K_INMSG
            db      "File exists: ",0
            mov     rf, yr_filename
            call    K_MSG
            call    K_INMSG
            db      "? (Y/N) ",0

            call    K_READ              ; D = character read (blocking)
            plo     rc                  ; stash in memory, not a
                                        ; register, across K_TTY/
                                        ; K_INMSG -- only R9's survival
                                        ; is confirmed (gotcha #8)
            mov     rf, yr_answer
            glo     rc
            str     rf

            call    K_TTY
            call    K_INMSG
            db      13,10,0

            mov     rf, yr_answer
            ldn     rf
            ani     $DF
            xri     'Y'
            lbz     yrpf_open

            mov     rf, yr_skip_file
            ldi     1
            str     rf
            rtn

yrpf_open:
            mov     rf, yr_filename
            mov     rd, yr_fcb
            mov     ra, yr_iobuf
            ldi     1                   ; mode = write (create/truncate)
            call    K_FILE_OPEN         ; DF=0/1
            lbdf    yrpf_open_failed

            mov     rf, yr_fcb_open
            ldi     1
            str     rf
            rtn

yrpf_open_failed:
            mov     rf, yr_skip_file
            ldi     1
            str     rf
            rtn

yr_skip_file:   db      0
yr_fcb_open:    db      0
yr_answer:      db      0

;==================================================================
; yr_receive_data: send the second 'C' to start requesting data
; blocks, then receive block after block (retrying on a bad block or
; a timeout waiting for the next one) until EOT. Each block's real
; (non-pad) byte count is computed from yr_target_size_hi/lo and the
; running yr_bytes_written_hi/lo before writing -- see this file's own
; top-of-file header comment on why the file this produces is never
; padded.
; Returns: DF = 0 on success, DF = 1 on a fatal protocol failure
;==================================================================
yr_receive_data:
            mov     rf, yr_bytes_written_hi
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            mov     rf, yr_blockno
            ldi     1
            str     rf

            mov     rf, yr_retry
            ldi     YM_HANDSHAKE_TRIES
            str     rf

yrd_send_c:
            ldi     YM_C
            call    ym_putbyte

yrd_wait_type:
            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    yrd_timeout

            plo     r8                  ; R8.0 = the type byte
            glo     r8
            xri     YM_CAN
            lbz     yrd_fatal

            glo     r8
            xri     YM_EOT
            lbz     yrd_got_eot

            glo     r8
            xri     YM_SOH
            lbz     yrd_got_soh

            glo     r8
            xri     YM_STX
            lbz     yrd_got_stx

yrd_timeout:
            mov     rf, yr_retry
            ldn     rf
            smi     1
            str     rf
            lbz     yrd_fatal
            ldi     YM_NAK
            call    ym_putbyte
            lbr     yrd_wait_type

yrd_fatal:
            stc
            rtn

yrd_got_eot:
            ldi     YM_NAK
            call    ym_putbyte

            ldi     high YM_POLL_BUDGET
            phi     rd
            ldi     low YM_POLL_BUDGET
            plo     rd
            call    ym_getbyte_timeout
            lbdf    yrd_eot_ack         ; nothing arrived -- lenient,
                                        ; finish anyway
            plo     r8
            glo     r8
            xri     YM_EOT
            lbnz    yrd_eot_ack         ; not a second EOT either --
                                        ; still lenient

yrd_eot_ack:
            ldi     YM_ACK
            call    ym_putbyte
            clc
            rtn

yrd_got_soh:
            mov     rf, yr_block_len
            ldi     0
            str     rf
            inc     rf
            ldi     YM_BLKLEN_128
            str     rf
            lbr     yrd_read_block

yrd_got_stx:
            mov     rf, yr_block_len
            ldi     high YM_BLKLEN_1024
            str     rf
            inc     rf
            ldi     low YM_BLKLEN_1024
            str     rf

yrd_read_block:
            call    ym_getbyte          ; blockno (received)
            plo     r8
            mov     rf, yr_recv_blockno
            glo     r8
            str     rf

            call    ym_getbyte          ; ~blockno (received)
            plo     r8
            mov     rf, yr_recv_blockno_c
            glo     r8
            str     rf

            mov     rf, yr_block_buf
            mov     rd, yr_block_len
            lda     rd
            phi     rc
            ldn     rd
            plo     rc                  ; RC = block_len
            sub16   rc, 1               ; RC = block_len-1 (ym_recv_
                                        ; block's pre-decremented
                                        ; convention)
            call    ym_recv_block

            call    ym_getbyte
            plo     r8
            mov     rf, yr_crc_hi
            glo     r8
            str     rf
            call    ym_getbyte
            plo     r8
            mov     rf, yr_crc_lo
            glo     r8
            str     rf

            mov     rf, yr_block_buf
            mov     rd, yr_block_len
            lda     rd
            phi     rc
            ldn     rd
            plo     rc
            call    ym_crc16

            mov     rf, yr_crc_hi
            ldn     rf
            str     r2
            ghi     rd
            xor
            lbnz    yrd_bad_block
            mov     rf, yr_crc_lo
            ldn     rf
            str     r2
            glo     rd
            xor
            lbnz    yrd_bad_block

            ; blockno/~blockno self-consistency (received values sum
            ; to 255)
            mov     rf, yr_recv_blockno
            ldn     rf
            str     r2
            mov     rf, yr_recv_blockno_c
            ldn     rf
            add
            xri     255
            lbnz    yrd_bad_block

            ; matches the expected next block number?
            mov     rf, yr_recv_blockno
            ldn     rf
            str     r2
            mov     rf, yr_blockno
            ldn     rf
            xor
            lbz     yrd_block_expected

            ; a duplicate of the block we already processed (sender
            ; never saw our ACK)? re-ACK without reprocessing
            mov     rf, yr_blockno
            ldn     rf
            smi     1
            str     r2
            mov     rf, yr_recv_blockno
            ldn     rf
            xor
            lbz     yrd_block_duplicate

            lbr     yrd_bad_block

yrd_block_duplicate:
            ldi     YM_ACK
            call    ym_putbyte
            mov     rf, yr_retry
            ldi     YM_HANDSHAKE_TRIES
            str     rf
            lbr     yrd_wait_type

yrd_block_expected:
            ; --- real_bytes = min(block_len, target_size -
            ; bytes_written); target_size == 0 means "no truncation" ---
            mov     rf, yr_target_size_hi
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = target_size

            ghi     rd
            lbnz    yrd_has_size
            glo     rd
            lbnz    yrd_has_size
            ghi     r8
            lbnz    yrd_has_size
            glo     r8
            lbnz    yrd_has_size

            mov     rf, yr_block_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, yr_real_bytes
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            lbr     yrd_have_real_bytes

yrd_has_size:
            mov     rf, yr_bytes_written_hi
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            inc     rf
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R7:R9 = bytes_written

            glo     r9
            str     r2
            glo     r8
            sm
            plo     r8
            ghi     r9
            str     r2
            ghi     r8
            smb
            phi     r8
            glo     r7
            str     r2
            glo     rd
            smb
            plo     rd
            ghi     r7
            str     r2
            ghi     rd
            smb
            phi     rd
            ; RD:R8 = remaining (target_size - bytes_written)

            ghi     rd
            lbnz    yrd_full_block
            glo     rd
            lbnz    yrd_full_block

            mov     rf, yr_block_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            glo     r9
            str     r2
            glo     r8
            sm
            ghi     r9
            str     r2
            ghi     r8
            smb
            lbdf    yrd_full_block      ; DF=1: remaining >= block_len

            mov     rf, yr_real_bytes
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            lbr     yrd_have_real_bytes

yrd_full_block:
            mov     rf, yr_block_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, yr_real_bytes
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

yrd_have_real_bytes:
            mov     rf, yr_skip_file
            ldn     rf
            lbnz    yrd_skip_write

            mov     rf, yr_real_bytes
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            mov     rf, yr_block_buf
            mov     rd, yr_fcb
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    yrd_write_err

yrd_skip_write:
            ; bytes_written += real_bytes (32-bit add)
            mov     rf, yr_real_bytes
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = real_bytes
            mov     rf, yr_bytes_written_lo
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            glo     r7
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r7
            str     r2
            ghi     r8
            adc
            phi     r8
            mov     rf, yr_bytes_written_lo
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            mov     rf, yr_bytes_written_hi
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ldi     0
            str     r2
            glo     rd
            adc
            plo     rd
            ldi     0
            str     r2
            ghi     rd
            adc
            phi     rd
            mov     rf, yr_bytes_written_hi
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, yr_blockno
            ldn     rf
            adi     1
            str     rf

            mov     rf, yr_retry
            ldi     YM_HANDSHAKE_TRIES
            str     rf

            ldi     YM_ACK
            call    ym_putbyte
            lbr     yrd_wait_type

yrd_write_err:
            stc
            rtn

yrd_bad_block:
            ldi     YM_NAK
            call    ym_putbyte
            mov     rf, yr_retry
            ldn     rf
            smi     1
            str     rf
            lbz     yrd_fatal2
            lbr     yrd_wait_type

yrd_fatal2:
            stc
            rtn

yr_bytes_written_hi: dw    0
yr_bytes_written_lo: dw    0
yr_blockno:          db   0
yr_block_type:       db   0
yr_block_len:        dw   0
yr_recv_blockno:     db   0
yr_recv_blockno_c:   db   0
yr_real_bytes:       dw   0

yr_filename:    ds      128
yr_fcb:         ds      FCB_LEN
yr_iobuf:       ds      FCB_IOBUF_LEN
yr_statbuf:     ds      DIRENT_LEN
yr_block_buf:   ds      1024

            end     start
