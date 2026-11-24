#!/usr/bin/env python3
"""Checks that every arm64 native library in an APK supports 16 KB pages.

Google Play requires LOAD segments aligned to at least 16 KB and, for
uncompressed libraries, a ZIP data offset that is a multiple of 16 KB.
"""
import struct
import sys
import zipfile

PAGE = 16 * 1024


def load_alignments(data: bytes) -> list[int]:
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not a little-endian 64-bit ELF file")
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    alignments = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        if struct.unpack_from("<I", data, offset)[0] == 1:  # PT_LOAD
            alignments.append(struct.unpack_from("<Q", data, offset + 0x30)[0])
    return alignments


def check(apk: str) -> list[str]:
    problems = []
    found = 0
    with zipfile.ZipFile(apk) as archive, open(apk, "rb") as raw:
        for info in archive.infolist():
            name = info.filename
            if not (name.startswith("lib/arm64-v8a/") and name.endswith(".so")):
                continue
            found += 1
            try:
                alignments = load_alignments(archive.read(info))
            except ValueError as error:
                problems.append(f"{name}: {error}")
                continue
            low = [a for a in alignments if a < PAGE]
            if not alignments or low:
                problems.append(f"{name}: LOAD alignment {min(alignments or [0])} < {PAGE}")
            if info.compress_type == zipfile.ZIP_STORED:
                raw.seek(info.header_offset)
                header = raw.read(30)
                name_length, extra_length = struct.unpack_from("<HH", header, 26)
                data_offset = info.header_offset + 30 + name_length + extra_length
                if data_offset % PAGE:
                    problems.append(f"{name}: ZIP offset {data_offset} is not 16 KB aligned")
    if found == 0:
        problems.append("no lib/arm64-v8a/*.so files found")
    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_16kb.py APP.apk", file=sys.stderr)
        return 2
    problems = check(sys.argv[1])
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("All arm64 native libraries support 16 KB pages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
