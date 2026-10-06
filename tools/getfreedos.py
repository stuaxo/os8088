#!/usr/bin/env python3
"""getfreedos: fetch the FreeDOS 1.4 boot floppy that the dosguest rows boot.

    python3 tools/getfreedos.py              # fetch + verify + extract
    python3 tools/getfreedos.py --check      # verify what is there, never fetch

**Nothing this script downloads is committed.** FreeDOS is somebody else's
work under its own licences, and a git repository is not a distribution
channel for it: the bytes land in build/freedos/, which is ignored (build/
is), and tests/dosguest.py builds its disks from there.

It exists because docs/plans/DOSGUEST-PLAN.md has to be tested against a
REAL DOS, and none is in this repository and none can be. FreeDOS is the one
that can be fetched by anybody, which is why it is the first host and not the
only one (the plan, section 11, wants a second).

What is kept is ONE file out of a 22MB archive: the 1.44MB boot floppy, which
carries the kernel, COMMAND.COM and FDAPM (the way the test powers the guest
off). The archive is unpacked into a directory of its own and never run:
everything in it is untrusted data until its SHA-256 has matched.
"""
import hashlib
import os
import sys
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
        ok = have()
        print("getfreedos: %s" % ("present" if ok else "missing or not the pinned image"))
        return 0 if ok else 1
    if not have():
        fetch()
    print("getfreedos: %s" % IMG)
    return 0


if __name__ == "__main__":
    sys.exit(main())
