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
ASMFLAGS    = -L -C -I ..
LINK        = link02
# -r: short-branch relaxation (Link/02, opt-in). Only affects proc/endp
# -wrapped code (that's the only case where a long-branch target isn't
# already fully known at assemble time) -- kernel/*.asm uses proc/endp
# throughout and benefits; progs/*.asm is flat and sees zero effect,
# harmlessly.
LFLAGS      = -b -be -r

DEV         = /dev/mmcblk0
SYS         = sys/elfdos-sys

# ---- Output files (all land in project root) ----
MBR_BIN     = mbr.bin
KRNBOOT_BIN = krnboot.bin
KERNEL_BIN  = kernel.bin
FULL_BIN    = kernel-full.bin

# ---- Kernel object files (in kernel/ subdir, link order matters) ----
KOBJ =  kernel/kernel.prg  \
        kernel/bpb.prg     \
        kernel/fat.prg     \
        kernel/dir.prg     \
        kernel/path.prg    \
        kernel/rtc.prg     \
        kernel/file.prg    \
        kernel/loader.prg

# ---- Common include dependencies ----
INCS =  include/bios.inc    \
        include/opcodes.def \
        include/kernel.inc

# ---- User programs (progs/ subdir) ----
# template.asm is a starting point, not a program -- excluded here.
# Built executables land in bin/, bare-named (no extension), so bin/'s
# entire contents can be copied straight onto the card as /bin.
PROG_SRCS = $(filter-out progs/template.asm, $(wildcard progs/*.asm))
PROG_EXES = $(patsubst progs/%.asm,bin/%,$(PROG_SRCS))

.PHONY: all mbr install update progs clean

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

kernel/bpb.prg: kernel/bpb.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) bpb.asm

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

# Programs are single-file: each progs/X.asm assembles and links on
# its own (no multi-module link order to worry about, unlike KOBJ).
progs/%.prg: progs/%.asm include/kernel_api.inc include/bios.inc include/opcodes.def
	cd progs && $(ASM) $(ASMFLAGS) $*.asm

bin:
	mkdir -p bin

bin/%: progs/%.prg | bin
	$(LINK) $(LFLAGS) -o bin/$* progs/$*.prg
	rm -f bin/$*.lkb

#------------------------------------------------------------------
# Link rules
#------------------------------------------------------------------

$(MBR_BIN): boot/mbr.prg
	$(LINK) $(LFLAGS) -o $(MBR_BIN) boot/mbr.prg

$(KRNBOOT_BIN): boot/krnboot.prg
	$(LINK) $(LFLAGS) -o $(KRNBOOT_BIN) boot/krnboot.prg

$(KERNEL_BIN): $(KOBJ)
	$(LINK) $(LFLAGS) -o $(KERNEL_BIN) $(KOBJ)

#------------------------------------------------------------------
# Concatenate bootstrap + kernel proper into final install image.
#
# Layout of kernel-full.bin:
#   Bytes    0-511:  krnboot.bin  (loads to $3E00, entry at $3E06)
#   Bytes 512+:      kernel.bin   (loads to $0100, entry at $0106)
#
# sys patches the sector count into bytes 4-5 of krnboot before
# writing, so the bootstrap knows how many sectors follow it.
#------------------------------------------------------------------

$(FULL_BIN): $(KRNBOOT_BIN) $(KERNEL_BIN)
	cat $(KRNBOOT_BIN) $(KERNEL_BIN) > $(FULL_BIN)

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
progs: $(PROG_EXES)

clean:
	rm -f boot/*.prg boot/*.lst \
	      kernel/*.prg kernel/*.lst \
	      progs/*.prg progs/*.lst progs/*.build progs/*.lkb \
	      $(MBR_BIN) $(KRNBOOT_BIN) $(KERNEL_BIN) $(FULL_BIN)
	rm -rf bin
