; 256-byte-vm
;
; Produces a 256-byte program at boot.bin. The disk-image build step wraps
; it in a 512-byte sector with the 0x55AA MBR signature at offset 510 so
; raw/qcow2/vdi/vmdk/vhd are bootable. The ISO embeds boot.bin verbatim
; via El Torito no-emulation; BIOS pulls in 512 bytes from the disc and
; jumps to 0x7C00, where our code sits at byte 0.
;
; Memory map at runtime:
;   0x7C00..0x7CFF  this program (256 bytes)
;   0x7E00..0x7E4F  line buffer (LINE_MAX bytes)

[BITS 16]
[ORG 0x7C00]

; ACPI PM1a registers. Modern QEMU (and SeaBIOS) programs PMBASE to 0x0600
; on both i440fx (Proxmox default) and Q35, so a single set of ports covers
; both machine types.
PM1A_STS        equ 0x0600
PM1A_EN         equ 0x0602
PM1A_CNT        equ 0x0604
PWRBTN_EN       equ 0x0100      ; gates PWRBTN_STS latching in QEMU
PWRBTN_STS      equ 0x0100      ; latches on guest power-button event
SLP_EN_S5       equ 0x2000      ; SLP_EN bit, SLP_TYP=0 -> S5 on QEMU

COM1            equ 0x3F8
COM1_DLM        equ COM1 + 1
COM1_FCR        equ COM1 + 2
COM1_LCR        equ COM1 + 3
COM1_MCR        equ COM1 + 4
COM1_LSR        equ COM1 + 5

LINE_BUF        equ 0x7E00
LINE_MAX        equ 80

start:
    ; Zero segment registers, set stack just below the boot sector.
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00

    ; Configure COM1 for 9600 8N1, no FIFO, DTR+RTS+OUT2 asserted.
    mov     dx, COM1_LCR
    mov     al, 0x80            ; set DLAB to access divisor latch
    out     dx, al
    mov     dx, COM1
    mov     al, 12              ; divisor 12 -> 115200/12 = 9600 baud
    out     dx, al
    mov     dx, COM1_DLM
    xor     al, al
    out     dx, al
    mov     dx, COM1_LCR
    mov     al, 0x03            ; 8 data bits, no parity, 1 stop, DLAB off
    out     dx, al
    mov     dx, COM1_FCR
    xor     al, al              ; disable FIFO
    out     dx, al
    mov     dx, COM1_MCR
    mov     al, 0x0B            ; DTR + RTS + OUT2 (OUT2 gates IRQ to PIC)
    out     dx, al

    ; Enable the ACPI power-button event source. QEMU only latches
    ; PWRBTN_STS on `system_powerdown` (what `qm shutdown` issues) when
    ; PWRBTN_EN is set.
    mov     dx, PM1A_EN
    mov     ax, PWRBTN_EN
    out     dx, ax

    sti

    ; Print the banner, then show the first input prompt.
    mov     si, msg
.banner:
    lodsb
    test    al, al
    jz      .first_prompt
    call    put_char
    jmp     .banner

.first_prompt:
    call    print_prompt
    mov     di, LINE_BUF

; Main loop: each pass checks for an ACPI shutdown request, then drains one
; serial RX byte if available. HLT parks the CPU until the BIOS timer IRQ 0
; wakes us (~18 Hz), keeping host CPU usage near zero.
.main:
    mov     dx, PM1A_STS
    in      ax, dx
    test    ax, PWRBTN_STS
    jnz     .off

    ; Serial RX poll: bit 0 of LSR is set when a byte is in the receive
    ; buffer. If nothing arrived, idle until the next timer tick.
    mov     dx, COM1_LSR
    in      al, dx
    test    al, 0x01
    jz      .idle

    ; Consume one received byte.
    mov     dx, COM1
    in      al, dx

    ; CR or LF terminates the line and triggers the reverse-echo path.
    cmp     al, 13
    je      .endline
    cmp     al, 10
    je      .endline

    ; Append to the line buffer unless it is already full. Either way,
    ; echo the byte so the typist sees what they typed.
    cmp     di, LINE_BUF + LINE_MAX
    jae     .echo_only
    mov     [di], al
    inc     di
.echo_only:
    call    put_char
    jmp     .main

.idle:
    hlt
    jmp     .main

.endline:
    ; Move to a new line, then walk the buffer back-to-front emitting each
    ; byte. SI starts at the current write position (one past the last
    ; stored byte) and stops once it reaches the buffer start.
    mov     al, 13
    call    put_char
    mov     al, 10
    call    put_char

    mov     si, di
.reverse:
    cmp     si, LINE_BUF
    jbe     .reverse_done
    dec     si
    mov     al, [si]
    call    put_char
    jmp     .reverse
.reverse_done:
    mov     al, 13
    call    put_char
    mov     al, 10
    call    put_char

    ; Show the prompt and reset the buffer for the next line.
    call    print_prompt
    mov     di, LINE_BUF
    jmp     .main

; ACPI soft-off: write SLP_EN with SLP_TYP=0 into PM1a_CNT. On QEMU this
; transitions the guest to S5 and the hypervisor stops the VM cleanly.
.off:
    mov     dx, PM1A_CNT
    mov     ax, SLP_EN_S5
    out     dx, ax
.dead:
    cli
    hlt
    jmp     .dead

; print_prompt: emit "$ " to both outputs.
print_prompt:
    mov     al, '$'
    call    put_char
    mov     al, ' '
    call    put_char
    ret

; put_char: write AL to BIOS teletype (int 0x10 AH=0Eh) and then to the COM1
; THR after waiting for it to drain. AL is preserved across both writes so
; callers can chain calls without reloading. Clobbers BX, DX.
put_char:
    push    ax
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    pop     ax
    push    ax
    mov     dx, COM1_LSR
.wait_thr:
    in      al, dx
    test    al, 0x20            ; THR empty
    jz      .wait_thr
    pop     ax
    mov     dx, COM1
    out     dx, al
    ret

msg:
    db      'ClientAPI', 13, 10, 0

    times 256 - ($ - $$) db 0
