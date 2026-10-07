; =============================================================================
; tests/dgtsr/xmsq.asm - is the XMS manager still happy? (tests/dosguest.py)
;
;   xmsq f   allocate 512 KB of extended memory, fill it with a known pattern,
;            and leave its handle in C:\XMS.HDL
;   xmsq c   read that block back and count mismatches; allocate and free a
;            fresh block; request and release the HMA; and drive A20 through the
;            manager (global enable, query, global disable, query)
;
; Run `f` before the launcher and `c` after it. Matching version and free memory
; (drvq.com) says the driver's own state came back; this says the MEMORY it
; manages did, and that its bookkeeping still agrees with the hardware.
; =============================================================================
cpu 8086
org 0x100
CHUNK   equ 16384
NCHUNK  equ 32                      ; 32 x 16 KB = 512 KB
    mov ax, 0x4300
    int 0x2F
    cmp al, 0x80
    je .have
    mov dx, m_noxms
    mov ah, 9
    int 0x21
    mov ax, 0x4C01
    int 0x21
.have:
    mov ax, 0x4310
    int 0x2F
    mov [xms], bx
    mov [xms+2], es
    cmp byte [0x82], 'f'
    je fill
    jmp check

; ----- f -----------------------------------------------------------------------
fill:
    mov ah, 9
    mov dx, 512
    call far [xms]
    cmp ax, 1
    jne fail
    mov [hdl], dx
    mov word [seed], 0x4321
    xor bp, bp                      ; chunk number
.c: call gen                        ; the pattern for this chunk into buf
    mov word [emb], CHUNK
    mov word [emb+2], 0
    mov word [emb+4], 0             ; source: conventional
    mov word [emb+6], buf
    mov [emb+8], ds
    mov ax, [hdl]
    mov [emb+10], ax                ; destination: the block
    mov ax, bp
    mov cl, 14
    shl ax, cl                      ; low word of bp * 16384
    mov [emb+12], ax
    mov ax, bp
    mov cl, 2
    shr ax, cl                      ; high word
    mov [emb+14], ax
    mov si, emb
    mov ah, 0x0B
    call far [xms]
    cmp ax, 1
    jne fail
    inc bp
    cmp bp, NCHUNK
    jb .c
    ; the handle, to a file
    mov dx, hname
    xor cx, cx
    mov ah, 0x3C
    int 0x21
    jc fail
    mov bx, ax
    mov dx, hdl
    mov cx, 2
    mov ah, 0x40
    int 0x21
    mov ah, 0x3E
    int 0x21
    mov dx, m_filled
    mov ah, 9
    int 0x21
    mov ax, 0x4C00
    int 0x21

; ----- c -----------------------------------------------------------------------
check:
    mov dx, hname
    mov ax, 0x3D00
    int 0x21
    jc fail
    mov bx, ax
    mov dx, hdl
    mov cx, 2
    mov ah, 0x3F
    int 0x21
    mov ah, 0x3E
    int 0x21
    mov word [seed], 0x4321
    mov word [bad], 0
    xor bp, bp
.c: call gen                        ; what the chunk should hold, into buf
    ; read the block's chunk into buf2
    mov word [emb], CHUNK
    mov word [emb+2], 0
    mov ax, [hdl]
    mov [emb+4], ax                 ; source: the block
    mov ax, bp
    mov cl, 14
    shl ax, cl
    mov [emb+6], ax
    mov ax, bp
    mov cl, 2
    shr ax, cl
    mov [emb+8], ax
    mov word [emb+10], 0            ; destination: conventional
    mov word [emb+12], buf2
    mov [emb+14], ds
    mov si, emb
    mov ah, 0x0B
    call far [xms]
    cmp ax, 1
    jne fail
    mov si, buf
    mov di, buf2
    mov cx, CHUNK / 2
.cmp:
    mov ax, [si]
    cmp ax, [di]
    je .eq
    inc word [bad]
.eq:
    inc si
    inc si
    inc di
    inc di
    loop .cmp
    inc bp
    cmp bp, NCHUNK
    jb .c
    mov si, m_data
    call puts
    mov ax, [bad]
    call hex16
    call crlf
    ; a fresh block: allocate, free
    mov ah, 9
    mov dx, 64
    call far [xms]
    mov [okalloc], ax
    mov dx, [hdl2]
    mov [hdl2], dx
    mov ah, 9
    mov dx, 64
    call far [xms]                  ; a second, so a leak shows
    mov [hdl2], dx
    mov [okalloc2], ax
    mov dx, [hdl2]
    mov ah, 0x0A
    call far [xms]
    mov si, m_alloc
    call puts
    mov ax, [okalloc]
    call hex16
    mov ax, [okalloc2]
    call hex16
    call crlf
    ; the HMA
    mov ah, 1
    mov dx, 0xFFFF
    call far [xms]
    mov [okhma], ax
    mov ah, 2
    call far [xms]
    mov si, m_hma
    call puts
    mov ax, [okhma]
    call hex16
    call crlf
    ; A20 through the manager: enable, query, disable, query
    mov ah, 3
    call far [xms]
    mov ah, 7
    call far [xms]
    mov [q1], ax
    mov ah, 4
    call far [xms]
    mov ah, 7
    call far [xms]
    mov [q2], ax
    mov si, m_a20
    call puts
    mov ax, [q1]
    call hex16
    mov ax, [q2]
    call hex16
    call crlf
    ; free the block we filled
    mov dx, [hdl]
    mov ah, 0x0A
    call far [xms]
    mov ax, 0x4C00
    int 0x21

fail:
    mov dx, m_fail
    mov ah, 9
    int 0x21
    mov ax, 0x4C02
    int 0x21

; gen: fill buf with CHUNK/2 words of the pattern, continuing [seed]
gen:
    mov di, buf
    mov cx, CHUNK / 2
.g: mov ax, [seed]
    mov dx, 25173
    mul dx
    add ax, 13849
    mov [seed], ax
    mov [di], ax
    inc di
    inc di
    loop .g
    ret

puts:
    lodsb
    test al, al
    jz .d
    call putc
    jmp puts
.d: ret
crlf:
    mov al, 13
    call putc
    mov al, 10
putc:
    push ax
    push dx
    mov dl, al
    mov ah, 2
    int 0x21
    pop dx
    pop ax
    ret
hex16:
    push ax
    mov al, ah
    call hex8
    pop ax
hex8:
    push ax
    push cx
    mov cl, 4
    shr al, cl
    call nib
    pop cx
    pop ax
    and al, 15
nib:
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
    jmp putc

xms     dw 0, 0
hdl     dw 0
hdl2    dw 0
seed    dw 0
bad     dw 0
okalloc dw 0
okalloc2 dw 0
okhma   dw 0
q1      dw 0
q2      dw 0
hname   db 'C:\XMS.HDL', 0
m_noxms db 'NOXMS', 13, 10, '$'
m_filled db 'FILLED', 13, 10, '$'
m_fail  db 'FAIL', 13, 10, '$'
m_data  db 'XMSDATA=', 0
m_alloc db 'ALLOC=', 0
m_hma   db 'HMA=', 0
m_a20   db 'A20=', 0
emb     times 16 db 0
buf     times CHUNK db 0
buf2    times CHUNK db 0
