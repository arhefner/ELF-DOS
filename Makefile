#
# Makefile - ELF-DOS kernel build
#
# Targets:
#   all        build kernel-full.bin (default)
#   mbr        build mbr.bin only
#   install    build everything and write to disk (MBR + kernel)
#   update     build and write kernel only (MBR already installed)
#   progs      build every progs/*.asm into bin/<name> (bare, no
#              extension -- mirrors the on-device /bin layout exactly)
#   test       build every test/*.asm into test/bin/<name> -- diagnostic/
#              subsystem-exercising programs, kept out of bin/ entirely
#              so a normal install's /bin never includes them
#   everything all + mbr + progs + test. Use this after "make clean" --
#              a bare "make" rebuilds only the kernel, leaving bin/ and
#              mbr.bin missing. Does not build "sdk" (a release package,
#              not a build output)
#   sdk        package the external-developer SDK (headers, lib/
#              modules, Developer's Guide) into elfdos-sdk.tar.gz --
#              a self-contained download, no repo clone needed
#   clean      remove all generated files
#
# Override DEV on the command line to target a specific device:
#   make install DEV=/dev/sdb
#
# bin/ isn't installed by this Makefile -- copy its whole contents onto
# the FAT16 partition's /bin yourself, e.g. with mtools:
#   mcopy -i /dev/sdb@@1M bin/* ::BIN/
# (offset/partition number depend on your card's layout; see the
# partition table read out earlier in this project's history.)
#

ASM         = asm02
# -r (Asm/02, opt-in as of the 2026-07-21 toolchain update): long
# branches emit relax-aware ('!'/'#') fixups instead of the old-style
# ('?'/'+') ones that are now this assembler's own default without -r.
# Required for Link/02's own -r (below) to find anything to shrink --
# without this flag here, the kernel silently reverts to its
# pre-relaxation size (confirmed: +322 bytes, one per branch no longer
# eligible) even with LFLAGS' own -r still in effect, since link02 has
# nothing marked '#' to work with.
ASMFLAGS    = -L -C -I .. -r
LINK        = link02
# -r: short-branch relaxation (Link/02, opt-in). Only affects proc/endp
# -wrapped code (that's the only case where a long-branch target isn't
# already fully known at assemble time) -- kernel/*.asm uses proc/endp
# throughout and benefits; progs/*.asm is flat and sees zero effect,
# harmlessly. Needs ASMFLAGS' own -r above to have anything to shrink.
LFLAGS      = -b -be -r

DEV         = /dev/mmcblk0
SYS         = sys/elfdos-sys

# ---- Output files (all land in project root) ----
MBR_BIN     = mbr.bin
KRNBOOT_BIN = krnboot.bin
KERNEL_BIN  = kernel.bin
FULL_BIN    = kernel-full.bin

# ---- Kernel object files -- link order is LOAD-BEARING ----
#
# The kernel is ONE link producing TWO address regions (see
# include/memmap.inc). Order controls placement, because Link/02 has
# no ".org": an absolute content line outside any proc sets its
# placement cursor, and procs then lay out sequentially from there.
#
#   KVOL  volatile, RAM at $0100. kernel.prg leads with absolute
#         content at $0100 (EDF header + K_* jump table), then every
#         module's _*_data proc follows. kvolend.prg MUST stay last --
#         it marks the region's end for tools/split_kernel.py.
#
#   KNV   non-volatile, ROM-able at NVK_BASE. nvhdr.prg MUST stay
#         first -- its absolute "org NVK_BASE" is what moves the
#         linker into the second region. Everything after it is code.
#
# Cross-references between the regions resolve normally: it is a
# single link, so the jump table's "lbr file_open" reaches ROM and
# ROM code's "mov rf, bpb_spc" reaches RAM.
#
# Within KNV the original link order is preserved (kinit replaces
# kernel.asm's old code half).
KVOL =  kernel/kernel.prg       \
        kernel/kernel_data.prg  \
        kernel/fat_data.prg     \
        kernel/dir_data.prg     \
        kernel/path_data.prg    \
        kernel/rtc_data.prg     \
        kernel/file_data.prg    \
        kernel/loader_data.prg  \
        kernel/batch_data.prg   \
        kernel/redir_data.prg   \
        lib/modload_data.prg    \
        kernel/kvolend.prg

KNV  =  kernel/nvhdr.prg   \
        kernel/kinit.prg   \
        kernel/fat.prg     \
        kernel/dir.prg     \
        kernel/path.prg    \
        kernel/rtc.prg     \
        kernel/file.prg    \
        kernel/loader.prg  \
        kernel/batch.prg   \
        kernel/redir.prg   \
        lib/modload.prg    \
        lib/icall.prg

KOBJ =  $(KVOL) $(KNV)

# ---- Common include dependencies ----
INCS =  include/bios.inc    \
        include/opcodes.def \
        include/kernel.inc  \
        include/memmap.inc

# ---- User programs (progs/ subdir) ----
# template.asm is a starting point, not a program -- excluded here.
# Built executables land in bin/, bare-named (no extension), so bin/'s
# entire contents can be copied straight onto the card as /bin -- test/
# programs (below) are deliberately NOT part of this, so bin/ only ever
# holds what a normal install actually wants.
PROG_SRCS = $(filter-out progs/template.asm, $(wildcard progs/*.asm))
PROG_EXES = $(patsubst progs/%.asm,bin/%,$(PROG_SRCS))

# ---- Test/diagnostic programs (test/ subdir) ----
# Exercise a specific subsystem (a lib/ allocator, K_FILE_SEEK, etc.)
# rather than being something a normal install wants day to day --
# segregated from progs/ (2026-07-25) so bin/ stays install-only. Same
# bare-name build convention as progs/, just landing in test/bin/
# instead of bin/.
TEST_SRCS = $(wildcard test/*.asm)
TEST_EXES = $(patsubst test/%.asm,test/bin/%,$(TEST_SRCS))

.PHONY: all everything mbr install update progs test sdk clean

all: $(FULL_BIN)

#------------------------------------------------------------------
# Assembly rules
# asm02 places output alongside the source file, so .prg files
# live in the same directory as their .asm source.
# The cd ensures asm02 finds #include files via relative paths.
#------------------------------------------------------------------

boot/mbr.prg: boot/mbr.asm include/bios.inc include/opcodes.def
	cd boot && $(ASM) $(ASMFLAGS) mbr.asm

boot/krnboot.prg: boot/krnboot.asm $(INCS)
	cd boot && $(ASM) $(ASMFLAGS) krnboot.asm

kernel/kernel.prg: kernel/kernel.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) kernel.asm

kernel/kernel_data.prg: kernel/kernel_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) kernel_data.asm

kernel/fat_data.prg: kernel/fat_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) fat_data.asm

kernel/dir_data.prg: kernel/dir_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) dir_data.asm

kernel/path_data.prg: kernel/path_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) path_data.asm

kernel/rtc_data.prg: kernel/rtc_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) rtc_data.asm

kernel/file_data.prg: kernel/file_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) file_data.asm

kernel/loader_data.prg: kernel/loader_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) loader_data.asm

kernel/batch_data.prg: kernel/batch_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) batch_data.asm

kernel/redir_data.prg: kernel/redir_data.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) redir_data.asm

kernel/kinit.prg: kernel/kinit.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) kinit.asm

kernel/nvhdr.prg: kernel/nvhdr.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) nvhdr.asm

kernel/kvolend.prg: kernel/kvolend.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) kvolend.asm

lib/modload_data.prg: lib/modload_data.asm $(INCS) include/modformat.inc
	cd lib && $(ASM) $(ASMFLAGS) modload_data.asm

kernel/fat.prg: kernel/fat.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) fat.asm

kernel/dir.prg: kernel/dir.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) dir.asm

kernel/path.prg: kernel/path.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) path.asm

kernel/rtc.prg: kernel/rtc.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) rtc.asm

kernel/file.prg: kernel/file.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) file.asm

kernel/loader.prg: kernel/loader.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) loader.asm

kernel/batch.prg: kernel/batch.asm $(INCS) include/batchmod.inc
	cd kernel && $(ASM) $(ASMFLAGS) batch.asm

kernel/redir.prg: kernel/redir.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) redir.asm

# kernel/batch_mod.asm: the loadable batch-script module (2026-07-30
# phase 1) -- NOT part of KOBJ/kernel.bin. A standalone build, own
# fixed org ($D000, include/batchmod.inc), landing on disk as
# bin/batch.mod (deployed alongside every other bin/* file, loaded
# fresh into RAM by kernel/batch.asm's own dispatcher whenever a .bat
# script runs). See kernel/batch_mod.asm's own header comment for the
# full design. TEST-MACHINE-ONLY for now -- fixed load address, not
# yet relocatable.
kernel/batch_mod.prg: kernel/batch_mod.asm include/opcodes.def include/bios.inc include/kernel_api.inc include/batchmod.inc include/modformat.inc
	cd kernel && $(ASM) $(ASMFLAGS) batch_mod.asm

bin/batch.mod: kernel/batch_mod.prg | bin
	$(LINK) $(LFLAGS) -m -o bin/batch.mod kernel/batch_mod.prg
	rm -f bin/batch.lkb

# Programs are single-file: each progs/X.asm assembles and links on
# its own (no multi-module link order to worry about, unlike KOBJ).
progs/%.prg: progs/%.asm include/kernel_api.inc include/bios.inc include/opcodes.def
	cd progs && $(ASM) $(ASMFLAGS) $*.asm

bin:
	mkdir -p bin

bin/%: progs/%.prg | bin
	$(LINK) $(LFLAGS) -o bin/$* progs/$*.prg
	rm -f bin/$*.lkb

# test/ mirrors progs/'s own single-file assemble+link pattern exactly,
# just landing in test/bin/ instead of bin/ -- see TEST_SRCS/TEST_EXES
# above for why they're kept separate.
test/%.prg: test/%.asm include/kernel_api.inc include/bios.inc include/opcodes.def
	cd test && $(ASM) $(ASMFLAGS) $*.asm

test/bin:
	mkdir -p test/bin

test/bin/%: test/%.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/$* test/$*.prg
	rm -f test/bin/$*.lkb

#------------------------------------------------------------------
# Reusable libraries (lib/ subdir) -- NOT standalone programs, no EDF
# header/entry point of their own. Assembled separately and linked
# alongside whichever program wants them, same idea as the kernel's
# own multi-module KOBJ link. test/bumptest.asm and test/malloctest.asm
# (moved from progs/ 2026-07-25, see TEST_SRCS/TEST_EXES above) were the
# first consumers; progs/ls.asm (switched to heap_bump for its per-entry
# name storage, 2026-07-19) is the first REAL (non-test) one. See their
# own explicit link rules below, which override the generic
# "bin/%: progs/%.prg"/"test/bin/%: test/%.prg" pattern rules above for
# just those targets (GNU Make always prefers an explicit target-
# specific rule over a pattern rule that also matches).
#------------------------------------------------------------------
lib/heap_bump.prg: lib/heap_bump.asm include/opcodes.def
	cd lib && $(ASM) $(ASMFLAGS) heap_bump.asm

lib/heap_malloc.prg: lib/heap_malloc.asm include/opcodes.def
	cd lib && $(ASM) $(ASMFLAGS) heap_malloc.asm

lib/env.prg: lib/env.asm include/opcodes.def include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) env.asm

lib/move.prg: lib/move.asm include/opcodes.def include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) move.asm

lib/fmt32.prg: lib/fmt32.asm include/opcodes.def
	cd lib && $(ASM) $(ASMFLAGS) fmt32.asm

lib/drives.prg: lib/drives.asm include/opcodes.def include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) drives.asm

lib/file_glob.prg: lib/file_glob.asm include/opcodes.def include/bios.inc include/kernel_api.inc include/file_glob.inc
	cd lib && $(ASM) $(ASMFLAGS) file_glob.asm

lib/vollabel.prg: lib/vollabel.asm include/opcodes.def include/kernel_api.inc include/vollabel.inc
	cd lib && $(ASM) $(ASMFLAGS) vollabel.asm

lib/pathstr.prg: lib/pathstr.asm include/opcodes.def include/bios.inc include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) pathstr.asm

lib/ymodem.prg: lib/ymodem.asm include/opcodes.def include/bios.inc include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) ymodem.asm

lib/lineedit.prg: lib/lineedit.asm include/opcodes.def include/bios.inc include/kernel_api.inc include/lineedit.inc
	cd lib && $(ASM) $(ASMFLAGS) lineedit.asm

lib/pos32.prg: lib/pos32.asm include/opcodes.def
	cd lib && $(ASM) $(ASMFLAGS) pos32.asm

lib/src_file.prg: lib/src_file.asm include/opcodes.def include/bios.inc include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) src_file.asm

lib/pager.prg: lib/pager.asm include/opcodes.def include/bios.inc include/kernel_api.inc include/lineedit.inc
	cd lib && $(ASM) $(ASMFLAGS) pager.asm

lib/icall.prg: lib/icall.asm include/opcodes.def
	cd lib && $(ASM) $(ASMFLAGS) icall.asm

lib/modload.prg: lib/modload.asm include/opcodes.def include/bios.inc include/kernel_api.inc
	cd lib && $(ASM) $(ASMFLAGS) modload.asm

bin/dir: progs/dir.prg lib/fmt32.prg lib/file_glob.prg lib/vollabel.prg lib/pathstr.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/dir progs/dir.prg lib/fmt32.prg lib/file_glob.prg lib/vollabel.prg lib/pathstr.prg lib/drives.prg
	rm -f bin/dir.lkb

bin/label: progs/label.prg lib/vollabel.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/label progs/label.prg lib/vollabel.prg lib/drives.prg
	rm -f bin/label.lkb

bin/pwd: progs/pwd.prg lib/pathstr.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/pwd progs/pwd.prg lib/pathstr.prg lib/drives.prg
	rm -f bin/pwd.lkb

bin/del: progs/del.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/del progs/del.prg lib/file_glob.prg
	rm -f bin/del.lkb

bin/touch: progs/touch.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/touch progs/touch.prg lib/file_glob.prg
	rm -f bin/touch.lkb

bin/copy: progs/copy.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/copy progs/copy.prg lib/file_glob.prg
	rm -f bin/copy.lkb

bin/attrib: progs/attrib.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/attrib progs/attrib.prg lib/file_glob.prg
	rm -f bin/attrib.lkb

bin/stat: progs/stat.prg lib/fmt32.prg | bin
	$(LINK) $(LFLAGS) -o bin/stat progs/stat.prg lib/fmt32.prg
	rm -f bin/stat.lkb

bin/mount: progs/mount.prg lib/fmt32.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/mount progs/mount.prg lib/fmt32.prg lib/drives.prg
	rm -f bin/mount.lkb

bin/umount: progs/umount.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/umount progs/umount.prg lib/drives.prg
	rm -f bin/umount.lkb

bin/chkdsk: progs/chkdsk.prg lib/fmt32.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/chkdsk progs/chkdsk.prg lib/fmt32.prg lib/drives.prg
	rm -f bin/chkdsk.lkb

bin/printenv: progs/printenv.prg lib/env.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/printenv progs/printenv.prg lib/env.prg lib/drives.prg
	rm -f bin/printenv.lkb

bin/export: progs/export.prg lib/env.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/export progs/export.prg lib/env.prg lib/drives.prg
	rm -f bin/export.lkb

bin/unset: progs/unset.prg lib/env.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/unset progs/unset.prg lib/env.prg lib/drives.prg
	rm -f bin/unset.lkb

bin/xcopy: progs/xcopy.prg lib/heap_bump.prg | bin
	$(LINK) $(LFLAGS) -o bin/xcopy progs/xcopy.prg lib/heap_bump.prg
	rm -f bin/xcopy.lkb

test/bin/envtest: test/envtest.prg lib/env.prg lib/drives.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/envtest test/envtest.prg lib/env.prg lib/drives.prg
	rm -f test/bin/envtest.lkb

test/bin/bumptest: test/bumptest.prg lib/heap_bump.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/bumptest test/bumptest.prg lib/heap_bump.prg
	rm -f test/bin/bumptest.lkb

test/bin/malloctest: test/malloctest.prg lib/heap_malloc.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/malloctest test/malloctest.prg lib/heap_malloc.prg
	rm -f test/bin/malloctest.lkb

test/bin/big64test: test/big64test.prg lib/fmt32.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/big64test test/big64test.prg lib/fmt32.prg
	rm -f test/bin/big64test.lkb

test/bin/rwboundtest: test/rwboundtest.prg lib/fmt32.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/rwboundtest test/rwboundtest.prg lib/fmt32.prg
	rm -f test/bin/rwboundtest.lkb

test/bin/corrupt: test/corrupt.prg lib/ymodem.prg lib/fmt32.prg | test/bin
	$(LINK) $(LFLAGS) -o test/bin/corrupt test/corrupt.prg lib/ymodem.prg lib/fmt32.prg
	rm -f test/bin/corrupt.lkb

bin/ls: progs/ls.prg lib/heap_bump.prg lib/env.prg lib/file_glob.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/ls progs/ls.prg lib/heap_bump.prg lib/env.prg lib/file_glob.prg lib/drives.prg
	rm -f bin/ls.lkb

bin/edlin: progs/edlin.prg lib/env.prg lib/lineedit.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/edlin progs/edlin.prg lib/env.prg lib/lineedit.prg lib/drives.prg
	rm -f bin/edlin.lkb

bin/less: progs/less.prg lib/pager.prg lib/src_file.prg lib/pos32.prg lib/env.prg lib/lineedit.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/less progs/less.prg lib/pager.prg lib/src_file.prg lib/pos32.prg lib/env.prg lib/lineedit.prg lib/drives.prg
	rm -f bin/less.lkb

bin/shell: progs/shell.prg lib/env.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/shell progs/shell.prg lib/env.prg lib/drives.prg
	rm -f bin/shell.lkb

bin/move: progs/move.prg lib/move.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/move progs/move.prg lib/move.prg lib/file_glob.prg
	rm -f bin/move.lkb

bin/yr: progs/yr.prg lib/ymodem.prg lib/fmt32.prg | bin
	$(LINK) $(LFLAGS) -o bin/yr progs/yr.prg lib/ymodem.prg lib/fmt32.prg
	rm -f bin/yr.lkb

bin/ys: progs/ys.prg lib/ymodem.prg lib/fmt32.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/ys progs/ys.prg lib/ymodem.prg lib/fmt32.prg lib/file_glob.prg
	rm -f bin/ys.lkb

bin/termsize: progs/termsize.prg lib/ymodem.prg lib/fmt32.prg lib/env.prg lib/drives.prg | bin
	$(LINK) $(LFLAGS) -o bin/termsize progs/termsize.prg lib/ymodem.prg lib/fmt32.prg lib/env.prg lib/drives.prg
	rm -f bin/termsize.lkb

bin/mr: progs/mr.prg lib/fmt32.prg | bin
	$(LINK) $(LFLAGS) -o bin/mr progs/mr.prg lib/fmt32.prg
	rm -f bin/mr.lkb

bin/ms: progs/ms.prg lib/fmt32.prg lib/file_glob.prg | bin
	$(LINK) $(LFLAGS) -o bin/ms progs/ms.prg lib/fmt32.prg lib/file_glob.prg
	rm -f bin/ms.lkb

#------------------------------------------------------------------
# Link rules
#------------------------------------------------------------------

$(MBR_BIN): boot/mbr.prg
	$(LINK) $(LFLAGS) -o $(MBR_BIN) boot/mbr.prg

$(KRNBOOT_BIN): boot/krnboot.prg
	$(LINK) $(LFLAGS) -o $(KRNBOOT_BIN) boot/krnboot.prg

$(KERNEL_BIN): $(KOBJ)
	$(LINK) $(LFLAGS) -o $(KERNEL_BIN) $(KOBJ)
	python3 tools/check_kernel_margin.py

#------------------------------------------------------------------
# Build the final install image from the bootstrap and the two kernel
# regions. The kernel links as ONE file spanning both regions with a
# ~30K zero gap between them (see include/memmap.inc), so it cannot be
# written to disk as-is -- tools/split_kernel.py slices it at the
# kvol_end marker, pads the volatile half to a sector boundary, and
# concatenates krnboot + volatile + non-volatile, patching BOTH sector
# counts into krnboot's header as it goes.
#
# Layout of kernel-full.bin:
#   Bytes     0-1535:  krnboot.bin  (loads to $4600, entry at $4606;
#                       3 sectors = KRNBOOT_SECTORS as of the
#                       multi-sector krnboot expansion, up from 1)
#   Bytes 1536+:       kernel.bin   (loads to $0100, entry at $0106)
#
# sys patches the sector count into bytes 4-5 of krnboot before
# writing, so the bootstrap knows how many sectors follow it.
#------------------------------------------------------------------

KVOL_BIN    = kvol.bin
KNV_BIN     = knv.bin

$(FULL_BIN): $(KRNBOOT_BIN) $(KERNEL_BIN)
	python3 tools/split_kernel.py $(KERNEL_BIN) $(KVOL_BIN) $(KNV_BIN) \
		$(KRNBOOT_BIN) $(FULL_BIN) $(KOBJ)

#------------------------------------------------------------------
# Convenience targets
#------------------------------------------------------------------

mbr: $(MBR_BIN)

# Full install: write MBR boot code and kernel to disk.
# Use this when setting up a new disk or after changing the MBR.
install: $(FULL_BIN) $(MBR_BIN)
	$(SYS) -m $(MBR_BIN) -k $(FULL_BIN) $(DEV)

# Kernel-only update: MBR already on disk, just refresh the kernel.
# Faster for routine kernel development and testing cycles.
update: $(FULL_BIN)
	$(SYS) -k $(FULL_BIN) $(DEV)

# Build every progs/*.asm into bin/<name> (bare name, no extension --
# matches the on-device /bin layout). Not installed by this Makefile --
# see the note near the top of this file for getting bin/'s contents
# onto the FAT16 partition.
progs: $(PROG_EXES) bin/batch.mod

# Build every test/*.asm into test/bin/<name> -- same bare-name
# convention as progs/, deliberately never mixed into bin/ itself (see
# TEST_SRCS/TEST_EXES above).
test: $(TEST_EXES)

# Everything a running system needs: the kernel image, /bin, and the
# test programs.
#
# Exists because "clean" removes bin/ and test/bin/, while the default
# "all" target rebuilds only the kernel -- so a bare "make clean; make"
# leaves a tree with NO programs at all, and the next card you build
# has an empty /bin. That has now caught two separate sessions, in both
# cases with nothing obviously wrong to see; use this instead of "all"
# after any clean.
#
# Includes "mbr" as well: mbr.bin is an ordinary build output, not a
# packaging step, and a tree without it is incomplete in a way that
# bites immediately -- "install" needs it, and so does the emulator's
# mkdisk.sh, which reads $(MBR_BIN) straight out of this directory.
# Leaving it out meant "make clean; make everything" produced a tree
# you could not actually install or emulate from.
#
# Deliberately does NOT build "sdk": that packages a release tarball
# (elfdos-sdk.tar.gz) for external developers, which is a publishing
# step rather than part of building the system, and dropping a stale
# archive in the tree on every rebuild would be noise. Run "make sdk"
# when you actually want to cut one.
everything: all mbr progs test

#------------------------------------------------------------------
# SDK package -- a single self-contained elfdos-sdk.tar.gz a developer
# downloads and expands directly into their own project, with no git
# clone of ELF-DOS and no local "make sdk" step of their own required.
# Bundles the program-facing headers, every lib/ module (and its own
# companion .inc, where it has one), and the Developer's Guide, laid
# out under one top-level elfdos-sdk/ directory so extracting the
# archive can't dump loose include/lib/ dirs on top of whatever the
# consuming project already has at its own root. Preserves the
# include/+lib/ layout so consuming source can use the exact same
# "#include include/kernel_api.inc" convention this project's own
# progs/*.asm already do -- no path translation needed on the
# consumer's side. Ships SOURCE, never a prebuilt .prg/.bin: this
# toolchain's own .prg fixup-marker format has changed across Asm/02
# versions before (see CLAUDE.md's own toolchain gotchas), so a
# prebuilt artifact would be exactly the kind of cross-toolchain-
# version fragility this project has already been bitten by more than
# once. Deliberately does NOT include kernel.inc (kernel-internal only
# -- the whole reason kernel_api.inc exists as a separate, decoupled
# file) or the toolchain itself (asm02/link02 are already a shared,
# separately-installed system tool at /opt/elfc, independent of any
# one project).
#
# Pins to a COMMIT, not a version number -- there is no binary ABI
# stability guarantee yet (PROG_BASE alone has moved roughly 8 times
# in this project's history), so an external project rebuilds from
# source whenever it wants to move to a newer ELF-DOS revision;
# downloading a freshly re-packaged archive and re-vendoring its
# contents IS that "move to a newer revision" action, deliberate and
# visible in the consuming project's own git history, never automatic.
#
# Usage: make sdk                     -> elfdos-sdk.tar.gz
#        make sdk SDK_OUT=dist/x.tar.gz
#------------------------------------------------------------------
SDK_HEADERS = include/kernel_api.inc include/opcodes.def include/bios.inc

# lib/ modules considered part of the public SDK surface (see
# docs/DEVELOPER_GUIDE.md's own "Library Modules" table) -- their own
# companion .inc, where one exists, ships alongside. env/fmt32/
# heap_bump/heap_malloc/icall/move/pathstr have no companion .inc of
# their own.
SDK_LIB_MODULES = env file_glob fmt32 heap_bump heap_malloc icall \
                  lineedit modload move pathstr vollabel ymodem
SDK_LIB_ASM  = $(patsubst %,lib/%.asm,$(SDK_LIB_MODULES))
SDK_LIB_INCS = include/file_glob.inc include/lineedit.inc \
               include/modformat.inc include/vollabel.inc \
               include/ymodem.inc

SDK_NAME  = elfdos-sdk
SDK_OUT   = $(SDK_NAME).tar.gz
SDK_STAGE = build/sdk-stage
SDK_ROOT  = $(SDK_STAGE)/$(SDK_NAME)

sdk:
	rm -rf $(SDK_STAGE)
	mkdir -p $(SDK_ROOT)/include $(SDK_ROOT)/lib
	cp $(SDK_HEADERS) $(SDK_ROOT)/include/
	cp $(SDK_LIB_INCS) $(SDK_ROOT)/include/
	cp $(SDK_LIB_ASM) $(SDK_ROOT)/lib/
	cp docs/DEVELOPER_GUIDE.md $(SDK_ROOT)/
	@echo "ELF-DOS SDK snapshot"                                     >  $(SDK_ROOT)/MANIFEST.txt
	@echo "Packaged:       $$(date -u +%Y-%m-%dT%H:%M:%SZ)"          >> $(SDK_ROOT)/MANIFEST.txt
	@echo "ELF-DOS commit: $$(git rev-parse HEAD)"                   >> $(SDK_ROOT)/MANIFEST.txt
	@echo "Kernel version: $$(grep -m1 'KERNEL_VER_MAJOR:' kernel/kernel.asm | sed 's/.*equ *//').$$(grep -m1 'KERNEL_VER_MINOR:' kernel/kernel.asm | sed 's/.*equ *//')" >> $(SDK_ROOT)/MANIFEST.txt
	@echo "PROG_BASE:      $$(grep -m1 '^PROG_BASE:' include/kernel_api.inc | sed 's/.*equ *//' | awk '{print $$1}')" >> $(SDK_ROOT)/MANIFEST.txt
	@echo ""                                                         >> $(SDK_ROOT)/MANIFEST.txt
	@echo "Headers:"                                                 >> $(SDK_ROOT)/MANIFEST.txt
	@for f in $(SDK_HEADERS) $(SDK_LIB_INCS); do echo "  $$f" >> $(SDK_ROOT)/MANIFEST.txt; done
	@echo "Library modules (lib/):"                                  >> $(SDK_ROOT)/MANIFEST.txt
	@for m in $(SDK_LIB_MODULES); do echo "  $$m.asm" >> $(SDK_ROOT)/MANIFEST.txt; done
	@echo ""                                                         >> $(SDK_ROOT)/MANIFEST.txt
	@echo "DEVELOPER_GUIDE.md included -- see it for the full API reference." >> $(SDK_ROOT)/MANIFEST.txt
	@echo "Toolchain (asm02/link02) is NOT included -- see DEVELOPER_GUIDE.md's own Build section for install instructions." >> $(SDK_ROOT)/MANIFEST.txt
	tar -czf $(SDK_OUT) -C $(SDK_STAGE) $(SDK_NAME)
	rm -rf $(SDK_STAGE)
	@rmdir build 2>/dev/null || true
	@echo "SDK packaged to $(SDK_OUT)"

clean:
	rm -f boot/*.prg boot/*.lst \
	      kernel/*.prg kernel/*.lst \
	      progs/*.prg progs/*.lst progs/*.build progs/*.lkb \
	      test/*.prg test/*.lst test/*.build test/*.lkb \
	      $(MBR_BIN) $(KRNBOOT_BIN) $(KERNEL_BIN) $(FULL_BIN) \
	      $(KVOL_BIN) $(KNV_BIN) ksym.sym \
	      $(SDK_OUT)
	rm -rf test/bin
	rm -rf bin
	rm -rf build
