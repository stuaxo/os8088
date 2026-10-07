; =============================================================================
; tests/dgtsr/a20q.asm - is the A20 line enabled? (tests/dosguest.py)
;
; The wrap-around test: 0000:0080 and FFFF:0090 are the same byte with A20 off
; and different bytes with it on. Prints 1 when A20 is ON, 0 when it is OFF.
; A BIOS boot leaves it on; an XMS driver may turn it off, and os8088 is booted
; into whichever it finds. dosguest has to know which, and put it back.
; =============================================================================
cpu 8086
org 0x100
    cli
    xor ax, ax
    mov ds, ax
    mov ax, 0xFFFF
    mov es, ax
    mov si, 0x80
    mov di, 0x90
    mov ax, [si]
    push ax
    mov bx, ax
    xor bx, 0xA5A5
    mov [si], bx                    ; write through the low alias
    mov ax, [es:di]                 ; ...and look at the high one
    cmp ax, bx
    pop ax
    mov [si], ax                    ; put it back
    sti
    mov dl, '1'
    jne .on                         ; they differ: A20 is on
    mov dl, '0'
.on:
    push cs
    pop ds
    mov ah, 2
    int 0x21
    mov dl, 13
    mov ah, 2
    int 0x21
    mov dl, 10
    mov ah, 2
    int 0x21
    mov ax, 0x4C00
    int 0x21
