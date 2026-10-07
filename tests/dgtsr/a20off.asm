; =============================================================================
; tests/dgtsr/a20off.asm - turn A20 off through the BIOS (tests/dosguest.py)
;
; A DOS whose XMS driver has A20 disabled is what dosguest finds on any machine
; where nothing is using the HMA. os8088 is not written for it: a BIOS boot
; leaves A20 on, so the launcher forces it on for os8088 and puts DOS's back.
; =============================================================================
cpu 8086
org 0x100
    mov ax, 0x2400
    int 0x15
    mov ax, 0x4C00
    int 0x21
