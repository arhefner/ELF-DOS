;
; envtest.asm - exercises lib/env.asm's env_getenv/env_setenv/
; env_unsetenv against the real on-disk /cfg/env.dat store.
;
; Usage: ENVTEST
;
; Deletes /cfg/env.dat first (via K_FILE_DELETE, failure ignored) to
; guarantee a deterministic starting state regardless of what's
; already on the card, then runs a battery of checks: getenv on a
; missing file, set/get round-trip, the overwrite=0 vs overwrite=1
; distinction, multiple variables coexisting in the same file
; (exercises the copy-unrelated-lines-through path across a real
; multi-line file), unsetenv removing one variable without disturbing
; the others, unsetenv's own idempotent success on a name that was
; never set, and both setenv/unsetenv correctly rejecting a name
; containing '='. Prints PASS/FAIL per check plus a final summary --
; no assert infrastructure exists on this platform, so failures are
; reported, not trapped.
;
; Deliberately does NOT delete /cfg/env.dat at the end -- leaves it
; for manual inspection via "TYPE /cfg/env.dat", matching seektest's
; own choice to leave SEEKTST.DAT behind. Links against lib/env.prg --
; NOT a self-contained single-file program; see the Makefile's own
; explicit rule for it.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   env_getenv
            extrn   env_setenv
            extrn   env_unsetenv
            extrn   _env_streq

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rb, et_fail_count
            ldi     0
            str     rb                  ; et_fail_count = 0

            call    K_INMSG
            db      "ENVTEST starting.",13,10,0

            ; --- clean slate: delete any pre-existing env.dat ---
            mov     rf, et_envpath
            call    K_FILE_DELETE       ; DF ignored -- may not exist

            ; ================================================
            ; check 1: getenv("FOO") on a missing file -> RF=0
            ; ================================================
            call    K_INMSG
            db      "check1 (getenv on missing file -> NULL): ",0
            mov     rf, et_foo
            call    env_getenv
            call    et_check_null

            ; ================================================
            ; check 2: setenv("FOO","bar",1) -> DF=0
            ; ================================================
            call    K_INMSG
            db      "check2 (setenv FOO=bar, overwrite): ",0
            mov     rf, et_foo
            mov     rd, et_bar
            ldi     1
            call    env_setenv
            call    et_expect_ok

            ; ================================================
            ; check 3: getenv("FOO") == "bar"
            ; ================================================
            call    K_INMSG
            db      "check3 (getenv FOO == bar): ",0
            mov     rf, et_foo
            call    env_getenv
            mov     rd, et_bar
            call    et_check_val

            ; ================================================
            ; check 4: setenv("FOO","baz",0) [no overwrite] -> DF=0
            ; ================================================
            call    K_INMSG
            db      "check4 (setenv FOO=baz, no overwrite): ",0
            mov     rf, et_foo
            mov     rd, et_baz
            ldi     0
            call    env_setenv
            call    et_expect_ok

            ; ================================================
            ; check 5: getenv("FOO") still == "bar" (unchanged)
            ; ================================================
            call    K_INMSG
            db      "check5 (FOO unchanged, still bar): ",0
            mov     rf, et_foo
            call    env_getenv
            mov     rd, et_bar
            call    et_check_val

            ; ================================================
            ; check 6: setenv("FOO","baz",1) [overwrite] -> DF=0
            ; ================================================
            call    K_INMSG
            db      "check6 (setenv FOO=baz, overwrite): ",0
            mov     rf, et_foo
            mov     rd, et_baz
            ldi     1
            call    env_setenv
            call    et_expect_ok

            ; ================================================
            ; check 7: getenv("FOO") now == "baz"
            ; ================================================
            call    K_INMSG
            db      "check7 (FOO now baz): ",0
            mov     rf, et_foo
            call    env_getenv
            mov     rd, et_baz
            call    et_check_val

            ; ================================================
            ; check 8/9: setenv ROWS=24, COLUMNS=80
            ; ================================================
            call    K_INMSG
            db      "check8 (setenv ROWS=24): ",0
            mov     rf, et_rows
            mov     rd, et_24
            ldi     1
            call    env_setenv
            call    et_expect_ok

            call    K_INMSG
            db      "check9 (setenv COLUMNS=80): ",0
            mov     rf, et_columns
            mov     rd, et_80
            ldi     1
            call    env_setenv
            call    et_expect_ok

            ; ================================================
            ; check 10/11/12: all three variables coexist correctly
            ; ================================================
            call    K_INMSG
            db      "check10 (FOO still baz): ",0
            mov     rf, et_foo
            call    env_getenv
            mov     rd, et_baz
            call    et_check_val

            call    K_INMSG
            db      "check11 (ROWS == 24): ",0
            mov     rf, et_rows
            call    env_getenv
            mov     rd, et_24
            call    et_check_val

            call    K_INMSG
            db      "check12 (COLUMNS == 80): ",0
            mov     rf, et_columns
            call    env_getenv
            mov     rd, et_80
            call    et_check_val

            ; ================================================
            ; check 13: unsetenv("ROWS") -> DF=0
            ; ================================================
            call    K_INMSG
            db      "check13 (unsetenv ROWS): ",0
            mov     rf, et_rows
            call    env_unsetenv
            call    et_expect_ok

            ; ================================================
            ; check 14: getenv("ROWS") -> RF=0 (gone)
            ; ================================================
            call    K_INMSG
            db      "check14 (ROWS gone): ",0
            mov     rf, et_rows
            call    env_getenv
            call    et_check_null

            ; ================================================
            ; check 15/16: FOO/COLUMNS unaffected by ROWS removal
            ; ================================================
            call    K_INMSG
            db      "check15 (FOO still baz after unset): ",0
            mov     rf, et_foo
            call    env_getenv
            mov     rd, et_baz
            call    et_check_val

            call    K_INMSG
            db      "check16 (COLUMNS still 80 after unset): ",0
            mov     rf, et_columns
            call    env_getenv
            mov     rd, et_80
            call    et_check_val

            ; ================================================
            ; check 17: unsetenv on a never-set name -> DF=0
            ; (idempotent, matching real unsetenv)
            ; ================================================
            call    K_INMSG
            db      "check17 (unsetenv never-set name): ",0
            mov     rf, et_notset
            call    env_unsetenv
            call    et_expect_ok

            ; ================================================
            ; check 18: setenv with a name containing '=' -> DF=1
            ; ================================================
            call    K_INMSG
            db      "check18 (setenv rejects name with '='): ",0
            mov     rf, et_badname
            mov     rd, et_bar
            ldi     1
            call    env_setenv
            call    et_expect_err

            ; ================================================
            ; check 19: unsetenv with a name containing '=' -> DF=1
            ; ================================================
            call    K_INMSG
            db      "check19 (unsetenv rejects name with '='): ",0
            mov     rf, et_badname
            call    env_unsetenv
            call    et_expect_err

            ; --- summary ---
            mov     rb, et_fail_count
            ldn     rb
            lbz     et_all_pass
            call    K_INMSG
            db      "ENVTEST: SOME CHECKS FAILED.",13,10,0
            ldi     1
            rtn

et_all_pass:
            call    K_INMSG
            db      "ENVTEST: all checks passed.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; et_check_val: compare RF (actual value from env_getenv, may be 0)
; against RD (expected string literal). Prints PASS/FAIL, updates
; et_fail_count. A NULL actual value is always a FAIL here -- this
; helper is only used where a real value is expected.
;------------------------------------------------------------------
et_check_val:
            ghi     rf
            lbnz    et_cv_notnull
            glo     rf
            lbnz    et_cv_notnull
            lbr     et_fail

et_cv_notnull:
            call    _env_streq          ; RF=actual, RD=expected
                                        ; (both already loaded by the
                                        ; caller)
            lbdf    et_fail
            lbr     et_pass

;------------------------------------------------------------------
; et_check_null: expect RF (from env_getenv) to be 0.
;------------------------------------------------------------------
et_check_null:
            ghi     rf
            lbnz    et_fail
            glo     rf
            lbnz    et_fail
            lbr     et_pass

;------------------------------------------------------------------
; et_expect_ok/et_expect_err: check DF as left by the immediately
; preceding call (env_setenv/env_unsetenv) -- DF survives a `call`
; instruction itself (a pure control-transfer, not an ALU op), so
; this is safe to check here rather than needing it re-threaded
; through an argument.
;------------------------------------------------------------------
et_expect_ok:
            lbdf    et_fail
            lbr     et_pass

et_expect_err:
            lbnf    et_fail
            lbr     et_pass

;------------------------------------------------------------------
; et_pass/et_fail: print PASS/FAIL, update et_fail_count, return --
; reached via a bare `lbr` (tail call) from the helpers above, so
; this `rtn` correctly returns to whatever called THEM.
;------------------------------------------------------------------
et_pass:
            call    K_INMSG
            db      "PASS",13,10,0
            rtn

et_fail:
            call    K_INMSG
            db      "FAIL",13,10,0
            mov     rb, et_fail_count
            ldn     rb
            adi     1
            str     rb
            rtn

et_fail_count:  db      0
et_envpath:     db      "/cfg/env.dat",0
et_foo:         db      "FOO",0
et_bar:         db      "bar",0
et_baz:         db      "baz",0
et_rows:        db      "ROWS",0
et_24:          db      "24",0
et_columns:     db      "COLUMNS",0
et_80:          db      "80",0
et_notset:      db      "NOTSET",0
et_badname:     db      "BAD=NAME",0

            end     start
