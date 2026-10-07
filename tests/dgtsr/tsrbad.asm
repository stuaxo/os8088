; =============================================================================
; tests/dgtsr/tsrbad.asm - a TSR dosguest must REFUSE (tests/dosguest.py)
;
; A hook with no way to see the previous owner through it: no sharing header,
; no `call` wrapper, and a chain the launcher's scan for `jmp far cs:[old]` and
; `call far cs:[old]` cannot find (it returns to the old vector through the
; stack). A plain `jmp far` hook IS accepted now - see tsrok.asm and the scan. The vector is -DVEC=<n>, INT 08h by
; default. A launcher that handed os8088 this vector would have it chain into
; memory it had just overwritten, so the right answer is to say no, name the
; vector and where it points, and touch nothing.
; =============================================================================
%ifndef VEC
 %define VEC 8
%endif
cpu 8086
org 0x100
start:
    jmp init
old     dd 0
cnt     dw 0
h:
    inc word [cs:cnt]
    ; chain by pushing the old vector and returning to it: it works, and there is
    ; no jmp or call through a variable for the launcher's scan to find
    push word [cs:old+2]
    push word [cs:old]
    retf
init:
    mov ax, 0x3500 | VEC
    int 0x21
    mov [old], bx
    mov [old+2], es
    mov dx, h
    mov ax, 0x2500 | VEC
    int 0x21
    mov dx, init                    ; paragraphs to keep: everything above `init`
    add dx, 15
    mov cl, 4
    shr dx, cl
    mov ax, 0x3100
    int 0x21
