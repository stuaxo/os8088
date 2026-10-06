; =============================================================================
; os8088 - dosguest/dg.asm
;
; THE LAUNCHER, WAVE 1 (docs/plans/DOSGUEST-PLAN.md 9): suspend DOS to a file,
; trash what os8088 would trash, put DOS back and check it. There is no os8088
; in this wave. The point is the part that has to be right before os8088 is
; involved at all: the hidden block, the extent list and the return stub.
;
;   DG.COM        run the self-test; writes \DGRESULT.TXT and prints it
;   DG.COM /K     ...and keeps \DGSWAP.IMG so the host can read it back
;
;   make dosguest            builds build/DG.COM
;   python3 tests/dosguest.py  runs it under FreeDOS in QEMU and checks the
;                              swap file on the host (docs/TESTING.md)
;   nasm -DBREAK_RESTORE      skip the restore: tests/dosguest.py's negative control,
;                              which must NOT come back
;   nasm -DDEBUG             a letter per step through BIOS teletype. NOTE THE
;                              CURSOR: it lives in the BDA, which the restore
;                              rewrites, so marks printed after the resume land
;                              on top of ones printed before it.
;
; THE SHAPE (plan 3.3). The launcher takes a block from the TOP of the DOS
; arena and lowers the BIOS memory size to just below it, so a machine that
; sizes itself from int 12h cannot reach the block. Everything that has to
; survive os8088 lives there: the stub, the extent list, the saved state. The
; image is linear 0 to the block's base and is written with raw int 13h FROM
; THE BLOCK, never through DOS: DOS mutates its own state when it writes a
; file, so a snapshot taken through it would be one no instant ever held
; (SPEC.md 87.4's reason for writing through the kernel's own layer).
;
; 8086 only, as the rest of the tree: the launcher runs on the machine the
; project is calibrated against.
; =============================================================================
cpu 8086
bits 16
org 0x100

PAT_SEED    equ 0x1234              ; tests/dosguest.py regenerates the pattern from it
HB_PARAS    equ 0x100               ; the hidden block: 4KB
MAXRUNS     equ 128                 ; extents; 6 bytes each
ST_STACK    equ 0x0FF0              ; the stub's stack top, inside the block
SECBUF_LEN  equ 1024                ; FAT/dir/boot sector buffer (2 sectors)

%macro MARK 1
%ifdef DEBUG
    push ax
    push bx
    mov ax, 0x0E00 | %1
    mov bx, 7
    int 0x10
    pop bx
    pop ax
%endif
%endmacro

section .text
start:
    jmp main

; --- launcher data ----------------------------------------------------------
total_kb    dw 0
size_kb     dw 0                    ; the image, in KB: a multiple of 16
hseg        dw 0                    ; the hidden block
pseg        dw 0                    ; the pattern block
pparas      dw 0
drive       db 0                    ; 0 = A
keep        db 0
bad         dw 0                    ; pattern mismatches after the resume
fatsec      dw 0xFFFF               ; the FAT sector in secbuf, if any
fatsec_ok   db 0

; the BPB, as read
bpb_spc     db 0
bpb_res     dw 0
bpb_nfat    db 0
bpb_root    dw 0
bpb_spf     dw 0
bpb_hid     dw 0, 0
bpb_tot     dw 0, 0
fat_start   dw 0
root_start  dw 0
root_secs   dw 0
data_start  dw 0
fat16       db 0
file_cl     dw 0
file_size   dw 0, 0
nsec_need   dw 0

; INT 25h packet
pk_sec      dw 0, 0
pk_cnt      dw 1
pk_off      dw 0
pk_seg      dw 0

swapname    db '\DGSWAP.IMG', 0
resname     db '\DGRESULT.TXT', 0
dirname     db 'DGSWAP  IMG'

msg_dos     db 'DG: needs DOS 3.31 or later', 13, 10, '$'
msg_mem     db 'DG: cannot allocate the hidden block', 13, 10, '$'
msg_swap    db 'DG: cannot write \DGSWAP.IMG', 13, 10, '$'
msg_bpb     db 'DG: unsupported volume (512-byte sectors, FAT12 or FAT16 only)', 13, 10, '$'
msg_unit    db 'DG: cannot find the BIOS unit for this drive', 13, 10, '$'
msg_dir     db 'DG: swap file not found in the root', 13, 10, '$'
msg_frag    db 'DG: swap file is too fragmented', 13, 10, '$'
msg_io      db 'DG: disk error', 13, 10, '$'
msg_vec     db 'DG: vector is in RAM, not ROM: INT ', '$'
msg_stub    db 'DG: the stub failed: ', '$'


; --- the report -------------------------------------------------------------
rptr        dw rbuf
rbuf        times 1024 db 0

; --- 512-aligned sector buffer: found at run time ---------------------------
secbuf      dw 0                    ; offset of the aligned 1KB inside rawbuf
rawbuf      times (SECBUF_LEN + 512) db 0


; =============================================================================
; main
; =============================================================================
main:
    cld
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, mystack
    ; --- shrink to what we use so the arena has something to hand out -------
    mov bx, stub_load + (stub_end - stub_start)
    add bx, 15
    mov cl, 4
    shr bx, cl
    inc bx
    mov ah, 0x4A
    int 0x21
    ; --- the command line: /K ------------------------------------------------
    mov si, 0x81
.cl: lodsb
    cmp al, 13
    je .cldone
    cmp al, '/'
    jne .cl
    lodsb
    and al, 0xDF
    cmp al, 'K'
    jne .cl
    mov byte [keep], 1
    jmp .cl
.cldone:
    ; --- DOS 3.31+ for INT 25h's packet form --------------------------------
    mov ah, 0x30
    int 0x21
    cmp al, 4
    jae .dosok
    cmp al, 3
    jne .dosbad
    cmp ah, 31
    jae .dosok
.dosbad:
    mov dx, msg_dos
    jmp fail
.dosok:
    int 0x12
    mov [total_kb], ax
    call build_clean
    MARK 'a'
    ; --- the hidden block, from the top of the arena ------------------------
    mov ax, 0x5801
    mov bx, 2                       ; last fit
    int 0x21
    mov ah, 0x48
    mov bx, HB_PARAS
    int 0x21
    jc .nomem
    mov [hseg], ax
    mov ax, 0x5801
    xor bx, bx                      ; first fit again
    int 0x21
    jmp .gotblk
.nomem:
    mov dx, msg_mem
    jmp fail
.gotblk:
    ; the image is everything below the block, in whole 16KB units
    mov ax, [hseg]
    mov cl, 6
    shr ax, cl                      ; paragraphs / 64 = KB
    and ax, 0xFFF0
    mov [size_kb], ax
    ; --- install the stub, now, so its disk service is ours to use ----------
    call install_stub
    call save_vectors               ; the stub's int 13h needs these at once
    MARK 'b'
    ; --- everything free becomes a pattern, so the round trip has content ---
    call alloc_pattern
    MARK 'c'
    MARK 'p'
    mov al, 0
    call pattern
    MARK 'q'
    ; --- the swap file, through DOS: it allocates the clusters --------------
    call make_swap
    MARK 'd'
    ; --- the volume, its unit, and the file's extents -----------------------
    call read_bpb
    MARK 'e'
    call find_unit
    MARK 'f'
    call find_file
    MARK 'g'
    call build_runs
    MARK 'h'
    ; --- state the stub needs that is not in the image ----------------------
    MARK 'i'
    ; --- THE SNAPSHOT: a second return from this call is the resume ----------
    push bp
    push si
    push di
    call far [cs:stub_suspend_far]
    MARK 'j'
    pop di
    pop si
    pop bp
    mov bx, ax                      ; 0 first time, 1 after the restore
    mov ax, cs
    mov ds, ax
    cmp bx, 2
    je stubfail
    test bx, bx
    jnz resumed
    ; --- first return: what os8088 would do to the machine ------------------
    MARK 'k'
    call far [cs:stub_trash_far]    ; never returns: the resume does
    mov dx, msg_stub
    jmp fail

resumed:
    MARK 'R'
    ; DS=CS again by the stub's restore. Everything here is the snapshot's.
    mov al, 1
    call pattern
    MARK 'P'
    mov es, [hseg]
    call report
    MARK 'Q'
    call write_report
    MARK 'W'
    ; --- give it all back -----------------------------------------------------
    mov es, [pseg]
    mov ah, 0x49
    int 0x21
    cmp byte [keep], 0
    jne .nodel
    mov dx, swapname
    mov ah, 0x41
    int 0x21
.nodel:
    mov es, [hseg]
    mov ah, 0x49
    int 0x21
    mov ax, 0x4C00
    int 0x21

stubfail:
    mov dx, msg_stub
    mov ah, 0x09
    int 0x21
    mov es, [hseg]
    mov ax, [es:blk_err]
    call con_hex16
    mov dl, ' '
    mov ah, 2
    int 0x21
    mov ax, [es:t_lba+2]
    call con_hex16
    mov ax, [es:t_lba]
    call con_hex16
    mov dl, ' '
    mov ah, 2
    int 0x21
    mov ax, [es:t_n]
    call con_hex16
    mov dl, ' '
    mov ah, 2
    int 0x21
    mov ax, [es:t_cyl]
    call con_hex16
    mov ax, [es:t_hd]
    call con_hex16
    mov ax, [es:blk_spt]
    call con_hex16
    mov ax, [es:blk_heads]
    call con_hex16
    mov ax, 0x4C02
    int 0x21

fail:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; =============================================================================
; the vector policy (plan 4.2). os8088 chains to whatever INT 08h and 09h hold
; at boot, so the live IVT it is handed must name the ROM. DOS's own vectors
; stay in the swap image and come back on the resume; what is built here is the
; CLEAN set the stub puts in the live IVT after the snapshot.
;
; A vector already in ROM is its own clean value. Stock FreeDOS wraps every IRQ
; vector in a stub of the form `call <handler>` followed by the original far
; vector, stored inline; that stub is recognised and unwrapped. Anything else
; in RAM is somebody's TSR, and the launcher refuses and says where it points.
; INT 13h itself has to be in ROM: the stub's disk service is the only way back.
; =============================================================================
vec_nums    db 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
            db 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77
cleanvec    times 16 dd 0
vec_idx     dw 0

build_clean:
    ; INT 13h: ROM or refuse
    xor ax, ax
    mov es, ax
    mov dx, [es:0x13*4+2]
    mov di, [es:0x13*4]
    mov bx, 0x13
    cmp dx, 0xC000
    jb refuse_vec
    xor si, si
.l: mov bl, [vec_nums+si]
    xor bh, bh
    mov [vec_cur], bx
    shl bx, 1
    shl bx, 1
    xor ax, ax
    mov es, ax
    mov di, [es:bx]                 ; offset
    mov dx, [es:bx+2]               ; segment
    mov ax, di
    mov cx, 8                       ; chain depth
.chase:
    cmp dx, 0xC000
    jae .ok
    ; in RAM. Two shapes are recognised, both of which keep the old vector
    ; inline: the IBM Interrupt Sharing Protocol header
    ;   EB 10 | dd old | 'KB' | 00 | EB F4 | ...
    ; and FreeDOS's wrapper   E8 rel16 | dd old
    mov es, dx
    mov bx, ax
    cmp byte [es:bx], 0xEB
    jne .notiisp
    cmp byte [es:bx+1], 0x10
    jne .no
    cmp word [es:bx+6], 0x424B
    jne .no
    mov ax, [es:bx+2]
    mov dx, [es:bx+4]
    jmp .again
.notiisp:
    cmp byte [es:bx], 0xE8
    jne .no
    mov ax, [es:bx+3]
    mov dx, [es:bx+5]
.again:
    loop .chase
.no:
    mov bx, [vec_cur]
    mov di, ax
    jmp refuse_vec
.ok:
    push si
    shl si, 1
    shl si, 1
    mov [cleanvec+si], ax
    mov [cleanvec+si+2], dx
    pop si
    inc si
    cmp si, 16
    jb .l
    push cs
    pop es
    ret
vec_cur dw 0

; refuse_vec: BX = vector, DX:DI = where it points
refuse_vec:
    push dx
    push di
    mov dx, msg_vec
    mov ah, 0x09
    int 0x21
    mov ax, bx
    call con_hex8
    mov dl, ' '
    mov ah, 2
    int 0x21
    pop di
    pop ax                          ; the segment
    call con_hex16
    mov dl, ':'
    mov ah, 2
    int 0x21
    mov ax, di
    call con_hex16
    mov dl, 13
    mov ah, 2
    int 0x21
    mov dl, 10
    mov ah, 2
    int 0x21
    mov ax, 0x4C01
    int 0x21

con_hex16:
    push ax
    mov al, ah
    call con_hex8
    pop ax
con_hex8:
    push ax
    mov cl, 4
    shr al, cl
    call con_nib
    pop ax
    and al, 0x0F
con_nib:
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p: mov dl, al
    mov ah, 2
    int 0x21
    ret

; =============================================================================
; install_stub: copy the stub into the hidden block and fill its constants
; =============================================================================
install_stub:
    push es
    mov es, [hseg]
    xor di, di
    mov si, stub_load
    mov cx, stub_end - stub_start
    rep movsb
    mov ax, [size_kb]
    mov [es:blk_size_kb], ax
    xor ax, ax
    mov [es:blk_nruns], ax
    mov ax, [hseg]
    mov [es:blk_seg], ax
    pop es
    ; far pointers into the block
    mov ax, [hseg]
    mov word [stub_suspend_far], STUB_SUSPEND
    mov [stub_suspend_far+2], ax
    mov word [stub_trash_far], STUB_TRASH
    mov [stub_trash_far+2], ax
    mov word [stub_rw_far], STUB_RW
    mov [stub_rw_far+2], ax
    ret

stub_suspend_far dw 0, 0
stub_trash_far   dw 0, 0
stub_rw_far      dw 0, 0

; =============================================================================
; save_vectors: the ROM's int 13h, the PIC masks and the original memory size
; go into the block, where the stub keeps them
; =============================================================================
save_vectors:
    push es
    xor ax, ax
    mov es, ax
    mov ax, [es:0x13*4]
    mov dx, [es:0x13*4+2]
    mov bx, [es:0x413]
    mov es, [hseg]
    mov [es:blk_rom13], ax
    mov [es:blk_rom13+2], dx
    mov [es:blk_orig_kb], bx
    mov si, cleanvec
    mov di, blk_clean
    mov cx, 32
    rep movsw                       ; 16 vectors, 2 words each
    pop es
    ret

; =============================================================================
; alloc_pattern: take every free paragraph, so the image is mostly this
; =============================================================================
alloc_pattern:
    mov ah, 0x48
    mov bx, 0xFFFF
    int 0x21                        ; fails; BX = largest block
    mov [pparas], bx
    mov ah, 0x48
    int 0x21
    mov [pseg], ax
    ret

pmode db 0
; pattern: AL=0 fill, AL=1 verify (count into [bad])
pattern:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    mov word [bad], 0
    mov [pmode], al
    mov es, [pseg]
    mov bx, [pparas]
    mov si, PAT_SEED                ; x = x*25173 + 13849, a word at a time
.para:
    test bx, bx
    jz .done
    xor di, di
    mov cx, 8
.w: mov ax, si
    mov dx, 25173
    mul dx
    add ax, 13849
    mov si, ax
    cmp byte [pmode], 0
    jnz .chk
    stosw
    jmp .nx
.chk:
    cmp ax, [es:di]
    je .same
    inc word [bad]
.same:
    inc di
    inc di
.nx:
    loop .w
    mov ax, es
    inc ax
    mov es, ax
    dec bx
    jmp .para
.done:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; make_swap: \DGSWAP.IMG, size_kb KB, through DOS. Any bytes: it is only there
; to own the clusters. (The snapshot overwrites them with raw int 13h.)
; =============================================================================
make_swap:
    mov dx, swapname
    xor cx, cx
    mov ah, 0x3C
    int 0x21
    jc .bad
    mov bx, ax
    mov cl, 4
    mov ax, [size_kb]
    shr ax, cl                      ; chunks of 16KB
    mov [swap_left], ax
    xor ax, ax
    mov [swap_seg], ax
.chunk:
    mov ax, [swap_seg]
    push ds
    mov ds, ax
    xor dx, dx
    mov cx, 16384
    mov ah, 0x40
    int 0x21
    pop ds
    jc .bad
    cmp ax, 16384
    jne .bad
    add word [swap_seg], 0x400
    dec word [swap_left]
    jnz .chunk
    mov ah, 0x3E
    int 0x21
    mov ah, 0x0D
    int 0x21
    ret
.bad:
    mov dx, msg_swap
    jmp fail
swap_seg dw 0
swap_left dw 0

; =============================================================================
; read_bpb: the boot sector of the current drive, by INT 25h's packet form
; =============================================================================
align_buf:
    ; secbuf = the first 512-aligned (physical) offset in rawbuf
    mov ax, cs
    mov cl, 4
    shl ax, cl
    mov bx, rawbuf
    add ax, bx
    mov dx, ax
    add ax, 511
    and ax, 0xFE00
    sub ax, dx
    add ax, bx
    mov [secbuf], ax
    ret

read_bpb:
    call align_buf
    mov ah, 0x19
    int 0x21
    mov [drive], al
    xor ax, ax
    mov [pk_sec], ax
    mov [pk_sec+2], ax
    mov word [pk_cnt], 1
    mov ax, [secbuf]
    mov [pk_off], ax
    mov [pk_seg], cs
    mov al, [drive]
    mov cx, 0xFFFF
    mov bx, pk_sec
    int 0x25
    pop ax                          ; INT 25h leaves the flags on the stack
    jc .bad
    mov si, [secbuf]
    mov di, bootsave
    mov cx, 256
    rep movsw
    mov si, [secbuf]
    cmp word [si+0x0B], 512
    jne .bad
    mov al, [si+0x0D]
    mov [bpb_spc], al
    mov ax, [si+0x0E]
    mov [bpb_res], ax
    mov al, [si+0x10]
    mov [bpb_nfat], al
    mov ax, [si+0x11]
    mov [bpb_root], ax
    mov ax, [si+0x16]
    mov [bpb_spf], ax
    test ax, ax
    jz .bad                         ; FAT32
    mov ax, [si+0x1C]
    mov [bpb_hid], ax
    mov ax, [si+0x1E]
    mov [bpb_hid+2], ax
    mov ax, [si+0x13]
    xor dx, dx
    test ax, ax
    jnz .t
    mov ax, [si+0x20]
    mov dx, [si+0x22]
.t: mov [bpb_tot], ax
    mov [bpb_tot+2], dx
    ; layout
    mov ax, [bpb_res]
    mov [fat_start], ax
    mov al, [bpb_nfat]
    xor ah, ah
    mul word [bpb_spf]
    add ax, [bpb_res]
    mov [root_start], ax
    mov ax, [bpb_root]
    mov cl, 5
    shl ax, cl
    add ax, 511
    mov cl, 9
    shr ax, cl
    mov [root_secs], ax
    add ax, [root_start]
    mov [data_start], ax
    ; clusters = (total - data_start) / spc ; FAT12 below 4085
    mov ax, [bpb_tot]
    mov dx, [bpb_tot+2]
    sub ax, [data_start]
    sbb dx, 0
    mov bl, [bpb_spc]
    xor bh, bh
    test dx, dx
    jnz .big
    div bx
    cmp ax, 4085
    jb .f12
.big:
    mov byte [fat16], 1
    ret
.f12:
    mov byte [fat16], 0
    ret
.bad:
    mov dx, msg_bpb
    jmp fail

; =============================================================================
; the stub's disk service, from here. in: DX:AX = LBA, CX = count, DI = op
; (2 read, 3 write), buffer ES:BX. Returns CF on error.
; =============================================================================
disk:
    push ds
    push ax
    mov ax, [cs:hseg]
    mov ds, ax
    mov [blk_op], di
    pop ax
    pop ds
    call far [cs:stub_rw_far]
    ret

; read_secs: DX:AX = LBA (volume-relative), CX = count -> secbuf. CF on error
read_secs:
    add ax, [bpb_hid]
    adc dx, [bpb_hid+2]
    mov bx, [secbuf]
    push es
    push cs
    pop es
    mov di, 2
    call disk
    pop es
    ret

; =============================================================================
; find_unit: the BIOS unit whose sector [hidden] is this drive's boot sector
; =============================================================================
find_unit:
    cmp byte [drive], 2
    jae .hd
    mov al, [drive]
    call set_unit
    ret
.hd:
    mov al, 0x80
.try:
    push ax
    call set_unit
    jc .next
    xor ax, ax
    xor dx, dx
    mov cx, 1
    call read_secs                  ; sector 0 of the volume, by BIOS
    jc .next
    mov si, [secbuf]
    mov di, bootsave
    push es
    push cs
    pop es
    mov cx, 256
    repe cmpsw                      ; ...against what DOS read
    pop es
    jne .next
    pop ax
    ret
.next:
    pop ax
    inc al
    cmp al, 0x88
    jb .try
    mov dx, msg_unit
    jmp fail
bootsave times 512 db 0

; set_unit: AL = BIOS unit. Learns its geometry into the block. CF if absent.
set_unit:
    push es
    mov es, [hseg]
    mov [es:blk_unit], al
    mov dl, al
    mov ah, 8
    push es
    int 0x13
    pop es
    jc .out
    mov al, cl
    and al, 0x3F
    xor ah, ah
    mov [es:blk_spt], ax
    mov al, dh
    inc al
    mov [es:blk_heads], ax
    clc
.out:
    pop es
    ret

; =============================================================================
; find_file / build_runs: the swap file's cluster chain, as extents
; =============================================================================
find_file:
    push cs
    pop es
    ; the root directory, a sector at a time
    mov bx, [root_secs]
    mov [rs_left], bx
    mov ax, [root_start]
    mov [rs_cur], ax
.sec:
    cmp word [rs_left], 0
    je .nf
    mov ax, [rs_cur]
    xor dx, dx
    mov cx, 1
    call read_secs
    jc .io
    mov si, [secbuf]
    mov cx, 16
.ent:
    push cx
    push si
    mov di, dirname
    mov cx, 11
    repe cmpsb
    pop si
    pop cx
    je .found
    add si, 32
    loop .ent
    inc word [rs_cur]
    dec word [rs_left]
    jmp .sec
.found:
    mov ax, [si+0x1A]
    mov [file_cl], ax
    mov ax, [si+0x1C]
    mov dx, [si+0x1E]
    mov [file_size], ax
    mov [file_size+2], dx
    ; sectors = (size + 511) / 512
    add ax, 511
    adc dx, 0
    mov cl, 9
    shr ax, cl
    mov cl, 7
    shl dx, cl
    or ax, dx
    mov [nsec_need], ax
    ret
.nf:
    mov dx, msg_dir
    jmp fail
.io:
    mov dx, msg_io
    jmp fail
rs_left dw 0
rs_cur  dw 0

; fat_next: AX = cluster -> AX = next, CF if that is the end of the chain
fat_next:
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, ax
    cmp byte [fat16], 0
    je .f12
    xor dx, dx
    shl ax, 1
    rcl dx, 1                       ; DX:AX = cluster * 2
    jmp .have
.f12:
    shr ax, 1
    add ax, bx                      ; cluster * 1.5
    xor dx, dx
.have:
    mov si, ax
    and si, 511                     ; offset within the sector
    mov cl, 9
    shr ax, cl
    mov cl, 7
    shl dx, cl
    or ax, dx                       ; the FAT sector
    cmp byte [fatsec_ok], 0
    je .load
    cmp ax, [fatsec]
    je .got
.load:
    mov [fatsec], ax
    push bx
    add ax, [fat_start]
    xor dx, dx
    mov cx, 2                       ; two: a FAT12 entry can straddle
    call read_secs
    pop bx
    jc .ioerr
    mov byte [fatsec_ok], 1
.got:
    mov di, [secbuf]
    add di, si
    mov ax, [di]
    cmp byte [fat16], 0
    jne .e16
    test bl, 1
    jz .ev
    mov cl, 4
    shr ax, cl
    jmp .e12
.ev:
    and ax, 0x0FFF
.e12:
    cmp ax, 0x0FF8
    jmp .fin
.e16:
    cmp ax, 0xFFF8
.fin:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    jae .last
    clc
    ret
.last:
    stc
    ret
.ioerr:
    mov dx, msg_io
    jmp fail

; build_runs: walk the chain, coalescing; the list goes to the block
build_runs:
    push es
    push cs
    pop es                          ; fat_next's compares want ES = DS
    mov byte [fatsec_ok], 0
    mov byte [lastflag], 0
    mov ax, [file_cl]
    mov [bcl], ax
    mov ax, [nsec_need]
    mov [bleft], ax
    xor di, di                      ; run count
    mov bx, blk_runs                ; next free slot in the block
.run:
    mov ax, [bcl]
    mov [rstart], ax
    mov word [rclust], 0
.ext:
    inc word [rclust]
    mov ax, [bcl]
    call fat_next
    mov [bnext], ax
    jc .endchain
    mov ax, [bcl]
    inc ax
    cmp ax, [bnext]
    jne .endrun
    mov [bcl], ax
    jmp .ext
.endchain:
    mov byte [lastflag], 1
.endrun:
    cmp di, MAXRUNS
    jae .frag
    mov ax, [rstart]
    sub ax, 2
    mov cl, [bpb_spc]
    xor ch, ch
    mul cx
    add ax, [data_start]
    adc dx, 0
    add ax, [bpb_hid]
    adc dx, [bpb_hid+2]
    push es
    mov es, [hseg]
    mov [es:bx], ax
    mov [es:bx+2], dx
    mov ax, [rclust]
    mov cl, [bpb_spc]
    xor ch, ch
    mul cx
    cmp ax, [bleft]
    jbe .nc
    mov ax, [bleft]
.nc:
    mov [es:bx+4], ax
    pop es
    sub [bleft], ax
    add bx, 6
    inc di
    cmp word [bleft], 0
    je .done
    cmp byte [lastflag], 0
    jne .done
    mov ax, [bnext]
    mov [bcl], ax
    jmp .run
.done:
    push es
    mov es, [hseg]
    mov [es:blk_nruns], di
    pop es
    pop es
    ret
.frag:
    mov dx, msg_frag
    jmp fail
bcl dw 0
bnext dw 0
bleft dw 0
rstart dw 0
rclust dw 0
lastflag db 0

; =============================================================================
; the report
; =============================================================================
emit_str:                           ; SI = zero-terminated
    push di
    mov di, [rptr]
.l: lodsb
    test al, al
    jz .d
    mov [di], al
    inc di
    jmp .l
.d: mov [rptr], di
    pop di
    ret

emit_hex16:                         ; AX
    push ax
    mov al, ah
    call emit_hex8
    pop ax
emit_hex8:                          ; AL. Preserves CX: the report's loops count in it
    push ax
    push cx
    mov cl, 4
    shr al, cl
    pop cx
    call emit_nib
    pop ax
    and al, 0x0F
emit_nib:
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p: mov di, [rptr]
    mov [di], al
    inc di
    mov [rptr], di
    ret

emit_crlf:
    mov di, [rptr]
    mov word [di], 0x0A0D
    add di, 2
    mov [rptr], di
    ret

report:                             ; ES = the block
    mov si, r_title
    call emit_str
    mov si, r_size
    call emit_str
    mov ax, [size_kb]
    call emit_hex16
    call emit_crlf
    mov si, r_hseg
    call emit_str
    mov ax, [hseg]
    call emit_hex16
    call emit_crlf
    mov si, r_orig
    call emit_str
    mov ax, [es:blk_orig_kb]
    call emit_hex16
    call emit_crlf
    mov si, r_hidden
    call emit_str
    mov ax, [es:blk_int12]
    call emit_hex16
    call emit_crlf
    mov si, r_after
    call emit_str
    push es
    xor ax, ax
    mov es, ax
    mov ax, [es:0x413]
    pop es
    call emit_hex16
    call emit_crlf
    mov si, r_ivt
    call emit_str
    mov ax, [es:blk_ivt_bad]
    call emit_hex16
    call emit_crlf
    mov si, r_c08
    call emit_str
    mov ax, [es:blk_clean+2]
    call emit_hex16
    mov al, ':'
    call emit_ch
    mov ax, [es:blk_clean]
    call emit_hex16
    call emit_crlf
    mov si, r_unit
    call emit_str
    mov al, [es:blk_unit]
    call emit_hex8
    call emit_crlf
    mov si, r_nruns
    call emit_str
    mov ax, [es:blk_nruns]
    call emit_hex16
    call emit_crlf
    mov cx, [es:blk_nruns]
    mov bx, blk_runs
.r: test cx, cx
    jz .rd
    mov si, r_run
    call emit_str
    mov ax, [es:bx+2]
    call emit_hex16
    mov ax, [es:bx]
    call emit_hex16
    mov al, ' '
    call emit_ch
    mov ax, [es:bx+4]
    call emit_hex16
    call emit_crlf
    add bx, 6
    dec cx
    jmp .r
.rd:
    mov si, r_bad
    call emit_str
    mov ax, [bad]
    call emit_hex16
    call emit_crlf
    mov si, r_pseg
    call emit_str
    mov ax, [pseg]
    call emit_hex16
    call emit_crlf
    mov si, r_pat
    call emit_str
    mov ax, [pparas]
    call emit_hex16
    call emit_crlf
    mov si, r_ok
    call emit_str
    call emit_crlf
    mov di, [rptr]
    mov byte [di], 0
    ret

emit_ch:
    mov di, [rptr]
    mov [di], al
    inc di
    mov [rptr], di
    ret

r_title  db 'DG W1 RESULT', 13, 10, 0
r_size   db 'size_kb=', 0
r_hseg   db 'hseg=', 0
r_orig   db 'orig_kb=', 0
r_hidden db 'int12_hidden=', 0
r_after  db 'int12_after=', 0
r_unit   db 'unit=', 0
r_ivt    db 'ivt_mismatches=', 0
r_c08    db 'clean_int08=', 0
r_nruns  db 'nruns=', 0
r_run    db 'run=', 0
r_bad    db 'mismatches=', 0
r_pat    db 'pattern_paras=', 0
r_pseg   db 'pattern_seg=', 0
r_ok     db 'resumed=1', 0

write_report:
    mov dx, rbuf
    mov si, rbuf
.len:
    cmp byte [si], 0
    je .go
    inc si
    jmp .len
.go:
    mov cx, si
    sub cx, rbuf
    mov [rlen], cx
    ; console
    mov bx, 1
    mov dx, rbuf
    mov ah, 0x40
    int 0x21
    ; file
    mov dx, resname
    xor cx, cx
    mov ah, 0x3C
    int 0x21
    jc .out
    mov bx, ax
    mov dx, rbuf
    mov cx, [rlen]
    mov ah, 0x40
    int 0x21
    mov ah, 0x3E
    int 0x21
.out:
    ret
rlen dw 0

; =============================================================================
; THE STUB. Assembled here, copied to the hidden block, runs there. Offsets are
; from the block's start (vstart=0), so a label is an offset in the block and
; the launcher reaches the block's data as [es:label].
; =============================================================================
; the launcher's own stack. It is in .text because a section that follows the
; stub (vstart=0) is placed by the stub's VIRTUAL end, which is not the file's.
            times 256 db 0
mystack:
stub_load:
section .stub vstart=0 follows=.text align=1
stub_start:
STUB_SUSPEND equ 0
STUB_TRASH   equ 3
STUB_RW      equ 6
    jmp stub_suspend                ; +0   far call: write the snapshot
    jmp stub_trash                  ; +3   far call: trash, then restore
    jmp stub_rw                     ; +6   far call: DX:AX LBA, CX count

; ----- the block's data, at fixed offsets --------------------------------------
blk_seg     dw 0
blk_size_kb dw 0
blk_orig_kb dw 0
blk_int12   dw 0
blk_unit    db 0
blk_pad     db 0
blk_spt     dw 0
blk_heads   dw 0
blk_op      dw 2
blk_rom13   dw 0, 0
blk_nruns   dw 0
sv_ss       dw 0
sv_sp       dw 0
sv_ds       dw 0
sv_es       dw 0
sv_bp       dw 0
sv_si       dw 0
sv_di       dw 0
sv_m1       db 0
sv_m2       db 0
t_lba       dw 0, 0
t_cnt       dw 0
t_cyl       dw 0
t_hd        dw 0
t_sec0      dw 0
t_n         dw 0
t_run       dw 0
at_flag     db 0
blk_err     dw 0
blk_fixirq  db 0
blk_ivt_bad dw 0
blk_clean   times 16 dd 0           ; the ROM vectors, 08-0F then 70-77
blk_dosvec  times 16 dd 0           ; DOS's, as the live IVT held them

; ----- bios: INT 13h through the saved ROM vector, immune to the IVT's restore -
bios13:
    cmp byte [cs:blk_fixirq], 0
    je .go
    push ax
    push es
    xor ax, ax
    mov es, ax
    mov ax, [cs:blk_clean + 6*4]        ; INT 0Eh: the floppy's IRQ
    mov [es:0x38], ax
    mov ax, [cs:blk_clean + 6*4 + 2]
    mov [es:0x3A], ax
    mov ax, [cs:blk_clean + 14*4]       ; INT 76h: the hard disk's
    mov [es:0x1D8], ax
    mov ax, [cs:blk_clean + 14*4 + 2]
    mov [es:0x1DA], ax
    pop es
    pop ax
.go:
    pushf
    call far [cs:blk_rom13]
    ret

; ivt_addr: BX = index 0..15 -> BX = the vector's address in the IVT
ivt_addr:
    cmp bx, 8
    jae .hi
    shl bx, 1
    shl bx, 1
    add bx, 0x20
    ret
.hi:
    sub bx, 8
    shl bx, 1
    shl bx, 1
    add bx, 0x1C0
    ret

; ivt_op: AL=0 save the live IVT to blk_dosvec, 1 apply blk_clean, 2 compare
; (the number that differ goes to blk_ivt_bad)
ivt_op:
    push ds
    push es
    push si
    push di
    push bx
    push cx
    mov [cs:op_al], al
    xor ax, ax
    mov es, ax
    mov ax, cs
    mov ds, ax
    xor si, si
    mov word [blk_ivt_bad], 0
.v: mov bx, si
    call ivt_addr
    mov di, si
    shl di, 1
    shl di, 1
    mov al, [op_al]
    test al, al
    jnz .notsave
    mov ax, [es:bx]
    mov [blk_dosvec+di], ax
    mov ax, [es:bx+2]
    mov [blk_dosvec+di+2], ax
    jmp .nx
.notsave:
    cmp al, 1
    jne .cmp
    mov ax, [blk_clean+di]
    mov [es:bx], ax
    mov ax, [blk_clean+di+2]
    mov [es:bx+2], ax
    jmp .nx
.cmp:
    mov ax, [es:bx]
    cmp ax, [blk_dosvec+di]
    jne .bad
    mov ax, [es:bx+2]
    cmp ax, [blk_dosvec+di+2]
    je .nx
.bad:
    inc word [blk_ivt_bad]
.nx:
    inc si
    cmp si, 16
    jb .v
    pop cx
    pop bx
    pop di
    pop si
    pop es
    pop ds
    ret
op_al db 0

; ----- lba_chs: DX:AX -> t_cyl, t_hd, t_sec0 ; CF if the cylinder will not fit -
lba_chs:
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, ax
    mov cx, [cs:blk_spt]
    mov ax, dx
    xor dx, dx
    div cx
    mov si, ax                      ; quotient, high word
    mov ax, bx
    div cx                          ; dx = sector - 1
    mov [cs:t_sec0], dx
    mov di, ax                      ; quotient, low word
    mov cx, [cs:blk_heads]
    mov ax, si
    xor dx, dx
    div cx
    test ax, ax
    jnz .toobig
    mov ax, di
    div cx                          ; ax = cylinder, dx = head
    mov [cs:t_hd], dx
    mov [cs:t_cyl], ax
    cmp ax, 1024
    jae .toobig
    clc
    jmp .o
.toobig:
    stc
.o: pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----- stub_rw: DX:AX = LBA, CX = count, ES:BX = buffer (512-aligned, bx=0 ok),
;       [blk_op] = 2 read / 3 write. On return ES has advanced, CF = failure.
stub_rw:
    push ds
    push si
    push di
    push bp
    mov si, cs
    mov ds, si
    mov [t_lba], ax
    mov [t_lba+2], dx
    mov [t_cnt], cx
.next:
    cmp word [t_cnt], 0
    je .ok
    mov ax, [t_lba]
    mov dx, [t_lba+2]
    call lba_chs
    jc .fail
    ; n = min(spt - sec0, count, 63, DMA room)
    mov ax, [blk_spt]
    sub ax, [t_sec0]
    cmp ax, [t_cnt]
    jbe .a
    mov ax, [t_cnt]
.a: cmp ax, 63
    jbe .b
    mov ax, 63
.b: mov [t_n], ax
    mov ax, es
    mov cl, 4
    shl ax, cl
    add ax, bx
    test ax, 511
    jnz .fail                       ; not 512-aligned: refuse, as the kernel's rule
    neg ax                          ; 0x10000 - low word (0 means a whole 64KB)
    jz .c
    mov cl, 9
    shr ax, cl
    cmp ax, [t_n]
    jae .c
    mov [t_n], ax
.c: mov bp, 3                       ; three tries
.try:
    mov ax, [t_cyl]
    mov ch, al
    mov al, ah
    mov cl, 6
    shl al, cl                      ; cylinder bits 8-9 go to CL bits 6-7
    mov cl, al
    mov ax, [t_sec0]
    inc al
    or cl, al
    mov dh, [t_hd]
    mov dl, [blk_unit]
    mov ax, [blk_op]
    mov ah, al
    mov al, [t_n]
    call bios13
    jnc .did
    xor ax, ax
    mov dl, [blk_unit]
    call bios13                     ; reset
    dec bp
    jnz .try
    mov [blk_err], ax
    jmp .fail
.did:
    mov ax, [t_n]
    add [t_lba], ax
    adc word [t_lba+2], 0
    sub [t_cnt], ax
    mov cl, 5
    shl ax, cl                      ; sectors * 32 paragraphs
    mov cx, es
    add cx, ax
    mov es, cx
    jmp .next
.ok:
    clc
    jmp .out
.fail:
    stc
.out:
    pop bp
    pop di
    pop si
    pop ds
    retf

; ----- every extent, in order: op in [blk_op], memory from linear 0 ------------
image_io:
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    xor bx, bx
    mov si, blk_runs
    mov cx, [blk_nruns]
.r: test cx, cx
    jz .ok
    push cx
    push si
    mov ax, [si]
    mov dx, [si+2]
    mov cx, [si+4]
    push cs
    call .near                      ; stub_rw ends in retf
    jmp .back
.near:
    jmp stub_rw
.back:
    pop si
    pop cx
    pushf
    xor bx, bx
    popf
    jc .fail
    add si, 6
    dec cx
    jmp .r
.ok:
    clc
    ret
.fail:
    stc
    ret

; ----- pic: the masks that keep every IRQ but the disks quiet -----------------
pic_quiet:
    in al, 0x21
    mov [cs:sv_m1], al
    mov al, 0xBB                    ; IRQ6 and the cascade only
    out 0x21, al
    cmp byte [cs:at_flag], 0
    je .xt
    in al, 0xA1
    mov [cs:sv_m2], al
    mov al, 0xBF                    ; IRQ14 only
    out 0xA1, al
.xt:
    ret
pic_back:
    mov al, [cs:sv_m1]
    out 0x21, al
    cmp byte [cs:at_flag], 0
    je .xt
    mov al, [cs:sv_m2]
    out 0xA1, al
.xt:
    ret

; ----- stub_suspend: far call from the launcher; it returns twice --------------
stub_suspend:
    mov [cs:sv_ds], ds
    mov [cs:sv_es], es
    mov [cs:sv_bp], bp
    mov [cs:sv_si], si
    mov [cs:sv_di], di
    mov [cs:sv_ss], ss
    mov [cs:sv_sp], sp
    cli
    mov ax, cs
    mov ss, ax
    mov sp, ST_STACK
    sti
    ; an AT-class machine has a second PIC: the BIOS model byte, F000:FFFE
    push ds
    mov ax, 0xF000
    mov ds, ax
    mov al, [0xFFFE]
    pop ds
    cmp al, 0xFC
    mov byte [cs:at_flag], 0
    jne .nat
    mov byte [cs:at_flag], 1
.nat:
    call pic_quiet
    MARK 's'
    mov word [cs:blk_op], 3
    call image_io
    MARK 'w'
    jc .fail
    ; the live IVT: remember DOS's, then name the ROM (plan 4.2)
    xor al, al
    call ivt_op
    mov al, 1
    call ivt_op
    ; hide the block from anything that sizes itself from int 12h
    xor ax, ax
    mov es, ax
    mov ax, [cs:blk_size_kb]
    mov [es:0x413], ax
    int 0x12
    mov [cs:blk_int12], ax
    call pic_back
    MARK 'r'
    ; first return: AX = 0, the caller's own stack and registers
    mov ss, [cs:sv_ss]
    mov sp, [cs:sv_sp]
    mov ds, [cs:sv_ds]
    mov es, [cs:sv_es]
    mov bp, [cs:sv_bp]
    mov si, [cs:sv_si]
    mov di, [cs:sv_di]
    xor ax, ax
    retf
.fail:
    call pic_back
    mov ss, [cs:sv_ss]
    mov sp, [cs:sv_sp]
    mov ds, [cs:sv_ds]
    mov es, [cs:sv_es]
    mov ax, 2
    retf

; ----- stub_trash: what os8088 does to the machine, then the restore -----------
stub_trash:
    MARK 't'
    cli
    mov ax, cs
    mov ss, ax
    mov sp, ST_STACK
    sti
    call pic_quiet
    ; 0xCC over 0000:0500 .. the image's top, a window at a time
    mov dx, [cs:blk_size_kb]
    mov cl, 6
    shl dx, cl                      ; paragraphs in the image
    xor bx, bx                      ; the window's segment
    mov di, 0x500
.win:
    mov ax, dx
    sub ax, bx                      ; paragraphs left
    cmp ax, 0x1000
    jbe .lim
    mov ax, 0x1000
.lim:
    mov cl, 3
    shl ax, cl                      ; words
    mov cx, ax
    test di, di
    jz .nf
    sub cx, 0x280                   ; the first window starts at 0x500
.nf:
    mov es, bx
    mov ax, 0xCCCC
    rep stosw
    xor di, di
    add bx, 0x1000
    cmp bx, dx
    jb .win
    MARK 'f'
    ; the restore: the same extents, read. The IVT is the first thing it
    ; overwrites, and the disk's own IRQ vectors have to name ROM until it ends
    mov word [cs:blk_op], 2
    mov byte [cs:blk_fixirq], 1
%ifdef BREAK_RESTORE
    clc                             ; the negative control: trash, never restore
%else
    call image_io
%endif
    mov byte [cs:blk_fixirq], 0
    MARK 'x'
    jc .fail
    xor ax, ax
    mov es, ax
    ; DOS's INT 0Eh and 76h, which the last disk call had replaced
    mov ax, [cs:blk_dosvec + 6*4]
    mov [es:0x38], ax
    mov ax, [cs:blk_dosvec + 6*4 + 2]
    mov [es:0x3A], ax
    mov ax, [cs:blk_dosvec + 14*4]
    mov [es:0x1D8], ax
    mov ax, [cs:blk_dosvec + 14*4 + 2]
    mov [es:0x1DA], ax
    mov al, 2
    call ivt_op                     ; the IVT is DOS's again, or it is not
    xor ax, ax
    mov es, ax
    mov ax, [cs:blk_orig_kb]
    mov [es:0x413], ax
    call pic_back
    mov ss, [cs:sv_ss]
    mov sp, [cs:sv_sp]
    mov ds, [cs:sv_ds]
    mov es, [cs:sv_es]
    mov bp, [cs:sv_bp]
    mov si, [cs:sv_si]
    mov di, [cs:sv_di]
    mov ax, 1
    retf                            ; the second return from stub_suspend
.fail:
    mov ax, 0xB800                  ; nothing left to return to: say so on screen
    mov es, ax
    mov word [es:0], 0x4F45         ; 'E' white on red
    jmp $

blk_runs    times (MAXRUNS * 6) db 0
stub_end:
