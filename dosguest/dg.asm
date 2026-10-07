; =============================================================================
; os8088 - dosguest/dg.asm
;
; THE LAUNCHER, WAVES 1 AND 2 (docs/plans/DOSGUEST-PLAN.md 9): suspend DOS to a
; file; then either trash what os8088 would trash and put DOS back (the
; self-test), or BOOT os8088 from a floppy, and put DOS back when it Restarts.
;
;   DG.COM        prints what to type
;   DG.COM /T     the self-test, no os8088; writes \DGRESULT.TXT
;   DG.COM B:     boot os8088 from the floppy in B: (or A:). Its Restart is the
;                 way home: the launcher points INT 19h at the stub
;   DG.COM /K     ...either way, keep \DGSWAP.IMG so the host can read it back
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
HB_PARAS    equ 0x200               ; the hidden block: 8KB (stub, extents, a 1KB bounce)
VIDEO_KB    equ 32                  ; the swap file's video area, after the image
VIDEO_SECS  equ VIDEO_KB * 2
MAXRUNS     equ 128                 ; extents; 6 bytes each
ST_STACK    equ 0x1FF0              ; the stub's stack top, inside the block
ST_STACK_USE equ 512                ; what it may use below that
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
prime       db 0                    ; /P: re-populate DOS's directory cache (a test)
noinval     db 0                    ; /N: skip invalidating DOS's buffers (a test)
a20flip     db 0                    ; /A: leave A20 the wrong way round on return (a test)
a20skip     db 0                    ; /Z: ...and do not put it right (the control)
extshow     db 0                    ; /X: show os8088 the extended memory (the control)
force3      db 0
dos_classic db 0                    ; DOS before 3.31: INT 25h's classic form only
chsonly     db 0                    ; /C: CHS only, never the extended calls (a test)
wflag       db 0                    ; /W: let os8088 WRITE (see wmask); the default is no unit
wmask       db 0                    ; bit n = floppy n, bit 7 = any hard disk
wtest       db 0                    ; /F: try a write through the live INT 13h (a test)
verbose     db 0                    ; /V: print the report, not only write it
selftest    db 0                    ; /T: the self-test
t_snap      dw 0, 0                 ; seconds of the day at the snapshot, and after
t_after     dw 0, 0
tmp_h       db 0
tmp_m       db 0
tmp_s       db 0
bootmode    db 0                    ; 1 = boot os8088 from bootunit
bootunit    db 0
bootdrive   db 0                    ; the DOS drive letter, 0 = A
boothd      db 0                    ; 1: a hard-disk volume
bootlba     dw 0, 0                 ; its first sector, absolute: the volume's hidden sectors
swap_unit   db 0
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

msg_boot    db 'DG: the drive to boot os8088 from is a letter A: to Z:', 13, 10, '$'
msg_loc     db 'DG: cannot find that drive on the BIOS (is it a hard-disk volume DOS owns?)', 13, 10, '$'
msg_v86     db 'DG: the CPU is in protected or virtual-8086 mode (EMM386, JEMM, QEMM, Windows)', 13, 10
            db '    os8088 needs the real machine. Boot without the memory manager.', 13, 10, '$'
msg_usage   db 'DG: start os8088 from DOS, and come back to DOS when it Restarts.', 13, 10, 13, 10
            db '  DG B:     boot os8088 from the floppy in drive B: (or A:)', 13, 10
            db '  DG D:     boot an os8088 hard-disk install from DOS drive D: (any letter)', 13, 10, 13, 10
            db 'In os8088, System menu (the logo, top left) then Restart returns you here', 13, 10
            db 'with your screen, clock, drivers and memory as they were. os8088 may not', 13, 10
            db 'write to your disks unless you add /W (boot unit), /WH (hard disks) or /W*.', 13, 10, 13, 10
            db 'Options: /K keep \DGSWAP.IMG   /V print the report   /T self-test, no os8088', 13, 10, '$'
msg_back    db 'DG: DOS is back. The report is in \DGRESULT.TXT.', 13, 10, '$'
msg_dos     db 'DG: needs DOS 3.0 or later', 13, 10, '$'
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
    je .sw
    cmp al, ' '
    je .cl
    ; a letter and a colon: the DOS drive os8088 is to boot from. A: and B: are
    ; the floppies (BIOS units 0 and 1); a higher letter is a hard-disk volume, whose
    ; BIOS unit and partition start are found by locate_boot once the stub exists.
    mov ah, al
    and ah, 0xDF
    cmp byte [si], ':'
    jne .cl
    sub ah, 'A'
    cmp ah, 25
    ja .badboot
    mov [bootdrive], ah
    mov [bootunit], ah
    cmp ah, 2
    jb .flop
    mov byte [boothd], 1
    mov byte [bootunit], 0x80       ; until locate_boot says which
.flop:
    mov byte [bootmode], 1
    inc si
    jmp .cl
.sw:
    lodsb
    and al, 0xDF
    cmp al, 'K'
    jne .sw2
    mov byte [keep], 1
    jmp .cl
.sw2:
    cmp al, 'P'
    jne .sw3
    mov byte [prime], 1
    jmp .cl
.sw3:
    cmp al, 'N'
    jne .sw4
    mov byte [noinval], 1
    jmp .cl
.sw4:
    cmp al, 'A'
    jne .sw5
    mov byte [a20flip], 1
    jmp .cl
.sw5:
    cmp al, 'Z'
    jne .sw6
    mov byte [a20skip], 1
    jmp .cl
.sw6:
    cmp al, 'X'
    jne .sw7
    mov byte [extshow], 1
    jmp .cl
.sw7:
    cmp al, 'F'
    jne .sw8
    mov byte [wtest], 1
    jmp .cl
.sw8:
    cmp al, 'V'
    jne .sw8b
    mov byte [verbose], 1           ; /V: the whole report on the console as well
    jmp .cl
.sw8b:
    cmp al, 'T'
    jne .sw8c
    mov byte [selftest], 1          ; /T: suspend, trash, restore - and no os8088
    jmp .cl
.sw8c:
    cmp al, 'C'
    jne .sw9
    mov byte [chsonly], 1
    jmp .cl
.sw9:
    cmp al, '3'
    jne .swa
    mov byte [force3], 1            ; /3: use INT 25h's classic form whatever DOS this is (a test)
    jmp .cl
.swa:
    cmp al, 'W'
    jne .cl
    mov byte [wflag], 1             ; /W alone: the os8088 boot unit. /WA /WB /WH /W*:
.wl:                                ; floppy A, floppy B, any hard disk, everything
    mov al, [si]
    cmp al, '*'
    jne .wa
    mov byte [wmask], 0xFF
    jmp .wn
.wa:
    and al, 0xDF
    cmp al, 'A'
    jne .wb
    or byte [wmask], 1
    jmp .wn
.wb:
    cmp al, 'B'
    jne .wh
    or byte [wmask], 2
    jmp .wn
.wh:
    cmp al, 'H'
    jne .cl
    or byte [wmask], 0x80
.wn:
    inc si
    jmp .wl
.badboot:
    mov dx, msg_boot
    jmp fail
.cldone:
    ; no drive and no /T: a person typed DG. Say what it is for - the self-test used to
    ; run here, which suspends DOS, trashes memory, restores it and says "DOS is back",
    ; and leaves the reader with no idea that os8088 was never started
    cmp byte [bootmode], 0
    jne .haveaction
    cmp byte [selftest], 0
    jne .haveaction
    mov dx, msg_usage
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21
.haveaction:
    ; --- DOS 3.0 or later. 3.31 and up read the boot sector with INT 25h's packet
    ; form, which names a sector with 32 bits; 3.0 to 3.30 have only the classic
    ; form (a 16-bit sector number), so a volume over 32 MB is out of reach there.
    ; THE CLASSIC PATH IS UNTESTED: no DOS 3.x was available to run it on.
    mov ah, 0x30
    int 0x21
    cmp al, 4
    jae .dosok
    cmp al, 3
    jne .dosbad
    cmp ah, 31
    jae .dosok
    mov byte [dos_classic], 1
    jmp .dosok
.dosbad:
    mov dx, msg_dos
    jmp fail
.dosok:
    cmp byte [force3], 0
    je .nf3
    mov byte [dos_classic], 1
.nf3:
    int 0x12
    mov [total_kb], ax
    call check_real_mode
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
    call build_clean                ; needs the block: an IRET lives in it
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
    call prime_cache
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
    cmp byte [boothd], 0
    je .nolocate
    call locate_boot                ; a hard-disk os8088: which unit, which sector
.nolocate:
    ; --- state the stub needs that is not in the image ----------------------
    MARK 'i'
    ; --- THE SNAPSHOT: a second return from this call is the resume ----------
    call dos_secs
    mov [t_snap], ax
    mov [t_snap+2], dx
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
    cmp byte [wtest], 0
    je .nowt
    call write_test                 ; through the LIVE int 13h: os8088's
.nowt:
    cmp byte [bootmode], 0
    je .trash
    call far [cs:stub_boot_far]     ; never returns: Restart's int 19h does
.trash:
    call far [cs:stub_trash_far]    ; never returns: the resume does
    mov dx, msg_stub
    jmp fail

resumed:
    MARK 'R'
    cmp byte [noinval], 0
    jne .nobuf
    call inval_buffers
.nobuf:
    call fix_clock
    call dos_secs
    mov [t_after], ax
    mov [t_after+2], dx
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
; the vector policy (plan 4.2). os8088 inherits the live IVT, and so does the
; BIOS under it: the ROM's INT 08h handler calls INT 1Ch, its INT 09h calls
; INT 1Bh on Ctrl-Break, its INT 70h calls INT 4Ah, and os8088 calls INT 10h,
; 13h, 15h, 16h and 1Ah itself. A DOS or a TSR that hooked any of them has sent
; the call into memory os8088 is about to overwrite. DOS's own vectors stay in
; the swap image and come back on the resume; what is built here is the CLEAN
; set the stub puts in the live IVT after the snapshot, and it covers every
; vector in this table.
;
; CLASS 0, a vector that is CALLED FOR ITS RESULT (an IRQ or a BIOS service): it
; has to name the ROM. Already in ROM, it is its own clean value. Otherwise the
; launcher follows it through the two shapes that keep the old vector inline -
; the IBM Interrupt Sharing Protocol header (EB 10 | dd old | 'KB' | 00 | EB F4)
; and FreeDOS's wrapper (E8 rel16 | dd old) - up to eight links. Anything else
; in RAM is a TSR it cannot see through, and the launcher REFUSES, naming it.
;
; CLASS 1, a hook the BIOS makes and nothing depends on (INT 1Bh, 1Ch, 4Ah, and
; the CPU's 00h to 07h): in ROM it stays; in RAM it becomes an IRET in the block.
; That is what the ROM's own default is, so os8088 sees what a BIOS boot gives.
;
; Not in the table, left DOS's: INT 20h and up (DOS's, and os8088 never calls
; them), and the data pointers 1Dh, 1Eh, 1Fh, 41h, 43h, 46h.
; =============================================================================
vec_tab     db 0x08, 0, 0x09, 0, 0x0A, 0, 0x0B, 0, 0x0C, 0, 0x0D, 0, 0x0E, 0, 0x0F, 0
            db 0x70, 0, 0x71, 0, 0x72, 0, 0x73, 0, 0x74, 0, 0x75, 0, 0x76, 0, 0x77, 0
            db 0x10, 0, 0x11, 0, 0x12, 0, 0x13, 0, 0x14, 0, 0x15, 0, 0x16, 0, 0x17, 0
            db 0x1A, 0
            db 0x00, 1, 0x01, 1, 0x02, 1, 0x03, 1, 0x04, 1, 0x05, 1, 0x06, 1, 0x07, 1
            db 0x1B, 1, 0x1C, 1, 0x4A, 1
            db 0xFF
MAXVEC      equ 48
cleanlist   times (MAXVEC * 6) db 0        ; vec word, off word, seg word
cl_ptr      dw cleanlist
cl_count    dw 0
cl_i13      dw 0                    ; the entries the stub needs by name
cl_i0e      dw 0
cl_i76      dw 0
cl_i15      dw 0
vec_cur     dw 0
cls_cur     db 0
heur_n      dw 0                    ; vectors unwrapped by the heuristic, reported

build_clean:
    xor si, si                      ; into vec_tab, two bytes an entry
.l: mov al, [vec_tab+si]
    cmp al, 0xFF
    je .done
    xor ah, ah
    mov [vec_cur], ax
    mov al, [vec_tab+si+1]
    mov [cls_cur], al
    mov bx, [vec_cur]
    shl bx, 1
    shl bx, 1
    xor ax, ax
    mov es, ax
    mov ax, [es:bx]                 ; offset
    mov dx, [es:bx+2]               ; segment
    mov cx, 8                       ; chain depth
.chase:
    cmp dx, 0xC000
    jae .ok
    mov es, dx
    mov bx, ax
    cmp byte [es:bx], 0xEB
    jne .notiisp
    cmp byte [es:bx+1], 0x10
    jne .nope
    cmp word [es:bx+6], 0x424B
    jne .nope
    mov ax, [es:bx+2]
    mov dx, [es:bx+4]
    jmp .again
.notiisp:
    cmp byte [es:bx], 0xE8
    jne .heur
    mov ax, [es:bx+3]
    mov dx, [es:bx+5]
    jmp .again
.heur:
    ; Not a shape that says where the old vector is. Most TSRs chain with a far
    ; jump or call through a variable in their own segment, so look for one whose
    ; target is in ROM. ES:BX is the handler.
    call scan_chain                 ; AX:DX <- the old vector, CF if none found
    jc .nope
    inc word [heur_n]
.again:
    loop .chase
.nope:
    cmp byte [cls_cur], 0
    jne .iret
    mov di, ax                      ; where it points: DX:DI
    mov bx, [vec_cur]
    jmp refuse_vec
.iret:
    mov ax, STUB_IRET
    mov dx, [hseg]
.ok:
    mov di, [cl_ptr]
    mov bx, [vec_cur]
    cmp bx, 0x13
    jne .n13
    mov cx, [cl_count]
    mov [cl_i13], cx
.n13:
    cmp bx, 0x0E
    jne .n0e
    mov cx, [cl_count]
    mov [cl_i0e], cx
.n0e:
    cmp bx, 0x76
    jne .n76
    mov cx, [cl_count]
    mov [cl_i76], cx
.n76:
    cmp bx, 0x15
    jne .n15
    mov cx, [cl_count]
    mov [cl_i15], cx
.n15:
    mov [di], bx
    mov [di+2], ax
    mov [di+4], dx
    add word [cl_ptr], 6
    inc word [cl_count]
    add si, 2
    jmp .l
.done:
    push cs
    pop es
    ret

; scan_chain: ES:BX = a handler in RAM. Look in its first 128 bytes for
;     2E FF 2E w   jmp far cs:[w]        2E FF 1E w   call far cs:[w]
;     EA o o s s   jmp far s:o
; and take the far pointer if it names ROM (segment C000 or above), which is the
; one thing that makes it believable: a variable in a TSR's own data holding a
; ROM address is the old vector. Returns AX:DX = offset:segment, CF if none.
; HEURISTIC, and counted in [heur_n] so a run says how many vectors rested on it.
scan_chain:
    push cx
    push si
    mov si, bx
    mov cx, 128
.s: cmp byte [es:si], 0x2E
    jne .ea
    cmp byte [es:si+1], 0xFF
    jne .ea
    mov al, [es:si+2]
    cmp al, 0x2E
    je .mem
    cmp al, 0x1E
    jne .ea
.mem:
    push bx
    mov bx, [es:si+3]               ; the variable, in the handler's own segment
    mov ax, [es:bx]
    mov dx, [es:bx+2]
    pop bx
    cmp dx, 0xC000
    jb .ea
    call plausible
    jnc .found
.ea:
    cmp byte [es:si], 0xEA
    jne .nx
    mov dx, [es:si+3+2]
    cmp dx, 0xC000
    jb .nx
    mov ax, [es:si+3]
    call plausible
    jnc .found
.nx:
    inc si
    loop .s
    stc
    jmp .out
.found:
    clc
.out:
    pop si
    pop cx
    ret

; plausible: DX:AX = a far pointer into the ROM area. CF set if what is there
; cannot be a handler's first instruction: unmapped ROM space reads FF, unused
; memory 00, and a first instruction is neither. Without this the scan took four
; bytes of an XMS driver's own code (00 F0 33 C0, `add al,dh; xor ax,ax`) for a
; ROM vector, and os8088 called into nothing.
plausible:
    push es
    push bx
    mov es, dx
    mov bx, ax
    mov bl, [es:bx]
    mov bh, bl                      ; the first byte, twice
    cmp bl, 0xFF
    je .no
    test bl, bl
    jz .no
    clc
    jmp .out
.no:
    stc
.out:
    pop bx
    pop es
    ret

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
; check_real_mode: refuse under a memory manager that put DOS in virtual-8086
; mode (EMM386, JEMM, QEMM) or under Windows. os8088 takes the machine over, and
; the stub does raw port I/O and boots a real-mode OS: none of that is the real
; machine's. `smsw` is a 286 instruction, so an 8086 or 186 has to be told apart
; first, by the flags: on those, bits 15 to 12 cannot be cleared. (And on those
; there is no V86 to be in.)
; =============================================================================
check_real_mode:
    pushf
    pop ax
    and ax, 0x0FFF
    push ax
    popf
    pushf
    pop ax
    and ax, 0xF000
    cmp ax, 0xF000
    je .real                        ; 8086/186: the high flag bits stick at 1
    db 0x0F, 0x01, 0xE0             ; smsw ax (a 286 opcode, written out)
    test al, 1                      ; PE: protected mode, which for DOS means V86
    jnz .v86
.real:
    ret
.v86:
    mov dx, msg_v86
    jmp fail

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
    mov ax, [size_kb]
    shl ax, 1
    mov [es:blk_img_secs], ax       ; the image is this many sectors of the file
    ; the bounce buffer for the video area has to be 512-aligned PHYSICALLY (the
    ; stub's disk service refuses otherwise), and the block is only paragraph
    ; aligned: offset = stub_end + whatever reaches the next 512
    mov ax, [hseg]
    mov cl, 4
    shl ax, cl
    add ax, stub_end
    neg ax
    and ax, 511
    add ax, stub_end
    mov [es:blk_bounce], ax
    mov al, [bootunit]
    mov [es:blk_bootunit], al
    mov al, [bootmode]
    mov [es:blk_bootmode], al
    pop es
    ; far pointers into the block
    mov ax, [hseg]
    mov word [stub_suspend_far], STUB_SUSPEND
    mov [stub_suspend_far+2], ax
    mov word [stub_trash_far], STUB_TRASH
    mov [stub_trash_far+2], ax
    mov word [stub_rw_far], STUB_RW
    mov [stub_rw_far+2], ax
    mov word [stub_boot_far], STUB_BOOT
    mov [stub_boot_far+2], ax
    ret

stub_suspend_far dw 0, 0
stub_trash_far   dw 0, 0
stub_rw_far      dw 0, 0
stub_boot_far    dw 0, 0

; =============================================================================
; save_vectors: the ROM's int 13h, the PIC masks and the original memory size
; go into the block, where the stub keeps them
; =============================================================================
save_vectors:
    push es
    xor ax, ax
    mov es, ax
    mov bx, [es:0x413]
    mov es, [hseg]
    mov [es:blk_orig_kb], bx
    ; the clean list, and by name the three entries the stub uses directly
    mov ax, [cl_count]
    mov [es:blk_clcnt], ax
    mov si, cleanlist
    mov di, blk_cl
    mov cx, MAXVEC * 3
    rep movsw
    mov bx, [cl_i13]
    call .ent
    mov ax, [si+2]
    mov [es:blk_rom13], ax
    mov ax, [si+4]
    mov [es:blk_rom13+2], ax
    mov bx, [cl_i0e]
    call .ent
    mov ax, [si+2]
    mov [es:blk_cl0e], ax
    mov ax, [si+4]
    mov [es:blk_cl0e+2], ax
    mov bx, [cl_i76]
    call .ent
    mov ax, [si+2]
    mov [es:blk_cl76], ax
    mov ax, [si+4]
    mov [es:blk_cl76+2], ax
    mov bx, [cl_i15]
    call .ent
    mov ax, [si+2]
    mov [es:blk_rom15], ax
    mov ax, [si+4]
    mov [es:blk_rom15+2], ax
    ; os8088 is given an INT 15h that reports NO extended memory and refuses
    ; block moves, so its XMEM.DRV does not load on top of an XMS manager (the
    ; clean entry was the ROM's; the ROM's stays in blk_rom15 for everything else)
    cmp byte [extshow], 0
    jne .nofilter
    sub si, cleanlist
    add si, blk_cl
    mov word [es:si+2], stub_int15
    mov ax, [hseg]
    mov [es:si+4], ax
    mov byte [es:blk_filter], 1
.nofilter:
    ; ...and an INT 13h that REFUSES WRITES to any unit DOS can see, except the ones
    ; /W names (by default only the floppy os8088 was booted from, and with a bare
    ; /W). os8088 reaches its disks through this vector, so a volume DOS has cached
    ; cannot be changed under it. A DRIVER THAT TALKS TO THE IDE PORTS DIRECTLY
    ; (os8088's hard-disk driver can) is not stopped by it.
    mov al, [wmask]
    cmp byte [wflag], 0
    je .wm
    test al, al
    jnz .wm
    mov cl, [bootunit]              ; a bare /W: the unit os8088 booted from
    mov al, 0x80                    ; a hard disk: bit 7...
    cmp cl, 0x80
    jae .wm
    mov al, 1                       ; ...a floppy: its own bit
    shl al, cl
.wm:
    mov [es:blk_wmask], al
    mov bx, [cl_i13]
    call .ent
    sub si, cleanlist
    add si, blk_cl
    mov word [es:si+2], stub_int13
    mov ax, [hseg]
    mov [es:si+4], ax
    mov al, [a20flip]
    mov [es:blk_a20flip], al
    mov al, [a20skip]
    mov [es:blk_a20skip], al
    pop es
    ret
.ent:                               ; BX = entry -> SI = its address in cleanlist
    mov si, bx
    shl si, 1
    add si, bx                      ; * 3
    shl si, 1                       ; * 6
    add si, cleanlist
    ret

; =============================================================================
; inval_buffers: after the resume, DOS's disk buffers are the snapshot's, and
; os8088 may have changed the disk since. INT 21h AH=0Dh, the documented disk
; reset, is the only handle on them that does not depend on one DOS's layout.
;
; On FreeDOS it FLUSHES AND MARKS EVERY BUFFER INVALID, which is why the launcher
; calls it before the snapshot (make_swap) and why a FreeDOS host has nothing
; stale to come back to; calling it again here covers a buffer filled between
; the two. MS-DOS's is documented as a flush, and WHETHER IT ALSO INVALIDATES IS
; NOT KNOWN HERE: no MS-DOS to test on. Do not rely on this for an MS-DOS host
; until it has been measured there (docs/plans/DOSGUEST-PLAN.md 14).
;
; A first version walked the buffer chain from the list of lists (+12h) and
; marked each header unused. It crashed FreeDOS 2043: that chain is not a simple
; list of headers (its second link points into COMMAND.COM's memory), and
; writing into a DOS structure laid out the way one DOS version happens to is
; the kind of fix that works on the machine it was written on.
; =============================================================================
inval_buffers:
    mov ah, 0x0D
    int 0x21
    ret

; prime_cache (/P, a test): after make_swap's disk reset, read the root directory
; through DOS, so the cache holds a directory sector when the snapshot is taken.
; That is the state an MS-DOS host is in anyway.
prime_cache:
    cmp byte [prime], 0
    je .no
    mov dx, primespec
    mov cx, 0x16
    mov ah, 0x4E
    int 0x21
.no:
    ret
primespec db '\*.*', 0

; =============================================================================
; write_test (/F, a test): try to WRITE a sector through the live INT 13h - the
; one os8088 would be given - using the extended write (AH=43h), which takes an
; LBA and needs no CHS. The target is sector 40 of the swap file's video area,
; which nothing uses in the self-test, so a write that does get through is harmless
; and shows up on the host. Records the BIOS's answer.
; =============================================================================
write_test:
    mov es, [hseg]
    ; the sector's LBA: file sector (image + 40), through the extent list
    mov ax, [es:blk_img_secs]
    add ax, 40
    mov si, blk_runs
    mov cx, [es:blk_nruns]
.r: test cx, cx
    jz .out
    mov dx, [es:si+4]
    cmp ax, dx
    jb .here
    sub ax, dx
    add si, 6
    dec cx
    jmp .r
.here:
    mov bx, [es:si]
    mov dx, [es:si+2]
    add bx, ax
    adc dx, 0
    mov [wt_pkt+8], bx
    mov [wt_pkt+10], dx
    ; a recognisable sector, in the aligned buffer
    push cs
    pop es
    mov di, [secbuf]
    mov cx, 256
    mov ax, 'GD'
.f: stosw
    loop .f
    mov ax, [secbuf]
    mov [wt_pkt+4], ax
    mov [wt_pkt+6], cs
    mov es, [hseg]
    mov dl, [es:blk_unit]
    push cs
    pop es
    mov si, wt_pkt
    mov ah, 0x43
    xor al, al
    int 0x13
    mov bl, 0                       ; the answer goes in the BLOCK: the launcher's own
    jnc .nc                         ; memory is rewound to the snapshot by the restore
    mov bl, 1
.nc:
    mov bh, ah
    mov es, [hseg]
    mov [es:blk_wt_ah], bh
    mov [es:blk_wt_cf], bl
.out:
    push cs
    pop es
    ret
wt_pkt  db 16, 0
        dw 1
        dw 0, 0                     ; the buffer, offset and segment
        dw 0, 0, 0, 0               ; the LBA, 64 bits

; =============================================================================
; dos_secs: DOS's clock as seconds since midnight, DX:AX
; =============================================================================
dos_secs:
    mov ah, 0x2C
    int 0x21                        ; CH hours, CL minutes, DH seconds
    mov [tmp_h], ch
    mov [tmp_m], cl
    mov [tmp_s], dh
    mov al, [tmp_h]
    xor ah, ah
    mov cx, 3600
    mul cx                          ; DX:AX
    push dx
    push ax
    mov al, [tmp_m]
    xor ah, ah
    mov cx, 60
    mul cx
    pop bx
    add ax, bx
    pop bx
    adc dx, bx
    mov bl, [tmp_s]
    xor bh, bh
    add ax, bx
    adc dx, 0
    ret

; =============================================================================
; fix_clock: DOS's time is the BIOS tick count at the snapshot, and that stopped
; while os8088 ran. The RTC did not. Read it, set DOS's date and time from it.
; (An XT with no RTC leaves it alone: INT 1Ah answers with the carry set.)
; =============================================================================
fix_clock:
    ; READ BOTH FIRST. Setting DOS's date makes FreeDOS write its own time, which
    ; is the stale tick-based one, back into the RTC - so a time read AFTER the
    ; date is set is the snapshot's time again, and os8088's whole run is lost.
    mov ah, 0x04
    int 0x1A                        ; CH century, CL year, DH month, DL day, BCD
    jc .no
    mov al, dl
    call bcd
    mov [cl_day], al
    mov al, dh
    call bcd
    mov [cl_mon], al
    mov al, cl
    call bcd
    mov bl, al
    mov al, ch
    call bcd
    mov cl, 100
    mul cl                          ; AX = century * 100
    xor bh, bh
    add ax, bx
    mov [cl_year], ax
    mov ah, 0x02
    int 0x1A                        ; CH hours, CL minutes, DH seconds, BCD
    jc .no
    mov al, ch
    call bcd
    mov [tmp_h], al
    mov al, cl
    call bcd
    mov [tmp_m], al
    mov al, dh
    call bcd
    mov [tmp_s], al
    ; ...then set both. Hundredths 10, not 0: FreeDOS turns the time into BIOS
    ; ticks and back by truncating, so a time set to :35.00 reads back :34
    mov cx, [cl_year]
    mov dh, [cl_mon]
    mov dl, [cl_day]
    mov ah, 0x2B
    int 0x21
    mov ch, [tmp_h]
    mov cl, [tmp_m]
    mov dh, [tmp_s]
    mov dl, 10
    mov ah, 0x2D
    int 0x21
.no:
    ret
cl_year dw 0
cl_mon  db 0
cl_day  db 0

bcd:                                ; AL, packed BCD -> AL
    push cx
    mov ch, al
    and ch, 0x0F
    mov cl, 4
    shr al, cl
    mov cl, 10
    mul cl
    add al, ch
    pop cx
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
    shr ax, cl                      ; chunks of 16KB...
    add ax, VIDEO_KB / 16           ; ...and the video area's
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
    cmp byte [dos_classic], 0
    jne .classic
    mov cx, 0xFFFF
    mov bx, pk_sec
    int 0x25
    pop ax                          ; INT 25h leaves the flags on the stack
    jc .bad
    jmp .read
.classic:
    mov cx, 1                       ; one sector, number 0, into DS:BX
    xor dx, dx
    mov bx, [secbuf]
    int 0x25
    pop ax
    jc .bad
.read:
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
    ; the BIOS's extended read and write, for a hard disk, unless /C: with CHS a
    ; partition beyond the 1,024th cylinder (the first 8 GB) cannot be addressed
    mov byte [es:blk_edd], 0
    cmp byte [chsonly], 0
    jne .okk
    mov al, [es:blk_unit]
    cmp al, 0x80
    jb .okk
    push es
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, al
    int 0x13
    pop es
    jc .okk
    cmp bx, 0xAA55
    jne .okk
    test cl, 1                      ; bit 0: the 42h to 44h subset (read, write, verify)
    jz .okk
    mov byte [es:blk_edd], 1
.okk:
    clc
.out:
    pop es
    ret

; =============================================================================
; locate_boot: the os8088 volume is a hard-disk volume DOS calls [bootdrive]. Its
; boot sector, read through DOS, says where the volume starts (the BPB's hidden
; sectors) and is then looked for on each BIOS unit by content, as find_unit does
; for the swap volume, so that the unit is what the BIOS calls it and not a guess.
; The unit's geometry and EDD flag are kept in the block for stub_boot, and the
; swap volume's are put back.
; =============================================================================
read_lba:                           ; DX:AX = an ABSOLUTE LBA, CX = count -> secbuf
    mov bx, [secbuf]
    push es
    push cs
    pop es
    mov di, 2
    call disk
    pop es
    ret

locate_boot:
    push es
    mov es, [hseg]
    mov al, [es:blk_unit]
    mov [swap_unit], al
    push cs
    pop es
    xor ax, ax
    mov [pk_sec], ax
    mov [pk_sec+2], ax
    mov word [pk_cnt], 1
    mov ax, [secbuf]
    mov [pk_off], ax
    mov [pk_seg], cs
    mov al, [bootdrive]
    cmp byte [dos_classic], 0
    jne .cls
    mov cx, 0xFFFF
    mov bx, pk_sec
    int 0x25
    pop ax
    jc .bad
    jmp .got
.cls:
    mov cx, 1
    xor dx, dx
    mov bx, [secbuf]
    int 0x25
    pop ax
    jc .bad
.got:
    mov si, [secbuf]
    mov di, bootsave2
    mov cx, 256
    rep movsw
    mov ax, [bootsave2+0x1C]
    mov [bootlba], ax
    mov ax, [bootsave2+0x1E]
    mov [bootlba+2], ax
    mov al, 0x80
.try:
    push ax
    call set_unit
    jc .next
    mov ax, [bootlba]
    mov dx, [bootlba+2]
    mov cx, 1
    call read_lba
    jc .next
    mov si, [secbuf]
    mov di, bootsave2
    mov cx, 256
    repe cmpsw
    jne .next
    pop ax
    mov [bootunit], al
    mov es, [hseg]
    mov [es:blk_bootunit], al
    mov ax, [bootlba]
    mov [es:blk_bootlba], ax
    mov ax, [bootlba+2]
    mov [es:blk_bootlba+2], ax
    mov al, [es:blk_unit]           ; set_unit has just filled these for the boot unit
    mov [es:blk_b_unit], al
    mov ax, [es:blk_spt]
    mov [es:blk_b_spt], ax
    mov ax, [es:blk_heads]
    mov [es:blk_b_heads], ax
    mov al, [es:blk_edd]
    mov [es:blk_b_edd], al
    mov al, [swap_unit]             ; and the swap volume's back, which the image uses
    call set_unit
    pop es
    ret
.next:
    pop ax
    inc al
    cmp al, 0x88
    jb .try
.bad:
    mov dx, msg_loc
    jmp fail
bootsave2 times 512 db 0

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
    mov ax, [es:blk_cl+4]
    call emit_hex16
    mov al, ':'
    call emit_ch
    mov ax, [es:blk_cl+2]
    call emit_hex16
    call emit_crlf
    mov si, r_cn
    call emit_str
    mov ax, [es:blk_clcnt]
    call emit_hex16
    call emit_crlf
    mov si, r_heur
    call emit_str
    mov ax, [heur_n]
    call emit_hex16
    call emit_crlf
    mov si, r_unit
    call emit_str
    mov al, [es:blk_unit]
    call emit_hex8
    call emit_crlf
    mov si, r_mode
    call emit_str
    mov al, [bootmode]
    call emit_hex8
    call emit_crlf
    mov si, r_bfail
    call emit_str
    mov al, [es:blk_bootfail]
    call emit_hex8
    call emit_crlf
    mov si, r_tick0
    call emit_str
    mov ax, [es:blk_snap_tick]
    call emit_hex16
    call emit_crlf
    mov si, r_tick1
    call emit_str
    mov ax, [es:blk_ret_tick]
    call emit_hex16
    call emit_crlf
    mov si, r_bunit
    call emit_str
    mov al, [bootunit]
    call emit_hex8
    call emit_crlf
    mov si, r_edd
    call emit_str
    mov al, [es:blk_edd]
    call emit_hex8
    call emit_crlf
    mov si, r_hid
    call emit_str
    mov ax, [bpb_hid+2]
    call emit_hex16
    mov ax, [bpb_hid]
    call emit_hex16
    call emit_crlf
    mov si, r_wtest
    call emit_str
    mov al, [es:blk_wt_ah]
    call emit_hex8
    mov al, [es:blk_wt_cf]
    call emit_hex8
    mov al, [es:blk_wmask]
    call emit_hex8
    call emit_crlf
    mov si, r_filter
    call emit_str
    mov al, [es:blk_filter]
    call emit_hex8
    call emit_crlf
    mov si, r_a20
    call emit_str
    mov al, [es:blk_a20_dos]
    call emit_hex8
    mov al, [es:blk_a20_boot]
    call emit_hex8
    mov al, [es:blk_a20_final]
    call emit_hex8
    call emit_crlf
    mov si, r_tsnap
    call emit_str
    mov ax, [t_snap+2]
    call emit_hex16
    mov ax, [t_snap]
    call emit_hex16
    call emit_crlf
    mov si, r_taft
    call emit_str
    mov ax, [t_after+2]
    call emit_hex16
    mov ax, [t_after]
    call emit_hex16
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
r_cn     db 'clean_vectors=', 0
r_heur   db 'heuristic_unwraps=', 0
r_nruns  db 'nruns=', 0
r_a20    db 'a20_dos_boot_final=', 0
r_filter db 'int15_filter=', 0
r_wtest  db 'wtest_ah_cf_wmask=', 0
r_edd    db 'edd=', 0
r_bunit  db 'boot_unit=', 0
r_hid    db 'hidden_sectors=', 0
r_tsnap  db 'dos_secs_snap=', 0
r_taft   db 'dos_secs_after=', 0
r_mode   db 'bootmode=', 0
r_bfail  db 'bootfail=', 0
r_tick0  db 'tick_at_boot=', 0
r_tick1  db 'tick_at_return=', 0
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
    ; the console: ONE line, unless /V. The report is forty lines and scrolls the
    ; screen the user came from off the top of the one DOS has just given back
    cmp byte [verbose], 0
    je .brief
    mov bx, 1
    mov dx, rbuf
    mov ah, 0x40
    int 0x21
    jmp .file
.brief:
    mov dx, msg_back
    mov ah, 0x09
    int 0x21
.file:
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
STUB_BOOT    equ 9
STUB_RETURN  equ 12
STUB_IRET    equ 15
    jmp stub_suspend                ; +0   far call: write the snapshot
    jmp stub_trash                  ; +3   far call: trash, then restore
    jmp stub_rw                     ; +6   far call: DX:AX LBA, CX count
    jmp stub_boot                   ; +9   far call: boot os8088; no return
    jmp stub_return                 ; +12  INT 19h's target while os8088 runs
    iret                            ; +15  what a hook the BIOS makes becomes

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
blk_rom15   dw 0, 0
blk_filter db 0
blk_wmask   db 0
blk_wt_ah   db 0xFF
blk_wt_cf   db 0xFF
blk_a20_dos db 0
blk_a20_boot db 0
blk_a20_final db 0
blk_a20flip db 0
blk_a20skip db 0
t_a20       db 0
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
blk_edd     db 0                    ; 1: this unit takes INT 13h AH=42h/43h
t_pkt       times 16 db 0
t_rem       dw 0
blk_img_secs dw 0
blk_bounce  dw 0
at_flag     db 0
blk_err     dw 0
blk_bootunit db 0
blk_bootlba dw 0, 0
blk_b_unit  db 0
blk_b_edd   db 0
blk_b_spt   dw 0
blk_b_heads dw 0
blk_bootmode db 0
blk_bootfail db 0
blk_pad2    db 0
blk_snap_tick dw 0
blk_ret_tick dw 0
scr_seg     dw 0
v_mode      db 3
v_text      db 1
v_vga       db 0
v_blink     db 0
v_s2        db 0
v_s4        db 0
v_g4        db 0
v_g5        db 0
v_g6        db 0
v_cur       dw 0
v_shape     dw 0
v_height    dw 0
blk_fixirq  db 0
blk_ivt_bad dw 0
blk_clcnt   dw 0
blk_cl      times (MAXVEC * 6) db 0 ; the clean list: vec word, off word, seg word
blk_dosvec  times (MAXVEC * 4) db 0 ; DOS's, as the live IVT held them
blk_cl0e    dw 0, 0                 ; the clean INT 0Eh and 76h, for the disk IRQs
blk_cl76    dw 0, 0
blk_dos0e   dw 0, 0                 ; DOS's own, found by ivt_op's save pass
blk_dos76   dw 0, 0

; ----- stub_int15: the INT 15h os8088 is given ------------------------------------
; Extended memory belongs to DOS's XMS manager, and os8088's XMEM.DRV would
; otherwise load on a machine that answers AH=88h with 6 MB and claim it. So:
; AH=88h and E801h say there is none, E820h and the AH=87h block move are
; refused, and everything else goes to the ROM. Reached only while os8088 runs.
stub_int15:
    cmp ah, 0x88
    je .none
    cmp ah, 0x87
    je .bad
    cmp ax, 0xE801
    je .e801
    cmp ax, 0xE820
    je .bad
    jmp far [cs:blk_rom15]          ; the ROM answers, and returns to the caller
.e801:
    xor bx, bx
    xor cx, cx
    xor dx, dx
.none:
    xor ax, ax                      ; no KB above 1MB
    push bp
    mov bp, sp
    and word [bp+6], 0xFFFE         ; CF clear in the flags INT pushed
    pop bp
    iret
.bad:
    mov ah, 0x86                    ; function not supported
    push bp
    mov bp, sp
    or word [bp+6], 1
    pop bp
    iret

; ----- stub_int13: the INT 13h os8088 is given ---------------------------------------
; Writes (AH=03h, 05h-07h format, 0Bh, 0Fh, 43h) go to the ROM only for a unit
; whose bit is in [blk_wmask]; otherwise the answer is "write protected" (AH=03h,
; CF set) and nothing reaches the disk. Reads, resets and everything else go
; straight to the ROM. DL = the unit: 0 to 3 floppies (bits 0 to 3), 80h up hard.
stub_int13:
    cmp ah, 0x03
    je .w
    cmp ah, 0x05
    je .w
    cmp ah, 0x06
    je .w
    cmp ah, 0x07
    je .w
    cmp ah, 0x0B
    je .w
    cmp ah, 0x0F
    je .w
    cmp ah, 0x43
    je .w
.rom:
    jmp far [cs:blk_rom13]
.w: push bx
    push cx
    mov bl, dl
    mov cl, 7                       ; any hard disk: bit 7
    cmp bl, 0x80
    jae .bit
    cmp bl, 4
    jae .deny                       ; not a unit this knows
    mov cl, bl
.bit:
    mov bl, 1
    shl bl, cl
    test [cs:blk_wmask], bl
    pop cx
    pop bx
    jnz .rom
    jmp .refuse
.deny:
    pop cx
    pop bx
.refuse:
    mov ah, 0x03                    ; write protected
    xor al, al
    push bp
    mov bp, sp
    or word [bp+6], 1               ; CF set in the flags INT pushed
    pop bp
    iret

; ----- A20 ---------------------------------------------------------------------
; a20_test: AL = 1 if A20 is on, 0 if it is off. The wrap-around test, twice with
; different patterns so a coincidence is not an answer: 0000:0080 and FFFF:0090
; are one byte with A20 off and two with it on. Preserves everything else.
a20_test:
    push bx
    push si
    push di
    push ds
    push es
    pushf
    cli
    xor ax, ax
    mov ds, ax
    mov ax, 0xFFFF
    mov es, ax
    mov si, 0x80
    mov di, 0x90
    mov bl, [si]                    ; the low byte, to put back
    mov bh, 0                       ; 0 = on until both patterns say aliased
    mov al, bl
    xor al, 0x5A
    mov [si], al
    cmp al, [es:di]
    jne .on
    mov al, bl
    xor al, 0xA5
    mov [si], al
    cmp al, [es:di]
    jne .on
    mov bh, 1                       ; both patterns showed through: aliased, off
.on:
    mov [si], bl
    popf
    pop es
    pop ds
    pop di
    pop si
    mov al, 1
    test bh, bh
    jz .out
    xor al, al
.out:
    pop bx
    ret

; a20_set: AL = 1 on, 0 off. BIOS INT 15h first (the ROM's, through the saved
; vector: a driver such as HIMEM hooks the live one), then the fast-A20 port 92h,
; then the keyboard controller. Each is checked by the wrap test. CF if none took.
a20_set:
    push ax
    push bx
    push cx
    push dx
    mov [cs:t_a20], al
    call a20_test
    cmp al, [cs:t_a20]
    je .ok
    mov ax, 0x2401
    cmp byte [cs:t_a20], 0
    jne .b
    mov ax, 0x2400
.b: pushf
    call far [cs:blk_rom15]
    call a20_test
    cmp al, [cs:t_a20]
    je .ok
    in al, 0x92                     ; fast A20. Bit 0 is a RESET: never set it
    mov ah, al
    and al, 0xFE
    cmp byte [cs:t_a20], 0
    jne .p1
    and al, 0xFD
    jmp .p2
.p1:
    or al, 2
.p2:
    out 0x92, al
    xor cx, cx
.w1: loop .w1
    call a20_test
    cmp al, [cs:t_a20]
    je .ok
    call kbc_wait
    mov al, 0xD1
    out 0x64, al
    call kbc_wait
    mov al, 0xDF
    cmp byte [cs:t_a20], 0
    jne .k
    mov al, 0xDD
.k: out 0x60, al
    call kbc_wait
    xor cx, cx
.w2: loop .w2
    call a20_test
    cmp al, [cs:t_a20]
    je .ok
    stc
    jmp .out
.ok:
    clc
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret
kbc_wait:                           ; the 8042's input buffer empties
    push ax
    push cx
    xor cx, cx
.l: in al, 0x64
    test al, 2
    jz .d
    loop .l
.d: pop cx
    pop ax
    ret

; ----- bios: INT 13h through the saved ROM vector, immune to the IVT's restore -
bios13:
    cmp byte [cs:blk_fixirq], 0
    je .go
    push ax
    push es
    xor ax, ax
    mov es, ax
    mov ax, [cs:blk_cl0e]               ; INT 0Eh: the floppy's IRQ
    mov [es:0x38], ax
    mov ax, [cs:blk_cl0e + 2]
    mov [es:0x3A], ax
    mov ax, [cs:blk_cl76]               ; INT 76h: the hard disk's
    mov [es:0x1D8], ax
    mov ax, [cs:blk_cl76 + 2]
    mov [es:0x1DA], ax
    pop es
    pop ax
.go:
    pushf
    call far [cs:blk_rom13]
    ret

; ivt_op: AL=0 save the live IVT to blk_dosvec, 1 apply the clean list, 2
; compare (the number that differ goes to blk_ivt_bad)
ivt_op:
    push ds
    push es
    push si
    push di
    push bx
    push cx
    mov [cs:op_al], al
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov word [blk_ivt_bad], 0
    xor si, si                      ; the entry, 6 bytes
    xor di, di                      ; DOS's copy, 4 bytes
    mov cx, [blk_clcnt]
.v: test cx, cx
    jz .done
    mov bx, [blk_cl+si]
    shl bx, 1
    shl bx, 1                       ; the vector's address in the IVT
    mov al, [op_al]
    test al, al
    jnz .notsave
    mov ax, [es:bx]
    mov [blk_dosvec+di], ax
    mov ax, [es:bx+2]
    mov [blk_dosvec+di+2], ax
    cmp bx, 0x38
    jne .s1
    mov ax, [es:bx]
    mov [blk_dos0e], ax
    mov ax, [es:bx+2]
    mov [blk_dos0e+2], ax
.s1:
    cmp bx, 0x1D8
    jne .nx
    mov ax, [es:bx]
    mov [blk_dos76], ax
    mov ax, [es:bx+2]
    mov [blk_dos76+2], ax
    jmp .nx
.notsave:
    cmp al, 1
    jne .cmp
    mov ax, [blk_cl+si+2]
    mov [es:bx], ax
    mov ax, [blk_cl+si+4]
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
    add si, 6
    add di, 4
    dec cx
    jmp .v
.done:
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
    cmp byte [blk_edd], 0
    jne .eddn                       ; the BIOS takes an LBA: no geometry to run out of
    call lba_chs
    jc .fail
    ; n = min(spt - sec0, count, 63, DMA room)
    mov ax, [blk_spt]
    sub ax, [t_sec0]
    cmp ax, [t_cnt]
    jbe .a
.eddn:
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
    cmp byte [blk_edd], 0
    jne .edd
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
    jmp .did
.edd:                               ; INT 13h AH=42h/43h: a packet with a 64-bit LBA
    mov byte [t_pkt], 16
    mov byte [t_pkt+1], 0
    mov ax, [t_n]
    mov [t_pkt+2], ax
    mov [t_pkt+4], bx
    mov [t_pkt+6], es
    mov ax, [t_lba]
    mov [t_pkt+8], ax
    mov ax, [t_lba+2]
    mov [t_pkt+10], ax
    xor ax, ax
    mov [t_pkt+12], ax
    mov [t_pkt+14], ax
.etry:
    mov ax, [blk_op]
    add al, 0x40                    ; 2 -> 42h read, 3 -> 43h write
    mov ah, al
    xor al, al
    mov si, t_pkt
    mov dl, [blk_unit]
    call bios13
    jnc .did
    xor ax, ax
    mov dl, [blk_unit]
    call bios13                     ; reset
    dec bp
    jnz .etry
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
    mov ax, [blk_img_secs]
    mov [t_rem], ax                 ; the file goes on past the image: the video area
    mov si, blk_runs
    mov cx, [blk_nruns]
.r: test cx, cx
    jz .ok
    cmp word [t_rem], 0
    je .ok
    push cx
    push si
    mov ax, [si]
    mov dx, [si+2]
    mov cx, [si+4]
    cmp cx, [t_rem]
    jbe .whole
    mov cx, [t_rem]
.whole:
    sub [t_rem], cx
    push cs
    call stub_rw                    ; ends in retf: CS and IP are both on the stack
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
    cmp byte [cs:at_flag], 0
    je pic_set_quiet
    in al, 0xA1
    mov [cs:sv_m2], al
pic_set_quiet:                      ; the same masks, without saving the live ones
    mov al, 0xBB                    ; IRQ6 and the cascade only
    out 0x21, al
    cmp byte [cs:at_flag], 0
    je .xt
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
    call a20_test
    mov [cs:blk_a20_dos], al        ; DOS's A20: an XMS driver owns it, and os8088 will not
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
    jmp restore_all

; ----- restore_all: the whole of the way back, shared by the self-test's trash
;       and by Restart's int 19h. On the stub's own stack, IRQs quiet.
restore_all:
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
    mov ax, [cs:blk_dos0e]
    mov [es:0x38], ax
    mov ax, [cs:blk_dos0e + 2]
    mov [es:0x3A], ax
    mov ax, [cs:blk_dos76]
    mov [es:0x1D8], ax
    mov ax, [cs:blk_dos76 + 2]
    mov [es:0x1DA], ax
    mov al, 2
    call ivt_op                     ; the IVT is DOS's again, or it is not
    xor ax, ax
    mov es, ax
    mov ax, [cs:blk_orig_kb]
    mov [es:0x413], ax
    cmp byte [cs:blk_a20skip], 0
    jne .noa20
    mov al, [cs:blk_a20_dos]        ; DOS's A20, which an XMS driver believes it knows
    call a20_set
.noa20:
    call a20_test
    mov [cs:blk_a20_final], al
    cmp byte [cs:blk_bootmode], 0
    je .novid
    call restore_video              ; os8088 left the card in a graphics mode
.novid:
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


; ----- the DOS video state, kept in the swap file after the image -------------
;       Video RAM is not in the image, and os8088 takes the card into a graphics
;       mode that a BIOS mode set on the way back then clears. Streamed through
;       a 1KB bounce buffer a sector at a time, so the hidden block stays small.
;
;       TEXT MODES ONLY. A host in a graphics mode comes back in 80x25 text:
;       nothing is kept of the picture, and the mode set says so by clearing it.
;
;       The video area, in sectors after the image:
;         0..15   the text screen, page 0, 8,192 bytes (80x50 is 8,000)
;         16..31  VGA font plane 2, 256 glyphs x 32 bytes
;         32..33  the DAC (768 bytes) then the 16 palette registers + overscan
;       What is NOT kept: other pages, a split screen, a loaded font in a second
;       bank, and anything on an adapter that is not VGA beyond the screen itself.

; vid_rw: AX = sector of the video area, BX = a buffer in the block, [blk_op]
; 2 read / 3 write. CF on failure. The file's extents are walked from the front,
; because the video area may not be in the run the image ends in.
vid_rw:
    push ds
    push es
    push si
    push bp
    push cx
    push dx
    mov dx, cs
    mov ds, dx
    mov es, dx
    add ax, [blk_img_secs]          ; a sector of the FILE
    mov si, blk_runs
    mov cx, [blk_nruns]
.run:
    test cx, cx
    jz .fail
    mov dx, [si+4]
    cmp ax, dx
    jb .here
    sub ax, dx
    add si, 6
    dec cx
    jmp .run
.here:
    mov dx, [si+2]
    mov bp, [si]
    add bp, ax
    adc dx, 0
    mov ax, bp
    mov cx, 1
    push cs
    call stub_rw                    ; DX:AX LBA, CX 1, ES:BX
    jmp .out
.fail:
    stc
.out:
    pop dx
    pop cx
    pop bp
    pop si
    pop es
    pop ds
    ret

; vid_copy_out / vid_copy_in: 256 words between DS:SI-ish and the bounce.
; font_open / font_close: the VGA's plane 2 mapped at A000:0, and put back
font_open:
    push ax
    push dx
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
    mov ax, 0x0402                  ; map mask: plane 2
    out dx, ax
    mov ax, 0x0604                  ; sequential, no chain-4
    out dx, ax
    mov dx, 0x3CE
    mov ax, 0x0204                  ; read map: plane 2
    out dx, ax
    mov ax, 0x0005                  ; read mode 0, write mode 0, odd/even off
    out dx, ax
    mov ax, 0x0406                  ; A000, 64KB
    out dx, ax
    pop dx
    pop ax
    ret
font_close:
    push ax
    push dx
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
    pop dx
    pop ax
    ret

; save_video: at the boot, DOS's screen is still on the glass
save_video:
    push ds
    push es
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov al, [es:0x449]
    and al, 0x7F
    mov [v_mode], al
    mov byte [v_text], 1
    mov bx, 0xB800
    cmp al, 7
    jne .col
    mov bx, 0xB000
.col:
    mov [scr_seg], bx
    cmp al, 3
    jbe .text
    cmp al, 7
    je .text
    mov byte [v_text], 0            ; graphics: nothing to keep
    jmp .done
.text:
    mov word [blk_op], 3
    ; --- the screen, 16 sectors -----------------------------------------------
    xor bp, bp                      ; the sector
.scr:
    push ds
    mov ds, [scr_seg]
    mov si, bp
    mov cl, 9
    shl si, cl                      ; * 512
    push cs
    pop es
    mov di, [cs:blk_bounce]
    mov cx, 256
    cld
    rep movsw
    pop ds
    mov ax, bp
    mov bx, [blk_bounce]
    call vid_rw
    inc bp
    cmp bp, 16
    jb .scr
    ; --- VGA? ----------------------------------------------------------------------
    mov byte [v_vga], 0
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A
    jne .done
    cmp bl, 7
    jb .done
    mov byte [v_vga], 1
    ; --- the font ------------------------------------------------------------------
    call font_open
    xor bp, bp
.fnt:
    push ds
    mov ax, 0xA000
    mov ds, ax
    mov si, bp
    mov cl, 9
    shl si, cl
    push cs
    pop es
    mov di, [cs:blk_bounce]
    mov cx, 256
    cld
    rep movsw
    pop ds
    mov ax, bp
    add ax, 16
    mov bx, [blk_bounce]
    call vid_rw
    inc bp
    cmp bp, 16
    jb .fnt
    call font_close
    ; --- the DAC and the palette registers ---------------------------------------
    push cs
    pop es
    mov di, [blk_bounce]
    mov dx, 0x3C7
    xor al, al
    out dx, al
    mov dx, 0x3C9
    mov cx, 768
.dac:
    in al, dx
    stosb
    loop .dac
    mov dx, [blk_bounce]
    add dx, 768
    mov ax, 0x1009
    int 0x10                        ; ES:DX <- the 16 registers and the overscan
    mov ax, 32
    mov bx, [blk_bounce]
    call vid_rw
    mov ax, 33
    mov bx, [blk_bounce]
    add bx, 512
    call vid_rw
.done:
    pop es
    pop ds
    ret

; restore_video: after the image, so the BDA is DOS's again
restore_video:
    push ds
    push es
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov ax, [es:0x450]              ; cursor, page 0: column in AL, row in AH
    mov [v_cur], ax
    mov ax, [es:0x460]              ; cursor shape
    mov [v_shape], ax
    mov ax, [es:0x485]              ; character height
    mov [v_height], ax
    mov al, [es:0x465]              ; the CRT mode register: bit 5 is blink
    mov [v_blink], al
    mov al, 3                       ; a host that was in a graphics mode: text
    cmp byte [v_text], 0
    je .set
    mov al, [v_mode]
.set:
    xor ah, ah
    int 0x10                        ; DOS's own INT 10h chain, restored with it
    cmp byte [v_text], 0
    je .out
    cmp byte [v_vga], 0
    je .screen
    ; --- the font's SHAPE (the mode's own line count) then its BITS -------------
    mov ax, [v_height]
    mov bl, 0
    cmp al, 8
    jne .h14
    mov ax, 0x1112
    int 0x10
    jmp .fbits
.h14:
    cmp al, 14
    jne .h16
    mov ax, 0x1111
    int 0x10
    jmp .fbits
.h16:
    cmp al, 16
    jne .fbits
    mov ax, 0x1114
    int 0x10
.fbits:
    mov word [blk_op], 2
    call font_open
    xor bp, bp
.fnt:
    mov ax, bp
    add ax, 16
    mov bx, [blk_bounce]
    call vid_rw
    push es
    mov ax, 0xA000
    mov es, ax
    mov di, bp
    mov cl, 9
    shl di, cl
    mov si, [blk_bounce]
    mov cx, 256
    cld
    rep movsw
    pop es
    inc bp
    cmp bp, 16
    jb .fnt
    call font_close
    ; --- the palette ------------------------------------------------------------------
    mov ax, 32
    mov bx, [blk_bounce]
    call vid_rw
    mov ax, 33
    mov bx, [blk_bounce]
    add bx, 512
    call vid_rw
    mov si, [blk_bounce]
    mov dx, 0x3C8
    xor al, al
    out dx, al
    inc dx
    mov cx, 768
.dac:
    lodsb
    out dx, al
    loop .dac
    push cs
    pop es
    mov dx, [blk_bounce]
    add dx, 768
    mov ax, 0x1002
    int 0x10                        ; ES:DX -> the 16 registers and the overscan
    mov ax, 0x1003
    mov bl, [v_blink]
    mov cl, 5
    shr bl, cl
    and bl, 1
    int 0x10                        ; blink or intensity
.screen:
    mov word [blk_op], 2
    xor bp, bp
.scr:
    mov ax, bp
    mov bx, [blk_bounce]
    call vid_rw
    push es
    mov es, [scr_seg]
    mov di, bp
    mov cl, 9
    shl di, cl
    mov si, [blk_bounce]
    mov cx, 256
    cld
    rep movsw
    pop es
    inc bp
    cmp bp, 16
    jb .scr
    mov cx, [v_shape]
    mov ah, 1
    int 0x10
    mov dx, [v_cur]
    xor bx, bx
    mov ah, 2
    int 0x10
.out:
    pop es
    pop ds
    ret

; ----- stub_boot: what a BIOS does at int 19h, from a floppy -------------------
;       Far-called by the launcher after the snapshot. It never returns: the
;       way back is os8088's Restart, whose int 19h lands on stub_return.
stub_boot:
    cli
    cld
    mov ax, cs
    mov ss, ax
    mov sp, ST_STACK
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov ax, [es:0x46C]
    mov [blk_snap_tick], ax
    call save_video
    mov al, 1                       ; a BIOS boot leaves A20 on, and os8088 is not
    call a20_set                    ; written for it off (an XMS driver may have left it so)
    call a20_test
    mov [blk_a20_boot], al
    cmp byte [blk_bootunit], 0x80
    jae .hdboot
    ; the boot sector, to 0000:7C00, by the ROM's own INT 13h
    mov bp, 3
.try:
    xor ax, ax
    mov es, ax
    mov bx, 0x7C00
    mov ax, 0x0201
    mov cx, 1
    xor dh, dh
    mov dl, [blk_bootunit]
    call bios13
    jnc .loaded
    xor ax, ax
    mov dl, [blk_bootunit]
    call bios13
    dec bp
    jnz .try
    mov byte [blk_bootfail], 1      ; no boot sector: give DOS back
    call pic_set_quiet
    mov word [blk_ret_tick], 0
    jmp restore_all
.hdboot:
    ; A HARD-DISK VOLUME: its boot record is the partition's first sector, which
    ; boot/boothd.asm takes DL and its own BPB for. The stub's disk service works
    ; on the swap volume's unit and geometry, so swap them for the one read.
    push word [blk_unit]            ; (a byte and its pad)
    push word [blk_spt]
    push word [blk_heads]
    push word [blk_edd]
    mov al, [blk_b_unit]
    mov [blk_unit], al
    mov ax, [blk_b_spt]
    mov [blk_spt], ax
    mov ax, [blk_b_heads]
    mov [blk_heads], ax
    mov al, [blk_b_edd]
    mov [blk_edd], al
    mov word [blk_op], 2
    xor ax, ax
    mov es, ax
    mov bx, 0x7C00
    mov ax, [blk_bootlba]
    mov dx, [blk_bootlba+2]
    mov cx, 1
    push cs
    call stub_rw
    pushf
    pop si                          ; keep the carry across the pops
    pop word [blk_edd]
    pop word [blk_heads]
    pop word [blk_spt]
    pop word [blk_unit]
    test si, 1
    jz .loaded
    mov byte [blk_bootfail], 1
    call pic_set_quiet
    mov word [blk_ret_tick], 0
    jmp restore_all
.loaded:
    ; Restart will int 19h: that is the way back
    xor ax, ax
    mov es, ax
    mov word [es:0x64], STUB_RETURN
    mov [es:0x66], cs
    ; the PIC as a BIOS leaves it, with DOS's own masks otherwise: the timer,
    ; keyboard, cascade and floppy on, and on an AT the RTC and the hard disk
    mov al, [sv_m1]
    and al, 0xB8
    out 0x21, al
    cmp byte [at_flag], 0
    je .xt
    mov al, [sv_m2]
    and al, 0xBE
    and al, 0xBF
    out 0xA1, al
.xt:
    mov dl, [blk_bootunit]
    xor ax, ax
    mov ds, ax
    mov es, ax
    xor bx, bx
    xor cx, cx
    xor dh, dh
    xor si, si
    xor di, di
    xor bp, bp
    mov ss, ax
    mov sp, 0x7C00
    sti
    jmp 0x0000:0x7C00

; ----- stub_return: int 19h from os8088's Restart ---------------------------------
stub_return:
    cli
    cld
    mov ax, cs
    mov ss, ax
    mov sp, ST_STACK
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov ax, [es:0x46C]
    mov [blk_ret_tick], ax
    call pic_set_quiet              ; NOT pic_quiet: DOS's masks are already saved
    cmp byte [blk_a20flip], 0
    je restore_all
    mov al, [blk_a20_dos]           ; /A, a test: os8088 "left" it the other way
    xor al, 1
    call a20_set
    jmp restore_all

blk_runs    times (MAXRUNS * 6) db 0
stub_end:
; the bounce buffer follows, 1KB plus up to 511 bytes of alignment: runtime
; only, so no file bytes
%if (stub_end - stub_start) + 1024 + 512 + ST_STACK_USE > HB_PARAS * 16
 %error "the hidden block is too small for the stub, the extents and the bounce"
%endif
