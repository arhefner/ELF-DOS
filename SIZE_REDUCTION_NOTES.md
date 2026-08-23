# Kernel size-reduction pass — 2026-08-23

Branch: `kernel-shrink-agent` (7 commits, rebased onto `main` after a
concurrent hardware-bug fix landed there mid-session — see "A real
correction made mid-session" below).

## Headline numbers

| | `Highest address` | Margin before `RUN_ERRORLEVEL` (the real floor — see `tools/check_kernel_margin.py`) |
|---|---|---|
| Baseline (`main`, `PROG_BASE=$4400`) | `$42e4` | 174 bytes |
| After this pass | `$401e` | **884 bytes** |
| **Delta** | **710 bytes smaller** | **+710 bytes margin** |

`PROG_BASE` was not touched. All 710 bytes are real, freed kernel-resident
space — this pass did not move any boundary, only removed duplicate code.
`krnboot.bin` is byte-identical to `main` (boot files were never touched).
`tools/check_kernel_margin.py` passes both of its checks on the final
build (the `ds`-buffer check and the `RUN_ERRORLEVEL`-floor check).

## What changed and why (grouped, not commit-by-commit)

All seven commits are mechanical *consolidations* of code that was
already byte-for-byte (or field-for-field) duplicated across multiple
call sites — no algorithm was rewritten, no calling convention changed
except "call a shared proc instead of repeating its body inline." Every
new proc's header comment documents exactly which call sites it replaced
and why the extraction is safe (register liveness re-checked at each
site, not assumed).

**`kernel/file.asm`** (by far the largest file — 6674 lines, ~50% of the
kernel's own linked size before this pass) got the overwhelming majority
of the reduction, in five layers of increasing scope:

1. **`_load_lba24` / `_dir_read_sector_from` / `_dir_write_sector_from`**
   (commit `e37ca3e`) — a 3-byte on-disk LBA field being loaded into the
   `R7:R8` register pair, immediately followed by an `f_ideread`/
   `f_idewrite` on `dir_buf`, was duplicated verbatim at 14 separate call
   sites across `_check_shortname_collision`, `_file_create`,
   `_fclose_rewrite_size`, `_mark_entry_deleted`, `dir_create`,
   `dir_remove`, `file_rename`, `file_setattr`, and `file_touch`.

2. **Five small FCB-field accessors** (`_fcb_load_boff`,
   `_fcb_load_cclust`, `_fcb_load_iobuf`, `_fcb_store_cclust`,
   `_fcb_store_boff`; commit `13b7804`) — `file_read`/`file_write`/
   `_fcb_seek_to` each independently repeated "compute `&FCB.field`,
   read/write 2 bytes" for the same field into/out of the same register,
   at 27 call sites total.

3. **The 32-bit (4-byte) siblings** of the above
   (`_fcb_load_fsize32`, `_fcb_load_fpos32`, `_fcb_store_fpos32`) plus
   **`_check_name_dotdot`** (the "reject `.`/`..`" guard, duplicated at 6
   sites) — commit `04c58d1`.

4. **`_fcb_sector_lba_and_iobuf`** (commit `4063fbd`) — the *biggest*
   single win: `file_read`'s own sector-load, `file_write`'s
   read-modify-write load, and `file_write`'s own write-back each
   repeated the same ~17-line "cluster→LBA, add `FCB_CSECT`, load
   `FCB_IOBUF`" sequence. This is file.asm's hottest code path (every
   single byte of every file read/write passes through one of these 3
   sites), so it got the most careful review of anything in this pass.

5. **`_store_fo_name` / `_resolve_fo_name`** (commit `decd501`) — "stash
   a path pointer into `fo_name`" (4 sites) and "load `fo_name`, call
   `path_resolve`" (3 sites), duplicated across `file_open`,
   `_scan_dir_for_name`, `_find_dirent`, `dir_create`, and
   `file_rename`.

**`kernel/redir.asm`** (commit `7a23b6e`) — `_redir_setup`'s own
error-unwind path and `_redir_teardown`'s output half both repeated an
identical 18-line "close `redir_out_handle` if genuinely open, then
clear both flags" sequence, factored into `_redir_close_out_if_open`.
The new version always clears both flags unconditionally (a strict
improvement — writing an already-0 flag is a no-op, and it closes a
narrow window where `redir_out_null` could otherwise carry stale value
forward from a previous command).

**`lib/modload.asm`** (commit `f6002a2`) — this is kernel-resident code
(linked into `kernel.bin`, not `bin/batch.mod` itself, which is built
from the separate `kernel/batch_mod.asm` and was never touched).
`mod_load`'s three exit paths each repeated "dereference `ml_fcb_ptr`,
call `K_FILE_CLOSE`"; factored into `_ml_close_fcb`. Two of those three
exits also shared an identical `stc`/`rtn` tail, merged via fallthrough
instead of a second copy.

### What was investigated and deliberately NOT done

- **`dir_save_state`/`dir_restore_state`'s manually-unrolled 6-byte and
  3-byte field copies** (`kernel/dir.asm`) — checked whether converting
  to a real counted loop would save bytes. It doesn't: at these small,
  fixed byte counts, the loop's own setup+condition-check overhead
  (~8-17 bytes) roughly equals or exceeds what unrolling costs. Verified
  with real byte counts before deciding, not assumed.
- **The three `_redir_type`/`_redir_msg`/`_redir_inmsg` "is output
  active, is it NUL" gate checks** — structurally identical 6-line
  blocks, but each branches to a *different*, dispatcher-specific label
  on both outcomes. A shared helper would need to return a status code
  and have each site branch on it, and the extra branching at each call
  site costs about as much as the extraction saves. Computed the actual
  byte math (would have been a net loss) before deciding to skip it.
- **A `kernel_getcurdir`/`kernel_setcurdir` shared `&drive_cur_dir[i]`
  address helper** (`kernel/kernel.asm`) — real but small (~15 net
  bytes), and `kernel_getcurdir` specifically has a documented history
  of two separate real hardware bugs from register-liveness mistakes.
  Skipped as not worth the risk for the size of the win.
- **`kernel/fat.asm`'s own 2-occurrence LBA-load pattern** — architecturally
  it's the same shape as `_load_lba24`, but `fat.asm` is a *lower* layer
  than `file.asm` (file.asm depends on fat.asm, not the reverse), so
  reaching back up for a shared helper would be a real dependency-direction
  smell for a computed ~8-byte win. Skipped.
- Several other 2–3-occurrence micro-patterns across `kernel/dir.asm`,
  `kernel/loader.asm`, and `kernel/kernel.asm` were checked and found to
  be either too generic (the same "copy a byte, advance two pointers"
  idiom incidentally repeated for unrelated purposes, with no shared
  calling convention worth introducing) or to cost more in call/setup
  overhead than they'd save at their real occurrence count.

## A real bug found and fixed during this pass (not shipped)

While extracting `_resolve_fo_name` (commit `decd501`), a scripted
bottom-up text substitution used a line-number range for `file_open`'s
own call site that didn't account for a 2-line comment continuation on
the instruction being replaced — the substitution ended 2 lines short of
the real `call path_resolve`, leaving a stray `plo rf` and a *duplicate*
`call path_resolve` behind as live code, not just a stale comment. This
would have been a real, if probably survivable (redundant re-resolve),
bug had it shipped.

**Caught before it was ever assembled**, by reviewing the actual diff
hunk-by-hunk rather than trusting the substitution script's own "done"
message — the leftover lines showed up as unchanged context around the
new `call` line, which isn't possible for a genuinely fully-replaced
block. Fixed via a precise, text-anchored edit; every other site from
that same commit was then independently re-read in full (not just
diffed) to confirm none had the same issue. See commit `decd501`'s own
message for the full account.

This is the reason every commit in this pass includes a direct
diff review as a stated verification step, not just "ran the sweeps and
it built" — the sweeps (D-clobber, self-overwrite, gotcha-#18) are
necessary but not sufficient; they don't catch "the substitution range
was wrong," only specific register-clobber shapes.

## A real correction made mid-session (worth knowing about)

Partway through this session, a `git diff main..HEAD -- include/` check
(done as part of final verification, to confirm boot/include files were
genuinely untouched) surfaced that `main` had moved **two commits ahead**
of the commit this branch had originally started from, while this branch
was in progress. Those two commits (`d4c212a`/`1b059db`) fixed a real,
hardware-confirmed bug: `PROG_BASE` had been at `$4300`, which was 82
bytes *past* `RUN_ERRORLEVEL` (the real floor of the kernel's usable
address space — the lowest of several fixed `PROG_BASE`-relative relay
addresses the shell rewrites on every command), even though the *old*
`Highest address < PROG_BASE` check reported a healthy-looking 28-byte
margin. The kernel's own compiled code (the batch-module loader) was
silently overlapping memory the shell overwrites on every single
command — invisible until a `.bat` script actually tried to call into
the corrupted code, which hung with zero console output. That commit
moved `PROG_BASE` back to `$4400` and extended `tools/check_kernel_margin.py`
with a second, generic check against this exact floor.

This branch's own work never touched `PROG_BASE`, `include/kernel.inc`,
or `tools/check_kernel_margin.py`, so `git rebase main` picked up both
fixes with **zero merge conflicts** (all seven commits here are confined
to `kernel/file.asm`, `kernel/redir.asm`, and `lib/modload.asm`). The
kernel's own `Highest address` came out byte-identical before and after
the rebase (`$401e` either way), confirming this pass's own reduction is
fully independent of that fix and additive on top of it. All verification
in this document (jump-table decode, margin numbers, `make progs`/`make
test`) was re-run *after* the rebase, against the corrected baseline —
the numbers above are the final, correct ones.

**Practical implication for whoever reviews this branch next**: don't
merge this without first confirming it's still rebased cleanly onto the
current tip of `main` — that's already true as of this writing, but
`main` may move again before this branch is reviewed.

## Jump table / boot files

**The kernel API jump table was NOT touched or renumbered.** All 47
`K_*` jump-table slots (plus the two data-pointer exceptions,
`BPB_DATA_PTR`/`DRIVE_DATA_PTR`) were decoded directly from the built
`kernel.bin` after every single commit and confirmed `0xC0`/`lbr` with
correct targets — this was checked after every commit in this pass, not
just at the end. The five redirect-aware dispatcher targets
(`K_TYPE`/`K_MSG`/`K_INMSG`/`K_READ`/`K_INPUTL` → `_redir_type`/
`_redir_msg`/`_redir_inmsg`/`_redir_read`/`_redir_inputl`) were
specifically cross-checked against their real linked addresses via
`link02 -s` on the exact relaxed build (not a separate, differently
relaxed link — `-r` relaxation renumbers everything per-build, so a
mismatched link would give false confidence).

**`boot/mbr.asm` and `boot/krnboot.asm` were never touched.**
`git diff main..HEAD -- boot/` is empty. `krnboot.bin` was rebuilt and
confirmed unchanged in size (1536 bytes) at every checkpoint.

## Verification performed (every commit, not just the final one)

- Clean assemble (0 errors/0 warnings) on every touched file.
- D-clobber sweep (`mov`/`add16`/`sub16`/`shl16`/`shr16`/`shlc16`/
  `shrc16`/`push`/`pop` immediately followed by a `D`-dependent
  consumer with no refresh) — 0 hits on every touched file, every
  commit.
- Self-overwrite sweep (`lda X` immediately followed by `phi X`/`plo X`
  with no intervening read) — 0 hits.
- Gotcha-#18 sweep (a register-register `add16`/`sub16` running between
  a `str r2` staging instruction and its real consumer) — 0 hits.
- `proc`/`endp` balance and duplicate-top-level-label checks — clean.
- A dangling-label-reference check (every branch/call target either
  defined locally or `extrn`'d) — the only hits were BIOS/kernel-API
  `equ` constants my regex-based "defined" check doesn't recognize
  (`f_ideread`, `K_FILE_CLOSE`, etc.) — confirmed false positives by
  inspection, not real dangling references.
- Full clean `make` + `make progs` + `make test` after every commit:
  0 errors/0 warnings throughout, 40 `bin/` + 11 `test/bin/` binaries
  present and unchanged in count.
- All 47 `K_*` jump-table slots decoded from the actual built
  `kernel.bin` and confirmed `0xC0`/`lbr`, every commit.
- `krnboot.bin` size confirmed unchanged (1536 bytes), every commit.
- A full `git diff` hunk-by-hunk review of every substitution before
  assembling (this is what caught the real bug described above).

## What I'm NOT fully confident about

- **Nothing here has been hardware-tested.** Per this project's own
  standing practice (no local emulator exists), "build-verified,
  not hardware-tested" is the expected state for all of this — not a
  caveat to downplay.
- The `_fcb_sector_lba_and_iobuf` extraction (commit `4063fbd`) touches
  the single hottest code path in the whole file-I/O layer. I'm
  confident it's a faithful, byte-for-byte mechanical relocation (the
  diff review confirms this directly), but it's the one change in this
  pass I'd want a hardware round to confirm *first*, before trusting
  the rest.
- The `_store_fo_name`/`_resolve_fo_name` commit (`decd501`) is the one
  where a real bug was caught and fixed mid-development (see above). The
  fix is verified correct by direct re-reading of every site, and the
  build/sweep suite is clean, but given a bug genuinely existed in an
  earlier draft of this exact commit, it's worth slightly extra scrutiny
  on hardware relative to the others.
- I did not attempt anything in `kernel/dir.asm`, `kernel/kernel.asm`,
  `kernel/fat.asm`, `kernel/path.asm`, `kernel/loader.asm`,
  `kernel/batch.asm`, or `kernel/glob.asm` beyond investigating them —
  every concrete opportunity I found in those files was either a wash
  or a net loss at its real occurrence count (see "deliberately NOT
  done" above). There may be size left on the table in those files that
  a different approach (e.g. actually restructuring an algorithm, not
  just deduplicating identical code) could find — I stayed within
  "mechanical consolidation of already-duplicate code," per the low-risk
  end of what the task asked for.

## What a hardware round should specifically exercise

In rough priority order, given what each commit touches:

1. **Ordinary file read/write/append, across at least one sector
   boundary and one cluster boundary** (`_fcb_sector_lba_and_iobuf`,
   `4063fbd`) — the highest-value single test. `TYPE`/`WTEST`/`ATEST`/
   `COPY` on files that cross 512 bytes and cross a full cluster.
2. **File open/create/delete/rename, plus `MD` and `REN` specifically**
   (`_store_fo_name`/`_resolve_fo_name`, `decd501`) — this is where the
   real bug was found and fixed; worth confirming directly.
3. **Anything that redirects output** (`>`, `>>`) — `_redir_close_out_if_open`
   (`7a23b6e`), especially back-to-back redirected commands (to catch
   any flag-clearing regression) and a redirect that fails partway
   (the error-unwind path specifically).
4. **A `.bat` script that uses the loadable batch module** — exercises
   `lib/modload.asm`'s `mod_load` (`f6002a2`) end to end, not just its
   own three exit paths individually.
5. **General regression**: `DIR`/`LS`/`CD`/directory creation and
   removal, `STAT` — all of these touch the FCB accessors and the
   `_load_lba24`/`_dir_read_sector_from`/`_dir_write_sector_from` family
   (commits `e37ca3e`/`13b7804`/`04c58d1`) indirectly, through
   `_file_create`/`dir_create`/`dir_remove`/`file_setattr`/`file_touch`.

None of the above needs to be a dedicated round on its own — the
project's own existing hardware-testing habits (a normal session
exercising ordinary commands, `MD`/`RD`/`REN`, a file crossing 64K, a
`.bat` script) already cover most of this list; it's worth being
deliberate about including a redirect and a batch-module invocation in
whatever round tests this branch, since those are the two paths this
pass touched that don't get exercised by pure everyday `DIR`/`TYPE`/`CD`
use.
