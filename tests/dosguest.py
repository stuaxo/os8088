#!/usr/bin/env python3
"""dosguest wave 1: DOS is suspended to a file and put back (docs/plans/DOSGUEST-PLAN.md).

    python3 tests/dosguest.py

There is no os8088 in this wave. dosguest/dg.asm runs under a REAL DOS - stock
FreeDOS 1.4, fetched by tools/getfreedos.py - and does the part that has to be
right before os8088 is involved at all:

  * takes a block from the top of the DOS arena and lowers the BIOS memory
    size to just under it (int 12h then answers the smaller machine);
  * fills every free paragraph with a known pattern;
  * writes conventional memory to \\DGSWAP.IMG with RAW int 13h from the
    block, never through DOS, so the snapshot is one instant;
  * puts the ROM's vectors in the live IVT (what os8088 would be handed),
    overwrites memory with 0xCC (what os8088 would do) and restores it.

THREE PARTIES AGREE OR THE ROW FAILS, and none of them is the one being tested:

  the guest   says what it did - and that the pattern and the IVT came back;
  tools/dgfat.py, a FAT reader that shares nothing with the guest, says where
              DGSWAP.IMG's clusters are, and they must be the guest's extents;
  this file   regenerates the pattern on the host and finds it in the swap
              file at the offset of the block the guest says it filled.

The last is the one that matters. A restore that "worked" proves the stub can
read back what it wrote; it does not prove the file holds the machine. The swap
file is read off the disk image after the guest has gone.

WHAT IT ALSO FINDS, for the plan: the file must hold DOS's own vectors (not the
clean ones the live IVT was given) and the ORIGINAL memory size (not the lowered
one) - the snapshot is taken before either change.

NEGATIVE CONTROLS: the host checker is run on a copy of the swap file with one
byte of the pattern flipped and must refuse it.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import dgfat                                  # noqa: E402
import getfreedos                             # noqa: E402

PAT_SEED = 0x1234                             # dosguest/dg.asm's
FAILS = []


def check(cond, what):
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAILS.append(what)


def pattern_bytes(paras):
    x, out = PAT_SEED, bytearray()
    for _ in range(paras * 8):
        x = (x * 25173 + 13849) & 0xFFFF
        out += x.to_bytes(2, "little")
    return bytes(out)


def pattern_ok(swap, seg, paras):
    """Does the swap file hold the pattern where the guest says it filled?

    Only the part INSIDE the image: the image is rounded down to 16KB, so the
    top of the pattern block can lie between the image's end and the hidden
    block. That memory is in neither the snapshot nor os8088's machine, which
    is why the guest's own verify passes over it and this must not look.
    """
    o = seg * 16
    n = min(paras * 16, len(swap) - o)
    return n > 0 and swap[o:o + n] == pattern_bytes(paras)[:n]


def sh(*a, **k):
    return subprocess.run(a, check=True, capture_output=True, **k)


def run_guest(work, ram_mb, defs=(), secs=120):
    """Boot FreeDOS with DG.COM on C:, return (result dict, data.img path)."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", *defs, "-f", "bin", "-o", com,
       os.path.join(ROOT, "dosguest", "dg.asm"))
    boot = os.path.join(work, "boot.img")
    shutil.copy(getfreedos.IMG, boot)
    cfg = os.path.join(work, "cfg")
    auto = os.path.join(work, "auto")
    with open(cfg, "wb") as f:
        f.write(b"SHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 "
                b"/P=\\FDAUTO.BAT\r\n")
    with open(auto, "wb") as f:
        f.write(b"@echo off\r\nc:\r\ndg /k > c:\\log.txt\r\n"
                b"a:\\freedos\\bin\\fdapm poweroff\r\n")
    sh("mcopy", "-o", "-i", boot, cfg, "::FDCONFIG.SYS")
    sh("mcopy", "-o", "-i", boot, auto, "::FDAUTO.BAT")
    data = os.path.join(work, "data.img")
    sh("mformat", "-C", "-T", "16384", "-h", "16", "-s", "63", "-i", data, "::")
    sh("mcopy", "-o", "-i", data, com, "::DG.COM")
    try:
        p = subprocess.run(
            ["qemu-system-i386", "-display", "none", "-no-reboot", "-m", str(ram_mb),
             "-drive", "file=%s,format=raw,if=floppy" % boot,
             "-drive", "file=%s,format=raw,if=ide" % data, "-boot", "a"],
            timeout=secs, capture_output=True)
        check(p.returncode == 0,
              "the guest powered itself off (qemu exit %d)" % p.returncode)
    except subprocess.TimeoutExpired:
        if not defs:
            check(False, "the guest finished inside %d s" % secs)
        res = None
        txt = subprocess.run(["mtype", "-i", data, "::DGRESULT.TXT"], capture_output=True)
        return ("hung" if txt.returncode else "wrote"), data
    res = {"runs": []}
    txt = subprocess.run(["mtype", "-i", data, "::DGRESULT.TXT"],
                         capture_output=True)
    if txt.returncode:
        log = subprocess.run(["mtype", "-i", data, "::LOG.TXT"], capture_output=True)
        print("  guest console: %r" % log.stdout.decode("latin1"))
        return None, data
    for line in txt.stdout.decode("latin1").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "run":
            lba, n = v.split()
            res["runs"].append((int(lba, 16), int(n, 16)))
        else:
            res[k] = v
    return res, data


def main():
    for tool in ("nasm", "qemu-system-i386", "mcopy", "mformat", "mtype"):
        if not shutil.which(tool):
            print("dosguest: SKIP, no %s" % tool)
            return 0
    if not getfreedos.have():
        print("dosguest: SKIP, no FreeDOS (python3 tools/getfreedos.py)")
        return 0
    dgfat.selfcheck()
    work = tempfile.mkdtemp(prefix="dosguest-")
    try:
        res, data = run_guest(work, 8)
        check(res is not None, "the guest wrote \\DGRESULT.TXT")
        if res is None:
            return 1
        h = lambda k: int(res[k], 16)
        print("  guest: %s" % {k: v for k, v in res.items() if k != "runs"})
        check(res.get("resumed") == "1", "the guest resumed")
        check(h("mismatches") == 0, "the pattern came back (0 mismatches over "
              "%d KB)" % (h("pattern_paras") * 16 // 1024))
        check(h("ivt_mismatches") == 0, "DOS's vectors came back (IVT)")
        check(h("int12_hidden") == h("size_kb"),
              "int 12h answered the hidden size while os8088 would run")
        check(h("int12_after") == h("orig_kb"), "int 12h answered the original size after")
        check(h("int12_hidden") < h("orig_kb"), "and the hidden size is smaller")
        check(int(res["clean_int08"].split(":")[0], 16) >= 0xC000,
              "the clean INT 08h is in ROM (%s)" % res["clean_int08"])

        # --- the second reader and the swap file --------------------------
        img = open(data, "rb").read()
        vol = dgfat.Volume(img)
        runs, size = vol.extents(b"DGSWAP  IMG")
        check(runs == res["runs"], "dgfat.py finds the guest's extents %s" % (runs,))
        check(size == h("size_kb") * 1024, "the swap file is the image's size (%d)" % size)
        swap = vol.read(b"DGSWAP  IMG")
        seg, paras = h("pattern_seg"), h("pattern_paras")
        check(pattern_ok(swap, seg, paras),
              "the swap file holds the pattern at %04X:0, %d paragraphs" % (seg, paras))
        bda = int.from_bytes(swap[0x413:0x415], "little")
        check(bda == h("orig_kb"),
              "the snapshot holds the ORIGINAL memory size (%d KB), not the lowered" % bda)
        v08 = int.from_bytes(swap[0x20:0x22], "little") | \
            int.from_bytes(swap[0x22:0x24], "little") << 16
        check(v08 >> 16 < 0xC000,
              "the snapshot holds DOS's INT 08h (%04X:%04X), not the clean one"
              % (v08 >> 16, v08 & 0xFFFF))

        # --- negative controls ---------------------------------------------
        bad = bytearray(swap)
        bad[seg * 16 + 1000] ^= 0x01
        check(not pattern_ok(bytes(bad), seg, paras),
              "NEGATIVE: one flipped bit in the pattern is refused")
        check(not pattern_ok(swap, seg + 1, paras),
              "NEGATIVE: the pattern is not accepted at the wrong offset")

        # THE GUEST'S OWN NEGATIVE CONTROL: the same launcher with the restore
        # left out. The trash then wipes the launcher itself, so the honest
        # outcome is a machine that never comes back and writes no result.
        # A launcher that "passed" without restoring would be a row that
        # tests nothing.
        w2 = tempfile.mkdtemp(prefix="dosguest-neg-")
        try:
            how, _ = run_guest(w2, 8, defs=("-DBREAK_RESTORE",), secs=25)
            check(how == "hung",
                  "NEGATIVE: with the restore skipped the guest does not come back (%s)" % how)
        finally:
            shutil.rmtree(w2, ignore_errors=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("dosguest: %s" % ("FAIL (%d)" % len(FAILS) if FAILS else "ok"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
