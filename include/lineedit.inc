;
; lineedit.inc - mode constants for lib/lineedit.asm's read_line_ex,
; shared between the library and any consuming program (progs/edlin.asm
; being the first). An equ is a pure assemble-time constant, not a real
; linked symbol, so it's safe to #include from multiple files that get
; linked together (unlike a db/dw variable, which would collide) --
; matches how include/kernel_api.inc's own constants are shared.
;

LE_MODE_FAST:   equ     0       ; read_line_ex: f_uread directly, byte-
                                ; drop-safe for live typed escape
                                ; sequences, but can never see
                                ; redirected input -- always DF=0.
LE_MODE_REDIR:  equ     1       ; read_line_ex: K_READ (redirect-aware
                                ; via the kernel's own _redir_read),
                                ; may return DF=1 at EOF, but subject
                                ; to K_READ's own latency-driven byte-
                                ; drop risk on a fast live arrow-key
                                ; sequence.
