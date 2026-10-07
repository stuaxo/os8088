; =============================================================================
; tests/dgtsr/vidq.asm - read the video state back (tests/dosguest.py)
;
; One line of hex: mode, rows, character height, cursor position, cursor shape,
; DAC register 5 (R G B), the first 8 bytes of glyph 'A' as the VGA holds them in
; plane 2, then the 12 characters at row 40. Everything vidset.com set, read the
; way a program would read it, so before and after can be compared as strings.
; =============================================================================
cpu 8086
org 0x100
    mov ah, 0x0F
    int 0x10
    mov al, al
    call hex8                       ; mode
    call sp_
    xor ax, ax
    mov es, ax
    mov al, [es:0x484]
    call hex8                       ; rows - 1
    call sp_
    mov al, [es:0x485]
    call hex8                       ; character height
    call sp_
    mov ah, 3
    xor bx, bx
    int 0x10                        ; DX cursor, CX shape
    mov [shape], cx
    mov ax, dx
    call hex16
    call sp_
    mov ax, [shape]
    call hex16
    call sp_
    mov ax, 0x1015
    mov bx, 5
    int 0x10                        ; DH red, CH green, CL blue
    mov [rgb], dx
    mov [rgb+2], cx
    mov al, [rgb+1]
    call hex8
    mov al, [rgb+3]
    call hex8
    mov al, [rgb+2]
    call hex8
    call sp_
    ; glyph 65, from plane 2
    mov dx, 0x3C4
    mov al, 2
    out dx, al
    inc dx
    in al, dx
    mov [v_s2], al
    dec dx
    mov al, 4
    out dx, al
    inc dx
    in al, dx
    mov [v_s4], al
    mov dx, 0x3CE
    mov al, 4
    out dx, al
    inc dx
    in al, dx
    mov [v_g4], al
    dec dx
    mov al, 5
    out dx, al
    inc dx
    in al, dx
    mov [v_g5], al
    dec dx
    mov al, 6
    out dx, al
    inc dx
    in al, dx
    mov [v_g6], al
    mov dx, 0x3C4
    mov ax, 0x0402
    out dx, ax
    mov ax, 0x0604
    out dx, ax
    mov dx, 0x3CE
    mov ax, 0x0204
    out dx, ax
    mov ax, 0x0005
    out dx, ax
    mov ax, 0x0406
    out dx, ax
    mov ax, 0xA000
    mov es, ax
    mov si, 65 * 32
    mov cx, 8
.g: mov al, [es:si]
    inc si
    push cx
    call hex8
    pop cx
    loop .g
    mov dx, 0x3C4
    mov ah, [v_s2]
    mov al, 2
    out dx, ax
    mov ah, [v_s4]
    mov al, 4
    out dx, ax
    mov dx, 0x3CE
    mov ah, [v_g4]
    mov al, 4
    out dx, ax
    mov ah, [v_g5]
    mov al, 5
    out dx, ax
    mov ah, [v_g6]
    mov al, 6
    out dx, ax
    call sp_
    ; the row-40 text
    mov ax, 0xB800
    mov es, ax
    mov si, 40 * 160
    mov cx, 12
.t: mov al, [es:si]
    add si, 2
    push cx
    call putc
    pop cx
    loop .t
    call sp_
    ; the top left of the text page: B800, or B000 in mode 7
    mov ah, 0x0F
    int 0x10
    mov bx, 0xB800
    cmp al, 7
    jne .t0
    mov bx, 0xB000
.t0:
    mov es, bx
    xor si, si
    mov cx, 8
.t1:
    mov al, [es:si]
    add si, 2
    push cx
    call putc
    pop cx
    loop .t1
    mov al, 13
    call putc
    mov al, 10
    call putc
    mov ax, 0x4C00
    int 0x21
sp_:
    mov al, ' '
    jmp putc
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
shape dw 0
rgb   dw 0, 0
v_s2 db 0
v_s4 db 0
v_g4 db 0
v_g5 db 0
v_g6 db 0
