;
; edlin.asm - line editor for ELF-DOS
;
; Usage: EDLIN [filename]
;
; The filename is optional -- a bare "EDLIN" opens with a genuinely
; empty buffer (2026-07-31: this used to print a usage error and
; exit; real edlin doesn't require a filename at all). W and E (see
; their own shared header comment further down) both ALSO take an
; optional filename of their own: given, they write there (and
; establish it as the buffer's filename for later bare W/E calls);
; omitted, they fall back to whatever filename is already
; established. A buffer that's never had one -- opened empty and
; never through a W/E naming one explicitly -- needs an explicit name
; on the first W or E; using either with no name at that point is an
; error.
;
; A minimal MS-DOS-edlin-style line editor. Loads the whole named file
; into RAM as a flat text buffer (lines separated by a single LF byte,
; including one after the last line) plus a parallel table of 16-bit
; line-start offsets into that buffer -- classic edlin's own multi-
; segment paged-buffer scheme existed purely to cope with DOS-era
; memory limits that don't apply here, so this design just holds the
; whole file in RAM, which is both simpler and removes edlin's whole
; W/A (page write/append) command pair.
;
; ed_buf is NOT a fixed-size static buffer -- it's sized at runtime
; from LOADER_ARGS (mem_base..mem_top), using whatever RAM the board
; actually has, rather than a hardcoded/guessed capacity. This is the
; first real consumer of LOADER_ARGS in this codebase.
;
; Reads its own command/insert-mode lines into a LOCAL buffer
; (ed_input_buf), not the shell's shared LINE_BUF -- the filename
; argument (argv[1], reached via RA) points into LINE_BUF, and reusing
; it here would silently overwrite that text the first time this
; program's own command loop read a line. Using a separate buffer means
; the filename string never needs to survive anything more than being
; read once into ed_filename_ptr; the text itself, sitting untouched in
; LINE_BUF for the program's whole run, is never invalidated.
;
; v1 command set: L(ist), <n> (navigate/display), I(nsert), A(ppend --
; insert at end of file, ignores any leading line number), D(elete),
; E(nd -- save+exit), Q(uit without saving). Command letters and the
; Q confirmation are case-insensitive. Insert/append mode uses its own
; ": " prompt (distinct from the normal "*" command prompt) and ends on
; a line containing EXACTLY a single "." -- not a blank line, which
; instead inserts a real empty line, matching real edlin's own
; insert-mode terminator and letting blank lines be entered as content.
; A is just I with the target pre-set to line_count+1 -- same shared
; validate/prompt/loop, one implementation of the actual mechanics.
;
; v1.1 additions: L now takes an optional [n] or [n1,n2] range (a bare
; [n] lists just that one line, matching D's own single-number
; convention; no range still lists the whole file -- there's no paging
; UI on this hardware yet, so that's more useful here than DOS's
; classic 23-line default window). <n> (bare line number) now actually
; supports real edlin's own core behavior -- display the line, then
; prompt for a replacement; Enter alone leaves it unchanged, any real
; text replaces it. Replacement is implemented as insert-then-delete
; (insert the new text before the old line, then delete the old line,
; now shifted one position down) rather than delete-then-insert,
; deliberately -- if the buffer is too full for the replacement text,
; insert fails first and the original line is never touched, instead
; of being lost. New S[text] command: case-sensitive literal substring
; search over an optional [n] or [n1,n2] range (default: whole file),
; stops at and displays the first matching line, sets cur_line to it.
; D's own delete mechanics were factored out into a callable
; ed_delete_range (Args: ed_d_first/ed_d_last, already validated) so
; the new single-line-edit path can reuse them without duplicating the
; buffer/line-table shifting logic -- D's own command handler is
; otherwise byte-for-byte unchanged, just restructured from an inline
; jump into a call+return.
;
; See the project plan file for the full design writeup and what's
; still deliberately deferred: R(eplace), C(opy), M(ove), T(ransfer
; file), the "?" confirm-prompt flag, multi-line ranges beyond a plain
; n/n,m pair, dirty-flag tracking, chunked saves.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

            extrn   env_getenv
            extrn   env_parse_uint
            extrn   read_line_ex

ED_MAX_LINES:   equ     512         ; line-offset table capacity
ED_RDBUF_LEN:   equ     512         ; ed_getbyte's own read-ahead
                                    ; buffer, one K_FILE_READ call's
                                    ; worth -- matches FCB_IOBUF_LEN
                                    ; (one sector), the same size
                                    ; COPY_CHUNK_LEN settled on for the
                                    ; identical per-call-overhead reason
ED_PAGE_LINES:  equ     23          ; how many lines print before a
                                    ; pause; overridden by ROWS-1 if
                                    ; ROWS is set, see start's own env-
                                    ; reading block -- this ONLY
                                    ; controls pause frequency, not L's
                                    ; own default starting line (see
                                    ; ED_DEFAULT_LOOKBACK below).
                                    ; REVERTED (2026-07-31, user's own
                                    ; direct correction after testing
                                    ; the plain-ROWS version): a full
                                    ; screen's worth with NOTHING held
                                    ; back is wrong even with the pause
                                    ; itself silent -- printing the
                                    ; terminal's own next line of
                                    ; output (the "*" prompt after
                                    ; Ctrl-C, or the next page) once
                                    ; the screen is already completely
                                    ; full forces the TERMINAL to auto-
                                    ; scroll, which pushes whatever was
                                    ; on the top row off-screen. Holding
                                    ; back one line keeps the bottom
                                    ; row blank, so that scroll never
                                    ; needs to happen and the top of
                                    ; the page stays visible. Nothing
                                    ; to do with the old "-- More --"
                                    ; visible-prompt text at all -- nice
                                    ; try, wrong reason.
ED_DEFAULT_LOOKBACK: equ 11         ; L with no explicit range starts
                                    ; this many lines before cur_line,
                                    ; matching real edlin's own fixed
                                    ; behavior -- a FIXED constant,
                                    ; deliberately NOT derived from
                                    ; ed_page_lines (2026-07-31,
                                    ; corrected on the user's own
                                    ; direct instruction: the original
                                    ; implementation used page_lines/2
                                    ; here, so a ROWS-driven pause-
                                    ; frequency change also silently
                                    ; changed the default lookback --
                                    ; the two are unrelated settings
                                    ; and must not be coupled)

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1], if present, is the filename
            ; argument. BUG FIX (2026-07-31, hardware-reported): a
            ; bare "EDLIN" (no filename) used to print a usage error
            ; and exit -- real edlin instead opens with an empty
            ; buffer, letting W establish a filename later (see its
            ; own header comment).
            glo     rc
            smi     2
            lbnf    ed_no_filename      ; argc < 2: start empty, no
                                        ; filename set yet

            mov     rb, ra
            inc     rb
            inc     rb            ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (filename)

            ; stash the filename pointer -- the string itself stays
            ; valid in LINE_BUF for our whole run, since we never call
            ; K_INPUTL on that buffer (see header)
            mov     rb, ed_filename_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            lbr     ed_have_filename

ed_no_filename:
            mov     rf, ed_filename_ptr
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; ed_filename_ptr = 0 (NULL --
                                        ; ed_open_file below skips the
                                        ; whole open attempt when it
                                        ; sees this; E will refuse to
                                        ; save until W sets a real name)

ed_have_filename:
            ; ed_buf_start = mem_base, ed_buf_end = mem_top, both from
            ; LOADER_ARGS (word0/word1, big-endian -- see
            ; kernel/loader.asm's own _prog_finish_load, which writes
            ; them in exactly this layout)
            call    ed_ldw_rd
            dw      LOADER_ARGS  ; RD = mem_base
            call    ed_stw_rd
            dw      ed_buf_start

            mov     rf, LOADER_ARGS
            inc     rf
            inc     rf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            call    ed_stw_rd
            dw      ed_buf_end

            ; zero line_count / text_len / cur_line -- cur_line starts
            ; at 1 (not 0) so a bare "I" on a brand-new/empty file
            ; targets line 1, the only valid insertion point (1 ==
            ; line_count+1 when line_count is 0), with no special-
            ; casing needed anywhere else
            mov     rf, ed_line_count
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, ed_text_len
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, ed_cur_line
            ldi     0
            str     rf
            inc     rf
            ldi     1
            str     rf

            ; --- read ROWS from the environment for the L command's
            ; own paging (see ed_cmd_l/ed_list_loop below); falls back
            ; to ED_PAGE_LINES if ROWS is unset, non-numeric, or too
            ; small (<2, leaving no room after subtracting 1 -- see
            ; ED_PAGE_LINES's own comment for why one line is always
            ; held back, REVERTED 2026-07-31 after briefly removing
            ; this same "-1" and finding it wrong). Read once, here --
            ; RA/RC (entry argv/argc) are already fully consumed by
            ; this point, and nothing below needs anything
            ; env_getenv/env_parse_uint might clobber. ---
            mov     rf, ed_rows_name
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    ed_have_rows
            glo     rf
            lbz     ed_open_file        ; not set: keep the default

ed_have_rows:
            call    env_parse_uint      ; RD = parsed value
            ghi     rd
            lbnz    ed_rows_ok          ; high byte nonzero: >= 256,
                                        ; certainly >= 2
            ldi     2
            str     r2
            glo     rd
            sm                          ; D = RD.lo - 2, DF=1 iff
                                        ; RD.lo >= 2
            lbnf    ed_open_file        ; RD < 2: keep the default

ed_rows_ok:
            dec     rd            ; RD = ROWS - 1
            mov     rb, ed_page_lines
            glo     rd
            str     rb                  ; ed_page_lines = RD.lo

ed_open_file:
            ; --- open and load the file, if a filename was given at
            ; all (see start:'s own ed_no_filename path -- a NULL
            ; ed_filename_ptr means "start with a genuinely empty
            ; buffer", not "try to open a file named nothing") ---
            mov     rf, ed_filename_ptr
            ldn     rf
            lbnz    ed_open_file_real   ; high byte nonzero: have a name
            inc     rf
            ldn     rf
            lbz     ed_cmdloop          ; both bytes zero: no filename
                                        ; at all -- empty buffer, no
                                        ; open attempted

ed_open_file_real:
            call    ed_ldw_ra
            dw      ed_filename_ptr  ; RA = filename pointer
            mov     rf, ra              ; RF = filename (K_FILE_OPEN's
                                        ; own path argument)
            mov     rd, ed_fcb
            mov     ra, ed_iobuf
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; ed_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    ed_cmdloop          ; not found: start empty (new
                                        ; file) -- matches edlin's own
                                        ; behavior

            call    ed_load_file
            lbdf    ed_load_err

            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            lbr     ed_cmdloop

ed_load_err:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

;==================================================================
; File loading
;==================================================================

;------------------------------------------------------------------
; ed_load_file: read the open file (ed_fcb) into
; ed_buf/ed_lines via ed_getbyte (buffered -- see its own header),
; silently skipping CR and splitting on LF (same shape as
; kernel/batch.asm's own batch_readline this project already built
; and hardware-tested).
; Args:    none
; Returns: DF = 0 on success, DF = 1 on a real I/O error
;------------------------------------------------------------------
ed_load_file:
            call    ed_start_line
            lbdf    el_toolong

el_byte_loop:
            call    ed_getbyte
            lbdf    el_eof              ; DF=1: no more bytes -- could
                                        ; be true EOF or a real
                                        ; K_FILE_READ error, checked
                                        ; below

            plo     r7                  ; stash the byte -- xri below
                                        ; clobbers D, and re-reading it
                                        ; is now just a register move
                                        ; instead of a memory round
                                        ; trip through ed_scratch

            glo     r7
            xri     13                  ; CR?
            lbz     el_byte_loop        ; skip silently

            glo     r7
            xri     10                  ; LF?
            lbz     el_line_done

            glo     r7                  ; D = the real byte
            call    ed_append_byte
            lbdf    el_toolong
            lbr     el_byte_loop

el_line_done:
            ldi     10
            call    ed_append_byte      ; store the separator itself
            lbdf    el_toolong
            call    ed_finish_line
            call    ed_start_line
            lbdf    el_toolong
            lbr     el_byte_loop

el_eof:
            mov     rf, ed_getbyte_ioerr
            ldn     rf
            lbnz    el_err              ; a real I/O error, not true
                                        ; end-of-file

            ; a final line with no trailing newline still needs to be
            ; finished off (with its own separator) if it has any
            ; content at all
            call    ed_cur_line_has_bytes
            lbnf    el_done
            ldi     10
            call    ed_append_byte
            lbdf    el_toolong
            call    ed_finish_line
el_done:
            clc
            rtn

el_toolong:
            call    K_INMSG
            db      "File too large for EDLIN.",13,10,0
            stc
            rtn

el_err:
            stc
            rtn

;------------------------------------------------------------------
; ed_getbyte: return the next byte from the open file, refilling
; ed_rdbuf via one ED_RDBUF_LEN-sized K_FILE_READ call whenever it
; runs out, instead of a separate K_FILE_READ call per byte (the
; original design here -- roughly 7000 calls for a 7K file, each
; paying real per-call overhead, made loading noticeably slow on
; hardware; same root cause and fix shape as COPY_CHUNK_LEN's own
; 64->512 bump, see CLAUDE.md's performance-follow-up writeup).
; Args:    none
; Returns: D = byte, DF = 0 on success; DF = 1 when there's nothing
;          left -- either true EOF (ed_getbyte_ioerr left 0) or a
;          real K_FILE_READ error (ed_getbyte_ioerr set nonzero); the
;          caller distinguishes the two via that flag
; Modifies: RF, RA, RC, RD, R7 (and D, DF)
;------------------------------------------------------------------
ed_getbyte:
            call    ed_ldw_rd
            dw      ed_rdbuf_pos  ; RD = ed_rdbuf_pos
            call    ed_ldw_ra
            dw      ed_rdbuf_len  ; RA = ed_rdbuf_len

            glo     ra
            str     r2
            glo     rd
            sm
            ghi     ra
            str     r2
            ghi     rd
            smb
            lbdf    egb_refill          ; DF=1: pos >= len -- refill

            mov     rf, ed_rdbuf
            add16   rf, rd              ; RF = &ed_rdbuf[pos]
            ldn     rf                  ; D = the byte
            plo     r7                  ; stash it across the pos++
                                        ; below (mov/str clobber D)

            inc     rd            ; RD = pos+1
            call    ed_stw_rd
            dw      ed_rdbuf_pos  ; ed_rdbuf_pos = pos+1

            glo     r7                  ; D = the byte
            clc
            rtn

egb_refill:
            mov     rb, ed_getbyte_ioerr
            ldi     0
            str     rb                  ; assume no error until proven
                                        ; otherwise below

            mov     rf, ed_rdbuf
            ldi     low ED_RDBUF_LEN
            plo     rc
            ldi     high ED_RDBUF_LEN
            phi     rc                  ; RC = ED_RDBUF_LEN (512
                                        ; doesn't fit an 8-bit ldi --
                                        ; same low/high pattern
                                        ; loader.asm already uses for
                                        ; PROG_BASE)
            mov     rd, ed_fcb          ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at ed_rdbuf)
            call    K_FILE_READ         ; RC = actual bytes read,
                                        ; DF = 0/1 (real error)
            lbnf    egb_check_count
            mov     rb, ed_getbyte_ioerr
            ldi     1
            str     rb                  ; real I/O error, not EOF
            stc
            rtn

egb_check_count:
            glo     rc
            lbnz    egb_have_data
            ghi     rc
            lbnz    egb_have_data
            stc                         ; RC == 0: true end of file
                                        ; (ed_getbyte_ioerr already 0)
            rtn

egb_have_data:
            call    ed_stw_rc
            dw      ed_rdbuf_len  ; ed_rdbuf_len = RC

            mov     rf, ed_rdbuf_pos
            ldi     0
            str     rf
            inc     rf
            ldi     0
            str     rf                  ; ed_rdbuf_pos = 0

            lbr     ed_getbyte          ; retry -- pos(0) < len(RC>0)
                                        ; now, delivers the first byte
                                        ; of the freshly-read chunk

;------------------------------------------------------------------
; ed_append_byte: append one byte to ed_buf at the current end
; (ed_buf_start + ed_text_len), bounds-checked, then ed_text_len++.
; Args:    D = byte to append
; Returns: DF = 0 on success, DF = 1 if ed_buf is full
;------------------------------------------------------------------
ed_append_byte:
            plo     r9                  ; stash the byte (movs below
                                        ; clobber D)

            call    ed_ldw_rd
            dw      ed_buf_start  ; RD = ed_buf_start
            call    ed_ldw_r8
            dw      ed_text_len  ; R8 = ed_text_len
            add16   rd, r8              ; RD = write position (absolute)

            call    ed_ldw_r8
            dw      ed_buf_end  ; R8 = ed_buf_end

            ; DF=1 if write position >= ed_buf_end (no room)
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    eab_full

            mov     rf, rd
            glo     r9
            str     rf                  ; write the byte

            call    ed_ldw_rd
            dw      ed_text_len
            inc     rd
            call    ed_stw_rd
            dw      ed_text_len  ; ed_text_len++

            clc
            rtn

eab_full:
            stc
            rtn

;------------------------------------------------------------------
; ed_start_line: record ed_lines[ed_line_count] = ed_text_len (the
; offset where the line about to be read begins).
; Args:    none
; Returns: DF = 0 on success, DF = 1 if ed_line_count >= ED_MAX_LINES
;------------------------------------------------------------------
ed_start_line:
            call    ed_ldw_rd
            dw      ed_line_count  ; RD = ed_line_count

            ldi     low ED_MAX_LINES
            str     r2
            glo     rd
            sm
            ldi     high ED_MAX_LINES
            str     r2
            ghi     rd
            smb
            lbdf    esl_full            ; DF=1: line_count >= ED_MAX_LINES

            call    ed_ldw_r8
            dw      ed_text_len  ; R8 = ed_text_len

            shl16   rd                  ; RD = ed_line_count * 2
            mov     rf, ed_lines
            add16   rf, rd              ; RF = &ed_lines[ed_line_count]
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            clc
            rtn

esl_full:
            stc
            rtn

;------------------------------------------------------------------
; ed_finish_line: ed_line_count++
;------------------------------------------------------------------
ed_finish_line:
            call    ed_ldw_rd
            dw      ed_line_count
            inc     rd
            call    ed_stw_rd
            dw      ed_line_count
            rtn

;------------------------------------------------------------------
; ed_cur_line_has_bytes: does the line currently being read (started
; by the most recent ed_start_line) have any content yet?
; Returns: DF = 1 if ed_text_len > ed_lines[ed_line_count], else DF = 0
;------------------------------------------------------------------
ed_cur_line_has_bytes:
            call    ed_ldw_rd
            dw      ed_line_count  ; RD = ed_line_count
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ed_lines[ed_line_count]
                                        ; (this line's own start offset)

            call    ed_ldw_rd
            dw      ed_text_len  ; RD = ed_text_len

            ; BUG FIX (2026-07-31, hardware-reported): a plain sm/smb
            ; here (subtrahend=start_offset, minuend=text_len) yields
            ; DF=1 for text_len >= start_offset, not the strict ">"
            ; this function's own contract needs -- when they're
            ; EQUAL (an empty trailing line, the exact case this
            ; function exists to detect), the old code wrongly
            ; reported "has bytes", causing a spurious blank line to
            ; be appended every time a file ending in a real trailing
            ; newline was loaded. Fixed by also requiring the
            ; computed difference to be nonzero.
            glo     r8
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     r9                  ; R9 = text_len - start_offset,
                                        ; DF=1 iff text_len >= start_offset
            lbnf    echb_empty          ; DF=0: text_len < start_offset --
                                        ; shouldn't normally happen, but
                                        ; treat defensively as empty

            ghi     r9
            lbnz    echb_has_bytes
            glo     r9
            lbnz    echb_has_bytes      ; difference == 0: text_len ==
                                        ; start_offset -- empty line

echb_empty:
            clc
            rtn

echb_has_bytes:
            stc
            rtn

;==================================================================
; Shared line-info / block-move helpers
;==================================================================

;------------------------------------------------------------------
; ed_ldw_rd / ed_ldw_r8 / ed_ldw_r9 / ed_ldw_ra: load a 16-bit
; big-endian word from a FIXED memory address into RD/R8/R9/RA, where
; the address is encoded as 2 inline bytes ("dw SYMBOL") immediately
; following the "call ed_ldw_rX" instruction that invokes it -- the
; same R6 inline-operand SCRT idiom K_INMSG's own inline text already
; uses (see kernel/redir.asm's _redir_inmsg, hardware-confirmed on
; this exact mechanism), just for a fixed 2-byte address instead of a
; variable-length NUL-terminated string. At entry, R6 holds the
; address right after the 3-byte CALL instruction (the standard SCRT
; call convention -- the same fact _redir_inmsg's own kim_scan relies
; on) -- exactly where the 2 inline address bytes live. Since none of
; these four routines make any further call of their own, R6 is never
; at risk of being clobbered before RTN uses its current value to
; resume -- no explicit save/restore needed (unlike _redir_inmsg,
; which DOES make nested calls and must save/restore R6 around them).
; Replaces the old "mov rf, ADDR / lda rf / phi rX / ldn rf / plo rX"
; 5-instruction/10-byte inline shape -- this file's single most
; common block by far (220+ occurrences before this pass) -- with
; "call ed_ldw_rX" + "dw ADDR" (5 bytes): HALF the size per call
; site. Only ever applied where the ORIGINAL code used RF itself as
; the address pointer (never r8/r9/rd/rb) -- those alternate-register
; sites were left untouched, since choosing a non-RF pointer there
; was itself the signal that RF already held something else that
; needed to survive, which this routine's own internal RF use would
; have clobbered.
; Args (inline): 2 bytes = address of the word to load
; Returns: RD/R8/R9/RA = the word's value
; Modifies: RF (scratch), R6 (consumed as the inline-operand cursor;
;           left pointing at the real resume address for RTN)
;------------------------------------------------------------------
ed_ldw_rd:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            rtn

ed_ldw_r8:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            rtn

ed_ldw_r9:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            rtn

ed_ldw_ra:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            lda     rf
            phi     ra
            ldn     rf
            plo     ra
            rtn

;------------------------------------------------------------------
; ed_stw_rd / ed_stw_r8 / ed_stw_r9 / ed_stw_rc: store RD/R8/R9/RC's
; 16-bit value (big-endian) to a FIXED memory address, addressed the
; same inline-operand way ed_ldw_* above does -- see that block's own
; header comment for the full mechanism explanation; identical
; reasoning applies here (no nested calls, RF only ever used where
; the original inline code already treated it as dead, source
; register is only ever READ so it's untouched by the call).
; Args (inline): 2 bytes = address to store to
; Returns: nothing (the memory word is written)
; Modifies: RF (scratch), R6 (consumed as the inline-operand cursor)
;------------------------------------------------------------------
ed_stw_rd:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

ed_stw_r8:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            rtn

ed_stw_r9:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            rtn

ed_stw_rc:
            lda     r6
            phi     rf
            lda     r6
            plo     rf
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            rtn

;------------------------------------------------------------------
; ed_line_info: compute a line's absolute start pointer and byte
; length (excluding its trailing LF separator).
; Args:    RD = 0-based line index (must be < ed_line_count)
; Returns: ed_li_ptr = absolute pointer to the line's first byte
;          ed_li_len = length in bytes (0 for an empty line)
;------------------------------------------------------------------
ed_line_info:
            call    ed_stw_rd
            dw      ed_li_idx

            shl16   rd                  ; RD = index * 2
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = start offset

            call    ed_stw_r8
            dw      ed_li_start_off

            call    ed_ldw_rd
            dw      ed_li_idx
            inc     rd            ; RD = index+1

            call    ed_ldw_r9
            dw      ed_line_count

            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    eli_use_textlen     ; DF=1: index+1 >= line_count

            shl16   rd                  ; RD = (index+1) * 2
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = end offset
            lbr     eli_have_end

eli_use_textlen:
            call    ed_ldw_r9
            dw      ed_text_len  ; R9 = end offset (= ed_text_len)

eli_have_end:
            call    ed_ldw_rd
            dw      ed_buf_start  ; RD = ed_buf_start
            call    ed_ldw_r8
            dw      ed_li_start_off  ; R8 = start offset (reloaded)
            add16   rd, r8              ; RD = absolute start pointer

            call    ed_stw_rd
            dw      ed_li_ptr

            ; length = end - start - 1 (drop the trailing LF)
            glo     r8
            str     r2
            glo     r9
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     r9
            smb
            phi     rc                  ; RC = end - start

            glo     rc
            smi     1
            plo     rc
            lbdf    eli_no_borrow
            ghi     rc
            smi     1
            phi     rc
eli_no_borrow:
            call    ed_stw_rc
            dw      ed_li_len
            rtn

;------------------------------------------------------------------
; ed_copy_fwd: copy ed_mv_count bytes from ed_mv_src to ed_mv_dst,
; walking low-to-high. Safe when dst < src (closing a gap, e.g. after
; a delete).
;------------------------------------------------------------------
ed_copy_fwd:
            call    ed_ldw_rd
            dw      ed_mv_count
            ghi     rd
            lbnz    ecf_have
            glo     rd
            lbz     ecf_done
ecf_have:
            call    ed_ldw_rd
            dw      ed_mv_src
            mov     rf, rd
            ldn     rf
            plo     r9                  ; stash the byte

            call    ed_ldw_rd
            dw      ed_mv_dst
            mov     rf, rd
            glo     r9
            str     rf

            call    ed_ldw_rd
            dw      ed_mv_src
            inc     rd
            call    ed_stw_rd
            dw      ed_mv_src

            call    ed_ldw_rd
            dw      ed_mv_dst
            inc     rd
            call    ed_stw_rd
            dw      ed_mv_dst

            call    ed_ldw_rd
            dw      ed_mv_count
            dec     rd
            call    ed_stw_rd
            dw      ed_mv_count

            lbr     ed_copy_fwd
ecf_done:
            rtn

;------------------------------------------------------------------
; ed_copy_bwd: copy ed_mv_count bytes, working from the end of the
; range backward. Safe when dst > src (opening a gap, e.g. before an
; insert). ed_mv_src/ed_mv_dst stay fixed at the ranges' own starts;
; the actual write positions are recomputed fresh each iteration as
; (start + count - 1), so no separate "current position" needs to
; survive across anything.
;------------------------------------------------------------------
ed_copy_bwd:
            call    ed_ldw_rd
            dw      ed_mv_count
            ghi     rd
            lbnz    ecb_have
            glo     rd
            lbz     ecb_done
ecb_have:
            call    ed_ldw_rd
            dw      ed_mv_src
            call    ed_ldw_r8
            dw      ed_mv_count
            add16   rd, r8
            dec     rd            ; RD = src_end
            mov     rf, rd
            ldn     rf
            plo     r9                  ; stash the byte

            call    ed_ldw_rd
            dw      ed_mv_dst
            call    ed_ldw_r8
            dw      ed_mv_count
            add16   rd, r8
            dec     rd            ; RD = dst_end
            mov     rf, rd
            glo     r9
            str     rf

            call    ed_ldw_rd
            dw      ed_mv_count
            dec     rd
            call    ed_stw_rd
            dw      ed_mv_count

            lbr     ed_copy_bwd
ecb_done:
            rtn

;------------------------------------------------------------------
; ed_strlen: Args: RF = null-terminated string. Returns: RD = length.
;------------------------------------------------------------------
ed_strlen:
            ldi     0
            phi     rd
            plo     rd
estr_loop:
            ldn     rf
            lbz     estr_done
            inc     rf
            inc     rd
            lbr     estr_loop
estr_done:
            rtn

;------------------------------------------------------------------
; ed_print_line: print a line's raw text (no trailing newline).
; Args:    RD = 0-based line index
;------------------------------------------------------------------
ed_print_line:
            call    ed_line_info

            call    ed_ldw_rd
            dw      ed_li_ptr
            mov     rf, rd              ; RF = absolute start pointer
                                        ; (using RF, not RD, to survive
                                        ; K_TYPE -- matches
                                        ; progs/type.asm's own
                                        ; hardware-confirmed pattern)

            mov     rd, ed_li_len
            lda     rd
            phi     rc
            ldn     rd
            plo     rc                  ; RC = length

epl_loop:
            ghi     rc
            lbnz    epl_have
            glo     rc
            lbz     epl_done
epl_have:
            lda     rf
            call    K_TYPE
            glo     rc
            lbnz    epl_dec_lo
            ghi     rc
            smi     1
            phi     rc
epl_dec_lo:
            glo     rc
            smi     1
            plo     rc
            lbr     epl_loop
epl_done:
            rtn

;==================================================================
; Command loop
;==================================================================

ed_cmdloop:
            call    K_INMSG
            db      "*",0
            mov     rf, ed_input_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc
            ldi     LE_MODE_REDIR       ; K_READ-based, redirect-aware
                                        ; -- this call site's own DF
                                        ; check below depends on it
            call    read_line_ex
            lbdf    ed_eof_quit         ; DF=1: redirected input is
                                        ; exhausted (e.g. `<NUL`, or a
                                        ; real script that's run out)
                                        ; -- stop here instead of
                                        ; spinning forever re-reading
                                        ; nothing; unsaved edits are
                                        ; abandoned, matching Q's own
                                        ; no-save exit (there's no live
                                        ; user left to confirm a Y/N
                                        ; prompt with)
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_input_buf
            call    f_ltrim

            ldn     rf
            lbz     ed_cmdloop          ; empty line: re-prompt

            call    ed_parse_range      ; RF advances past any number(s)

            ldn     rf
            lbz     ed_bare_number      ; nothing after the number(s)

            ; optional "?" confirm flag, between the range and the
            ; command letter (matches FreeDOS edlin's own
            ; "[#][,#][?]s$" syntax -- currently only S looks at this,
            ; other commands simply ignore it)
            mov     rb, ed_have_confirm
            ldi     0
            str     rb                  ; ed_have_confirm = 0 (reset
                                        ; every pass)

            ldn     rf
            xri     '?'
            lbnz    ed_after_confirm
            inc     rf                  ; consume the '?'
            mov     rb, ed_have_confirm
            ldi     1
            str     rb

ed_after_confirm:
            ldn     rf
            ani     $DF
            xri     'L'
            lbz     ed_cmd_l

            ldn     rf
            ani     $DF
            xri     'I'
            lbz     ed_cmd_i

            ldn     rf
            ani     $DF
            xri     'A'
            lbz     ed_cmd_a

            ldn     rf
            ani     $DF
            xri     'D'
            lbz     ed_cmd_d

            ldn     rf
            ani     $DF
            xri     'E'
            lbz     ed_cmd_e

            ldn     rf
            ani     $DF
            xri     'Q'
            lbz     ed_cmd_q

            ldn     rf
            ani     $DF
            xri     'S'
            lbz     ed_cmd_s

            ldn     rf
            ani     $DF
            xri     'P'
            lbz     ed_cmd_p

            ldn     rf
            ani     $DF
            xri     'T'
            lbz     ed_cmd_t

            ldn     rf
            ani     $DF
            xri     'R'
            lbz     ed_cmd_r

            ldn     rf
            ani     $DF
            xri     'C'
            lbz     ed_cmd_c

            ldn     rf
            ani     $DF
            xri     'M'
            lbz     ed_cmd_m

            ldn     rf
            ani     $DF
            xri     'W'
            lbz     ed_cmd_w

ed_unknown_cmd:
            call    K_INMSG
            db      "? Unknown command.",13,10,0
            lbr     ed_cmdloop

ed_num_range_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_parse_range: parse up to four comma-separated line references
; ("N", "N,M", "N,,O", "N,,O,P", etc. -- any slot may be left BLANK
; between two commas, matching real edlin's own skip-a-parameter
; shorthand, e.g. ",,10,3" for C's "default first, default last,
; target 10, repeat 3"). Each present N/M/O/P is anything
; ed_parse_lineref accepts (a literal number, '.', '$', '#', or a
; "+n"/"-n" relative form). Every command here except C only ever
; looks at n1/n2 -- n3/n4 exist purely for C's own
; "first,last,target,count" syntax (M uses n1-n3 the same way,
; target in n3, no count). A blank slot leaves its own have_nX flag
; at 0 (letting each command apply its own default) but does NOT
; stop the scan -- only the ABSENCE of a further comma does. This is
; a pure generalization of the original "N,M" parser: D/L/R/S/etc.,
; which never type more than 2 numbers and never leave a slot
; blank, see identical behavior to before.
; Args:    RF = current parse position
; Returns: RF advanced past everything parsed; ed_have_n1..n4/
;          ed_n1..n4 set accordingly
;------------------------------------------------------------------
ed_parse_range:
            mov     rb, ed_have_n1
            ldi     0
            str     rb
            mov     rb, ed_have_n2
            ldi     0
            str     rb
            mov     rb, ed_have_n3
            ldi     0
            str     rb
            mov     rb, ed_have_n4
            ldi     0
            str     rb

            call    ed_parse_lineref
            lbdf    epr_check1          ; failed: n1 stays blank, but
                                        ; still check for a comma --
                                        ; only a bare command (no
                                        ; comma either) truly stops here

            mov     rb, ed_have_n1
            ldi     1
            str     rb
            mov     rb, ed_n1
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

epr_check1:
            ldn     rf
            xri     ','
            lbnz    epr_done
            inc     rf                  ; skip the comma

            call    ed_parse_lineref
            lbdf    epr_check2

            mov     rb, ed_have_n2
            ldi     1
            str     rb
            mov     rb, ed_n2
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

epr_check2:
            ldn     rf
            xri     ','
            lbnz    epr_done
            inc     rf

            call    ed_parse_lineref
            lbdf    epr_check3

            mov     rb, ed_have_n3
            ldi     1
            str     rb
            mov     rb, ed_n3
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

epr_check3:
            ldn     rf
            xri     ','
            lbnz    epr_done
            inc     rf

            call    ed_parse_lineref
            lbdf    epr_done            ; slot 4 is last -- success or
                                        ; failure, nothing follows it

            mov     rb, ed_have_n4
            ldi     1
            str     rb
            mov     rb, ed_n4
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

epr_done:
            rtn

;------------------------------------------------------------------
; ed_parse_lineref: parse a FreeDOS-style line reference at RF -- a
; literal decimal number, or one of '.' (current line), '$' (last
; line), '#' (one past the last line) -- optionally followed by a
; "+n"/"-n" relative modifier (".+1", "$-2", or a bare "+3"/"-3",
; which implicitly bases off the current line, matching real edlin).
; Deliberately does NOT range-check the result -- every caller already
; validates the returned value against 0/line_count itself, so a "-n"
; that underflows past 0 just wraps into an obviously-too-large
; unsigned value and gets rejected by those same, already-existing
; checks; no separate clamping needed here.
; Args:    RF = position
; Returns: DF = 0 with RD = value, RF advanced past everything parsed;
;          DF = 1 if nothing recognized at RF at all (RF unchanged)
; Modifies: RD, R8, R9 (RF is the parse cursor -- see epl_* below,
;           which deliberately use R8, never RF, as scratch when
;           reading ed_cur_line/ed_line_count, so RF is never at risk
;           of being clobbered mid-parse)
;------------------------------------------------------------------
ed_parse_lineref:
            ldn     rf
            xri     '.'
            lbz     epl_cur
            ldn     rf
            xri     '$'
            lbz     epl_last
            ldn     rf
            xri     '#'
            lbz     epl_onepast

            call    ed_parse_uint       ; plain digit string?
            lbnf    epl_modifier        ; got one -- RD = base value

            ; no base at all -- a bare "+n"/"-n" implicitly means
            ; "relative to the current line" (real edlin's own ".+1"
            ; shorthand)
            ldn     rf
            xri     '+'
            lbz     epl_bare_sign
            ldn     rf
            xri     '-'
            lbz     epl_bare_sign
            stc
            rtn                         ; nothing recognized at all

epl_cur:
            inc     rf                  ; consume '.'
            mov     r8, ed_cur_line
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = ed_cur_line
            lbr     epl_modifier

epl_last:
            inc     rf                  ; consume '$'
            mov     r8, ed_line_count
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = ed_line_count
            lbr     epl_modifier

epl_onepast:
            inc     rf                  ; consume '#'
            mov     r8, ed_line_count
            lda     r8
            phi     rd
            ldn     r8
            plo     rd
            inc     rd            ; RD = ed_line_count + 1
            lbr     epl_modifier

epl_bare_sign:
            ; RF is NOT advanced here -- the sign itself is still
            ; unconsumed, and epl_modifier below (reached via
            ; fallthrough) is what recognizes and consumes it
            mov     r8, ed_cur_line
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = ed_cur_line

epl_modifier:
            ldn     rf
            xri     '+'
            lbz     epl_plus
            ldn     rf
            xri     '-'
            lbz     epl_minus
            clc
            rtn                         ; no modifier -- RD = base, DF=0

epl_plus:
            inc     rf                  ; consume '+'
            ghi     rd
            phi     r9
            glo     rd
            plo     r9                  ; R9 = base (staged for the
                                        ; add below)

            ; ALSO stash to memory: R9 does NOT survive the
            ; ed_parse_uint call immediately below -- real bug,
            ; hardware-found 2026-07-31. ed_parse_uint's own digit
            ; loop uses R9.0 as its own internal scratch (see that
            ; routine's own body: "plo r9 ; stash the digit value"),
            ; silently clobbering whatever the caller had stored
            ; there. Symptom: "+5" from any current line landed on
            ; line 10 (2*5, not cur_line+5) -- R9.0 ended up holding
            ; the offset's own last digit instead of the base's real
            ; low byte. Reloaded fresh from memory right after the
            ; call returns instead of trusting the register across
            ; it (this project's own standing gotcha #10 discipline:
            ; don't trust a register across a call whose body you
            ; haven't checked).
            mov     r8, ed_lineref_base
            ghi     r9
            str     r8
            inc     r8
            glo     r9
            str     r8

            call    ed_parse_uint       ; RD = offset digits, if any
            lbnf    epl_plus_reload
            ldi     0
            phi     rd
            plo     rd                  ; no digits after '+': offset=0
epl_plus_reload:
            mov     r8, ed_lineref_base
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = base (reloaded from
                                        ; memory, undoing whatever
                                        ; ed_parse_uint left behind)

epl_plus_add:
            glo     r9
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r9
            str     r2
            ghi     rd
            adc
            phi     rd                  ; RD = base + offset
            clc
            rtn

epl_minus:
            inc     rf                  ; consume '-'
            ghi     rd
            phi     r9
            glo     rd
            plo     r9                  ; R9 = base (staged for the
                                        ; subtract below)

            ; ALSO stash to memory -- same R9-across-ed_parse_uint
            ; hazard as epl_plus above (see its own comment for the
            ; full explanation)
            mov     r8, ed_lineref_base
            ghi     r9
            str     r8
            inc     r8
            glo     r9
            str     r8

            call    ed_parse_uint       ; RD = offset digits, if any
            lbnf    epl_minus_reload
            ldi     0
            phi     rd
            plo     rd                  ; no digits after '-': offset=0
epl_minus_reload:
            mov     r8, ed_lineref_base
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = base (reloaded from
                                        ; memory)

epl_minus_sub:
            ; R8 = base - offset (R9 - RD); computed into R8 since RD
            ; itself supplies operands to both halves of the subtract
            glo     rd
            str     r2
            glo     r9
            sm
            plo     r8
            ghi     rd
            str     r2
            ghi     r9
            smb
            phi     r8
            mov     rd, r8              ; RD = base - offset
            clc
            rtn

;------------------------------------------------------------------
; ed_parse_uint: parse a plain decimal number at RF. Private helper
; for ed_parse_lineref (both the base-value and modifier-offset
; cases) -- not called directly by anything else.
; Args:    RF = position
; Returns: DF = 0 with RD = value, RF advanced past the digits;
;          DF = 1 if no digit at RF (RF unchanged)
;------------------------------------------------------------------
ed_parse_uint:
            ldn     rf
            smi     '0'
            lbnf    epn_none
            ldn     rf
            smi     '9'+1
            lbdf    epn_none

            ldi     0
            phi     rd
            plo     rd

epn_loop:
            ldn     rf
            smi     '0'
            lbnf    epn_done
            ldn     rf
            smi     '9'+1
            lbdf    epn_done

            ldn     rf
            smi     '0'
            plo     r9                  ; stash the digit value

            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = RD (copy, for the *2 term)
            shl16   rd
            shl16   rd
            shl16   rd                  ; RD = RD * 8
            add16   rd, r8
            add16   rd, r8              ; RD = RD*8 + RD*2 = RD*10

            glo     r9
            str     r2
            glo     rd
            add
            plo     rd
            ghi     rd
            adci    0
            phi     rd                  ; RD += digit

            inc     rf
            lbr     epn_loop

epn_done:
            clc
            rtn

epn_none:
            stc
            rtn

;------------------------------------------------------------------
; ed_bare_number: a line consisting of just a number -- navigate to
; and display that line.
;------------------------------------------------------------------
ed_bare_number:
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_unknown_cmd

            call    ed_ldw_rd
            dw      ed_n1  ; RD = n1

            ghi     rd
            lbnz    ed_num_range_err
            glo     rd
            lbz     ed_num_range_err    ; n1 == 0: invalid

            call    ed_ldw_r8
            dw      ed_line_count

            ; line_count >= n1 ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_num_range_err

            mov     rf, ed_cur_line
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            call    ed_ldw_rd
            dw      ed_n1
            dec     rd            ; RD = n1 - 1 (0-based index)
            call    ed_print_line
            call    K_INMSG
            db      13,10,0

            ; prompt for a replacement -- Enter alone leaves the line
            ; unchanged (matches real edlin's own single-line-edit
            ; behavior); any real text replaces it
            call    K_INMSG
            db      ": ",0
            mov     rf, ed_input_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc
            ldi     LE_MODE_REDIR       ; DF deliberately ignored here,
                                        ; matching the original
                                        ; K_INPUTL usage -- an EOF at
                                        ; this exact prompt already
                                        ; falls through to "leave the
                                        ; line unchanged" below, and
                                        ; ed_cmdloop's own DF check
                                        ; catches the real EOF on its
                                        ; very next read (see this
                                        ; file's own header/CLAUDE.md
                                        ; for the full reasoning)
            call    read_line_ex
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_input_buf
            ldn     rf
            lbz     ed_cmdloop          ; empty: leave line unchanged

            ; replace line n1 by inserting the new text just before it,
            ; then deleting the old line (now shifted to n1+1) --
            ; insert-then-delete, not delete-then-insert, so a "buffer
            ; full" failure leaves the original line completely intact
            ; instead of losing it
            call    ed_ldw_rd
            dw      ed_n1  ; RD = n1 (1-based, already
                                        ; range-validated above)
            call    ed_stw_rd
            dw      ed_i_target

            mov     rf, ed_input_buf
            call    ed_strlen
            call    ed_stw_rd
            dw      ed_i_text_len

            mov     rf, ed_i_source_buf
            ldi     high ed_input_buf
            str     rf
            inc     rf
            ldi     low ed_input_buf
            str     rf

            call    ed_insert_one
            lbdf    ed_edit_toolong

            call    ed_ldw_rd
            dw      ed_n1
            inc     rd            ; RD = n1+1 (old line's new
                                        ; 1-based position, after the
                                        ; insert shifted it down)
            call    ed_stw_rd
            dw      ed_d_first
            call    ed_stw_rd
            dw      ed_d_last

            call    ed_delete_range

            mov     rf, ed_cur_line
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; cur_line = n1 (the edited
                                        ; line's final position)

            lbr     ed_cmdloop

ed_edit_toolong:
            call    K_INMSG
            db      "Buffer full.",13,10,0
            lbr     ed_cmdloop

;==================================================================
; L - list, P - print
;==================================================================
;
; FreeDOS parity: both share the exact same "[first][,last]" handling
; below -- when an explicit range is given, L and P behave IDENTICALLY
; (start at first, end at last if given, else a page from first). They
; differ ONLY in what "no first parameter at all" defaults to: L
; starts (page_lines/2) lines before the current line (the classic
; "11 lines before" default when page_lines is the 23-line default --
; scaled here rather than hard-coded 11, so a ROWS-overridden page
; size keeps the same "roughly centered on cur_line" effect); P starts
; AT the current line. Neither command lists the WHOLE file by
; default any more -- that was this project's own pre-parity design,
; not real edlin's.

ed_cmd_l:
            mov     rf, ed_have_n1
            ldn     rf
            lbnz    ed_lp_n1_given      ; explicit range: shared path

            ; default first = cur_line - ED_DEFAULT_LOOKBACK (a fixed
            ; constant, deliberately NOT ed_page_lines/2 -- see that
            ; equ's own comment for why), clamped >= 1
            ldi     0
            phi     r9
            ldi     ED_DEFAULT_LOOKBACK
            plo     r9                  ; R9 = fixed lookback offset

            mov     r8, ed_cur_line
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = cur_line

            glo     r9
            str     r2
            glo     rd
            sm
            plo     r8
            ghi     r9
            str     r2
            ghi     rd
            smb
            phi     r8                  ; R8 = cur_line - lookback
                                        ; (may have wrapped/underflowed)
            lbnf    ed_l_clamp_to_1     ; DF=0: borrow -- cur_line was
                                        ; less than the lookback offset
            ghi     r8
            lbnz    ed_lp_have_default
            glo     r8
            lbnz    ed_lp_have_default
ed_l_clamp_to_1:
            ldi     0
            phi     r8
            ldi     1
            plo     r8                  ; clamp to line 1
            lbr     ed_lp_have_default

ed_cmd_p:
            mov     rf, ed_have_n1
            ldn     rf
            lbnz    ed_lp_n1_given      ; explicit range: shared path

            ; default first = cur_line (always already >= 1, no clamp
            ; needed)
            mov     r8, ed_cur_line
            lda     r8
            phi     rd
            ldn     r8
            plo     rd
            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = cur_line

ed_lp_have_default:
            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = default first
            mov     rf, ed_list_i
            dec     rd            ; RD = first - 1 (0-based start)
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = first (restore, 1-based)
            call    ed_list_clamp_last  ; RD = last (first+page-1,
                                        ; clamped to line_count)
            call    ed_stw_rd
            dw      ed_list_last
            lbr     ed_list_start

ed_lp_n1_given:
            call    ed_ldw_rd
            dw      ed_n1  ; RD = n1 (1-based)

            ghi     rd
            lbnz    ed_l_n1_ok
            glo     rd
            lbz     ed_l_err            ; n1 == 0: invalid
ed_l_n1_ok:
            call    ed_ldw_r8
            dw      ed_line_count  ; R8 = line_count

            ; line_count >= n1 ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_l_err

            mov     rf, ed_list_i
            dec     rd            ; RD = n1 - 1 (0-based start)
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_l_single         ; only n1: a page starting there

            call    ed_ldw_rd
            dw      ed_n2  ; RD = n2 (1-based)

            ghi     rd
            lbnz    ed_l_n2_ok
            glo     rd
            lbz     ed_l_err            ; n2 == 0: invalid
ed_l_n2_ok:
            ; line_count >= n2 ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_l_err

            call    ed_stw_rd
            dw      ed_list_last
            lbr     ed_list_start

ed_l_single:
            call    ed_ldw_rd
            dw      ed_n1  ; RD = n1 (1-based, already
                                        ; validated above)
            call    ed_list_clamp_last  ; RD = min(n1+page-1, line_count)
            call    ed_stw_rd
            dw      ed_list_last
            lbr     ed_list_start

ed_l_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_list_clamp_last: given RD = first (1-based; may legitimately be
; line_count+1, e.g. an empty file -- that just yields an empty list),
; compute RD = min(first + page_lines - 1, line_count) -- L/P's own
; "no explicit end line" default, a single page starting at first.
; Args:    RD = first
; Returns: RD = last
;------------------------------------------------------------------
ed_list_clamp_last:
            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = first (stashed across
                                        ; the page_lines read below)
            mov     r9, ed_page_lines
            ldn     r9
            plo     r9
            ldi     0
            phi     r9                  ; R9 = page_lines (16-bit)

            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = first (restored)
            add16   rd, r9
            dec     rd            ; RD = first + page_lines - 1

            mov     r9, ed_line_count
            lda     r9
            phi     r8
            ldn     r9
            plo     r8                  ; R8 = line_count

            ; candidate (RD) >= line_count (R8) ?
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbnf    elcl_done           ; DF=0: candidate < line_count,
                                        ; keep RD as-is

            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = line_count (clamped)
elcl_done:
            rtn

ed_list_start:
            mov     rf, ed_list_page_count
            ldi     0
            str     rf                  ; reset the page counter --
                                        ; once, here, before the loop
                                        ; begins (NOT inside the loop
                                        ; itself, which also reaches
                                        ; ed_list_loop directly via its
                                        ; own back-edge below)

            ; stash the STARTING index (0-based) so ed_list_finish can
            ; tell "at least one line was actually shown" from "the
            ; range was empty from the start" -- only the former
            ; should update ed_cur_line (2026-07-31, hardware-reported:
            ; L/P never updated ed_cur_line at all, which is also the
            ; real cause behind "+n"/"-n" line-refs on a later command
            ; appearing to compute from the wrong base -- they were
            ; correct all along, just relative to a STALE cur_line
            ; that the previous L/P never advanced)
            call    ed_ldw_rd
            dw      ed_list_i
            call    ed_stw_rd
            dw      ed_list_start_i

ed_list_loop:
            call    ed_ldw_rd
            dw      ed_list_i
            call    ed_ldw_r8
            dw      ed_list_last

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_list_finish      ; list_i >= list_last: done

            call    ed_ldw_rd
            dw      ed_list_i
            inc     rd            ; RD = 1-based line number
            mov     rf, ed_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ed_num_buf
            call    K_MSG
            call    K_INMSG
            db      ": ",0

            call    ed_ldw_rd
            dw      ed_list_i  ; RD = list_i (0-based, for
                                        ; ed_print_line)
            call    ed_print_line
            call    K_INMSG
            db      13,10,0

            call    ed_ldw_rd
            dw      ed_list_i
            inc     rd
            call    ed_stw_rd
            dw      ed_list_i

            ; --- pause every ed_page_lines lines, fully silent (no
            ; "-- More --" text, no key echo) -- redesigned 2026-07-31
            ; per hardware testing/explicit request, replacing the
            ; more.asm-style visible prompt this was originally
            ; modeled on. Any key EXCEPT Ctrl-C ($03) continues at the
            ; same line; Ctrl-C stops the listing early via the same
            ; ed_list_finish exit reaching the end normally uses. ---
            mov     rf, ed_list_page_count
            ldn     rf
            adi     1
            str     rf                  ; ed_list_page_count++

            mov     rf, ed_page_lines
            ldn     rf                  ; D = threshold
            str     r2
            mov     rf, ed_list_page_count
            ldn     rf                  ; D = current count
            sm                          ; D = count - threshold, DF=1
                                        ; iff count >= threshold
            lbnf    ed_list_loop        ; not yet a full page

            mov     rf, ed_list_page_count
            ldi     0
            str     rf                  ; reset the page counter

            call    K_READ              ; D = key pressed (blocking) --
                                        ; no prompt printed, not echoed
            xri     3                   ; Ctrl-C?
            lbz     ed_list_finish      ; stop early -- same exit as
                                        ; reaching the end of the range

            lbr     ed_list_loop

;------------------------------------------------------------------
; ed_list_finish: shared exit for L/P, reached either by listing the
; whole requested range or by an early Ctrl-C during a pause. Sets
; ed_cur_line to the last line actually displayed -- but only if at
; least one line was (an empty range must leave cur_line untouched).
;------------------------------------------------------------------
ed_list_finish:
            call    ed_ldw_rd
            dw      ed_list_i  ; RD = list_i (0-based "next"
                                        ; index -- equals the 1-based
                                        ; line number of whatever was
                                        ; last actually shown, if
                                        ; anything was)

            call    ed_ldw_r8
            dw      ed_list_start_i  ; R8 = starting index (0-based)

            ; want: skip the update iff list_i <= start_i (strict "<="
            ; test) -- staging list_i (RD) as subtrahend and loading
            ; start_i (R8) last as minuend gives D = start_i - list_i;
            ; DF=1 (no borrow) means start_i >= list_i, i.e. list_i <=
            ; start_i (nothing shown, skip). Caught during review,
            ; before ever assembling: a first draft staged the wrong
            ; operand here and reproduced the EXACT off-by-one bug
            ; class this whole session's fixes were for (list_i ==
            ; start_i, the common "nothing shown" case, would have
            ; been misread as "something was shown").
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbdf    ed_cmdloop          ; DF=1: list_i <= start_i --
                                        ; nothing was ever shown, leave
                                        ; ed_cur_line untouched

            call    ed_stw_rd
            dw      ed_cur_line
            lbr     ed_cmdloop

;==================================================================
; A - append (insert at end of file)
;==================================================================

; A leading line number, if any, was already parsed by ed_parse_range
; but is deliberately ignored here -- append always targets the very
; end of the file, unlike I (which defaults to cur_line). Reuses the
; same validate/prompt/loop as I, just with the target pre-set, so the
; append/insert mechanics themselves have exactly one implementation.
ed_cmd_a:
            call    ed_ldw_rd
            dw      ed_line_count
            inc     rd            ; RD = line_count + 1 (append
                                        ; position -- always valid,
                                        ; ed_i_validate's range check
                                        ; is a no-op here but reusing
                                        ; it costs nothing)
            call    ed_stw_rd
            dw      ed_i_target
            lbr     ed_i_validate

;==================================================================
; I - insert
;==================================================================

ed_cmd_i:
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_i_use_cur

            mov     rf, ed_i_target
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_i_validate

ed_i_use_cur:
            mov     rf, ed_i_target
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ed_i_validate:
            call    ed_validate_insert_target
            lbdf    ed_i_err

            call    K_INMSG
            db      "Insert (. to end):",13,10,0

ed_i_loop:
            call    K_INMSG
            db      ": ",0
            mov     rf, ed_input_buf
            ldi     127
            plo     rc
            ldi     0
            phi     rc
            ldi     LE_MODE_REDIR
            call    read_line_ex
            lbdf    ed_i_done           ; DF=1: redirected input
                                        ; exhausted mid-insert -- treat
                                        ; it the same as the "."
                                        ; terminator (end insert mode,
                                        ; return to the command prompt)
                                        ; rather than silently
                                        ; inserting blank lines until
                                        ; the buffer fills
            call    K_INMSG
            db      13,10,0

            ; end-of-insert marker: a line consisting of EXACTLY a
            ; single "." (matches real edlin's own insert-mode
            ; terminator, and the distinct ": " prompt above matches
            ; its visual cue for "in text-entry mode"). Blank lines are
            ; no longer special-cased as a terminator -- they fall
            ; through and get inserted as real (empty) lines, which
            ; ed_insert_one already handles correctly with no changes
            ; needed (a zero-length line just writes its own separator).
            mov     rf, ed_input_buf
            ldn     rf
            xri     '.'
            lbnz    ed_i_not_dot
            inc     rf
            ldn     rf
            lbnz    ed_i_not_dot
            lbr     ed_i_done           ; exactly "." and nothing else
ed_i_not_dot:

            mov     rf, ed_input_buf
            call    ed_strlen
            call    ed_stw_rd
            dw      ed_i_text_len

            mov     rf, ed_i_source_buf
            ldi     high ed_input_buf
            str     rf
            inc     rf
            ldi     low ed_input_buf
            str     rf

            call    ed_insert_one
            lbdf    ed_i_toolong

            call    ed_ldw_rd
            dw      ed_i_target
            inc     rd
            call    ed_stw_rd
            dw      ed_i_target

            lbr     ed_i_loop

ed_i_toolong:
            call    K_INMSG
            db      "Buffer full.",13,10,0
ed_i_done:
            lbr     ed_cmdloop

ed_i_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_validate_insert_target: is ed_i_target a legal insertion point
; (1 <= target <= line_count+1)? Shared by I/A's own validate-then-
; prompt path and T's validate-then-transfer path -- factored out so
; both go through exactly one range check.
; Args:    ed_i_target (read only, never modified)
; Returns: DF = 0 if valid, DF = 1 if not
;------------------------------------------------------------------
ed_validate_insert_target:
            call    ed_ldw_rd
            dw      ed_i_target
            ghi     rd
            lbnz    evit_nonzero
            glo     rd
            lbz     evit_bad
evit_nonzero:
            call    ed_ldw_r8
            dw      ed_line_count
            inc     r8            ; R8 = line_count+1

            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    evit_bad
            clc
            rtn
evit_bad:
            stc
            rtn

;------------------------------------------------------------------
; ed_insert_one: insert the text at ed_i_source_buf (length
; ed_i_text_len) as a new line before ed_i_target (1-based). I/A/T
; set ed_i_source_buf = ed_input_buf; R and C both point it at the
; shared ed_line_scratch buffer instead, for two DIFFERENT reasons:
; R's old/new search text lives INSIDE ed_input_buf (the raw command
; line) and must stay valid across every line in its range, so it
; can't be the thing being overwritten; C is copying a line's content
; OUT of ed_buf itself, and that source pointer would be unsafe to
; hand to ed_insert_one directly -- the gap-opening shift below could
; move or clobber it before it's ever read, so it has to be staged
; somewhere stable first too. ed_line_scratch is 128 bytes, safely
; reusable by both since R and C are never active at the same time.
; Returns: DF = 0 on success, DF = 1 if out of room
;------------------------------------------------------------------
ed_insert_one:
            ; capacity_left = (buf_end - buf_start) - ed_text_len
            call    ed_ldw_rd
            dw      ed_buf_end
            call    ed_ldw_r8
            dw      ed_buf_start

            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc                  ; RC = total capacity

            call    ed_ldw_rd
            dw      ed_text_len

            glo     rd
            str     r2
            glo     rc
            sm
            plo     r9
            ghi     rd
            str     r2
            ghi     rc
            smb
            phi     r9                  ; R9 = bytes remaining

            call    ed_ldw_rd
            dw      ed_i_text_len
            inc     rd            ; RD = bytes needed (text + LF)

            ; remaining >= needed ?
            glo     rd
            str     r2
            glo     r9
            sm
            ghi     rd
            str     r2
            ghi     r9
            smb
            lbnf    eio_full

            call    ed_ldw_rd
            dw      ed_line_count
            ldi     low ED_MAX_LINES
            str     r2
            glo     rd
            sm
            ldi     high ED_MAX_LINES
            str     r2
            ghi     rd
            smb
            lbdf    eio_full

            ; ins_idx (0-based) = target - 1
            call    ed_ldw_rd
            dw      ed_i_target
            dec     rd
            call    ed_stw_rd
            dw      ed_i_ins_idx

            ; insert_offset = (ins_idx < line_count) ? ed_lines[ins_idx]
            ; : ed_text_len
            call    ed_ldw_r8
            dw      ed_line_count

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    eio_use_textlen     ; DF=1: ins_idx >= line_count

            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            lbr     eio_have_off

eio_use_textlen:
            call    ed_ldw_r9
            dw      ed_text_len

eio_have_off:
            call    ed_stw_r9
            dw      ed_i_ins_off

            call    ed_ldw_rd
            dw      ed_i_text_len
            inc     rd
            call    ed_stw_rd
            dw      ed_i_shift

            ; --- shift ed_buf's tail forward to open a gap ---
            call    ed_ldw_rd
            dw      ed_buf_start
            call    ed_ldw_r8
            dw      ed_i_ins_off
            add16   rd, r8              ; RD = absolute insert_offset
            call    ed_stw_rd
            dw      ed_mv_src

            call    ed_ldw_r8
            dw      ed_i_shift
            add16   rd, r8              ; RD = ed_mv_src + shift
            call    ed_stw_rd
            dw      ed_mv_dst

            call    ed_ldw_rd
            dw      ed_text_len
            call    ed_ldw_r8
            dw      ed_i_ins_off
            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc
            call    ed_stw_rc
            dw      ed_mv_count

            call    ed_copy_bwd

            ; --- write the new text + LF into the freed gap ---
            call    ed_ldw_rd
            dw      ed_mv_src
            call    ed_stw_rd
            dw      ed_i_wr_ptr

            mov     rf, ed_i_source_buf ; caller-supplied source buffer
                                        ; (ed_input_buf for every
                                        ; command except R, which
                                        ; supplies its own ed_line_scratch
                                        ; -- old/new text pointers into
                                        ; the R command's own raw
                                        ; ed_input_buf line must stay
                                        ; valid across every line in
                                        ; its range, so R can't build
                                        ; its rewritten line back into
                                        ; that same buffer)
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = the real source buffer
                                        ; address
            mov     rd, ed_i_src_ptr
            ghi     r8
            str     rd
            inc     rd
            glo     r8
            str     rd

            mov     rf, ed_i_wr_count
            mov     rd, ed_i_text_len
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

eio_wr_loop:
            call    ed_ldw_rd
            dw      ed_i_wr_count
            ghi     rd
            lbnz    eio_wr_have
            glo     rd
            lbz     eio_wr_lf
eio_wr_have:
            call    ed_ldw_rd
            dw      ed_i_src_ptr
            mov     rf, rd
            ldn     rf
            plo     r9

            call    ed_ldw_rd
            dw      ed_i_wr_ptr
            mov     rf, rd
            glo     r9
            str     rf

            call    ed_ldw_rd
            dw      ed_i_src_ptr
            inc     rd
            call    ed_stw_rd
            dw      ed_i_src_ptr

            call    ed_ldw_rd
            dw      ed_i_wr_ptr
            inc     rd
            call    ed_stw_rd
            dw      ed_i_wr_ptr

            call    ed_ldw_rd
            dw      ed_i_wr_count
            dec     rd
            call    ed_stw_rd
            dw      ed_i_wr_count

            lbr     eio_wr_loop

eio_wr_lf:
            call    ed_ldw_rd
            dw      ed_i_wr_ptr
            mov     rf, rd
            ldi     10
            str     rf

            ; --- shift ed_lines[ins_idx..line_count-1] up by one
            ; slot, adding ed_i_shift to each moved entry's value ---
            call    ed_ldw_rd
            dw      ed_line_count
            call    ed_stw_rd
            dw      ed_i_shift_i

eio_shift_loop:
            call    ed_ldw_rd
            dw      ed_i_shift_i
            call    ed_ldw_r8
            dw      ed_i_ins_idx

            ; ins_idx >= shift_i ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbdf    eio_shift_done      ; DF=1: shift_i <= ins_idx: done

            call    ed_ldw_rd
            dw      ed_i_shift_i
            dec     rd            ; RD = src_index (shift_i - 1)

            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ed_lines[shift_i-1]

            call    ed_ldw_r8
            dw      ed_i_shift

            glo     r8
            str     r2
            glo     r9
            add
            plo     rc
            ghi     r8
            str     r2
            ghi     r9
            adc
            phi     rc                  ; RC = ed_lines[shift_i-1] + shift

            call    ed_ldw_rd
            dw      ed_i_shift_i
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            call    ed_ldw_rd
            dw      ed_i_shift_i
            dec     rd
            call    ed_stw_rd
            dw      ed_i_shift_i

            lbr     eio_shift_loop

eio_shift_done:
            call    ed_ldw_rd
            dw      ed_i_ins_idx
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            mov     rd, ed_i_ins_off
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            call    ed_ldw_rd
            dw      ed_line_count
            inc     rd
            call    ed_stw_rd
            dw      ed_line_count

            call    ed_ldw_rd
            dw      ed_text_len
            call    ed_ldw_r8
            dw      ed_i_shift
            glo     r8
            str     r2
            glo     rd
            add
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rc
            call    ed_stw_rc
            dw      ed_text_len

            mov     rf, ed_cur_line
            mov     rd, ed_i_target
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            clc
            rtn

eio_full:
            stc
            rtn

;==================================================================
; T - transfer (insert the contents of a file)
;==================================================================
;
; [#]T filename -- insert filename's entire contents as new lines
; before line # (or before the current line, if # is omitted),
; matching real edlin's own "T" semantics. Reuses ed_fcb/ed_iobuf/
; ed_rdbuf/ed_getbyte -- the INITIAL file load's own FCB+buffered
; reader -- rather than a second allocation: by the time any command
; can run, ed_load_file has already opened, fully read, and closed
; that FCB, so it's sitting completely idle. Each transferred line is
; inserted via the exact same ed_insert_one/ed_i_target-bump sequence
; ed_cmd_i's own interactive loop already uses -- T is really just
; "I, but ed_getbyte supplies the lines instead of K_INPUTL."

ed_cmd_t:
            inc     rf                  ; consume 'T'
            call    f_ltrim             ; skip spaces before the name
            ldn     rf
            lbz     ed_t_usage          ; nothing after T: no filename

            mov     rb, ed_t_filename_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; stash the filename pointer --
                                        ; everything below uses RF
                                        ; freely as scratch, same as
                                        ; every other command here

            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_t_use_cur

            mov     rf, ed_i_target
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_t_validate

ed_t_use_cur:
            mov     rf, ed_i_target
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ed_t_validate:
            call    ed_validate_insert_target
            lbdf    ed_i_err            ; reuse I/A's own message

            ; --- open the file (reusing ed_fcb/ed_iobuf) ---
            call    ed_ldw_ra
            dw      ed_t_filename_ptr
            mov     rf, ra              ; RF = filename (K_FILE_OPEN's
                                        ; own path argument)
            mov     rd, ed_fcb
            mov     ra, ed_iobuf
            ldi     0                   ; mode = read
            call    K_FILE_OPEN
            lbdf    ed_t_notfound

            ; ed_getbyte's own buffered-read state is stale from the
            ; INITIAL load -- must not be trusted here
            mov     rf, ed_rdbuf_pos
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, ed_rdbuf_len
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_t_line_loop:
            mov     rf, ed_t_line_len
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_t_byte_loop:
            call    ed_getbyte
            lbdf    ed_t_eof

            plo     r9                  ; stash the byte

            glo     r9
            xri     13
            lbz     ed_t_byte_loop      ; CR: skip silently

            glo     r9
            xri     10
            lbz     ed_t_line_done      ; LF: line complete

            ; append to ed_input_buf if there's room -- 127 bytes max,
            ; matching K_INPUTL's own cap (there's no way to type a
            ; longer line interactively either, and ed_input_buf is
            ; only ever sized for that)
            call    ed_ldw_rd
            dw      ed_t_line_len  ; RD = current line length
            ldi     127
            str     r2
            glo     rd
            sm
            lbdf    ed_t_byte_loop      ; len >= 127: silently drop
                                        ; any further bytes on this
                                        ; over-long line

            mov     rf, ed_input_buf
            add16   rf, rd
            glo     r9
            str     rf                  ; ed_input_buf[len] = byte

            call    ed_ldw_rd
            dw      ed_t_line_len
            inc     rd
            call    ed_stw_rd
            dw      ed_t_line_len
            lbr     ed_t_byte_loop

ed_t_line_done:
            mov     rf, ed_input_buf
            mov     rd, ed_t_line_len
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            add16   rf, r8
            ldi     0
            str     rf                  ; NUL-terminate ed_input_buf

            call    ed_t_insert_line
            lbdf    ed_t_toolong
            lbr     ed_t_line_loop

ed_t_eof:
            mov     rf, ed_getbyte_ioerr
            ldn     rf
            lbnz    ed_t_ioerr

            ; a final partial line (no trailing LF) still needs
            ; inserting if it has any content
            call    ed_ldw_rd
            dw      ed_t_line_len
            ghi     rd
            lbnz    ed_t_final_have
            glo     rd
            lbz     ed_t_done           ; nothing pending: done cleanly
ed_t_final_have:
            mov     rf, ed_input_buf
            mov     rd, ed_t_line_len
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            add16   rf, r8
            ldi     0
            str     rf
            call    ed_t_insert_line
            lbdf    ed_t_toolong

ed_t_done:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            lbr     ed_cmdloop

ed_t_ioerr:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            lbr     ed_cmdloop

ed_t_toolong:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Buffer full.",13,10,0
            lbr     ed_cmdloop

ed_t_notfound:
            call    K_INMSG
            db      "File not found.",13,10,0
            lbr     ed_cmdloop

ed_t_usage:
            call    K_INMSG
            db      "Usage: T filename",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_t_insert_line: insert ed_input_buf (length already in
; ed_t_line_len) at ed_i_target, then advance ed_i_target -- the same
; "compute length, insert, bump target" sequence ed_i_loop's own
; interactive path already does per line, just sourcing
; ed_i_text_len from ed_t_line_len (already known) instead of
; re-measuring via ed_strlen.
; Returns: DF = 0 on success, DF = 1 if out of room
;------------------------------------------------------------------
ed_t_insert_line:
            call    ed_ldw_rd
            dw      ed_t_line_len
            call    ed_stw_rd
            dw      ed_i_text_len

            mov     rf, ed_i_source_buf
            ldi     high ed_input_buf
            str     rf
            inc     rf
            ldi     low ed_input_buf
            str     rf

            call    ed_insert_one
            lbdf    eti_full

            call    ed_ldw_rd
            dw      ed_i_target
            inc     rd
            call    ed_stw_rd
            dw      ed_i_target

            clc
            rtn
eti_full:
            stc
            rtn

;==================================================================
; R - replace string
;==================================================================
;
; [#][,#]Roldtext,newtext -- replace every occurrence of oldtext with
; newtext on every line in [first,last]. Either field may optionally
; be wrapped in matching '...'/"..." quotes (stripped, NOT escape-
; processed -- see the roadmap note on why escapes were deliberately
; left out: this project's own size budget matters more on a 32K
; board than typing a raw control byte into a search string). oldtext
; may not be empty (rejected outright -- an empty needle would match
; at every position forever). Default range, matching real edlin
; exactly: omitting the first line number starts at cur_line+1 (NOT
; cur_line itself, unlike every other command here); omitting the
; second defaults to the last line of the buffer. A defaulted range
; that comes out empty (e.g. cur_line is already the last line) is
; NOT an error -- it just means "nothing to replace"; an EXPLICIT
; out-of-range or inverted (first>last) range still is, matching D's
; own established validation.
;
; Each changed line is rewritten via the same insert-then-delete
; sequence the bare-number single-line edit already established
; (insert the new content first -- a "buffer full" leaves the
; original line intact -- then delete the old, now-shifted line).
; Since one insert + one delete leaves the total line count (and
; every OTHER line's own numbering) unchanged, the outer per-line
; loop can just walk ed_r_line_idx forward by 1 regardless of
; whether the current line actually changed.

ed_cmd_r:
            inc     rf                  ; consume 'R'
            call    ed_r_parse_args
            lbdf    ed_r_usage

            ; --- range: default first = cur_line+1, default last =
            ; line_count (unlike every other command's range default) ---
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_r_default_first

            call    ed_ldw_rd
            dw      ed_n1
            ghi     rd
            lbnz    ed_r_n1_ok
            glo     rd
            lbz     ed_r_err
ed_r_n1_ok:
            call    ed_ldw_r8
            dw      ed_line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_r_err
            call    ed_stw_rd
            dw      ed_r_first
            lbr     ed_r_have_first

ed_r_default_first:
            call    ed_ldw_rd
            dw      ed_cur_line
            inc     rd            ; RD = cur_line + 1
            call    ed_stw_rd
            dw      ed_r_first

ed_r_have_first:
            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_r_default_last

            call    ed_ldw_rd
            dw      ed_n2
            ghi     rd
            lbnz    ed_r_n2_ok
            glo     rd
            lbz     ed_r_err
ed_r_n2_ok:
            call    ed_ldw_r8
            dw      ed_line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_r_err

            mov     r8, ed_r_first
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = first (already resolved
                                        ; above, explicit or default)
            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbnf    ed_r_err            ; n2 < first: invalid

            call    ed_stw_rd
            dw      ed_r_last
            lbr     ed_r_range_ready

ed_r_default_last:
            call    ed_ldw_rd
            dw      ed_line_count
            call    ed_stw_rd
            dw      ed_r_last

ed_r_range_ready:
            ; a DEFAULTED range that's empty (first > line_count, or
            ; first > last) is not an error -- just nothing to do
            call    ed_ldw_rd
            dw      ed_r_first
            ; BUG FIX (2026-07-31, hardware-reported): all three checks
            ; in this proc used to stage the wrong operand as
            ; subtrahend, so "lbdf" fired on ">=" instead of the
            ; strict ">" each comment claimed -- first==line_count or
            ; first==last were wrongly treated as "empty range,
            ; nothing to do". Fixed by swapping which value is staged
            ; (str r2) vs. loaded last (the true minuend right before
            ; sm), and switching lbdf->lbnf to match: DF=0 (borrow)
            ; now correctly means the swapped minuend < the swapped
            ; subtrahend, i.e. the original strict ">" condition.
            call    ed_ldw_r8
            dw      ed_line_count  ; R8 = line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_r_report         ; DF=0: line_count < first,
                                        ; i.e. first > line_count

            call    ed_ldw_r8
            dw      ed_r_last  ; R8 = last
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_r_report         ; DF=0: last < first,
                                        ; i.e. first > last

            call    ed_stw_rd
            dw      ed_r_line_idx  ; ed_r_line_idx = first

            mov     rf, ed_r_count
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_r_loop:
            call    ed_ldw_rd
            dw      ed_r_line_idx
            call    ed_ldw_r8
            dw      ed_r_last  ; R8 = last
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_r_report         ; DF=0: last < line_idx,
                                        ; i.e. line_idx > last -- done
                                        ; (same swap-and-lbnf fix as
                                        ; the two checks above, same
                                        ; hardware-reported bug: this
                                        ; was the specific site that
                                        ; skipped the range's own last
                                        ; line, since line_idx==last
                                        ; used to be wrongly treated
                                        ; as "past the end")

            call    ed_r_process_line
            lbdf    ed_r_toolong

            call    ed_ldw_rd
            dw      ed_r_line_idx
            inc     rd
            call    ed_stw_rd
            dw      ed_r_line_idx
            lbr     ed_r_loop

ed_r_report:
            call    ed_ldw_rd
            dw      ed_r_count
            mov     rf, ed_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ed_num_buf
            call    K_MSG
            call    K_INMSG
            db      " replacement(s) made.",13,10,0
            lbr     ed_cmdloop

ed_r_toolong:
            call    K_INMSG
            db      "Buffer full.",13,10,0
            lbr     ed_cmdloop

ed_r_usage:
            call    K_INMSG
            db      "Usage: R oldtext,newtext",13,10,0
            lbr     ed_cmdloop

ed_r_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_r_parse_args: parse "oldtext,newtext" (each optionally wrapped
; in matching '...'/"..." quotes -- stripped, NOT escape-processed)
; at RF, up to the line's own terminating NUL. The delimiting comma
; must be unquoted -- a comma inside a quoted field is part of that
; field's own text. RF is never trusted to survive the internal
; ed_r_strip_quotes calls -- every position needed afterward is
; re-derived from memory first.
; Args:    RF = start of R's argument text (right after the 'R')
; Returns: DF = 0 with ed_r_old_ptr/len and ed_r_new_ptr/len set;
;          DF = 1 on error (no unquoted comma found at all, or the
;          old-text field is empty after stripping)
;------------------------------------------------------------------
ed_r_parse_args:
            mov     rb, ed_r_old_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ed_r_old_ptr = RF (field
                                        ; start, before stripping)

            ldi     0
            plo     r8                  ; R8.0 = quote_state (0=none)

erpa_scan1:
            ldn     rf
            lbz     erpa_err            ; NUL before any comma: error
            plo     r9

            glo     r8
            lbz     erpa_s1_unquoted

            glo     r9
            str     r2
            glo     r8
            xor
            lbnz    erpa_s1_adv         ; not the closing quote char
            ldi     0
            plo     r8                  ; quote closed
            lbr     erpa_s1_adv

erpa_s1_unquoted:
            glo     r9
            xri     $27                 ; "'"
            lbz     erpa_s1_openq
            glo     r9
            xri     $22                 ; '"'
            lbz     erpa_s1_openq
            glo     r9
            xri     ','
            lbz     erpa_s1_found       ; unquoted comma: delimiter
            lbr     erpa_s1_adv

erpa_s1_openq:
            glo     r9
            plo     r8                  ; quote_state = this char
erpa_s1_adv:
            inc     rf
            lbr     erpa_scan1

erpa_s1_found:
            ; old field = [ed_r_old_ptr, RF)
            mov     r9, ed_r_old_ptr
            lda     r9
            phi     rd
            ldn     r9
            plo     rd                  ; RD = old field start
            glo     rd
            str     r2
            glo     rf
            sm
            plo     r8
            ghi     rd
            str     r2
            ghi     rf
            smb
            phi     r8                  ; R8 = old field length
            mov     r9, ed_r_old_len
            ghi     r8
            str     r9
            inc     r9
            glo     r8
            str     r9

            inc     rf                  ; skip the comma
            mov     rb, ed_r_new_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ed_r_new_ptr = RF (new
                                        ; field start) -- stashed to
                                        ; memory NOW, before the
                                        ; ed_r_strip_quotes call below
                                        ; can clobber RF

            mov     rb, ed_r_old_ptr
            mov     r9, ed_r_old_len
            call    ed_r_strip_quotes

            mov     r9, ed_r_old_len
            lda     r9
            lbnz    erpa_have_old
            ldn     r9
            lbz     erpa_err            ; old field is empty
erpa_have_old:

            ; resume scanning at ed_r_new_ptr for the NUL that ends
            ; the new field
            call    ed_ldw_r8
            dw      ed_r_new_ptr
            mov     rf, r8              ; RF = new field start

erpa_scan2:
            ldn     rf
            lbz     erpa_s2_end
            inc     rf
            lbr     erpa_scan2

erpa_s2_end:
            mov     r9, ed_r_new_ptr
            lda     r9
            phi     rd
            ldn     r9
            plo     rd                  ; RD = new field start
            glo     rd
            str     r2
            glo     rf
            sm
            plo     r8
            ghi     rd
            str     r2
            ghi     rf
            smb
            phi     r8                  ; R8 = new field length
            mov     r9, ed_r_new_len
            ghi     r8
            str     r9
            inc     r9
            glo     r8
            str     r9

            mov     rb, ed_r_new_ptr
            mov     r9, ed_r_new_len
            call    ed_r_strip_quotes

            clc
            rtn

erpa_err:
            stc
            rtn

;------------------------------------------------------------------
; ed_r_strip_quotes: given a (ptr,len) pair stored at the two memory
; addresses passed in, strip a matching leading/trailing quote pair
; ('...' or "...") if present -- adjusts both fields in place. No
; effect if the field isn't quoted (or is too short to be). Shared by
; both the old-text and new-text fields.
; Args:    RB = address of the 2-byte pointer field
;          R9 = address of the 2-byte length field
;------------------------------------------------------------------
ed_r_strip_quotes:
            mov     ra, rb              ; stash the ORIGINAL field
            mov     rc, r9              ; addresses -- needed for the
                                        ; write-back at the end, since
                                        ; RB/R9 themselves get walked
                                        ; forward by the reads below

            lda     r9
            phi     rd
            ldn     r9
            plo     rd                  ; RD = len
            ghi     rd
            lbnz    ersq_check          ; high byte nonzero: len is
                                        ; way more than 2, definitely
                                        ; long enough
            glo     rd
            smi     2
            lbnf    ersq_done           ; len < 2: can't be quoted
ersq_check:
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; R8 = field start ptr

            mov     rf, r8
            ldn     rf
            plo     r7                  ; R7.0 = first char
            xri     $27
            lbz     ersq_is_quote
            glo     r7
            xri     $22
            lbz     ersq_is_quote
            lbr     ersq_done           ; first char isn't a quote

ersq_is_quote:
            mov     rf, r8
            add16   rf, rd
            dec     rf                  ; RF = last char's address
            ldn     rf
            str     r2
            glo     r7
            xor
            lbnz    ersq_done           ; last char != first char

            inc     r8            ; ptr++
            dec     rd
            dec     rd            ; len -= 2

            call    ed_stw_r8
            dw      ra

            call    ed_stw_rd
            dw      rc

ersq_done:
            rtn

;------------------------------------------------------------------
; ed_r_process_line: replace every occurrence of ed_r_old_ptr/len
; with ed_r_new_ptr/len on the line named by ed_r_line_idx (1-based),
; rewriting it via insert-then-delete if anything actually changed.
; Returns: DF = 0 on success (ed_r_count bumped if the line changed),
;          DF = 1 if the replacement wouldn't fit in ed_line_scratch or
;          couldn't be inserted (ed_buf itself full)
;------------------------------------------------------------------
ed_r_process_line:
            call    ed_ldw_rd
            dw      ed_r_line_idx
            dec     rd            ; RD = 0-based index
            call    ed_line_info        ; ed_li_ptr/ed_li_len set

            mov     rf, ed_r_out_len
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, ed_r_changed
            ldi     0
            str     rf
            mov     rf, ed_r_src_pos
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_rpl_loop:
            ; remaining = li_len - src_pos
            call    ed_ldw_rd
            dw      ed_li_len
            call    ed_ldw_r8
            dw      ed_r_src_pos
            glo     r8
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     r9                  ; R9 = remaining

            call    ed_ldw_r8
            dw      ed_r_old_len  ; R8 = old_len

            ; remaining >= old_len ?
            glo     r8
            str     r2
            glo     r9
            sm
            ghi     r8
            str     r2
            ghi     r9
            smb
            lbnf    ed_rpl_copy_rest    ; DF=0: remaining < old_len --
                                        ; no more matches possible

            call    ed_r_match_here
            lbdf    ed_rpl_copy_one

            ; matched -- append new_text, then skip old_len bytes
            call    ed_ldw_r8
            dw      ed_r_new_ptr
            call    ed_ldw_r9
            dw      ed_r_new_len
            call    ed_r_append_block
            lbdf    ed_rpl_full

            mov     rf, ed_r_changed
            ldi     1
            str     rf

            call    ed_ldw_rd
            dw      ed_r_src_pos
            call    ed_ldw_r8
            dw      ed_r_old_len
            glo     r8
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rd
            call    ed_stw_rd
            dw      ed_r_src_pos
            lbr     ed_rpl_loop

ed_rpl_copy_one:
            call    ed_ldw_r8
            dw      ed_li_ptr
            call    ed_ldw_r9
            dw      ed_r_src_pos
            add16   r8, r9              ; R8 = &li_ptr[src_pos]
            ldi     0
            phi     r9
            ldi     1
            plo     r9                  ; R9 = 1 (one byte)
            call    ed_r_append_block
            lbdf    ed_rpl_full

            call    ed_ldw_rd
            dw      ed_r_src_pos
            inc     rd
            call    ed_stw_rd
            dw      ed_r_src_pos
            lbr     ed_rpl_loop

ed_rpl_copy_rest:
            call    ed_ldw_rd
            dw      ed_r_src_pos
            call    ed_ldw_r8
            dw      ed_li_len
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_rpl_done         ; DF=1: src_pos >= li_len

            call    ed_ldw_r8
            dw      ed_li_ptr
            add16   r8, rd              ; R8 = &li_ptr[src_pos]
            ldi     0
            phi     r9
            ldi     1
            plo     r9                  ; R9 = 1 (one byte)
            call    ed_r_append_block
            lbdf    ed_rpl_full

            call    ed_ldw_rd
            dw      ed_r_src_pos
            inc     rd
            call    ed_stw_rd
            dw      ed_r_src_pos
            lbr     ed_rpl_copy_rest

ed_rpl_done:
            mov     rf, ed_r_changed
            ldn     rf
            lbz     ed_rpl_unchanged

            mov     rf, ed_line_scratch
            mov     rd, ed_r_out_len
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            add16   rf, r8
            ldi     0
            str     rf                  ; NUL-terminate ed_line_scratch

            mov     rf, ed_r_line_idx
            mov     rd, ed_i_target
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd                  ; ed_i_target = ed_r_line_idx

            call    ed_ldw_rd
            dw      ed_r_out_len
            call    ed_stw_rd
            dw      ed_i_text_len

            mov     rf, ed_i_source_buf
            ldi     high ed_line_scratch
            str     rf
            inc     rf
            ldi     low ed_line_scratch
            str     rf

            call    ed_insert_one
            lbdf    ed_rpl_full

            ; delete the old line, now shifted to ed_r_line_idx + 1
            call    ed_ldw_rd
            dw      ed_r_line_idx
            inc     rd
            call    ed_stw_rd
            dw      ed_d_first
            call    ed_stw_rd
            dw      ed_d_last
            call    ed_delete_range

            call    ed_ldw_rd
            dw      ed_r_count
            inc     rd
            call    ed_stw_rd
            dw      ed_r_count

ed_rpl_unchanged:
            clc
            rtn

ed_rpl_full:
            stc
            rtn

;------------------------------------------------------------------
; ed_r_match_here: does ed_li_ptr[ed_r_src_pos .. +old_len) equal
; ed_r_old_ptr[0..old_len)? Caller has already confirmed there's
; enough remaining source text for the comparison to be safe.
; Returns: DF = 0 if it matches, DF = 1 if not
;------------------------------------------------------------------
ed_r_match_here:
            call    ed_ldw_r8
            dw      ed_li_ptr
            call    ed_ldw_r9
            dw      ed_r_src_pos
            add16   r8, r9              ; R8 = &li_ptr[src_pos]

            call    ed_ldw_r9
            dw      ed_r_old_ptr  ; R9 = old_ptr

            call    ed_ldw_ra
            dw      ed_r_old_len  ; RA = remaining count

erm_loop:
            ghi     ra
            lbnz    erm_have
            glo     ra
            lbz     erm_match
erm_have:
            ldn     r8
            str     r2
            ldn     r9
            xor
            lbnz    erm_nomatch
            inc     r8
            inc     r9
            dec     ra
            lbr     erm_loop

erm_match:
            clc
            rtn
erm_nomatch:
            stc
            rtn

;------------------------------------------------------------------
; ed_r_append_block: append R9 bytes starting at R8 to ed_line_scratch,
; bounds-checked (capped at 127 content bytes, always leaving room
; for the trailing NUL ed_rpl_done writes). Checked BEFORE any byte
; is written, so a rejected append leaves ed_line_scratch's own already-
; accumulated content untouched.
; Args:    R8 = source pointer, R9 = byte count
; Returns: DF = 0 on success, DF = 1 if it wouldn't fit
;------------------------------------------------------------------
ed_r_append_block:
            call    ed_ldw_rd
            dw      ed_r_out_len  ; RD = out_len

            glo     r9
            str     r2
            glo     rd
            add
            plo     r7
            ghi     r9
            str     r2
            ghi     rd
            adc
            phi     r7                  ; R7 = out_len + count

            ghi     r7
            lbnz    erab_full           ; way too big
            ldi     127
            str     r2
            glo     r7
            sm
            lbdf    erab_full           ; DF=1: (out_len+count) >= 127

            mov     rf, ed_line_scratch
            add16   rf, rd              ; RF = &out_buf[out_len]

erab_loop:
            ghi     r9
            lbnz    erab_have
            glo     r9
            lbz     erab_done
erab_have:
            lda     r8
            str     rf
            inc     rf
            dec     r9
            lbr     erab_loop

erab_done:
            mov     rf, ed_r_out_len
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf
            clc
            rtn

erab_full:
            stc
            rtn

;==================================================================
; C - copy a range of lines
;==================================================================
;
; [first],[last],target[,count]C -- copy lines [first,last] (each
; independently defaulting to cur_line, NOT to each other) to just
; before target (REQUIRED -- no sensible default exists), repeated
; count times (default 1). Unlike R's insert-then-delete, a copy
; never removes anything, so there's no crash-safety ordering to
; worry about -- but target overlapping the source needs real care:
; if target is at or before the source's own start, every insertion
; shifts the yet-to-be-copied source lines forward too. Deliberately
; REJECTS a target strictly INSIDE (first,last] -- copying part of a
; block into the middle of the very block being copied has no clean
; definition and real edlin doesn't document one either.
;
; The shift-or-not distinction reduces to one flag, computed once:
; shift = (target <= first). With that fixed, the i-th line (0-based
; within one copy) of the k-th repeat sits, in CURRENT (already-
; shifted-by-prior-inserts) numbering, at:
;     src_pos = first + i + (shift ? n : 0)
; where n is the running total of lines already inserted by this
; whole C command so far -- independently verified (Python simulation
; against a real list-splice model, several worked cases including
; target==first, target==last+1, target at the very start/end of the
; file) before writing this in assembly.
;
; Each copied line's content has to be staged into ed_line_scratch
; before insertion, same as R -- handing ed_insert_one a pointer
; straight into ed_buf itself (what ed_line_info returns) would be
; unsafe, since the insert's own internal gap-opening shift could
; move or clobber that exact memory before it's ever read.

;------------------------------------------------------------------
; ed_cm_parse_target: shared C/M setup -- resolves ed_c_first/
; ed_c_last (from n1/n2, each independently defaulting to cur_line),
; ed_i_target (from n3, REQUIRED), and ed_c_shift (1 if target <=
; first, else 0), rejecting a target strictly inside (first,last].
; Both C's own repeat-count loop and M's single-pass move sit on top
; of this identical setup -- factored out so the two commands' own
; validation can never quietly drift apart from each other.
; Returns: DF = 0 on success;
;          DF = 1, D = 1 on a range/validation error (bad first/
;          last/target, last < first, or target inside the source
;          range) -- print "Line number out of range.";
;          DF = 1, D = 2 if n3 (target) was never given at all --
;          print the caller's own usage message
;------------------------------------------------------------------
ed_cm_parse_target:
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ecpt_first_cur

            mov     rf, ed_c_first
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ecpt_have_first

ecpt_first_cur:
            mov     rf, ed_c_first
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ecpt_have_first:
            call    ed_ldw_rd
            dw      ed_c_first
            ghi     rd
            lbnz    ecpt_f_ok
            glo     rd
            lbz     ecpt_err
ecpt_f_ok:
            call    ed_ldw_r8
            dw      ed_line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ecpt_err

            mov     rf, ed_have_n2
            ldn     rf
            lbz     ecpt_last_cur

            mov     rf, ed_c_last
            mov     rd, ed_n2
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ecpt_have_last

ecpt_last_cur:
            mov     rf, ed_c_last
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ecpt_have_last:
            call    ed_ldw_rd
            dw      ed_c_last
            ghi     rd
            lbnz    ecpt_l_ok
            glo     rd
            lbz     ecpt_err
ecpt_l_ok:
            call    ed_ldw_r8
            dw      ed_line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ecpt_err

            mov     r8, ed_c_first
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = first
            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbnf    ecpt_err            ; last < first

            ; --- target: required, no default ---
            mov     rf, ed_have_n3
            ldn     rf
            lbz     ecpt_usage

            mov     rf, ed_i_target
            mov     rd, ed_n3
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            call    ed_validate_insert_target
            lbdf    ecpt_err

            ; target must be <= first, OR > last -- never strictly
            ; inside (first,last]
            call    ed_ldw_rd
            dw      ed_i_target  ; RD = target
            call    ed_ldw_r8
            dw      ed_c_first  ; R8 = first

            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbdf    ecpt_shift_yes      ; DF=1: first >= target ->
                                        ; target <= first

            call    ed_ldw_r8
            dw      ed_c_last  ; R8 = last
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbdf    ecpt_err            ; DF=1: last >= target ->
                                        ; target inside (first,last]

            mov     rf, ed_c_shift
            ldi     0
            str     rf
            clc
            rtn

ecpt_shift_yes:
            mov     rf, ed_c_shift
            ldi     1
            str     rf
            clc
            rtn

ecpt_err:
            ldi     1
            stc
            rtn

ecpt_usage:
            ldi     2
            stc
            rtn

ed_cmd_c:
            call    ed_cm_parse_target
            lbnf    ed_c_have_shift
            xri     2
            lbz     ed_c_usage
            lbr     ed_c_err

ed_c_have_shift:
            ; --- count: default 1 ---
            mov     rf, ed_have_n4
            ldn     rf
            lbnz    ed_c_count_explicit
            mov     rf, ed_c_count
            ldi     0
            str     rf
            inc     rf
            ldi     1
            str     rf
            lbr     ed_c_ready

ed_c_count_explicit:
            mov     rf, ed_c_count
            mov     rd, ed_n4
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ed_c_ready:
            call    ed_c_setup_pass

            mov     rf, ed_c_k
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_c_outer:
            call    ed_ldw_rd
            dw      ed_c_k
            call    ed_ldw_r8
            dw      ed_c_count
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_c_done           ; DF=1: k >= count

            call    ed_c_copy_block     ; always returns DF=0 -- see
                                        ; its own header comment

            call    ed_ldw_rd
            dw      ed_c_k
            inc     rd
            call    ed_stw_rd
            dw      ed_c_k
            lbr     ed_c_outer

ed_c_done:
            ; cur_line = wherever the insert loop left ed_c_ins_pos --
            ; one past the very last line inserted, matching this
            ; file's own established "cur_line follows the insert
            ; target" convention
            mov     rf, ed_cur_line
            mov     rd, ed_c_ins_pos
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_cmdloop

ed_c_toolong:
            call    K_INMSG
            db      "Buffer full.",13,10,0
            lbr     ed_cmdloop

ed_c_usage:
            call    K_INMSG
            db      "Usage: [first],[last],target[,count]C",13,10,0
            lbr     ed_cmdloop

ed_c_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_c_setup_pass: compute ed_c_blocklen from ed_c_first/ed_c_last,
; and reset ed_c_n = 0 / ed_c_ins_pos = ed_i_target -- the common
; setup both C (before its own repeat-count loop) and M (before its
; own single pass) need before their first call to ed_c_copy_block.
;------------------------------------------------------------------
ed_c_setup_pass:
            call    ed_ldw_rd
            dw      ed_c_last
            call    ed_ldw_r8
            dw      ed_c_first
            glo     r8
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     r9
            inc     r9
            call    ed_stw_r9
            dw      ed_c_blocklen

            mov     rf, ed_c_n
            ldi     0
            str     rf
            inc     rf
            str     rf

            mov     rf, ed_c_ins_pos
            mov     rd, ed_i_target
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            rtn

;------------------------------------------------------------------
; ed_c_copy_block: run ONE pass of ed_c_blocklen line-copy+insert
; iterations, using ed_c_first/ed_c_shift/ed_c_n/ed_c_ins_pos.
; ed_c_n and ed_c_ins_pos are NOT reset here -- a caller doing
; multiple passes (C's own repeat count) calls this repeatedly and
; needs them to keep accumulating across passes; ed_c_i IS reset to
; 0 at entry, since it's private to a single pass. Shared by both
; ed_cmd_c's own outer repeat-count loop and ed_cmd_m (a move is
; just one pass of this followed by deleting the original block).
; Returns: DF = 0 (always -- a copy that wouldn't fit jumps straight
;          to the shared "Buffer full." handler and never returns
;          here at all, since every caller wants that exact same
;          message and exit; ed_c_n/ed_c_ins_pos still reflect
;          exactly how far it got before that, if ever inspected)
;------------------------------------------------------------------
ed_c_copy_block:
            mov     rf, ed_c_i
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_c_inner:
            call    ed_ldw_rd
            dw      ed_c_i
            call    ed_ldw_r8
            dw      ed_c_blocklen
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_c_inner_done     ; DF=1: i >= blocklen

            call    ed_ldw_rd
            dw      ed_c_first
            call    ed_ldw_r8
            dw      ed_c_i
            glo     r8
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rd                  ; RD = first + i

            mov     rf, ed_c_shift
            ldn     rf
            lbz     ed_c_have_src

            call    ed_ldw_r8
            dw      ed_c_n
            glo     r8
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rd                  ; RD += n

ed_c_have_src:
            dec     rd            ; RD = 0-based source index
            call    ed_line_info        ; ed_li_ptr/ed_li_len set

            mov     rf, ed_line_scratch
            mov     rd, ed_li_ptr
            lda     rd
            phi     r8
            ldn     rd
            plo     r8                  ; R8 = li_ptr
            mov     rd, ed_li_len
            lda     rd
            phi     r9
            ldn     rd
            plo     r9                  ; R9 = li_len

ed_c_copy_loop:
            ghi     r9
            lbnz    ed_c_copy_have
            glo     r9
            lbz     ed_c_copy_done
ed_c_copy_have:
            lda     r8
            str     rf
            inc     rf
            dec     r9
            lbr     ed_c_copy_loop
ed_c_copy_done:
            ldi     0
            str     rf                  ; NUL-terminate

            mov     rf, ed_i_target
            mov     rd, ed_c_ins_pos
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            mov     rf, ed_i_text_len
            mov     rd, ed_li_len
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            mov     rf, ed_i_source_buf
            ldi     high ed_line_scratch
            str     rf
            inc     rf
            ldi     low ed_line_scratch
            str     rf

            call    ed_insert_one
            lbdf    ed_c_toolong

            call    ed_ldw_rd
            dw      ed_c_ins_pos
            inc     rd
            call    ed_stw_rd
            dw      ed_c_ins_pos

            call    ed_ldw_rd
            dw      ed_c_n
            inc     rd
            call    ed_stw_rd
            dw      ed_c_n

            call    ed_ldw_rd
            dw      ed_c_i
            inc     rd
            call    ed_stw_rd
            dw      ed_c_i
            lbr     ed_c_inner

ed_c_inner_done:
            clc
            rtn

;==================================================================
; M - move a range of lines
;==================================================================
;
; [first],[last]target M -- move lines [first,last] to just before
; target (same validation/defaults/shift-vs-not logic as C, via the
; shared ed_cm_parse_target -- see its own header comment). No repeat
; count (M only ever moves once). Implemented exactly as the doc
; itself describes it -- "similar to copying then deleting the
; original block" -- one ed_c_copy_block pass, then delete the
; ORIGINAL block from wherever it ended up: unchanged at
; [first,last] if the copy landed strictly after it (ed_c_shift=0),
; or shifted forward by ed_c_n (== blocklen, after exactly one pass)
; if the copy landed at or before it (ed_c_shift=1) -- ed_c_n is
; exactly the same accumulator ed_c_copy_block already tracks for
; C's own repeat-count case, reused here unchanged.

ed_cmd_m:
            call    ed_cm_parse_target
            lbnf    ed_m_ready
            xri     2
            lbz     ed_m_usage
            lbr     ed_m_err

ed_m_ready:
            call    ed_c_setup_pass
            call    ed_c_copy_block    ; single pass -- always DF=0

            ; delete_first = first + (shift ? n : 0)
            call    ed_ldw_rd
            dw      ed_c_first
            mov     rf, ed_c_shift
            ldn     rf
            lbz     ed_m_first_noshift

            call    ed_ldw_r8
            dw      ed_c_n
            glo     r8
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rd

ed_m_first_noshift:
            call    ed_stw_rd
            dw      ed_d_first

            ; delete_last = last + (shift ? n : 0)
            call    ed_ldw_rd
            dw      ed_c_last
            mov     rf, ed_c_shift
            ldn     rf
            lbz     ed_m_last_noshift

            call    ed_ldw_r8
            dw      ed_c_n
            glo     r8
            str     r2
            glo     rd
            add
            plo     rd
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     rd

ed_m_last_noshift:
            call    ed_stw_rd
            dw      ed_d_last

            call    ed_delete_range

            ; cur_line follows the insert target, same as C
            mov     rf, ed_cur_line
            mov     rd, ed_c_ins_pos
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_cmdloop

ed_m_usage:
            call    K_INMSG
            db      "Usage: [first],[last]target M",13,10,0
            lbr     ed_cmdloop

ed_m_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;==================================================================
; D - delete
;==================================================================

ed_cmd_d:
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_d_use_cur

            mov     rf, ed_d_first
            mov     rd, ed_n1
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_d_last_eq_first

            mov     rf, ed_d_last
            mov     rd, ed_n2
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_d_validate

ed_d_last_eq_first:
            mov     rf, ed_d_last
            mov     rd, ed_d_first
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_d_validate

ed_d_use_cur:
            mov     rf, ed_d_first
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            mov     rf, ed_d_last
            mov     rd, ed_cur_line
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ed_d_validate:
            call    ed_ldw_rd
            dw      ed_d_first
            ghi     rd
            lbnz    ed_d_err
            glo     rd
            lbz     ed_d_err            ; first == 0

            call    ed_ldw_r8
            dw      ed_d_last

            ; last >= first ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_d_err

            call    ed_ldw_r9
            dw      ed_line_count

            ; line_count >= last ?
            glo     r8
            str     r2
            glo     r9
            sm
            ghi     r8
            str     r2
            ghi     r9
            smb
            lbnf    ed_d_err
            call    ed_delete_range
            call    K_INMSG
            db      "Deleted.",13,10,0
            lbr     ed_cmdloop

ed_d_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_delete_range: delete lines ed_d_first..ed_d_last (1-based,
; inclusive) -- both must already be validated (1 <= first <= last <=
; line_count) by the caller. Also called directly by the bare-number
; single-line-edit path above (with first == last), reusing the exact
; same buffer/line-table shifting logic rather than duplicating it.
; Args:    ed_d_first, ed_d_last
; Returns: nothing (ed_cur_line updated to a sane post-delete value)
;------------------------------------------------------------------
ed_delete_range:
            ; start_off = ed_lines[first-1]
            call    ed_ldw_rd
            dw      ed_d_first
            dec     rd
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            call    ed_stw_r8
            dw      ed_d_start_off

            ; end_off = (last < line_count) ? ed_lines[last] : ed_text_len
            call    ed_ldw_rd
            dw      ed_d_last  ; RD = last (0-based index of
                                        ; the line right after the
                                        ; deleted range)

            call    ed_ldw_r9
            dw      ed_line_count

            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    ed_d_use_textlen    ; DF=1: last >= line_count

            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            lbr     ed_d_have_end

ed_d_use_textlen:
            call    ed_ldw_r9
            dw      ed_text_len

ed_d_have_end:
            call    ed_stw_r9
            dw      ed_d_end_off

            ; removed = end_off - start_off
            call    ed_ldw_rd
            dw      ed_d_start_off
            call    ed_ldw_r8
            dw      ed_d_end_off

            glo     rd
            str     r2
            glo     r8
            sm
            plo     rc
            ghi     rd
            str     r2
            ghi     r8
            smb
            phi     rc
            call    ed_stw_rc
            dw      ed_d_removed

            ; --- shift ed_buf: [end_off, text_len) back to start_off ---
            call    ed_ldw_rd
            dw      ed_buf_start
            call    ed_ldw_r8
            dw      ed_d_end_off
            add16   rd, r8              ; RD = absolute src
            call    ed_stw_rd
            dw      ed_mv_src

            call    ed_ldw_rd
            dw      ed_buf_start
            call    ed_ldw_r8
            dw      ed_d_start_off
            add16   rd, r8              ; RD = absolute dst
            call    ed_stw_rd
            dw      ed_mv_dst

            call    ed_ldw_rd
            dw      ed_text_len
            call    ed_ldw_r8
            dw      ed_d_end_off
            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc
            call    ed_stw_rc
            dw      ed_mv_count

            call    ed_copy_fwd

            ; --- shift ed_lines[last..line_count-1] down to
            ; [first-1..], subtracting "removed" from each entry ---
            call    ed_ldw_rd
            dw      ed_d_last
            call    ed_stw_rd
            dw      ed_d_shift_src

            call    ed_ldw_rd
            dw      ed_d_first
            dec     rd
            call    ed_stw_rd
            dw      ed_d_shift_dst

ed_d_shift_loop:
            call    ed_ldw_rd
            dw      ed_d_shift_src
            call    ed_ldw_r8
            dw      ed_line_count

            ; shift_src >= line_count ?
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_d_shift_done

            call    ed_ldw_rd
            dw      ed_d_shift_src
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ed_lines[shift_src]

            call    ed_ldw_r8
            dw      ed_d_removed

            glo     r8
            str     r2
            glo     r9
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     r9
            smb
            phi     rc                  ; RC = ed_lines[shift_src] -
                                        ; removed

            call    ed_ldw_rd
            dw      ed_d_shift_dst
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            call    ed_ldw_rd
            dw      ed_d_shift_src
            inc     rd
            call    ed_stw_rd
            dw      ed_d_shift_src

            call    ed_ldw_rd
            dw      ed_d_shift_dst
            inc     rd
            call    ed_stw_rd
            dw      ed_d_shift_dst

            lbr     ed_d_shift_loop

ed_d_shift_done:
            ; line_count -= (last - first + 1)
            call    ed_ldw_rd
            dw      ed_d_last
            call    ed_ldw_r8
            dw      ed_d_first

            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc
            inc     rc            ; RC = deleted-line count

            call    ed_ldw_rd
            dw      ed_line_count

            glo     rc
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     rc
            str     r2
            ghi     rd
            smb
            phi     r9

            call    ed_stw_r9
            dw      ed_line_count

            ; text_len -= removed
            call    ed_ldw_rd
            dw      ed_text_len
            call    ed_ldw_r8
            dw      ed_d_removed

            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc

            call    ed_stw_rc
            dw      ed_text_len

            ; cur_line = (first <= new line_count) ? first :
            ; (new line_count >= 1 ? new line_count : 1)
            call    ed_ldw_rd
            dw      ed_line_count  ; RD = new line_count

            call    ed_ldw_r8
            dw      ed_d_first

            ; line_count >= first ?
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_d_cur_is_first

            ghi     rd
            lbnz    ed_d_cur_is_count
            glo     rd
            lbnz    ed_d_cur_is_count
            ldi     0
            phi     rd
            ldi     1
            plo     rd
            lbr     ed_d_cur_is_count

ed_d_cur_is_first:
            call    ed_ldw_rd
            dw      ed_d_first

ed_d_cur_is_count:
            call    ed_stw_rd
            dw      ed_cur_line

            rtn

;==================================================================
; W/E - write buffer (or first # lines) to a filename; E also exits
;==================================================================

; [#]W [filename] / [#]E [filename] -- both share this one
; implementation (2026-07-31, redesigned on the user's own explicit
; instruction). Real edlin's own W/A (page write/append) pair existed
; to flush/reload PAGES of a buffer too large to fit in memory at
; once -- this project's own top-of-file header comment already
; explains why that's not needed here (the whole file always fits in
; RAM); W survives anyway as a general "write [the first N lines of]
; the buffer to a filename" that doesn't end the session, with E
; being the same operation plus exit.
;
; The filename is now OPTIONAL on both:
;   - given: write there. If this was E, exit afterward.
;   - omitted: fall back to ed_filename_ptr (the file EDLIN was
;     opened with, or the target of the last successful W/E that DID
;     name one explicitly) -- this is what lets a bare "E" keep
;     working exactly as before once a name has been established.
;   - omitted AND ed_filename_ptr is ALSO unset (a buffer that was
;     opened empty, via a bare "EDLIN", and has never been through a
;     W/E with an explicit filename): an error, since there is
;     nothing to fall back to.
; The optional leading [#] (line count, unrelated to the filename)
; is unchanged: write only the first # lines, or the whole buffer if
; omitted -- applies identically regardless of where the filename
; itself came from.
;
; On any successful write, ed_filename_ptr is set to the target just
; written (a harmless no-op when that target WAS ed_filename_ptr
; already) -- so once a name is established, either explicitly or via
; the file EDLIN opened, every later bare W/E keeps using it.
;
; E's own pre-existing "exit even on a write/open failure" behavior
; is preserved (matches DOS's own urgency about a failed save); W
; continues to just report the error and return to the prompt,
; unchanged from its own original design. A malformed range or a
; genuinely missing filename (no fallback available either) always
; returns to the prompt for both -- trivially recoverable mistakes
; that shouldn't cost the whole edit session.
ed_cmd_w:
            mov     rb, ed_wsave_is_e
            ldi     0
            str     rb                  ; not E
            lbr     ed_wsave_common

ed_cmd_e:
            mov     rb, ed_wsave_is_e
            ldi     1
            str     rb                  ; is E

ed_wsave_common:
            inc     rf                  ; consume 'W' or 'E'
            call    f_ltrim             ; skip spaces before an
                                        ; optional filename
            ldn     rf
            lbz     ed_wsave_fallback   ; nothing here: fall back to
                                        ; ed_filename_ptr

            mov     rb, ed_w_filename_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; stash the EXPLICIT filename
                                        ; pointer -- everything below
                                        ; uses RF freely as scratch
            lbr     ed_wsave_have_target

ed_wsave_fallback:
            mov     rf, ed_filename_ptr
            ldn     rf
            lbnz    ed_wsave_copy_fallback  ; high byte nonzero: have one
            inc     rf
            ldn     rf
            lbz     ed_wsave_no_name    ; both bytes zero: genuinely
                                        ; nothing to fall back to

ed_wsave_copy_fallback:
            mov     rb, ed_w_filename_ptr
            mov     rf, ed_filename_ptr
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; ed_w_filename_ptr =
                                        ; ed_filename_ptr -- so the
                                        ; rest of this routine treats
                                        ; "explicit" and "fallback"
                                        ; identically from here on

ed_wsave_have_target:
            ; count = n1 if given (validated 1..line_count), else
            ; line_count (write everything) -- ed_have_n1/ed_n1 were
            ; already set (or not) by ed_cmdloop's own leading-range
            ; parse, well before dispatch reached here
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_wsave_all

            call    ed_ldw_rd
            dw      ed_n1  ; RD = n1
            ghi     rd
            lbnz    ed_wsave_n1_ok
            glo     rd
            lbz     ed_wsave_rangeerr   ; n1 == 0: invalid
ed_wsave_n1_ok:
            call    ed_ldw_r8
            dw      ed_line_count  ; R8 = line_count
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_wsave_rangeerr   ; DF=0: line_count < n1
            call    ed_stw_rd
            dw      ed_w_count
            lbr     ed_wsave_have_count

ed_wsave_all:
            call    ed_ldw_rd
            dw      ed_line_count
            call    ed_stw_rd
            dw      ed_w_count

ed_wsave_have_count:
            ; --- open the target file (reusing ed_fcb/ed_iobuf --
            ; safe: nothing else has either open at this point in the
            ; command loop) ---
            call    ed_ldw_ra
            dw      ed_w_filename_ptr
            mov     rf, ra
            mov     rd, ed_fcb
            mov     ra, ed_iobuf
            ldi     1                   ; mode = write/truncate
            call    K_FILE_OPEN
            lbdf    ed_wsave_openerr

            mov     rf, ed_save_i
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_wsave_loop:
            call    ed_ldw_rd
            dw      ed_save_i
            call    ed_ldw_r8
            dw      ed_w_count

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_wsave_done       ; DF=1: save_i >= count -- done
                                        ; (0-based counter against a
                                        ; COUNT -- >= is the correct
                                        ; terminator here, NOT the
                                        ; 1-based-line-vs-last shape
                                        ; ed_cmd_r's own bug was in)

            call    ed_ldw_rd
            dw      ed_save_i
            call    ed_line_info

            call    ed_ldw_r8
            dw      ed_li_ptr
            mov     rf, ed_li_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            mov     rf, r8
            mov     rd, ed_fcb
            call    K_FILE_WRITE
            lbdf    ed_wsave_werr

            mov     rf, ed_crlf
            ldi     0
            phi     rc
            ldi     2
            plo     rc
            mov     rd, ed_fcb
            call    K_FILE_WRITE
            lbdf    ed_wsave_werr

            call    ed_ldw_rd
            dw      ed_save_i
            inc     rd
            call    ed_stw_rd
            dw      ed_save_i
            lbr     ed_wsave_loop

ed_wsave_done:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE

            ; update ed_filename_ptr to the target just written -- see
            ; this section's own header comment for why
            call    ed_ldw_rd
            dw      ed_w_filename_ptr
            call    ed_stw_rd
            dw      ed_filename_ptr

            mov     rf, ed_wsave_is_e
            ldn     rf
            lbz     ed_cmdloop          ; W: return to the prompt
            ldi     0                   ; E: exit with success
            rtn

ed_wsave_werr:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            mov     rf, ed_wsave_is_e
            ldn     rf
            lbz     ed_cmdloop
            ldi     1
            rtn

ed_wsave_openerr:
            call    K_INMSG
            db      "Cannot create file.",13,10,0
            mov     rf, ed_wsave_is_e
            ldn     rf
            lbz     ed_cmdloop
            ldi     1
            rtn

ed_wsave_rangeerr:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

ed_wsave_no_name:
            ; always returns to the prompt regardless of W/E -- a
            ; missing filename with no fallback is trivially
            ; recoverable (just retype the command with a name) and
            ; shouldn't cost the whole edit session
            call    K_INMSG
            db      "No filename.",13,10,0
            lbr     ed_cmdloop

;==================================================================
; S - search
;==================================================================

; [range][?]S<text> -- case-sensitive literal substring search,
; matching FreeDOS edlin's own "[#][,#][?]s$" syntax (2026-07-20).
; Range defaults to (cur_line+1, line_count) -- NOT the whole file --
; so a plain "S" naturally continues forward from wherever the last
; match (or edit) left cur_line; "Not found." if cur_line is already
; the last line, rather than a range error. An explicit [n] still
; searches from n to the end, same as before. Stops at and displays
; the FIRST matching line in range, setting cur_line to it; "Not
; found." if nothing matches. With the "?" flag, prompts "O.K.? "
; after landing on a match -- answering Y stops there (same as the
; no-"?" case); anything else resumes searching from the next line
; through the end of the same range, so "1?sfoo" then repeated
; "N" answers steps through every occurrence until "Not found." (no
; need to remember/retype the search text, since a bare "S" always
; means "search again from here" once cur_line has advanced).
ed_cmd_s:
            inc     rf                  ; skip the 'S' letter itself
            call    f_ltrim             ; skip an optional space before
                                        ; the search text ("S text" or
                                        ; "Stext" both work)
            mov     rd, ed_s_text_ptr
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd

            ldn     rf
            lbz     ed_s_no_text        ; nothing to search for

            call    ed_strlen           ; RD = length (RF now points at
                                        ; the text's own NUL terminator
                                        ; -- unused below, ed_s_text_ptr
                                        ; was already saved above)
            mov     r8, rd              ; stash before the range-calc
                                        ; code below reuses RD heavily
            call    ed_stw_r8
            dw      ed_s_text_len

            ; first = have_n1 ? n1 : 1
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_s_first_default

            call    ed_ldw_rd
            dw      ed_n1
            ghi     rd
            lbnz    ed_s_first_ok
            glo     rd
            lbz     ed_s_err            ; n1 == 0: invalid
ed_s_first_ok:
            call    ed_stw_rd
            dw      ed_s_first
            lbr     ed_s_first_done

ed_s_first_default:
            ; FreeDOS edlin compatibility (2026-07-20): default first =
            ; cur_line + 1 (search starts on the line AFTER the
            ; current one), not the whole file from line 1 -- this is
            ; what lets a bare "S" naturally continue forward on a
            ; second press after landing on a match, without needing
            ; to remember the last search text.
            call    ed_ldw_rd
            dw      ed_cur_line  ; RD = cur_line
            inc     rd            ; RD = cur_line + 1

            call    ed_ldw_r8
            dw      ed_line_count  ; R8 = line_count

            ; cur_line+1 > line_count ? (already at/past the last line
            ; -- nothing left to search from here). Report "Not
            ; found." directly rather than falling into the range
            ; validator below, which is reserved for a genuinely bad
            ; EXPLICIT line number.
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_s_not_found      ; DF=0: line_count < cur_line+1

            call    ed_stw_rd
            dw      ed_s_first

ed_s_first_done:
            ; last = have_n2 ? n2 : line_count
            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_s_last_default

            call    ed_ldw_rd
            dw      ed_n2
            call    ed_stw_rd
            dw      ed_s_last
            lbr     ed_s_range_ready

ed_s_last_default:
            mov     rf, ed_s_last
            mov     rd, ed_line_count
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

ed_s_range_ready:
            ; validate: 1 <= first <= last <= line_count
            call    ed_ldw_rd
            dw      ed_s_first  ; RD = first
            call    ed_ldw_r8
            dw      ed_s_last  ; R8 = last

            ; last >= first ?
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_s_err

            call    ed_ldw_r9
            dw      ed_line_count

            ; line_count >= last ?
            glo     r8
            str     r2
            glo     r9
            sm
            ghi     r8
            str     r2
            ghi     r9
            smb
            lbnf    ed_s_err

            ; scan lines [first-1 .. last-1] (0-based)
            call    ed_ldw_rd
            dw      ed_s_first
            dec     rd
            call    ed_stw_rd
            dw      ed_s_scan_i

ed_s_scan_loop:
            call    ed_ldw_rd
            dw      ed_s_scan_i  ; RD = scan_i (0-based)
            inc     rd            ; RD = 1-based line number
            call    ed_ldw_r8
            dw      ed_s_last

            ; 1-based scan number > last ? -> done, not found
            ; BUG FIX (hardware-found, 2026-07-19): operands were loaded
            ; in the wrong order for a STRICT ">" comparison -- the
            ; original code computed "scan >= last" (branching to
            ; ed_s_not_found one iteration too early, at scan==last),
            ; which meant the LAST line of any search range was never
            ; actually checked by ed_line_contains. For the default
            ; whole-file range that's the file's last line; for a
            ; single-line range (nS) it fires on the very first and
            ; only iteration, making that form of the command always
            ; report "Not found." regardless of content. Fixed by
            ; computing "last - scan" instead (DF=1 iff last>=scan,
            ; i.e. scan<=last) and branching away only when DF=0
            ; (scan>last, a genuine strict inequality).
            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_s_not_found

            call    ed_ldw_rd
            dw      ed_s_scan_i
            call    ed_line_info        ; sets ed_li_ptr/ed_li_len for
                                        ; this candidate line

            call    ed_line_contains
            lbnf    ed_s_found

            call    ed_ldw_rd
            dw      ed_s_scan_i
            inc     rd
            call    ed_stw_rd
            dw      ed_s_scan_i
            lbr     ed_s_scan_loop

ed_s_found:
            call    ed_ldw_rd
            dw      ed_s_scan_i
            inc     rd            ; RD = 1-based line number
            call    ed_stw_rd
            dw      ed_cur_line

            mov     rf, ed_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ed_num_buf
            call    K_MSG
            call    K_INMSG
            db      ": ",0

            call    ed_ldw_rd
            dw      ed_s_scan_i
            call    ed_print_line
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_have_confirm
            ldn     rf
            lbz     ed_cmdloop          ; no "?": stop here, as before

            ; "?" given: ask whether this is the one. Matches FreeDOS
            ; edlin: answering Y stops here; anything else resumes the
            ; search from the next line. Follows copy.asm's own
            ; established Y/N-prompt pattern exactly (K_READ, stash to
            ; MEMORY not a register since only R9 is confirmed to
            ; survive K_TTY/K_INMSG -- gotcha #8 -- then K_TTY to echo,
            ; then reload fresh for the check).
            call    K_INMSG
            db      "O.K.? ",0

            call    K_READ              ; D = character read (blocking)
            plo     rc                  ; short-lived stash, not across
                                        ; a call -- just to survive the
                                        ; "mov rf, ed_s_answer" D-clobber
            mov     rf, ed_s_answer
            glo     rc
            str     rf                  ; ed_s_answer = character

            call    K_TTY               ; echo it back to the console
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_s_answer
            ldn     rf                  ; D = the character read
            ani     $DF                 ; fold lowercase to uppercase
            xri     'Y'
            lbz     ed_cmdloop          ; "yes": stop here, as before

            ; anything else: keep searching from the line after this
            ; match, through the end of the already-established range
            call    ed_ldw_rd
            dw      ed_s_scan_i
            inc     rd
            call    ed_stw_rd
            dw      ed_s_scan_i
            lbr     ed_s_scan_loop

ed_s_not_found:
            call    K_INMSG
            db      "Not found.",13,10,0
            lbr     ed_cmdloop

ed_s_no_text:
            call    K_INMSG
            db      "Search text required.",13,10,0
            lbr     ed_cmdloop

ed_s_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_line_contains: does the line described by ed_li_ptr/ed_li_len
; (haystack) contain the text at ed_s_text_ptr/ed_s_text_len (needle,
; must be non-empty -- callers guarantee this) as a substring, tried
; at every possible starting offset (naive search, lines here are at
; most 127 bytes so this is cheap)?
; Args:    ed_li_ptr/ed_li_len, ed_s_text_ptr/ed_s_text_len
; Returns: DF = 0 if found, DF = 1 if not
;------------------------------------------------------------------
ed_line_contains:
            mov     rf, ed_lc_outer
            ldi     0
            str     rf
            inc     rf
            str     rf

elc_outer_loop:
            ; remaining = haystack_len - outer (can't borrow: outer
            ; only ever advances while remaining >= needle_len, so it
            ; never exceeds haystack_len before this loop exits)
            call    ed_ldw_rd
            dw      ed_li_len  ; RD = haystack_len
            call    ed_ldw_r8
            dw      ed_lc_outer  ; R8 = outer

            glo     r8
            str     r2
            glo     rd
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     rd
            smb
            phi     rc                  ; RC = remaining

            call    ed_ldw_r9
            dw      ed_s_text_len  ; R9 = needle_len

            ; remaining >= needle_len ?
            glo     r9
            str     r2
            glo     rc
            sm
            ghi     r9
            str     r2
            ghi     rc
            smb
            lbnf    elc_not_found       ; DF=0: remaining < needle_len

            mov     rf, ed_lc_inner
            ldi     0
            str     rf
            inc     rf
            str     rf

elc_inner_loop:
            call    ed_ldw_rd
            dw      ed_lc_inner  ; RD = inner
            call    ed_ldw_r8
            dw      ed_s_text_len

            ; inner >= needle_len ? -> every byte matched
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    elc_match

            ; haystack[outer+inner] == needle[inner] ?
            ;
            ; ROOT CAUSE (found 2026-07-20 via several rounds of
            ; targeted hardware diagnostics, after extensive static
            ; review of this comparison's own logic repeatedly found
            ; nothing wrong with it): ADD16/SUB16's register-register
            ; form uses M(R2) as its own internal scratch space --
            ; confirmed by decoding its real opcode expansion in
            ; include/opcodes.def, where "STR R2" (byte 0x52) appears
            ; twice. Every other comparison in this whole codebase
            ; follows the same tight "str r2, then IMMEDIATELY
            ; sm/smb/xor" idiom with nothing in between -- this was
            ; the one place that broke it: the original code computed
            ; the haystack address, staged its byte via "str r2", THEN
            ; computed the needle address via a THIRD add16 -- silently
            ; destroying the just-staged haystack byte before the
            ; "xor" ever ran. The algorithm itself was always correct;
            ; this was a previously-undiscovered toolchain-level side
            ; effect of ADD16 (does NOT affect the immediate-constant
            ; form, "add16 reg,CONSTANT", which uses ADI/ADCI instead
            ; and never touches memory -- only the register-register
            ; form is affected). Fixed by computing BOTH addresses
            ; first, so no add16/sub16 ever runs between "str r2" and
            ; the compare that depends on it.
            call    ed_ldw_r8
            dw      ed_li_ptr
            call    ed_ldw_r9
            dw      ed_lc_outer
            add16   r8, r9
            call    ed_ldw_r9
            dw      ed_lc_inner
            add16   r8, r9              ; R8 = &haystack[outer+inner]

            mov     rf, ed_s_text_ptr
            lda     rf
            phi     rb
            ldn     rf
            plo     rb
            call    ed_ldw_r9
            dw      ed_lc_inner
            add16   rb, r9              ; RB = &needle[inner] -- both
                                        ; addresses fully computed now;
                                        ; no more add16/sub16 calls
                                        ; happen before the compare
                                        ; below

            mov     rf, r8
            ldn     rf
            str     r2                  ; M(R2) = haystack byte

            mov     rf, rb
            ldn     rf                  ; D = needle byte

            xor                         ; D = needle ^ haystack
            lbnz    elc_mismatch

            call    ed_ldw_rd
            dw      ed_lc_inner
            inc     rd
            call    ed_stw_rd
            dw      ed_lc_inner
            lbr     elc_inner_loop

elc_mismatch:
            call    ed_ldw_rd
            dw      ed_lc_outer
            inc     rd
            call    ed_stw_rd
            dw      ed_lc_outer
            lbr     elc_outer_loop

elc_match:
            clc
            rtn

elc_not_found:
            stc
            rtn

;==================================================================
; EOF handling (redirected input exhausted -- see K_INPUTL's own
; DF=1 contract, kernel_api.inc)
;==================================================================

ed_eof_quit:
            call    K_INMSG
            db      13,10,0
            ldi     0                   ; exit code 0 -- same as a
                                        ; confirmed Q, unsaved edits
                                        ; abandoned
            rtn

;==================================================================
; Q - quit without saving
;==================================================================

ed_cmd_q:
            call    K_INMSG
            db      "Abort edits (Y/N)? ",0
            call    K_READ
            plo     rc                  ; stash (mov below clobbers D)
            mov     rf, ed_key
            glo     rc
            str     rf

            mov     rf, ed_key
            ldn     rf                  ; D = char (reloaded)
            call    K_TTY
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_key
            ldn     rf
            ani     $DF
            xri     'Y'
            lbnz    ed_cmdloop

            ldi     0
            rtn

;==================================================================
; Data
;==================================================================

ed_lines:       ds      ED_MAX_LINES*2
ed_line_count:  dw      0
ed_text_len:    dw      0
ed_cur_line:    dw      0
ed_buf_start:   dw      0
ed_buf_end:     dw      0
ed_filename_ptr: dw     0
ed_w_filename_ptr: dw   0
ed_w_count:      dw     0
ed_wsave_is_e:   db     0          ; 0 = the current W/E call was W
                                    ; (return to the prompt when done),
                                    ; nonzero = it was E (exit when done)
ed_fcb:         ds      FCB_LEN
ed_iobuf:       ds      FCB_IOBUF_LEN

; ed_getbyte's own buffered-read state (see its header comment)
ed_rdbuf:       ds      ED_RDBUF_LEN
ed_rdbuf_pos:   dw      0           ; next unread byte's offset
ed_rdbuf_len:   dw      0           ; valid byte count currently in
                                    ; ed_rdbuf (from the last refill)
ed_getbyte_ioerr: db    0           ; set nonzero only when ed_getbyte's
                                    ; DF=1 return was a real K_FILE_READ
                                    ; error, not true end-of-file
ed_input_buf:   ds      128
ed_lineref_base: dw    0           ; ed_parse_lineref's own epl_plus/
                                    ; epl_minus: memory stash for the
                                    ; base value across the call to
                                    ; ed_parse_uint (which clobbers R9
                                    ; internally -- see their own
                                    ; header comments)
ed_have_n1:     db      0
ed_n1:          dw      0
ed_have_n2:     db      0
ed_n2:          dw      0
ed_have_n3:     db      0           ; C/M only -- see ed_parse_range's
ed_n3:          dw      0           ; own header comment
ed_have_n4:     db      0           ; C only (repeat count)
ed_n4:          dw      0

; ed_cmd_c scratch
ed_c_first:     dw      0
ed_c_last:      dw      0
ed_c_shift:     db      0
ed_c_count:     dw      0
ed_c_blocklen:  dw      0
ed_c_n:         dw      0
ed_c_ins_pos:   dw      0
ed_c_k:         dw      0
ed_c_i:         dw      0

ed_have_confirm: db     0           ; "?" seen between the range and
                                    ; the command letter -- currently
                                    ; only S looks at this
ed_s_answer:    db      0           ; S's own "O.K.?" Y/N answer,
                                    ; stashed to memory (not a
                                    ; register) across K_TTY/K_INMSG
ed_list_i:      dw      0
ed_list_last:   dw      0
ed_list_start_i: dw     0          ; ed_list_i's own starting value,
                                    ; snapshotted once per L/P call so
                                    ; ed_list_finish can tell "at least
                                    ; one line was shown" from "the
                                    ; range was empty"
ed_t_filename_ptr: dw   0           ; T's own transfer-source filename
ed_t_line_len:  dw      0           ; T's own per-line accumulation
                                    ; length into ed_input_buf

; ed_cmd_r scratch
ed_r_old_ptr:   dw      0
ed_r_old_len:   dw      0
ed_r_new_ptr:   dw      0
ed_r_new_len:   dw      0
ed_r_first:     dw      0
ed_r_last:      dw      0
ed_r_line_idx:  dw      0
ed_r_count:     dw      0           ; lines actually changed, for the
                                    ; final "N replacement(s) made"
ed_r_out_len:   dw      0
ed_r_src_pos:   dw      0
ed_r_changed:   db      0
ed_line_scratch:   ds      128         ; a SEPARATE buffer from
                                    ; ed_input_buf -- see
                                    ; ed_insert_one's own header
                                    ; comment for why

ed_page_lines:  db      ED_PAGE_LINES   ; overridden if ROWS is set
ed_list_page_count: db  0
ed_rows_name:   db      "ROWS",0
ed_num_buf:     ds      8
ed_key:         db      0
ed_crlf:        db      13,10

; ed_line_info scratch
ed_li_idx:      dw      0
ed_li_start_off: dw     0
ed_li_ptr:      dw      0
ed_li_len:      dw      0

; ed_copy_fwd/ed_copy_bwd scratch
ed_mv_src:      dw      0
ed_mv_dst:      dw      0
ed_mv_count:    dw      0

; ed_cmd_i / ed_insert_one scratch
ed_i_target:    dw      0
ed_i_text_len:  dw      0
ed_i_ins_idx:   dw      0
ed_i_ins_off:   dw      0
ed_i_shift:     dw      0
ed_i_wr_ptr:    dw      0
ed_i_src_ptr:   dw      0
ed_i_wr_count:  dw      0
ed_i_shift_i:   dw      0
ed_i_source_buf: dw     0           ; caller-supplied source buffer
                                    ; address -- see ed_insert_one's
                                    ; own header comment

; ed_cmd_d scratch
ed_d_first:     dw      0
ed_d_last:      dw      0
ed_d_start_off: dw      0
ed_d_end_off:   dw      0
ed_d_removed:   dw      0
ed_d_shift_src: dw      0
ed_d_shift_dst: dw      0

; ed_cmd_e scratch
ed_save_i:      dw      0

; ed_cmd_s / ed_line_contains scratch
ed_s_text_ptr:  dw      0
ed_s_text_len:  dw      0
ed_s_first:     dw      0
ed_s_last:      dw      0
ed_s_scan_i:    dw      0
ed_lc_outer:    dw      0
ed_lc_inner:    dw      0

            end     start
