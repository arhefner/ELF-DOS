;
; mdv.asm - show a Markdown file with ANSI styling
;
; Usage: MDV [-c] [-p] <filename>
;
; Renders Markdown the way md2ansi/mdcat do, for a terminal:
;   # headings        bold, in colour (levels 1-3 differ; 4-6 bold)
;   **bold** __bold__, *italic* _italic_, `code` (yellow)
;   [text](url)       text underlined, then " (url)" in green unless the
;                     url is the same as the text; ![alt](src) likewise
;   <http://...>      underlined
;   - * + and 1. 2)   list items, with a hanging indent for wrapped lines
;   > quote           a green bar down the left edge
;   ``` / ~~~ fences  and 4-space-indented code: yellow, 2-column margin
;   --- *** ___       a rule across the screen
;   | table rows |    kept one row per line, inline styling applied
; Paragraphs are joined and word-wrapped to the screen (lib/term.asm:
; TERMSIZE's copy, else COLUMNS, else 80), never writing the last
; column. Only the escapes below are used, so any VT100/ANSI terminal
; works: ESC[0m, ESC[1m bold, ESC[3m italic, ESC[4m underline, ESC[7m
; (the prompt), and the 30-37 colours. Italic is not shown by every
; terminal (minicom, for one); the rest is VT100.
;
; Output is paged like MORE: after a screenful, --More-- waits for a
; key. SPACE (or any key) shows the next page, ENTER or Down-arrow one
; more line, q quits.
;
; -c  continuous: no paging. Paging is also off whenever output is
;     redirected, so MDV README.MD > README.ANS gives a file for TYPE or
;     LESS. Every row starts from a reset and ends with ESC[0m, so rows
;     stand alone -- LESS can show them in any order.
; -p  plain: the same layout with no escape sequences at all.
;
; How it works: a paragraph (or list item, or quote) is gathered whole
; into a buffer in free RAM above the program (LOADER_ARGS mem_base..
; mem_top, up to 32000 bytes), then rendered in one pass, so emphasis
; can look ahead for its closing marker anywhere in the paragraph -- an
; unmatched * or _ stays literal. A paragraph bigger than the buffer is
; rendered in pieces (styling does not carry across a piece). Block
; structure is decided line by line; nested blocks inside quotes and
; setext/ATX headings inside lists are not recognised.
;
; tools/mdvref.py is a byte-exact Python model of this renderer, used
; to test it: MDV -c under Run/02 must print exactly its rows. Change
; the two together.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   term_size

; block kinds
K_NONE:     equ     0
K_PARA:     equ     1
K_LIST:     equ     2
K_QUOTE:    equ     3
K_HEAD:     equ     4
K_TABLE:    equ     5

; inline style bits (w_cur)
S_B:        equ     1               ; bold
S_I:        equ     2               ; italic
S_L:        equ     4               ; link text (underline)
S_C:        equ     8               ; code (yellow)
S_U:        equ     16              ; url (green)

RD_CHUNK:   equ     512             ; file read size
RB_LEN:     equ     1100            ; row buffer (bytes incl. escapes)
RB_SOFT:    equ     901             ; force a break at this many bytes
BLK_MAX:    equ     32000           ; most of the block buffer used
LINE_ROOM:  equ     1026            ; flush a block before a line if less
                                    ; room than this is left

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv, RC.0 = argc. The scan makes no calls: R9.0 =
            ; index, R8 = filename (0 until found), RB = current arg.
            ldi     0
            phi     r8
            plo     r8
            ldi     1
            plo     r9
arg_loop:
            glo     rc
            str     r2
            glo     r9
            sm                          ; index - argc
            lbdf    args_done
            glo     r9
            shl
            str     r2
            glo     ra
            add
            plo     rd
            ghi     ra
            adci    0
            phi     rd                  ; RD = &argv[index]
            lda     rd
            phi     rb
            ldn     rd
            plo     rb                  ; RB = argv[index]
            ldn     rb
            xri     '-'
            lbnz    arg_name
            inc     rb
            ldn     rb
            lbz     usage               ; a bare "-"
arg_flag:
            ldn     rb
            lbz     arg_next
            ani     $DF
            xri     'C'
            lbnz    af_notc
            mov     rf, opt_cont
            ldi     1
            str     rf
            inc     rb
            lbr     arg_flag
af_notc:
            ldn     rb
            ani     $DF
            xri     'P'
            lbnz    usage
            mov     rf, opt_plain
            ldi     1
            str     rf
            inc     rb
            lbr     arg_flag
arg_name:
            ghi     r8
            lbnz    usage               ; a second filename
            glo     r8
            lbnz    usage
            ghi     rb
            phi     r8
            glo     rb
            plo     r8
arg_next:
            glo     r9
            adi     1
            plo     r9
            lbr     arg_loop
args_done:
            ghi     r8
            lbnz    have_name
            glo     r8
            lbz     usage
have_name:
            mov     rf, fname
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            ; --- screen size: width W = columns-1 (20..250), page =
            ; rows-1 (at least 1) ---
            call    term_size           ; RC.1 = rows, RC.0 = columns
            glo     rc
            smi     1                   ; columns - 1
            plo     r9
            smi     20
            lbdf    w_notsmall
            ldi     20
            plo     r9
w_notsmall:
            glo     r9
            smi     251
            lbnf    w_notbig
            ldi     250
            plo     r9
w_notbig:
            mov     rf, wid
            glo     r9
            str     rf
            ghi     rc
            smi     1                   ; rows - 1
            lbnz    pg_ok
            ldi     1
pg_ok:
            plo     r9
            mov     rf, pg_rows
            glo     r9
            str     rf

            ; --- paging: off with -c, and off when output is redirected
            ; (K_TYPE's entry no longer names the console routine) ---
            mov     rf, opt_cont
            ldn     rf
            lbnz    no_paging
            mov     rf, K_TYPE+1
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = K_TYPE's target
            mov     rf, IO_TYPE_TARGET
            lda     rf
            str     r2
            ghi     r8
            xor
            lbnz    no_paging
            ldn     rf
            str     r2
            glo     r8
            xor
            lbnz    no_paging
            mov     rf, paging
            ldi     1
            str     rf
no_paging:

            ; --- block buffer: mem_base up to min(free-64, BLK_MAX) ---
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            lda     rf
            plo     rd                  ; RD = mem_base
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = mem_top
            glo     rd
            str     r2
            glo     r9
            sm
            plo     r9
            ghi     rd
            str     r2
            ghi     r9
            smb
            phi     r9                  ; R9 = mem_top - mem_base
            lbnf    no_memory
            sub16   r9, 64
            lbnf    no_memory
            mov     r8, r9
            sub16   r8, BLK_MAX
            lbnf    cap_ok
            mov     r9, BLK_MAX
cap_ok:
            mov     r8, r9
            sub16   r8, 2048
            lbnf    no_memory
            mov     rf, blk_cap
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, blk_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- open the file ---
            mov     rf, fname
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            mov     rd, in_fcb
            mov     ra, in_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    not_found

;------------------------------------------------------------------
; main loop: one source line per pass
;------------------------------------------------------------------
main_loop:
            mov     rf, quit
            ldn     rf
            lbnz    finish

            ; room left = cap - len; flush first if short
            mov     rf, blk_cap
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, blk_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     r7, r9
            sub16   r7, r8
            sub16   r7, LINE_ROOM
            lbdf    ml_room
            call    flush
ml_room:
            ; rl_dst = base + len + 1, rl_max = cap - len - 2
            mov     rf, blk_base
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, blk_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r9, r8
            inc     r9
            mov     rf, rl_dst
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, blk_cap
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            sub16   r9, r8
            sub16   r9, 2
            mov     rf, rl_max
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, rl_part
            ldn     rf
            plo     r9
            mov     rf, prev_part
            glo     r9
            str     rf

            call    read_line
            lbdf    finish
            call    do_line
            lbr     main_loop

finish:
            call    flush
            mov     rd, in_fcb
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success
            rtn

usage:
            call    K_INMSG
            db      "Usage: MDV [-c] [-p] <filename>",13,10,0
            ldi     1
            rtn
not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn
no_memory:
            call    K_INMSG
            db      "Not enough memory.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; read_line: read one line into rl_dst (at most rl_max bytes), dropping
; CR and NUL, stopping at LF. The line is NUL-terminated (ln_end points
; at the NUL). rl_part = 1 if it was cut at rl_max (the rest is left
; for the next call).
; Returns: DF = 1 if the file had nothing left at all.
;
; The scan works straight out of rd_buf in registers -- RF = next byte,
; RC = bytes left in the chunk, RD = destination, RB = room left, R8.1 =
; anything consumed -- and only saves them around K_FILE_READ.
;------------------------------------------------------------------
read_line:
            mov     rf, rl_part
            ldi     0
            str     rf
            mov     rf, rl_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = destination
            mov     rf, rl_max
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = room
            ldi     0
            phi     r8                  ; nothing consumed yet
            mov     rf, rd_pos
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = pos
            mov     rf, rd_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = len
            glo     r9
            str     r2
            glo     rc
            sm
            plo     rc
            ghi     r9
            str     r2
            ghi     rc
            smb
            phi     rc                  ; RC = len - pos
            mov     rf, rd_buf
            add16   rf, r9              ; RF = rd_buf + pos
rlf_loop:
            ghi     rb
            lbnz    rlf_room
            glo     rb
            lbz     rlf_full            ; no room: leave the rest
rlf_room:
            ghi     rc
            lbnz    rlf_byte
            glo     rc
            lbz     rlf_refill
rlf_byte:
            lda     rf
            dec     rc
            plo     r7
            ldi     1
            phi     r8                  ; consumed something
            glo     r7
            xri     10
            lbz     rlf_done
            glo     r7
            lbz     rlf_loop            ; NUL
            xri     13
            lbz     rlf_loop            ; CR
            glo     r7
            str     rd
            inc     rd
            dec     rb
            lbr     rlf_loop
rlf_refill:
            mov     r9, rl_sv
            ghi     rd
            str     r9
            inc     r9
            glo     rd
            str     r9
            inc     r9
            ghi     rb
            str     r9
            inc     r9
            glo     rb
            str     r9
            inc     r9
            ghi     r8
            str     r9
            mov     rf, rd_eof
            ldn     rf
            lbnz    rlf_eof
            mov     rd, in_fcb
            mov     rf, rd_buf
            mov     rc, RD_CHUNK
            call    K_FILE_READ
            lbdf    rlf_seteof
            ghi     rc
            lbnz    rlf_got
            glo     rc
            lbz     rlf_seteof
rlf_got:
            mov     rf, rd_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            call    rlf_restore
            mov     rf, rd_buf
            lbr     rlf_loop
rlf_seteof:
            mov     rf, rd_eof
            ldi     1
            str     rf
            mov     rf, rd_len
            ldi     0
            str     rf
            inc     rf
            str     rf
rlf_eof:
            call    rlf_restore
            mov     rf, rd_buf          ; pos 0 of an empty chunk
            ghi     r8
            lbz     rl_none             ; nothing at all
            lbr     rlf_done
rlf_full:
            mov     r9, rl_part
            ldi     1
            str     r9
rlf_done:
            ; rd_pos = RF - rd_buf
            mov     r9, rd_buf
            glo     r9
            str     r2
            glo     rf
            sm
            plo     r9
            ghi     r9
            str     r2
            ghi     rf
            smb
            phi     r9
            mov     rf, rd_pos
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            ldi     0
            str     rd                  ; NUL-terminate
            mov     rf, ln_end
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            clc
            rtn
rl_none:
            stc
            rtn

; rlf_restore: RD, RB, R8.1 back from rl_sv (RC untouched: after a
; refill it holds the new chunk's length)
rlf_restore:
            mov     r9, rl_sv
            lda     r9
            phi     rd
            lda     r9
            plo     rd
            lda     r9
            phi     rb
            lda     r9
            plo     rb
            ldn     r9
            phi     r8
            rtn

;------------------------------------------------------------------
; small helpers
;------------------------------------------------------------------
; get_s: RF = ln_s (the line after its indent), D = *RF
get_s:
            mov     r8, ln_s
            lda     r8
            phi     rf
            ldn     r8
            plo     rf
            ldn     rf
            rtn

; get_ind: D = ln_ind
get_ind:
            mov     rf, ln_ind
            ldn     rf
            rtn

; clr_list: in_list = 0
clr_list:
            mov     rf, in_list
            ldi     0
            str     rf
            rtn

; is_blank: D = 0 if RF points at nothing but spaces/tabs up to the NUL.
; Uses RF, R7.0.
is_blank:
            lda     rf
            lbz     ib_yes
            plo     r7
            xri     ' '
            lbz     is_blank
            glo     r7
            xri     9
            lbz     is_blank
            ldi     1
            rtn
ib_yes:
            ldi     0
            rtn

; is_ws: DF = 1 if D is NUL, space or tab. Uses D only.
is_ws:
            lbz     iw_y
            xri     32
            lbz     iw_y
            xri     41
            lbz     iw_y
            clc
            rtn
iw_y:
            stc
            rtn

; is_punct: DF = 1 if D is ASCII punctuation. Uses R7.1.
is_punct:
            phi     r7
            smi     33
            lbnf    ip_no
            ghi     r7
            smi     48
            lbnf    ip_yes
            ghi     r7
            smi     58
            lbnf    ip_no
            ghi     r7
            smi     65
            lbnf    ip_yes
            ghi     r7
            smi     91
            lbnf    ip_no
            ghi     r7
            smi     97
            lbnf    ip_yes
            ghi     r7
            smi     123
            lbnf    ip_no
            ghi     r7
            smi     127
            lbnf    ip_yes
ip_no:
            clc
            rtn
ip_yes:
            stc
            rtn

; run_len: RF = pointer, D = character (not NUL). Returns D = how many
; of it in a row (at most 255), RF just past them. Uses R8.0, R9.0.
run_len:
            plo     r8
            ldi     0
            plo     r9
rln_l:
            glo     r8
            str     r2
            ldn     rf
            xor
            lbnz    rln_d
            glo     r9
            xri     255
            lbz     rln_d
            inc     rf
            glo     r9
            adi     1
            plo     r9
            lbr     rln_l
rln_d:
            glo     r9
            rtn

; trim_ws: RF = start, RD = end (exclusive). Moves RD back over
; trailing spaces/tabs, not past RF.
trim_ws:
            glo     rd
            str     r2
            glo     rf
            xor
            lbnz    tw_c
            ghi     rd
            str     r2
            ghi     rf
            xor
            lbz     tw_done
tw_c:
            dec     rd
            ldn     rd
            xri     ' '
            lbz     trim_ws
            ldn     rd
            xri     9
            lbz     trim_ws
            inc     rd
tw_done:
            rtn

;------------------------------------------------------------------
; do_line: classify the line just read (at rl_dst, ending at ln_end) and
; act on it.
;------------------------------------------------------------------
do_line:
            mov     rf, rl_dst
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ln_p
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            ; indentation: a tab goes to the next multiple of 4
            ldi     0
            plo     r9
dl_ind:
            ldn     r8
            xri     ' '
            lbz     dl_sp
            ldn     r8
            xri     9
            lbnz    dl_ind_done
            glo     r9
            adi     4
            ani     $FC
            lbr     dl_indset
dl_sp:
            glo     r9
            adi     1
dl_indset:
            plo     r9
            smi     200
            lbnf    dl_nocap
            ldi     200
            plo     r9
dl_nocap:
            inc     r8
            lbr     dl_ind
dl_ind_done:
            mov     rf, ln_s
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, ln_ind
            glo     r9
            str     rf

            ; ---- inside a fenced code block ----
            mov     rf, in_fence
            ldn     rf
            lbz     dl_nofence
            call    get_ind
            smi     4
            lbdf    dl_codeline
            call    get_s
            plo     r9
            mov     rf, fch
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    dl_codeline
            call    get_s               ; D = the fence char
            call    run_len             ; D = k, RF past the run
            plo     rb
            mov     rd, flen
            ldn     rd
            str     r2
            glo     rb
            sm                          ; k - flen
            lbnf    dl_codeline
            call    is_blank
            lbnz    dl_codeline
            mov     rf, in_fence
            ldi     0
            str     rf
            rtn
dl_codeline:
            mov     rf, ln_p
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, find
            ldn     rf
            plo     r9
dcl_l:
            glo     r9
            lbz     dcl_go
            ldn     r8
            xri     ' '
            lbnz    dcl_go
            inc     r8
            glo     r9
            smi     1
            plo     r9
            lbr     dcl_l
dcl_go:
            mov     rf, r8
            lbr     code_row

dl_nofence:
            ; ---- the rest of a line cut short last time ----
            mov     rf, prev_part
            ldn     rf
            lbz     dl_notpart
            mov     rf, ln_p
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ln_s
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            lbr     dl_text

dl_notpart:
            ; ---- blank line ----
            call    get_s
            lbnz    dl_notblank
            call    flush
            mov     rf, any_out
            ldn     rf
            lbz     dl_ret
            mov     rf, need_blank
            ldi     1
            str     rf
dl_ret:
            rtn

dl_notblank:
            call    get_ind
            smi     4
            lbdf    dl_indented         ; only lists and code from here

            ; ---- fence open: ``` or ~~~ ----
            call    get_s
            xri     '`'
            lbz     dfo_c
            ldn     rf
            xri     '~'
            lbnz    dl_nofopen
dfo_c:
            call    get_s
            plo     r9
            inc     rf
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    dl_nofopen
            inc     rf
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    dl_nofopen
            call    get_s
            call    run_len             ; D = k, RF past the run
            plo     rb
            mov     rd, rf              ; RD = the rest of the line
            call    get_s
            xri     '`'
            lbnz    dfo_ok
dfo_scan:
            lda     rd
            lbz     dfo_ok
            xri     '`'
            lbz     dl_nofopen          ; ``` with a ` after: not a fence
            lbr     dfo_scan
dfo_ok:
            mov     rf, flen
            glo     rb
            str     rf
            call    get_s
            plo     r9
            mov     rf, fch
            glo     r9
            str     rf
            call    get_ind
            plo     r9
            mov     rf, find
            glo     r9
            str     rf
            call    flush
            mov     rf, in_fence
            ldi     1
            str     rf
            lbr     clr_list

dl_nofopen:
            ; ---- setext underline (=== or ---) under a paragraph ----
            mov     rf, kind
            ldn     rf
            xri     K_PARA
            lbnz    dl_nosetext
            call    get_s
            plo     r9
            xri     '='
            lbz     dse_l
            glo     r9
            xri     '-'
            lbnz    dl_nosetext
dse_l:
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    dse_rest
            inc     rf
            lbr     dse_l
dse_rest:
            call    is_blank
            lbnz    dl_nosetext
            call    get_s
            xri     '='
            lbz     dse_1
            ldi     2
            lbr     dse_set
dse_1:
            ldi     1
dse_set:
            plo     r9
            mov     rf, level
            glo     r9
            str     rf
            mov     rf, kind
            ldi     K_HEAD
            str     rf
            call    flush
            lbr     clr_list

dl_nosetext:
            ; ---- thematic break: 3+ of - * _ (spaces allowed) ----
            call    get_s
            plo     r9
            xri     '-'
            lbz     dhr_c
            glo     r9
            xri     '*'
            lbz     dhr_c
            glo     r9
            xri     '_'
            lbnz    dl_nohr
dhr_c:
            ldi     0
            plo     rb
dhr_l:
            lda     rf
            lbz     dhr_end
            plo     r7
            glo     r9
            str     r2
            glo     r7
            xor
            lbz     dhr_cnt
            glo     r7
            xri     ' '
            lbz     dhr_l
            glo     r7
            xri     9
            lbz     dhr_l
            lbr     dl_nohr
dhr_cnt:
            glo     rb
            xri     255
            lbz     dhr_l
            glo     rb
            adi     1
            plo     rb
            lbr     dhr_l
dhr_end:
            glo     rb
            smi     3
            lbnf    dl_nohr
            call    flush
            call    do_hr
            lbr     clr_list

dl_nohr:
            ; ---- ATX heading: 1-6 #, then space or end ----
            call    get_s
            xri     '#'
            lbnz    dl_noatx
            call    get_s
            call    run_len             ; D = k, RF past the #s
            plo     rb
            smi     7
            lbdf    dl_noatx
            ldn     rf
            lbz     datx_ok
            xri     ' '
            lbz     datx_ok
            ldn     rf
            xri     9
            lbnz    dl_noatx
datx_ok:
            mov     rd, hd_level
            glo     rb
            str     rd
datx_sk:
            ldn     rf
            xri     ' '
            lbz     datx_sk1
            ldn     rf
            xri     9
            lbnz    datx_c
datx_sk1:
            inc     rf
            lbr     datx_sk
datx_c:
            ; RF = content start; RD = end, less trailing blanks
            mov     r8, ln_end
            lda     r8
            phi     rd
            ldn     r8
            plo     rd
            call    trim_ws
            mov     r9, rd
dt_h:
            glo     r9
            str     r2
            glo     rf
            xor
            lbnz    dt_h1
            ghi     r9
            str     r2
            ghi     rf
            xor
            lbz     dt_take             ; all #s
dt_h1:
            dec     r9
            ldn     r9
            xri     '#'
            lbz     dt_h
            inc     r9
            ; keep the #s unless a blank precedes them
            dec     r9
            ldn     r9
            plo     r7
            inc     r9
            glo     r7
            xri     ' '
            lbz     dt_take
            glo     r7
            xri     9
            lbz     dt_take
            lbr     dt_keep
dt_take:
            mov     rd, r9
            call    trim_ws
dt_keep:
            ldi     0
            str     rd
            mov     r8, hd_c
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            call    flush
            mov     rf, hd_level
            ldn     rf
            plo     r9
            mov     rf, level
            glo     r9
            str     rf
            mov     rf, hd_c
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            ldi     K_HEAD
            call    render_text
            lbr     clr_list

dl_noatx:
            ; ---- block quote ----
            call    get_s
            xri     '>'
            lbnz    dl_noquote
            call    get_s
dq_l:
            ldn     rf
            xri     '>'
            lbnz    dq_e
            inc     rf
            ldn     rf
            xri     ' '
            lbnz    dq_l
            inc     rf
            lbr     dq_l
dq_e:
            ldn     rf
            xri     ' '
            lbz     dq_e1
            ldn     rf
            xri     9
            lbnz    dq_e2
dq_e1:
            inc     rf
            lbr     dq_e
dq_e2:
            ldn     rf
            lbnz    dq_content
            call    flush
            lbr     quote_blank
dq_content:
            mov     r8, nl_c
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            call    clr_list
            mov     rf, kind
            ldn     rf
            xri     K_QUOTE
            lbz     dq_join
            ldi     K_QUOTE
            lbr     start_blk
dq_join:
            lbr     join_blk

dl_noquote:
            ; ---- table row ----
            call    get_s
            xri     '|'
            lbnz    dl_indented
            mov     r8, hd_c
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            call    flush
            call    clr_list
            mov     rf, hd_c
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            ldi     K_TABLE
            lbr     render_text

dl_indented:
            ; ---- list item (any indent while in a list, else < 4) ----
            mov     rf, in_list
            ldn     rf
            lbnz    dli_try
            call    get_ind
            smi     4
            lbdf    dl_nolist
dli_try:
            call    get_ind
            smi     64
            lbdf    dl_nolist
            call    get_s
            plo     r9
            xri     '-'
            lbz     dli_b
            glo     r9
            xri     '*'
            lbz     dli_b
            glo     r9
            xri     '+'
            lbnz    dli_num
dli_b:
            inc     rf
            ldn     rf
            lbz     dli_bok
            xri     ' '
            lbz     dli_bok
            ldn     rf
            xri     9
            lbnz    dl_nolist
dli_bok:
            ldi     0                   ; bullet: marker length 0 = bullet
            plo     rb
            lbr     dli_have
dli_num:
            glo     r9
            smi     '0'
            lbnf    dl_nolist
            glo     r9
            smi     '9'+1
            lbdf    dl_nolist
            ldi     0
            plo     rb
dln_l:
            ldn     rf
            smi     '0'
            lbnf    dln_e
            ldn     rf
            smi     '9'+1
            lbdf    dln_e
            glo     rb
            smi     9
            lbdf    dln_e
            inc     rf
            glo     rb
            adi     1
            plo     rb
            lbr     dln_l
dln_e:
            ldn     rf
            xri     '.'
            lbz     dln_d
            ldn     rf
            xri     ')'
            lbnz    dl_nolist
dln_d:
            inc     rf
            glo     rb
            adi     1
            plo     rb
            ldn     rf
            lbz     dli_have
            xri     ' '
            lbz     dli_have
            ldn     rf
            xri     9
            lbnz    dl_nolist
dli_have:
            ; RF = just past the marker, RB.0 = marker length (0 for a
            ; bullet). Keep both: flush clobbers every register.
            mov     r8, nl_c
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     r8, nl_q
            glo     rb
            str     r8
            call    flush
            ; margin = min(indent, 8)
            call    get_ind
            plo     r9
            smi     9
            lbnf    dli_m
            ldi     8
            plo     r9
dli_m:
            mov     rf, margin
            glo     r9
            str     rf
            ; the marker
            mov     rf, nl_q
            ldn     rf
            lbnz    dli_numbered
            call    get_ind
            lbnz    dli_nested
            ldi     '*'
            lbr     dli_bset
dli_nested:
            ldi     '-'
dli_bset:
            plo     r9
            mov     rf, mk_buf
            glo     r9
            str     rf
            mov     rf, mk_len
            ldi     1
            str     rf
            lbr     dli_mk_done
dli_numbered:
            plo     rc                  ; count
            mov     rf, mk_len
            glo     rc
            str     rf
            call    get_s               ; RF = the digits
            mov     rd, mk_buf
dli_cp:
            lda     rf
            str     rd
            inc     rd
            glo     rc
            smi     1
            plo     rc
            lbnz    dli_cp
dli_mk_done:
            ; cont = margin + marker length + 1
            mov     rf, margin
            ldn     rf
            str     r2
            mov     rf, mk_len
            ldn     rf
            add
            adi     1
            plo     r9
            mov     rf, cont
            glo     r9
            str     rf
            mov     rf, list_cont
            glo     r9
            str     rf
            mov     rf, in_list
            ldi     1
            str     rf
            ; content: skip the blanks after the marker
            mov     rf, nl_c
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
dli_sk:
            ldn     r8
            xri     ' '
            lbz     dli_sk1
            ldn     r8
            xri     9
            lbnz    dli_sk2
dli_sk1:
            inc     r8
            lbr     dli_sk
dli_sk2:
            mov     rf, r8
            call    copy_blk            ; into the (now empty) block
            mov     rf, kind
            ldi     K_LIST
            str     rf
            rtn

dl_nolist:
            ; ---- indented code (not in a list, not after a paragraph) ----
            call    get_ind
            smi     4
            lbnf    dl_text
            mov     rf, in_list
            ldn     rf
            lbnz    dl_text
            mov     rf, kind
            ldn     rf
            lbnz    dl_text
            mov     rf, ln_p
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            ldi     0
            plo     r9                  ; column
dic_l:
            glo     r9
            smi     4
            lbdf    dic_go
            ldn     rf
            xri     ' '
            lbz     dic_sp
            ldn     rf
            xri     9
            lbnz    dic_go
            glo     r9
            adi     4
            ani     $FC
            plo     r9
            inc     rf
            lbr     dic_l
dic_sp:
            glo     r9
            adi     1
            plo     r9
            inc     rf
            lbr     dic_l
dic_go:
            lbr     code_row

dl_text:
            ; ---- ordinary text ----
            call    get_s
            mov     r8, nl_c
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     rf, kind
            ldn     rf
            xri     K_PARA
            lbz     join_blk
            ldn     rf
            xri     K_LIST
            lbz     join_blk
            ldn     rf
            xri     K_QUOTE
            lbz     join_blk
            call    get_ind
            lbnz    dt_keeplist
            call    clr_list
dt_keeplist:
            ldi     K_PARA
            call    start_blk
            ; margin = in_list ? list_cont : 0
            mov     rf, in_list
            ldn     rf
            lbz     dt_m0
            mov     rf, list_cont
            ldn     rf
dt_m0:
            plo     r9
            mov     rf, margin
            glo     r9
            str     rf
            rtn

;------------------------------------------------------------------
; start_blk: flush the current block, then begin a new one of kind D
; holding the text at nl_c.
; join_blk: add the text at nl_c to the current block, after a space.
;------------------------------------------------------------------
start_blk:
            plo     r9
            mov     rf, sb_kind
            glo     r9
            str     rf
            call    flush
            mov     rf, nl_c
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            call    copy_blk
            mov     rf, sb_kind
            ldn     rf
            plo     r9
            mov     rf, kind
            glo     r9
            str     rf
            rtn

join_blk:
            mov     rf, blk_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            ghi     r8
            lbnz    jb_space
            glo     r8
            lbz     jb_copy
jb_space:
            mov     rf, blk_base
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, r8
            ldi     ' '
            str     rd
            inc     r8
            mov     rf, blk_len
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
jb_copy:
            mov     rf, nl_c
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            lbr     copy_blk

;------------------------------------------------------------------
; copy_blk: append the NUL-terminated string at RF to the block at
; blk_base+blk_len (the string always lies at or after that point, so
; a forward copy is safe), and update blk_len.
;------------------------------------------------------------------
copy_blk:
            mov     r8, blk_base
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = base
            mov     r8, blk_len
            lda     r8
            phi     r9
            ldn     r8
            plo     r9
            add16   rd, r9              ; RD = base + len
cb_l:
            lda     rf
            str     rd
            lbz     cb_d
            inc     rd
            lbr     cb_l
cb_d:
            ; len = RD - base
            mov     r8, blk_base
            lda     r8
            str     r2
            ldn     r8
            plo     r9                  ; R9.0 = base.lo, M(R2) = base.hi
            ghi     rd
            sm
            phi     rc                  ; provisional high byte
            glo     r9
            str     r2
            glo     rd
            sm
            plo     rc
            lbdf    cb_nb
            ghi     rc
            smi     1
            phi     rc
cb_nb:
            mov     r8, blk_len
            ghi     rc
            str     r8
            inc     r8
            glo     rc
            str     r8
            rtn

;------------------------------------------------------------------
; flush: render the current block (if any) and empty it.
;------------------------------------------------------------------
flush:
            mov     rf, kind
            ldn     rf
            lbz     fl_ret
            mov     rf, blk_base
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, blk_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   rd, r8
            ldi     0
            str     rd                  ; NUL-terminate
            mov     rf, blk_base
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, kind
            ldn     rf
            plo     r9
            mov     rf, r8
            glo     r9
            call    render_text
            mov     rf, kind
            ldi     K_NONE
            str     rf
            mov     rf, blk_len
            ldi     0
            str     rf
            inc     rf
            str     rf
fl_ret:
            rtn

;------------------------------------------------------------------
; render_text: render the NUL-terminated text at RF as one block of
; kind D, word-wrapped.
;------------------------------------------------------------------
render_text:
            plo     r9
            mov     r8, ri_start
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     rf, rt_kind
            glo     r9
            str     rf
            mov     rf, w_words
            ldi     1
            str     rf
            mov     rf, w_base
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, w_basef
            ldi     0
            str     rf
            mov     rf, w_cur
            ldi     0
            str     rf
            mov     rf, w_started
            ldi     0
            str     rf
            mov     rf, w_ptype
            ldi     0
            str     rf
            mov     rf, w_fsp
            ldi     0
            str     rf
            mov     rf, w_csp
            ldi     0
            str     rf

            mov     rf, rt_kind
            ldn     rf
            xri     K_PARA
            lbnz    rt_np
            mov     rf, margin
            ldn     rf
            plo     r9
            mov     rf, w_fsp
            glo     r9
            str     rf
            mov     rf, w_csp
            glo     r9
            str     rf
            lbr     rt_go
rt_np:
            ldn     rf
            xri     K_LIST
            lbnz    rt_nl
            mov     rf, w_ptype
            ldi     1
            str     rf
            mov     rf, cont
            ldn     rf
            plo     r9
            mov     rf, w_csp
            glo     r9
            str     rf
            lbr     rt_go
rt_nl:
            ldn     rf
            xri     K_QUOTE
            lbnz    rt_nq
            mov     rf, w_ptype
            ldi     2
            str     rf
            lbr     rt_go
rt_nq:
            ldn     rf
            xri     K_HEAD
            lbnz    rt_go               ; K_TABLE: nothing to set
            mov     rf, level
            ldn     rf
            xri     1
            lbnz    rt_h2
            mov     r8, s_h1
            lbr     rt_hset
rt_h2:
            ldn     rf
            xri     2
            lbnz    rt_h3
            mov     r8, s_h2
            lbr     rt_hset
rt_h3:
            ldn     rf
            xri     3
            lbnz    rt_h4
            mov     r8, s_h3
            lbr     rt_hset
rt_h4:
            mov     r8, s_h4
rt_hset:
            mov     rf, w_base
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, w_basef
            ldi     1
            str     rf
rt_go:
            call    render_inline
            lbr     w_finish

;------------------------------------------------------------------
; code_row: one line of code at RF: yellow, 2-column margin, tabs to
; multiples of 8, broken at the screen width.
;------------------------------------------------------------------
code_row:
            mov     r8, cr_p
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     rf, cr_col
            ldi     0
            str     rf
            mov     rf, w_words
            ldi     0
            str     rf
            mov     rf, w_ptype
            ldi     0
            str     rf
            mov     rf, w_fsp
            ldi     2
            str     rf
            mov     rf, w_csp
            ldi     2
            str     rf
            mov     rf, w_base
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, w_basef
            ldi     0
            str     rf
            mov     rf, w_cur
            ldi     S_C
            str     rf
            mov     rf, w_started
            ldi     0
            str     rf
cr_l:
            mov     rf, cr_p
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            ldn     r8
            lbz     cr_done
            plo     r7
            inc     r8
            mov     rf, cr_p
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            glo     r7
            xri     9
            lbz     cr_tab
            glo     r7
            smi     32
            lbnf    cr_l
            glo     r7
            xri     127
            lbz     cr_l
            glo     r7
            ani     $C0
            xri     $80
            lbz     cr_put
            mov     rf, cr_col
            ldn     rf
            adi     1
            str     rf
cr_put:
            glo     r7
            call    w_put
            lbr     cr_l
cr_tab:
            mov     rf, cr_col
            ldn     rf
            ani     7
            sdi     8                   ; 8 - (col & 7)
            plo     r9
            mov     rf, cr_n
            glo     r9
            str     rf
            mov     rf, cr_col
            ldn     rf
            str     r2
            glo     r9
            add
            str     rf
cr_tl:
            mov     rf, cr_n
            ldn     rf
            lbz     cr_l
            smi     1
            str     rf
            ldi     32
            call    w_put
            lbr     cr_tl
cr_done:
            lbr     w_finish

;------------------------------------------------------------------
; do_hr / quote_blank: rows that stand on their own
;------------------------------------------------------------------
do_hr:
            call    blank_check
            call    rb_clear
            mov     rf, s_hr_sgr
            call    rb_esc
            mov     rf, wid
            ldn     rf
            plo     rc
dhr_d:
            ldi     '-'
            call    rb_append
            glo     rc
            smi     1
            plo     rc
            lbnz    dhr_d
            mov     rf, s_reset
            call    rb_esc
            lbr     out_row

quote_blank:
            call    blank_check
            call    rb_clear
            call    quote_bar
            lbr     out_row

; quote_bar: append the green "|" (no trailing space)
quote_bar:
            mov     rf, s_bar_sgr
            call    rb_esc
            ldi     '|'
            call    rb_append
            mov     rf, s_reset
            lbr     rb_esc

; blank_check: print the pending blank line, if any
blank_check:
            mov     rf, need_blank
            ldn     rf
            lbz     bc_ret
            ldi     0
            str     rf
            mov     rf, any_out
            ldn     rf
            lbz     bc_ret
            call    rb_clear
            lbr     out_row
bc_ret:
            rtn

;------------------------------------------------------------------
; render_inline: walk the text at ri_start, applying inline markup,
; feeding w_put. All state is in memory: w_put clobbers everything.
;------------------------------------------------------------------
render_inline:
            mov     rf, ri_start
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ri_i
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, it_ch
            ldi     0
            str     rf
            mov     rf, bo_ch
            ldi     0
            str     rf
            mov     rf, lk_end
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, url_s
            ldi     0
            str     rf
            inc     rf
            str     rf
ri_loop:
            call    ri_ld
            lbz     ri_done
            plo     r7
            ; nothing at or above 'a', and no capital letter, is special
            smi     'a'
            lbdf    ri_plain
            glo     r7
            smi     'A'
            lbnf    ri_chk
            glo     r7
            smi     'Z'+1
            lbnf    ri_plain
ri_chk:
            glo     r7
            xri     ']'
            lbnz    ri_nle
            ; a ] may end a link's text (lk_end always points at one)
            mov     r8, lk_end
            lda     r8
            phi     r9
            ldn     r8
            plo     r9
            glo     r9
            str     r2
            glo     rf
            xor
            lbnz    ri_plain
            ghi     r9
            str     r2
            ghi     rf
            xor
            lbz     ri_linkend
            lbr     ri_plain
ri_nle:
            glo     r7
            xri     92
            lbz     ri_bs
            glo     r7
            xri     '`'
            lbz     ri_tick
            glo     r7
            xri     '*'
            lbz     ri_emph
            glo     r7
            xri     '_'
            lbz     ri_emph
            glo     r7
            xri     '!'
            lbz     ri_bang
            glo     r7
            xri     '['
            lbz     ri_brack
            glo     r7
            xri     '<'
            lbz     ri_lt
ri_plain:
            ; an ordinary character (RF = i, R7.0 = it)
            inc     rf
            mov     r8, ri_i
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            glo     r7
            call    w_put
            lbr     ri_loop
ri_done:
            mov     rf, w_cur
            ldi     0
            str     rf
            rtn

; ri_ld: RF = i, D = *i
ri_ld:
            mov     r8, ri_i
            lda     r8
            phi     rf
            ldn     r8
            plo     rf
            ldn     rf
            rtn

; ri_adv: i += D
ri_adv:
            plo     r7
            mov     r8, ri_i
            lda     r8
            phi     r9
            ldn     r8
            plo     r9
            glo     r7
            str     r2
            glo     r9
            add
            plo     r9
            ghi     r9
            adci    0
            phi     r9
            glo     r9
            str     r8
            dec     r8
            ghi     r9
            str     r8
            rtn

; ri_put1: output D, i += 1, next
ri_put1:
            plo     r7
            mov     r8, ri_c
            glo     r7
            str     r8
            ldi     1
            call    ri_adv
            mov     r8, ri_c
            ldn     r8
            call    w_put
            lbr     ri_loop

; ri_lit_l: output ri_c ri_n times (i already advanced), then next
ri_lit_l:
            mov     rf, ri_n
            ldn     rf
            lbz     ri_loop
            smi     1
            str     rf
            mov     rf, ri_c
            ldn     rf
            call    w_put
            lbr     ri_lit_l

; put_range: output the bytes from ri_p up to (not including) ri_f
put_range:
            mov     rf, ri_p
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ri_f
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            glo     r8
            str     r2
            glo     r9
            xor
            lbnz    pr_go
            ghi     r8
            str     r2
            ghi     r9
            xor
            lbz     pr_ret
pr_go:
            ldn     r8
            plo     r7
            inc     r8
            mov     rf, ri_p
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            glo     r7
            call    w_put
            lbr     put_range
pr_ret:
            rtn

; ---- end of a link's text: close it, show the url ----
ri_linkend:
            mov     rf, w_cur
            ldn     rf
            ani     $FF-S_L
            str     rf
            mov     rf, url_s
            ldn     rf
            lbnz    rle_url
            inc     rf
            ldn     rf
            lbz     rle_done
rle_url:
            mov     rf, w_cur
            ldn     rf
            ori     S_U
            str     rf
            ldi     ' '
            call    w_put
            ldi     '('
            call    w_put
            mov     rf, url_s
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ri_p
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, url_e
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ri_f
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            call    put_range
            ldi     ')'
            call    w_put
            mov     rf, w_cur
            ldn     rf
            ani     $FF-S_U
            str     rf
rle_done:
            mov     rf, lk_after
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ri_i
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, lk_end
            ldi     0
            str     rf
            inc     rf
            str     rf
            lbr     ri_loop

; ---- backslash: escapes ASCII punctuation ----
ri_bs:
            inc     rf
            ldn     rf
            call    is_punct
            lbnf    ri_bs_lit
            ldi     1
            call    ri_adv
            call    ri_ld
            lbr     ri_put1
ri_bs_lit:
            ldi     92
            lbr     ri_put1

; ---- code span ----
ri_tick:
            ldi     '`'
            call    run_len             ; RF = i still (ri_ld)
            plo     r7
            mov     rf, ri_k
            glo     r7
            str     rf
            call    ri_ld
            mov     r8, ri_k
            ldn     r8
            call    fcc
            lbdf    ri_tick_lit
            mov     r8, ri_e            ; e: start of the closing run
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     rd, rf              ; RD = f
            call    ri_ld
            mov     r8, ri_k
            ldn     r8
            str     r2
            glo     rf
            add
            plo     rf
            ghi     rf
            adci    0
            phi     rf                  ; RF = s = i + k
            ; strip one space each side if both are there and the
            ; content is not all spaces
            glo     rf
            str     r2
            glo     rd
            sm
            plo     r9
            ghi     rf
            str     r2
            ghi     rd
            smb
            phi     r9                  ; R9 = f - s
            lbnz    rt_chk
            glo     r9
            smi     2
            lbnf    rt_nostrip
rt_chk:
            ldn     rf
            xri     ' '
            lbnz    rt_nostrip
            dec     rd
            ldn     rd
            inc     rd
            xri     ' '
            lbnz    rt_nostrip
            mov     r8, rf
rt_scan:
            glo     r8
            str     r2
            glo     rd
            xor
            lbnz    rt_sc1
            ghi     r8
            str     r2
            ghi     rd
            xor
            lbz     rt_nostrip          ; all spaces
rt_sc1:
            lda     r8
            xri     ' '
            lbz     rt_scan
            inc     rf
            dec     rd
rt_nostrip:
            mov     r8, ri_p
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     r8, ri_f
            ghi     rd
            str     r8
            inc     r8
            glo     rd
            str     r8
            ; i = e + k
            mov     rf, ri_e
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, ri_k
            ldn     rf
            str     r2
            glo     r9
            add
            plo     r9
            ghi     r9
            adci    0
            phi     r9
            mov     rf, ri_i
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, w_cur
            ldn     rf
            ori     S_C
            str     rf
            call    put_range
            mov     rf, w_cur
            ldn     rf
            ani     $FF-S_C
            str     rf
            lbr     ri_loop
ri_tick_lit:
            mov     rf, ri_c
            ldi     '`'
            str     rf
            mov     rf, ri_k
            ldn     rf
            plo     r9
            mov     rf, ri_n
            glo     r9
            str     rf
            glo     r9
            call    ri_adv
            lbr     ri_lit_l

; ---- * and _ ----
ri_emph:
            mov     rf, ri_c
            glo     r7
            str     rf
            call    ri_ld
            call    run_len             ; D = k
            plo     r9
            mov     rf, ri_k
            glo     r9
            str     rf
            glo     r9
            smi     4
            lbdf    ri_emph_lit
            ; need = (k&1 ? I) | (k&2 ? B)
            ldi     0
            plo     r9
            mov     rf, ri_k
            ldn     rf
            ani     1
            lbz     re_1
            ldi     S_I
            plo     r9
re_1:
            ldn     rf
            ani     2
            lbz     re_2
            glo     r9
            ori     S_B
            plo     r9
re_2:
            mov     rf, ri_need
            glo     r9
            str     rf
            ; on = cur & need
            str     r2
            mov     rf, w_cur
            ldn     rf
            and
            plo     r9
            lbz     ri_try_open
            mov     rf, ri_need
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    ri_emph_lit         ; partly on
            ; the open marker(s) must be the same character
            mov     rf, ri_need
            ldn     rf
            ani     S_I
            lbz     rc_1
            mov     rf, it_ch
            ldn     rf
            str     r2
            mov     rf, ri_c
            ldn     rf
            xor
            lbnz    ri_emph_lit
rc_1:
            mov     rf, ri_need
            ldn     rf
            ani     S_B
            lbz     rc_2
            mov     rf, bo_ch
            ldn     rf
            str     r2
            mov     rf, ri_c
            ldn     rf
            xor
            lbnz    ri_emph_lit
rc_2:
            call    ri_ld
            mov     r8, ri_k
            ldn     r8
            call    emph_class
            ani     2
            lbz     ri_emph_lit
            mov     rf, ri_need
            ldn     rf
            xri     $FF
            str     r2
            mov     rf, w_cur
            ldn     rf
            and
            str     rf
            lbr     ri_emph_adv
ri_try_open:
            call    ri_ld
            mov     r8, ri_k
            ldn     r8
            call    emph_class
            ani     1
            lbz     ri_emph_lit
            call    ri_ld
            mov     r8, ri_k
            ldn     r8
            call    fec
            lbdf    ri_emph_lit
            mov     rf, ri_need
            ldn     rf
            str     r2
            mov     rf, w_cur
            ldn     rf
            or
            str     rf
            mov     rf, ri_need
            ldn     rf
            ani     S_I
            lbz     ro_1
            mov     rf, ri_c
            ldn     rf
            plo     r9
            mov     rf, it_ch
            glo     r9
            str     rf
ro_1:
            mov     rf, ri_need
            ldn     rf
            ani     S_B
            lbz     ri_emph_adv
            mov     rf, ri_c
            ldn     rf
            plo     r9
            mov     rf, bo_ch
            glo     r9
            str     rf
ri_emph_adv:
            mov     rf, ri_k
            ldn     rf
            call    ri_adv
            lbr     ri_loop
ri_emph_lit:
            mov     rf, ri_k
            ldn     rf
            plo     r9
            mov     rf, ri_n
            glo     r9
            str     rf
            glo     r9
            call    ri_adv
            lbr     ri_lit_l

; ---- ! before [ : an image, shown like a link ----
ri_bang:
            mov     rf, w_cur
            ldn     rf
            ani     S_L
            lbnz    ri_bang_lit
            call    ri_ld
            inc     rf
            ldn     rf
            xri     '['
            lbnz    ri_bang_lit
            call    fbr
            lbdf    ri_bang_lit
            inc     rf
            ldn     rf
            xri     '('
            lbz     ri_bang_skip
            ldn     rf
            xri     '['
            lbnz    ri_bang_lit
ri_bang_skip:
            ldi     1
            call    ri_adv
            lbr     ri_loop
ri_bang_lit:
            ldi     '!'
            lbr     ri_put1

; ---- [text](url) and [text][ref] ----
ri_brack:
            mov     rf, w_cur
            ldn     rf
            ani     S_L
            lbnz    ri_brack_lit
            call    ri_ld
            call    fbr                 ; RF = the matching ]
            lbdf    ri_brack_lit
            mov     r8, ri_j
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            inc     rf
            ldn     rf
            xri     '('
            lbz     rbk_paren
            ldn     rf
            xri     '['
            lbz     rbk_ref
            lbr     ri_brack_lit
rbk_paren:
            call    fpr                 ; RF = the matching )
            lbdf    ri_brack_lit
            mov     r8, ri_e
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            ; url = j+2 up to the first blank or )
            mov     r8, ri_j
            lda     r8
            phi     rd
            ldn     r8
            plo     rd
            inc     rd
            inc     rd                  ; RD = us
            mov     rb, rd              ; RB = ue
ru_l:
            glo     rb
            str     r2
            glo     rf
            xor
            lbnz    ru_c
            ghi     rb
            str     r2
            ghi     rf
            xor
            lbz     ru_d
ru_c:
            ldn     rb
            xri     ' '
            lbz     ru_d
            ldn     rb
            xri     9
            lbz     ru_d
            inc     rb
            lbr     ru_l
ru_d:
            mov     r8, url_s
            ghi     rd
            str     r8
            inc     r8
            glo     rd
            str     r8
            mov     r8, url_e
            ghi     rb
            str     r8
            inc     r8
            glo     rb
            str     r8
            ; no url if it is empty or the same as the text
            glo     rd
            str     r2
            glo     rb
            sm
            plo     r9
            ghi     rd
            str     r2
            ghi     rb
            smb
            phi     r9                  ; R9 = url length
            lbnz    ru_nonempty
            glo     r9
            lbz     rbk_nourl
ru_nonempty:
            call    ri_ld               ; RF = i
            inc     rf                  ; text start
            mov     r8, ri_j
            lda     r8
            phi     rc
            ldn     r8
            plo     rc                  ; RC = j
            glo     rf
            str     r2
            glo     rc
            sm
            plo     r8
            ghi     rf
            str     r2
            ghi     rc
            smb
            phi     r8                  ; R8 = text length
            glo     r8
            str     r2
            glo     r9
            xor
            lbnz    rbk_set
            ghi     r8
            str     r2
            ghi     r9
            xor
            lbnz    rbk_set
            ; same length: compare R9 bytes of RF (text) and RD (url)
ru_cmp:
            glo     r9
            lbnz    ru_cmp1
            ghi     r9
            lbz     rbk_nourl           ; identical
ru_cmp1:
            lda     rd
            str     r2
            lda     rf
            xor
            lbnz    rbk_set
            dec     r9
            lbr     ru_cmp
rbk_nourl:
            mov     rf, url_s
            ldi     0
            str     rf
            inc     rf
            str     rf
rbk_set:
            ; lk_end = j, lk_after = e + 1, link style on, i += 1
            mov     rf, ri_j
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, lk_end
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, ri_e
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            inc     r8
            mov     rf, lk_after
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, w_cur
            ldn     rf
            ori     S_L
            str     rf
            ldi     1
            call    ri_adv
            lbr     ri_loop
rbk_ref:
            call    fbr                 ; RF at j+1 = '['
            lbdf    ri_brack_lit
            mov     r8, ri_e
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            lbr     rbk_nourl
ri_brack_lit:
            ldi     '['
            lbr     ri_put1

; ---- <scheme:...> and <user@host> ----
ri_lt:
            call    ri_ld
            inc     rf
            mov     rd, rf              ; RD = content start
            ldi     0
            plo     rb                  ; seen : or @
lt_l:
            ldn     rf
            lbz     lt_e
            smi     33
            lbnf    lt_e
            ldn     rf
            xri     '<'
            lbz     lt_e
            ldn     rf
            xri     '>'
            lbz     lt_e
            ldn     rf
            xri     ':'
            lbz     lt_sp
            ldn     rf
            xri     '@'
            lbnz    lt_n
lt_sp:
            ldi     1
            plo     rb
lt_n:
            inc     rf
            lbr     lt_l
lt_e:
            ldn     rf
            xri     '>'
            lbnz    lt_lit
            glo     rb
            lbz     lt_lit
            glo     rf
            str     r2
            glo     rd
            xor
            lbnz    lt_ok
            ghi     rf
            str     r2
            ghi     rd
            xor
            lbz     lt_lit              ; <>
lt_ok:
            mov     r8, ri_p
            ghi     rd
            str     r8
            inc     r8
            glo     rd
            str     r8
            mov     r8, ri_f
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            inc     rf
            mov     r8, ri_i
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            mov     rf, w_cur
            ldn     rf
            ori     S_L
            str     rf
            call    put_range
            mov     rf, w_cur
            ldn     rf
            ani     $FF-S_L
            str     rf
            lbr     ri_loop
lt_lit:
            ldi     '<'
            lbr     ri_put1

;------------------------------------------------------------------
; fcc: find a code span's closing run. RF = the opening run, D = its
; length k. Returns DF = 0 and RF = the start of a run of exactly k
; backticks, or DF = 1 if there is none. Uses R7, R8, R9, RB.
;------------------------------------------------------------------
fcc:
            plo     r7
            str     r2
            glo     rf
            add
            plo     rf
            ghi     rf
            adci    0
            phi     rf
fcc_l:
            ldn     rf
            lbz     fcc_no
            xri     '`'
            lbnz    fcc_n
            mov     rb, rf
            ldi     '`'
            call    run_len
            str     r2
            glo     r7
            xor
            lbnz    fcc_l
            mov     rf, rb
            clc
            rtn
fcc_n:
            inc     rf
            lbr     fcc_l
fcc_no:
            stc
            rtn

;------------------------------------------------------------------
; fbr / fpr: RF at [ or ( -- find the matching ] or ), skipping
; backslash escapes and counting nesting. DF = 0 and RF at it, or
; DF = 1. Use R9.0.
;------------------------------------------------------------------
fbr:
            ldi     1
            plo     r9
            inc     rf
fbr_l:
            ldn     rf
            lbz     fbr_no
            xri     92
            lbnz    fbr_nb
            inc     rf
            ldn     rf
            lbz     fbr_l
            inc     rf
            lbr     fbr_l
fbr_nb:
            ldn     rf
            xri     '['
            lbnz    fbr_nob
            glo     r9
            adi     1
            plo     r9
            lbr     fbr_nx
fbr_nob:
            ldn     rf
            xri     ']'
            lbnz    fbr_nx
            glo     r9
            smi     1
            plo     r9
            lbz     fbr_yes
fbr_nx:
            inc     rf
            lbr     fbr_l
fbr_yes:
            clc
            rtn
fbr_no:
            stc
            rtn

fpr:
            ldi     1
            plo     r9
            inc     rf
fpr_l:
            ldn     rf
            lbz     fpr_no
            xri     92
            lbnz    fpr_nb
            inc     rf
            ldn     rf
            lbz     fpr_l
            inc     rf
            lbr     fpr_l
fpr_nb:
            ldn     rf
            xri     '('
            lbnz    fpr_nob
            glo     r9
            adi     1
            plo     r9
            lbr     fpr_nx
fpr_nob:
            ldn     rf
            xri     ')'
            lbnz    fpr_nx
            glo     r9
            smi     1
            plo     r9
            lbz     fpr_yes
fpr_nx:
            inc     rf
            lbr     fpr_l
fpr_yes:
            clc
            rtn
fpr_no:
            stc
            rtn

;------------------------------------------------------------------
; emph_class: the run of k (D) * or _ at RF. Returns D bit 0 = it can
; open emphasis, bit 1 = it can close it (CommonMark flanking rules).
; RF is preserved. Uses R7-R9, RB-RD.
;------------------------------------------------------------------
emph_class:
            plo     r9                  ; k
            ldn     rf
            plo     rb
            mov     r8, ec_ch
            glo     rb
            str     r8
            ; previous character: a space at the block's start
            mov     r8, ri_start
            lda     r8
            phi     rd
            ldn     r8
            plo     rd
            glo     rd
            str     r2
            glo     rf
            xor
            lbnz    ec_hp
            ghi     rd
            str     r2
            ghi     rf
            xor
            lbnz    ec_hp
            ldi     ' '
            lbr     ec_sp
ec_hp:
            dec     rf
            ldn     rf
            inc     rf
ec_sp:
            plo     rb
            mov     r8, ec_prev
            glo     rb
            str     r8
            ; next character: RF + k
            glo     r9
            str     r2
            glo     rf
            add
            plo     rd
            ghi     rf
            adci    0
            phi     rd
            ldn     rd
            plo     rb
            mov     r8, ec_next
            glo     rb
            str     r8
            ; RC.0: 1 prev blank, 2 next blank, 4 prev punct, 8 next punct
            ldi     0
            plo     rc
            mov     r8, ec_prev
            ldn     r8
            call    is_ws
            lbnf    ec_1
            glo     rc
            ori     1
            plo     rc
ec_1:
            mov     r8, ec_next
            ldn     r8
            call    is_ws
            lbnf    ec_2
            glo     rc
            ori     2
            plo     rc
ec_2:
            mov     r8, ec_prev
            ldn     r8
            call    is_punct
            lbnf    ec_3
            glo     rc
            ori     4
            plo     rc
ec_3:
            mov     r8, ec_next
            ldn     r8
            call    is_punct
            lbnf    ec_4
            glo     rc
            ori     8
            plo     rc
ec_4:
            ; RB.0: bit 0 left-flanking, bit 1 right-flanking
            ldi     0
            plo     rb
            glo     rc
            ani     2
            lbnz    ec_noleft           ; next is blank
            glo     rc
            ani     8
            lbz     ec_left             ; next not punctuation
            glo     rc
            ani     5
            lbz     ec_noleft           ; prev neither blank nor punct
ec_left:
            glo     rb
            ori     1
            plo     rb
ec_noleft:
            glo     rc
            ani     1
            lbnz    ec_noright          ; prev is blank
            glo     rc
            ani     4
            lbz     ec_right            ; prev not punctuation
            glo     rc
            ani     10
            lbz     ec_noright          ; next neither blank nor punct
ec_right:
            glo     rb
            ori     2
            plo     rb
ec_noright:
            mov     r8, ec_ch
            ldn     r8
            xri     '*'
            lbnz    ec_under
            glo     rb
            rtn
ec_under:
            ; _ : open = left and (not right or prev punct)
            ;     close = right and (not left or next punct)
            ldi     0
            plo     r9
            glo     rb
            ani     1
            lbz     eu_noopen
            glo     rb
            ani     2
            lbz     eu_open
            glo     rc
            ani     4
            lbz     eu_noopen
eu_open:
            glo     r9
            ori     1
            plo     r9
eu_noopen:
            glo     rb
            ani     2
            lbz     eu_noclose
            glo     rb
            ani     1
            lbz     eu_close
            glo     rc
            ani     8
            lbz     eu_noclose
eu_close:
            glo     r9
            ori     2
            plo     r9
eu_noclose:
            glo     r9
            rtn

;------------------------------------------------------------------
; fec: does the run of k (D) * or _ at RF have a closer later in the
; text (same character, same length, able to close; backslash escapes
; and code spans skipped)? DF = 0 yes, DF = 1 no.
;------------------------------------------------------------------
fec:
            plo     r9
            mov     r8, fec_k
            glo     r9
            str     r8
            ldn     rf
            plo     r9
            mov     r8, fec_ch
            glo     r9
            str     r8
            mov     r8, fec_k
            ldn     r8
            str     r2
            glo     rf
            add
            plo     rf
            ghi     rf
            adci    0
            phi     rf                  ; j = RF + k
fec_loop:
            mov     r8, fec_j
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8
            ldn     rf
            lbz     fec_fail
            xri     92
            lbnz    fec_nbs
            inc     rf
            ldn     rf
            lbz     fec_loop
            inc     rf
            lbr     fec_loop
fec_nbs:
            ldn     rf
            xri     '`'
            lbnz    fec_nt
            ldi     '`'
            call    run_len             ; D = m
            plo     r9
            mov     r8, fec_m
            glo     r9
            str     r8
            mov     r8, fec_j
            lda     r8
            phi     rf
            ldn     r8
            plo     rf
            mov     r8, fec_m
            ldn     r8
            call    fcc
            lbnf    fec_addm            ; RF = e: j = e + m
            mov     r8, fec_j
            lda     r8
            phi     rf
            ldn     r8
            plo     rf                  ; no close: j = j + m
fec_addm:
            mov     r8, fec_m
            ldn     r8
            str     r2
            glo     rf
            add
            plo     rf
            ghi     rf
            adci    0
            phi     rf
            lbr     fec_loop
fec_nt:
            mov     r8, fec_ch
            ldn     r8
            str     r2
            ldn     rf
            xor
            lbnz    fec_next
            ldn     rf
            call    run_len             ; D = m
            plo     r9
            mov     r8, fec_m
            glo     r9
            str     r8
            mov     r8, fec_k
            ldn     r8
            str     r2
            glo     r9
            xor
            lbnz    fec_skipm
            mov     r8, fec_j
            lda     r8
            phi     rf
            ldn     r8
            plo     rf
            mov     r8, fec_k
            ldn     r8
            call    emph_class
            ani     2
            lbz     fec_skipm
            clc
            rtn
fec_skipm:
            mov     r8, fec_j
            lda     r8
            phi     rf
            ldn     r8
            plo     rf
            lbr     fec_addm
fec_next:
            inc     rf
            lbr     fec_loop
fec_fail:
            stc
            rtn

;------------------------------------------------------------------
; The row builder. A row is assembled in rb_buf (text plus escape
; sequences); w_col counts its visible columns. Word mode breaks at the
; last space when a character would pass the width; otherwise a row is
; cut where it fills.
;------------------------------------------------------------------

; w_put: add the character D to the block being rendered.
;
; Fast path, taken for nearly every character: printable ASCII, the row
; started and not full, the wanted style already in effect, the buffer
; not near its limit. It appends in place (using only D, R7-R9, RF) and
; for a word-mode space records the break point. Anything else goes the
; general way (wp_slow). Relies on w_started..rb_len being laid out in
; that order (see the data).
w_put:
            plo     r7
            smi     32
            lbnf    wp_slow             ; control character
            glo     r7
            smi     127
            lbdf    wp_slow             ; DEL, or UTF-8
            mov     r8, w_started
            lda     r8
            lbz     wp_slow             ; no row yet
            lda     r8                  ; wid
            str     r2
            lda     r8                  ; w_col
            sm                          ; col - wid
            lbdf    wp_slow             ; row full
            lda     r8                  ; w_cur
            str     r2
            lda     r8                  ; w_rstyle
            xor
            lbz     wpf_style           ; style already in effect
            ldn     r8                  ; w_basef
            lbnz    wp_slow
            dec     r8
            ldn     r8                  ; w_rstyle: plain, and
            xri     $FF
            lbnz    wp_slow
            dec     r8
            ldn     r8                  ; w_cur: none wanted
            lbnz    wp_slow
            inc     r8
            inc     r8
wpf_style:
            inc     r8                  ; -> rb_len
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = rb_len, R8 -> its low byte
            ghi     r9                  ; below RB_SOFT ($385)?
            smi     3
            lbnf    wpf_ok
            lbnz    wp_slow
            glo     r9
            smi     $85
            lbdf    wp_slow
wpf_ok:
            glo     r7
            xri     32
            lbnz    wpf_char
            mov     rf, w_words
            ldn     rf
            lbz     wpf_char            ; code: a space is just a char
            mov     rf, w_pcol
            ldn     rf
            str     r2
            mov     rf, w_col
            ldn     rf
            xor
            lbz     wpf_ret             ; no space at a row's start
            mov     rf, w_brk           ; break point: this space
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, w_rstyle
            ldn     rf
            phi     r7
            mov     rf, w_bst
            ghi     r7
            str     rf
            mov     r8, rb_len+1
wpf_char:
            inc     r9
            glo     r9
            str     r8
            dec     r8
            ghi     r9
            str     r8
            dec     r9
            mov     r8, rb_buf
            glo     r9
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r9
            str     r2
            ghi     r8
            adc
            phi     r8
            glo     r7
            str     r8
            mov     r8, w_col
            ldn     r8
            adi     1
            str     r8
wpf_ret:
            rtn

wp_slow:
            glo     r7
            plo     r7
            mov     rf, wp_c
            glo     r7
            str     rf
            mov     rf, w_started
            ldn     rf
            lbnz    wp_go
            ldi     1
            call    w_start
wp_go:
            mov     rf, wp_c
            ldn     rf
            xri     9
            lbnz    wp_nt
            ldi     32
            str     rf
wp_nt:
            ldn     rf
            smi     32
            lbnf    wp_ret              ; control character
            ldn     rf
            xri     127
            lbz     wp_ret
            ldn     rf
            ani     $C0
            xri     $80
            lbnz    wp_vis
            ldn     rf                  ; UTF-8 continuation: no width
            lbr     rb_append
wp_vis:
            ldn     rf
            xri     32
            lbnz    wp_char
            mov     rf, w_words
            ldn     rf
            lbz     wp_char
            ; a space in word mode: never at the start of a row
            mov     rf, w_pcol
            ldn     rf
            str     r2
            mov     rf, w_col
            ldn     rf
            xor
            lbz     wp_ret
            mov     rf, wid
            ldn     rf
            str     r2
            mov     rf, w_col
            ldn     rf
            sm                          ; col - W
            lbnf    wp_sp_fits
            call    w_end_row           ; the row is full: the space
            ldi     0                   ; is the break
            lbr     w_start
wp_sp_fits:
            call    w_apply
            ldi     32
            call    rb_append
            call    col_inc
            mov     rf, rb_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            dec     r8
            mov     rf, w_brk
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, w_rstyle
            ldn     rf
            plo     r8
            mov     rf, w_bst
            glo     r8
            str     rf
wp_ret:
            rtn
wp_char:
            mov     rf, wid
            ldn     rf
            str     r2
            mov     rf, w_col
            ldn     rf
            sm                          ; col - W
            lbdf    wp_break
            mov     rf, rb_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            sub16   r8, RB_SOFT
            lbnf    wp_place
wp_break:
            mov     rf, w_words
            ldn     rf
            lbz     wp_hard
            mov     rf, w_brk
            ldn     rf
            xri     $FF
            lbnz    wp_soft
            inc     rf
            ldn     rf
            xri     $FF
            lbnz    wp_soft
wp_hard:
            call    w_end_row
            ldi     0
            call    w_start
            lbr     wp_place
wp_soft:
            call    w_softbreak
wp_place:
            call    w_apply
            mov     rf, wp_c
            ldn     rf
            call    rb_append
            lbr     col_inc

; col_inc: w_col += 1
col_inc:
            mov     rf, w_col
            ldn     rf
            adi     1
            str     rf
            rtn

; w_softbreak: end the row at the last space; what followed it moves to
; a new row.
w_softbreak:
            mov     rf, w_brk
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            inc     r8                  ; R8 = first byte after the space
            mov     rf, rb_len
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = end
            glo     r8
            str     r2
            glo     r9
            sm
            plo     rc
            ghi     r8
            str     r2
            ghi     r9
            smb
            phi     rc                  ; RC = count
            mov     rf, rest_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            mov     rf, rb_buf
            add16   rf, r8
            mov     rd, rest_buf
            ldi     0
            plo     rb                  ; visible count
            phi     rb                  ; inside an escape
sb_cp:
            ghi     rc
            lbnz    sb_cp1
            glo     rc
            lbz     sb_cp_done
sb_cp1:
            lda     rf
            str     rd
            inc     rd
            dec     rc
            plo     r7
            ghi     rb
            lbz     sb_notesc
            glo     r7
            xri     'm'
            lbnz    sb_cp
            ldi     0
            phi     rb
            lbr     sb_cp
sb_notesc:
            glo     r7
            xri     27
            lbnz    sb_vis
            ldi     1
            phi     rb
            lbr     sb_cp
sb_vis:
            glo     r7
            ani     $C0
            xri     $80
            lbz     sb_cp
            glo     rb
            adi     1
            plo     rb
            lbr     sb_cp
sb_cp_done:
            mov     rf, sb_vis_n
            glo     rb
            str     rf
            ; the row ends at the space, in the style that was on there
            mov     rf, w_brk
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, rb_len
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
            mov     rf, w_rstyle
            ldn     rf
            plo     r8
            mov     rf, sb_old
            glo     r8
            str     rf
            mov     rf, w_bst
            ldn     rf
            plo     r8
            mov     rf, w_rstyle
            glo     r8
            str     rf
            call    w_end_row
            ldi     0
            call    w_start
            mov     rf, w_bst
            ldn     rf
            xri     $FF
            lbz     sb_nosgr
            mov     rf, w_bst
            ldn     rf
            call    rb_sgr
sb_nosgr:
            mov     rf, rest_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
            mov     rf, rest_buf
sb_ap:
            ghi     rc
            lbnz    sb_ap1
            glo     rc
            lbz     sb_ap_done
sb_ap1:
            lda     rf
            call    rb_append           ; keeps RF, RC
            dec     rc
            lbr     sb_ap
sb_ap_done:
            mov     rf, sb_old
            ldn     rf
            plo     r8
            mov     rf, w_rstyle
            glo     r8
            str     rf
            mov     rf, sb_vis_n
            ldn     rf
            str     r2
            mov     rf, w_col
            ldn     rf
            add
            str     rf
            rtn

; w_apply: make the terminal's style (w_rstyle, $FF = plain) match the
; wanted one (w_cur, plus the heading base) before a visible byte.
w_apply:
            mov     rf, w_cur
            ldn     rf
            lbnz    wa_want
            mov     rf, w_base
            lda     rf
            lbnz    wa_want
            ldn     rf
            lbnz    wa_want
            mov     rf, w_rstyle
            ldn     rf
            xri     $FF
            lbz     wa_ret
            ldi     $FF
            str     rf
            mov     rf, s_reset
            lbr     rb_esc
wa_want:
            mov     rf, w_cur
            ldn     rf
            str     r2
            mov     rf, w_rstyle
            ldn     rf
            xor
            lbz     wa_ret
            mov     rf, w_cur
            ldn     rf
            plo     r8
            mov     rf, w_rstyle
            glo     r8
            str     rf
            glo     r8
            lbr     rb_sgr
wa_ret:
            rtn

; w_start: begin a row (D = 1 for a block's first row): the pending
; blank line, then the prefix -- margin, list marker, or quote bar.
w_start:
            plo     r8
            mov     rf, ws_first
            glo     r8
            str     rf
            call    blank_check
            call    rb_clear
            mov     rf, w_rstyle
            ldi     $FF
            str     rf
            mov     rf, w_brk
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            mov     rf, w_started
            ldi     1
            str     rf
            mov     rf, w_ptype
            ldn     rf
            lbz     ws_spaces
            xri     1
            lbz     ws_list
            call    quote_bar           ; quote: "| "
            ldi     ' '
            call    rb_append
            ldi     2
            lbr     ws_setcol
ws_list:
            mov     rf, ws_first
            ldn     rf
            lbz     ws_cont
            mov     rf, margin
            ldn     rf
            call    rb_spaces
            mov     rf, s_mark_sgr
            call    rb_esc
            mov     rf, mk_len
            ldn     rf
            plo     rc
            mov     rf, mk_buf
ws_mk:
            lda     rf
            call    rb_append           ; keeps RF, RC
            glo     rc
            smi     1
            plo     rc
            lbnz    ws_mk
            mov     rf, s_reset
            call    rb_esc
            ldi     ' '
            call    rb_append
            mov     rf, margin
            ldn     rf
            str     r2
            mov     rf, mk_len
            ldn     rf
            add
            adi     1
            lbr     ws_setcol
ws_spaces:
            mov     rf, ws_first
            ldn     rf
            lbz     ws_cont
            mov     rf, w_fsp
            ldn     rf
            lbr     ws_sp
ws_cont:
            mov     rf, w_csp
            ldn     rf
ws_sp:
            plo     r8
            mov     rf, ws_n
            glo     r8
            str     rf
            glo     r8
            call    rb_spaces
            mov     rf, ws_n
            ldn     rf
ws_setcol:
            plo     r8
            mov     rf, w_col
            glo     r8
            str     rf
            mov     rf, w_pcol
            glo     r8
            str     rf
            rtn

; w_end_row: close the row's style and print it
w_end_row:
            mov     rf, w_rstyle
            ldn     rf
            xri     $FF
            lbz     out_row
            mov     rf, s_reset
            call    rb_esc
            lbr     out_row

; w_finish: end the block (an empty block still prints its prefix row)
w_finish:
            mov     rf, w_started
            ldn     rf
            lbnz    wf_go
            ldi     1
            call    w_start
wf_go:
            call    w_end_row
            mov     rf, w_started
            ldi     0
            str     rf
            rtn

;------------------------------------------------------------------
; rb_*: append to the row buffer. rb_append keeps RF, RB, RC, RD.
;------------------------------------------------------------------
rb_clear:
            mov     rf, rb_len
            ldi     0
            str     rf
            inc     rf
            str     rf
            rtn

; rb_append: add byte D (dropped once the buffer is near full).
; Uses R7, R8, R9.
rb_append:
            plo     r9
            mov     r8, rb_len
            lda     r8
            phi     r7
            ldn     r8
            plo     r7                  ; R7 = len, R8 -> its low byte
            ghi     r7
            smi     4
            lbdf    rba_drop            ; 1024 or more
            inc     r7
            glo     r7
            str     r8
            dec     r8
            ghi     r7
            str     r8
            dec     r7
            mov     r8, rb_buf
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
            glo     r9
            str     r8
rba_drop:
            rtn

; rb_str: add the NUL-terminated string at RF
rb_str:
            lda     rf
            lbz     rbs_done
            call    rb_append
            lbr     rb_str
rbs_done:
            rtn

; rb_esc: add the escape string at RF, unless -p
rb_esc:
            mov     r8, opt_plain
            ldn     r8
            lbz     rb_str
            rtn

; rb_spaces: add D spaces
rb_spaces:
            plo     rc
rbsp_l:
            glo     rc
            lbz     rbsp_d
            ldi     ' '
            call    rb_append
            glo     rc
            smi     1
            plo     rc
            lbr     rbsp_l
rbsp_d:
            rtn

; rb_sgr: add the SGR sequence for style bits D (plus the heading
; base), unless -p: ESC[0 base ;1 ;3 ;4 ;33 ;32 m
rb_sgr:
            plo     rc
            mov     rf, sg_bits
            glo     rc
            str     rf
            mov     rf, opt_plain
            ldn     rf
            lbnz    sg_ret
            mov     rf, s_sgr0
            call    rb_str
            mov     rf, w_base
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            ghi     r8
            lbnz    sg_base
            glo     r8
            lbz     sg_nobase
sg_base:
            mov     rf, r8
            call    rb_str
sg_nobase:
            mov     rf, sg_bits
            ldn     rf
            ani     S_B
            lbz     sg_1
            mov     rf, s_b
            call    rb_str
sg_1:
            mov     rf, sg_bits
            ldn     rf
            ani     S_I
            lbz     sg_2
            mov     rf, s_i
            call    rb_str
sg_2:
            mov     rf, sg_bits
            ldn     rf
            ani     S_L
            lbz     sg_3
            mov     rf, s_l
            call    rb_str
sg_3:
            mov     rf, sg_bits
            ldn     rf
            ani     S_C
            lbz     sg_4
            mov     rf, s_c
            call    rb_str
sg_4:
            mov     rf, sg_bits
            ldn     rf
            ani     S_U
            lbz     sg_5
            mov     rf, s_u
            call    rb_str
sg_5:
            ldi     'm'
            lbr     rb_append
sg_ret:
            rtn

;------------------------------------------------------------------
; out_row: print the row buffer and a CR LF; page if it is time
;------------------------------------------------------------------
out_row:
            mov     rf, any_out
            ldi     1
            str     rf
            mov     rf, quit
            ldn     rf
            lbnz    or_ret
            mov     rf, rb_len
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, rb_buf
            add16   rf, r8
            ldi     0
            str     rf
            mov     rf, rb_buf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, paging
            ldn     rf
            lbz     or_ret
            mov     rf, rows_out
            ldn     rf
            adi     1
            str     rf
            plo     r8
            mov     rf, pg_rows
            ldn     rf
            str     r2
            glo     r8
            sm                          ; rows_out - pg_rows
            lbdf    more_prompt
or_ret:
            rtn

; more_prompt: --More--, then a key: q quits, ENTER or Down one line,
; anything else a page.
more_prompt:
            mov     rf, opt_plain
            ldn     rf
            lbnz    mp_plain
            call    K_INMSG
            db      27,"[7m--More--",27,"[0m",0
            lbr     mp_key
mp_plain:
            call    K_INMSG
            db      "--More--",0
mp_key:
            call    K_READ
            plo     r8
            ani     $DF
            xri     'Q'
            lbz     mp_quit
            glo     r8
            xri     13
            lbz     mp_line
            glo     r8
            xri     10
            lbz     mp_line
            glo     r8
            xri     27
            lbnz    mp_page
            call    K_READ              ; ESC: an arrow key?
            xri     '['
            lbnz    mp_page
            call    K_READ
            plo     r8
            xri     'B'
            lbz     mp_line             ; Down
            glo     r8
            xri     '6'
            lbnz    mp_notpgdn
            call    K_READ              ; the ~ of ESC[6~ (Page Down)
            lbr     mp_page
mp_notpgdn:
            glo     r8
            smi     '0'
            lbnf    mp_key
            glo     r8
            smi     '9'+1
            lbdf    mp_key
            call    K_READ              ; the ~ of another ESC[n~
            lbr     mp_key
mp_quit:
            mov     rf, quit
            ldi     1
            str     rf
            lbr     mp_erase
mp_line:
            mov     rf, pg_rows
            ldn     rf
            smi     1
            plo     r8
            mov     rf, rows_out
            glo     r8
            str     rf
            lbr     mp_erase
mp_page:
            mov     rf, rows_out
            ldi     0
            str     rf
mp_erase:
            mov     rf, opt_plain
            ldn     rf
            lbnz    mp_erase_p
            call    K_INMSG
            db      13,27,"[K",0
            rtn
mp_erase_p:
            call    K_INMSG
            db      13,"        ",13,0
            rtn

;------------------------------------------------------------------
; strings
;------------------------------------------------------------------
s_sgr0:         db      27,"[0",0
s_reset:        db      27,"[0m",0
s_mark_sgr:     db      27,"[36m",0
s_bar_sgr:      db      27,"[32m",0
s_hr_sgr:       db      27,"[36m",0
s_h1:           db      ";1",';',"4",';',"36",0
s_h2:           db      ";1",';',"36",0
s_h3:           db      ";1",';',"35",0
s_h4:           db      ";1",0
s_b:            db      ";1",0
s_i:            db      ";3",0
s_l:            db      ";4",0
s_c:            db      ";33",0
s_u:            db      ";32",0

;------------------------------------------------------------------
; data
;------------------------------------------------------------------
opt_cont:       db      0
opt_plain:      db      0
fname:          dw      0
pg_rows:           db      23
paging:         db      0
rows_out:       db      0
quit:           db      0

rd_pos:         dw      0
rd_len:         dw      0
rd_eof:         db      0

blk_base:       dw      0
blk_cap:        dw      0
blk_len:        dw      0

kind:           db      0
level:          db      0
margin:         db      0
mk_len:         db      0
mk_buf:         ds      12
cont:           db      0
in_list:        db      0
list_cont:      db      0
in_fence:       db      0
fch:            db      0
flen:           db      0
find:           db      0
any_out:        db      0
need_blank:     db      0

rl_dst:         dw      0
rl_max:         dw      0
rl_part:        db      0
prev_part:      db      0
rl_sv:          ds      5

ln_p:           dw      0
ln_s:           dw      0
ln_end:         dw      0
ln_ind:         db      0
nl_c:           dw      0
nl_q:           db      0
hd_c:           dw      0
hd_level:       db      0
sb_kind:        db      0
rt_kind:        db      0

w_words:        db      0
w_ptype:        db      0
w_fsp:          db      0
w_csp:          db      0
w_base:         dw      0
; w_started..rb_len: this order is relied on by w_put's fast path
w_started:      db      0
wid:            db      79
w_col:          db      0
w_cur:          db      0
w_rstyle:       db      $FF
w_basef:        db      0           ; w_base is set
rb_len:         dw      0
w_pcol:         db      0
w_brk:          dw      $FFFF
w_bst:          db      0
wp_c:           db      0
ws_first:       db      0
ws_n:           db      0
sg_bits:        db      0
rest_len:       dw      0
sb_vis_n:       db      0
sb_old:         db      0

cr_p:           dw      0
cr_col:         db      0
cr_n:           db      0

ri_start:       dw      0
ri_i:           dw      0
ri_c:           db      0
ri_n:           db      0
ri_k:           db      0
ri_need:        db      0
ri_p:           dw      0
ri_f:           dw      0
ri_e:           dw      0
ri_j:           dw      0
it_ch:          db      0
bo_ch:          db      0
lk_end:         dw      0
lk_after:       dw      0
url_s:          dw      0
url_e:          dw      0

ec_ch:          db      0
ec_prev:        db      0
ec_next:        db      0
fec_j:          dw      0
fec_k:          db      0
fec_ch:         db      0
fec_m:          db      0

.align  32                  ; FCB must not straddle a page --
                            ; file_open rejects one that does
in_fcb:         ds      FCB_LEN
#if (in_fcb & $FF) > (256 - FCB_LEN)
#error in_fcb crosses a page boundary
#endif
in_iobuf:       ds      FCB_IOBUF_LEN
rd_buf:         ds      RD_CHUNK
rb_buf:         ds      RB_LEN
rest_buf:       ds      RB_LEN
                db      0           ; so the buffers above are part of
                                    ; the image, not overlapped by the
                                    ; libraries linked after it

            end     start
