;
; fat_data.asm - volatile (RAM-resident) data for fat.asm
;
; Split out of fat.asm for the split memory model (volatile RAM data at
; $0100, non-volatile ROM-able code at NVK_BASE). Every symbol here is
; already reached through extrn/public by its owning module, so moving
; the proc between files changes nothing about how it is referenced --
; only where the linker places it.
;
; Do NOT move these back inline: the linker lays procs out sequentially
; in command-line/source order, so a data proc sharing a .prg with code
; would land in the ROM region with that code.
;

#include    include/opcodes.def
#include    include/kernel.inc


; ----------------------------------------------------------------
; _fat_load_sector's own scratch: the cluster number it was called
; with, kept across its internal fat_flush/f_ideread calls.
;
; BUG FIX: this used to live in R9 ("mov r9, rd" at _fat_load_sector's
; entry) -- but R9 is relied upon by a caller several levels further
; up the stack: dir_read stashes its own caller's result-buffer
; pointer in R9 across its internal call to _dir_next_sector (see
; dir.asm), and _dir_next_sector's own cluster-chain-follow path
; (dns_subdir) calls fat_get, which calls THIS routine. Nothing in
; that chain's own documented Args/Returns mentions R9, so the clobber
; was completely invisible from any single routine's own contract --
; classic gotcha #10 (a callee's "obviously scratch" register turns
; out to be exactly what a distant caller depends on surviving).
; Confirmed on hardware (2026-07-10): every directory scan that
; crossed a cluster boundary (forcing exactly one fat_get call) wrote
; the NEXT decoded entry's attr/cluster/size fields to a garbage
; address computed from the FAT cluster number instead of the real
; result buffer -- which for a scan on this card's test directory
; (cluster $10) computed to address $0090, squarely inside LINE_BUF
; ($0080-$00FF), silently corrupting the shell's own command-line
; buffer. Moved to memory instead of a register specifically so this
; class of "unrelated distant caller relies on this register" bug
; can't recur here regardless of what any future caller happens to
; keep in a register across a call into this routine.
            proc    _fat_data

fls_cluster:    dw      0

; ffl_sector_idx: fat_flush's own scratch (see its own BUG FIX note) --
; same fix, same reason: fat_flush is called from INSIDE
; _fat_load_sector's fls_load branch (cache dirty case), which sits in
; the exact same dir_read -> _dir_next_sector -> fat_get ->
; _fat_load_sector -> fat_flush chain that made R9 unsafe above. Not
; yet observed to misfire on hardware (the test scans that exposed the
; fls_cluster bug happened to hit a clean cache), but the mechanism is
; identical and would trigger under the right timing (a scan crossing
; a cluster boundary shortly after a write left the FAT cache dirty) --
; fixed proactively rather than waiting for a second hardware failure.
ffl_sector_idx: db      0

; fat_next_free: fat_alloc's "next-fit" search hint -- the cluster to
; start its next scan from, instead of always restarting at cluster 2.
; See fat_alloc's own header for why the always-restart design was a
; real, measured performance problem. Initialized by fat_init (below);
; kept in memory (not a register) since it must survive across every
; call into this file between one fat_alloc and the next.
fat_next_free:  dw      0

; FAT12 support (PROTOTYPE). bpb_fat16 is derived by _switch_drive from
; bpb_max_clust whenever a drive becomes active -- not stored per drive,
; so drive_bpb_table's layout and every published offset are unchanged.
; Initialised to 1 so anything reaching the FAT before the first switch
; behaves exactly as it always has. f12_clust_hi is fat_set's scratch:
; _fat_load_sector hands RD back with RD.1 = FAT sector index, so the
; cluster's high byte has to be put back from memory.
bpb_fat16:      db      1

; fat_cache_drive: which drive the sector in fat_cache belongs to, or
; $FF for none. _switch_drive uses it to keep a still-valid cache across
; a switch instead of dropping it -- see its own header.
fat_cache_drive: db     $FF
f12_clust_hi:   db      0

                public  fls_cluster
                public  ffl_sector_idx
                public  fat_next_free
                public  bpb_fat16
                public  fat_cache_drive
                public  f12_clust_hi

                endp
