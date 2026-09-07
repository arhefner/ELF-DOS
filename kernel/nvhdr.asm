;
; nvhdr.asm - non-volatile kernel region header / placement marker
;
; Two jobs, both essential to the split memory model:
;
; 1. PLACEMENT. This file emits plain top-level (absolute) content at
;    NVK_BASE. Link/02 sets its placement cursor from an absolute
;    content line outside any proc, so listing this object between the
;    volatile objects and the code objects is what moves the linker
;    from the $0100 region to the NVK_BASE region -- every proc listed
;    after it lands in the non-volatile region. There is no ".org"
;    directive in Link/02; this is the mechanism.
;
;    (This is the same behaviour CLAUDE.md gotcha #20 warns about --
;    stray top-level data anchoring the link to an unintended address.
;    Here it is deliberate and load-bearing rather than accidental.)
;
; 2. SIGNATURE. krnboot reads these bytes at boot to decide whether the
;    non-volatile kernel is already present (ROM: signature matches,
;    nothing to load) or must be loaded from disk (RAM-only machine:
;    signature absent). Because it sits at NVK_BASE itself, ahead of
;    all code, the check is a fixed, known address on every machine.
;
; Keep this the FIRST non-volatile object in the link order, and keep
; nothing else in this file -- any extra content here shifts every
; code proc that follows.
;

#include    include/opcodes.def
#include    include/memmap.inc

            org     NVK_BASE
            db      'N','V','K'         ; 3-byte magic
            db      NVK_SIG_VER         ; non-volatile kernel version
