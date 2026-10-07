; =============================================================================
; tests/dgtsr/clk.asm - print the RTC's time and DOS's time (tests/dosguest.py)
;
; "RR RR RR DD DD DD": the RTC's hours, minutes, seconds as INT 1Ah gives them
; (BCD, shown as it is) and DOS's as INT 21h AH=2Ch gives them (hex of binary).
; dosguest sets DOS's clock from the RTC after os8088 runs, so the two have to
; agree, and DOS's has to have moved on by the time os8088 ran.
; =============================================================================
cpu 8086
org 0x100
again:
    mov ah, 2
    int 0x1A
    mov [r], cx
    mov [r+2], dx
    mov ah, 0x2C
    int 0x21
    mov [d], cx
    mov [d+2], dx
    mov al, [r+1]
    call hex8
    mov al, [r]
    call hex8
    mov al, [r+3]
    call hex8
    mov al, ' '
    call putc
    mov al, [d+1]
    call hex8
    mov al, [d]
    call hex8
    mov al, [d+3]
    call hex8
    mov al, 13
    call putc
    mov al, 10
    call putc
    cmp byte [done], 0
    jne fin
    mov byte [done], 1
    cmp byte [0x83], 'w'
    jne fin
    xor ax, ax
    int 0x1A
    mov [t0], dx
.w: xor ax, ax
    int 0x1A
    sub dx, [t0]
    cmp dx, 91
    jb .w
    jmp again
fin:
    mov ax, 0x4C00
    int 0x21
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
r dw 0, 0
t0 dw 0
done db 0
d dw 0, 0
