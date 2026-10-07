#!/usr/bin/env python3
"""dosguest_demo: a directory a browser can open - DOS, with os8088 started FROM it.

    python3 tools/dosguest_demo.py                 # build build/dosguest-demo/
    python3 tools/dosguest_demo.py --serve [PORT]  # ...and serve it (default 8087)
    python3 tools/dosguest_demo.py --qemu          # ...and open it in a QEMU window
    python3 tools/dosguest_demo.py --qemu --display none   # (headless; what the check uses)

FreeDOS boots in v86 and leaves you at its prompt. Type

    DG B:

and os8088 takes the machine over, with the VMware absolute pointer (kern_emu's
VMMOUSE.DRV), so the mouse needs no grab. System menu > Restart returns to DOS,
with its screen, its clock, its drivers and its memory as they were.

It needs `make emu` (build/emu.img), `make dosguest` is built here, FreeDOS's boot
floppy (tools/getfreedos.py) and a v86 build (V86_DIR, default ../../v86): the
page loads libv86.js, v86.wasm, SeaBIOS and the VGA BIOS, which are COPIED into the
directory. Nothing in it is committed: build/ is ignored.

NOT OPENED IN A BROWSER by whoever wrote it. tests/dosguest.py runs the same disks
in v86 under node (the whole round trip, Restart included); what the page adds over
that is the DOM glue, which is the starter's own and the example pages'.

Licences travel with what is copied: FreeDOS (GPL and others), v86 (BSD-2-Clause),
SeaBIOS and SeaVGABIOS (LGPLv3).
"""
import http.server
import os
import shutil
import socketserver
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import getfreedos  # noqa: E402

OUT = os.path.join(ROOT, "build", "dosguest-demo")
V86 = os.environ.get("V86_DIR") or os.path.abspath(os.path.join(ROOT, "..", "..", "v86"))

HTML = """<!doctype html>
<meta charset="utf-8">
<title>os8088 started from DOS</title>
<style>
  body { font: 15px system-ui, sans-serif; margin: 1.5em; background: #fafaf7; color: #222; max-width: 52em; }
  #screen_container { margin: 1em 0; border: 1px solid #ccc; width: max-content; background: #000; }
  #screen_container canvas { display: block; }
  code, kbd { background: #eee; border: 1px solid #ccc; border-radius: 3px; padding: 0 4px; }
  .hint { color: #555; }
</style>
<h2>os8088, started from DOS</h2>
<p>This is <b>FreeDOS</b> in <a href="https://github.com/copy/v86">v86</a>. Click the screen, wait for the
prompt, and type <kbd>DG B:</kbd> then <kbd>Enter</kbd>. os8088 takes the machine over and the
pointer is <b>absolute</b>: no grab, the arrow follows the mouse. Choose <b>System &rsaquo; Restart</b>
(the logo at the top left) to go back to DOS.</p>
<p class="hint">While os8088 runs, DOS is on a file on the C: drive of this virtual machine, with the
bit of memory os8088 may not touch hidden from it. When you Restart, the file is read back: the
screen, the clock, the drivers and every byte of memory are as you left them.
Files on A: and C: are refused to os8088 (it is write-protected on purpose).</p>
<div id="screen_container">
  <div style="white-space: pre; font: 14px monospace; line-height: 14px"></div>
  <canvas style="display: none"></canvas>
</div>
<script src="libv86.js"></script>
<script>
"use strict";
window.onload = function() {
    window.emulator = new V86({
        wasm_path: "v86.wasm",
        bios: { url: "seabios.bin" },
        vga_bios: { url: "vgabios.bin" },
        fda: { url: "boot.img" },
        fdb: { url: "os8088.img" },
        hda: { url: "hda.img" },
        boot_order: 0x321,          // v86: 1 = CD, 2 = hard disk, 3 = floppy, FIRST digit first
        memory_size: 32 * 1024 * 1024,
        vga_memory_size: 2 * 1024 * 1024,
        screen_container: document.getElementById("screen_container"),
        autostart: true,
    });
};
</script>
"""


def qemu_args(display="gtk", qmp=None):
    """QEMU on the demo's disks. os8088 here is the STANDARD kernel (build/os8088.img) with
    QEMU's serial mouse - the pair every test in tests/dosguest.py drives - not the emu
    kernel's absolute pointer, which is what v86 is for. The serial mouse is RELATIVE: click
    the window to GRAB it (Ctrl+Alt+G lets go)."""
    std = os.path.join(ROOT, "build", "os8088.img")
    if not os.path.exists(std):
        sys.exit("dosguest_demo: no build/os8088.img - run make")
    shutil.copy(std, os.path.join(OUT, "os8088-std.img"))
    a = ["qemu-system-i386", "-m", "8", "-boot", "a", "-display", display, "-no-reboot",
         "-drive", "file=%s,format=raw,if=floppy,index=0" % os.path.join(OUT, "boot.img"),
         "-drive", "file=%s,format=raw,if=floppy,index=1" % os.path.join(OUT, "os8088-std.img"),
         "-drive", "file=%s,format=raw,if=ide" % os.path.join(OUT, "hda.img"),
         "-chardev", "msmouse,id=m0", "-serial", "chardev:m0"]
    if qmp:
        a += ["-qmp", "unix:%s,server,nowait" % qmp]
    return a


def run_qemu():
    disp = "gtk"
    if "--display" in sys.argv:
        disp = sys.argv[sys.argv.index("--display") + 1]
    print("dosguest_demo: QEMU. At the FreeDOS prompt type  DG B:  and Enter.")
    print("dosguest_demo: click the window to grab the mouse (Ctrl+Alt+G releases it);")
    print("dosguest_demo: in os8088, System menu (the logo, top left) > Restart returns to DOS.")
    os.execvp("qemu-system-i386", qemu_args(disp))


def main():
    emu = os.path.join(ROOT, "build", "emu.img")
    for need, how in ((emu, "make emu"), (getfreedos.IMG, "python3 tools/getfreedos.py"),
                      (os.path.join(V86, "build", "libv86.js"), "a v86 build (V86_DIR)")):
        if not os.path.exists(need):
            sys.exit("dosguest_demo: missing %s - %s" % (need, how))
    os.makedirs(OUT, exist_ok=True)
    subprocess.run(["make", "build/DG.COM"], cwd=ROOT, check=True, capture_output=True)
    for src, dst in ((os.path.join(V86, "build", "libv86.js"), "libv86.js"),
                     (os.path.join(V86, "build", "v86.wasm"), "v86.wasm"),
                     (os.path.join(V86, "bios", "seabios.bin"), "seabios.bin"),
                     (os.path.join(V86, "bios", "vgabios.bin"), "vgabios.bin"),
                     (emu, "os8088.img")):
        shutil.copy(src, os.path.join(OUT, dst))
    # FreeDOS's floppy, with a prompt that says what to type and nothing else
    boot = os.path.join(OUT, "boot.img")
    shutil.copy(getfreedos.IMG, boot)
    cfg, auto = os.path.join(OUT, "cfg.tmp"), os.path.join(OUT, "auto.tmp")
    with open(cfg, "wb") as f:
        f.write(b"SHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 /P=\\FDAUTO.BAT\r\n")
    with open(auto, "wb") as f:
        f.write(b"@echo off\r\nPATH=A:\\FREEDOS\\BIN;C:\\\r\nC:\r\n"
                b"echo.\r\necho  FreeDOS. Type  DG B:  to start os8088 from here.\r\n"
                b"echo  (System menu, then Restart, brings you back.)\r\necho.\r\n")
    for dst, src in (("FDCONFIG.SYS", cfg), ("FDAUTO.BAT", auto)):
        subprocess.run(["mcopy", "-o", "-i", boot, src, "::" + dst], check=True)
    os.unlink(cfg)
    os.unlink(auto)
    hda = os.path.join(OUT, "hda.img")
    if os.path.exists(hda):
        os.unlink(hda)
    subprocess.run(["mformat", "-C", "-T", "16384", "-h", "16", "-s", "63", "-i", hda, "::"], check=True)
    subprocess.run(["mcopy", "-o", "-i", hda, os.path.join(ROOT, "build", "DG.COM"), "::DG.COM"], check=True)
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(HTML)
    print("dosguest_demo: %s" % OUT)
    if "--qemu" in sys.argv:
        return run_qemu()
    if "--serve" in sys.argv:
        i = sys.argv.index("--serve")
        port = int(sys.argv[i + 1]) if len(sys.argv) > i + 1 and sys.argv[i + 1].isdigit() else 8087
        os.chdir(OUT)
        socketserver.TCPServer.allow_reuse_address = True
        print("dosguest_demo: http://localhost:%d/" % port)
        with socketserver.TCPServer(("", port), http.server.SimpleHTTPRequestHandler) as httpd:
            httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
