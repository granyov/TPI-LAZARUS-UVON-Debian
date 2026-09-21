#!/usr/bin/env python3
"""Разбор и сборка update.img для RKDevTool (форматы RKFW и RKAF).

RKFW — внешняя обёртка: заголовок, загрузчик, внутри неё пакет RKAF с
разделами. Структуры взяты из RKImage.h/RKAndroidImage.h утилиты
rkdeveloptool, порядок полей проверен на заводском образе.
"""
from __future__ import annotations
import hashlib, struct, sys

RKFW_HDR = "<4sHIIHBBBBBIIIII"          # до reserved[61]
RKFW_HDR_LEN = struct.calcsize(RKFW_HDR)   # 41 + ... считается ниже
RKAF_PART = "<32s60sIIIII"                 # name, file, nand_size, pos, nand_addr, padded, size


def parse_rkfw(data: bytes) -> dict:
    tag, hsize = struct.unpack_from("<4sH", data, 0)
    if tag != b"RKFW":
        raise ValueError(f"не RKFW, а {tag!r}")
    ver, merge = struct.unpack_from("<II", data, 6)
    year, mon, day, hh, mm, ss = struct.unpack_from("<HBBBBB", data, 14)
    chip, boot_off, boot_size, fw_off, fw_size = struct.unpack_from("<IIIII", data, 21)
    return dict(hsize=hsize, version=ver, merge=merge,
                time=(year, mon, day, hh, mm, ss), chip=chip,
                boot_off=boot_off, boot_size=boot_size,
                fw_off=fw_off, fw_size=fw_size)


def parse_rkaf(data: bytes, base: int) -> dict:
    tag, size = struct.unpack_from("<4sI", data, base)
    if tag != b"RKAF":
        raise ValueError(f"не RKAF, а {tag!r}")
    model = data[base + 8: base + 8 + 34].split(b"\0")[0].decode(errors="replace")
    ident = data[base + 42: base + 42 + 30].split(b"\0")[0].decode(errors="replace")
    manuf = data[base + 72: base + 72 + 56].split(b"\0")[0].decode(errors="replace")
    # 128: неизвестное поле, 132: версия, 136: число разделов, 140: сами разделы
    unknown, ver, nparts = struct.unpack_from("<III", data, base + 128)
    parts = []
    off = base + 140
    for _ in range(nparts):
        name, fname, nand_size, pos, nand_addr, padded, size = struct.unpack_from(RKAF_PART, data, off)
        parts.append(dict(name=name.split(b"\0")[0].decode(),
                          file=fname.split(b"\0")[0].decode(),
                          nand_size=nand_size, pos=pos, nand_addr=nand_addr,
                          padded=padded, size=size))
        off += struct.calcsize(RKAF_PART)
    return dict(size=size, model=model, id=ident, manufacturer=manuf,
                version=ver, nparts=nparts, parts=parts)


def main() -> None:
    path = sys.argv[1]
    with open(path, "rb") as f:
        head = f.read(0x4000)
        fw = parse_rkfw(head)
        print(f"RKFW: заголовок {fw['hsize']} Б, версия {fw['version']:#x}, "
              f"чип {fw['chip']:#x}, {fw['time'][0]}-{fw['time'][1]:02d}-{fw['time'][2]:02d}")
        print(f"  загрузчик: смещение {fw['boot_off']:#x}, размер {fw['boot_size']}")
        print(f"  пакет:     смещение {fw['fw_off']:#x}, размер {fw['fw_size']}")
        f.seek(fw["fw_off"])
        af_head = f.read(0x4000)
        af = parse_rkaf(af_head, 0)
        print(f"RKAF: модель {af['model']!r}, id {af['id']!r}, "
              f"изготовитель {af['manufacturer']!r}, разделов {af['nparts']}")
        for p in af["parts"]:
            print(f"    {p['name']:<14} {p['file']:<22} "
                  f"смещение {p['pos']:#010x} размер {p['size']:>10} "
                  f"в флеш {p['nand_addr']:#010x}")
        import os
        total = os.path.getsize(path)
        print(f"  хвост после пакета: {total - (fw['fw_off'] + fw['fw_size'])} Б "
              f"(обычно 32 Б MD5 + подпись)")


if __name__ == "__main__":
    main()
