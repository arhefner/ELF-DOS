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
; See the project plan file for the full design writeup and what's
; deliberately deferred (S/R/C/M/T/#, multi-line ranges beyond a plain
; n/n,m pair, in-place bare-number replace, dirty-flag tracking,
; chunked saves).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

ED_MAX_LINES:   equ     512         ; line-offset table capacity

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
            call    K_FILE_OPEN
            lbdf    ed_cmdloop          ; not found: start empty (new
                                        ; file) -- matches edlin's own
                                        ; behavior

            plo     rd                  ; stash handle (mov below
                                        ; clobbers D)
            mov     rf, ed_handle
            glo     rd
            str     rf

            call    ed_load_file
            lbdf    ed_load_err

            mov     rf, ed_handle
            ldn     rf
            call    K_FILE_CLOSE
            lbr     ed_cmdloop

ed_load_err:
            mov     rf, ed_handle
            ldn     rf
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
; ed_load_file: read the open file (handle in ed_handle) into
; ed_buf/ed_lines, one byte at a time via K_FILE_READ, silently
; skipping CR and splitting on LF (same shape as kernel/batch.asm's
; own batch_readline this project already built and hardware-tested).
; Args:    none
; Returns: DF = 0 on success, DF = 1 on a real I/O error
;------------------------------------------------------------------
ed_load_file:
            call    ed_start_line
            lbdf    el_toolong

el_byte_loop:
            mov     rf, ed_scratch
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     ra, ed_handle
            ldn     ra
            call    K_FILE_READ
            lbdf    el_err

            glo     rc
            lbz     el_eof              ; 0 bytes: end of file

            mov     rf, ed_scratch
            ldn     rf
            xri     13                  ; CR?
            lbz     el_byte_loop        ; skip silently

            mov     rf, ed_scratch
            ldn     rf                  ; reload -- xri above destroyed D
            xri     10                  ; LF?
            lbz     el_line_done

            mov     rf, ed_scratch
            ldn     rf                  ; D = the real byte
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
            call    K_INMSG
            db      13,10,0

            mov     rf, ed_input_buf
            call    f_ltrim

            ldn     rf
            lbz     ed_cmdloop          ; empty line: re-prompt

            call    ed_parse_range      ; RF advances past any number(s)

            ldn     rf
            lbz     ed_bare_number      ; nothing after the number(s)

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
            lbr     ed_cmdloop

;==================================================================
; L - list
;==================================================================

ed_cmd_l:
            mov     rf, ed_list_i
            ldi     0
            str     rf
            inc     rf
            str     rf

ed_list_loop:
            mov     rf, ed_list_i
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
            lbdf    ed_cmdloop          ; list_i >= line_count: done

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
            lbr     ed_d_do

ed_d_err:
            call    K_INMSG
            db      "Line number out of range.",13,10,0
            lbr     ed_cmdloop

ed_d_do:
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

            call    K_INMSG
            db      "Deleted.",13,10,0
            lbr     ed_cmdloop

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
            call    K_FILE_OPEN
            lbdf    ed_save_open_err

            plo     rd
            mov     rf, ed_handle
            glo     rd
            str     rf

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
            mov     rd, ed_handle
            ldn     rd
            call    K_FILE_WRITE
            lbdf    ed_save_werr

            mov     rf, ed_crlf
            ldi     0
            phi     rc
            ldi     2
            plo     rc
            mov     rd, ed_handle
            ldn     rd
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
            mov     rf, ed_handle
            ldn     rf
            call    K_FILE_CLOSE
            ldi     0
            rtn

ed_save_werr:
            mov     rf, ed_handle
            ldn     rf
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
ed_handle:      db      0
ed_scratch:     db      0
ed_input_buf:   ds      128
ed_have_n1:     db      0
ed_n1:          dw      0
ed_have_n2:     db      0
ed_n2:          dw      0
ed_list_i:      dw      0
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

            end     start
