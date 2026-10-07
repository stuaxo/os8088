; =============================================================================
; tests/dgtsr/tsrok.asm - a TSR dosguest has to survive (tests/dosguest.py)
;
; Three hooks, each of a kind the launcher treats differently:
;
;   INT 1Ch  a plain tick hook. NOT a vector os8088 calls, but the BIOS's INT 08h
;            handler does - so if the launcher left it in the live IVT, os8088's
;            first tick would jump into this code after it was overwritten. The
;            launcher makes it an IRET for os8088 and DOS gets this back.
;   INT 09h  behind an IBM Interrupt Sharing Protocol header (EB 10 | old | 'KB'),
;            which the launcher unwraps to the ROM's handler.
;   INT 60h  a service: AX = the tick count this TSR has seen, BX = keystrokes.
;            Not in the launcher's table, so it is DOS's the whole time.
;
; tsrq.com reads INT 60h twice, a second apart. A counter that moves AFTER the
; round trip is a hook that came back.
; =============================================================================
cpu 8086
org 0x100
start:
    jmp init

old1c   dd 0
cnt1c   dw 0
cnt09   dw 0

; ----- the IBM Interrupt Sharing Protocol header -----------------------------
isp09:
    db 0xEB, 0x10                   ; jmp short over the header
old09:
    dd 0                            ; the previous owner
    dw 0x424B                       ; 'KB'
    db 0                            ; flags
    db 0xEB, 0x00                   ; the hardware-reset entry: nothing to do
    times 7 db 0                    ; reserved
h09:
    inc word [cs:cnt09]
    jmp far [cs:old09]

h1c:
    inc word [cs:cnt1c]
    jmp far [cs:old1c]

h60:
    mov ax, [cs:cnt1c]
    mov bx, [cs:cnt09]
    iret

init:
    mov ax, 0x351C
    int 0x21
    mov [old1c], bx
    mov [old1c+2], es
    mov dx, h1c
    mov ax, 0x251C
    int 0x21
    mov ax, 0x3509
    int 0x21
    mov [old09], bx
    mov [old09+2], es
    mov dx, isp09                   ; the vector points at the HEADER, as the
    mov ax, 0x2509                  ; protocol has it, and the header jumps on
    int 0x21
    mov dx, h60
    mov ax, 0x2560
    int 0x21
    mov dx, init                    ; paragraphs to keep: everything above `init`
    add dx, 15
    mov cl, 4
    shr dx, cl
    mov ax, 0x3100
    int 0x21
