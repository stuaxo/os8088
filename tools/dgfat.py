#!/usr/bin/env python3
"""dgfat: a FAT12/16 file's extents, read the way dosguest's launcher reads them.

    python3 tools/dgfat.py IMAGE NAME        # print the extents of ROOT file NAME
    python3 tools/dgfat.py --selfcheck

THE SECOND READER. dosguest/dg.asm walks a file's cluster chain on a DOS
machine, in 8086 assembly, and hands the result to a stub that reads and
writes the volume with raw int 13h. If that walk is wrong the snapshot goes to
the wrong sectors and nothing notices until the restore. tests/dosguest.py
therefore asks this independent implementation the same question about the
image the guest left behind, and the two have to agree.

It deliberately shares nothing with tools/os88disk.py (which BUILDS volumes)
and reads a volume the way a third party would: BPB, FAT, root directory,
chain. Root-directory files only, which is all dosguest needs.
"""
import struct
import sys


class Volume:
    def __init__(self, img, start=0):
        self.img, self.start = img, start
        b = img[start:start + 512]
        (self.bps, self.spc, self.res, self.nfat, self.rootents,
         tot16, _media, self.spf) = struct.unpack_from("<HBHBHHBH", b, 11)
        self.hidden = struct.unpack_from("<I", b, 28)[0]
        tot32 = struct.unpack_from("<I", b, 32)[0]
        self.total = tot16 or tot32
        if self.bps != 512 or not self.spf:
            raise ValueError("not a 512-byte-sector FAT12/16 volume")
        self.root_start = self.res + self.nfat * self.spf
        self.root_secs = (self.rootents * 32 + 511) // 512
        self.data_start = self.root_start + self.root_secs
        clusters = (self.total - self.data_start) // self.spc
        self.fat16 = clusters >= 4085

    def sector(self, n):
        o = self.start + n * 512
        return self.img[o:o + 512]

    def fat_entry(self, cl):
        fat = self.start + self.res * 512
        if self.fat16:
            return struct.unpack_from("<H", self.img, fat + cl * 2)[0]
        v = struct.unpack_from("<H", self.img, fat + cl + cl // 2)[0]
        return (v >> 4) if cl & 1 else (v & 0x0FFF)

    def eoc(self, v):
        return v >= (0xFFF8 if self.fat16 else 0x0FF8)

    def find(self, name83):
        """(first cluster, size) of a root file, or None. NAME83 is 11 bytes."""
        for s in range(self.root_secs):
            blk = self.sector(self.root_start + s)
            for i in range(0, 512, 32):
                ent = blk[i:i + 32]
                if ent[0] == 0:
                    return None
                if ent[0] != 0xE5 and ent[:11] == name83:
                    return (struct.unpack_from("<H", ent, 26)[0],
                            struct.unpack_from("<I", ent, 28)[0])
        return None

    def extents(self, name83):
        """[(volume-relative LBA, sector count)] covering the file, coalesced,
        and the size. Clamped to the file's own size, as the launcher does."""
        hit = self.find(name83)
        if hit is None:
            raise FileNotFoundError(name83)
        cl, size = hit
        need = (size + 511) // 512
        runs = []
        while True:
            lba = self.data_start + (cl - 2) * self.spc
            if runs and runs[-1][0] + runs[-1][1] == lba:
                runs[-1][1] += self.spc
            else:
                runs.append([lba, self.spc])
            nxt = self.fat_entry(cl)
            if self.eoc(nxt):
                break
            cl = nxt
        left = need
        out = []
        for lba, n in runs:
            n = min(n, left)
            out.append((lba, n))
            left -= n
        return out, size

    def read(self, name83):
        runs, size = self.extents(name83)
        data = b"".join(self.sector(l + k) for l, n in runs for k in range(n))
        return data[:size]


def selfcheck():
    """A hand-built FAT12 volume with a fragmented file, and the same file on a
    FAT16 one, each read back; plus a chain that must NOT coalesce."""
    def build(fat16):
        spc, res, nfat, spf, rootents = 1, 1, 2, (32 if fat16 else 3), 16
        total = 20000 if fat16 else 400
        img = bytearray(total * 512)
        struct.pack_into("<HBHBHHBH", img, 11, 512, spc, res, nfat, rootents,
                         total if total < 65536 else 0, 0xF8, spf)
        root = res + nfat * spf
        data = root + 1
        # a file of 5 clusters: 2,3, then 7, 8, then 5 (fragmented)
        chain = [2, 3, 7, 8, 5]
        def setfat(cl, v):
            fat = res * 512
            if fat16:
                struct.pack_into("<H", img, fat + cl * 2, v)
            else:
                o = fat + cl + cl // 2
                cur = struct.unpack_from("<H", img, o)[0]
                cur = ((cur & 0x000F) | (v << 4)) if cl & 1 else ((cur & 0xF000) | v)
                struct.pack_into("<H", img, o, cur & 0xFFFF)
        for a, b in zip(chain, chain[1:]):
            setfat(a, b)
        setfat(chain[-1], 0xFFFF if fat16 else 0x0FFF)
        ent = bytearray(32)
        ent[:11] = b"DGSWAP  IMG"
        struct.pack_into("<HI", ent, 26, chain[0], 5 * 512 - 100)
        img[root * 512:root * 512 + 32] = ent
        for k, cl in enumerate(chain):
            img[(data + cl - 2) * 512:(data + cl - 1) * 512] = bytes([k + 1]) * 512
        return bytes(img), data
    for fat16 in (False, True):
        img, data = build(fat16)
        v = Volume(img)
        runs, size = v.extents(b"DGSWAP  IMG")
        want = [(data + 0, 2), (data + 5, 2), (data + 3, 1)]
        assert runs == want, (fat16, runs, want)
        assert size == 5 * 512 - 100
        got = v.read(b"DGSWAP  IMG")
        assert len(got) == size and got[0] == 1 and got[-1] == 5
    print("dgfat: selfcheck ok (FAT12 and FAT16, a fragmented chain)")


def main():
    if sys.argv[1:2] == ["--selfcheck"]:
        selfcheck()
        return 0
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    img = open(sys.argv[1], "rb").read()
    name = sys.argv[2].upper()
    base, _, ext = name.partition(".")
    n83 = (base.ljust(8) + ext.ljust(3)).encode()
    runs, size = Volume(img).extents(n83)
    print("size", size)
    for lba, n in runs:
        print("run %08X %04X" % (lba, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
