;
; kernel.inc - ELF-DOS kernel shared definitions
;
; Include in every kernel source file with:
;   #include include/kernel.inc
;

; ----------------------------------------------------------------
; Memory layout
; ----------------------------------------------------------------
PROG_BASE:      equ     $2000       ; user programs load here

; ----------------------------------------------------------------
; Disk geometry
; ----------------------------------------------------------------
SECTOR_SIZE:    equ     $0200       ; 512 bytes per sector

; ----------------------------------------------------------------
; FAT16 cluster values
; ----------------------------------------------------------------
FAT_FREE:       equ     $0000       ; cluster is free
FAT_BAD:        equ     $FFF7       ; bad cluster marker
FAT_EOC:        equ     $FFF8       ; end-of-chain threshold (>= means EOC)

; ----------------------------------------------------------------
; FAT16 VBR / BPB field offsets
; All multi-byte BPB fields are little-endian on disk.
; ----------------------------------------------------------------
BPB_SPC:        equ     $0D         ; sectors per cluster (byte)
BPB_RSVD:       equ     $0E         ; reserved sector count (word)
BPB_NFAT:       equ     $10         ; number of FATs (byte)
BPB_ROOTENT:    equ     $11         ; root directory entry count (word)
BPB_SPF:        equ     $16         ; sectors per FAT (word)

; ----------------------------------------------------------------
; MBR partition table
; ----------------------------------------------------------------
PT_OFFSET:      equ     $01BE       ; partition table offset within MBR
PT_ENT_LEN:     equ     16          ; bytes per partition entry
PT_LBA_OFF:     equ     8           ; LBA start within entry (4 bytes, LE)

; ----------------------------------------------------------------
; LBA storage format (3 bytes, big-endian)
;
; LBAs are stored in memory as three consecutive bytes:
;   [0] = bits 23-16  -> loads into R8.0
;   [1] = bits 15-8   -> loads into R7.1
;   [2] = bits  7-0   -> loads into R7.0
;
; After loading, R8.1 must be set to 0 (drive/head) before
; calling f_ideread or f_idewrite.
;
; To load an LBA from [RF] into R7/R8:
;   lda  rf          ; D = bits 23-16
;   plo  r8          ;   -> R8.0
;   lda  rf          ; D = bits 15-8
;   phi  r7          ;   -> R7.1
;   lda  rf          ; D = bits 7-0
;   plo  r7          ;   -> R7.0
;   ldi  0
;   phi  r8          ; R8.1 = 0 (drive/head)
;
; To add a 16-bit offset (in RD) to an LBA already in R7/R8:
;   add16  r7, rd    ; R7 += RD, DF = carry out
;   glo    r8
;   adci   0         ; R8.0 += carry (ADCI 0 = D + 0 + DF)
;   plo    r8
; ----------------------------------------------------------------
LBA_SIZE:       equ     3           ; bytes per stored LBA

; ----------------------------------------------------------------
; FCB (File Control Block) structure offsets
;
; Each FCB is FCB_LEN bytes.  The kernel maintains FCB_COUNT
; FCBs in a static table (fcb_table).
;
; File size and position are stored as 4-byte big-endian values.
; On this 16K-64K machine the high words will normally be zero,
; but the full 32-bit fields keep the code correct for FAT16.
; ----------------------------------------------------------------
FCB_FLAGS:      equ     0           ; status byte (1 byte)
FCB_SCLUST:     equ     1           ; start cluster (2 bytes)
FCB_CCLUST:     equ     3           ; current cluster (2 bytes)
FCB_CSECT:      equ     5           ; sector index within current cluster (1 byte)
FCB_BOFF:       equ     6           ; byte offset within current sector (2 bytes)
FCB_FSIZE:      equ     8           ; file size in bytes (4 bytes, big-endian)
FCB_FPOS:       equ     12          ; current file position (4 bytes, big-endian)
FCB_LEN:        equ     16          ; total FCB size

; FCB flag bits
FCB_F_OPEN:     equ     $01         ; slot is in use
FCB_F_WRITE:    equ     $02         ; opened for writing
FCB_F_DIRTY:    equ     $04         ; io_buf holds data not yet written to disk

; Number of simultaneous open files
FCB_COUNT:      equ     3

; ----------------------------------------------------------------
; Path and drive conventions
; ----------------------------------------------------------------
PATH_SEP:       equ     '/'         ; directory separator character
DRIVE_FIRST:    equ     'C'         ; first hard-disk drive letter

; ----------------------------------------------------------------
; Directory entry result buffer (caller-provided, DIRENT_LEN bytes)
; ----------------------------------------------------------------
DIRENT_NAME:    equ     0           ; null-terminated filename (LFN_BUFLEN bytes)
DIRENT_ATTR:    equ     128         ; FAT attribute byte
DIRENT_CLUST:   equ     129         ; first cluster (2 bytes, big-endian)
DIRENT_SIZE:    equ     131         ; file size (4 bytes, big-endian)
DIRENT_LEN:     equ     135         ; total result buffer size

; ----------------------------------------------------------------
; FAT16 file attribute bits
; ----------------------------------------------------------------
ATTR_RDONLY:    equ     $01
ATTR_HIDDEN:    equ     $02
ATTR_SYSTEM:    equ     $04
ATTR_VOLID:     equ     $08
ATTR_DIR:       equ     $10
ATTR_ARCHIVE:   equ     $20
ATTR_LFN:       equ     $0F         ; combination that marks an LFN entry

; ----------------------------------------------------------------
; Raw 32-byte directory entry field offsets
; ----------------------------------------------------------------
DE_NAME:        equ     0           ; 8.3 name (11 bytes, space-padded)
DE_ATTR:        equ     11          ; attribute byte
DE_CLUSTER:     equ     26          ; first cluster low word (2 bytes, LE)
DE_SIZE:        equ     28          ; file size (4 bytes, LE)

; ----------------------------------------------------------------
; LFN entry field offsets (within the same 32-byte slot)
; ----------------------------------------------------------------
LFN_SEQ:        equ     0           ; sequence number
LFN_NAME1:      equ     1           ; chars 1-5  (10 bytes, UTF-16LE)
LFN_ATTR:       equ     11          ; attribute  (always ATTR_LFN = $0F)
LFN_CHKSUM:     equ     13          ; 8.3 short-name checksum
LFN_NAME2:      equ     14          ; chars 6-11 (12 bytes, UTF-16LE)
LFN_NAME3:      equ     28          ; chars 12-13 (4 bytes, UTF-16LE)

; ----------------------------------------------------------------
; LFN constants
; ----------------------------------------------------------------
LFN_LAST:       equ     $40         ; flag OR'd into seq# of last LFN entry
LFN_CHARS:      equ     13          ; Unicode chars per LFN entry
LFN_BUFLEN:     equ     128         ; max LFN chars we support (incl. null)

; ----------------------------------------------------------------
; Directory layout
; ----------------------------------------------------------------
DIR_ENT_SIZE:       equ     32      ; bytes per directory entry
DIR_ENT_PER_SEC:    equ     16      ; entries per 512-byte sector
