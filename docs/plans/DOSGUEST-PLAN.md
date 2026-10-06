# `dosguest` - starting os8088 from DOS, and returning to it

**Status: wave 1 is built and passing (section 12). Waves 2 to 6 are plan.**

**The ask:** run os8088 from a DOS prompt, and exit back to that prompt with
DOS as it was. The first version takes the whole machine. A later version lets
os8088 call DOS for file operations, through a loadable `.DRV`, so that normal
operation pays no memory for it.

This is the mirror image of `docs/plans/KERN-DOS-PLAN.md`. `kern_dos` leaves
os8088 for a DOS program and comes back. `dosguest` leaves DOS for os8088 and
comes back.

## Decisions taken

| decision | by | consequence |
|---|---|---|
| Version 1 treats every DOS-visible volume as read-only | owner | Section 5 |
| **Suspend and rehydrate live outside os8088**, in the launcher | owner | os8088 learns nothing about DOS. Section 3 |

---

## 1. Summary

1. **os8088 cannot coexist with DOS in conventional memory.** The kernel
   is at 0000:0600 (`KERNEL_SEG` 0x0060, SPEC.md 2) and every package's far
   calls are baked against that address. DOS is resident in the same bytes.
2. **So DOS is swapped out, by the launcher.** It writes memory to a file,
   boots os8088, and a stub it left behind reads the file back.
3. **The launcher hides a block of top RAM from os8088** by lowering the BIOS
   memory size (`0040:0013`, which is what `int 12h` returns). os8088 sizes
   itself from `int 12h` (`kernel/memory.inc`, `boot/boot.asm`), so it never
   touches the block. The block holds the return stub, so nothing needs
   to survive in video RAM, which the CGA and Hercules framebuffers would
   overwrite.
4. **Exit is os8088's existing Restart.** It ends in a software `int 19h`
   (`kernel/ui.inc`, `ui_cmd_reboot`). The launcher points the IVT's INT 19h
   entry into the hidden block, so Restart returns to DOS.
5. **Expected kernel change in version 1: none.** Section 4.2 is the one place
   this could fail.
6. **Version 2 (separate PR) is a pass-through `.DRV`.** Section 8.

## 2. Terms

| term | meaning |
|---|---|
| launcher | the DOS program (`OS8088.COM` or `.EXE`) that the user types |
| swap image | the saved DOS memory, in a file |
| hidden block | top-of-memory RAM the launcher removes from the BIOS memory size |
| return stub | code in the hidden block that reads the swap image back and resumes DOS |
| host | the DOS machine os8088 was started from |

## 3. Shape

### 3.1 Why swap, and not "load above DOS"

Loading os8088 above DOS needs `KERNEL_SEG` to be a runtime value. SPEC.md 2
records that it is a constant in three places, one of which is baked into every
`.o88`. Making it variable touches every package and every far-call target,
and the result is a worse machine, with DOS and an OS designed for 640 KB
sharing one arena.

### 3.2 Why the logic is outside os8088

Everything that knows about DOS (the swap file, the FAT chain, the hardware
state, the return) sits in the launcher and the return stub. os8088 sees a
machine with slightly less RAM, a clean set of vectors, and a reboot that
happens to land somewhere else. That keeps `KERN_BUDGET` untouched and keeps
os8088 bootable on machines that have never heard of DOS.

### 3.3 The hidden block

1. The launcher allocates the block from DOS, from the top of the arena
   (INT 21h AH=58h to set last-fit, then AH=48h), so DOS considers it owned.
2. It sets `0040:0013` to the block's base in KB. From then on `int 12h`
   answers a smaller machine.
3. The block is **not** part of the swap image. It is the launcher's own
   state, so there is nothing to overwrite and nothing to restore.
4. On return, the image restore puts the original `0040:0013` back with the
   rest of the BDA, and DOS owns the block again; the launcher frees it.

The block holds:

| contents | notes |
|---|---|
| return stub | reads the extent list, reads the image, restores hardware, jumps back |
| extent list | LBA and length of each run of the swap file |
| saved hardware state | section 4.3 |
| vector thunks | section 4.2 |
| the INT 19h entry | where Restart lands |

Size is a few hundred bytes plus the extent list. Round up to a paragraph and
let os8088 lose 1 KB.

## 4. Entering os8088

### 4.1 Sequence

1. **Refuse unsafe hosts.** Not real mode (Windows, EMM386 or QEMM in V86
   mode, a DPMI host): `smsw` bit 0 on a 286 or later, plus INT 2Fh AX=1600h.
   An 8086 cannot be in V86 so it skips the check. Refuse if conventional
   memory is below the os8088 floor.
2. **Find the volume.** The launcher's own drive, via the BPB: unit, LBA of
   the volume start, geometry. The same facts the resume stub already takes
   (SPEC.md 87.5, step 1).
3. **Allocate the hidden block** (3.3).
4. **Allocate the swap file with DOS, fill it with raw `int 13h`.** DOS
   creates `\DGSWAP.IMG` at the image's size so that it owns the clusters.
   The image itself is then written by the stub, from the hidden block, with
   raw `int 13h`. **It is not written through DOS**: a DOS write changes DOS's
   own state (SFT, buffers) while the image is being captured, and the result
   would be a snapshot no instant ever held (SPEC.md 87.4 writes through the
   kernel's own layer for the same reason). Layout as `HIBERNAT.IMG`
   (SPEC.md 87.3): no header, file offset n is linear address n, from 0 to
   the image's top, which is the hidden block's base rounded down to 16 KB.
5. **Flush DOS.** INT 21h AH=0Dh. Flush a write-behind cache if present
   (SMARTDRV: INT 2Fh AX=4A10h). The swap file's clusters must be on disk
   before the stub reads them with `int 13h`.
6. **Walk the swap file's FAT chain into an extent list** (SPEC.md 87.5).
   Contiguity is not required.
7. **Save hardware state** (4.3) into the hidden block.
8. **Install the vector thunks and the INT 19h entry** (4.2, 6).
9. **Load and enter os8088** (4.4).

**Optimisation, not v1:** the image need not carry free memory. Walking the
MCB chain, only allocated blocks, the MCB headers, the IVT and the BDA have
to be saved. A typical DOS has under 100 KB in use against 640. It cuts the
write and the read by most of their cost, at the price of the launcher
understanding the arena.

### 4.2 The vectors (the central hazard)

os8088 does not own the interrupt vectors on its own. At boot `sch_hook`
reads INT 08h and keeps it as `sch_old08`, and every tick **chains to it first**
(`kernel/sched.inc`, `sch_isr`). `mouse_init` does the same with INT 09h
(`kernel/mouse.inc`). That is right after a BIOS boot, where those vectors are
ROM. Under DOS they may point at a TSR or a resident driver in memory os8088
has just overwritten, and the first tick jumps into garbage. The other hardware
vectors (IRQ 3/4, 5, 7, 10 to 15) have the same problem, quietly.

**What wave 1 found, on a stock FreeDOS 1.4 (section 12):** every hardware
vector is in RAM. FreeDOS wraps IRQ 08h to 0Fh and 70h to 77h in stubs inside
its kernel segment, and the "refuse if the vector is in RAM" rule I first
wrote would refuse a stock FreeDOS every time. The stubs keep the original ROM
vector inline, so it can be recovered.

**Policy for version 1, with no kernel change:**

1. **DOS's own vectors stay in the swap image.** They come back on the resume.
   The launcher never edits them in place.
2. **The launcher builds a CLEAN set** of the 16 hardware vectors (08h to 0Fh,
   70h to 77h) and the stub writes it into the live IVT **after** the
   snapshot. That is what os8088 is handed, so `sch_hook` and `mouse_init`
   chain to ROM as after a BIOS boot.
3. **For each vector:** in ROM (segment at or above C000), it is its own clean
   value. Otherwise follow it, up to eight links, through the two shapes that
   keep the previous vector inline:
   - the **IBM Interrupt Sharing Protocol** header, `EB 10 | dd old | 'KB'`
     (FreeDOS uses it for IRQ 2 to 7 and 70h to 77h, and so do many TSRs);
   - **FreeDOS's wrapper**, `E8 rel16 | dd old` (IRQ 0 and 1).
4. **Anything else in RAM is a TSR the launcher cannot see through.** It
   refuses, naming the vector and where it points.
5. **INT 13h itself has to be in ROM.** The stub's disk service is the only
   way back and calls it through a saved far pointer.
6. **During the restore the IVT is the first thing overwritten**, and the BIOS
   disk code takes IRQ 6 and IRQ 14 through INT 0Eh and INT 76h. Those two
   would point into DOS code not yet restored. The stub re-applies the clean
   values for those two before **every** `int 13h` of the restore, and puts
   DOS's back at the end.
7. Mask every IRQ except the disks' (6, 14 and the cascade) while the stub
   runs. Restore the PIC masks.

Still open: a TSR that hooks INT 08h or 09h without either shape. That is the
case the earlier draft's thunk was for. `INT 15h` is unchecked: a BIOS disk
call may chain through it (HIMEM hooks it), and a stub that runs HIMEM's code
mid-restore is a crash. W4 tests it.

### 4.3 Hardware state not in the image

The image is memory only. The launcher saves the following into the hidden
block, and the return stub restores it. Each is something to verify on a real
machine, not to assume:

| state | how | note |
|---|---|---|
| PIC masks, both | `in 21h` / `in A1h` | |
| PIT channel 0 reload and mode | latch and read | os8088 reprograms it; the BDA tick count drifts by the time spent in os8088 |
| keyboard controller | drain the output buffer; restore the command byte if changed | |
| video mode and cursor | `int 10h` AH=0Fh, AH=03h; set on return | text-mode hosts only in v1 |
| text video RAM | B800 (4 KB, active page) | the BIOS and os8088 will both have drawn on it |
| A20 | read, restore | |
| RTC, DMA | not saved in v1 | documented as not preserved, as SPEC.md 87 does |

DOS drivers that own hardware (mouse, sound, network) keep state in the device,
which the image cannot restore. On return the launcher calls the usual reset
where one exists (INT 33h AX=0 for a mouse). The rest is listed in the user's
limits, as SPEC.md 87.4 lists its own.

### 4.4 Loading os8088

os8088 boots in two stages (SPEC.md 2.9). Stage 1 reads the first
`BOOT2_SECS` sectors of `KERNEL.SYS` to `HEAP_SEG` and jumps in with DL, DH,
CX, SI, BP and DI set from the volume's BPB. Stage 2 reads the rest.

**The launcher stands in for stage 1.** It sets the same registers and jumps.
This reuses stage 2 unchanged. The inputs are the unit, the geometry, the LBA
of the data area, and the KSIG canary (`boot2.asm` header).

**Open question 1:** `KERNEL.SYS` must be reachable by LBA. A DOS volume may
carry it anywhere, fragmented, and stage 2's `read_run` takes a contiguous
run. Options: require a contiguous file and refuse otherwise, extend stage 2 to
take an extent list as the stub does, or have the launcher read the kernel
itself with DOS calls and jump to its entry. The third is simplest and changes
nothing in os8088, but skips stage 2, so it needs a check that `kmain` does
not depend on stage 2 having run.

### 4.5 Memory above 1 MB

The image does not cover extended memory (SPEC.md 87.7 draws the same line). A
host may have HIMEM.SYS, a RAM drive, a SMARTDRV cache or the HMA in use, and
os8088's `XMEM.DRV` would write over them.

v1 rule: **`XMEM.DRV` is not loaded under dosguest**, and the launcher refuses
if the HMA is claimed. A later version can allocate through the XMS API and
pass os8088 the range it owns.

## 5. Disk consistency: v1 is read-only

DOS keeps disk buffers and, on a hard disk, an in-memory FAT and directory
cache. The swap image is a snapshot of those at the moment of the swap. If
os8088 changes the volume, DOS resumes with buffers that disagree with the
disk and the next write can corrupt it. A floppy's change line tells DOS; a
hard disk's nothing does.

**Decided: os8088 treats every volume DOS can see as read-only and writes only
to storage DOS does not hold** (a RAM disk, or a partition DOS has not mapped).
The swap file is safe: DOS writes and flushes it before the swap, and os8088
never touches it.

**Open question 2:** where to enforce read-only. The existing disk layer has
per-volume write paths (`dskw_*`, SPEC.md 18). The narrowest place is likely a
flag on the volume row. This is **a kernel change** and the one place the
"no kernel change" claim is soft. Two ways out:

- **Enforce in the launcher.** Not evidently possible: the launcher has no way
  to write-protect a hard disk, and none was found for a floppy.
- **Do not mount it.** The launcher gives os8088 only its own boot volume and
  removes the DOS volume from what os8088 sees. Needs reading how
  `[dsk_bootvol]` and the hard-disk driver choose volumes (SPEC.md 52.10.3).

Resolve this in W0, before anything else, because it decides whether v1
touches the kernel at all.

A way to invalidate DOS's buffers on return would let a later version relax
this. It is DOS-version-specific and out of scope.

## 6. Exiting os8088

1. The user picks **Restart**. It is os8088's existing path (SPEC.md 87.4
   step 7): detach drivers, `drv_shutdown`, `sched_unhook` (which gives INT
   08h and 09h back), the floppy park, then a software `int 19h`.
2. `int 19h` follows the IVT entry the launcher set (4.1 step 8) into the
   hidden block. The return stub runs there.
3. The stub reads the swap image back to linear 0 using `int 13h` and the
   extent list, over the IVT, the BDA and everything os8088 left. The hidden
   block is outside the image, so the stub is not overwritten while it runs.
   DOS's vectors, including its own INT 19h, come back with the image.
4. The stub restores the 4.3 state and the video mode.
5. The stub jumps to the launcher's return point, inside the restored image.
   The launcher frees the hidden block, deletes the swap file with DOS, resets
   the devices it can, and exits to the prompt.

**What the user sees:** Restart returns to DOS. There is no separate "Exit to
DOS" item in v1. If that is confusing, a label change is a one-line follow-up
that does not belong in this PR, and a menu item keyed on a handoff flag is
the kernel change this design avoids.

**What if the user wants a real reboot?** Restart cannot do both. v1 chooses
DOS. Whether Ctrl-Alt-Del still reaches a real reboot while os8088 runs is
untested.

**Failure.** If the swap file is unreadable or the extents are bad, the stub
cannot restore DOS. It prints a message and waits for a key, then reboots
through the ROM (`jmp F000:FFF0`, not `int 19h`, which is ours). The swap
file stays on disk; the launcher's next run notices it and offers to delete
it.

## 7. Build

- A separate `OS8088.COM`, built with flat NASM like the rest of the tree. Not
  part of the kernel.
- Layout on a DOS volume: `OS8088.COM`, `KERNEL.SYS` and the driver set, in one
  directory.
- Kernel changes: **none expected**. The candidates, in the order they could
  appear, are the read-only enforcement (5, open question 2) and, as a last
  resort, a vector host flag (4.2). Either is `KERN_BUDGET`'s owner's call
  and not a build fix.
- Every Makefile and index change goes through `tools/os88index.py` and
  `make checkdocs`.

## 8. Version 2: DOS as a loadable backend

**Not for this PR.** Recorded so version 1 does not close the door.

The aim: under dosguest, os8088 reads and writes host files through DOS. In
normal operation nothing extra is resident.

Shape, for later: a `DRVC_FILE`-class `.DRV` (SPEC.md 51), loaded only under
dosguest. It needs DOS **and its memory**, which conflicts with 3.1. Candidate
approaches, none chosen:

1. **Keep a small part of DOS resident** in the hidden block, called through a
   real-mode trampoline. The hidden block is already the mechanism, so this
   grows it. It costs os8088 whatever it grows by, and only under dosguest,
   because the launcher decides the size.
2. **Reload the swap image on demand.** Swap os8088 out and DOS in for each
   call. Seconds per call (KERN-DOS-PLAN 2.2). Only for rare operations.
3. **Reimplement the host's FAT in the driver and invalidate DOS's caches on
   return.** Moves the section 5 problem rather than solving it.

The hidden block makes option 1 the natural one: the cost is paid only when
the launcher asks for it.

## 9. Plan of work

| wave | what | gate |
|---|---|---|
| W0 | Answer open questions 1 and 2 on paper: how the kernel picks volumes, what `kmain` assumes of stage 2. Confirm `int 12h` is the only source of `mem_top` and that nothing reads the BDA word directly. Decide whether v1 touches the kernel. | this document updated |
| W1 | **DONE.** Launcher: hidden block, swap file, extent list, stub, vector policy. No os8088. `dosguest/dg.asm`, `tests/dosguest.py` | a DOS machine restores itself byte for byte, and the swap file read back off the disk holds it |
| W2 | Vector policy (4.2) and hardware state (4.3). Enter os8088 with the stage-1 stand-in. Exit by Restart. | boots to the desktop under a DOS in QEMU and MartyPC; Restart returns to the prompt |
| W3 | Read-only enforcement (5). | a write to the host volume is refused; the host `CHKDSK` is clean afterwards |
| W4 | A TSR and a disk cache on the host: refuse or survive, as designed. | `docs/TESTING.md` rows |
| W5 | Real hardware: 5150, an AT, a machine with a mouse driver and a cache. | `docs/FIELD-MACHINES.md` |
| W6 (optional) | MCB-aware image: skip free memory. | image size and round-trip time against the full image |

## 10. What would kill this

- **Refusing too often.** If most real DOS setups have a RAM-resident hook on
  INT 08h or 09h, the launcher works only on a clean DOS. The thunk fallback
  in 4.2 is the answer, and it is real work.
- **`int 12h` not being the only truth.** If the kernel, a driver or a package
  reads RAM size from somewhere else, the hidden block is not hidden. W0
  checks this.
- **A disk cache that cannot be flushed from outside.** A write-behind cache
  with no flush entry point makes the swap image unsafe to read back with
  `int 13h`. The launcher refuses on such a host.
- **A host with extended memory in use** where the XMS API cannot be reached
  (4.5). A v1 limit, not fatal.

## 11. Testing

`docs/TESTING.md` is the reference for what each emulator can do. Starting
points, to be checked there before relying on them:

- QEMU and MartyPC boot a DOS floppy or hard disk image. MS-DOS, FreeDOS and
  PC-DOS differ in their buffers, so test at least two.
- The swap round trip is a byte comparison and does not need a display.
- Anything about timing off MartyPC's hard disk is not quotable
  (`docs/TESTING.md`, KERN-DOS-PLAN 2.2).

## 12. Wave 1: what was built and what it found

`dosguest/dg.asm` (8 KB `.COM`, 8086 code) and `tests/dosguest.py`, run under
stock FreeDOS 1.4 in QEMU (`python3 tools/getfreedos.py` fetches the boot
floppy at a pinned SHA-256 and never commits it; `make dosguest` builds
`build/DG.COM`). Nothing in os8088 changed.

What the launcher does, in the order it does it: refuse DOS older than 3.31;
build the clean vector set (4.2); take the hidden block from the top of the
arena with last-fit allocation; copy the stub into it; fill every free
paragraph with a pattern; make `\DGSWAP.IMG` through DOS; read the BPB with
INT 25h's packet form; find the BIOS unit by comparing the volume's boot sector
as DOS read it with the BIOS's, for units 80h up; find the file's extents by
walking the FAT itself; then call the stub, which writes the image with raw
`int 13h`, saves DOS's vectors, applies the clean set, lowers `0040:0013` and
returns. The test then calls the stub's second entry, which fills memory with
`0xCC` and restores. The stub returns a second time into the same place with
`AX=1`, the way `setjmp` does.

**Result on FreeDOS 1.4 / QEMU (SeaBIOS), 8 MB:** 639 KB visible before, 624 KB
while hidden, 639 KB after. A 489 KB pattern came back with 0 mismatches and
the IVT with 0. The swap file is one contiguous run of 1,248 sectors. The
snapshot holds the original memory size and DOS's own INT 08h
(`0070:000F`), not the clean one, which is the point of taking it first.
`tools/dgfat.py`, a FAT reader that shares nothing with the guest, finds the
same extent, and the pattern regenerated on the host is found in the swap file
read off the disk after the guest has gone.

**Findings that changed the design:**

1. **Stock FreeDOS wraps every IRQ vector in RAM** (4.2). The refuse-on-RAM
   rule was wrong for it. The clean set is built by unwrapping.
2. **The image must not be written through DOS** (4.1).
3. **The restore overwrites the IVT first, and the BIOS needs two of those
   vectors to finish the disk call** (4.2, point 6).
4. **The BIOS cursor lives in the BDA**, which the restore rewrites, so a mark
   printed after the resume lands on top of one printed before it. A debug
   build (`-DDEBUG`) that prints a letter per step looks wrong for that reason
   and is not.
5. **The image is rounded down to 16 KB**, so up to 16 KB below the hidden
   block is in neither the snapshot nor os8088's machine. It is untouched, so
   DOS is unharmed, but os8088 loses it. Rounding to 1 KB needs the swap file
   written in 1 KB-aligned chunks; a later optimisation.

**Not done, and not claimed:** XT or 8086 (QEMU only, so the CPU is a 386 running
8086 code); any DOS but FreeDOS; any BIOS but SeaBIOS; a hard-disk
partition table (the test volume is unpartitioned, so the BIOS-unit search was
only exercised at hidden sector 0); FAT32 and partitions over 32 MB (the
launcher refuses them); drive letters that are not the current drive's
volume; large-disk CHS (the stub refuses a cylinder above 1023); video state,
DOS's timer tick, and the extended-memory refusal of 4.5.
