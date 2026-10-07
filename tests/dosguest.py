#!/usr/bin/env python3
"""dosguest waves 1 and 2: DOS is suspended, os8088 runs, DOS comes back (docs/plans/DOSGUEST-PLAN.md).

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

WAVE 2 is the same launcher with a drive letter, `DG B:`, and the real thing:
the stub loads B:'s boot sector to 0000:7C00 and jumps to it with DL set, as a
BIOS does at int 19h, so os8088's own stage 1 runs unchanged. Restart is its
way home, because it ends in `int 19h` and the launcher has pointed that
vector at the stub. What is asserted, with the guest running and then after:

  * WHILE os8088 RUNS: its `mem_top` (read out of guest RAM at the address
    tools/os88sym.py gives) is the HIDDEN size, not the machine's. That is the
    whole of "os8088 cannot reach the block", read off os8088 itself;
  * os8088 reached a desktop, and Restart (System menu, by the serial mouse)
    took it out;
  * AFTER: DOS is back. The pattern os8088 overwrote is intact, the IVT is
    DOS's, the BIOS tick moved (os8088 ran), `dir` works, and the DOS text
    screen from before the launcher is on the glass again - video RAM is not in
    the image, so that one is the stub's own save and restore.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

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


def read_result(data):
    txt = subprocess.run(["mtype", "-i", data, "::DGRESULT.TXT"], capture_output=True)
    if txt.returncode:
        return None
    res = {"runs": []}
    for line in txt.stdout.decode("latin1").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "run":
            lba, n = v.split()
            res["runs"].append((int(lba, 16), int(n, 16)))
        else:
            res[k] = v
    return res


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


def dos_session(work, auto_lines, files=(), secs=90):
    """Boot FreeDOS, run AUTO_LINES from C:, power off. Returns (log, data.img)."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", "-f", "bin", "-o", com, os.path.join(ROOT, "dosguest", "dg.asm"))
    boot = os.path.join(work, "boot.img")
    shutil.copy(getfreedos.IMG, boot)
    cfg, auto = os.path.join(work, "cfg"), os.path.join(work, "auto")
    with open(cfg, "wb") as f:
        f.write(b"SHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 /P=\\FDAUTO.BAT\r\n")
    with open(auto, "wb") as f:
        f.write(b"@echo off\r\nc:\r\n" + b"".join(l + b"\r\n" for l in auto_lines) +
                b"a:\\freedos\\bin\\fdapm poweroff\r\n")
    sh("mcopy", "-o", "-i", boot, cfg, "::FDCONFIG.SYS")
    sh("mcopy", "-o", "-i", boot, auto, "::FDAUTO.BAT")
    data = os.path.join(work, "data.img")
    sh("mformat", "-C", "-T", "16384", "-h", "16", "-s", "63", "-i", data, "::")
    sh("mcopy", "-o", "-i", data, com, "::DG.COM")
    for f in files:
        sh("mcopy", "-o", "-i", data, f, "::" + os.path.basename(f).upper())
    p = subprocess.run(
        ["qemu-system-i386", "-display", "none", "-no-reboot", "-m", "8",
         "-drive", "file=%s,format=raw,if=floppy" % boot,
         "-drive", "file=%s,format=raw,if=ide" % data, "-boot", "a"],
        timeout=secs, capture_output=True)
    check(p.returncode == 0, "the guest powered itself off (qemu exit %d)" % p.returncode)
    log = subprocess.run(["mtype", "-i", data, "::LOG.TXT"], capture_output=True)
    return log.stdout.decode("latin1"), data


def hmp(sock, *cmds):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "qmp.py"), sock, *cmds],
                       capture_output=True, text=True, cwd=ROOT)
    return r.stdout


def sym(*names):
    out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "os88sym.py"), *names],
                         capture_output=True, text=True, cwd=ROOT, check=True).stdout
    res = {}
    for line in out.strip().splitlines():
        f = line.split()
        if len(f) >= 4:
            res[f[0]] = int(f[3], 16)
    return res


def peek16(sock, lin):
    out = hmp(sock, "xp /1xh 0x%x" % lin)
    for line in out.splitlines():
        if ":" in line and "0x" in line.split(":", 1)[1]:
            return int(line.split(":", 1)[1].split()[0], 16)
    return None


def text_screen(sock, base=0xB8000, cols=80, rows=25):
    """The text screen as a list of strings, read out of video RAM."""
    out = hmp(sock, "xp /%dxb 0x%x" % (cols * rows * 2, base))
    b = bytearray()
    for line in out.splitlines():
        if ":" in line:
            b += bytes(int(x, 16) for x in line.split(":", 1)[1].split() if x.startswith("0x"))
    chars = b[0::2]
    return [bytes(chars[r * cols:(r + 1) * cols]).decode("latin1").rstrip() for r in range(rows)]


def run_boot(work, os_img, auto_lines=None, files=()):
    """Wave 2: `DG B:` with os8088 in B:, Restart by the mouse, DOS back."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", "-f", "bin", "-o", com, os.path.join(ROOT, "dosguest", "dg.asm"))
    boot = os.path.join(work, "boot.img")
    shutil.copy(getfreedos.IMG, boot)
    osd = os.path.join(work, "os8088.img")
    shutil.copy(os_img, osd)
    cfg, auto = os.path.join(work, "cfg"), os.path.join(work, "auto")
    with open(cfg, "wb") as f:
        f.write(b"SHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 /P=\\FDAUTO.BAT\r\n")
    # no poweroff: the harness reads the screen first. `dir` and `ver` after the
    # launcher prove DOS's file layer and its own state came back, not only RAM
    if auto_lines is None:
        auto_lines = [b"dg /k b: > c:\\log.txt"]
    with open(auto, "wb") as f:
        f.write(b"@echo off\r\nc:\r\n" + b"".join(l + b"\r\n" for l in auto_lines) +
                b"dir c:\\ > c:\\after.txt\r\nver >> c:\\after.txt\r\n"
                b"echo DOSGUEST-BACK\r\n")
    sh("mcopy", "-o", "-i", boot, cfg, "::FDCONFIG.SYS")
    sh("mcopy", "-o", "-i", boot, auto, "::FDAUTO.BAT")
    data = os.path.join(work, "data.img")
    sh("mformat", "-C", "-T", "16384", "-h", "16", "-s", "63", "-i", data, "::")
    sh("mcopy", "-o", "-i", data, com, "::DG.COM")
    for f in files:
        sh("mcopy", "-o", "-i", data, f, "::" + os.path.basename(f).upper())
    sock = os.path.join(work, "q.sock")
    q = subprocess.Popen(
        ["qemu-system-i386", "-display", "none", "-no-reboot", "-m", "8",
         "-drive", "file=%s,format=raw,if=floppy,index=0" % boot,
         "-drive", "file=%s,format=raw,if=floppy,index=1" % osd,
         "-drive", "file=%s,format=raw,if=ide" % data, "-boot", "a",
         "-chardev", "msmouse,id=m0", "-serial", "chardev:m0",
         "-qmp", "unix:%s,server,nowait" % sock],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    info = {}
    try:
        syms = sym("mem_top", "ticks")
        t0 = time.time()
        # os8088 is up when its mem_top is a plausible machine and a desktop is drawn
        while time.time() - t0 < 120:
            time.sleep(2)
            if not os.path.exists(sock):
                continue
            mt = peek16(sock, syms["mem_top"])
            # a whole number of KB, as the kernel makes it: DOS's own memory at
            # that address is garbage until os8088 has put its variable there
            if mt and 0x8000 <= mt <= 0xA000 and mt % 64 == 0:
                shot = os.path.join(work, "desk.png")
                m = re.search(r"(\d+(?:\.\d+)?)% non-white",
                              subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                                              sock, shot], capture_output=True, text=True,
                                             cwd=ROOT).stdout)
                # os8088's desktop is a dither, about half non-white; DOS's
                # black screen is ALL non-white to this counter, which is what
                # let an earlier version of this wait accept DOS
                if m and 20 < float(m.group(1)) < 80:
                    info["mem_top"] = mt
                    break
        check("mem_top" in info, "os8088 reached a desktop under DOS (mem_top %s)"
              % (hex(info["mem_top"]) if "mem_top" in info else "never read"))
        if "mem_top" not in info:
            return None, data, info
        tk = peek16(sock, syms["ticks"])
        time.sleep(3)
        tk2 = peek16(sock, syms["ticks"])
        check(tk is not None and tk2 is not None and tk != tk2,
              "os8088's own tick count is advancing (%s -> %s)" % (tk, tk2))
        # Restart: the System menu, then its item. Coordinates are the 640x480
        # VGA desktop's (a screenshot of the open menu put Restart at 30,108)
        mouse = [sys.executable, os.path.join(ROOT, "tools", "mouse.py"), "--screen", "640x480", sock]
        subprocess.run(mouse + ["down", "15", "9"], check=True, cwd=ROOT, capture_output=True)
        time.sleep(1)
        subprocess.run(mouse + ["to", "30", "108"], check=True, cwd=ROOT, capture_output=True)
        subprocess.run(mouse + ["up"], check=True, cwd=ROOT, capture_output=True)
        back = False
        for _ in range(40):
            time.sleep(2)
            scr = text_screen(sock)
            if any("DOSGUEST-BACK" in ln for ln in scr):
                back = True
                break
        info["screen"] = text_screen(sock)
        check(back, "Restart took os8088 out and DOS ran on (DOSGUEST-BACK on the screen)")
    finally:
        q.terminate()
        try:
            q.wait(10)
        except subprocess.TimeoutExpired:
            q.kill()
    return back, data, info


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

        # --- WAVE 2: os8088 itself ------------------------------------------
        os_img = os.path.join(ROOT, "build", "os8088.img")
        if not os.path.exists(os_img):
            print("  SKIP wave 2: no build/os8088.img (make)")
        else:
            print("wave 2: DG B: with os8088 in B:")
            w3 = tempfile.mkdtemp(prefix="dosguest-boot-")
            try:
                back, data2, info = run_boot(w3, os_img)
                r2 = read_result(data2) if back else None
                check(r2 is not None, "DG wrote its result after os8088 returned")
                if r2 is not None:
                    g = lambda k: int(r2[k], 16)
                    print("  guest: %s" % {k: v for k, v in r2.items() if k != "runs"})
                    check(r2.get("resumed") == "1" and g("bootmode") == 1, "DG resumed, in boot mode")
                    check(g("bootfail") == 0, "the boot sector loaded")
                    check(info["mem_top"] == g("size_kb") * 64,
                          "os8088 sized itself to the HIDDEN machine: mem_top %04X == %d KB * 64"
                          % (info["mem_top"], g("size_kb")))
                    check(((g("tick_at_return") - g("tick_at_boot")) & 0xFFFF) > 36,
                          "os8088 ran: the BIOS tick moved %d ticks"
                          % ((g("tick_at_return") - g("tick_at_boot")) & 0xFFFF))
                    check(g("mismatches") == 0,
                          "the pattern os8088 overwrote came back (0 mismatches over %d KB)"
                          % (g("pattern_paras") * 16 // 1024))
                    check(g("ivt_mismatches") == 0, "DOS's vectors came back (IVT)")
                    check(g("int12_after") == g("orig_kb"), "int 12h is the original size again")
                    scr = info["screen"]
                    check(any("FreeCom version" in ln for ln in scr),
                          "the DOS screen from BEFORE the launcher is back (FreeCom banner)")
                    after = subprocess.run(["mtype", "-i", data2, "::AFTER.TXT"], capture_output=True)
                    atxt = after.stdout.decode("latin1")
                    check("DG" in atxt and "DGSWAP" in atxt and "FreeCom" in atxt,
                          "DOS's file layer works after the resume (dir and ver ran)")
                    # the swap file is os8088-time evidence too: it must hold the pattern
                    img2 = open(data2, "rb").read()
                    v2 = dgfat.Volume(img2)
                    swap2 = v2.read(b"DGSWAP  IMG")
                    check(pattern_ok(swap2, g("pattern_seg"), g("pattern_paras")),
                          "the swap file holds the pattern (read off the disk after os8088 ran)")
            finally:
                shutil.rmtree(w3, ignore_errors=True)

        # --- TSRs ---------------------------------------------------------
        built = {}
        tw = tempfile.mkdtemp(prefix="dosguest-tsr-")
        try:
            for name, src, defs in (("tsrok", "tsrok.asm", ()), ("tsrq", "tsrq.asm", ()),
                                    ("tsrbad8", "tsrbad.asm", ()),
                                    ("tsrbad10", "tsrbad.asm", ("-DVEC=0x10",))):
                out = os.path.join(tw, name + ".com")
                sh("nasm", "-w+error", *defs, "-f", "bin", "-o", out,
                   os.path.join(ROOT, "tests", "dgtsr", src))
                built[name] = out
            print("TSRs the launcher must refuse:")
            for name, vec in (("tsrbad8", "INT 08"), ("tsrbad10", "INT 10")):
                wd = tempfile.mkdtemp(prefix="dosguest-bad-")
                try:
                    log, d = dos_session(wd, [name.encode() + b".com" if False else name.encode(),
                                              b"dg > c:\\log.txt", b"echo ALIVE > c:\\alive.txt"],
                                         files=[built[name]])
                    check(vec in log and "RAM, not ROM" in log,
                          "a plain hook on %s is refused, by name: %r" % (vec, log.strip()))
                    check(subprocess.run(["mtype", "-i", d, "::ALIVE.TXT"],
                                         capture_output=True).returncode == 0,
                          "and DOS carries on after the refusal")
                    check(subprocess.run(["mtype", "-i", d, "::DGSWAP.IMG"],
                                         capture_output=True).returncode != 0,
                          "and the launcher wrote nothing (no swap file)")
                finally:
                    shutil.rmtree(wd, ignore_errors=True)
            if os.path.exists(os_img):
                print("a TSR the launcher must carry through os8088:")
                wd = tempfile.mkdtemp(prefix="dosguest-tsrok-")
                try:
                    back, d, info = run_boot(
                        wd, os_img,
                        auto_lines=[b"tsrok", b"tsrq > c:\\q1.txt",
                                    b"dg /k b: > c:\\log.txt", b"tsrq > c:\\q2.txt"],
                        files=[built["tsrok"], built["tsrq"]])
                    r3 = read_result(d) if back else None
                    check(r3 is not None and r3.get("resumed") == "1",
                          "DG accepted a TSR hooking INT 09h (ISP), 1Ch and 60h and resumed")
                    if r3 is not None:
                        check(int(r3["mismatches"], 16) == 0 and int(r3["ivt_mismatches"], 16) == 0,
                              "memory and the IVT came back with the TSR resident")
                        q1 = subprocess.run(["mtype", "-i", d, "::Q1.TXT"], capture_output=True).stdout.decode().split()
                        q2 = subprocess.run(["mtype", "-i", d, "::Q2.TXT"], capture_output=True).stdout.decode().split()
                        print("  tsrq before: %s  after: %s" % (q1, q2))
                        check(len(q1) == 3 and int(q1[1], 16) > int(q1[0], 16),
                              "the TSR's INT 1Ch hook counts before the launcher")
                        check(len(q2) == 3 and int(q2[1], 16) > int(q2[0], 16),
                              "...and AFTER os8088 ran: the hook came back and is ticking")
                        check(len(q2) == 3 and int(q2[0], 16) >= int(q1[1], 16),
                              "its counter never went backwards (state restored, not rebuilt)")
                finally:
                    shutil.rmtree(wd, ignore_errors=True)
        finally:
            shutil.rmtree(tw, ignore_errors=True)

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
