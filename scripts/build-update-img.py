#!/usr/bin/env python3
"""Собрать update.img для RKDevTool (режим Upgrade Firmware).

Форматы RKFW и RKAF разобраны по исходникам rkdeveloptool и сверены с заводским
образом платы: разбор его заголовков совпал, а схема контрольной суммы (32 байта
шестнадцатеричного MD5 в хвосте) подтверждена пересчётом.

Сборщиков Rockchip (afptool, rkImageMaker) здесь не используется — только
стандартная библиотека.
"""
from __future__ import annotations
import hashlib, os, struct, sys, time

ALIGN = 0x800
SECTOR = 512


def pad(n: int, a: int = ALIGN) -> int:
    return (n + a - 1) // a * a


def rkaf_layout(entries):
    """Считает раскладку пакета, не читая сами файлы."""
    hdr_len = 0x800
    parts, off = [], hdr_len
    for name, fname, path, flash in entries:
        size = os.path.getsize(path)
        padded = pad(size)
        parts.append(dict(name=name, file=fname, path=path, size=size,
                          pos=off, padded=padded,
                          flash=0xFFFFFFFF if flash is None else flash,
                          nand_size=0xFFFFFFFF if flash is None
                                    else (padded + SECTOR - 1) // SECTOR))
        off += padded
    return hdr_len, parts, off


def rkaf_header(hdr_len, parts, total, model, ident, manuf, version):
    hdr = bytearray(hdr_len)
    struct.pack_into("<4sI", hdr, 0, b"RKAF", total - 4)
    hdr[8:8 + 34] = model.encode()[:33].ljust(34, b"\0")
    hdr[42:42 + 30] = ident.encode()[:29].ljust(30, b"\0")
    hdr[72:72 + 56] = manuf.encode()[:55].ljust(56, b"\0")
    struct.pack_into("<III", hdr, 128, 0, version, len(parts))
    o = 140
    for p in parts:
        struct.pack_into("<32s60sIIIII", hdr, o,
                         p["name"].encode()[:31].ljust(32, b"\0"),
                         p["file"].encode()[:59].ljust(60, b"\0"),
                         p["nand_size"], p["pos"], p["flash"],
                         p["padded"], p["size"])
        o += 112
    return bytes(hdr)


def main() -> None:
    src, out = sys.argv[1], sys.argv[2]
    entries = [
        ("package-file", "package-file", f"{src}/package-file", None),
        ("parameter",    "parameter.txt", f"{src}/parameter.txt", 0x00000000),
        ("bootloader",   "MiniLoaderAll.bin", f"{src}/MiniLoaderAll.bin", None),
        ("uboot",        "uboot.img",  f"{src}/uboot.img",  0x00004000),
        ("boot",         "boot.img",   f"{src}/boot.img",   0x00008000),
        ("rootfs",       "rootfs.img", f"{src}/rootfs.img", 0x00078000),
    ]
    for _, _, p, _ in entries:
        if not os.path.exists(p):
            raise SystemExit(f"нет файла: {p}")

    print("== пакет RKAF ==")
    hdr_len, parts, total = rkaf_layout(entries)
    for p in parts:
        flash = "—" if p["flash"] == 0xFFFFFFFF else f"{p['flash']:#010x}"
        print(f"  {p['name']:<13} {p['file']:<20} {p['size']:>10} Б  в флеш {flash}")
    rkaf_hdr = rkaf_header(hdr_len, parts, total, " TPI LAZARUS UVON", " 007",
                           " TPI", 0x01000000)

    loader_path = f"{src}/MiniLoaderAll.bin"
    loader_size = os.path.getsize(loader_path)
    t0 = time.gmtime()
    hdr = bytearray(102)
    struct.pack_into("<4sH", hdr, 0, b"RKFW", 102)
    struct.pack_into("<II", hdr, 6, 0x01000000, 0x01000000)
    struct.pack_into("<HBBBBB", hdr, 14, t0.tm_year, t0.tm_mon, t0.tm_mday,
                     t0.tm_hour, t0.tm_min, t0.tm_sec)
    struct.pack_into("<I", hdr, 21, 0x33353638)
    struct.pack_into("<II", hdr, 25, 102, loader_size)
    struct.pack_into("<II", hdr, 33, 102 + loader_size, total)

    print("== образ RKFW ==")
    h = hashlib.md5()

    def emit(f, blob):
        f.write(blob); h.update(blob)

    with open(out, "wb") as f:
        emit(f, bytes(hdr))
        with open(loader_path, "rb") as lf:
            while chunk := lf.read(1 << 20):
                emit(f, chunk)
        emit(f, rkaf_hdr)
        for p in parts:
            written = 0
            with open(p["path"], "rb") as pf:
                while chunk := pf.read(1 << 20):
                    emit(f, chunk); written += len(chunk)
            emit(f, b"\0" * (p["padded"] - written))
        emit(f, h.hexdigest().encode())

    size = os.path.getsize(out)
    print(f"  загрузчик: {loader_size} Б, пакет: {total} Б")
    print(f"  {out}: {size} Б ({size / 2**20:.0f} МиБ)")
    print(f"  MD5 тела: {h.hexdigest()}")


if __name__ == "__main__":
    main()
