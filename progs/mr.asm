;
; mr.asm - receive a file over the serial port
;
; Usage: MR [-u|-b] <filename>
;
; Companion to the host-side max-xfr tool, run as "max-xfr -s" to
; send. The wire protocol (handshake byte, per-block header echo,
; block layout) is ELF-DOS's own file-transfer protocol -- see
; mr_receive's own header comment below for the exact byte sequence.
;
; Structure: this file is a thin setup/teardown shell (argument
; parsing, file open/close, result reporting) around mr_receive, a
; self-contained routine that does the actual protocol work against an
; already-open FCB. The split is deliberate -- mr_receive takes no
; console-I/O responsibility and touches nothing but its own local
; state and the FCB it's given, so it can be lifted into a shared
; library later (e.g. for the C compiler's own runtime) without
; dragging this program's argument handling along with it.
;
; mr_receive is a real proc/endp block (same-file cross-proc call from
; start, via extrn -- ordinary Asm/02 convention, see kernel/file.asm
; for precedent) rather than a flat label, and is placed on its own
; page via ".link .align page" immediately before it. That directive
; passes ".align page" through to Link/02 itself (Asm/02's own .align
; is assemble-time-only and doesn't survive into the .prg for a
; relocatable proc -- confirmed by direct testing -- so plain .align
; before a proc/endp block is a silent no-op). Link/02 honors it
; whether or not -r is active (confirmed via an isolated synthetic
; test: a proc preceded by ".link .align page" landed exactly on a
; page boundary both with and without -r, 2026-07-11). Page-aligning
; mr_receive (well under 256 bytes) guarantees every intra-proc branch
; -- readlp_uart/readlp_bitbang's hand-written short branches in
; particular -- fits on one page regardless of where the proc lands in
; the final program.
;
; IMPORTANT, hardware-confirmed 2026-07-11: a register is NOT safe to
; hold a value across more than one intervening call to K_READ/K_TYPE
; -- something inside repeated calls to these two (f_read/f_type)
; clobbers at least one general-purpose register, contrary to the
; assumption this file and ms.asm both originally made (copied from
; the original Elf/OS ms.asm, which used the identical "cache a
; pointer in a register across the whole transfer" pattern and was,
; per the user, "very reliable" there -- so this is most likely a
; genuine ELF-DOS f_read/f_type behavior difference under repeated
; calls, not a design mistake ported from the original). Confirmed via
; ms.asm's own send buffer (RA) silently resetting mid-transfer,
; producing a byte-exact repeating 512-byte block in the received
; file instead of the real, varying file content -- see ms.asm's
; header for the full evidence. This file's own mr_cnt_hi/mr_cnt_lo
; (below) exist because of the same risk: the block byte count used
; to live in R7 across the two intervening, discarded address-field
; K_READ/K_TYPE call pairs in mr_cmd01, which is exactly the failure
; shape that produced ms.asm's bug. Only R9's survival across
; f_msg/f_inmsg/f_idewrite has ever been confirmed (gotcha #8 in
; CLAUDE.md) -- nothing about K_READ/K_TYPE specifically was tested
; before this. mr_cmd01's header exchange still goes through K_READ/
; K_TYPE (it's once-per-block, not once-per-byte, so the indirection
; cost doesn't matter there) and still needs the memory-based
; mr_cnt_hi/mr_cnt_lo workaround below for that reason.
; readlp_uart/readlp_bitbang's own use of RC across their direct
; f_uread/f_bread calls (in the one loop that has to stay fast) has
; NOT been independently confirmed safe either -- left as-is rather
; than moved to memory, since fixing it would cost real throughput in
; the one loop where that matters most, and RC's survival across
; K_TYPE at least is indirectly supported by ms.asm's own sendloop
; (same register, same call shape) producing a correctly-sized
; transfer end-to-end. Revisit if a future transfer fails with the
; wrong total byte count rather than corrupted-but-correctly-sized
; content.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   mr_receive

; Direct-device receive loop: an optional "-u" (UART, the default) or
; "-b" (bit-bang) flag before the filename selects which BIOS routine
; readlp_uart/readlp_bitbang below calls directly for each incoming
; byte, bypassing K_READ entirely -- no kernel jump-table hop, no
; f_read's own RAM-vector indirection through whatever "read" is
; currently patched to (the device-abstraction layer that lets a
; BIOS trap console I/O to something else, e.g. a directly connected
; keyboard or an OLED terminal, per the user's own account of why that
; indirection was added to Elf/OS originally). f_uread/f_bread
; (bios.inc, EBIOS+0ch/+00h) are stable, already-established BIOS
; entry points -- confirmed against this project's own mbios.asm/
; mbios.lst source -- that reach the hardware UART/bit-bang driver
; directly, independent of RE.1 and the device-abstraction layer (same
; as f_utest/f_btest). Motivation: hardware testing showed mr
; occasionally dropping individual bytes during a real transfer
; (confirmed via byte-exact comparison against the original file, not
; guessed) -- right at the edge of keeping up at high baud, per the
; user's own assessment (echoed by their own account of intermittent
; Elf/OS failures starting once that 3rd indirection layer was added),
; so shaving those hops off the hot loop's per-byte cost is worth it.
; Deferred, not yet implemented: auto-selecting UART vs. bit-bang via
; an environment variable or an f_getdev probe once either exists --
; for now the caller states it explicitly, defaulting to UART.

; mr_receive I/O mode selector (mr_io_mode, set once in start, read
; once per block in mr_receive -- see readlp_uart/readlp_bitbang below)
MR_IO_UART:         equ     0           ; call f_uread directly (default)
MR_IO_BITBANG:      equ     1           ; call f_bread directly

; mr_receive result codes (returned in D; 0 = success)
MRERR_HANDSHAKE:    equ     1           ; sync byte never arrived/matched
MRERR_COMMAND:      equ     2           ; unrecognized per-block command byte
MRERR_WRITE:        equ     3           ; K_FILE_WRITE failed

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc (RC.0 alone is enough).
            ; argv[0] is this program's own name. argv[1] may be an
            ; optional "-u"/"-b" flag -- now a clean, standalone token
            ; (the shell's own tokenizer already split on whitespace,
            ; so no per-character space-boundary check is needed
            ; anymore, just a direct 2-character-plus-NUL comparison);
            ; the filename is argv[2] if a flag was given, else
            ; argv[1]. mr_io_mode (memory) records the choice, since
            ; mr_receive -- a separate proc -- needs to read it once at
            ; block-entry time, outside the tight loop itself. Defaults
            ; to MR_IO_UART when no flag is given.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    not_flag

            inc     rf
            ldn     rf                  ; D = argv[1][1]
            plo     r8                  ; R8.0 = the flag letter (temp)

            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
                                        ; for "-u"/"-b" to be exactly
                                        ; this whole token
            lbnz    not_flag

            glo     r8                  ; D = flag letter again
            xri     'u'
            lbz     flag_uart
            glo     r8
            xri     'b'
            lbz     flag_bitbang
            lbr     not_flag            ; unrecognized letter -- fall
                                        ; back to treating argv[1]
                                        ; itself as the (probably
                                        ; invalid) filename

flag_uart:
            glo     rc
            smi     3
            lbnf    usage               ; flag given but argc < 3: no
                                        ; filename after it
            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (filename)
            mov     rf, mr_io_mode
            ldi     MR_IO_UART
            str     rf
            lbr     have_name_ptr

flag_bitbang:
            glo     rc
            smi     3
            lbnf    usage
            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (filename)
            mov     rf, mr_io_mode
            ldi     MR_IO_BITBANG
            str     rf
            lbr     have_name_ptr

not_flag:
            ; RD already holds argv[1]'s pointer, untouched by the
            ; flag-character checks above -- that's the filename
            mov     rf, mr_io_mode
            ldi     MR_IO_UART          ; default
            str     rf
            lbr     have_name_ptr

usage:
            call    K_INMSG
            db      "Usage: MR [-u|-b] <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name_ptr:
            mov     rf, rd              ; RF = filename
            mov     rd, mr_fcb_struct   ; RD = our FCB struct
            mov     ra, mr_iobuf        ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     1                   ; mode = write (create/truncate)
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; mr_fcb_struct is a fixed
                                        ; address, nothing to capture)
            lbdf    open_error

            mov     rd, mr_fcb_struct   ; RD = FCB pointer, passed to
                                        ; mr_receive as its own
                                        ; argument -- widened from the
                                        ; old 1-byte handle-in-D
                                        ; convention to match the new
                                        ; K_FILE_* ABI (mr_receive
                                        ; still takes it as an explicit
                                        ; argument rather than
                                        ; referencing mr_fcb_struct
                                        ; directly -- it's a separate
                                        ; proc, and this project has no
                                        ; existing precedent for a
                                        ; proc referencing flat, non-
                                        ; proc-wrapped data in the same
                                        ; file, so this sidesteps that
                                        ; open question entirely)
            call    mr_receive          ; D = result code (0 = success)
            ; BUG-CLASS GUARD (see progs/type.asm/wtest.asm): stash the
            ; result before "mov rf, ..." for K_FILE_CLOSE's own arg
            ; setup clobbers D.
            plo     r8                  ; R8.0 = mr_receive's result

            mov     rd, mr_fcb_struct
            call    K_FILE_CLOSE        ; result/DF here intentionally
                                        ; ignored -- mr_receive's own
                                        ; result is what we report

            glo     r8
            lbnz    xfer_failed

            call    K_INMSG
            db      "File received.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

xfer_failed:
            ; D = mr_receive's numeric result code (1-3); print it
            ; alongside a generic message rather than maintaining three
            ; separate strings in this file too -- see mr_receive's own
            ; header comment for what each code means.
            adi     '0'
            plo     r8
            call    K_INMSG
            db      "Transfer failed (error ",0
            glo     r8
            call    K_TYPE
            call    K_INMSG
            db      ").",13,10,0
            ldi     1
            rtn

open_error:
            call    K_INMSG
            db      "Cannot create/open file.",13,10,0
            ldi     1
            rtn

mr_fcb_struct:  ds      FCB_LEN
mr_iobuf:       ds      FCB_IOBUF_LEN
mr_io_mode:     db      0

;==================================================================
; mr_receive: receive a file's contents over the console/serial port
; into an already-open FCB, using ELF-DOS's own MAX-derived transfer
; protocol.
;
; Args:    RD = FCB pointer of an already-open file (mode 1 -- write)
; Returns: D  = 0 on success, MRERR_* on failure (see equ's above)
;          DF = 0 on success, DF = 1 on failure (redundant with D,
;               kept for consistency with this project's other calls)
; Clobbers: everything except the FCB itself and whatever the caller
;          separately preserved -- this is a leaf worker, not a
;          register-preserving subroutine.
;
; Protocol (matches max-xfr's "-s" / send mode):
;   1. Host sends $55 (sync). We ACK with $AA.
;   2. Per block: host sends $01 (more data) or $00 (end of transfer).
;      A $01 is echoed back, then a 2-byte big-endian byte count and a
;      2-byte address field follow, each echoed as read. The address
;      field exists for compatibility with the underlying raw memory-
;      load wire format this protocol is derived from, but goes
;      unused here -- we're writing into a file, not a fixed memory
;      address. The data bytes themselves are NOT individually echoed
;      (throughput, see the readlp_uart/readlp_bitbang loop's own
;      comment below); we ACK with $AA once the whole block has been
;      written to the file.
;   3. On $00 (end of transfer), the host sends a final 'x', which we
;      just validate before returning -- no reply expected.
;
; Page-aligned (see .align below): mr_receive's whole body is well
; under 256 bytes, so aligning its start to a page boundary guarantees
; every branch within it -- readlp_uart/readlp_bitbang's hand-written
; short branches in particular -- are on the same page as their
; targets, regardless of where the rest of this program grows or
; shrinks around it. Confirmed necessary, not just theoretical: an
; earlier attempt without this alignment placed the receive loop's own
; branch straddling a page boundary at its real assembled position,
; which -r's own exclude-and-retry machinery correctly detected and
; left long rather than corrupting anything -- safe, but not the tight
; loop this needs. Alignment turns "usually fits" into "always fits."
;==================================================================

            .link   .align  page
            proc    mr_receive
            mov     rf, mr_handle
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; mr_handle = RD (the FCB
                                        ; pointer, received as this
                                        ; proc's own argument)

;------------------------------------------------------------------
; Handshake: wait for $55 (sync), ACK with $AA.
;------------------------------------------------------------------
            call    K_READ
            xri     $55
            lbz     mr_shake

            ldi     MRERR_HANDSHAKE
            lbr     mr_exit

mr_shake:   ldi     $aa
            call    K_TYPE

;------------------------------------------------------------------
; Per-block loop.
;
; mr_handle (not a register) holds the FCB pointer across K_FILE_WRITE
; calls: file_write uses RB as its own internal scratch (see
; progs/type.asm's own note), so nothing kept in a register here would
; reliably survive the call.
;------------------------------------------------------------------
mr_next:    call    K_READ
            lbz     mr_over             ; 0 = end of transfer

            ; BUG-CLASS GUARD: K_TYPE's register-preservation contract
            ; isn't independently confirmed beyond its documented D-in
            ; convention (see COPY's own overwrite-confirmation prompt,
            ; which stashes a char in memory rather than trusting any
            ; register across K_TTY/K_INMSG for the same reason) -- stash
            ; the command byte in memory, not a register, before echoing
            ; it, instead of assuming D survives the call.
            plo     rc                  ; RC.0 = command byte (temp,
                                        ; only needs to survive the mov
                                        ; below, no call yet)
            mov     rf, mr_cmdbyte
            glo     rc
            str     rf                  ; mr_cmdbyte = command byte

            ldn     rf                  ; D = command byte (rf still
                                        ; points at mr_cmdbyte)
            call    K_TYPE              ; echo it

            mov     rf, mr_cmdbyte
            ldn     rf                  ; D = command byte again
            smi     1
            lbz     mr_cmd01

            ldi     MRERR_COMMAND
            lbr     mr_exit

mr_cmd01:   call    K_READ
            ; BUG-CLASS GUARD: stash D (the byte just read) before "mov
            ; rf, ..." clobbers it -- needed twice below, once for the
            ; str and once for K_TYPE's echo (str itself doesn't touch
            ; D, so one reload covers both).
            plo     rc                  ; RC.0 = count high byte (temp)
            mov     rf, mr_cnt_hi
            glo     rc
            str     rf                  ; mr_cnt_hi = count high byte
            call    K_TYPE              ; echo it (D still = the byte)

            call    K_READ
            plo     rc                  ; RC.0 = count low byte (temp)
            mov     rf, mr_cnt_lo
            glo     rc
            str     rf                  ; mr_cnt_lo = count low byte (the
                                        ; FULL count -- not decremented)
            call    K_TYPE              ; echo it

            call    K_READ              ; address high byte (unused)
            call    K_TYPE

            call    K_READ              ; address low byte (unused)
            call    K_TYPE

            ; BUG-CLASS GUARD: reconstruct the byte count from memory,
            ; not a register -- R7 (originally used here to hold count
            ; hi/lo directly) is not confirmed to survive the two
            ; intervening K_READ/K_TYPE call pairs above (the discarded
            ; address hi/lo fields). Confirmed necessary, not just
            ; theoretical: this exact pattern -- a value cached in a
            ; register across multiple K_READ/K_TYPE calls -- is what
            ; caused ms.asm's own confirmed-on-hardware data corruption
            ; (RA, holding the send buffer's address, silently reset by
            ; something inside repeated K_READ/K_TYPE calls; see that
            ; file's header comment for the byte-exact evidence). Only
            ; R9's survival across f_msg/f_inmsg/f_idewrite has ever
            ; been confirmed (gotcha #8) -- R7 across K_READ/K_TYPE was
            ; never actually tested until this bug surfaced it.
            mov     rf, mr_cnt_hi
            ldn     rf
            phi     rc
            mov     rf, mr_cnt_lo
            ldn     rf
            plo     rc

            ; Which receive loop to use is decided once per block, here
            ; -- outside the tight loop itself, so neither variant pays
            ; a per-byte cost for the choice. Both movs happen before
            ; the mode is read into D, since mov itself clobbers D
            ; (gotcha #4) -- reading mr_io_mode any earlier here would
            ; just get stomped by the mov rf, mr_buf right after.
            ; UART is the fall-through (no branch) since it's the
            ; default/common case; bit-bang is the explicit branch.
            mov     rd, mr_io_mode
            mov     rf, mr_buf          ; RF = receive buffer
            dec     rc                  ; the loop below runs COUNT
                                        ; times when seeded with
                                        ; COUNT-1 (decrement, then loop
                                        ; while the high byte hasn't
                                        ; underflowed to $FF)
            ldn     rd                  ; D = io mode (fresh, after
                                        ; both movs above)
            xri     MR_IO_BITBANG
            lbz     readlp_bitbang

;------------------------------------------------------------------
; readlp_uart / readlp_bitbang: the one loop in this whole file that
; has to be fast. This runs once per incoming byte with no per-byte
; handshake from the host (only the block-level $AA ack throttles it),
; so at the top end of whichever transport is in use every extra
; instruction here is real risk of an overrun and a dropped byte -- a
; genuine short branch for the loop-back, not an lbnz left for -r to
; shrink after the fact. Safe specifically because of the .align page
; above: an earlier, unaligned attempt at this same short branch
; placed it straddling a page boundary at its real linked position
; (caught by link02, not silently wrong -- see the '<' fix noted
; below), which -r correctly left long rather than corrupt anything,
; but that's not the tight loop this needs. Page-aligning the whole
; proc guarantees every intra-proc branch fits on one page regardless
; of where the proc lands in the final program, so this can be
; hand-written short with confidence instead of hoping -r manages it.
;
; (Also caught a real link02 bug while chasing this down: a detected
; out-of-page short branch used to only print a warning and still
; write the corrupted output anyway. Now a hard link error instead,
; regardless of which path -- relaxed or plain -- finds it.)
;
; Both variants call their BIOS routine (f_uread/f_bread) directly
; instead of going through K_READ, skipping K_READ's own two
; indirection hops (the kernel jump table, then f_read's RAM-vector
; redirect through whatever "read" is currently patched to) -- see
; this file's top-of-file header comment for the motivation.
;------------------------------------------------------------------
readlp_uart:
            call    f_uread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     readlp_uart

            lbr     readlp_done

readlp_bitbang:
            call    f_bread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     readlp_bitbang

readlp_done:
            ; write the FULL (undecremented) block count to the file --
            ; reconstruct from memory, same reasoning as mr_cmd01 above
            mov     rf, mr_cnt_hi
            ldn     rf
            phi     rc
            mov     rf, mr_cnt_lo
            ldn     rf
            plo     rc
            mov     rf, mr_buf
            ; RD needs the FCB pointer, a 2-byte value stashed in
            ; mr_handle -- RB is the scratch address register used to
            ; fetch it, since RF/RC (buffer/count) are already set up
            ; and must stay untouched. RB is confirmed free here (not
            ; used anywhere in the read loops above).
            mov     rb, mr_handle
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = the FCB pointer
            call    K_FILE_WRITE        ; DF = 0/1
            lbdf    mr_wrerr

            ldi     $aa
            call    K_TYPE

            lbr     mr_next

mr_wrerr:   ldi     MRERR_WRITE
            lbr     mr_exit

mr_over:    call    K_READ
            xri     'x'
            lbz     mr_success

            ldi     MRERR_COMMAND
            lbr     mr_exit

mr_success: ldi     0

mr_exit:    ; D = result code (0 = success); set DF to match
            lbz     mr_ok
            stc
            lbr     mr_ret
mr_ok:      clc
mr_ret:     rtn

mr_handle:      dw      0           ; the FCB pointer (2 bytes -- was a
                                    ; 1-byte small-int handle)
mr_cmdbyte:     db      0
mr_cnt_hi:      db      0
mr_cnt_lo:      db      0
mr_buf:         ds      512
            endp

            end     start
