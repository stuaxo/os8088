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
import hashlib
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


def pattern_ok(swap, seg, paras, image_bytes):
    """Does the swap file hold the pattern where the guest says it filled?

    Only the part INSIDE the image: the image is rounded down to 16KB, so the
    top of the pattern block can lie between the image's end and the hidden
    block. That memory is in neither the snapshot nor os8088's machine, which
    is why the guest's own verify passes over it and this must not look.
    """
    o = seg * 16
    n = min(paras * 16, image_bytes - o)
    return n > 0 and swap[o:o + n] == pattern_bytes(paras)[:n]


def sh(*a, **k):
    return subprocess.run(a, check=True, capture_output=True, **k)


class Host:
    """A DOS to boot: its floppy, and the names it reads its configuration under."""

    def __init__(self, name, img, cfg_name, shell, auto_name, poweroff, banner, ver, base_cfg=b""):
        self.banner, self.ver = banner, ver
        self.name, self.img, self.cfg_name = name, img, cfg_name
        self.shell, self.auto_name, self.poweroff, self.base_cfg = shell, auto_name, poweroff, base_cfg

    def boot_image(self, work, body, cfg_extra=(), power=True):
        """A copy of the floppy with OUR config and autoexec: BODY is the batch lines."""
        boot = os.path.join(work, "boot.img")
        shutil.copy(self.img, boot)
        cfg, auto = os.path.join(work, "cfg"), os.path.join(work, "auto")
        with open(cfg, "wb") as f:
            f.write(self.base_cfg + b"".join(l + b"\r\n" for l in cfg_extra) + self.shell + b"\r\n")
        with open(auto, "wb") as f:
            f.write(b"@echo off\r\nc:\r\n" + b"".join(l + b"\r\n" for l in body) +
                    (self.poweroff + b"\r\n" if power else b""))
        sh("mcopy", "-o", "-i", boot, cfg, "::" + self.cfg_name)
        sh("mcopy", "-o", "-i", boot, auto, "::" + self.auto_name)
        return boot


FREEDOS = Host("FreeDOS 1.4", getfreedos.IMG, "FDCONFIG.SYS",
               b"SHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 /P=\\FDAUTO.BAT",
               "FDAUTO.BAT", b"a:\\freedos\\bin\\fdapm poweroff", "FreeCom version", "FreeCom")
SVARDOS = Host("SvarDOS 20250427 (Enhanced DR-DOS kernel)", getfreedos.SVAR_IMG, "CONFIG.SYS",
               b"SHELL=COMMAND.COM /e:512 /p", "AUTOEXEC.BAT", b"a:\\fdapm poweroff", "Enhanced DR-DOS kernel", "DR-DOS",
               base_cfg=b"LASTDRIVE=Z\r\nFILES=30\r\nBUFFERS=20\r\n")
HOST = FREEDOS                        # the DOS the current pass is booting


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


BIG_START = 16777216                  # 8 GB in sectors: past the 1,024th cylinder
BIG_SECS = 204800                     # a 100 MB FAT16 partition


def make_big_disk(path):
    """A sparse 10 GB disk: an MBR and ONE FAT16 partition that starts at 8 GB.
    CHS cannot address it (cylinder 1,024 is 8 GB in), and the volume's own
    boot sector says it hides 16,777,216 sectors - which nothing else here does."""
    with open(path, "wb") as f:
        f.truncate(10 * 1024 ** 3)
        ent = bytearray(16)
        ent[0] = 0x80                                 # active
        ent[1:4] = bytes((0xFE, 0xFF, 0xFF))          # CHS: out of range, as LBA disks say
        ent[4] = 0x06                                 # FAT16 > 32 MB
        ent[5:8] = bytes((0xFE, 0xFF, 0xFF))
        ent[8:12] = BIG_START.to_bytes(4, "little")
        ent[12:16] = BIG_SECS.to_bytes(4, "little")
        f.seek(0x1BE)
        f.write(ent)
        f.seek(0x1FE)
        f.write(b"\x55\xAA")
    off = BIG_START * 512
    sh("mformat", "-i", "%s@@%d" % (path, off), "-T", str(BIG_SECS), "-h", "255", "-s", "63",
       "-H", str(BIG_START), "::")
    return off


def run_guest(work, ram_mb, defs=(), secs=120, flags=b"", big=False):
    """Boot FreeDOS with DG.COM on C:, return (result dict, data.img path)."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", *defs, "-f", "bin", "-o", com,
       os.path.join(ROOT, "dosguest", "dg.asm"))
    boot = HOST.boot_image(work, [b"dg /k " + flags + b" > c:\\log.txt"])
    data = os.path.join(work, "data.img")
    datai = data                      # what mtools' -i is given: the offset form for a big disk
    if big:
        datai = "%s@@%d" % (data, make_big_disk(data))
        sh("mcopy", "-o", "-i", datai, com, "::DG.COM")
    else:
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
        txt = subprocess.run(["mtype", "-i", datai, "::DGRESULT.TXT"], capture_output=True)
        return ("hung" if txt.returncode else "wrote"), datai
    res = {"runs": []}
    txt = subprocess.run(["mtype", "-i", datai, "::DGRESULT.TXT"],
                         capture_output=True)
    if txt.returncode:
        log = subprocess.run(["mtype", "-i", datai, "::LOG.TXT"], capture_output=True)
        print("  guest console: %r" % log.stdout.decode("latin1"))
        return None, datai
    for line in txt.stdout.decode("latin1").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "run":
            lba, n = v.split()
            res["runs"].append((int(lba, 16), int(n, 16)))
        else:
            res[k] = v
    return res, datai


def dos_session(work, auto_lines, files=(), secs=90, cfg_extra=()):
    """Boot FreeDOS, run AUTO_LINES from C:, power off. Returns (log, data.img)."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", "-f", "bin", "-o", com, os.path.join(ROOT, "dosguest", "dg.asm"))
    boot = HOST.boot_image(work, auto_lines, cfg_extra)
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


def text_screen(sock, cols=80, rows=50):
    """The text screen as a list of strings, read out of video RAM. Both text
    pages: a mono host (mode 7) is at B0000 and the rest at B8000."""
    lines = []
    for base in (0xB8000, 0xB0000):
        out = hmp(sock, "xp /%dxb 0x%x" % (cols * rows * 2, base))
        b = bytearray()
        for line in out.splitlines():
            if ":" in line:
                b += bytes(int(x, 16) for x in line.split(":", 1)[1].split() if x.startswith("0x"))
        chars = b[0::2]
        lines += [bytes(chars[r * cols:(r + 1) * cols]).decode("latin1").rstrip() for r in range(rows)]
    return lines


def run_boot(work, os_img, auto_lines=None, files=(), cfg_extra=(), during=None, hd2=None):
    """Wave 2: `DG B:` with os8088 in B:, Restart by the mouse, DOS back."""
    com = os.path.join(work, "DG.COM")
    sh("nasm", "-w+error", "-f", "bin", "-o", com, os.path.join(ROOT, "dosguest", "dg.asm"))
    osd = os.path.join(work, "os8088.img")
    shutil.copy(os_img, osd)
    # no poweroff: the harness reads the screen first. `dir` and `ver` after the
    # launcher prove DOS's file layer and its own state came back, not only RAM
    if auto_lines is None:
        auto_lines = [b"dg /k b: > c:\\log.txt"]
    boot = HOST.boot_image(work, auto_lines + [b"dir c:\\ > c:\\after.txt", b"ver >> c:\\after.txt",
                                               b"echo DOSGUEST-BACK"], cfg_extra, power=False)
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
         "-drive", "file=%s,format=raw,if=ide,index=0" % data]
        + (["-drive", "file=%s,format=raw,if=ide,index=1" % hd2] if hd2 else []) +
        ["-boot", "a",
         "-chardev", "msmouse,id=m0", "-serial", "chardev:m0",
         "-qmp", "unix:%s,server,nowait" % sock],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    info = {}
    try:
        syms = sym("mem_top", "ticks", "xm_row")
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
            if os.environ.get("DG_SHOT"):        # a picture of where it stopped
                subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"), sock,
                                os.environ["DG_SHOT"]], capture_output=True, cwd=ROOT)
                with open(os.environ["DG_SHOT"] + ".regs", "w") as f:
                    regs = hmp(sock, "info registers")
                    f.write(regs)
                    m = re.search(r"EIP=([0-9a-f]+).*?CS =([0-9a-f]+)", regs, re.S)
                    if m:
                        lin = int(m.group(2), 16) * 16 + int(m.group(1), 16)
                        f.write(hmp(sock, "x /24i 0x%x" % (lin - 24)))
                        f.write(hmp(sock, "xp /32xb 0x%x" % (lin - 16)))
                        for name, addr, n in (("stage2 start 98180", 0x98180, 32), ("kernel 600", 0x600, 32),
                                              ("top sector 9BE00", 0x9BE00, 48), ("BDA 413", 0x413, 4),
                                              ("IVT 0..0x80", 0, 128)):
                            f.write("== %s\n" % name)
                            f.write(hmp(sock, "xp /%dxb 0x%x" % (n, addr)))
            return None, data, info
        if during is not None:
            during(osd, data)            # while os8088 runs: the host changes a disk
        # XMEM.DRV's driver row: DRVR_SEG +2 (0 = not loaded), DRVR_KB +8, DRVR_WANT +13
        xr = syms["xm_row"]
        info["xmem"] = (peek16(sock, xr + 2), peek16(sock, xr + 8), (peek16(sock, xr + 12) or 0) >> 8)
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
        if not back and os.environ.get("DG_SHOT"):
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"), sock,
                            os.environ["DG_SHOT"]], capture_output=True, cwd=ROOT)
            with open(os.environ["DG_SHOT"] + ".regs", "w") as f:
                regs = hmp(sock, "info registers")
                f.write(regs)
                f.write("\n".join(l for l in info["screen"] if l.strip()))
    finally:
        q.terminate()
        try:
            q.wait(10)
        except subprocess.TimeoutExpired:
            q.kill()
    return back, data, info


def scenarios(host):
    """Everything, against one DOS."""
    work = tempfile.mkdtemp(prefix="dosguest-")
    try:
        res, data = run_guest(work, 8)
        check(res is not None, "the guest wrote \\DGRESULT.TXT")
        if res is None:
            return
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
        check(size == h("size_kb") * 1024 + 32768,
              "the swap file is the image plus the 32 KB video area (%d)" % size)
        swap = vol.read(b"DGSWAP  IMG")
        seg, paras = h("pattern_seg"), h("pattern_paras")
        check(pattern_ok(swap, seg, paras, h("size_kb") * 1024),
              "the swap file holds the pattern at %04X:0, %d paragraphs" % (seg, paras))
        bda = int.from_bytes(swap[0x413:0x415], "little")
        check(bda == h("orig_kb"),
              "the snapshot holds the ORIGINAL memory size (%d KB), not the lowered" % bda)
        v08 = int.from_bytes(swap[0x20:0x22], "little") | \
            int.from_bytes(swap[0x22:0x24], "little") << 16
        if host is FREEDOS:               # FreeDOS wraps INT 08h in RAM; the DR-DOS kernel leaves the ROM's
            check(v08 >> 16 < 0xC000,
                  "the snapshot holds DOS's INT 08h (%04X:%04X), not the clean one"
                  % (v08 >> 16, v08 & 0xFFFF))
        else:
            print("  note: this DOS leaves INT 08h in the ROM (%04X:%04X), so there is no hook to find"
                  % (v08 >> 16, v08 & 0xFFFF))

        # --- negative controls ---------------------------------------------
        bad = bytearray(swap)
        bad[seg * 16 + 1000] ^= 0x01
        check(not pattern_ok(bytes(bad), seg, paras, h("size_kb") * 1024),
              "NEGATIVE: one flipped bit in the pattern is refused")
        check(not pattern_ok(swap, seg + 1, paras, h("size_kb") * 1024),
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
                    ran = ((g("tick_at_return") - g("tick_at_boot")) & 0xFFFF) / 18.2065
                    dsec = g("dos_secs_after") - g("dos_secs_snap")
                    check(ran - 2 <= dsec <= ran + 30,
                          "DOS's clock moved on by the time os8088 ran: %d s against %.1f s of ticks"
                          % (dsec, ran))
                    check(g("mismatches") == 0,
                          "the pattern os8088 overwrote came back (0 mismatches over %d KB)"
                          % (g("pattern_paras") * 16 // 1024))
                    check(g("ivt_mismatches") == 0, "DOS's vectors came back (IVT)")
                    check(g("int12_after") == g("orig_kb"), "int 12h is the original size again")
                    scr = info["screen"]
                    check(any(host.banner in ln for ln in scr),
                          "the DOS screen from BEFORE the launcher is back (%r)" % host.banner)
                    after = subprocess.run(["mtype", "-i", data2, "::AFTER.TXT"], capture_output=True)
                    atxt = after.stdout.decode("latin1")
                    check("DG" in atxt and "DGSWAP" in atxt and host.ver in atxt,
                          "DOS's file layer works after the resume (dir and ver ran)")
                    # the swap file is os8088-time evidence too: it must hold the pattern
                    img2 = open(data2, "rb").read()
                    v2 = dgfat.Volume(img2)
                    swap2 = v2.read(b"DGSWAP  IMG")
                    check(pattern_ok(swap2, g("pattern_seg"), g("pattern_paras"), g("size_kb") * 1024),
                          "the swap file holds the pattern (read off the disk after os8088 ran)")
            finally:
                shutil.rmtree(w3, ignore_errors=True)

        # --- video: the DOS text state, brought back --------------------------
        if os.path.exists(os_img):
            vw = tempfile.mkdtemp(prefix="dosguest-vid-")
            try:
                progs = {}
                for name, src, defs in (("vidset", "vidset.asm", ()), ("vidgfx", "vidset.asm", ("-DGFX",)),
                                        ("vidq", "vidq.asm", ())):
                    out = os.path.join(vw, name + ".com")
                    sh("nasm", "-w+error", *defs, "-f", "bin", "-o", out,
                       os.path.join(ROOT, "tests", "dgtsr", src))
                    progs[name] = out
                print("video: 80x50, a custom font, a palette entry, the cursor, text on row 40")
                wd = tempfile.mkdtemp(prefix="dosguest-v1-")
                try:
                    back, d, info = run_boot(
                        wd, os_img,
                        auto_lines=[b"vidq > c:\\v0.txt", b"vidset", b"vidq > c:\\v1.txt",
                                    b"dg /k b: > c:\\log.txt", b"vidq > c:\\v2.txt"],
                        files=[progs["vidset"], progs["vidq"]])
                    v = {k: subprocess.run(["mtype", "-i", d, "::%s.TXT" % k.upper()],
                                           capture_output=True).stdout.decode().strip()
                         for k in ("v0", "v1", "v2")}
                    print("  default : %s\n  set up  : %s\n  after   : %s" % (v["v0"], v["v1"], v["v2"]))
                    check(v["v1"] != v["v0"] and v["v1"].startswith("03 31 08"),
                          "CONTROL: vidset really changed the state (80x50, 8-line font, a custom glyph)")
                    check(v["v2"] == v["v1"] and v["v2"] != "",
                          "after os8088 and Restart the video state is IDENTICAL: mode, rows, "
                          "font height, cursor, palette, the custom glyph, the row-40 text")
                finally:
                    shutil.rmtree(wd, ignore_errors=True)
                print("video: a host in a graphics mode comes back in text")
                wd = tempfile.mkdtemp(prefix="dosguest-v2-")
                try:
                    back, d, info = run_boot(
                        wd, os_img,
                        auto_lines=[b"vidgfx", b"dg /k b: > c:\\log.txt", b"vidq > c:\\v3.txt"],
                        files=[progs["vidgfx"], progs["vidq"]])
                    v3 = subprocess.run(["mtype", "-i", d, "::V3.TXT"], capture_output=True).stdout.decode().strip()
                    print("  after   : %s" % v3)
                    check(v3.startswith("03 "), "a graphics-mode host comes back in 80x25 text (mode 03)")
                finally:
                    shutil.rmtree(wd, ignore_errors=True)
            finally:
                shutil.rmtree(vw, ignore_errors=True)

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

        # --- os8088 installed on a HARD DISK ----------------------------------
        # An os8088 hard-disk install is booted through its volume boot record
        # (boot/boothd.asm), which takes DL and its own BPB. DOS calls the volume
        # D:, so the launcher finds its BIOS unit and partition start by content.
        # And the disk is handed to os8088 write-protected, so the image must be
        # byte-for-byte unchanged afterwards.
        need = [os.path.join(ROOT, "build", f) for f in ("kernel.sys", "boothd.bin", "mbr.bin")]
        if all(os.path.exists(n) for n in need) and os.path.exists(os_img):
            hw = tempfile.mkdtemp(prefix="dosguest-hd-")
            try:
                hdimg = os.path.join(hw, "os8088hd.img")
                sh(sys.executable, os.path.join(ROOT, "tools", "os88hdd.py"), "--raw", "--spt", "63",
                   "--heads", "16", "--cyls", "65", "--kernel", need[0], "--vbr", need[1], "--mbr", need[2],
                   "--out", hdimg)
                before = hashlib.sha256(open(hdimg, "rb").read()).hexdigest()
                print("os8088 on a hard disk: DG D: (a second IDE disk, DOS's D:)")
                back, d, info = run_boot(hw, os_img, auto_lines=[b"dg /k d: > c:\\log.txt"], hd2=hdimg)
                rh = read_result(d) if back else None
                check(rh is not None and rh.get("resumed") == "1" and int(rh["bootfail"], 16) == 0,
                      "DG found D:, booted os8088 from its volume boot record, and DOS came back")
                if rh is not None:
                    check(int(rh["boot_unit"], 16) == 0x81 and int(rh["tick_at_return"], 16) != int(rh["tick_at_boot"], 16),
                          "os8088 ran from BIOS unit %s" % rh["boot_unit"])
                    check(int(rh["mismatches"], 16) == 0 and int(rh["ivt_mismatches"], 16) == 0,
                          "memory and the IVT came back")
                after = hashlib.sha256(open(hdimg, "rb").read()).hexdigest()
                check(after == before, "the os8088 disk is byte-for-byte unchanged: os8088 could not write it")
            finally:
                shutil.rmtree(hw, ignore_errors=True)

        # --- a disk the old addressing cannot reach ----------------------------
        # A partition that starts 8 GB into a 10 GB disk: past the 1,024th cylinder,
        # so CHS cannot name it, and the volume hides 16,777,216 sectors. The launcher
        # uses the BIOS's extended calls when it can; /C is the control that cannot.
        for flags, works, what in ((b"", True, "the swap file on a partition 8 GB into the disk (extended INT 13h)"),
                                   (b"/c", False, "CONTROL: with CHS only the same disk cannot be reached")):
            wd = tempfile.mkdtemp(prefix="dosguest-big-")
            try:
                rb, db = run_guest(wd, 8, flags=flags, big=True, secs=60 if works else 40)
                if works:
                    check(isinstance(rb, dict), what)
                    if isinstance(rb, dict):
                        g2 = lambda k: int(rb[k], 16)
                        check(g2("mismatches") == 0 and g2("ivt_mismatches") == 0 and rb.get("resumed") == "1",
                              "...and DOS came back from it")
                        check(g2("hidden_sectors") == BIG_START and g2("edd") == 1,
                              "...the volume hides %d sectors and the launcher used the extended calls"
                              % g2("hidden_sectors"))
                        part = open(db.split("@@")[0], "rb")
                        part.seek(BIG_START * 512)
                        vol = dgfat.Volume(part.read(BIG_SECS * 512))
                        part.close()
                        runs, size = vol.extents(b"DGSWAP  IMG")
                        check([(l + BIG_START, n) for l, n in runs] == rb["runs"],
                              "dgfat.py finds the guest's extents, which are past LBA %d" % BIG_START)
                else:
                    check(rb in ("hung", None) or (isinstance(rb, dict) and rb.get("resumed") != "1"),
                          what + " (%s)" % (rb if not isinstance(rb, dict) else "ran"))
            finally:
                shutil.rmtree(wd, ignore_errors=True)

        # --- DOS 3.0 to 3.30: INT 25h's classic form ----------------------------
        # No DOS 3.x is here to run it on, so this proves the PATH and not that DOS.
        wd = tempfile.mkdtemp(prefix="dosguest-cls-")
        try:
            rc, dc = run_guest(wd, 8, flags=b"/3")
            check(isinstance(rc, dict) and rc.get("resumed") == "1" and int(rc["mismatches"], 16) == 0,
                  "the classic INT 25h path (as DOS 3.30 has) finds the volume and the round trip works")
        finally:
            shutil.rmtree(wd, ignore_errors=True)

        # --- os8088 may not write what DOS can see ----------------------------
        # os8088 reaches its disks through INT 13h, and the launcher hands it one
        # that refuses writes. The test goes through the LIVE vector with the
        # extended write, at a sector of the swap file's video area that nothing
        # uses, so a write that gets through is harmless and shows on the host.
        for flags, blocked, what in ((b"/f", True, "by default a write through os8088's INT 13h is REFUSED (write protected)"),
                                     (b"/f /w", True, "a bare /W allows the os8088 boot floppy only: a hard-disk write is still refused"),
                                     (b"/f /wh", False, "/WH allows hard disks: the same write goes through"),
                                     (b"/f /w*", False, "CONTROL: with /W* the same write goes through")):
            wd = tempfile.mkdtemp(prefix="dosguest-wp-")
            try:
                rw_, dw_ = run_guest(wd, 8, flags=flags)
                if rw_ is None:
                    check(False, what)
                    continue
                ah_cf_mask = rw_["wtest_ah_cf_wmask"]
                ah, cf = int(ah_cf_mask[0:2], 16), int(ah_cf_mask[2:4], 16)
                vol = dgfat.Volume(open(dw_, "rb").read())
                swp = vol.read(b"DGSWAP  IMG")
                off = (int(rw_["size_kb"], 16) * 2 + 40) * 512
                landed = swp[off:off + 4] == b"GDGD"
                if blocked:
                    check(cf == 1 and ah == 3 and not landed,
                          "%s (AH=%02X CF=%d, and the sector %s)" % (what, ah, cf, "was written" if landed else "is untouched"))
                else:
                    check(cf == 0 and landed, "%s (CF=%d, and the sector %s)" % (what, cf, "holds the marker" if landed else "is NOT written"))
            finally:
                shutil.rmtree(wd, ignore_errors=True)

        # --- every video mode a DOS can be in -----------------------------------
        # Text modes (0 to 3, 7) come back as themselves, marker and all; a
        # graphics mode cannot be restored and the host must come back in 80x25
        # TEXT - not in a graphics mode with nothing on it, and not in some
        # third thing. Mode 3 and the 80x50 font case are covered above.
        if os.path.exists(os_img):
            mw = tempfile.mkdtemp(prefix="dosguest-modes-")
            try:
                vm, vq = os.path.join(mw, "vidmode.com"), os.path.join(mw, "vidq.com")
                for nm, out in (("vidmode", vm), ("vidq", vq)):
                    sh("nasm", "-w+error", "-f", "bin", "-o", out,
                       os.path.join(ROOT, "tests", "dgtsr", nm + ".asm"))
                print("video modes: text modes return as themselves, graphics modes as 80x25 text")
                for mode, kind in (("0", "40x25 grey-scale text"), ("1", "40x25 text"), ("2", "80x25 grey-scale text"),
                                   ("7", "MDA-style mono text (B000)"),
                                   ("4", "CGA 320x200 graphics"), ("D", "EGA 320x200 graphics"),
                                   ("12", "VGA 640x480 graphics"), ("13", "VGA 320x200x256")):
                    wd = tempfile.mkdtemp(prefix="dosguest-mode-")
                    try:
                        back, d, info = run_boot(
                            wd, os_img,
                            auto_lines=[b"vidmode " + mode.encode(), b"vidq > c:\\v1.txt",
                                        b"dg /k b: > c:\\log.txt", b"vidq > c:\\v2.txt"],
                            files=[vm, vq])
                        t = lambda f: subprocess.run(["mtype", "-i", d, "::" + f],
                                                     capture_output=True).stdout.decode("latin1").strip()
                        v1, v2 = t("V1.TXT"), t("V2.TXT")
                        text = int(mode, 16) <= 3 or int(mode, 16) == 7
                        pre = "%02X" % int(mode, 16)
                        check(bool(back) and v1.startswith(pre),
                              "CONTROL: vidmode really set mode %s (%s): %r" % (mode, kind, v1[:2]))
                        if text:
                            check(v2 == v1 and v2.endswith("MODEMARK"),
                                  "mode %s (%s) comes back as itself, line and marker identical" % (mode, kind))
                        else:
                            check(v2.startswith("03 "),
                                  "mode %s (%s) is not restorable: the host comes back in mode 03 (%r)"
                                  % (mode, kind, v2[:2]))
                    finally:
                        shutil.rmtree(wd, ignore_errors=True)
            finally:
                shutil.rmtree(mw, ignore_errors=True)

        # --- A20: forced on for os8088, DOS's own state put back --------------
        if os.path.exists(os_img):
            aw = tempfile.mkdtemp(prefix="dosguest-a20-")
            try:
                progs = {}
                for nm in ("a20q", "a20off"):
                    out = os.path.join(aw, nm + ".com")
                    sh("nasm", "-w+error", "-f", "bin", "-o", out,
                       os.path.join(ROOT, "tests", "dgtsr", nm + ".asm"))
                    progs[nm] = out
                print("A20: the way os8088 leaves it is not DOS's problem")
                dg_a, dg_az = b"dg /k /a b: > c:\\log.txt", b"dg /k /a /z b: > c:\\log.txt"
                for what, lines, want_probe, want_rep in (
                        ("on at DOS; the return leaves it OFF; the launcher puts it back",
                         [b"a20q > c:\\a0.txt", dg_a, b"a20q > c:\\a1.txt"], ("1", "1"), "010101"),
                        ("CONTROL: the same with the restore skipped leaves DOS with A20 OFF",
                         [b"a20q > c:\\a0.txt", dg_az, b"a20q > c:\\a1.txt"], ("1", "0"), "010100"),
                        ("OFF at DOS: os8088 still boots (A20 forced on) and DOS gets it OFF again",
                         [b"a20off", b"a20q > c:\\a0.txt", b"dg /k b: > c:\\log.txt", b"a20q > c:\\a1.txt"],
                         ("0", "0"), "000100")):
                    wd = tempfile.mkdtemp(prefix="dosguest-a20r-")
                    try:
                        back, d, info = run_boot(wd, os_img, auto_lines=lines,
                                                 files=[progs["a20q"], progs["a20off"]])
                        t = lambda f: subprocess.run(["mtype", "-i", d, "::" + f],
                                                     capture_output=True).stdout.decode().strip()
                        r5 = read_result(d) if back else None
                        got = (t("A0.TXT"), t("A1.TXT"))
                        check(bool(back) and r5 is not None and got == want_probe
                              and r5.get("a20_dos_boot_final") == want_rep,
                              "%s (probe %s, guest %s)" % (what, got,
                                                          r5.get("a20_dos_boot_final") if r5 else None))
                    finally:
                        shutil.rmtree(wd, ignore_errors=True)
            finally:
                shutil.rmtree(aw, ignore_errors=True)

        # --- the disk changes while os8088 runs ------------------------------
        # Whoever writes the volume, DOS cannot tell: here the HOST adds a file to
        # C: while os8088 runs, which is what os8088 writing there looks like from
        # DOS's side. Without /P the launcher's own disk reset has already emptied
        # FreeDOS's cache and there is nothing stale to find; /P re-populates the
        # directory cache before the snapshot (the state an MS-DOS host is in), and
        # /N then leaves out the invalidation after the resume.
        if os.path.exists(os_img):
            print("the disk changes while os8088 runs (a file added to C: by the host):")
            for flags, expect, what in ((b"/p /n", False, "CONTROL, primed cache and no invalidation: DOS cannot see it"),
                                        (b"/p", True, "primed cache, disk reset after the resume: DOS sees it")):
                ww = tempfile.mkdtemp(prefix="dosguest-wr-")
                try:
                    hostfile = os.path.join(ww, "HOSTC.TXT")
                    with open(hostfile, "w") as hf:
                        hf.write("written by the host to C: while os8088 ran\r\n")

                    def during(osd, data, hostfile=hostfile):
                        subprocess.run(["mcopy", "-o", "-i", data, hostfile, "::HOSTC.TXT"], check=True)
                    back, d, info = run_boot(
                        ww, os_img,
                        auto_lines=[b"dg /k " + flags + b" b: > c:\\log.txt", b"dir c:\\ > c:\\h1.txt",
                                    b"type c:\\hostc.txt > c:\\h2.txt"],
                        during=during)
                    t = lambda f: subprocess.run(["mtype", "-i", d, "::" + f], capture_output=True).stdout.decode("latin1")
                    seen = "HOSTC" in t("H1.TXT") and "written by the host" in t("H2.TXT")
                    check(bool(back) and seen == expect, "%s" % what)
                finally:
                    shutil.rmtree(ww, ignore_errors=True)

        # --- REAL DRIVERS, from the FreeDOS repository ---------------------
        # A toy TSR proves what its author thought of. These are somebody else's.
        if host is not FREEDOS:
            print("  SKIP real drivers: the packages are FreeDOS's")
        elif not getfreedos.have_pkgs():
            print("  SKIP real drivers: python3 tools/getfreedos.py --pkgs")
        else:
            pk = lambda n, m: getfreedos.pkg_path(n, m)
            HM, CT = pk("himemx", "BIN/HimemX.exe"), pk("ctmouse", "BIN/CTMOUSE.EXE")
            aw = tempfile.mkdtemp(prefix="dosguest-drv-")
            try:
                dq = os.path.join(aw, "drvq.com")
                sh("nasm", "-w+error", "-f", "bin", "-o", dq, os.path.join(ROOT, "tests", "dgtsr", "drvq.asm"))
                aq = os.path.join(aw, "a20q.com")
                sh("nasm", "-w+error", "-f", "bin", "-o", aq, os.path.join(ROOT, "tests", "dgtsr", "a20q.asm"))
                xq = os.path.join(aw, "xmsq.com")
                sh("nasm", "-w+error", "-f", "bin", "-o", xq, os.path.join(ROOT, "tests", "dgtsr", "xmsq.asm"))
                # the manager's answers with NO launcher at all: what "happy" is
                wd0 = tempfile.mkdtemp(prefix="dosguest-xref-")
                try:
                    _, dref = dos_session(wd0, [b"xmsq f > c:\\x0.txt", b"xmsq c > c:\\x1.txt"],
                                          files=[xq, HM], cfg_extra=[b"DEVICE=C:\\HIMEMX.EXE"])
                    xref = subprocess.run(["mtype", "-i", dref, "::X1.TXT"], capture_output=True).stdout.decode()
                finally:
                    shutil.rmtree(wd0, ignore_errors=True)
                print("  XMS manager with no launcher: %r" % xref)
                if os.path.exists(os_img):
                    print("real drivers through os8088: HIMEMX (XMS, hooks INT 15h) and CTMOUSE (hooks INT 10h)")
                    wd = tempfile.mkdtemp(prefix="dosguest-real-")
                    try:
                        back, d, info = run_boot(
                            wd, os_img,
                            auto_lines=[b"ctmouse", b"xmsq f > c:\\xf.txt",
                                        b"drvq > c:\\d0.txt", b"a20q > c:\\a0.txt",
                                        b"dg /k b: > c:\\log.txt",
                                        b"drvq > c:\\d1.txt", b"a20q > c:\\a1.txt",
                                        b"xmsq c > c:\\x2.txt"],
                            files=[CT, HM, dq, aq, xq], cfg_extra=[b"DEVICE=C:\\HIMEMX.EXE"])
                        rr = read_result(d) if back else None
                        check(rr is not None and rr.get("resumed") == "1",
                              "DG accepted HIMEMX and CTMOUSE, booted os8088 and resumed")
                        if rr is not None:
                            g = lambda k: int(rr[k], 16)
                            t = lambda f: subprocess.run(["mtype", "-i", d, "::" + f],
                                                         capture_output=True).stdout.decode().strip()
                            d0, d1, a0, a1 = t("D0.TXT"), t("D1.TXT"), t("A0.TXT"), t("A1.TXT")
                            print("  drivers before: %s   after: %s   A20: %s -> %s" % (d0, d1, a0, a1))
                            check(d0.startswith("80 0300") and d0.endswith("FFFF"),
                                  "CONTROL: the probe sees an XMS 3.00 driver and a mouse driver (%s)" % d0)
                            check(d1 == d0, "XMS (version, free memory, A20) and the mouse driver are "
                                  "the same after os8088: nothing the image does not cover was lost")
                            check(a0 == "1" and a1 == "1", "A20 is on before and after")
                            check(info.get("xmem") == (0, 0, 0),
                                  "os8088 was shown NO extended memory: XMEM.DRV is not wanted and not loaded "
                                  "(its row: %s)" % (info.get("xmem"),))
                            x2 = t("X2.TXT").replace("\r", "")
                            check(x2.replace("\n", " ").startswith("XMSDATA=0000"),
                                  "the 512 KB XMS block filled before os8088 ran holds its pattern after: %r"
                                  % x2.split("\n")[0])
                            check(x2.strip() == xref.replace("\r", "").strip(),
                                  "the manager still allocates and frees, hands out the HMA, and drives A20 "
                                  "exactly as it does with no launcher: %r" % x2.replace("\n", " "))
                            check(g("heuristic_unwraps") >= 2,
                                  "the INT 15h and INT 10h hooks were unwrapped by the scan (%d)" % g("heuristic_unwraps"))
                            check(g("mismatches") == 0 and g("ivt_mismatches") == 0,
                                  "memory and the IVT came back with both resident")
                    finally:
                        shutil.rmtree(wd, ignore_errors=True)
                if os.path.exists(os_img):
                    print("CONTROL: with the INT 15h filter off (/X), os8088 loads XMEM.DRV on top of the XMS manager")
                    wd = tempfile.mkdtemp(prefix="dosguest-x-")
                    try:
                        back, d, info = run_boot(wd, os_img, auto_lines=[b"dg /k /x b: > c:\\log.txt"],
                                                 files=[HM], cfg_extra=[b"DEVICE=C:\\HIMEMX.EXE"])
                        xm = info.get("xmem")
                        check(bool(xm) and xm[0] != 0 and xm[2] == 1,
                              "CONTROL: without the filter XMEM.DRV is wanted and resident (row %s)" % (xm,))
                    finally:
                        shutil.rmtree(wd, ignore_errors=True)
                print("real drivers that must be accepted (the launcher alone):")
                for name, files, cfg, lines in (
                        ("SHARE", [pk("share", "BIN/SHARE.COM")], (), [b"share"]),
                        ("NANSI.SYS", [pk("nansi", "BIN/NANSI.SYS")], (b"DEVICE=C:\\NANSI.SYS",), []),
                        ("KEYB", [pk("keyb", "BIN/KEYB.EXE")], (), [b"keyb us"]),
                        ("LBACACHE on XMS", [HM, pk("lbacache", "BIN/LBACACHE.COM")],
                         (b"DEVICE=C:\\HIMEMX.EXE",), [b"lbacache"])):
                    wd = tempfile.mkdtemp(prefix="dosguest-acc-")
                    try:
                        log, d = dos_session(wd, lines + [b"dg /k > c:\\log.txt"], files=files, cfg_extra=cfg)
                        ra = read_result(d)
                        check(ra is not None and ra.get("resumed") == "1" and int(ra["mismatches"], 16) == 0,
                              "%s is accepted and DOS comes back" % name)
                    finally:
                        shutil.rmtree(wd, ignore_errors=True)
                print("a memory manager that puts DOS in virtual-8086 mode must be refused:")
                wd = tempfile.mkdtemp(prefix="dosguest-v86-")
                try:
                    log, d = dos_session(wd, [b"dg > c:\\log.txt", b"echo ALIVE > c:\\alive.txt"],
                                         files=[HM, pk("jemm", "BIN/JEMM386.EXE")],
                                         cfg_extra=(b"DEVICE=C:\\HIMEMX.EXE", b"DEVICE=C:\\JEMM386.EXE"))
                    check("virtual-8086" in log, "JEMM386 is refused as V86: %r" % log.strip()[:60])
                    check(subprocess.run(["mtype", "-i", d, "::ALIVE.TXT"], capture_output=True).returncode == 0
                          and subprocess.run(["mtype", "-i", d, "::DGSWAP.IMG"], capture_output=True).returncode != 0,
                          "and DOS carries on with nothing written")
                finally:
                    shutil.rmtree(wd, ignore_errors=True)
            finally:
                shutil.rmtree(aw, ignore_errors=True)

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


def main():
    global HOST
    for tool in ("nasm", "qemu-system-i386", "mcopy", "mformat", "mtype"):
        if not shutil.which(tool):
            print("dosguest: SKIP, no %s" % tool)
            return 0
    hosts = [h for h, ok in ((FREEDOS, getfreedos.have()), (SVARDOS, getfreedos.have_svardos())) if ok]
    if not hosts:
        print("dosguest: SKIP, no DOS (python3 tools/getfreedos.py)")
        return 0
    if SVARDOS not in hosts:
        print("  SKIP SvarDOS: python3 tools/getfreedos.py --svardos")
    dgfat.selfcheck()
    for h in hosts:
        HOST = h
        print("=" * 72 + "\nDOS host: %s\n" % h.name + "=" * 72)
        scenarios(h)
    print("dosguest: %s" % ("FAIL (%d)" % len(FAILS) if FAILS else "ok"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
