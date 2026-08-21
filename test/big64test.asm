;
; big64test.asm - comprehensive >64K file I/O regression test
;
; Usage: BIG64TEST
;
; Written 2026-07-26 to get to the bottom of a user-reported hardware
; data-corruption bug: a file's cluster chain silently stopped growing
; once its size crossed 65536 bytes via repeated ATEST appends,
; eventually producing "Write error." and corrupting the filesystem
; badly enough to break /bin/shell's own cached lookup. A kernel-side
; print diagnostic was tried first but turned out to have its own bug
; (see kernel/file.asm's git history / CLAUDE.md -- every f_uintout
; call in it was passed the VALUE in R9 but never actually copied it
; into RD, f_uintout's own real argument register, so it printed the
; ADDRESS of the stashed value instead -- explaining why every printed
; line looked identical regardless of the real, growing file position).
; This program replaces that approach entirely: instead of trying to
; catch the bug mid-flight from inside the kernel, it exercises the
; exact failure shape end-to-end and verifies every byte actually
; landed where it should have, so a real corruption shows up as a
; concrete FAIL with a position, not a guess. Run FSCK immediately
; after this program finishes (pass or fail) to independently confirm
; filesystem/cluster-chain integrity -- that combination (this
; program's own byte-level verification, plus a real fsck pass) is
; the standard of evidence needed to trust the >64K file I/O code
; going forward.
;
; Methodology: a single running 32-bit "position" counter (bt_pos)
; drives a simple, fully deterministic, position-derived byte pattern
; (pattern(pos) = the 4 bytes of pos, XORed together) -- so the entire
; expected content of the file at ANY position is always cheaply
; recomputable from that position alone, with no need to hold the
; whole (72000-byte) file in RAM at once. Only a single CHUNK_LEN
; (500-byte) scratch buffer is ever needed, matching this program's
; real constraint (available program RAM is not the bottleneck here --
; keeping the design simple and auditable is). Every K_FILE_READ/
; K_FILE_WRITE moves exactly one chunk; bt_pos is advanced by exactly
; the same amount every time a chunk is produced or consumed, so it
; always describes the absolute position of the very next byte.
;
; Phases, run in this fixed order:
;   A. Create BIG64TST.DAT (mode 1) and write PHASE1_LEN (60000)
;      pattern bytes -- comfortably under the 65536-byte boundary, a
;      clean baseline written in one open/write/close session.
;   B. Re-open read-only and verify all 60000 bytes match the pattern
;      -- confirms the baseline is correct BEFORE the boundary-
;      crossing append in phase C, so a later failure there can be
;      attributed to the crossing itself, not a pre-existing bug.
;   C. Re-open in append mode (mode 2) and write PHASE2_LEN (12000)
;      more pattern bytes, continuing the SAME position sequence from
;      60000. This crosses the 65536-byte boundary partway through
;      (at byte 65536, i.e. chunk 12 of phase C's own 24 chunks) --
;      the exact scenario from the original hardware bug report
;      (repeated ATEST appends crossing 65536 mid-run). Total file
;      size after this phase: 72000 bytes.
;   D. Re-open read-only and verify ALL 72000 bytes from position 0 --
;      this both confirms the newly appended data (60000-71999) is
;      correct AND that the original 60000 bytes are still intact
;      after an append that crossed the boundary.
;   E. With the same read-only handle, run 11 K_FILE_SEEK checks
;      (SEEK_SET/CUR/END, each with at least one case landing within
;      the first 64K and one beyond it, plus 3 error cases) --
;      verified by seeking, then reading a small number of bytes and
;      checking them against the position-derived pattern, NOT by
;      trusting K_FILE_SEEK's own returned position (which is
;      documented to return only the LOW WORD -- ambiguous for any
;      real position >= 65536, so not a meaningful check on its own
;      for this test's own >64K cases).
;   F. Print a final PASS/FAIL summary.
;
; A full-file verify (phases B/D) that hits a short/zero read (fewer
; bytes than requested) is treated as a distinct, immediately-fatal
; condition for that phase -- printed with the exact bt_pos where it
; happened (extremely useful for pinpointing a truncated cluster
; chain) rather than silently continuing with position tracking that
; would no longer match the real file. An ordinary DATA mismatch
; (read succeeded, byte value is wrong) is NOT fatal -- verification
; continues through the whole pass, tallying a total mismatch count
; (32-bit -- up to 72000 possible) plus the position/expected/actual
; of the FIRST mismatch only, matching this project's own established
; "don't flood the console, but don't stop early either" convention
; from progs/xcopy.asm-style test/diagnostic output.
;
; Links against lib/fmt32.asm's fmt_size32 (already proven via DIR/
; STAT) to print the 32-bit positions/counts this test needs -- a
; plain 16-bit f_uintout can't represent a value >= 65536, which most
; of this test's own interesting positions are.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   fmt_size32

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

CHUNK_LEN:          equ     500
SEEK_CHECK_LEN:     equ     8

PHASE1_LEN:         equ     60000       ; phase A: initial write, under
                                        ; the 64K boundary
PHASE1_CHUNKS:      equ     120         ; 60000 / 500

PHASE2_LEN:         equ     12000       ; phase C: append, crosses the
                                        ; 64K boundary partway through
PHASE2_CHUNKS:      equ     24          ; 12000 / 500

TOTAL_LEN:          equ     72000       ; PHASE1_LEN + PHASE2_LEN
TOTAL_CHUNKS:       equ     144         ; 72000 / 500

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rf, bt_fail_count
            ldi     0
            str     rf                  ; bt_fail_count = 0

            call    K_INMSG
            db      "BIG64TEST starting -- this writes/reads/appends/",13,10
            db      "seeks a 72000-byte file. Run FSCK immediately after",13,10
            db      "this completes (pass or fail) to confirm filesystem",13,10
            db      "integrity.",13,10,13,10,0

            ;============================================================
            ; Phase A: create + write PHASE1_LEN (60000) pattern bytes
            ;============================================================
            call    K_INMSG
            db      "Phase A: writing 60000 bytes... ",0

            mov     rf, bt_name
            mov     rd, bt_fcb
            mov     ra, bt_iobuf
            ldi     1                   ; mode 1 = create/overwrite --
                                        ; set LAST: mov clobbers D
            call    K_FILE_OPEN
            lbdf    bt_open_w_err

            call    bt_pos_zero         ; bt_pos = 0

            mov     rf, bt_loop_count
            ldi     PHASE1_CHUNKS
            str     rf

btA_loop:
            mov     rf, bt_loop_count
            ldn     rf
            lbz     btA_done

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    bt_fill_n           ; fills bt_chunk, advances
                                        ; bt_pos by CHUNK_LEN

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_WRITE
            lbdf    bt_write_a_err

            mov     rf, bt_loop_count
            ldn     rf
            smi     1
            str     rf
            lbr     btA_loop

btA_done:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            lbdf    bt_close_a_err

            call    K_INMSG
            db      "done.",13,10,0

            ;============================================================
            ; Phase B: re-open read-only, verify all 60000 bytes
            ;============================================================
            call    K_INMSG
            db      "Phase B: verifying 60000 bytes... ",0

            mov     rf, bt_name
            mov     rd, bt_fcb
            mov     ra, bt_iobuf
            ldi     0                   ; mode 0 = read
            call    K_FILE_OPEN
            lbdf    bt_open_rb_err

            call    bt_pos_zero
            call    bt_mismatch_reset

            mov     rf, bt_loop_count
            ldi     PHASE1_CHUNKS
            str     rf

btB_loop:
            mov     rf, bt_loop_count
            ldn     rf
            lbz     btB_done

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_READ
            lbdf    bt_read_b_err

            ; stash the real transferred count NOW, before anything
            ; else (including K_FILE_CLOSE, on the short-read path
            ; just below) gets a chance to clobber RC -- K_FILE_CLOSE's
            ; own clobber list isn't documented/proven, so RC can't be
            ; trusted to survive it (gotcha #8/#10)
            mov     r8, bt_short_got
            ghi     rc
            str     r8
            inc     r8
            glo     rc
            str     r8

            glo     rc
            str     r2
            ldi     low CHUNK_LEN
            xor
            lbnz    bt_short_b
            ghi     rc
            str     r2
            ldi     high CHUNK_LEN
            xor
            lbnz    bt_short_b

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    bt_verify_n         ; advances bt_pos by CHUNK_LEN

            mov     rf, bt_loop_count
            ldn     rf
            smi     1
            str     rf
            lbr     btB_loop

btB_done:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    bt_report_verify

            ;============================================================
            ; Phase C: re-open append (mode 2), write PHASE2_LEN (12000)
            ; more bytes -- crosses the 65536-byte boundary partway
            ; through.
            ;============================================================
            call    K_INMSG
            db      "Phase C: appending 12000 bytes (crosses the 64K",13,10
            db      "boundary partway through)... ",0

            mov     rf, bt_name
            mov     rd, bt_fcb
            mov     ra, bt_iobuf
            ldi     2                   ; mode 2 = append
            call    K_FILE_OPEN
            lbdf    bt_open_c_err

            ldi     0
            phi     ra
            plo     ra                  ; RA = 0 (position high word)
            ldi     high PHASE1_LEN
            phi     r9
            ldi     low PHASE1_LEN
            plo     r9                  ; R9 = 60000 (position low
                                        ; word -- matches where the
                                        ; append will really begin)
            call    bt_pos_set          ; bt_pos = 60000

            mov     rf, bt_loop_count
            ldi     PHASE2_CHUNKS
            str     rf

btC_loop:
            mov     rf, bt_loop_count
            ldn     rf
            lbz     btC_done

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    bt_fill_n

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_WRITE
            lbdf    bt_write_c_err

            mov     rf, bt_loop_count
            ldn     rf
            smi     1
            str     rf
            lbr     btC_loop

btC_done:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            lbdf    bt_close_c_err

            call    K_INMSG
            db      "done.",13,10,0

            ;============================================================
            ; Phase D: re-open read-only, verify ALL 72000 bytes from
            ; position 0
            ;============================================================
            call    K_INMSG
            db      "Phase D: verifying all 72000 bytes... ",0

            mov     rf, bt_name
            mov     rd, bt_fcb
            mov     ra, bt_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    bt_open_rd_err

            call    bt_pos_zero
            call    bt_mismatch_reset

            mov     rf, bt_loop_count
            ldi     TOTAL_CHUNKS
            str     rf

btD_loop:
            mov     rf, bt_loop_count
            ldn     rf
            lbz     btD_done

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_READ
            lbdf    bt_read_d_err

            ; stash the real transferred count NOW, same reasoning as
            ; phase B's own identical stash above
            mov     r8, bt_short_got
            ghi     rc
            str     r8
            inc     r8
            glo     rc
            str     r8

            glo     rc
            str     r2
            ldi     low CHUNK_LEN
            xor
            lbnz    bt_short_d
            ghi     rc
            str     r2
            ldi     high CHUNK_LEN
            xor
            lbnz    bt_short_d

            mov     rf, bt_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    bt_verify_n

            mov     rf, bt_loop_count
            ldn     rf
            smi     1
            str     rf
            lbr     btD_loop

btD_done:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    bt_report_verify

            ;============================================================
            ; Phase E: seek checks (same read-only handle re-opened
            ; fresh here)
            ;============================================================
            call    K_INMSG
            db      "Phase E: seek checks...",13,10,0

            mov     rf, bt_name
            mov     rd, bt_fcb
            mov     ra, bt_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    bt_open_e_err

            call    bt_check_s1
            call    bt_check_s2
            call    bt_check_s3
            call    bt_check_s4
            call    bt_check_s5
            call    bt_check_s6
            call    bt_check_s7
            call    bt_check_s8
            call    bt_check_s9
            call    bt_check_s10
            call    bt_check_s11

            mov     rd, bt_fcb
            call    K_FILE_CLOSE

            ;============================================================
            ; Phase F: summary
            ;============================================================
            call    K_INMSG
            db      13,10,0

            mov     rf, bt_fail_count
            ldn     rf
            lbz     bt_all_pass

            call    K_INMSG
            db      "BIG64TEST: SOME CHECKS FAILED. Run FSCK now.",13,10,0
            ldi     1
            rtn

bt_all_pass:
            call    K_INMSG
            db      "BIG64TEST: all checks passed. Run FSCK now to",13,10
            db      "confirm filesystem integrity.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; Fatal setup-error labels -- reached via lbdf directly from start's
; own top-level flow (never from inside a nested call frame), so a
; bare rtn here correctly ends the whole program, matching every
; other test/*.asm program's own established convention (see
; atest.asm/seektest.asm).
;------------------------------------------------------------------
bt_open_w_err:
            call    K_INMSG
            db      "FAILED: could not create test file (phase A).",13,10,0
            ldi     1
            rtn

bt_write_a_err:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: write error (phase A).",13,10,0
            ldi     1
            rtn

bt_close_a_err:
            call    K_INMSG
            db      "FAILED: close error (phase A).",13,10,0
            ldi     1
            rtn

bt_open_rb_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file (phase B).",13,10,0
            ldi     1
            rtn

bt_read_b_err:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read I/O error (phase B).",13,10,0
            ldi     1
            rtn

bt_short_b:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    bt_print_short_read
            call    K_INMSG
            db      " (phase B).",13,10,0
            ldi     1
            rtn

bt_open_c_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file for append",13,10
            db      "(phase C).",13,10,0
            ldi     1
            rtn

bt_write_c_err:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: write error (phase C, crossing the 64K",13,10
            db      "boundary).",13,10,0
            ldi     1
            rtn

bt_close_c_err:
            call    K_INMSG
            db      "FAILED: close error (phase C).",13,10,0
            ldi     1
            rtn

bt_open_rd_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file (phase D).",13,10,0
            ldi     1
            rtn

bt_read_d_err:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read I/O error (phase D).",13,10,0
            ldi     1
            rtn

bt_short_d:
            mov     rd, bt_fcb
            call    K_FILE_CLOSE
            call    bt_print_short_read
            call    K_INMSG
            db      " (phase D).",13,10,0
            ldi     1
            rtn

bt_open_e_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file (phase E).",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; bt_print_short_read: prints "FAILED: short/zero read at position "
; followed by the current bt_pos (decimal) -- shared by phases B/D's
; short-read fatal paths.
; Args:    none (reads bt_pos and bt_short_got -- the latter already
;          stashed by btB_loop/btD_loop themselves, immediately after
;          the K_FILE_READ call that detected the shortfall and BEFORE
;          the K_FILE_CLOSE call that runs ahead of this routine on
;          both call sites -- K_FILE_CLOSE's own clobber list isn't
;          documented/proven, so RC can't be trusted to still hold the
;          real transferred count by the time this routine runs;
;          gotcha #8/#10)
; Returns: nothing
; Modifies: everything (calls fmt_size32); caller is about to end the
;          whole program anyway, so nothing needs to survive this.
;------------------------------------------------------------------
bt_print_short_read:
            call    K_INMSG
            db      "FAILED: short/zero read at position ",0

            mov     rf, bt_pos
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, bt_numbuf
            call    fmt_size32
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      " (got ",0

            mov     rf, bt_short_got
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, bt_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      " bytes, expected 500)",0
            rtn

;------------------------------------------------------------------
; bt_pos_zero: bt_pos (4-byte big-endian) = 0.
; Modifies: R8, D
;------------------------------------------------------------------
bt_pos_zero:
            mov     r8, bt_pos
            ldi     0
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            rtn

;------------------------------------------------------------------
; bt_pos_set: bt_pos (4-byte big-endian) = RA:R9 (RA = high word, R9 =
; low word). RA/R9 are read via GHI/GLO only, so they survive this
; call unchanged.
; Args:    RA = position high word, R9 = position low word
; Modifies: R8, D
;------------------------------------------------------------------
bt_pos_set:
            mov     r8, bt_pos
            ghi     ra
            str     r8
            inc     r8
            glo     ra
            str     r8
            inc     r8
            ghi     r9
            str     r8
            inc     r8
            glo     r9
            str     r8
            rtn

;------------------------------------------------------------------
; bt_pattern_byte: D = the 4 bytes of bt_pos, XORed together. Does not
; modify bt_pos. A pure leaf (no calls), so a caller can safely hold
; anything except R8/D live across it.
; Args:    none (reads bt_pos)
; Returns: D = pattern byte
; Modifies: R8, D
;------------------------------------------------------------------
bt_pattern_byte:
            mov     r8, bt_pos
            lda     r8
            str     r2
            lda     r8
            xor
            str     r2
            lda     r8
            xor
            str     r2
            ldn     r8
            xor
            rtn

;------------------------------------------------------------------
; bt_pos_inc: bt_pos (4-byte big-endian) += 1, ripple carry from the
; LSB (byte 3) upward.
; Modifies: R8, D
;------------------------------------------------------------------
bt_pos_inc:
            mov     r8, bt_pos
            add16   r8, 3               ; R8 -> &bt_pos[3] (LSB)
            ldn     r8
            adi     1
            str     r8
            lbnf    bpi_done
            dec     r8                  ; -> &bt_pos[2]
            ldn     r8
            adi     1
            str     r8
            lbnf    bpi_done
            dec     r8                  ; -> &bt_pos[1]
            ldn     r8
            adi     1
            str     r8
            lbnf    bpi_done
            dec     r8                  ; -> &bt_pos[0]
            ldn     r8
            adi     1
            str     r8
bpi_done:
            rtn

;------------------------------------------------------------------
; bt_fill_n: fill RC bytes at *RF with the pattern derived from bt_pos
; (advancing bt_pos by RC as it goes).
; Args:    RF = destination buffer, RC = count (16-bit)
; Modifies: RF (advances by RC), RC (counts down to 0), R8, D
;------------------------------------------------------------------
bt_fill_n:
bfn_loop:
            glo     rc
            lbnz    bfn_have
            ghi     rc
            lbnz    bfn_have
            lbr     bfn_done
bfn_have:
            call    bt_pattern_byte     ; D = pattern byte; only
                                        ; touches R8/D -- RF/RC survive
            str     rf
            inc     rf
            call    bt_pos_inc          ; only touches R8/D -- RF/RC
                                        ; survive
            sub16   rc, 1
            lbr     bfn_loop
bfn_done:
            rtn

;------------------------------------------------------------------
; bt_verify_n: compare RC bytes at *RF (already read from disk)
; against the pattern derived from bt_pos (advancing bt_pos by RC),
; tallying mismatches via bt_record_mismatch.
; Args:    RF = buffer to check, RC = count (16-bit)
; Modifies: RF (advances by RC), RC (counts down to 0), R8, RB, D
;------------------------------------------------------------------
bt_verify_n:
bvn_loop:
            glo     rc
            lbnz    bvn_have
            ghi     rc
            lbnz    bvn_have
            lbr     bvn_done
bvn_have:
            call    bt_pattern_byte     ; D = expected byte
            str     r2                  ; stage expected
            ldn     rf                  ; D = actual byte (RF not
                                        ; advanced by ldn)
            xor                         ; D = expected XOR actual
            lbz     bvn_match
            call    bt_record_mismatch  ; RF/RC untouched by this call
bvn_match:
            inc     rf
            call    bt_pos_inc
            sub16   rc, 1
            lbr     bvn_loop
bvn_done:
            rtn

;------------------------------------------------------------------
; bt_mismatch_reset: bt_mismatch_count (4 bytes) = 0, bt_mismatch_found
; = 0. Called once at the start of each full verify pass (phases
; B/D).
; Modifies: R8, D
;------------------------------------------------------------------
bt_mismatch_reset:
            mov     r8, bt_mismatch_count
            ldi     0
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            mov     r8, bt_mismatch_found
            ldi     0
            str     r8
            rtn

;------------------------------------------------------------------
; bt_record_mismatch: called by bt_verify_n when the byte at *RF
; doesn't match the expected pattern for the CURRENT bt_pos (not yet
; advanced for this byte). Always increments bt_mismatch_count
; (32-bit, ripple carry). Records position/expected/actual details
; ONLY for the first mismatch of this pass (gated by
; bt_mismatch_found) -- later mismatches are still counted but not
; individually recorded, so a badly corrupted region doesn't flood
; the console, just contributes to the total.
; Args:    RF = pointer to the actual (mismatching) byte, NOT advanced
;          by this call; bt_pos = that byte's own absolute position,
;          also not yet advanced.
; Returns: nothing
; Modifies: R8, RB, D. RF/RC untouched (caller needs them to survive).
;------------------------------------------------------------------
bt_record_mismatch:
            mov     r8, bt_mismatch_count
            add16   r8, 3               ; -> &bt_mismatch_count[3] (LSB)
            ldn     r8
            adi     1
            str     r8
            lbnf    brm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbnf    brm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbnf    brm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
brm_count_done:

            mov     r8, bt_mismatch_found
            ldn     r8
            lbnz    brm_rtn             ; already recorded the first
                                        ; one this pass -- just count

            ldi     1
            str     r8                  ; bt_mismatch_found = 1 (R8
                                        ; still points here -- ldn
                                        ; doesn't advance)

            mov     rb, bt_first_bad_pos
            mov     r8, bt_pos
            lda     r8
            str     rb
            inc     rb
            lda     r8
            str     rb
            inc     rb
            lda     r8
            str     rb
            inc     rb
            ldn     r8
            str     rb                  ; bt_first_bad_pos = bt_pos

            ; expected byte -- dest pointer set up in RB BEFORE the
            ; call, since bt_pattern_byte's own scratch is R8 (would
            ; clobber a dest pointer held there), and RB survives it
            ; untouched (gotcha #4 ordering: the mov must precede the
            ; value-producing call, never follow it)
            mov     rb, bt_first_bad_expected
            call    bt_pattern_byte     ; D = expected byte; bt_pos
                                        ; itself is unmodified by this
                                        ; call
            str     rb

            ; actual byte -- same ordering: dest pointer via mov
            ; FIRST, then the value-producing ldn, then str
            ; immediately, no mov in between
            mov     rb, bt_first_bad_actual
            ldn     rf
            str     rb

brm_rtn:
            rtn

;------------------------------------------------------------------
; bt_report_verify: prints "PASS" if bt_mismatch_found is still 0, or
; a detailed FAIL line (mismatch count, first bad position, expected/
; actual byte values) otherwise; increments bt_fail_count on failure.
; Args:    none (reads bt_mismatch_found/bt_mismatch_count/
;          bt_first_bad_pos/bt_first_bad_expected/bt_first_bad_actual)
; Returns: nothing
; Modifies: everything (calls fmt_size32/f_uintout)
;------------------------------------------------------------------
bt_report_verify:
            mov     r8, bt_mismatch_found
            ldn     r8
            lbz     brv_pass

            call    K_INMSG
            db      "FAIL: ",0

            mov     rf, bt_mismatch_count
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, bt_numbuf
            call    fmt_size32
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      " mismatch(es), first at position ",0

            mov     rf, bt_first_bad_pos
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, bt_numbuf
            call    fmt_size32
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      ", expected ",0

            mov     rf, bt_first_bad_expected
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, bt_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      " actual ",0

            mov     rf, bt_first_bad_actual
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, bt_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, bt_numbuf
            call    K_MSG

            call    K_INMSG
            db      ".",13,10,0

            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

brv_pass:
            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; bt_seek_verify_tail: bt_pos must already have been set (via
; bt_pos_set) to the position the file is now positioned at, following
; a just-succeeded K_FILE_SEEK on bt_fcb. Reads SEEK_CHECK_LEN bytes
; and verifies them against the pattern; prints PASS/FAIL via
; bt_report_verify.
; Args:    none (uses bt_fcb, bt_pos)
; Returns: nothing
; Modifies: everything
;------------------------------------------------------------------
bt_seek_verify_tail:
            mov     rf, bt_chunk
            ldi     0
            phi     rc
            ldi     SEEK_CHECK_LEN
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_READ
            lbdf    bsvt_readerr

            glo     rc
            str     r2
            ldi     SEEK_CHECK_LEN
            xor
            lbnz    bsvt_short
            ghi     rc
            lbnz    bsvt_short

            call    bt_mismatch_reset
            mov     rf, bt_chunk
            ldi     0
            phi     rc
            ldi     SEEK_CHECK_LEN
            plo     rc
            call    bt_verify_n
            call    bt_report_verify
            rtn

bsvt_readerr:
            call    K_INMSG
            db      "FAIL (read I/O error)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

bsvt_short:
            call    K_INMSG
            db      "FAIL (short read)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

;------------------------------------------------------------------
; Shared seek-check failure handlers -- reached via lbdf/lbnf from
; WITHIN each bt_check_sN's own call frame (bt_check_sN is itself
; CALLED from start's Phase E block), so the rtn at the end of each of
; these correctly returns to that frame's real caller (start), never
; skipping past it. Matches seektest.asm's own established
; sk_unexpected_fail/sk_unexpected_ok/sk_setup_err pattern.
;------------------------------------------------------------------
bt_check_setup_failed:
            call    K_INMSG
            db      "FAIL (setup seek failed unexpectedly)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

bt_check_seek_failed:
            call    K_INMSG
            db      "FAIL (seek unexpectedly failed)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

bt_check_unexpected_ok:
            call    K_INMSG
            db      "FAIL (seek unexpectedly succeeded)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

;------------------------------------------------------------------
; S1: SEEK_SET(30000) -- within the first 64K
;------------------------------------------------------------------
bt_check_s1:
            call    K_INMSG
            db      "  S1 (SEEK_SET 30000, within 64K): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high $7530
            phi     r9
            ldi     low  $7530
            plo     r9                  ; RA:R9 = 30000
            call    bt_pos_set          ; bt_pos = 30000 (RA/R9
                                        ; survive bt_pos_set)

            ldi     0
            plo     rc                  ; whence = SEEK_SET
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S2: SEEK_SET(70000) -- beyond 64K
;------------------------------------------------------------------
bt_check_s2:
            call    K_INMSG
            db      "  S2 (SEEK_SET 70000, beyond 64K): ",0

            ldi     0
            phi     ra
            ldi     1
            plo     ra
            ldi     high $1170
            phi     r9
            ldi     low  $1170
            plo     r9                  ; RA:R9 = 70000
            call    bt_pos_set

            ldi     0
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S3: SEEK_SET(10000) [setup] then SEEK_CUR(+2000) -> 12000 -- stays
; within the first 64K throughout
;------------------------------------------------------------------
bt_check_s3:
            ldi     0
            phi     ra
            plo     ra
            ldi     high $2710
            phi     r9
            ldi     low  $2710
            plo     r9                  ; RA:R9 = 10000
            ldi     0
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_setup_failed

            call    K_INMSG
            db      "  S3 (SEEK_CUR +2000 from 10000 -> 12000, within",13,10
            db      "  64K): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high $2EE0
            phi     r9
            ldi     low  $2EE0
            plo     r9                  ; RA:R9 = 12000
            call    bt_pos_set          ; bt_pos = 12000 (target)

            ldi     0
            phi     ra
            plo     ra
            ldi     high $07D0
            phi     r9
            ldi     low  $07D0
            plo     r9                  ; RA:R9 = +2000 (offset)
            ldi     1
            plo     rc                  ; whence = SEEK_CUR
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S4: SEEK_SET(65000) [setup] then SEEK_CUR(+2000) -> 67000 -- crosses
; the 64K boundary forward
;------------------------------------------------------------------
bt_check_s4:
            ldi     0
            phi     ra
            plo     ra
            ldi     high $FDE8
            phi     r9
            ldi     low  $FDE8
            plo     r9                  ; RA:R9 = 65000
            ldi     0
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_setup_failed

            call    K_INMSG
            db      "  S4 (SEEK_CUR +2000 from 65000 -> 67000, crosses",13,10
            db      "  64K forward): ",0

            ldi     0
            phi     ra
            ldi     1
            plo     ra
            ldi     high $05B8
            phi     r9
            ldi     low  $05B8
            plo     r9                  ; RA:R9 = 67000
            call    bt_pos_set          ; bt_pos = 67000 (target)

            ldi     0
            phi     ra
            plo     ra
            ldi     high $07D0
            phi     r9
            ldi     low  $07D0
            plo     r9                  ; RA:R9 = +2000 (offset)
            ldi     1
            plo     rc                  ; whence = SEEK_CUR
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S5: SEEK_SET(67000) [setup] then SEEK_CUR(-3000) -> 64000 -- crosses
; the 64K boundary backward
;------------------------------------------------------------------
bt_check_s5:
            ldi     0
            phi     ra
            ldi     1
            plo     ra
            ldi     high $05B8
            phi     r9
            ldi     low  $05B8
            plo     r9                  ; RA:R9 = 67000
            ldi     0
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_setup_failed

            call    K_INMSG
            db      "  S5 (SEEK_CUR -3000 from 67000 -> 64000, crosses",13,10
            db      "  64K backward): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high $FA00
            phi     r9
            ldi     low  $FA00
            plo     r9                  ; RA:R9 = 64000
            call    bt_pos_set          ; bt_pos = 64000 (target)

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $F4
            phi     r9
            ldi     $48
            plo     r9                  ; RA:R9 = -3000 (offset)
            ldi     1
            plo     rc                  ; whence = SEEK_CUR
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S6: SEEK_END(-2000) -> 70000 -- beyond 64K
;------------------------------------------------------------------
bt_check_s6:
            call    K_INMSG
            db      "  S6 (SEEK_END -2000 -> 70000, beyond 64K): ",0

            ldi     0
            phi     ra
            ldi     1
            plo     ra
            ldi     high $1170
            phi     r9
            ldi     low  $1170
            plo     r9                  ; RA:R9 = 70000
            call    bt_pos_set          ; bt_pos = 70000 (target)

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $F8
            phi     r9
            ldi     $30
            plo     r9                  ; RA:R9 = -2000 (offset)
            ldi     2
            plo     rc                  ; whence = SEEK_END
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S7: SEEK_END(-10000) -> 62000 -- within the first 64K
;------------------------------------------------------------------
bt_check_s7:
            call    K_INMSG
            db      "  S7 (SEEK_END -10000 -> 62000, within 64K): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     high $F230
            phi     r9
            ldi     low  $F230
            plo     r9                  ; RA:R9 = 62000
            call    bt_pos_set          ; bt_pos = 62000 (target)

            ldi     $FF
            phi     ra
            ldi     $FF
            plo     ra
            ldi     $D8
            phi     r9
            ldi     $F0
            plo     r9                  ; RA:R9 = -10000 (offset)
            ldi     2
            plo     rc                  ; whence = SEEK_END
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            call    bt_seek_verify_tail
            rtn

;------------------------------------------------------------------
; S8: SEEK_END(0) -> exactly EOF (72000) -- a subsequent read must
; return 0 bytes
;------------------------------------------------------------------
bt_check_s8:
            call    K_INMSG
            db      "  S8 (SEEK_END 0, exactly EOF): ",0

            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9                  ; RA:R9 = 0
            ldi     2
            plo     rc                  ; whence = SEEK_END
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_seek_failed

            mov     rf, bt_chunk
            ldi     0
            phi     rc
            ldi     1
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_READ
            lbdf    bs8_ioerr

            glo     rc
            lbnz    bs8_wrongcount
            ghi     rc
            lbnz    bs8_wrongcount

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

bs8_ioerr:
            call    K_INMSG
            db      "FAIL (read I/O error at EOF)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

bs8_wrongcount:
            call    K_INMSG
            db      "FAIL (expected 0 bytes at EOF)",13,10,0
            mov     rf, bt_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

;------------------------------------------------------------------
; S9: SEEK_SET(80000) -- past EOF, expect error
;------------------------------------------------------------------
bt_check_s9:
            call    K_INMSG
            db      "  S9 (SEEK_SET 80000, past EOF -> expect error): ",0

            ldi     0
            phi     ra
            ldi     1
            plo     ra
            ldi     high $3880
            phi     r9
            ldi     low  $3880
            plo     r9                  ; RA:R9 = 80000 (offset)
            ldi     0
            plo     rc                  ; whence = SEEK_SET
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbnf    bt_check_unexpected_ok

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; S10: SEEK_END(-80000) -- would go negative, expect error
;------------------------------------------------------------------
bt_check_s10:
            call    K_INMSG
            db      "  S10 (SEEK_END -80000 -> negative -> expect",13,10
            db      "  error): ",0

            ldi     $FF
            phi     ra
            ldi     $FE
            plo     ra
            ldi     $C7
            phi     r9
            ldi     $80
            plo     r9                  ; RA:R9 = -80000 (offset)
            ldi     2
            plo     rc                  ; whence = SEEK_END
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbnf    bt_check_unexpected_ok

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; S11: SEEK_SET(50000) [setup] then SEEK_CUR(-60000) -- would go
; negative, expect error
;------------------------------------------------------------------
bt_check_s11:
            ldi     0
            phi     ra
            plo     ra
            ldi     high $C350
            phi     r9
            ldi     low  $C350
            plo     r9                  ; RA:R9 = 50000
            ldi     0
            plo     rc
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbdf    bt_check_setup_failed

            call    K_INMSG
            db      "  S11 (SEEK_CUR -60000 from 50000 -> negative ->",13,10
            db      "  expect error): ",0

            ldi     $FF
            phi     ra
            plo     ra
            ldi     $15
            phi     r9
            ldi     $A0
            plo     r9                  ; RA:R9 = -60000 (offset)
            ldi     1
            plo     rc                  ; whence = SEEK_CUR
            mov     rd, bt_fcb
            call    K_FILE_SEEK
            lbnf    bt_check_unexpected_ok

            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
bt_fail_count:          db      0
bt_loop_count:          db      0
bt_name:                db      "BIG64TST.DAT",0
bt_fcb:                 ds      FCB_LEN
bt_iobuf:               ds      FCB_IOBUF_LEN
bt_pos:                 ds      4
bt_chunk:               ds      CHUNK_LEN
bt_mismatch_count:      ds      4
bt_mismatch_found:      db      0
bt_first_bad_pos:       ds      4
bt_first_bad_expected:  db      0
bt_first_bad_actual:    db      0
bt_short_got:           ds      2
bt_numbuf:              ds      14

            end     start
