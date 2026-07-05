#
# Makefile - ELF-DOS kernel build
#
# Targets:
#   all        build kernel-full.bin (default)
#   mbr        build mbr.bin only
#   install    build everything and write to disk (MBR + kernel)
#   update     build and write kernel only (MBR already installed)
#   clean      remove all generated files
#
# Override DEV on the command line to target a specific device:
#   make install DEV=/dev/sdb
#

ASM         = asm02
ASMFLAGS    = -L -C -I ..
LINK        = link02
LFLAGS      = -b -be

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
        kernel/file.prg    \
        kernel/loader.prg  \
        kernel/shell.prg

# ---- Common include dependencies ----
INCS =  include/bios.inc    \
        include/opcodes.def \
        include/kernel.inc

.PHONY: all mbr install update clean

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

kernel/file.prg: kernel/file.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) file.asm

kernel/loader.prg: kernel/loader.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) loader.asm

kernel/shell.prg: kernel/shell.asm $(INCS)
	cd kernel && $(ASM) $(ASMFLAGS) shell.asm

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
#   Bytes    0-511:  krnboot.bin  (loads to $3000, entry at $3006)
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

clean:
	rm -f boot/*.prg boot/*.lst \
	      kernel/*.prg kernel/*.lst \
	      $(MBR_BIN) $(KRNBOOT_BIN) $(KERNEL_BIN) $(FULL_BIN)
