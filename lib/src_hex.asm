;
; src_hex.asm - the HEX data source for lib/pager.asm.
;
; Implements the pager's SOURCE CONTRACT (see lib/pager.asm's header)
; over an ordinary file, shown `hexdump -C` style: one row per "line" --
; an 8-digit hex offset, the bytes in hex in two equal groups, then the
; same bytes as ASCII between bars. A short final row pads its
; missing hex positions so the bar column still lines up; the ASCII
; field itself is never padded.
;
;   00000000  48 65 6c 6c 6f 0a 00 ff  01 02 03 04 05 06 07 08  |Hello...........|
;
; BYTES PER ROW is 16 unless the program sets otherwise with hx_set_row
; (HEXDUMP fits it to COLUMNS): any multiple of 4 from 4 to 32. A row is
; 14 + 4*n characters -- 78 for 16 bytes, 62 for 12.
;
; A POSITION is a byte offset into the file (32-bit, big-endian, the same
; form as the kernel's), and every position this source hands out starts
; a row -- a multiple of the row length -- except one: the file's own
; size, where reading stops. Because rows are fixed-width, everything
; that has to SCAN in the text source is plain arithmetic here: the row
; before a position is (position-1) rounded down to a row, the last page
; is the size stepped back n rows, and a typed number is a byte offset
; rounded down to its row. Rounding is "subtract position mod row
; length", a 32-step shift-and-subtract (hx_round_down) -- the row
; length need not be a power of two. Only src_read_line and src_search
; touch the disk.
;
; Offsets are full 32-bit values, so files over 64K show their real
; offsets (the old stand-alone HEXDUMP stopped at 16 bits).
;
; Register discipline: nothing is trusted to survive a kernel call;
; state lives in memory. The row formatter makes no calls into the
; kernel at all, so it works in registers throughout.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

HX_ROW_MAX:     equ     32          ; most bytes per row (hx_set_row clamps)
HX_LINE_MAX:    equ     144         ; 14 + 4*32 = 142 characters + NUL
HX_CHUNK_LEN:   equ     128         ; K_FILE_READ chunk -- MUST stay <= 255,
                                    ; it is loaded with a one-byte ldi (see
                                    ; lib/src_file.asm's LESS_CHUNK_LEN for
                                    ; the hardware bug that taught that)

;------------------------------------------------------------------
; src_open: open the named file and learn its size.
; Args:    RF = pointer to a NUL-terminated path
; Returns: DF=0 opened and positioned at 0, hx_size = its byte count;
;          DF=1 could not be opened
; Modifies: everything
;------------------------------------------------------------------
            proc    src_open
            extrn   hx_fcb
            extrn   hx_iobuf
            extrn   hx_path
            extrn   hx_size
            extrn   hx_stat_buf
            extrn   src_rewind
            extrn   copy4bytes
            extrn   zero4bytes

            mov     r8, hx_path         ; keep the path: K_FILE_OPEN
            ghi     rf                  ; clobbers RF
            str     r8
            inc     r8
            glo     rf
            str     r8

            mov     rd, hx_fcb
            mov     ra, hx_iobuf
            ldi     0                   ; mode 0 = read
            call    K_FILE_OPEN
            lbdf    hop_fail

            call    src_rewind          ; src_pos = 0, chunk buffer empty
                                        ; -- 'ds' storage is not zeroed

            mov     rf, hx_path
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            mov     rd, hx_stat_buf
            call    K_STAT
            lbdf    hop_nosize

            mov     rf, hx_stat_buf
            add16   rf, DIRENT_SIZE
            mov     rd, hx_size
            call    copy4bytes
            clc
            rtn

hop_nosize:
            ; opened but the size is unknown: treat it as 0, so 'G' and a
            ; typed offset land at the top rather than somewhere wild.
            ; Reading still works -- the rows just come from the file.
            mov     rf, hx_size
            call    zero4bytes
            clc
            rtn

hop_fail:
            stc
            rtn
            endp

;------------------------------------------------------------------
; src_close: close the file.
;------------------------------------------------------------------
            proc    src_close
            extrn   hx_fcb

            mov     rd, hx_fcb
            call    K_FILE_CLOSE
            rtn
            endp

;------------------------------------------------------------------
; src_rewind: back to offset 0 with the chunk buffer invalidated.
;------------------------------------------------------------------
            proc    src_rewind
            extrn   src_pos
            extrn   src_seek_to
            extrn   zero4bytes

            mov     rf, src_pos
            call    zero4bytes
            mov     rf, src_pos
            call    src_seek_to
            rtn
            endp

;------------------------------------------------------------------
; src_seek_to: seek to the 4-byte position at [RF], set src_pos to it,
; and empty the chunk buffer so the next byte really comes from there.
; Args:    RF = pointer to a 4-byte position (may be src_pos itself)
; Returns: src_pos = that position
; Modifies: everything
;------------------------------------------------------------------
            proc    src_seek_to
            extrn   hx_fcb
            extrn   hx_chunk_rem
            extrn   src_pos
            extrn   copy4bytes

            mov     rd, src_pos
            call    copy4bytes          ; src_pos = [RF]

            mov     rf, src_pos
            lda     rf
            phi     ra
            lda     rf
            plo     ra                  ; RA = high word
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = low word

            mov     rd, hx_fcb
            ldi     0
            plo     rc                  ; whence = SEEK_SET
            call    K_FILE_SEEK

            mov     rf, hx_chunk_rem
            ldi     0
            str     rf
            rtn
            endp

;------------------------------------------------------------------
; src_read_line: format the row at src_pos into src_line_buf.
; Returns: DF=0 -- src_line_buf holds the row, src_pos advanced past it
;                  (by the row length, or by fewer for the last row)
;          DF=1 -- no bytes left
; Modifies: everything
;------------------------------------------------------------------
            proc    src_read_line
            extrn   hx_getbyte
            extrn   hx_rowbuf
            extrn   hx_count
            extrn   hx_rowlen
            extrn   src_pos
            extrn   src_line_buf
            extrn   addbyte32

            mov     rf, hx_count
            ldi     0
            str     rf                  ; hx_count = 0

hrl_fill:
            mov     rf, hx_count
            ldn     rf
            str     r2
            mov     rf, hx_rowlen       ; (mov leaves M(R2) alone)
            ldn     rf
            sm                          ; rowlen - count
            lbz     hrl_have            ; a full row

            call    hx_getbyte          ; D = byte, DF=1 at the end
            lbdf    hrl_end
            plo     r9                  ; stash the byte (gotcha #4)

            mov     rf, hx_count
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = count
            mov     rf, hx_rowbuf
            add16   rf, r8              ; RF = &rowbuf[count]
            glo     r9
            str     rf

            mov     rf, hx_count
            ldn     rf
            adi     1
            str     rf
            lbr     hrl_fill

hrl_end:
            mov     rf, hx_count
            ldn     rf
            lbnz    hrl_have            ; a short last row
            stc                         ; nothing at all
            rtn

hrl_have:
            ; From here to the NUL nothing calls the kernel, so the work
            ; stays in registers: RF = write cursor, RA = next row byte,
            ; RB.0 = bytes in this row, R9.0 = column, RC.0 = bytes per
            ; row, RC.1 = half that (where the gap goes). hx_hexbyte and
            ; hx_nibble touch only D and R7.
            mov     r8, hx_rowlen
            ldn     r8
            plo     rc
            shr
            phi     rc
            mov     rf, src_line_buf
            mov     ra, src_pos
            lda     ra
            call    hx_hexbyte
            lda     ra
            call    hx_hexbyte
            lda     ra
            call    hx_hexbyte
            ldn     ra
            call    hx_hexbyte          ; 8-digit offset of this row
            ldi     ' '
            str     rf
            inc     rf
            str     rf
            inc     rf

            mov     rb, hx_count
            ldn     rb
            plo     rb                  ; RB.0 = bytes in this row
            mov     ra, hx_rowbuf
            ldi     0
            plo     r9                  ; column = 0

hrl_hex:
            ghi     rc
            str     r2
            glo     r9
            sm                          ; column - half
            lbnz    hrl_nogap
            ldi     ' '                 ; the gap between the two groups
            str     rf
            inc     rf
hrl_nogap:
            glo     rb
            str     r2
            glo     r9
            sm                          ; column - count: DF=0 iff column < count
            lbnf    hrl_byte
            ldi     ' '                 ; past the end of a short row
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            lbr     hrl_hex_next
hrl_byte:
            lda     ra
            call    hx_hexbyte
            ldi     ' '
            str     rf
            inc     rf
hrl_hex_next:
            glo     r9
            adi     1
            plo     r9
            str     r2
            glo     rc
            sm                          ; rowlen - (column+1)
            lbnz    hrl_hex

            ldi     ' '
            str     rf
            inc     rf
            ldi     '|'
            str     rf
            inc     rf

            mov     ra, hx_rowbuf
            ldi     0
            plo     r9                  ; column = 0
hrl_asc:
            glo     rb
            str     r2
            glo     r9
            sm                          ; column - count
            lbdf    hrl_asc_done        ; DF=1: column >= count
            lda     ra
            plo     r7
            smi     $20
            lbnf    hrl_dot             ; below space
            glo     r7
            smi     $7F
            lbdf    hrl_dot             ; DEL and above
            glo     r7
            lbr     hrl_put
hrl_dot:
            ldi     '.'
hrl_put:
            str     rf
            inc     rf
            glo     r9
            adi     1
            plo     r9
            lbr     hrl_asc

hrl_asc_done:
            ldi     '|'
            str     rf
            inc     rf
            ldi     0
            str     rf                  ; NUL: at most 78 characters written

            ; only now move past the row -- the offset printed above had
            ; to be the row's own start
            mov     rf, hx_count
            ldn     rf
            plo     r9
            mov     rf, src_pos
            glo     r9
            call    addbyte32
            clc
            rtn

;------------------------------------------------------------------
; hx_hexbyte: write D as two lowercase hex digits at [RF], RF += 2.
; Modifies: D, R7
;------------------------------------------------------------------
hx_hexbyte:
            plo     r7
            shr
            shr
            shr
            shr                         ; high nibble (SHR zero-fills)
            call    hx_nibble
            str     rf
            inc     rf
            glo     r7
            ani     $0F
            call    hx_nibble
            str     rf
            inc     rf
            rtn

;------------------------------------------------------------------
; hx_nibble: D (0-15) -> its lowercase ASCII hex digit.  Modifies: D
;------------------------------------------------------------------
hx_nibble:
            smi     10
            lbnf    hxn_digit           ; borrow: < 10
            adi     'a'
            rtn
hxn_digit:
            adi     10 + '0'
            rtn
            endp

;------------------------------------------------------------------
; hx_getbyte: the next byte from the file, through a chunk buffer.
; Returns: D = byte, DF=0 -- or DF=1 at the end of the file
; Modifies: R7, R8, RC, RD, RF
;------------------------------------------------------------------
            proc    hx_getbyte
            extrn   hx_fcb
            extrn   hx_chunk_buf
            extrn   hx_chunk_ptr
            extrn   hx_chunk_rem

            mov     rf, hx_chunk_rem
            ldn     rf
            lbnz    hgb_have

            mov     rd, hx_fcb
            mov     rf, hx_chunk_buf
            ldi     HX_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
            call    K_FILE_READ         ; RC = bytes read
            glo     rc
            lbnz    hgb_got
            ghi     rc
            lbnz    hgb_got
            stc                         ; nothing read: the end
            rtn

hgb_got:
            mov     rf, hx_chunk_rem
            glo     rc
            str     rf                  ; RC <= HX_CHUNK_LEN, fits a byte
            mov     r8, hx_chunk_buf
            mov     rf, hx_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; hx_chunk_ptr = hx_chunk_buf

hgb_have:
            mov     rf, hx_chunk_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = the pointer's value
            ldn     r8
            plo     r7                  ; the byte
            inc     r8
            mov     rf, hx_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; pointer advanced
            mov     rf, hx_chunk_rem
            ldn     rf
            smi     1
            str     rf
            glo     r7
            clc
            rtn
            endp

;------------------------------------------------------------------
; src_line_of / src_line_mark: line numbers (the pager's -N) have no
; meaning for a hex view -- every row already shows its own offset.
; src_line_of answers DF=1, which turns numbering off; HEXDUMP never
; asks for it anyway.
;------------------------------------------------------------------
            proc    src_line_of
            stc
            rtn
            endp

            proc    src_line_mark
            rtn
            endp

;------------------------------------------------------------------
; src_set_mode: hex rows are a fixed width, so wrap/room mean nothing
; here -- accept and ignore. (D = wrap flag, RC.0 = room, per contract.)
;------------------------------------------------------------------
            proc    src_set_mode
            rtn
            endp

;------------------------------------------------------------------
; src_prev_start: the start of the row before the position at [RF] --
; or of the row containing it, when the position is mid-row (which
; only the file's own size ever is). Either way that is (position - 1)
; rounded down to a row; a position of 0 gives 0.
; Args:    RF = pointer to a 4-byte position
; Returns: src_prev_result
;------------------------------------------------------------------
            proc    src_prev_start
            extrn   src_prev_result
            extrn   hx_row_before
            extrn   copy4bytes

            mov     rd, src_prev_result
            call    copy4bytes          ; by value: [RF] is never touched
            mov     rf, src_prev_result
            call    hx_row_before
            rtn
            endp

;------------------------------------------------------------------
; hx_row_before: the 4-byte value at [RF] = (value - 1) rounded down to
; a row start, or left at 0 if it is already 0.
; Args:    RF = pointer.  Modifies: R7, R8, R9, RA, RC, RF, D, DF
;------------------------------------------------------------------
            proc    hx_row_before
            extrn   hx_round_down

            mov     r8, rf              ; keep the base
            ldn     rf
            lbnz    hrb_nonzero
            inc     rf
            ldn     rf
            lbnz    hrb_nonzero
            inc     rf
            ldn     rf
            lbnz    hrb_nonzero
            inc     rf
            ldn     rf
            lbnz    hrb_nonzero
            rtn                         ; already 0

hrb_nonzero:
            mov     rf, r8
            inc     rf
            inc     rf
            inc     rf                  ; RF -> LSB
            ldn     rf
            smi     1                   ; value - 1, borrow in DF
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf
            mov     rf, r8
            call    hx_round_down
            rtn
            endp

;------------------------------------------------------------------
; hx_round_down: the 4-byte value at [RF] -= (value mod bytes-per-row).
;
; The remainder comes from a restoring shift-and-subtract over all 32
; bits, MSB first: r = 2r + next bit; if r >= n then r -= n. With n at
; most 32, r stays below 64, so it fits a byte and the shift out of r
; is always 0. Makes no calls, so it all lives in registers.
; Args:    RF = pointer to a 4-byte value (left pointing at it)
; Modifies: R7, R8, R9, RA, RC, D, DF
;------------------------------------------------------------------
            proc    hx_round_down
            extrn   hx_rowlen

            mov     r7, rf              ; keep the base
            lda     rf
            phi     ra
            lda     rf
            plo     ra
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; RA:R9 = a working copy
            mov     r8, hx_rowlen
            ldn     r8
            plo     rc                  ; RC.0 = n
            ldi     0
            plo     r8                  ; R8.0 = remainder
            ldi     32
            phi     rc                  ; RC.1 = bits left

hrd_loop:
            shl16   r9
            shlc16  ra                  ; DF = the next bit, MSB first
            glo     r8
            shlc
            plo     r8                  ; r = 2r + bit
            glo     rc
            str     r2
            glo     r8
            sm                          ; r - n
            lbnf    hrd_small           ; borrow: r < n
            plo     r8                  ; r -= n
hrd_small:
            ghi     rc
            smi     1
            phi     rc
            lbnz    hrd_loop

            mov     rf, r7
            inc     rf
            inc     rf
            inc     rf                  ; LSB
            glo     r8
            str     r2
            ldn     rf
            sm                          ; value - remainder, LSB first
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf
            dec     rf
            ldn     rf
            smbi    0
            str     rf                  ; RF is back at the base
            rtn
            endp

;------------------------------------------------------------------
; hx_set_row: set the bytes per row -- rounded down to a multiple of 4,
; and held to 4..HX_ROW_MAX. Call before src_open (or at any time the
; pager is not running); it takes effect on the next row read.
; Args:    D = bytes per row
; Modifies: R7, RF, D, DF
;------------------------------------------------------------------
            proc    hx_set_row
            extrn   hx_rowlen

            ani     $FC                 ; a multiple of 4
            lbnz    hsr_nonzero
            ldi     4
hsr_nonzero:
            plo     r7
            smi     HX_ROW_MAX+1
            lbnf    hsr_ok              ; borrow: at most HX_ROW_MAX
            ldi     HX_ROW_MAX
            plo     r7
hsr_ok:
            mov     rf, hx_rowlen
            glo     r7
            str     rf
            rtn
            endp

;------------------------------------------------------------------
; src_last_page: where the last n rows begin -- the size stepped back n
; rows, stopping at 0. The first step from the size lands on the last
; row whether or not that row is full.
; Args:    D = n
; Returns: src_goto_result
;------------------------------------------------------------------
            proc    src_last_page
            extrn   src_goto_result
            extrn   hx_size
            extrn   hx_n
            extrn   hx_row_before
            extrn   copy4bytes

            plo     r7
            mov     rf, hx_n
            glo     r7
            str     rf                  ; hx_n = n

            mov     rf, hx_size
            mov     rd, src_goto_result
            call    copy4bytes          ; start from the end

hlp_loop:
            mov     rf, hx_n
            ldn     rf
            lbz     hlp_done
            mov     rf, src_goto_result
            call    hx_row_before       ; a no-op once at 0
            mov     rf, hx_n
            ldn     rf
            smi     1
            str     rf
            lbr     hlp_loop
hlp_done:
            rtn
            endp

;------------------------------------------------------------------
; src_goto: a typed number, read as a BYTE OFFSET, rounded down to the
; start of its row.
; Args:    RF = pointer to a 4-byte count
; Returns: DF=0 -- src_goto_result = count, rounded down to its row
;          DF=1 -- count >= the file size: past the end
;------------------------------------------------------------------
            proc    src_goto
            extrn   src_goto_result
            extrn   hx_size
            extrn   hx_round_down
            extrn   copy4bytes

            mov     rd, src_goto_result
            call    copy4bytes          ; result = count

            ; count - size, LSB first: no borrow means count >= size
            mov     r7, src_goto_result
            inc     r7
            inc     r7
            inc     r7
            mov     r8, hx_size
            inc     r8
            inc     r8
            inc     r8
            ldn     r8
            str     r2
            ldn     r7
            sm
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            lbdf    hgt_past_end

            mov     rf, src_goto_result
            call    hx_round_down       ; round down to the row
            clc
            rtn

hgt_past_end:
            stc
            rtn
            endp

;------------------------------------------------------------------
; src_search: find the pattern's bytes in the file at or after a start
; position. The pager has already turned escapes into bytes, so the
; pattern is a counted string that may hold any byte, $00 included.
;
; One forward pass through the chunk buffer, re-seeking only when a
; partial match fails: a failed FIRST byte leaves the stream already on
; the next candidate, so the common case never seeks at all.
;
; Answers the ROW holding the match's first byte, and resumes at the
; row after it. Resuming at the match+1 would find a second match in the
; same row, but the view would not move, so 'n' would appear to do
; nothing; stepping a row keeps every 'n' visible.
;
; Args:    RF = pattern, RC.0 = its length (1..255), RD = ptr to start
; Returns: DF=0 -- src_search_top, src_search_resume
;          DF=1 -- no match
; Leaves src_pos and the read position unspecified: callers seek after.
; Modifies: everything
;------------------------------------------------------------------
            proc    src_search
            extrn   hx_getbyte
            extrn   src_seek_to
            extrn   src_search_top
            extrn   src_search_resume
            extrn   hx_size
            extrn   hx_rowlen
            extrn   hx_round_down
            extrn   hs_pat
            extrn   hs_len
            extrn   hs_i
            extrn   hs_cand
            extrn   hs_cur
            extrn   copy4bytes
            extrn   addbyte32

            mov     r8, hs_pat
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8                  ; hs_pat = RF
            mov     r8, hs_len
            glo     rc
            str     r8                  ; hs_len = RC.0

            mov     rf, rd
            mov     rd, hs_cur
            call    copy4bytes          ; hs_cur = start

            mov     rf, hs_len
            ldn     rf
            lbz     hs_notfound         ; an empty pattern never matches

            mov     rf, hs_cur
            call    src_seek_to

hs_scan:
            mov     rf, hs_cur
            mov     rd, hs_cand
            call    copy4bytes          ; this byte is the candidate

            call    hx_getbyte
            lbdf    hs_notfound
            plo     r9                  ; stash (gotcha #4)
            mov     rf, hs_cur
            call    hs_bump             ; hs_cur++

            mov     rf, hs_pat
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            ldn     r8                  ; pattern[0]
            str     r2
            glo     r9
            sm
            lbnz    hs_scan             ; no: on to the next byte

            mov     rf, hs_i
            ldi     1
            str     rf

hs_verify:
            mov     rf, hs_i
            ldn     rf
            str     r2
            mov     rf, hs_len
            ldn     rf
            sm                          ; len - i
            lbz     hs_found

            call    hx_getbyte
            lbdf    hs_notfound
            plo     r9
            mov     rf, hs_cur
            call    hs_bump

            mov     rf, hs_pat
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, hs_i
            ldn     rf
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r8
            adci    0
            phi     r8                  ; R8 = pattern + i
            ldn     r8
            str     r2
            glo     r9
            sm
            lbnz    hs_mismatch

            mov     rf, hs_i
            ldn     rf
            adi     1
            str     rf
            lbr     hs_verify

hs_mismatch:
            mov     rf, hs_cand
            call    hs_bump
            mov     rf, hs_cand
            mov     rd, hs_cur
            call    copy4bytes          ; resume one past the candidate
            mov     rf, hs_cur
            call    src_seek_to
            lbr     hs_scan

hs_found:
            mov     rf, hs_cand
            mov     rd, src_search_top
            call    copy4bytes
            mov     rf, src_search_top
            call    hx_round_down       ; top = the match's row

            mov     rf, src_search_top
            mov     rd, src_search_resume
            call    copy4bytes
            mov     rf, hx_rowlen
            ldn     rf
            plo     r9
            mov     rf, src_search_resume
            glo     r9
            call    addbyte32           ; resume = the next row

            ; ...but never past the end: a seek there would fail and
            ; leave the file wherever it happened to be. At the size the
            ; next search simply finds nothing.
            mov     r7, src_search_resume
            inc     r7
            inc     r7
            inc     r7
            mov     r8, hx_size
            inc     r8
            inc     r8
            inc     r8
            ldn     r7
            str     r2
            ldn     r8
            sm                          ; size - resume, LSB first
            dec     r7
            dec     r8
            ldn     r7
            str     r2
            ldn     r8
            smb
            dec     r7
            dec     r8
            ldn     r7
            str     r2
            ldn     r8
            smb
            dec     r7
            dec     r8
            ldn     r7
            str     r2
            ldn     r8
            smb
            lbdf    hs_resume_ok        ; no borrow: resume <= size
            mov     rf, hx_size
            mov     rd, src_search_resume
            call    copy4bytes
hs_resume_ok:
            clc
            rtn

hs_notfound:
            stc
            rtn

;------------------------------------------------------------------
; hs_bump: the 4-byte value at [RF] += 1.  Modifies: R7, D, DF
;------------------------------------------------------------------
hs_bump:
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7
            ldn     r7
            adi     1
            str     r7
            dec     r7
            ldn     r7
            adci    0
            str     r7
            dec     r7
            ldn     r7
            adci    0
            str     r7
            dec     r7
            ldn     r7
            adci    0
            str     r7
            rtn
            endp

            proc    _src_hex_data
            .link   .align  32          ; the FCB must not straddle a page;
                                        ; ".link .align" only works as the
                                        ; first thing in a proc, with the
                                        ; FCB immediately after it
hx_fcb:                 ds      FCB_LEN
hx_iobuf:               ds      FCB_IOBUF_LEN

; --- shared with the pager (the source contract) ---
src_pos:                ds      4
src_line_buf:           ds      HX_LINE_MAX
src_prev_result:        ds      4
src_goto_result:        ds      4
src_search_top:         ds      4
src_search_resume:      ds      4
src_at_line_start:      db      1       ; every hex row starts a "line" (for -N)
src_row_wrapped:        db      0       ; hex rows never wrap-continue

; --- private ---
hx_size:                ds      4       ; byte count, captured at open
hx_path:                dw      0
hx_stat_buf:            ds      DIRENT_LEN
hx_rowbuf:              ds      HX_ROW_MAX
hx_rowlen:              db      16      ; bytes per row (hx_set_row)
hx_count:               db      0
hx_n:                   db      0
hx_chunk_buf:           ds      HX_CHUNK_LEN
hx_chunk_ptr:           dw      0
hx_chunk_rem:           db      0
hs_pat:                 dw      0
hs_len:                 db      0
hs_i:                   db      0
hs_cand:                ds      4
hs_cur:                 ds      4

                public  hx_fcb
                public  hx_iobuf
                public  src_pos
                public  src_line_buf
                public  src_prev_result
                public  src_goto_result
                public  src_search_top
                public  src_search_resume
                public  src_at_line_start
                public  src_row_wrapped
                public  hx_size
                public  hx_path
                public  hx_stat_buf
                public  hx_rowbuf
                public  hx_rowlen
                public  hx_count
                public  hx_n
                public  hx_chunk_buf
                public  hx_chunk_ptr
                public  hx_chunk_rem
                public  hs_pat
                public  hs_len
                public  hs_i
                public  hs_cand
                public  hs_cur
            endp
