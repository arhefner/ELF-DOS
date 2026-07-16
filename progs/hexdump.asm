;
; hexdump.asm - dump a file's contents in hex and ASCII
;
; Usage: HEXDUMP <filename>
;
; Output format modeled on Linux's `hexdump -C`: one row per 16 bytes,
; an 8-digit hex offset, the 16 bytes in hex (two groups of 8, with an
; extra gap between them), then the same bytes as ASCII (printable
; bytes as themselves, everything else as '.'), framed in '|...|'. A
; short final row shows only the real bytes it has -- missing hex
; positions are blank-padded so the '|' column still lines up, but the
; ASCII field itself is never padded.
;
; File offsets on this system top out at 16 bits (see kernel/file.asm's
; own FCB_FPOS/FCB_FSIZE comment), so the offset's high 4 hex digits
; are always "0000" -- printed anyway, to match hexdump -C's layout.
;
; The hex conversion (hex_nibble/hex_byte below) is hand-rolled rather
; than using the BIOS's own f_hexout2 -- that routine has never been
; used anywhere in this codebase (confirmed via grep), so its exact
; register contract isn't verified on this hardware, and getting a hex
; dump's own hex digits subtly wrong would defeat the entire point of
; the tool. Plain shift/mask arithmetic needs no such trust.
;
; The row byte count and column index are both kept in memory, not
; registers, across every K_INMSG/K_MSG/K_TYPE/K_FILE_READ call in the
; row-printing loops below -- this project has only confirmed R9's
; survival across f_msg/f_inmsg (CLAUDE.md gotcha #8), nothing for
; K_TYPE, so nothing here relies on any register surviving a call
; whose clobber list isn't already proven (RF/RC across K_TYPE is the
; one exception, proven by progs/type.asm's own hot loop).
;

#include    include/opcodes.def
#include    include/kernel_api.inc

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
            mov     rd, hd_fcb          ; RD = our FCB struct
            mov     ra, hd_iobuf        ; RA = our I/O buffer
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    not_found

            plo     rd                  ; stash handle (mov below
                                        ; clobbers D)
            mov     rf, hd_handle
            glo     rd
            str     rf                  ; hd_handle = handle

            mov     rf, hd_offset
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; hd_offset = 0

row_loop:
            mov     rf, hd_rowbuf
            ldi     16
            plo     rc
            ldi     0
            phi     rc                  ; RC = 16 (bytes requested)
            mov     rd, hd_handle
            ldn     rd                  ; D = handle, RF untouched
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    io_error

            mov     rf, hd_row_count
            glo     rc
            str     rf                  ; hd_row_count = bytes read
                                        ; (0-16)
            lbz     done                ; 0 bytes: EOF

            ; --- print the 8-digit offset ---
            call    K_INMSG
            db      "0000",0
            mov     rf, hd_digits
            mov     rd, hd_offset
            lda     rd                  ; D = offset high byte
            call    hex_byte
            ldn     rd                  ; D = offset low byte
            call    hex_byte
            ldi     0
            str     rf                  ; null-terminate hd_digits
            mov     rf, hd_digits
            call    K_MSG

            call    K_INMSG
            db      "  ",0

            ; --- hex byte columns ---
            mov     rf, hd_col
            ldi     0
            str     rf                  ; hd_col = 0
hex_col:
            mov     rf, hd_col
            ldn     rf
            xri     8
            lbnz    hc_no_gap
            call    K_INMSG
            db      " ",0
hc_no_gap:
            mov     rf, hd_row_count
            ldn     rf                  ; D = row_count
            str     r2                  ; M(X) = row_count
            mov     rf, hd_col
            ldn     rf                  ; D = col (fresh read)
            sm                          ; D = col - row_count
            lbnf    hc_have_byte        ; DF=0 (borrow): col < row_count

            call    K_INMSG
            db      "   ",0
            lbr     hc_next

hc_have_byte:
            ldi     0
            phi     r8
            mov     rf, hd_col
            ldn     rf
            plo     r8                  ; R8 = col, zero-extended --
                                        ; used only for this one add16,
                                        ; never trusted across a call
            mov     rf, hd_rowbuf
            add16   rf, r8
            ldn     rf                  ; D = the byte at this column
            plo     rc                  ; stash it (mov below clobbers
                                        ; D -- gotcha #4; this exact
                                        ; ordering mistake was the
                                        ; original bug here, every byte
                                        ; printed as hd_digits' own
                                        ; address low byte instead of
                                        ; the real data)
            mov     rf, hd_digits
            glo     rc                  ; D = the byte (reloaded,
                                        ; correct)
            call    hex_byte
            ldi     0
            str     rf
            mov     rf, hd_digits
            call    K_MSG
            call    K_INMSG
            db      " ",0

hc_next:
            mov     rf, hd_col
            ldn     rf
            adi     1
            str     rf
            smi     16
            lbnz    hex_col

            ; --- ascii column ---
            call    K_INMSG
            db      " |",0

            mov     rf, hd_col
            ldi     0
            str     rf                  ; hd_col = 0 (reused)
ascii_col:
            mov     rf, hd_row_count
            ldn     rf
            str     r2                  ; M(X) = row_count
            mov     rf, hd_col
            ldn     rf
            sm                          ; D = col - row_count
            lbdf    ascii_done          ; DF=1 (no borrow): col >= row_count

            ldi     0
            phi     r8
            mov     rf, hd_col
            ldn     rf
            plo     r8                  ; R8 = col, zero-extended
            mov     rf, hd_rowbuf
            add16   rf, r8
            ldn     rf                  ; D = the byte at this column

            ; printable range $20-$7E; anything else prints as '.'
            plo     rc                  ; stash it (very short-lived,
                                        ; not across a call -- just to
                                        ; survive the mov two lines
                                        ; below, gotcha #4)
            glo     rc
            smi     $20
            lbnf    ascii_dot
            glo     rc
            smi     $7F
            lbdf    ascii_dot

            glo     rc
            call    K_TYPE
            lbr     ascii_next

ascii_dot:
            ldi     '.'
            call    K_TYPE

ascii_next:
            mov     rf, hd_col
            ldn     rf
            adi     1
            str     rf
            lbr     ascii_col

ascii_done:
            call    K_INMSG
            db      "|",13,10,0

            ; --- advance the offset by the row's real byte count ---
            mov     rf, hd_offset
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = hd_offset
            mov     rf, hd_row_count
            ldn     rf
            str     r2
            glo     rd
            add
            plo     rd
            ghi     rd
            adci    0
            phi     rd
            mov     rf, hd_offset
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; a short row (< 16 bytes) is always the last one
            mov     rf, hd_row_count
            ldn     rf
            smi     16
            lbnz    done

            lbr     row_loop

done:
            mov     rf, hd_handle
            ldn     rf
            call    K_FILE_CLOSE
            ldi     0                   ; exit code 0 = success
            rtn

io_error:
            mov     rf, hd_handle
            ldn     rf
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: HEXDUMP <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

;------------------------------------------------------------------
; hex_nibble: convert a 4-bit value (0-15) in D to its lowercase ASCII
; hex digit.
; Args:    D = nibble (0-15)
; Returns: D = ASCII character ('0'-'9' or 'a'-'f')
; Modifies: D only
;------------------------------------------------------------------
hex_nibble:
            smi     10
            lbnf    hn_digit            ; DF=0 (borrow): nibble < 10
            adi     'a'                 ; nibble >= 10: D = 'a' +
                                        ; (nibble-10)
            rtn
hn_digit:
            adi     10 + '0'            ; D = (nibble-10) + 10 + '0'
                                        ; = nibble + '0'
            rtn

;------------------------------------------------------------------
; hex_byte: write 2 lowercase ASCII hex digits for a byte to *RF,
; advancing RF by 2. Does not null-terminate.
; Args:    D = byte value, RF = destination
; Returns: RF advanced by 2
; Modifies: D, RC (used as local scratch across the two hex_nibble
;           calls -- never live across this call at either of its two
;           call sites above)
;------------------------------------------------------------------
hex_byte:
            plo     rc                  ; RC.0 = byte value (stash
                                        ; across the two hex_nibble
                                        ; calls below)
            glo     rc
            shr
            shr
            shr
            shr                         ; D = high nibble (SHR always
                                        ; zero-fills the top bit, so
                                        ; four of them give a clean
                                        ; >>4 with no DF dependency)
            call    hex_nibble
            str     rf
            inc     rf

            glo     rc
            ani     $0F                 ; D = low nibble
            call    hex_nibble
            str     rf
            inc     rf
            rtn

hd_fcb:         ds      FCB_LEN
hd_iobuf:       ds      FCB_IOBUF_LEN
hd_handle:      db      0
hd_rowbuf:      ds      16
hd_offset:      dw      0
hd_row_count:   db      0
hd_col:         db      0
hd_digits:      ds      3           ; scratch for hex_byte's 2-digit
                                    ; output + forced NUL

            end     start
