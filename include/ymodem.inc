;
; ymodem.inc - YMODEM-CRC protocol constants shared by progs/yr.asm and
; progs/ys.asm. Restated (not #included from lib/ymodem.asm) matching
; this project's own established convention for small shared constant
; sets -- see include/vollabel.inc/include/file_glob.inc for precedent.
;

; restated from lib/ymodem.asm's own equ's -- an equ is a pure
; assemble-time constant, not a real linked symbol, so it can't be
; extrn'd across files the way ym_io_mode (real memory) can; matches
; this project's own established restated-constant convention (e.g.
; BPBBLK_* between kernel.inc/kernel_api.inc). Renumbered 2026-09-01
; when a third mode (CONSOLE, via K_READ/K_TYPE) became the default --
; see lib/ymodem.asm's own header comment for the full device-
; selection design; keep this file in sync with lib/ymodem.asm if it
; ever changes again.
YM_IO_CONSOLE:  equ     0       ; call K_READ/K_TYPE (default)
YM_IO_UART:     equ     1       ; call f_uread/f_utype directly
YM_IO_BITBANG:  equ     2       ; call f_bread/f_btype directly

YM_SOH:     equ     $01     ; 128-byte block follows
YM_STX:     equ     $02     ; 1024-byte block follows ("-k" mode)
YM_EOT:     equ     $04     ; end of this file's data
YM_ACK:     equ     $06     ; positive acknowledge
YM_NAK:     equ     $15     ; negative acknowledge / retransmit please
YM_CAN:     equ     $18     ; cancel (sent by either end to abort)
YM_C:       equ     $43     ; 'C' -- CRC-mode probe, sent by the receiver

YM_BLKLEN_128:  equ     128
YM_BLKLEN_1024: equ     1024

; Retry/timeout policy -- see lib/ymodem.asm's own header comment for
; why these can only be real, polled timeouts in UART (-u) mode; bit-
; bang (-b) mode has no non-blocking "byte waiting" primitive at all,
; so ym_getbyte_timeout just blocks there regardless of these budgets.
; YM_POLL_BUDGET is an iteration count, not a calibrated wall-clock
; time -- deliberately generous (a real hardware round may want to
; retune it once its actual real-world duration is known).
YM_POLL_BUDGET:     equ     20000       ; per-attempt poll budget
YM_HANDSHAKE_TRIES: equ     15          ; times to (re)send 'C' before
                                        ; giving up on a file/batch
YM_BLOCK_TRIES:     equ     10          ; times to NAK-and-retry one
                                        ; bad data block before giving up
