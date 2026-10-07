; =============================================================================
; tests/dgtsr/drvq.asm - ask the DOS drivers what they think (tests/dosguest.py)
;
; One line: XMS present (INT 2Fh AX=4300h, 80h), the driver's version and its
; free extended memory in KB, the A20 line as the driver finds it (function 07h),
; and whether a mouse driver answers INT 33h AX=0 (FFFF). Everything a driver
; keeps in a device or in a CPU mode that the memory image does not cover, read
; before and after dosguest so the two lines can be compared.
; =============================================================================
cpu 8086
org 0x100
    mov ax, 0x4300
    int 0x2F
    mov bh, al                      ; printing clobbers AL, so keep it
    call hex8                       ; 80 = an XMS driver
    call sp_
    cmp bh, 0x80
    jne .nox
    mov ax, 0x4310
    int 0x2F
    mov [xms], bx
    mov [xms+2], es
    xor ax, ax
    call far [xms]                  ; function 00h: version in AX
    call hex16
    call sp_
    mov ah, 0x08
    xor bl, bl
    call far [xms]                  ; function 08h: largest block (AX), total (DX), KB
    mov ax, dx
    call hex16
    call sp_
    mov ah, 0x07
    call far [xms]                  ; function 07h: AX=1 if A20 is enabled
    call hex16
    jmp .mouse
.nox:
    mov ax, 0xFFFF
    call hex16
    call sp_
    call hex16
    call sp_
    call hex16
.mouse:
    call sp_
    xor ax, ax
    int 0x33
    call hex16
    mov al, 13
    call putc
    mov al, 10
    call putc
    mov ax, 0x4C00
    int 0x21
sp_:
    push ax
    mov al, ' '
    call putc
    pop ax
    ret
hex16:
    push ax
    mov al, ah
    call hex8
    pop ax
hex8:
    push ax
    mov cl, 4
    shr al, cl
    call nib
    pop ax
    and al, 15
nib:
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
putc:
    push ax
    push dx
    mov dl, al
    mov ah, 2
    int 0x21
    pop dx
    pop ax
    ret
xms dw 0, 0
