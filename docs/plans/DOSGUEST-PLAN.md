# `dosguest` - starting os8088 from DOS, and returning to it

**Status: PLAN. Nothing is built.**

**The ask:** run os8088 from a DOS prompt, and exit back to that prompt with
DOS as it was. The first version takes the whole machine. A later version lets
os8088 call DOS for file operations, through a loadable `.DRV`, so that normal
operation pays no memory for it.

This is the mirror image of `docs/plans/KERN-DOS-PLAN.md`. `kern_dos` leaves
os8088 for a DOS program and comes back. `dosguest` leaves DOS for os8088 and
comes back.

---

## 1. Summary

1. **os8088 cannot coexist with DOS in conventional memory.** The kernel
   is at 0000:0600 (`KERNEL_SEG` 0x0060, SPEC.md 2) and every package's far
   calls are baked against that address. DOS is resident in the same bytes.
2. **So DOS is swapped out.** A launcher writes conventional memory to a file,
   boots os8088, and on exit reads it back. SPEC.md 87 (Hibernate) already does
   this for os8088's own memory. It supplies the image format, the stub that
   runs from video RAM, and the extent-list reader.
3. **The hazard is not the memory. It is the interrupt vectors and the disk.**
   Sections 4 and 5.
4. **Version 1 treats every DOS-visible volume as read-only.** Section 5.
5. **Version 2 (separate PR) is a pass-through `.DRV`.** Section 8.

## 2. Terms

| term | meaning |
|---|---|
| launcher | the DOS program (`OS8088.COM` or `.EXE`) that the user types |
| swap image | conventional memory, linear 0 to the top of DOS memory, in a file |
| stub | the short routine copied into video RAM that does I/O with `int 13h` while nothing else is in memory (SPEC.md 87.5) |
| host | the DOS machine os8088 was started from |

## 3. Why swap, and not "load above DOS"

Loading os8088 above DOS needs `KERNEL_SEG` to be a runtime value. SPEC.md 2
records that it is a constant in three places, one of which is baked into every
`.o88`. Making it variable touches every package and every far-call target.
That is a different and much larger change, and it gives a worse result: DOS
and a 640 KB-designed OS would share the arena, and neither has room.

Swapping is also what `kern_dos` and Hibernate already do, so the mechanism is
proven on real hardware (`docs/reports/KERN-DOS-BUDGET-2026-09-13.md`).

## 4. Entering os8088

### 4.1 Sequence

1. **Refuse unsafe hosts.** Not real mode (Windows, EMM386 or QEMM in V86
   mode, a DPMI host): `smsw` bit 0 on a 286 or later, plus INT 2Fh AX=1600h.
   An 8086 cannot be in V86, so it skips the check. Refuse if conventional
   memory is below the os8088 floor.
2. **Find the volume.** The launcher's own drive, via the BPB. Needs: unit,
   LBA of the volume start, geometry. The same facts the resume stub already
   takes (SPEC.md 87.5, step 1).
3. **Write the swap image** with DOS calls, to a file in the root of that
   volume, before anything is torn down. Size is linear 0 to top of memory
   (INT 12h). Same shape as `HIBERNAT.IMG` (SPEC.md 87.3): no header, file
   offset n is linear address n.
4. **Flush DOS.** INT 21h AH=0Dh (disk reset). Flush a write-behind cache
   if one is present (SMARTDRV: INT 2Fh AX=4A10h). The swap file's clusters
   must be on disk before the stub reads them with `int 13h`.
5. **Walk the swap file's FAT chain into an extent list.** Same code path as
   SPEC.md 87.5. Contiguity is not required.
6. **Save the host's hardware state** that is not in the image (section 4.3).
7. **Put a clean machine in front of os8088** (section 4.2).
8. **Load and enter os8088.** Section 4.4.

### 4.2 The vectors (the central hazard)

os8088 does not own the interrupt vectors on its own. At boot, `sch_hook`
reads INT 08h and keeps it as `sch_old08`, and every tick **chains to it first**
(`kernel/sched.inc`, `sch_isr`). `mouse_init` does the same with INT 09h
(`kernel/mouse.inc`). That is correct after a BIOS boot, where those vectors
are ROM. Under DOS they may point at a TSR, a resident mouse driver, or
anything else in the memory os8088 has just overwritten. The first tick then
jumps into garbage.

The other hardware vectors have the same problem in a quieter form: IRQ 3/4,
5, 7, 10 to 15 and their vectors, which os8088 does not claim, can fire into
overwritten code.

**Candidate fixes, in order of preference:**

1. **A host flag in the handoff block, read by `sch_hook` and `mouse_init`.**
   When set, the saved "old" vector is the launcher's one-instruction `iret`
   thunk and not whatever is in the IVT, and os8088 keeps `[ticks]` and the
   BDA tick count itself. Cost: a few bytes in the kernel image, on `kern_emu`
   only if the budget requires (section 7).
2. **Reinstall BIOS defaults.** The IBM-compatible entry points
   (F000:FEA5 for IRQ 0 and so on) are common but not universal. Use only as
   a cross-check, not as the mechanism.
3. **Mask every IRQ except the ones os8088 enables**, so unclaimed vectors
   never fire. Needed in any case; not sufficient alone, because the claimed
   ones chain.

Fix 1 plus 3 is the proposal. Fix 1 needs reading `sch_hook` and `mouse_init`
closely, because both are on hot paths with a size budget (SPEC.md 15.1,
`KERN_BUDGET`).

### 4.3 Hardware state not in the image

The image is memory only. The following are saved by the launcher and
restored by the return stub (section 6), and each is an item to verify on a
real machine and not assume:

| state | how | note |
|---|---|---|
| PIC masks, both | `in 21h` / `in A1h` | |
| PIT channel 0 reload and mode | latch and read | os8088 reprograms it; the tick count in the BDA will drift by the time spent in os8088 |
| keyboard controller | drain the output buffer; restore the command byte if changed | |
| video mode and cursor | `int 10h` AH=0Fh, AH=03h on return | graphics-mode hosts: text mode only in v1 |
| video RAM | B800 (4 KB, or the active page set) | the stub itself uses it (SPEC.md 87.5), so it must be saved first |
| A20 | read, restore | `kern_emu` has `XMEM.DRV`; see section 4.5 |
| RTC, DMA | not saved in v1 | document as not preserved, as SPEC.md 87 does |

DOS drivers that own hardware (mouse, sound, network) keep state in the device
that the image cannot restore. On return the launcher's resident return
point calls the usual reset where one exists (INT 33h AX=0 for a mouse).
Everything else is listed in the user-facing limits, as SPEC.md 87.4 lists its
own.

### 4.4 Loading os8088

os8088 boots in two stages (SPEC.md 2.9). Stage 1 reads the first
`BOOT2_SECS` sectors of `KERNEL.SYS` to `HEAP_SEG` and jumps in with DL, DH,
CX, SI, BP and DI set from the volume's BPB. Stage 2 reads the rest.

**The launcher stands in for stage 1.** It sets the same registers and jumps.
This reuses stage 2 unchanged. The inputs it must supply are the unit, the
geometry, the LBA of the data area, and the KSIG canary (`boot2.asm` header).

**Open question 1:** `KERNEL.SYS` must be reachable by LBA from the stub's
point of view. A DOS volume may carry it anywhere, fragmented. Stage 2's
`read_run` takes a contiguous run. Options: require a contiguous file (check
and refuse), give stage 2 an extent list as the stub already has, or let the
launcher read the kernel itself with DOS calls and jump straight to the
kernel entry. The third is simplest and costs nothing in os8088. It leaves
stage 2 out entirely, so confirm that nothing in `kmain` depends on stage 2
having run.

### 4.5 Memory above 1 MB

The image does not cover extended memory (SPEC.md 87.7 draws the same line).
A host may have HIMEM.SYS, a RAM drive, a SMARTDRV cache or the HMA in use,
and os8088's `XMEM.DRV` would write over them.

v1 rule: **`XMEM.DRV` is not loaded under dosguest**, and the launcher refuses
if the HMA is claimed. os8088 runs on conventional memory only. A later
version can allocate through the XMS API and pass os8088 the range it owns.

## 5. Disk consistency, and why v1 is read-only

DOS keeps disk buffers and, on a hard disk, an in-memory FAT and directory
cache. The swap image is a snapshot of those buffers at the moment of the
swap. If os8088 changes the volume while it runs, DOS resumes with buffers
that disagree with the disk, and the next write can corrupt the volume.

For a floppy DOS notices a media change through the change line. For a hard
disk nothing tells it.

**v1 rule: os8088 mounts every volume DOS can see read-only, and writes only
to storage DOS does not hold.** That means a RAM disk, or a volume on a
partition DOS has not mapped. os8088's own settings need a home that
satisfies this.

**Open question 2:** the existing DRV layer has per-volume write control
(`dskw_*`, SPEC.md 18). The task is to find the narrowest place to enforce
read-only on a host volume. A `DVK_*` flag on the row is the likely shape.

A way to invalidate DOS's buffers on return (a device I/O call per drive, or
setting the drive's media-changed state in the DPB) would allow v1.1 to relax
this. It is DOS-version-specific and out of scope here.

The swap file itself is safe: DOS writes it and flushes before the swap
(section 4.1, step 4), and os8088 never touches it.

## 6. Exiting os8088

1. A menu item, **Exit to DOS**, present only when the handoff block says
   os8088 was started by dosguest. Same position as Hibernate (SPEC.md 12.1).
2. The kernel's restart sweep runs: detach drivers, `drv_shutdown`,
   `sched_unhook`, and give back INT 09h, as SPEC.md 87.4 step 7 does. Under
   dosguest the vectors given back are the launcher's thunks (section 4.2),
   not DOS's.
3. Copy the return stub, its parameters and the extent list into video RAM.
   Same stub as SPEC.md 87.5 with the payload reversed.
4. The stub reads the swap image back to linear 0, over the IVT, the BDA and
   everything else. This restores DOS's vectors with the rest of the image.
5. Restore the section 4.3 state. Reload the video mode.
6. Jump to the launcher's return point, which is inside the restored image.
   It deletes the swap file with DOS, resets the devices it can, and exits
   with the code os8088 passed (the exit code rides in the BDA; KERN-DOS-PLAN
   8.2 measured that it survives).

**Failure.** If the swap file is unreadable or the extents are bad, the
stub cannot restore DOS. It prints a message and waits for a key, then does
`int 19h`. The swap file is left on disk and the launcher's next run offers to
discard it, as the hibernate probe does (SPEC.md 87.5).

## 7. Build

- A separate `OS8088.COM`, built with the DOS toolchain this tree already has
  (`docs/C-TOOLCHAIN.md`, or flat NASM). Not part of the kernel.
- A small change to `sched.inc` and `mouse.inc` for the host flag (4.2). If
  the footprint matters, it is `%ifdef KERN_EMU` or a new `KERN_DOSGUEST` kernel
  family, like `make small` and `make emu` (SPEC.md 9.11.7). This is a decision
  for whoever owns `KERN_BUDGET`. It is not a build fix.
- A new disk image or folder layout: `OS8088.COM`, `KERNEL.SYS` and the
  driver set, in one directory on a DOS volume.
- Every Makefile and index change goes through `tools/os88index.py` and
  `make checkdocs`.

## 8. Version 2: DOS as a loadable backend

**Not for this PR.** Recorded here so version 1 does not close the door.

The aim: under dosguest, os8088 can read and write host files through DOS
instead of treating the host disk as read-only. In normal operation nothing
extra is resident.

Shape, for later: a `DRVC_FILE`-class `.DRV` (SPEC.md 51), loaded only when
the handoff block says dosguest. It would need DOS **and its memory**, which
conflicts with section 3. Candidate approaches, none chosen:

1. **Keep a small part of DOS resident** in a reserved low region os8088 does
   not claim, and call it through a real-mode trampoline. Needs a kernel
   reservation, which `KERN_BUDGET` pays for.
2. **Reload the swap image on demand.** Swap os8088 out and DOS in for each
   call. Seconds per call (KERN-DOS-PLAN 2.2). Only suitable for rare
   operations such as opening a file.
3. **Reimplement the host's FAT in the driver and invalidate DOS's caches on
   return.** Moves the section 5 problem rather than solving it.

Section 5's resolution decides which of these is viable.

## 9. Plan of work

| wave | what | gate |
|---|---|---|
| W0 | Read `sch_hook`, `mouse_init`, `kmain`'s assumptions about stage 2 and about the IVT. Answer open questions 1 and 2 on paper. | this document updated |
| W1 | Launcher: refuse unsafe hosts, write and verify the swap image, build the extent list. No os8088 yet. | a DOS test program restores itself byte for byte |
| W2 | Enter os8088 with the clean-vector shim and stage-1 stand-in. Return by `int 19h` only. | boots to the desktop under a DOS in QEMU and in MartyPC |
| W3 | The return path: stub, hardware state, launcher return point. | exit to DOS; a DOS program and a TSR both survive the round trip |
| W4 | Read-only enforcement on host volumes. | a write to the host volume is refused; the host `CHKDSK` is clean afterwards |
| W5 | Real hardware: 5150, an AT, and a machine with a TSR mouse driver and a disk cache. | `docs/FIELD-MACHINES.md` |

## 10. What would kill this

- **A host whose BIOS vectors cannot be neutralised.** If fix 1 in 4.2 proves
  too expensive for the kernel budget and fix 2 is unreliable, the launcher
  can only work on a clean DOS with no hardware TSRs. That is a narrower
  product, not no product.
- **A disk cache that cannot be flushed from the outside.** A write-behind
  cache with no flush entry point makes the swap image unsafe to read back
  with `int 13h`. The launcher must refuse on such a host.
- **A host with extended memory in use** where the XMS API cannot be reached
  (4.5). This is only a v1 limit, not fatal.

## 11. Testing

`docs/TESTING.md` is the reference for what each emulator can do. Starting
points, to be checked there before relying on them:

- QEMU and MartyPC boot a DOS floppy or hard disk image. MS-DOS, FreeDOS and
  PC-DOS differ in their buffers, so test at least two.
- The swap round trip is a byte comparison and does not need a display.
- Anything about timing off MartyPC's hard disk is not quotable
  (`docs/TESTING.md`, KERN-DOS-PLAN 2.2).
