/*
 * sys.c - ELF-DOS host-side disk installer
 *
 * Installs ELF-DOS boot components onto an SD card or disk image.
 * Intended to be compiled and run on a Linux or Windows host to
 * bootstrap a new ELF-DOS disk or update an existing kernel.
 *
 * Two independent operations, either or both may be specified:
 *
 *   -m <mbr.bin>     Install MBR boot code.  Reads the existing
 *                    sector 0, replaces only the 446-byte boot code
 *                    area, and writes back.  The partition table and
 *                    boot signature are preserved.
 *
 *   -k <kernel.bin>  Install kernel.  Patches the sector count into
 *                    the bootstrap header (bytes 4-5, big-endian) and
 *                    writes all sectors to disk starting at LBA 1.
 *
 * Kernel binary layout (as produced by the ELF-DOS build):
 *   Bytes    0-511:  Bootstrap sector (runs at $3800 on target)
 *     Offset   0-2:  'KRN' magic signature
 *     Offset     3:  Kernel major version
 *     Offset   4-5:  Sector count word -- PATCHED HERE (big-endian)
 *     Offset   6+:   Bootstrap code + padding to 512 bytes
 *   Bytes  512+:     Kernel proper (runs at $0100 on target)
 *
 * Compiling:
 *   Linux/macOS:  gcc -o elfdos-sys sys.c
 *   Windows MSVC: cl sys.c /Fe:elfdos-sys.exe
 *   Windows MinGW: gcc -o elfdos-sys.exe sys.c
 *
 * Usage:
 *   Linux:   sudo ./elfdos-sys -m mbr.bin -k kernel.bin /dev/sdb
 *   Windows: elfdos-sys.exe -m mbr.bin -k kernel.bin \\.\PhysicalDrive1
 *
 * CAUTION: This utility writes directly to a raw block device.
 * Specifying the wrong device path will destroy data with no
 * possibility of recovery.  Always double-check the device path.
 *
 * Windows notes:
 *   - Must be run as Administrator.
 *   - For MBR installation use \\.\PhysicalDriveN (physical disk).
 *     \\.\X: addresses the partition VBR, not the MBR.
 *   - The target volume should be unmounted before writing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#define SECTOR_SIZE         512
#define MBR_CODE_SIZE       446     /* boot code area, before partition table */
#define MBR_PT_OFFSET       446     /* partition table starts here */
#define MBR_SIG_OFFSET      510     /* $55/$AA boot signature */
#define KERN_MAGIC_OFFSET   0       /* 'KRN' signature in bootstrap */
#define KERN_CNT_OFFSET     4       /* sector count (big-endian word) */

/* ================================================================
 * Platform-specific raw disk I/O
 * ================================================================ */

#ifdef _WIN32
#include <windows.h>

typedef HANDLE  disk_t;
#define DISK_INVALID    INVALID_HANDLE_VALUE

static disk_t disk_open(const char *path) {
    /*
     * FILE_FLAG_NO_BUFFERING is required for raw sector-aligned I/O
     * on Windows physical drives.  FILE_FLAG_WRITE_THROUGH ensures
     * writes reach the device before the call returns.
     */
    HANDLE h = CreateFileA(path,
                           GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL,
                           OPEN_EXISTING,
                           FILE_FLAG_WRITE_THROUGH | FILE_FLAG_NO_BUFFERING,
                           NULL);
    return h;
}

static int disk_read_sector(disk_t disk, uint32_t lba, uint8_t *buf) {
    LARGE_INTEGER pos;
    DWORD n;
    pos.QuadPart = (LONGLONG)lba * SECTOR_SIZE;
    if (!SetFilePointerEx(disk, pos, NULL, FILE_BEGIN)) return -1;
    if (!ReadFile(disk, buf, SECTOR_SIZE, &n, NULL))    return -1;
    return (n == SECTOR_SIZE) ? 0 : -1;
}

static int disk_write_sector(disk_t disk, uint32_t lba, const uint8_t *buf) {
    LARGE_INTEGER pos;
    DWORD n;
    pos.QuadPart = (LONGLONG)lba * SECTOR_SIZE;
    if (!SetFilePointerEx(disk, pos, NULL, FILE_BEGIN))   return -1;
    if (!WriteFile(disk, buf, SECTOR_SIZE, &n, NULL))     return -1;
    return (n == SECTOR_SIZE) ? 0 : -1;
}

static void disk_close(disk_t disk) {
    CloseHandle(disk);
}

static void print_os_error(const char *ctx) {
    char msg[256];
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, GetLastError(), 0, msg, sizeof(msg), NULL);
    /* strip trailing newline that FormatMessage sometimes adds */
    size_t len = strlen(msg);
    while (len && (msg[len-1] == '\r' || msg[len-1] == '\n')) msg[--len] = 0;
    fprintf(stderr, "%s: %s\n", ctx, msg);
}

#else   /* Linux / macOS / POSIX */

#include <fcntl.h>
#include <unistd.h>

typedef int     disk_t;
#define DISK_INVALID    (-1)

static disk_t disk_open(const char *path) {
    return open(path, O_RDWR);
}

static int disk_read_sector(disk_t disk, uint32_t lba, uint8_t *buf) {
    off_t   off = (off_t)lba * SECTOR_SIZE;
    ssize_t n   = pread(disk, buf, SECTOR_SIZE, off);
    return (n == SECTOR_SIZE) ? 0 : -1;
}

static int disk_write_sector(disk_t disk, uint32_t lba, const uint8_t *buf) {
    off_t   off = (off_t)lba * SECTOR_SIZE;
    ssize_t n   = pwrite(disk, buf, SECTOR_SIZE, off);
    return (n == SECTOR_SIZE) ? 0 : -1;
}

static void disk_close(disk_t disk) {
    close(disk);
}

static void print_os_error(const char *ctx) {
    fprintf(stderr, "%s: %s\n", ctx, strerror(errno));
}

#endif  /* platform */

/* ================================================================
 * File utilities
 * ================================================================ */

/*
 * read_file_alloc: read an entire binary file into a malloc'd buffer.
 * Sets *size on success.  Returns NULL on error (error already printed).
 * Caller is responsible for free().
 */
static uint8_t *read_file_alloc(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Cannot open '%s': %s\n", path, strerror(errno));
        return NULL;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        fprintf(stderr, "'%s': seek failed\n", path);
        fclose(f);
        return NULL;
    }

    long len = ftell(f);
    rewind(f);

    if (len <= 0) {
        fprintf(stderr, "'%s': file is empty or unreadable\n", path);
        fclose(f);
        return NULL;
    }

    uint8_t *buf = malloc((size_t)len);
    if (!buf) {
        fprintf(stderr, "Out of memory reading '%s'\n", path);
        fclose(f);
        return NULL;
    }

    if (fread(buf, 1, (size_t)len, f) != (size_t)len) {
        fprintf(stderr, "'%s': read error\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }

    fclose(f);
    *size = (size_t)len;
    return buf;
}

/* ================================================================
 * MBR installation
 *
 * Reads existing sector 0, replaces the 446-byte boot code region
 * with the new code (zero-padded if smaller), restores the existing
 * partition table and ensures the $55/$AA signature is present, then
 * writes the modified sector back.
 * ================================================================ */
static int install_mbr(disk_t disk, const char *mbr_path) {
    size_t   mbr_size;
    uint8_t *mbr_bin = read_file_alloc(mbr_path, &mbr_size);
    if (!mbr_bin) return -1;

    /* verify this looks like our MBR binary */
    if (mbr_size < 6 || memcmp(mbr_bin, "MBR", 3) != 0) {
        fprintf(stderr,
            "'%s': missing 'MBR' signature at offset 0.\n"
            "       Is this the correct file?\n", mbr_path);
        free(mbr_bin);
        return -1;
    }
    if (mbr_size > MBR_CODE_SIZE) {
        fprintf(stderr,
            "'%s': boot code is %zu bytes but the boot code area is only %d bytes.\n",
            mbr_path, mbr_size, MBR_CODE_SIZE);
        free(mbr_bin);
        return -1;
    }

    /* read the existing sector 0 so we can preserve the partition table */
    uint8_t sector[SECTOR_SIZE];
    printf("  Reading existing sector 0...\n");
    if (disk_read_sector(disk, 0, sector) != 0) {
        print_os_error("  Read sector 0 failed");
        free(mbr_bin);
        return -1;
    }

    int had_sig = (sector[510] == 0x55 && sector[511] == 0xAA);
    if (had_sig) {
        printf("  Existing boot signature found -- partition table will be preserved.\n");
    } else {
        printf("  No boot signature in sector 0 -- partition table area will be zeroed.\n");
    }

    /* replace boot code area, preserve partition table and signature */
    memset(sector, 0, MBR_CODE_SIZE);          /* zero boot code region */
    memcpy(sector, mbr_bin, mbr_size);          /* install new code      */
    sector[510] = 0x55;                         /* ensure signature      */
    sector[511] = 0xAA;

    printf("  Writing new MBR boot code (%zu bytes)...\n", mbr_size);
    if (disk_write_sector(disk, 0, sector) != 0) {
        print_os_error("  Write sector 0 failed");
        free(mbr_bin);
        return -1;
    }

    free(mbr_bin);
    printf("  MBR installed.\n");
    return 0;
}

/* ================================================================
 * Kernel installation
 *
 * Verifies the 'KRN' signature, computes the number of kernel-proper
 * sectors (all sectors after the first bootstrap sector), patches the
 * big-endian sector count word at offset 4-5 of the binary, and
 * writes all sectors to LBA 1 onwards.
 * ================================================================ */
static int install_kernel(disk_t disk, const char *kern_path) {
    size_t   kern_size;
    uint8_t *kern_bin = read_file_alloc(kern_path, &kern_size);
    if (!kern_bin) return -1;

    /* verify this looks like our kernel binary */
    if (kern_size < SECTOR_SIZE || memcmp(kern_bin, "KRN", 3) != 0) {
        fprintf(stderr,
            "'%s': missing 'KRN' signature at offset 0 or file < 512 bytes.\n"
            "       Is this the correct file?\n", kern_path);
        free(kern_bin);
        return -1;
    }

    /*
     * Compute number of additional sectors (kernel proper) after the
     * 512-byte bootstrap sector.  Uses ceiling division:
     *
     *   extra = ceil((kern_size - 512) / 512)
     *
     * Equivalent to:  (kern_size - 1) / 512  for kern_size >= 512.
     * (Both give 0 when kern_size == 512, i.e. bootstrap only.)
     */
    uint32_t total_sectors = (uint32_t)((kern_size + SECTOR_SIZE - 1) / SECTOR_SIZE);
    uint32_t extra_sectors = total_sectors - 1;

    if (extra_sectors > 0xFFFF) {
        fprintf(stderr,
            "'%s': kernel requires %u sectors, maximum is 65535.\n",
            kern_path, extra_sectors);
        free(kern_bin);
        return -1;
    }

    /* patch the bootstrap header with the sector count (big-endian) */
    kern_bin[KERN_CNT_OFFSET]     = (uint8_t)(extra_sectors >> 8);
    kern_bin[KERN_CNT_OFFSET + 1] = (uint8_t)(extra_sectors & 0xFF);

    printf("  File size   : %zu bytes\n",    kern_size);
    printf("  Total sectors: %u (bootstrap 1 + kernel proper %u)\n",
           total_sectors, extra_sectors);
    printf("  Sector count patched into header: %u ($%04X)\n",
           extra_sectors, extra_sectors);

    /* write sectors to LBA 1, 2, 3 ... */
    uint8_t sector[SECTOR_SIZE];
    for (uint32_t i = 0; i < total_sectors; i++) {
        size_t src_off = (size_t)i * SECTOR_SIZE;
        size_t avail   = (kern_size > src_off) ? (kern_size - src_off) : 0;
        size_t copy    = (avail < SECTOR_SIZE) ? avail : SECTOR_SIZE;

        memset(sector, 0, SECTOR_SIZE);             /* zero-pad short sector */
        if (copy) memcpy(sector, kern_bin + src_off, copy);

        uint32_t lba = i + 1;
        printf("  Writing sector %u to LBA %u...\n", i, lba);
        if (disk_write_sector(disk, lba, sector) != 0) {
            print_os_error("  Write failed");
            free(kern_bin);
            return -1;
        }
    }

    free(kern_bin);
    printf("  Kernel installed (%u sector(s) written to LBA 1-%u).\n",
           total_sectors, total_sectors);
    return 0;
}

/* ================================================================
 * Argument parsing and entry point
 * ================================================================ */
static void usage(const char *prog) {
    fprintf(stderr,
        "ELF-DOS host-side disk installer\n"
        "\n"
        "Usage: %s [options] <device>\n"
        "\n"
        "Options:\n"
        "  -m <mbr.bin>      Install MBR boot code (preserves partition table)\n"
        "  -k <kernel.bin>   Install kernel binary  (writes to LBA 1+)\n"
        "  -y                Skip confirmation prompt\n"
        "\n"
        "At least one of -m or -k must be given.\n"
        "\n"
        "Examples:\n"
#ifdef _WIN32
        "  %s -m mbr.bin -k kernel.bin \\\\.\\PhysicalDrive1\n"
        "  %s -k kernel.bin \\\\.\\PhysicalDrive1\n"
        "\n"
        "Note: must be run as Administrator.\n"
        "      Use \\\\.\\PhysicalDriveN for MBR access, not a drive letter.\n"
#else
        "  sudo %s -m mbr.bin -k kernel.bin /dev/sdb\n"
        "  sudo %s -k kernel.bin /dev/sdb\n"
        "\n"
        "Note: requires read/write access to the raw device.\n"
        "      Use lsblk or dmesg to identify the correct device.\n"
#endif
        "\n"
        "CAUTION: writes directly to a raw block device.\n"
        "         Wrong device = immediate, unrecoverable data loss.\n",
        prog
#ifdef _WIN32
        , prog, prog
#else
        , prog, prog
#endif
    );
}

int main(int argc, char *argv[]) {
    const char *mbr_path  = NULL;
    const char *kern_path = NULL;
    const char *device    = NULL;
    int         yes       = 0;      /* skip confirmation if -y given */

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            mbr_path = argv[++i];
        } else if (strcmp(argv[i], "-k") == 0 && i + 1 < argc) {
            kern_path = argv[++i];
        } else if (strcmp(argv[i], "-y") == 0) {
            yes = 1;
        } else if (argv[i][0] != '-') {
            if (device) {
                fprintf(stderr, "Error: multiple device paths given.\n\n");
                usage(argv[0]);
                return 1;
            }
            device = argv[i];
        } else {
            fprintf(stderr, "Unknown option: %s\n\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!device || (!mbr_path && !kern_path)) {
        usage(argv[0]);
        return 1;
    }

    /* print a summary and confirm before touching the disk */
    printf("ELF-DOS installer\n");
    printf("  Device : %s\n", device);
    if (mbr_path)  printf("  MBR    : %s\n", mbr_path);
    if (kern_path) printf("  Kernel : %s\n", kern_path);
    printf("\n");

    if (!yes) {
        printf("WARNING: This will write directly to %s.\n", device);
        printf("Proceed? [y/N] ");
        fflush(stdout);
        char ans[8] = {0};
        if (!fgets(ans, sizeof(ans), stdin) ||
            (ans[0] != 'y' && ans[0] != 'Y')) {
            printf("Aborted.\n");
            return 1;
        }
        printf("\n");
    }

    disk_t disk = disk_open(device);
    if (disk == DISK_INVALID) {
        print_os_error(device);
        return 1;
    }

    int result = 0;

    if (mbr_path) {
        printf("--- Installing MBR ---\n");
        if (install_mbr(disk, mbr_path) != 0) result = 1;
        printf("\n");
    }

    if (kern_path && result == 0) {
        printf("--- Installing kernel ---\n");
        if (install_kernel(disk, kern_path) != 0) result = 1;
        printf("\n");
    }

    disk_close(disk);

    printf(result == 0 ? "Done.\n" : "Installation FAILED.\n");
    return result;
}
