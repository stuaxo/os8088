; =============================================================================
; tests/dgtsr/tsrq.asm - ask tsrok.com for its counters, a second apart
;
; Prints "AAAA BBBB CCCC" (hex): the tick hook's count, then its count about
; twenty BIOS ticks later, then the keyboard hook's. A hook that survived the
; round trip makes BBBB larger than AAAA; one that did not, or a machine whose
; timer never came back, leaves them equal.
; =============================================================================
cpu 8086
org 0x100
    int 0x60
    mov [a1], ax
    xor ax, ax
    int 0x1A                        ; CX:DX = ticks
    mov [t0], dx
.w: xor ax, ax
    int 0x1A
    sub dx, [t0]
    cmp dx, 20
    jb .w
    int 0x60
    mov [a2], ax
    mov [a3], bx
    mov ax, [a1]
    call hex
    mov al, ' '
    call putc
    mov ax, [a2]
    call hex
    mov al, ' '
    call putc
    mov ax, [a3]
    call hex
    mov al, 13
    call putc
    mov al, 10
    call putc
    mov ax, 0x4C00
    int 0x21
hex:
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
a1 dw 0
a2 dw 0
a3 dw 0
t0 dw 0
