#!/usr/bin/env python3
"""getfreedos: fetch the FreeDOS 1.4 boot floppy that the dosguest rows boot.

    python3 tools/getfreedos.py              # fetch + verify + extract the boot floppy
    python3 tools/getfreedos.py --pkgs       # ...and the real drivers tests/dosguest.py loads
    python3 tools/getfreedos.py --svardos    # ...and SvarDOS, a second DOS (Enhanced DR-DOS kernel)
    python3 tools/getfreedos.py --check      # verify what is there, never fetch

**Nothing this script downloads is committed.** FreeDOS is somebody else's
work under its own licences, and a git repository is not a distribution
channel for it: the bytes land in build/freedos/, which is ignored (build/
is), and tests/dosguest.py builds its disks from there.

It exists because docs/plans/DOSGUEST-PLAN.md has to be tested against a
REAL DOS, and none is in this repository and none can be. FreeDOS is the one
that can be fetched by anybody, which is why it is the first host and not the
only one (the plan, section 11, wants a second).

--pkgs fetches a handful of real FreeDOS packages (an XMS driver, a mouse driver,
a keyboard driver, an ANSI driver, a disk cache, SHARE and JEMM386), each at a
pinned SHA-256, from the FreeDOS repository. They are what a launcher has to
survive on a real DOS: toy TSRs only prove what their author thought of.

What is kept of the boot floppy is ONE file out of a 22MB archive: the 1.44MB boot floppy, which
carries the kernel, COMMAND.COM and FDAPM (the way the test powers the guest
off). The archive is unpacked into a directory of its own and never run:
everything in it is untrusted data until its SHA-256 has matched.
"""
import hashlib
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "freedos")
URL = ("https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/"
       "distributions/1.4/FD14-FloppyEdition.zip")
ZIP_SHA256 = "45b1fa7c52dd996c3bfa5e352ffcd410781b952a6ad629f15a4c9ec4bbaefc5a"
MEMBER = "144m/x86BOOT.img"
IMG = os.path.join(OUT, "x86BOOT.img")
IMG_SHA256 = "552f7cbb0625960c050a3e682a4d2121cc2ffdfa9dc9d592ccd49edf179333dc"


REPO = ("https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.4/base/%s.zip")
PKGS = {                              # name -> (sha256 of the zip, members kept)
    "ctmouse":  ("fd47069fb3d9559604dcaef34ca4f3705a7f2f2cff3e4b205e361b79f10a8200", ("BIN/CTMOUSE.EXE",)),
    "himemx":   ("99b44e5bbb878105486e172675a460f645cdfb5a86cc1cf1e0e549fa31f29ce6", ("BIN/HimemX.exe",)),
    "jemm":     ("c67daebcd8f64e5977d1b2538a8c68d9ef8078cce6f9641f4469cc1b6dd96165", ("BIN/JEMM386.EXE",)),
    "keyb":     ("470a6c1f2a0710de37df25477ec81074b472cc81c340dd427ddebf1d54aa9ae4", ("BIN/KEYB.EXE",)),
    "nansi":    ("5e17dfd767e9e4f93206da0cfcf17b03a36dd578417e6fc30a4135a311ac9c56", ("BIN/NANSI.SYS",)),
    "share":    ("c434ee6ea09cd4047fc478dfc650dda59a77318f018079793a8bcca0135a9249", ("BIN/SHARE.COM",)),
    "lbacache": ("21ca3fa717e6c6f3bc705869a4b84ffcc58ef5ca7929d8a57bb2c932afbe6ae0", ("BIN/LBACACHE.COM",)),
}
PKGDIR = os.path.join(OUT, "pkgs")

# SvarDOS: its kernel is Enhanced DR-DOS (a DR-DOS, not a FreeDOS), which is the
# point - a second DOS family. Over plain HTTP because its site has no TLS.
SVAR_DIR = os.path.join(ROOT, "build", "svardos")
SVAR_URL = "http://svardos.org/download/20250427/svardos-20250427-floppy-1.44M.zip"
SVAR_ZIP_SHA256 = "3a648ab160167d0e5cc96db35d3bef487c5995a9da93f1262be02ec5c1aca6dd"
SVAR_MEMBER = "svdos-1.44M-disk-1.img"
SVAR_IMG = os.path.join(SVAR_DIR, "boot.img")
SVAR_IMG_SHA256 = "4db7fcab7388909d8e1d1cd4433f30d96cf3740ae363c889243e9f39bcdccda5"


def have_svardos():
    return os.path.exists(SVAR_IMG) and sha256(SVAR_IMG) == SVAR_IMG_SHA256


def fetch_svardos():
    dl = os.path.join(SVAR_DIR, "dl")
    os.makedirs(dl, exist_ok=True)
    zpath = os.path.join(dl, "svardos-floppy.zip")
    if not (os.path.exists(zpath) and sha256(zpath) == SVAR_ZIP_SHA256):
        print("getfreedos: fetching %s" % SVAR_URL)
        tmp = zpath + ".part"
        for attempt in range(4):
            try:
                with urllib.request.urlopen(SVAR_URL, timeout=60) as r, open(tmp, "wb") as f:
                    f.write(r.read())
                break
            except (urllib.error.URLError, OSError) as e:
                if attempt == 3:
                    raise
                print("getfreedos: svardos: %s, retrying" % e)
                time.sleep(10 * (attempt + 1))
        if sha256(tmp) != SVAR_ZIP_SHA256:
            os.unlink(tmp)
            sys.exit("getfreedos: the SvarDOS archive does not match its pin")
        os.replace(tmp, zpath)
    with zipfile.ZipFile(zpath) as z:
        data = z.read(SVAR_MEMBER)
    with open(SVAR_IMG, "wb") as f:
        f.write(data)
    if sha256(SVAR_IMG) != SVAR_IMG_SHA256:
        sys.exit("getfreedos: the extracted SvarDOS floppy does not match its pin")


def pkg_path(name, member):
    """Where a kept package member lives, upper-cased as DOS names it."""
    return os.path.join(PKGDIR, name, os.path.basename(member).upper())


def have_pkgs():
    return all(os.path.exists(pkg_path(n, m)) for n, (_, ms) in PKGS.items() for m in ms)


def fetch_pkgs():
    for name, (digest, members) in PKGS.items():
        d = os.path.join(PKGDIR, name)
        os.makedirs(d, exist_ok=True)
        zpath = os.path.join(d, name + ".zip")
        if not (os.path.exists(zpath) and sha256(zpath) == digest):
            print("getfreedos: fetching %s" % name)
            tmp = zpath + ".part"
            for attempt in range(6):          # ibiblio answers 503 when it is busy
                try:
                    with urllib.request.urlopen(REPO % name, timeout=60) as r, open(tmp, "wb") as f:
                        f.write(r.read())
                    break
                except (urllib.error.URLError, OSError) as e:
                    if attempt == 5:
                        raise
                    print("getfreedos: %s: %s, retrying" % (name, e))
                    time.sleep(10 * (attempt + 1))
            if sha256(tmp) != digest:
                os.unlink(tmp)
                sys.exit("getfreedos: %s does not match its pin" % name)
            os.replace(tmp, zpath)
        with zipfile.ZipFile(zpath) as z:
            for m in members:
                with open(pkg_path(name, m), "wb") as f:
                    f.write(z.read(m))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def have():
    """True when the extracted floppy is present and is the pinned one."""
    return os.path.exists(IMG) and sha256(IMG) == IMG_SHA256


def fetch():
    dl = os.path.join(OUT, "dl")
    os.makedirs(dl, exist_ok=True)
    zpath = os.path.join(dl, "FD14-FloppyEdition.zip")
    if not (os.path.exists(zpath) and sha256(zpath) == ZIP_SHA256):
        print("getfreedos: fetching %s" % URL)
        tmp = zpath + ".part"
        with urllib.request.urlopen(URL, timeout=120) as r, open(tmp, "wb") as f:
            while True:
                blk = r.read(1 << 20)
                if not blk:
                    break
                f.write(blk)
        if sha256(tmp) != ZIP_SHA256:
            os.unlink(tmp)
            sys.exit("getfreedos: the archive's SHA-256 does not match the pin")
        os.replace(tmp, zpath)
    with zipfile.ZipFile(zpath) as z:
        data = z.read(MEMBER)
    tmp = IMG + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, IMG)
    if sha256(IMG) != IMG_SHA256:
        sys.exit("getfreedos: the extracted floppy does not match the pin")


def main():
    if "--check" in sys.argv:
        ok = have() and (have_pkgs() or "--pkgs" not in sys.argv)
        print("getfreedos: %s" % ("present" if ok else "missing or not the pinned image"))
        return 0 if ok else 1
    if not have():
        fetch()
    print("getfreedos: %s" % IMG)
    if "--pkgs" in sys.argv:
        fetch_pkgs()
        print("getfreedos: %d packages in %s" % (len(PKGS), PKGDIR))
    if "--svardos" in sys.argv:
        if not have_svardos():
            fetch_svardos()
        print("getfreedos: %s" % SVAR_IMG)
    return 0


if __name__ == "__main__":
    sys.exit(main())
