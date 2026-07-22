;
; edlin.asm - line editor for ELF-DOS
;
; Usage: EDLIN <filename>
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

            extrn   env_getenv
            extrn   env_parse_uint

ED_MAX_LINES:   equ     512         ; line-offset table capacity
ED_RDBUF_LEN:   equ     512         ; ed_getbyte's own read-ahead
                                    ; buffer, one K_FILE_READ call's
                                    ; worth -- matches FCB_IOBUF_LEN
                                    ; (one sector), the same size
                                    ; COPY_CHUNK_LEN settled on for the
                                    ; identical per-call-overhead reason
ED_PAGE_LINES:  equ     23          ; L command's own page size
                                    ; default (same "-1 for the
                                    ; prompt" reasoning as more.asm's
                                    ; own MORE_PAGE_LINES); overridden
                                    ; by ROWS-1 if ROWS is set, see
                                    ; start's own env-reading block

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
            ; program's own name; argv[1] is the filename argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no filename given

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
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

            ; ed_buf_start = mem_base, ed_buf_end = mem_top, both from
            ; LOADER_ARGS (word0/word1, big-endian -- see
            ; kernel/loader.asm's own _prog_finish_load, which writes
            ; them in exactly this layout)
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rf, ed_buf_start
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, LOADER_ARGS
            add16   rf, 2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            mov     rf, ed_buf_end
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
            ; small (<2, leaving no room after subtracting 1 for the
            ; "-- More --" prompt). Read once, here -- RA/RC (entry
            ; argv/argc) are already fully consumed by this point, and
            ; nothing below needs anything env_getenv/env_parse_uint
            ; might clobber. ---
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
            sub16   rd, 1               ; RD = ROWS - 1
            mov     rb, ed_page_lines
            glo     rd
            str     rb                  ; ed_page_lines = RD.lo

ed_open_file:
            ; --- open and load the file, if it exists ---
            mov     rf, ed_filename_ptr
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; RA = filename pointer
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

usage:
            call    K_INMSG
            db      "Usage: EDLIN <filename>",13,10,0
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
            mov     rf, ed_rdbuf_pos
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_rdbuf_pos
            mov     rf, ed_rdbuf_len
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; RA = ed_rdbuf_len

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

            add16   rd, 1               ; RD = pos+1
            mov     rf, ed_rdbuf_pos
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ed_rdbuf_pos = pos+1

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
            mov     rf, ed_rdbuf_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; ed_rdbuf_len = RC

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

            mov     rf, ed_buf_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_buf_start
            mov     rf, ed_text_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ed_text_len
            add16   rd, r8              ; RD = write position (absolute)

            mov     rf, ed_buf_end
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ed_buf_end

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

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_text_len
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ed_text_len++

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
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_line_count

            ldi     low ED_MAX_LINES
            str     r2
            glo     rd
            sm
            ldi     high ED_MAX_LINES
            str     r2
            ghi     rd
            smb
            lbdf    esl_full            ; DF=1: line_count >= ED_MAX_LINES

            mov     rf, ed_text_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ed_text_len

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
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_line_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; ed_cur_line_has_bytes: does the line currently being read (started
; by the most recent ed_start_line) have any content yet?
; Returns: DF = 1 if ed_text_len > ed_lines[ed_line_count], else DF = 0
;------------------------------------------------------------------
ed_cur_line_has_bytes:
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_line_count
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ed_lines[ed_line_count]
                                        ; (this line's own start offset)

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_text_len

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            rtn                         ; DF=1 iff ed_text_len > start
                                        ; offset (has content)

;==================================================================
; Shared line-info / block-move helpers
;==================================================================

;------------------------------------------------------------------
; ed_line_info: compute a line's absolute start pointer and byte
; length (excluding its trailing LF separator).
; Args:    RD = 0-based line index (must be < ed_line_count)
; Returns: ed_li_ptr = absolute pointer to the line's first byte
;          ed_li_len = length in bytes (0 for an empty line)
;------------------------------------------------------------------
ed_line_info:
            mov     rf, ed_li_idx
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            shl16   rd                  ; RD = index * 2
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = start offset

            mov     rf, ed_li_start_off
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            mov     rf, ed_li_idx
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = index+1

            mov     rf, ed_line_count
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

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
            mov     rf, ed_text_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = end offset (= ed_text_len)

eli_have_end:
            mov     rf, ed_buf_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ed_buf_start
            mov     rf, ed_li_start_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = start offset (reloaded)
            add16   rd, r8              ; RD = absolute start pointer

            mov     rf, ed_li_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
            mov     rf, ed_li_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            rtn

;------------------------------------------------------------------
; ed_copy_fwd: copy ed_mv_count bytes from ed_mv_src to ed_mv_dst,
; walking low-to-high. Safe when dst < src (closing a gap, e.g. after
; a delete).
;------------------------------------------------------------------
ed_copy_fwd:
            mov     rf, ed_mv_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    ecf_have
            glo     rd
            lbz     ecf_done
ecf_have:
            mov     rf, ed_mv_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            ldn     rf
            plo     r9                  ; stash the byte

            mov     rf, ed_mv_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            glo     r9
            str     rf

            mov     rf, ed_mv_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_mv_src
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_mv_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_mv_dst
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_mv_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_mv_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
            mov     rf, ed_mv_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    ecb_have
            glo     rd
            lbz     ecb_done
ecb_have:
            mov     rf, ed_mv_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_mv_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8
            sub16   rd, 1               ; RD = src_end
            mov     rf, rd
            ldn     rf
            plo     r9                  ; stash the byte

            mov     rf, ed_mv_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_mv_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8
            sub16   rd, 1               ; RD = dst_end
            mov     rf, rd
            glo     r9
            str     rf

            mov     rf, ed_mv_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_mv_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
            add16   rd, 1
            lbr     estr_loop
estr_done:
            rtn

;------------------------------------------------------------------
; ed_print_line: print a line's raw text (no trailing newline).
; Args:    RD = 0-based line index
;------------------------------------------------------------------
ed_print_line:
            call    ed_line_info

            mov     rf, ed_li_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
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
            call    K_INPUTL
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

ed_unknown_cmd:
            call    K_INMSG
            db      "? Unknown command.",13,10,0
            lbr     ed_cmdloop

ed_num_range_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

;------------------------------------------------------------------
; ed_parse_range: parse an optional "N" or "N,M" prefix.
; Args:    RF = current parse position
; Returns: RF advanced past any parsed number(s); ed_have_n1/ed_n1/
;          ed_have_n2/ed_n2 set accordingly
;------------------------------------------------------------------
ed_parse_range:
            mov     rb, ed_have_n1
            ldi     0
            str     rb
            mov     rb, ed_have_n2
            ldi     0
            str     rb

            call    ed_parse_num
            lbdf    epr_done            ; no digit at all: bare command

            mov     rb, ed_have_n1
            ldi     1
            str     rb
            mov     rb, ed_n1
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            ldn     rf
            xri     ','
            lbnz    epr_done

            inc     rf                  ; skip the comma
            call    ed_parse_num
            lbdf    epr_done            ; trailing comma, no second
                                        ; number: treat as single-number

            mov     rb, ed_have_n2
            ldi     1
            str     rb
            mov     rb, ed_n2
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

epr_done:
            rtn

;------------------------------------------------------------------
; ed_parse_num: parse a decimal number at RF.
; Args:    RF = position
; Returns: DF = 0 with RD = value, RF advanced past the digits;
;          DF = 1 if no digit at RF (RF unchanged)
;------------------------------------------------------------------
ed_parse_num:
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

            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = n1

            ghi     rd
            lbnz    ed_num_range_err
            glo     rd
            lbz     ed_num_range_err    ; n1 == 0: invalid

            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1               ; RD = n1 - 1 (0-based index)
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
            call    K_INPUTL
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
            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = n1 (1-based, already
                                        ; range-validated above)
            mov     rf, ed_i_target
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_input_buf
            call    ed_strlen
            mov     rf, ed_i_text_len
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            call    ed_insert_one
            lbdf    ed_edit_toolong

            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = n1+1 (old line's new
                                        ; 1-based position, after the
                                        ; insert shifted it down)
            mov     rf, ed_d_first
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, ed_d_last
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
; L - list
;==================================================================

ed_cmd_l:
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_l_full           ; no range: list every line
                                        ; (now paged every ed_page_lines
                                        ; lines -- see ed_list_loop's
                                        ; own pause-prompt logic below --
                                        ; rather than DOS's classic
                                        ; 23-line default window)

            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = n1 (1-based)

            ghi     rd
            lbnz    ed_l_n1_ok
            glo     rd
            lbz     ed_l_err            ; n1 == 0: invalid
ed_l_n1_ok:
            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = line_count

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

            sub16   rd, 1               ; RD = n1 - 1 (0-based start)
            mov     rf, ed_list_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_l_single         ; only n1: list just that line

            mov     rf, ed_n2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = n2 (1-based)

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

            mov     rf, ed_list_last
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     ed_list_start

ed_l_single:
            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_list_last
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     ed_list_start

ed_l_full:
            mov     rf, ed_list_i
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, ed_list_last
            mov     rd, ed_line_count
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ed_list_start

ed_l_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

ed_list_start:
            mov     rf, ed_list_page_count
            ldi     0
            str     rf                  ; reset the page counter --
                                        ; once, here, before the loop
                                        ; begins (NOT inside the loop
                                        ; itself, which also reaches
                                        ; ed_list_loop directly via its
                                        ; own back-edge below)

ed_list_loop:
            mov     rf, ed_list_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_list_last
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_cmdloop          ; list_i >= list_last: done

            mov     rf, ed_list_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = 1-based line number
            mov     rf, ed_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ed_num_buf
            call    K_MSG
            call    K_INMSG
            db      ": ",0

            mov     rf, ed_list_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = list_i (0-based, for
                                        ; ed_print_line)
            call    ed_print_line
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_list_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_list_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- pause every ed_page_lines lines. Reuses the exact
            ; K_READ/K_TTY prompt idiom the S command's own O.K.?
            ; prompt already established above (memory, not a
            ; register, across K_TTY/K_INMSG -- only R9 is confirmed
            ; to survive those, gotcha #8). ---
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

            call    K_INMSG
            db      "-- More --",0

            call    K_READ              ; D = character read (blocking)
            plo     rc                  ; short-lived stash, not
                                        ; across a call -- just to
                                        ; survive the "mov rf,
                                        ; ed_list_answer" D-clobber
            mov     rf, ed_list_answer
            glo     rc
            str     rf                  ; ed_list_answer = character

            call    K_TTY               ; echo it back to the console
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_list_page_count
            ldi     0
            str     rf                  ; reset the page counter

            mov     rf, ed_list_answer
            ldn     rf
            ani     $DF                 ; uppercase-fold
            xri     'Q'
            lbz     ed_cmdloop          ; quit the listing early

            lbr     ed_list_loop

;==================================================================
; A - append (insert at end of file)
;==================================================================

; A leading line number, if any, was already parsed by ed_parse_range
; but is deliberately ignored here -- append always targets the very
; end of the file, unlike I (which defaults to cur_line). Reuses the
; same validate/prompt/loop as I, just with the target pre-set, so the
; append/insert mechanics themselves have exactly one implementation.
ed_cmd_a:
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = line_count + 1 (append
                                        ; position -- always valid,
                                        ; ed_i_validate's range check
                                        ; is a no-op here but reusing
                                        ; it costs nothing)
            mov     rf, ed_i_target
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
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
            ; 1 <= target <= line_count+1
            mov     rf, ed_i_target
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    ed_i_err
            glo     rd
            lbz     ed_i_err

            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, 1               ; R8 = line_count+1

            glo     rd
            str     r2
            glo     r8
            sm
            ghi     rd
            str     r2
            ghi     r8
            smb
            lbnf    ed_i_err

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
            call    K_INPUTL
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
            mov     rf, ed_i_text_len
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            call    ed_insert_one
            lbdf    ed_i_toolong

            mov     rf, ed_i_target
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_i_target
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

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
; ed_insert_one: insert the text in ed_input_buf (length
; ed_i_text_len) as a new line before ed_i_target (1-based).
; Returns: DF = 0 on success, DF = 1 if out of room
;------------------------------------------------------------------
ed_insert_one:
            ; capacity_left = (buf_end - buf_start) - ed_text_len
            mov     rf, ed_buf_end
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_buf_start
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

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

            mov     rf, ed_i_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = bytes needed (text + LF)

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

            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
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
            mov     rf, ed_i_target
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_i_ins_idx
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; insert_offset = (ins_idx < line_count) ? ed_lines[ins_idx]
            ; : ed_text_len
            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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
            mov     rf, ed_text_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

eio_have_off:
            mov     rf, ed_i_ins_off
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, ed_i_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_i_shift
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- shift ed_buf's tail forward to open a gap ---
            mov     rf, ed_buf_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_ins_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8              ; RD = absolute insert_offset
            mov     rf, ed_mv_src
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_i_shift
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8              ; RD = ed_mv_src + shift
            mov     rf, ed_mv_dst
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_ins_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
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
            mov     rf, ed_mv_count
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            call    ed_copy_bwd

            ; --- write the new text + LF into the freed gap ---
            mov     rf, ed_mv_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_wr_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_input_buf
            mov     rd, ed_i_src_ptr
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd

            mov     rf, ed_i_wr_count
            mov     rd, ed_i_text_len
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

eio_wr_loop:
            mov     rf, ed_i_wr_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    eio_wr_have
            glo     rd
            lbz     eio_wr_lf
eio_wr_have:
            mov     rf, ed_i_src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            ldn     rf
            plo     r9

            mov     rf, ed_i_wr_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            glo     r9
            str     rf

            mov     rf, ed_i_src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_i_src_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_i_wr_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_i_wr_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_i_wr_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_i_wr_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     eio_wr_loop

eio_wr_lf:
            mov     rf, ed_i_wr_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            ldi     10
            str     rf

            ; --- shift ed_lines[ins_idx..line_count-1] up by one
            ; slot, adding ed_i_shift to each moved entry's value ---
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_shift_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

eio_shift_loop:
            mov     rf, ed_i_shift_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_ins_idx
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_i_shift_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1               ; RD = src_index (shift_i - 1)

            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ed_lines[shift_i-1]

            mov     rf, ed_i_shift
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_i_shift_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            mov     rf, ed_i_shift_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_i_shift_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     eio_shift_loop

eio_shift_done:
            mov     rf, ed_i_ins_idx
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            mov     rd, ed_i_ins_off
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_line_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_i_shift
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
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
            mov     rf, ed_text_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

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
            mov     rf, ed_d_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    ed_d_err
            glo     rd
            lbz     ed_d_err            ; first == 0

            mov     rf, ed_d_last
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_line_count
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

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
            mov     rf, ed_d_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ed_d_start_off
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            ; end_off = (last < line_count) ? ed_lines[last] : ed_text_len
            mov     rf, ed_d_last
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = last (0-based index of
                                        ; the line right after the
                                        ; deleted range)

            mov     rf, ed_line_count
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

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
            mov     rf, ed_text_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

ed_d_have_end:
            mov     rf, ed_d_end_off
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; removed = end_off - start_off
            mov     rf, ed_d_start_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_end_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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
            mov     rf, ed_d_removed
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            ; --- shift ed_buf: [end_off, text_len) back to start_off ---
            mov     rf, ed_buf_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_end_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8              ; RD = absolute src
            mov     rf, ed_mv_src
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_buf_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_start_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8              ; RD = absolute dst
            mov     rf, ed_mv_dst
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_end_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
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
            mov     rf, ed_mv_count
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            call    ed_copy_fwd

            ; --- shift ed_lines[last..line_count-1] down to
            ; [first-1..], subtracting "removed" from each entry ---
            mov     rf, ed_d_last
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_shift_src
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_d_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_d_shift_dst
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

ed_d_shift_loop:
            mov     rf, ed_d_shift_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_d_shift_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ed_lines[shift_src]

            mov     rf, ed_d_removed
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_d_shift_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            mov     rf, ed_lines
            add16   rf, rd
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            mov     rf, ed_d_shift_src
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_d_shift_src
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_d_shift_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_d_shift_dst
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     ed_d_shift_loop

ed_d_shift_done:
            ; line_count -= (last - first + 1)
            mov     rf, ed_d_last
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_first
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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
            add16   rc, 1               ; RC = deleted-line count

            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

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

            mov     rf, ed_line_count
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; text_len -= removed
            mov     rf, ed_text_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_d_removed
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_text_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            ; cur_line = (first <= new line_count) ? first :
            ; (new line_count >= 1 ? new line_count : 1)
            mov     rf, ed_line_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = new line_count

            mov     rf, ed_d_first
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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
            mov     rf, ed_d_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

ed_d_cur_is_count:
            mov     rf, ed_cur_line
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            rtn

;==================================================================
; E - save and exit
;==================================================================

ed_cmd_e:
            mov     rf, ed_filename_ptr
            lda     rf
            phi     ra
            ldn     rf
            plo     ra
            mov     rf, ra
            mov     rd, ed_fcb
            mov     ra, ed_iobuf
            ldi     1                   ; mode = write/truncate
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; ed_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    ed_save_open_err

            mov     rf, ed_save_i
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_save_loop:
            mov     rf, ed_save_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ed_save_done

            mov     rf, ed_save_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    ed_line_info

            mov     rf, ed_li_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ed_li_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            mov     rf, r8
            mov     rd, ed_fcb
            call    K_FILE_WRITE
            lbdf    ed_save_werr

            mov     rf, ed_crlf
            ldi     0
            phi     rc
            ldi     2
            plo     rc
            mov     rd, ed_fcb
            call    K_FILE_WRITE
            lbdf    ed_save_werr

            mov     rf, ed_save_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_save_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     ed_save_loop

ed_save_done:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            ldi     0
            rtn

ed_save_werr:
            mov     rd, ed_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

ed_save_open_err:
            call    K_INMSG
            db      "Cannot create file.",13,10,0
            ldi     1
            rtn

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
            mov     rf, ed_s_text_len
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            ; first = have_n1 ? n1 : 1
            mov     rf, ed_have_n1
            ldn     rf
            lbz     ed_s_first_default

            mov     rf, ed_n1
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    ed_s_first_ok
            glo     rd
            lbz     ed_s_err            ; n1 == 0: invalid
ed_s_first_ok:
            mov     rf, ed_s_first
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     ed_s_first_done

ed_s_first_default:
            ; FreeDOS edlin compatibility (2026-07-20): default first =
            ; cur_line + 1 (search starts on the line AFTER the
            ; current one), not the whole file from line 1 -- this is
            ; what lets a bare "S" naturally continue forward on a
            ; second press after landing on a match, without needing
            ; to remember the last search text.
            mov     rf, ed_cur_line
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = cur_line
            add16   rd, 1               ; RD = cur_line + 1

            mov     rf, ed_line_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = line_count

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

            mov     rf, ed_s_first
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

ed_s_first_done:
            ; last = have_n2 ? n2 : line_count
            mov     rf, ed_have_n2
            ldn     rf
            lbz     ed_s_last_default

            mov     rf, ed_n2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ed_s_last
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
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
            mov     rf, ed_s_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = first
            mov     rf, ed_s_last
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = last

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

            mov     rf, ed_line_count
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

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
            mov     rf, ed_s_first
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, 1
            mov     rf, ed_s_scan_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

ed_s_scan_loop:
            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = scan_i (0-based)
            add16   rd, 1               ; RD = 1-based line number
            mov     rf, ed_s_last
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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

            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    ed_line_info        ; sets ed_li_ptr/ed_li_len for
                                        ; this candidate line

            call    ed_line_contains
            lbnf    ed_s_found

            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_s_scan_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     ed_s_scan_loop

ed_s_found:
            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1               ; RD = 1-based line number
            mov     rf, ed_cur_line
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ed_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ed_num_buf
            call    K_MSG
            call    K_INMSG
            db      ": ",0

            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
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
            mov     rf, ed_s_scan_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_s_scan_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
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
            mov     rf, ed_li_len
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = haystack_len
            mov     rf, ed_lc_outer
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = outer

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

            mov     rf, ed_s_text_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = needle_len

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
            mov     rf, ed_lc_inner
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = inner
            mov     rf, ed_s_text_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

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
            mov     rf, ed_li_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ed_lc_outer
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            add16   r8, r9
            mov     rf, ed_lc_inner
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            add16   r8, r9              ; R8 = &haystack[outer+inner]

            mov     rf, ed_s_text_ptr
            lda     rf
            phi     rb
            ldn     rf
            plo     rb
            mov     rf, ed_lc_inner
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
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

            mov     rf, ed_lc_inner
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_lc_inner
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     elc_inner_loop

elc_mismatch:
            mov     rf, ed_lc_outer
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, ed_lc_outer
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
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
ed_have_n1:     db      0
ed_n1:          dw      0
ed_have_n2:     db      0
ed_n2:          dw      0
ed_have_confirm: db     0           ; "?" seen between the range and
                                    ; the command letter -- currently
                                    ; only S looks at this
ed_s_answer:    db      0           ; S's own "O.K.?" Y/N answer,
                                    ; stashed to memory (not a
                                    ; register) across K_TTY/K_INMSG
ed_list_i:      dw      0
ed_list_last:   dw      0
ed_page_lines:  db      ED_PAGE_LINES   ; overridden if ROWS is set
ed_list_page_count: db  0
ed_list_answer: db      0
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
