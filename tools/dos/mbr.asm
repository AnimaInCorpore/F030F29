; Minimal MBR chain-loader for img/uw.hdd.
;
; Relocates itself 0000:7C00 -> 0000:0600, finds the active partition entry,
; loads its boot sector back to 0000:7C00 and jumps to it with DL = BIOS drive
; and DS:SI -> the partition entry (what MS-DOS boot records expect).
;
; Reads via INT 13h AH=42h (LBA) when the BIOS advertises extensions, else via
; INT 13h AH=02h using the CHS in the partition entry.  The LBA path is what
; makes this geometry-proof: an earlier hand-assembled CHS-only MBR broke
; because its baked-in 18/2 geometry did not match QEMU's translation.
;
; Build: nasm -f bin work/mbr.asm -o work/img_build/mbr.bin   (must be <= 446 B)

                bits    16
                org     0x0600

RELOC           equ     0x0600
LOAD            equ     0x7C00

start:
                cli
                xor     ax, ax
                mov     ds, ax
                mov     es, ax
                mov     ss, ax
                mov     sp, LOAD
                sti
                cld
                mov     si, LOAD                ; relocate 512 B down to 0x600
                mov     di, RELOC
                mov     cx, 256
                rep     movsw
                jmp     0:relocated

relocated:
                mov     [drive], dl             ; BIOS boot drive from firmware
                mov     si, RELOC + 0x1BE       ; first partition entry
                mov     cx, 4
.scan:
                cmp     byte [si], 0x80         ; active?
                je      .found
                add     si, 16
                loop    .scan
                mov     si, msg_nopart
                jmp     fail
.found:
                mov     ax, [si + 8]            ; start LBA (low word)
                mov     [dap_lba], ax
                mov     ax, [si + 10]           ; start LBA (high word)
                mov     [dap_lba + 2], ax

                ; --- INT 13h extensions present? ---
                mov     ah, 0x41
                mov     bx, 0x55AA
                mov     dl, [drive]
                int     0x13
                jc      chs_read
                cmp     bx, 0xAA55
                jne     chs_read
                test    cl, 1                   ; bit 0 = packet access supported
                jz      chs_read

                mov     ah, 0x42
                mov     dl, [drive]
                push    si                      ; SI must survive: the VBR wants it
                mov     si, dap
                int     0x13
                pop     si
                jnc     verify
                ; fall through to CHS on any LBA error

chs_read:
                mov     dh, [si + 1]            ; head
                mov     cx, [si + 2]            ; CL = sector|cyl-hi, CH = cyl-lo
                mov     dl, [drive]
                mov     bx, LOAD
                mov     ax, 0x0201              ; read 1 sector
                int     0x13
                jc      .err
                jmp     verify
.err:
                mov     si, msg_ioerr
                jmp     fail

verify:
                cmp     word [LOAD + 510], 0xAA55
                jne     .bad
                mov     dl, [drive]             ; hand off: DL = drive, DS:SI = entry
                jmp     0:LOAD
.bad:
                mov     si, msg_nosig
                ; fall through

fail:
                lodsb
                or      al, al
                jz      .halt
                mov     ah, 0x0E
                mov     bx, 0x0007
                int     0x10
                jmp     fail
.halt:
                hlt
                jmp     .halt

; --- INT 13h AH=42h disk address packet -------------------------------------
                align   4
dap:
                db      0x10                    ; packet size
                db      0                       ; reserved
                dw      1                       ; sectors to transfer
                dw      LOAD                    ; buffer offset
                dw      0                       ; buffer segment
dap_lba:
                dd      0                       ; LBA low
                dd      0                       ; LBA high

drive:          db      0x80

msg_nopart:     db      'No active partition', 13, 10, 0
msg_ioerr:      db      'Disk read error', 13, 10, 0
msg_nosig:      db      'No boot signature', 13, 10, 0

                times   446 - ($ - $$) db 0
