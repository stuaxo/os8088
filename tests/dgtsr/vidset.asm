; =============================================================================
; tests/dgtsr/vidset.asm - put the video in a state worth losing (tests/dosguest.py)
;
; 80x50 text (the 8x8 font), a CUSTOM glyph for 'A' (not the ROM's), a changed
; DAC register, a cursor shape and position, and text on row 40 - a row that does
; not exist in an 80x25 mode. dosguest has to bring ALL of it back; vidq.com
; reads it out again to compare. -DGFX instead sets graphics mode 12h, which
; dosguest does not keep: the host has to come back in 80x25 TEXT, not in a
; graphics mode with nothing on it.
; =============================================================================
cpu 8086
org 0x100
%ifdef GFX
    mov ax, 0x0012
    int 0x10
    mov ax, 0x4C00
    int 0x21
%else
    mov ax, 0x0003
    int 0x10
    mov ax, 0x1112                  ; the 8x8 font: 400 lines / 8 = 50 rows
    xor bx, bx
    int 0x10
    ; a glyph of our own for 'A' (65): 8 bytes of a recognisable pattern
    push cs
    pop es
    mov bp, glyph
    mov ax, 0x1100
    mov bh, 8
    xor bl, bl
    mov cx, 1
    mov dx, 65
    int 0x10
    ; DAC register 5
    mov ax, 0x1010
    mov bx, 5
    mov dh, 0x3F
    mov ch, 0x0A
    mov cl, 0x14
    int 0x10
    ; text at row 40, and an 'A' under the new glyph
    mov ax, 0xB800
    mov es, ax
    mov di, 40 * 160
    mov si, marker
.m: lodsb
    test al, al
    jz .md
    mov ah, 0x1F
    stosw
    jmp .m
.md:
    mov di, 41 * 160
    mov ax, 0x1E41
    stosw
    ; cursor: shape 4..7, position row 45 column 7
    mov ah, 1
    mov cx, 0x0407
    int 0x10
    mov ah, 2
    xor bx, bx
    mov dx, 0x2D07
    int 0x10
    mov ax, 0x4C00
    int 0x21
glyph   db 0xF0, 0xF0, 0xF0, 0xF0, 0x0F, 0x0F, 0x0F, 0x0F
marker  db 'VIDSET-ROW40', 0
%endif
