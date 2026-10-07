; =============================================================================
; tests/dgtsr/vidmode.asm - set a BIOS video mode, mark it (tests/dosguest.py)
;
;   vidmode 12     mode 12h, in hex. A text mode (0 to 3, 7) gets the word
;                  MODEMARK-xx written at the top left of its text page, so
;                  what comes back can be told from a blank screen of the same
;                  mode; a graphics mode just gets set.
; dosguest keeps text modes and puts a graphics-mode host back in 80x25 text.
; =============================================================================
cpu 8086
org 0x100
    mov si, 0x82
    xor bx, bx
.p: lodsb
    cmp al, 13
    je .go
    cmp al, ' '
    je .p
    cmp al, '9'
    jbe .dig
    and al, 0xDF                    ; a letter: upper-case it, A = 10
    sub al, 'A' - 10
    jmp .d
.dig:
    sub al, '0'
.d: mov cl, 4
    shl bx, cl
    xor ah, ah
    add bx, ax
    jmp .p
.go:
    mov [mode], bl
    mov ax, bx
    xor ah, ah
    int 0x10
    mov al, [mode]
    cmp al, 3
    jbe .text
    cmp al, 7
    jne .done
.text:
    mov bx, 0xB800
    mov ah, 0x1F
    cmp al, 7
    jne .m
    mov bx, 0xB000
    mov ah, 0x07
.m: mov es, bx
    xor di, di
    mov si, mark
.w: lodsb
    test al, al
    jz .done
    stosw
    jmp .w
.done:
    mov ax, 0x4C00
    int 0x21
mode db 0
mark db 'MODEMARK', 0
