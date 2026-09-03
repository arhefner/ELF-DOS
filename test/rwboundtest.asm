;
; rwboundtest.asm - cluster-boundary K_FILE_READ/K_FILE_WRITE
; regression test (verifies the 2026-09-02 speculative-lookahead
; fixes in kernel/file.asm)
;
; Usage: RWBOUNDTEST
;
; Background: two related kernel bugs were found and fixed the same
; session (see kernel/file.asm's own git history / CLAUDE.md for the
; full investigation). Both had the same shape: file_read's and
; file_write's own internal copy loops, after finishing a chunk that
; happened to land exactly on a sector/cluster boundary, EAGERLY tried
; to resolve/allocate the NEXT cluster in the chain -- even when the
; caller's own request was already fully satisfied (RC==0) and
; nothing more was actually needed. A transient failure in that
; unneeded lookahead then got reported as the WHOLE call's own I/O
; error, discarding an otherwise-fully-successful read or write.
;   - file_read's fix: cluster resolution moved out of the copy loop
;     entirely, into _fcb_sector_lba_and_iobuf, made LAZY -- it now
;     only runs at the one point a sector is actually about to be
;     loaded, which by construction can't happen once a request is
;     already finished.
;   - file_write's fix is narrower: only the plain fat_get chain-
;     follow (no side effects on failure) got the same "suppress on
;     RC==0" treatment; the fat_alloc/fat_set/fat_flush allocate-on-
;     grow chain (real, consequential disk side effects) was
;     deliberately left untouched.
;
; This program can't safely reproduce the ORIGINAL trigger (a genuine
; fat_get I/O failure) without deliberately damaging real disk media,
; which isn't something to do to a card with real data on it. What it
; CAN do, safely and repeatably, is verify the fixed code's actual
; boundary-crossing BEHAVIOR is correct under normal conditions --
; every scenario the fix touches, exercised deliberately rather than
; by chance:
;   - A single K_FILE_WRITE/K_FILE_READ call whose own last (and
;     only) internal chunk lands EXACTLY on a cluster boundary, with
;     nothing more requested -- the literal trigger condition, minus
;     the injected failure.
;   - The read side's LAZY design specifically: does it correctly
;     leave the "still need to resolve" state alone when a request
;     finishes exactly at a boundary, and correctly pick it back up
;     on a LATER, separate K_FILE_READ call on the same still-open
;     FCB? (This is the exact property the fix's own safety depends
;     on -- if it didn't persist correctly, a later read would either
;     silently corrupt data or hang.)
;   - The write side's allocate-on-grow chain, still exercised
;     end-to-end and unaffected by the narrower fix (a real append
;     that needs a brand new cluster).
;
; Chunk size is deliberately CHUNK_LEN=512 (one sector), not an
; arbitrary size -- every single K_FILE_WRITE/K_FILE_READ call this
; program makes requests an exact multiple of 512 bytes, so its own
; LAST internal chunk always lands exactly on a sector boundary, with
; RC reaching 0 on that same iteration. Every 128th chunk (128*512 =
; 65536) additionally lands on a CLUSTER boundary for every real-world
; bpb_spc this project has seen on actual hardware (1, 16, 32, 128 --
; 65536 is an exact multiple of the cluster size for all four), so
; this test's own boundary points work regardless of which spc the
; card under test actually has, with no need to query it.
;
; Phases, run in this fixed order:
;   A. Create RWBOUND.DAT (mode 1) and write 3 full "cluster-sized"
;      spans (384 chunks / 196608 bytes total) in one continuous
;      write loop, closing once at the end. The file starts empty, so
;      this exercises file_write's real allocate-on-grow chain twice
;      internally (at 65536 and 131072) PLUS the exact trigger
;      condition once more at the very end (196608, the file's own
;      true EOF, where NOTHING more needs allocating).
;   B. Re-open read-only. Read the file back as 3 SEPARATE 65536-byte
;      K_FILE_READ calls (128 chunks each) on the SAME open FCB, not
;      one big read -- this is the read side's own key property test.
;      Call 1 finishes exactly at the first cluster boundary; if the
;      fix's laziness didn't correctly persist that "unresolved"
;      state, call 2 (which must resolve it before its own first
;      byte) would either read garbage or hang. Call 3 additionally
;      finishes exactly at the file's own true EOF.
;   C. Re-open in append mode (mode 2) and write one more 65536-byte
;      span (128 chunks), extending the file to a 4th cluster-sized
;      span (262144 bytes total). Exercises fopen_check_append's own
;      positioning (which goes through the same now-lazy
;      _fcb_sector_lba_and_iobuf file_read uses) landing exactly on
;      an already-resolved cluster boundary, followed by a REAL
;      allocate-on-grow (the file has no cluster there yet).
;   D. Re-open read-only and verify the WHOLE 262144-byte file, again
;      as 4 separate 65536-byte K_FILE_READ calls on one open FCB --
;      confirms the newly appended span AND that the original 3 are
;      still intact after the append.
;   E. Print a final PASS/FAIL summary.
;
; Methodology (byte verification): a single running 32-bit "position"
; counter (rwb_pos) drives a simple, fully deterministic, position-
; derived byte pattern (pattern(pos) = the 4 bytes of pos, XORed
; together) -- lifted directly from test/big64test.asm's own already
; hardware-proven scheme, so the entire expected content of the file
; at any position is always cheaply recomputable, with no need to
; hold the whole 262144-byte file in RAM. Only a single CHUNK_LEN
; (512-byte) scratch buffer is needed.
;
; A short/zero read is treated as a distinct, immediately-fatal
; condition (printed with the exact rwb_pos where it happened) rather
; than silently continuing with position tracking that would no
; longer match the real file. An ordinary DATA mismatch (read
; succeeded, byte value is wrong) is NOT fatal -- verification
; continues through the whole call, tallying a total mismatch count
; plus the position/expected/actual of the FIRST mismatch only,
; matching big64test's own established convention.
;
; Run FSCK immediately after this program finishes (pass or fail) to
; independently confirm filesystem/cluster-chain integrity, same
; standing practice as big64test.
;
; Links against lib/fmt32.asm's fmt_size32 (already proven via DIR/
; STAT/BIG64TEST) to print the 32-bit positions/counts this test
; needs -- a plain 16-bit f_uintout can't represent 65536 or above.
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

CHUNK_LEN:          equ     512         ; one sector, deliberately --
                                        ; see this file's own header
SPAN_CHUNKS:        equ     128         ; 65536 / 512 -- one "cluster-
                                        ; sized" span, in chunks
SPAN_LEN:           equ     65536

PHASE1_SPANS:       equ     3           ; phase A: 3 spans in one
                                        ; continuous write (196608
                                        ; bytes)
PHASE1_CHUNKS:      equ     384         ; PHASE1_SPANS * SPAN_CHUNKS

PHASE2_SPANS:       equ     1           ; phase C: append 1 more span
                                        ; (65536 bytes)

TOTAL_SPANS:        equ     4           ; PHASE1_SPANS + PHASE2_SPANS
TOTAL_LEN:          equ     262144      ; TOTAL_SPANS * SPAN_LEN

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rf, rwb_fail_count
            ldi     0
            str     rf                  ; rwb_fail_count = 0

            call    K_INMSG
            db      "RWBOUNDTEST starting -- writes/reads/appends a",13,10
            db      "262144-byte file, deliberately landing every 65536",13,10
            db      "bytes to exercise the cluster-boundary fixes. Run",13,10
            db      "FSCK immediately after this completes (pass or",13,10
            db      "fail) to confirm filesystem integrity.",13,10,13,10,0

            ;============================================================
            ; Phase A: create + write 3 spans (384 chunks, 196608
            ; bytes) in one continuous write loop
            ;============================================================
            call    K_INMSG
            db      "Phase A: writing 196608 bytes (3 spans)... ",0

            mov     rf, rwb_name
            mov     rd, rwb_fcb
            mov     ra, rwb_iobuf
            ldi     1                   ; mode 1 = create/overwrite --
                                        ; set LAST: mov clobbers D
            call    K_FILE_OPEN
            lbdf    rwb_open_a_err

            call    rwb_pos_zero        ; rwb_pos = 0

            ldi     high PHASE1_CHUNKS
            phi     rc
            ldi     low PHASE1_CHUNKS
            plo     rc
            call    rwb_write_chunks
            lbdf    rwb_write_a_err

            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            lbdf    rwb_close_a_err

            call    K_INMSG
            db      "done.",13,10,0

            ;============================================================
            ; Phase B: re-open read-only, verify all 3 spans as 3
            ; SEPARATE 65536-byte reads on the same open FCB
            ;============================================================
            call    K_INMSG
            db      "Phase B: verifying 3 spans as 3 separate reads",13,10
            db      "on the same FCB (the read-side fix's own key",13,10
            db      "property)...",13,10,0

            mov     rf, rwb_name
            mov     rd, rwb_fcb
            mov     ra, rwb_iobuf
            ldi     0                   ; mode 0 = read
            call    K_FILE_OPEN
            lbdf    rwb_open_b_err

            call    rwb_pos_zero
            call    rwb_mismatch_reset

            call    K_INMSG
            db      "  span 1 (0-65535, ends exactly on a cluster",13,10
            db      "  boundary): ",0
            ldi     high SPAN_CHUNKS
            phi     rc
            ldi     low SPAN_CHUNKS
            plo     rc
            call    rwb_read_chunks
            lbdf    rwb_read_b1_err

            call    K_INMSG
            db      "  span 2 (65536-131071, must resolve the pending",13,10
            db      "  cluster before its own first byte): ",0
            ldi     high SPAN_CHUNKS
            phi     rc
            ldi     low SPAN_CHUNKS
            plo     rc
            call    rwb_read_chunks
            lbdf    rwb_read_b2_err

            call    K_INMSG
            db      "  span 3 (131072-196607, ends exactly at true",13,10
            db      "  EOF): ",0
            ldi     high SPAN_CHUNKS
            phi     rc
            ldi     low SPAN_CHUNKS
            plo     rc
            call    rwb_read_chunks
            lbdf    rwb_read_b3_err

            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    rwb_report_verify

            ;============================================================
            ; Phase C: re-open append (mode 2), write 1 more span
            ; (128 chunks, 65536 bytes) -- extends to a 4th
            ; cluster-sized span, requiring real allocation
            ;============================================================
            call    K_INMSG
            db      "Phase C: appending 65536 bytes (real allocate-on-",13,10
            db      "grow, positioned via the same lazy resolve as",13,10
            db      "phase B)... ",0

            mov     rf, rwb_name
            mov     rd, rwb_fcb
            mov     ra, rwb_iobuf
            ldi     2                   ; mode 2 = append
            call    K_FILE_OPEN
            lbdf    rwb_open_c_err

            ; RA:R9 = 196608 = 0x00030000 (32-bit), the position the
            ; append will really begin at. BUG-CLASS GUARD: high/low
            ; only extract the high/low BYTE of a 16-bit expression --
            ; they do NOT split a 32-bit value into its high/low WORD.
            ; "high SPAN_LEN*PHASE1_SPANS"/"low SPAN_LEN*PHASE1_SPANS"
            ; would both evaluate the product mod 65536 first (giving
            ; 0, since 196608 is an exact multiple of 65536) and hand
            ; that same truncated 0 to BOTH high and low -- silently
            ; correct for R9 (196608's own low word genuinely is 0)
            ; but wrong for RA (196608's real high word is 3, not 0).
            ; Hand-computed literal hex avoids the ambiguity entirely,
            ; matching test/big64test.asm's own established precedent
            ; for any >64K position constant.
            ldi     0
            phi     ra
            ldi     3
            plo     ra                  ; RA = 0x0003 (position high word)
            ldi     0
            phi     r9
            plo     r9                  ; R9 = 0x0000 (position low word)
            call    rwb_pos_set         ; rwb_pos = 196608

            ldi     high SPAN_CHUNKS
            phi     rc
            ldi     low SPAN_CHUNKS
            plo     rc
            call    rwb_write_chunks
            lbdf    rwb_write_c_err

            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            lbdf    rwb_close_c_err

            call    K_INMSG
            db      "done.",13,10,0

            ;============================================================
            ; Phase D: re-open read-only, verify the whole 262144-byte
            ; file as 4 separate 65536-byte reads on one open FCB
            ;============================================================
            call    K_INMSG
            db      "Phase D: verifying all 4 spans (262144 bytes)...",13,10,0

            mov     rf, rwb_name
            mov     rd, rwb_fcb
            mov     ra, rwb_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    rwb_open_d_err

            call    rwb_pos_zero
            call    rwb_mismatch_reset

            mov     rf, rwb_dspan
            ldi     TOTAL_SPANS
            str     rf

rwbD_loop:
            mov     rf, rwb_dspan
            ldn     rf
            lbz     rwbD_done

            call    K_INMSG
            db      "  span: ",0

            ldi     high SPAN_CHUNKS
            phi     rc
            ldi     low SPAN_CHUNKS
            plo     rc
            call    rwb_read_chunks
            lbdf    rwb_read_d_err

            mov     rf, rwb_dspan
            ldn     rf
            smi     1
            str     rf
            lbr     rwbD_loop

rwbD_done:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    rwb_report_verify

            ;============================================================
            ; Phase E: summary
            ;============================================================
            call    K_INMSG
            db      13,10,0

            mov     rf, rwb_fail_count
            ldn     rf
            lbz     rwb_all_pass

            call    K_INMSG
            db      "RWBOUNDTEST: SOME CHECKS FAILED. Run FSCK now.",13,10,0
            ldi     1
            rtn

rwb_all_pass:
            call    K_INMSG
            db      "RWBOUNDTEST: all checks passed. Run FSCK now to",13,10
            db      "confirm filesystem integrity.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; Fatal setup-error labels -- reached via lbdf directly from start's
; own top-level flow (never from inside a nested call frame), so a
; bare rtn here correctly ends the whole program, matching
; test/big64test.asm's own established convention.
;------------------------------------------------------------------
rwb_open_a_err:
            call    K_INMSG
            db      "FAILED: could not create test file (phase A).",13,10,0
            ldi     1
            rtn

rwb_write_a_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: write error (phase A).",13,10,0
            ldi     1
            rtn

rwb_close_a_err:
            call    K_INMSG
            db      "FAILED: close error (phase A).",13,10,0
            ldi     1
            rtn

rwb_open_b_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file (phase B).",13,10,0
            ldi     1
            rtn

rwb_read_b1_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read error, span 1 (phase B).",13,10,0
            ldi     1
            rtn

rwb_read_b2_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read error, span 2 -- the pending-",13,10
            db      "cluster-resolve case (phase B).",13,10,0
            ldi     1
            rtn

rwb_read_b3_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read error, span 3 (phase B).",13,10,0
            ldi     1
            rtn

rwb_open_c_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file for append",13,10
            db      "(phase C).",13,10,0
            ldi     1
            rtn

rwb_write_c_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: write error, append/allocate-on-grow",13,10
            db      "(phase C).",13,10,0
            ldi     1
            rtn

rwb_close_c_err:
            call    K_INMSG
            db      "FAILED: close error (phase C).",13,10,0
            ldi     1
            rtn

rwb_open_d_err:
            call    K_INMSG
            db      "FAILED: could not re-open test file (phase D).",13,10,0
            ldi     1
            rtn

rwb_read_d_err:
            mov     rd, rwb_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "FAILED: read error (phase D).",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; rwb_write_chunks: write RC chunks of CHUNK_LEN (512) bytes each to
; rwb_fcb, pattern-filled from the current rwb_pos (advancing it as
; it goes). Stops at the first write error.
; Args:    RC = chunk count (16-bit)
; Returns: DF = 0 on success, DF = 1 on the first write error
; Modifies: everything
;------------------------------------------------------------------
rwb_write_chunks:
            mov     rf, rwb_count
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; rwb_count = RC

rwbwc_loop:
            mov     rf, rwb_count
            lda     rf
            lbnz    rwbwc_have
            ldn     rf
            lbz     rwbwc_done
rwbwc_have:
            mov     rf, rwb_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    rwb_fill_n          ; fills rwb_chunk, advances
                                        ; rwb_pos by CHUNK_LEN

            mov     rf, rwb_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, rwb_fcb
            call    K_FILE_WRITE
            lbdf    rwbwc_err

            mov     rf, rwb_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = rwb_count
            sub16   r8, 1
            mov     rf, rwb_count
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; rwb_count -= 1
            lbr     rwbwc_loop

rwbwc_done:
            clc
            rtn
rwbwc_err:
            stc
            rtn

;------------------------------------------------------------------
; rwb_read_chunks: read RC chunks of CHUNK_LEN (512) bytes each from
; rwb_fcb, verifying each one against the pattern derived from the
; current rwb_pos (advancing it, tallying mismatches via
; rwb_record_mismatch). A short/zero read is fatal -- see this file's
; own header. Stops at the first read I/O error or short read.
; Args:    RC = chunk count (16-bit)
; Returns: DF = 0 on success (all chunks read, no short reads -- data
;          mismatches, if any, are tallied but don't set DF), DF = 1
;          on I/O error or short read
; Modifies: everything
;------------------------------------------------------------------
rwb_read_chunks:
            mov     rf, rwb_count
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; rwb_count = RC

rwbrc_loop:
            mov     rf, rwb_count
            lda     rf
            lbnz    rwbrc_have
            ldn     rf
            lbz     rwbrc_done
rwbrc_have:
            mov     rf, rwb_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            mov     rd, rwb_fcb
            call    K_FILE_READ
            lbdf    rwbrc_err

            ; stash the real transferred count NOW, before anything
            ; else gets a chance to clobber RC (gotcha #8/#10, same
            ; reasoning as test/big64test.asm's own identical stash)
            mov     r8, rwb_short_got
            ghi     rc
            str     r8
            inc     r8
            glo     rc
            str     r8

            glo     rc
            str     r2
            ldi     low CHUNK_LEN
            xor
            lbnz    rwbrc_short
            ghi     rc
            str     r2
            ldi     high CHUNK_LEN
            xor
            lbnz    rwbrc_short

            mov     rf, rwb_chunk
            ldi     high CHUNK_LEN
            phi     rc
            ldi     low CHUNK_LEN
            plo     rc
            call    rwb_verify_n        ; advances rwb_pos by CHUNK_LEN

            mov     rf, rwb_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = rwb_count
            sub16   r8, 1
            mov     rf, rwb_count
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; rwb_count -= 1
            lbr     rwbrc_loop

rwbrc_done:
            clc
            rtn

rwbrc_err:
            call    K_INMSG
            db      "FAIL (read I/O error)",13,10,0
            mov     rf, rwb_fail_count
            ldn     rf
            adi     1
            str     rf
            stc
            rtn

rwbrc_short:
            call    rwb_print_short_read
            call    K_INMSG
            db      13,10,0
            mov     rf, rwb_fail_count
            ldn     rf
            adi     1
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; rwb_print_short_read: prints "FAIL (short/zero read at position "
; followed by rwb_pos (decimal) and the byte count actually
; transferred.
; Args:    none (reads rwb_pos and rwb_short_got -- the latter already
;          stashed by rwbrc_loop itself, immediately after the
;          K_FILE_READ call that detected the shortfall)
; Modifies: everything (calls fmt_size32/f_uintout)
;------------------------------------------------------------------
rwb_print_short_read:
            call    K_INMSG
            db      "FAIL (short/zero read at position ",0

            mov     rf, rwb_pos
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, rwb_numbuf
            call    fmt_size32
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      ", got ",0

            mov     rf, rwb_short_got
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rwb_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      " bytes, expected 512)",0
            rtn

;------------------------------------------------------------------
; rwb_pos_zero: rwb_pos (4-byte big-endian) = 0.
; Modifies: R8, D
;------------------------------------------------------------------
rwb_pos_zero:
            mov     r8, rwb_pos
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
; rwb_pos_set: rwb_pos (4-byte big-endian) = RA:R9 (RA = high word,
; R9 = low word). RA/R9 are read via GHI/GLO only, so they survive
; this call unchanged.
; Args:    RA = position high word, R9 = position low word
; Modifies: R8, D
;------------------------------------------------------------------
rwb_pos_set:
            mov     r8, rwb_pos
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
; rwb_pattern_byte: D = the 4 bytes of rwb_pos, XORed together. Does
; not modify rwb_pos. A pure leaf (no calls).
; Args:    none (reads rwb_pos)
; Returns: D = pattern byte
; Modifies: R8, D
;------------------------------------------------------------------
rwb_pattern_byte:
            mov     r8, rwb_pos
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
; rwb_pos_inc: rwb_pos (4-byte big-endian) += 1, ripple carry from the
; LSB (byte 3) upward.
; Modifies: R8, D
;------------------------------------------------------------------
rwb_pos_inc:
            mov     r8, rwb_pos
            add16   r8, 3               ; R8 -> &rwb_pos[3] (LSB)
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbpi_done
            dec     r8                  ; -> &rwb_pos[2]
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbpi_done
            dec     r8                  ; -> &rwb_pos[1]
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbpi_done
            dec     r8                  ; -> &rwb_pos[0]
            ldn     r8
            adi     1
            str     r8
rwbpi_done:
            rtn

;------------------------------------------------------------------
; rwb_fill_n: fill RC bytes at *RF with the pattern derived from
; rwb_pos (advancing rwb_pos by RC as it goes).
; Args:    RF = destination buffer, RC = count (16-bit)
; Modifies: RF (advances by RC), RC (counts down to 0), R8, D
;------------------------------------------------------------------
rwb_fill_n:
rwbfn_loop:
            glo     rc
            lbnz    rwbfn_have
            ghi     rc
            lbnz    rwbfn_have
            lbr     rwbfn_done
rwbfn_have:
            call    rwb_pattern_byte    ; D = pattern byte; only
                                        ; touches R8/D -- RF/RC survive
            str     rf
            inc     rf
            call    rwb_pos_inc         ; only touches R8/D -- RF/RC
                                        ; survive
            sub16   rc, 1
            lbr     rwbfn_loop
rwbfn_done:
            rtn

;------------------------------------------------------------------
; rwb_verify_n: compare RC bytes at *RF (already read from disk)
; against the pattern derived from rwb_pos (advancing rwb_pos by RC),
; tallying mismatches via rwb_record_mismatch.
; Args:    RF = buffer to check, RC = count (16-bit)
; Modifies: RF (advances by RC), RC (counts down to 0), R8, RB, D
;------------------------------------------------------------------
rwb_verify_n:
rwbvn_loop:
            glo     rc
            lbnz    rwbvn_have
            ghi     rc
            lbnz    rwbvn_have
            lbr     rwbvn_done
rwbvn_have:
            call    rwb_pattern_byte    ; D = expected byte
            str     r2                  ; stage expected
            ldn     rf                  ; D = actual byte (RF not
                                        ; advanced by ldn)
            xor                         ; D = expected XOR actual
            lbz     rwbvn_match
            call    rwb_record_mismatch ; RF/RC untouched by this call
rwbvn_match:
            inc     rf
            call    rwb_pos_inc
            sub16   rc, 1
            lbr     rwbvn_loop
rwbvn_done:
            rtn

;------------------------------------------------------------------
; rwb_mismatch_reset: rwb_mismatch_count (4 bytes) = 0,
; rwb_mismatch_found = 0. Called once before each fresh verify pass.
; Modifies: R8, D
;------------------------------------------------------------------
rwb_mismatch_reset:
            mov     r8, rwb_mismatch_count
            ldi     0
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            inc     r8
            str     r8
            mov     r8, rwb_mismatch_found
            ldi     0
            str     r8
            rtn

;------------------------------------------------------------------
; rwb_record_mismatch: called by rwb_verify_n when the byte at *RF
; doesn't match the expected pattern for the CURRENT rwb_pos (not yet
; advanced for this byte). Always increments rwb_mismatch_count
; (32-bit, ripple carry). Records position/expected/actual details
; ONLY for the first mismatch of this pass (gated by
; rwb_mismatch_found) -- later mismatches are still counted but not
; individually recorded.
; Args:    RF = pointer to the actual (mismatching) byte, NOT advanced
;          by this call; rwb_pos = that byte's own absolute position,
;          also not yet advanced.
; Returns: nothing
; Modifies: R8, RB, D. RF/RC untouched (caller needs them to survive).
;------------------------------------------------------------------
rwb_record_mismatch:
            mov     r8, rwb_mismatch_count
            add16   r8, 3               ; -> &rwb_mismatch_count[3]
                                        ; (LSB)
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbrm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbrm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbnf    rwbrm_count_done
            dec     r8
            ldn     r8
            adi     1
            str     r8
rwbrm_count_done:

            mov     r8, rwb_mismatch_found
            ldn     r8
            lbnz    rwbrm_rtn           ; already recorded the first
                                        ; one this pass -- just count

            ldi     1
            str     r8                  ; rwb_mismatch_found = 1 (R8
                                        ; still points here -- ldn
                                        ; doesn't advance)

            mov     rb, rwb_first_bad_pos
            mov     r8, rwb_pos
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
            str     rb                  ; rwb_first_bad_pos = rwb_pos

            ; expected byte -- dest pointer set up in RB BEFORE the
            ; call, since rwb_pattern_byte's own scratch is R8 (would
            ; clobber a dest pointer held there), and RB survives it
            ; untouched (gotcha #4 ordering: the mov must precede the
            ; value-producing call, never follow it)
            mov     rb, rwb_first_bad_expected
            call    rwb_pattern_byte    ; D = expected byte; rwb_pos
                                        ; itself is unmodified by this
                                        ; call
            str     rb

            ; actual byte -- same ordering: dest pointer via mov
            ; FIRST, then the value-producing ldn, then str
            ; immediately, no mov in between
            mov     rb, rwb_first_bad_actual
            ldn     rf
            str     rb

rwbrm_rtn:
            rtn

;------------------------------------------------------------------
; rwb_report_verify: prints "PASS" if rwb_mismatch_found is still 0,
; or a detailed FAIL line (mismatch count, first bad position,
; expected/actual byte values) otherwise; increments rwb_fail_count
; on failure.
; Args:    none (reads rwb_mismatch_found/rwb_mismatch_count/
;          rwb_first_bad_pos/rwb_first_bad_expected/
;          rwb_first_bad_actual)
; Returns: nothing
; Modifies: everything (calls fmt_size32/f_uintout)
;------------------------------------------------------------------
rwb_report_verify:
            mov     r8, rwb_mismatch_found
            ldn     r8
            lbz     rwbrv_pass

            call    K_INMSG
            db      "FAIL: ",0

            mov     rf, rwb_mismatch_count
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, rwb_numbuf
            call    fmt_size32
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      " mismatch(es), first at position ",0

            mov     rf, rwb_first_bad_pos
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, rwb_numbuf
            call    fmt_size32
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      ", expected ",0

            mov     rf, rwb_first_bad_expected
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, rwb_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      " actual ",0

            mov     rf, rwb_first_bad_actual
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, rwb_numbuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, rwb_numbuf
            call    K_MSG

            call    K_INMSG
            db      ".",13,10,0

            mov     rf, rwb_fail_count
            ldn     rf
            adi     1
            str     rf
            rtn

rwbrv_pass:
            call    K_INMSG
            db      "PASS",13,10,0
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
rwb_fail_count:         db      0
rwb_dspan:              db      0
rwb_count:              dw      0
rwb_name:                db      "RWBOUND.DAT",0
rwb_fcb:                 ds      FCB_LEN
rwb_iobuf:                ds      FCB_IOBUF_LEN
rwb_pos:                 ds      4
rwb_chunk:                ds      CHUNK_LEN
rwb_mismatch_count:       ds      4
rwb_mismatch_found:       db      0
rwb_first_bad_pos:        ds      4
rwb_first_bad_expected:   db      0
rwb_first_bad_actual:     db      0
rwb_short_got:            ds      2
rwb_numbuf:                ds      14

            end     start
