# EDLIN size reduction (branch `edlin-shrink-agent`)

## Result

| | bytes |
|---|---|
| `bin/edlin` before (main, `6bd1052`) | 15569 |
| `bin/edlin` after (this branch, `c85b6c9`) | 12891 |
| **delta** | **-2678 bytes (-17.2%)** |

| | bytes |
|---|---|
| `progs/edlin.prg` "Code Generated" before | 9492 |
| `progs/edlin.prg` "Code Generated" after | 6818 |
| **delta** | **-2674 bytes (-28.2%)** |

(`bin/edlin`'s smaller percentage drop is expected -- it also carries the
linked-in `lib/env.prg`/`lib/lineedit.prg`, which this work never touched.)

The source file itself also shrank, from 6282 to 4999 lines, despite
adding roughly a dozen new shared helper routines -- because every
converted call site collapsed from several lines of inline
register/memory shuffling down to one `call` plus one or two inline
operand lines, and that reduction outweighed the new routines' own,
one-time cost.

No hardware or emulator access exists in this environment. Every change
below is **build-verified only** -- clean assemble, a battery of static
sweeps, and direct `.lst`-byte decoding of sample sites -- never run on
real 1802 hardware. Treat "build-verified, not hardware-tested" as the
expected, normal state of this branch, not a caveat to downplay. See the
test checklist at the end before trusting this on real hardware.

## Hardware round (2026-08-24) and the L/P investigation

The branch got its first real hardware round. Most of it passed cleanly:
`dir`/`ls`/`xcopy`/`touch`/`cd`/`pwd`/`edlin`, several batch scripts, and
I/O redirection all "looked good." Two commands, `L` and `P`, were
reported as misbehaving:

- **P**: "It prints a page of text, but then the cursor is just sitting
  on a blank line at the bottom. When I press any key it prints a
  prompt" -- i.e. any keypress, not just Ctrl-C, was ending the listing
  and returning to the `*` prompt.
- **L**: "similar, but I can't determine exactly how it decides what
  line to start with."

This was investigated exhaustively -- the entire `ed_cmd_l`/`ed_cmd_p`
default-line computation, `ed_list_clamp_last`, `ed_parse_range`/`ed_
parse_lineref` (the `+n`/`-n` relative-reference parser), `ed_list_
start`/`ed_list_loop`/`ed_list_finish`'s own pause-and-continue
mechanic, `ed_bare_number`'s insert-then-delete single-line edit, and
**every one of the 25 occurrences of the new `ed_copy_word` helper**,
cross-referenced as a full multiset against `main`'s original inline
copies (every one matches in both content and source/destination
polarity -- zero drift, no argument-order bugs anywhere). Every register
a new helper documents as scratch was checked against what its actual
callers in this file need to survive across it.

**Conclusion: this was not a regression.** The behavior is byte-for-byte
identical to `main`'s pre-existing, already-hardware-confirmed
(2026-07-31) design -- confirmed not just by source-level tracing but by
directly decoding the final `-r`-relaxed linked binary at the `ed_list_
loop`/`ed_list_finish`/`K_READ`-pause region: every branch target
matches its label's real linked address exactly, with zero drift from
relaxation. What's actually happening: a bare `P` or `L` (no explicit
line range) is capped to exactly ONE page by design, matching real
MS-DOS/FreeDOS EDLIN -- you type `P`/`L` again to see the next page,
rather than one invocation paging continuously. Because the range is
capped to exactly one page, the internal pause-and-continue mechanism
(which exists to handle an EXPLICIT multi-line range like `L 1,50`)
always coincides with the very end of that range for a bare invocation
-- so any keypress, not just Ctrl-C, correctly returns to the prompt,
because there's genuinely nothing left in the range to show. The
explicit-multi-line-range continuation path (where the pause SHOULD
resume printing further lines) was traced numerically too (e.g.
`list_i=23 < list_last=50` after the first pause correctly falls
through to print line 24 onward) and found correct.

The one real, if currently non-symptomatic, issue found along the way
(commit `1cd9ce9`): `ed_stb_const` stages its inline constant byte in
`R9.0` across the 2-byte address read, but its header only documented
`RF`/`R6` as modified. All 9 call sites in this file were checked --
none currently depend on `R9` surviving the call -- so the fix is pure
documentation (zero instruction/byte change, confirmed via an unchanged
`Code Generated` count), closing a real gap before it can bite a future
caller.

**Not fully confident about**: whether the design itself (single page
per bare invocation, no continuous auto-paging) actually matches what
the user wants day-to-day -- that's a legitimate UX question, separate
from "is the code correct," and outside the scope of a regression
investigation. If continuous paging on a bare `P`/`L` turns out to be
the desired behavior, that's a real design change to discuss, not a bug
fix.

## L/P design fix (2026-08-24) -- the user's own FreeDOS-backed pushback

The "not a regression, working as designed" conclusion above turned out
to be right as far as it went, but the design itself was wrong. The
user came back with real FreeDOS documentation and asked for three
specific, deliberate reversals of the 2026-07-31 decisions this file's
own comments already documented at length -- each one confirmed
explicitly before implementing, and each one a real design change, not
a bug fix, kept as its own separate, clearly-labeled commit on top of
the size-reduction work above:

1. **`ED_DEFAULT_LOOKBACK` (a fixed `11`) reverted to `ed_page_lines/2`,
   computed at runtime.** L's own default starting line now genuinely
   scales with whatever `ROWS` currently produces for the page size,
   instead of assuming a fixed screen height. Interestingly, this is
   itself a *second* reversal -- `ED_PAGE_LINES`'s own comment already
   recorded that the *original* implementation (before 2026-07-31) used
   `page_lines/2`, and it was deliberately decoupled into a fixed
   constant at the user's own earlier request; this change simply
   un-reverses that. Implemented as a single `SHR` on `ed_page_lines`
   (a plain 0-255 byte) -- floor division, the natural reading of
   "centered."
2. **`ed_list_clamp_last`'s "no end given" default changed from
   `first + page_lines - 1` (cap to exactly one page) to `line_count`
   (the rest of the buffer).** This is the change that actually fixes
   the reported symptom: with the range always capped to one page, the
   pause-and-continue mechanism in `ed_list_loop` -- already correct for
   a genuinely multi-page range -- could never have anything left to
   continue to, since the pause always coincided with the very end of
   the range. The routine shrank to a thin wrapper reading `ed_line_count`
   directly; it keeps its old `(first in, last out)` signature purely to
   avoid touching either of its two call sites, even though `first` is
   no longer read.
3. **The silent "any key but Ctrl-C continues" pause replaced with a
   real, visible `"Continue (Y/N)? "` prompt**, following `ed_cmd_q`'s
   own already-hardware-proven Y/N-confirmation idiom exactly (`K_READ`,
   stash via `plo rc` before the `mov` that would clobber `D`, echo via
   `K_TTY`, print CRLF, fold case, anything but `Y`/`y` stops). Ctrl-C is
   no longer special-cased -- per the user's own explicit "I don't need
   Ctrl-C to stop the listing," it just falls through to the same
   "anything but Y" stop path as every other non-continue key.

**The `ED_PAGE_LINES` `ROWS-1` holdback was re-examined, not assumed
unchanged**, since the original 2026-07-31 reasoning for it was written
specifically for the *silent* pause design being replaced here. Traced
through concretely: printing exactly `ed_page_lines` (`=ROWS-1`) content
lines leaves the terminal's cursor on the last, still-blank row --
exactly where the new prompt text lands, with no scroll needed to show
it. The screen only scrolls once the user actually answers and presses
Enter, which is the natural point for that to happen, not a surprise
that pushes unread content away before it's been seen. A plain `ROWS`
(no holdback) would instead force that same scroll *before* the prompt
even printed, silently losing the page's own first line the instant the
pause fired. Conclusion: `ROWS-1` stays correct, now for a related but
different reason than the one originally written down -- both the old
and new reasoning are preserved in the code's own comment for history.

**Verification for this pass**: since none of these three changes are
mechanical transforms (unlike the earlier size-reduction commits), each
was traced by hand against concrete register values rather than just
diff-reviewed, and the full rewritten pipeline was mechanically traced
against four scenarios before any of it was trusted: a file shorter
than one page (no pause ever fires), a file of exactly one page (the
pause fires once, right at the end, and answering Y correctly finds
nothing left and ends cleanly with no spurious second prompt), a
genuinely multi-page file (the pause fires mid-listing and Y correctly
resumes printing the next batch), and a range whose final page is a
partial page (no pause after that last short batch, since the top-of-
loop range check fires before the per-line pause-threshold check gets a
chance to). Full D-clobber/self-overwrite/gotcha-18/duplicate-label/
self-referential-call/register-name-as-symbol sweeps clean at every
commit; clean `make`+`make progs`+`make test` (0 errors/warnings) at
every commit; `bin/edlin` ends this pass at 12904 bytes (up from 12860
after part 2's own routine-shrink, and up 13 bytes net from the branch's
pre-design-fix baseline of 12891 -- the visible prompt's own new code
costs slightly more than `ed_list_clamp_last`'s simplification saved).

**Still build-verified only, not hardware-tested** -- this needs its own
fresh hardware round; see the updated checklist below, which now
specifically calls for the explicit multi-line-range scenario (the one
path neither this pass nor the original investigation could exercise
without real hardware).

## What changed, and why

`progs/edlin.asm` is a large, flat (no `proc`/`endp`) file full of small,
repeated 1802 instruction sequences -- the same "load a word from a fixed
address," "store a word," "compare two values," "copy a word between two
fixed addresses" shapes appearing dozens of times across different EDLIN
commands, each written out inline. 1802 code has no cheap way to pass a
compile-time-constant address as an ordinary call argument (there's no
"immediate operand after a call" instruction), so the natural C-like fix
(extract a shared subroutine, pass the address as a parameter) doesn't
translate directly -- passing an address either costs a `mov` into a
register first (no smaller than the inline code it would replace) or needs
some other mechanism.

The mechanism used throughout this branch is the SCRT **inline-operand
idiom** already established elsewhere in this codebase (`K_INMSG`'s
inline-text convention, `kernel/redir.asm`'s `_redir_inmsg`): a routine
reached via `call` can read fixed bytes immediately following the `call`
instruction itself via `lda r6` (R6 holds the resume address at entry to a
called routine under SCRT, and auto-increments as bytes are read from it),
as long as it leaves R6 correctly repositioned past those inline bytes
before its own `rtn`. This turns `mov rf, ADDR` (3 bytes) + `lda
rf`/`plo`/`phi` (4-6 bytes) into `call ed_ldw_rd` (2 bytes) + `dw ADDR` (2
bytes) -- the call site shrinks, and the actual load logic lives once,
shared, in the callee. Verified empirically in isolation (a standalone
test file, `.lst`-decoded) before trusting it in the real file, and
reasoned to be safe here because none of these leaf helper routines ever
make a nested `call` of their own, so R6 is never at risk of being
clobbered before they return control past their own inline operand bytes.

Everything below groups the 12 commits on this branch into four themes.

### 1. Word load/store helpers (the foundational pattern)

New leaf routines, each replacing several inline instructions with one
`call` + 2-4 inline operand bytes:

- `ed_ldw_rd`/`ed_ldw_r8`/`ed_ldw_r9`/`ed_ldw_ra` -- load a 16-bit word
  from a fixed address into RD/R8/R9/RA.
- `ed_stw_rd`/`ed_stw_r8`/`ed_stw_r9`/`ed_stw_rc` -- store RD/R8/R9/RC to
  a fixed address.
- `ed_zero_word` -- zero a 16-bit word at a fixed address (a common
  special case of store, worth its own smaller/simpler routine).
- `ed_stb_const` -- store a fixed constant byte to a fixed address (two
  inline operands: the byte value, then the 2-byte address).
- `ed_ldw_rd_via_r8`/`ed_ldw_r9_via_r8` -- same as `ed_ldw_rd`/`ed_ldw_r9`
  but using R8 (never RF) as internal scratch, for call sites inside/near
  `ed_parse_lineref` where RF itself is the live parse cursor and must
  never be disturbed (that routine's own header comment already documents
  this "always R8, never RF" discipline for its own hand-written code --
  these two helpers extend the same discipline to its call sites).
- `ed_stw_rf_via_rb`/`ed_stw_rd_via_rb` -- the store-side counterpart:
  stores RF's or RD's *own current value* using RB (never RF/RD) as
  scratch, for the 5+4 sites where the value being stored is exactly the
  register that must survive the store (filename/parse-cursor pointers in
  RF; `ed_parse_range`'s n1-n4 capture into RD while RF is simultaneously
  the live parse cursor).

This family alone accounts for the largest share of commits (5 of 12) and
covers the majority of individual call sites converted (well over 60
across the whole file).

### 2. Register-register comparison and arithmetic helpers

No inline operand needed here -- both operands are already in registers,
so these are pure "several instructions collapse to one call" savings:

- `ed_cmp_rd_le`/`ed_cmp_r8_le` -- compare RD (resp. R8) against a value
  loaded from a fixed address, returning DF only (no branch baked in, so
  callers keep their own `lbdf`/`lbnf` choice).
- `ed_cmp_rd_r8`/`ed_cmp_rd_r9` -- plain register-register compare
  (RD vs R8, RD vs R9), DF=1 if RD>=operand.
- `ed_sub_rd_r8_to_rc`/`ed_sub_rd_r8_to_r9` -- RC (resp. R9) = RD - R8,
  register-register subtract with the result kept.

One shape was deliberately investigated and **not** extracted: the
"`glo r8/str r2/glo rd/add/plo rd/ghi r8/str r2/ghi rd/adc/phi rd`"
register-register-add pattern (5 occurrences) is the literal hand-written
expansion of `ADD16`'s own `NR`-form macro -- replacing it with
`add16 rd, r8` produces byte-*identical* output, a readability win only,
zero size benefit, so it was left alone.

### 3. Memory-to-memory word copy (`ed_copy_word`) -- the single largest win

The "`mov rf, DST / mov rd, SRC / lda rd / str rf / inc rf / ldn rd / str
rf`"-shaped word copy between two fixed addresses appeared 25 times across
the file (found via a general sliding-window repeated-block scanner, not
anticipated up front). Collapsed into one `ed_copy_word` routine taking
both addresses as inline operands (source first, then destination). This
single pattern was the largest per-site saving on the whole branch.

### 4. Array/table lookup (`ed_lines_lookup_r8`/`ed_lines_lookup_r9`)

`ed_lines[RD]` (the line-offset table lookup: double RD, add the table's
base address, load the resulting word into R8 or R9) recurred 8 times.
Unlike the load/store family above, this needs no inline address operand
at all -- `ed_lines` is always the same fixed symbol -- so the routine
hardcodes it internally. RD is destructively doubled as a side effect;
verified safe at all 8 call sites (none of them needed RD's original,
un-doubled value afterward). Second-largest per-site saving on the
branch, found by the same general scanner as `ed_copy_word`.

### 5. Error-message consolidation

Two clusters of byte-for-byte duplicate error-print-and-return blocks:
9 duplicate "Line number out of range." blocks (labels `ed_l_err`,
`ed_i_err`, `ed_r_err`, `ed_c_err`, `ed_m_err`, `ed_d_err`,
`ed_wsave_rangeerr`, `ed_s_err`, plus the original canonical target) and
5 duplicate "Buffer full." blocks (`ed_i_toolong`, `ed_t_toolong`,
`ed_r_toolong`, `ed_c_toolong`, plus the canonical `ed_edit_toolong`).
Every `lbr`/`lbz`/`lbnz`/etc. that used to target one of the 12 duplicate
labels was retargeted to the one real, canonical label, and the now-dead
duplicate blocks deleted. Pure `lbr`-target consolidation, no new
routines.

## Two real bugs, self-caught before they reached a build (or reached hardware)

Both were caught by this branch's own verification discipline doing
exactly what it's for -- worth keeping as concrete examples, not just a
line in a changelog.

**Bug 1 -- a mechanical transform matched something it shouldn't have.**
The STORE-pattern transform script matched `mov rf, <token>` via a regex
that accepted *any* non-whitespace token as the target address, including
bare CPU register mnemonics. Two sites in `ed_r_strip_quotes` used `mov
rf, ra` / `mov rf, rc` -- these are *register-indirect* stores (RF :=
RA's/RC's *current runtime value*, a pointer the caller already loaded),
not symbolic-address stores at all. The transform mechanically produced
`call ed_stw_r8 / dw ra` and `call ed_stw_rd / dw rc`. Because
`ed_ldw_*`/`ed_stw_*`'s whole mechanism requires a real compile-time
address in the `dw` operand, Asm/02 silently accepted the bare tokens
`ra`/`rc` and resolved them as their own register-*index* numeric
constants ($000A/$000C) instead of erroring -- confirmed by decoding the
actual `.lst` bytes, which showed `dw ra` compiled to `00 0a`. Left
uncaught, this would have written through the fixed wrong address
$000A/$000C on hardware instead of dereferencing the real runtime pointer
-- a genuine memory-corruption bug. Caught by directly decoding a sample
of *every* transformed pattern's compiled bytes rather than trusting the
regex match, not by any generic "clean assemble" check (Asm/02 accepted
it without complaint). Fixed by reverting this one site to its original
inline form with an explanatory comment, and by adding a permanent
"register-name-as-symbol false match" check to the standing sweep script,
re-run after every subsequent transform on this branch.

**Bug 2 -- a routine's own definition matched its own search pattern.**
While building `ed_sub_rd_r8_to_rc`, its definition was inserted into the
file *before* running the transform/replace script that hunts for its
target instruction pattern. Since the new routine's own 10-instruction
body *is* that exact pattern, the script matched and replaced the
routine's own body with a call to itself (`ed_sub_rd_r8_to_rc: call
ed_sub_rd_r8_to_rc / rtn`, infinite recursion). Caught immediately by
re-reading the routine body right after running the script, before ever
assembling or committing -- reverted via `git checkout` and redone in the
safe order (transform first, against a file with no such routine defined
yet; insert the new routine's own definition afterward). A permanent
"self-referential call site" check (does any `ed_*:` label's own body
contain `call <its own name>`) was added to the standing sweep and re-run
after every later routine addition.

## What was investigated and deliberately not done

- **Merging the R and S commands' shared search/scan logic.** They share
  real structural similarity but differ enough in range-default semantics
  and post-match behavior that a merge felt like a real risk of quietly
  changing behavior for a marginal byte saving -- not pursued.
- **Merging the T command's file-load path with `ed_load_file`.** A real,
  moderate-size opportunity, but touches file-I/O-adjacent control flow
  this pass didn't have time to verify as rigorously as the smaller, more
  mechanical patterns above -- deferred rather than rushed.
- **The 15-site "`ghi rd/lbnz X/glo rd/lbz Y`" zero-check shape.**
  Investigated for consolidation, but the 15 sites turned out to encode
  **two different semantics**: most treat it as "is RD exactly zero," but
  at least 2 sites (e.g. `ed_bare_number`'s n1 check) branch to the same
  error label on *either* condition, meaning they also silently reject any
  RD >= 256 (reachable, since `ED_MAX_LINES=512`) -- a pre-existing,
  seemingly unintentional quirk in the *original* code, unrelated to
  anything on this branch. Consolidating all 15 into one shared routine
  risked silently normalizing that inconsistency one way or the other, an
  unauthorized behavior change disguised as a size optimization -- left
  alone on purpose.
- **A separate `ed_cmp_r8_rd` routine** (R8 staged, RD loaded last, the
  mirror image of `ed_cmp_rd_r8`). One apparent occurrence turned out to
  be *inside* `ed_cmp_rd_le`'s own leaf-routine body (internal
  implementation, not a separate call site) and was correctly left alone.
  Only 2 genuine, non-self-referential sites remained after excluding it
  -- not worth a dedicated routine (call+rtn overhead would roughly
  offset the saving).

## What I'm not fully confident about

- **No hardware or emulator access at all in this environment.** Every
  claim above is backed by a clean assemble, static sweeps, and
  `.lst`-byte decoding of representative sample sites per pattern -- never
  an actual run. This is the single biggest reason to treat this branch
  as "needs a real hardware round," not as finished.
- The mechanical transforms converted 60+ call sites across several
  pattern families; every family was sample-verified at the byte level and
  swept structurally across *all* its sites (D-clobber, self-overwrite,
  gotcha #18, register-name-as-symbol, self-referential-call, duplicate-
  label, undefined-branch-target), but not every single individual site
  was hand-traced byte-by-byte the way the bug-1 sample was. The sweep
  suite is designed to catch the *shapes* of error already seen on this
  project (including both bugs found on this branch); a genuinely novel
  failure shape specific to one particular call site is the residual risk.
- The R6-inline-operand mechanism itself is well-precedented elsewhere in
  this codebase (`K_INMSG`, `_redir_inmsg`) but this is the first time
  it's been used in `edlin.asm` specifically, and the first time in this
  codebase it's been used for fixed *addresses*/*constants* rather than
  variable-length *text*. Verified in isolation before use and reasoned
  safe (no nested calls inside these leaf routines), but "reasoned safe"
  is not the same as "hardware-confirmed."
- `ed_lines_lookup_r8`/`_r9` destructively double RD as a side effect.
  All 8 call sites were checked and none needed RD's pre-doubled value
  afterward, but this is exactly the kind of implicit-clobber contract
  gotcha #10 warns is easy to get wrong at a *future* call site that isn't
  on this branch yet -- worth flagging in the routine's own header comment
  (already done) for whoever adds a 9th call site later.

## Hardware test checklist

EDLIN commands touched by this branch (all of them touch at least one of
the new shared helpers, since the helpers are used throughout the file):
**L, P, bare-number single-line edit, I, A, T, R, S, C, M, D, W, E, Q.**
Recommended order and specific edge cases, matching this project's own
established EDLIN bug history (empty buffer, single-line buffer, range
boundaries, no-match search have all been real historical bug sources):

1. **Start EDLIN with no filename / on a nonexistent file** -- confirms
   the empty-buffer path (bare-number edit, L, D, etc. all need to handle
   `ed_line_count==0` cleanly without touching `ed_lines[]` out of range).
2. **`I` (insert) a handful of lines**, including at least one that pushes
   the buffer's line-offset table across a page/cluster-adjacent size, and
   one line right up against the character-length cap.
3. **`L`** with no range (whole file), a single-line range `L n`, and a
   two-number range `L n1,n2` -- including `n1==n2` and a range that's
   exactly the first line or exactly the last line. **This section was
   rewritten after the 2026-08-24 design fix -- L/P's own default range
   now spans the rest of the buffer, not one page, and the pause is a
   real, visible `"Continue (Y/N)? "` prompt, not a silent any-key
   design.** On a file spanning several pages, confirm a BARE `L` (no
   args) shows a page centered on `cur_line` (starting `ed_page_lines/2`
   lines before it, clamped to line 1), pauses with the visible prompt
   once a full page has printed, and that typing `Y`/`y` correctly
   resumes printing the REMAINING lines through to the end of the
   buffer (not just one page) -- repeating through however many pauses
   the file needs. Confirm `N` (or any other key) stops immediately and
   updates `ed_cur_line` to whatever was last actually shown. Also
   specifically test an explicit two-number range spanning more than
   one page (e.g. `L 1,50` on a file with 50+ lines, `ed_page_lines`
   defaults to 23) the same way, and confirm a range whose last page is
   a PARTIAL page does NOT show a spurious extra pause/prompt after
   that final short batch.
4. **Bare-number single-line edit**: edit the *first* line, the *last*
   line, and (if buffer has exactly one line) the only line -- confirm
   Enter-alone leaves it unchanged and real replacement text works,
   including text that grows the line significantly.
5. **`P`** (page) -- same rewritten expectations as `L` above: a BARE
   `P` (no args) starts AT `cur_line` (not centered, that's `L`'s own
   distinction) and now also continues through the WHOLE REST OF THE
   BUFFER via the same visible `Y`/`N` pause, not just one page. Confirm
   a SECOND bare `P` run to completion, then invoked again right after,
   starts fresh from `cur_line`'s own now-advanced position (matching
   `ed_cur_line`'s update from the first run); and confirm a range
   ending at exactly the last line doesn't show a spurious pause/prompt
   with nothing left to continue to.
6. **`A`** (append, if present) with the file at/near buffer capacity, to
   exercise `ed_edit_toolong`'s consolidated "Buffer full." path.
7. **`T`** (transfer another file in) -- both a normal insert and a
   transfer into an empty buffer.
8. **`R`** (replace) with a range boundary at line 1 and at the last line,
   and a range spanning the whole buffer.
9. **`S`** (search) with: a match on the very first line, a match on the
   very last line, and **no match at all** (confirms
   `ed_num_range_err`'s and the search-not-found path's consolidated
   targets still print the right message and leave the buffer/cursor
   untouched).
10. **`C`** (copy) and **`M`** (move) with a single-line range, a range
    including the destination line itself (should be rejected or handled
    per existing semantics -- confirm unchanged from pre-branch behavior),
    and a range at each buffer boundary.
11. **`D`** (delete) a single line, a full range, and the very last
    remaining line (buffer should end at 0 lines cleanly, matching step 1
    in reverse).
12. **`W`**/**`E`** (write/exit) after each of the above, confirming the
    file on disk matches what the in-memory buffer should contain -- this
    is the ultimate cross-check that none of the word-copy/load/store
    consolidation silently shuffled a byte to the wrong address.
13. **`Q`** (quit without saving) after making unsaved edits, confirming
    the original on-disk file is untouched.
14. As a final regression pass: repeat a representative subset of the
    above back-to-back in one session (not one command per fresh EDLIN
    invocation) to exercise the shared helpers' register-liveness across
    consecutive, differently-shaped commands in the same run, not just in
    isolation.
