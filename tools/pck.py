"""Godot 3.5 PCK reader and writer.

Format, verified against the reference implementation in
godotengine/godot `core/io/pck_packer.cpp` (MIT) and against a pack produced by Godot 3.5.1's own
`PCKPacker`:

    header   4   magic "GDPC"
             4   pack format version (1)
             4   engine major    (3)
             4   engine minor    (5)
             4   engine patch    (1)
            64   16 reserved uint32s
             4   file count
    entries  per file, in the order they were added:
             4   path length (bytes, no terminator)
             n   path, UTF-8, no padding
            16   offset (uint64 LE), size (uint64 LE)
            16   md5 (left as zeroes by Godot; not verified by the engine)
    data     file contents, back to back, no per-file padding

There is no compression and no encryption in this format. `PCKPacker::pck_start` takes an
alignment argument but Godot's exporter passes 0, so real packs are unpadded; the reader here
still honours a non-zero alignment if a pack happens to use one.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"GDPC"
PACK_FORMAT_VERSION = 1
ENGINE_VERSION = (3, 5, 1)


@dataclass
class Entry:
    path: str          # as stored, e.g. "res://ui/UILayer.gd"
    offset: int        # absolute offset of the data in the pack
    size: int
    md5: bytes


class PckError(Exception):
    pass


class Pck:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.raw = self.path.read_bytes()
        self.entries: list[Entry] = []
        self.version = (0, 0, 0)
        self._parse()

    def _parse(self) -> None:
        b = self.raw
        if len(b) < 88 or b[:4] != MAGIC:
            raise PckError(f"{self.path} does not start with the Godot pack magic 'GDPC'")
        fmt, major, minor, patch = struct.unpack_from("<IIII", b, 4)
        if fmt != PACK_FORMAT_VERSION:
            raise PckError(f"unsupported pack format version {fmt} (expected {PACK_FORMAT_VERSION})")
        self.version = (major, minor, patch)
        off = 4 + 16 + 64
        (count,) = struct.unpack_from("<I", b, off)
        off += 4
        for _ in range(count):
            (length,) = struct.unpack_from("<I", b, off)
            off += 4
            if length == 0 or length > 8192:
                raise PckError(f"implausible path length {length} at offset {off - 4}")
            path = b[off:off + length].decode("utf-8")
            off += length
            offset, size = struct.unpack_from("<QQ", b, off)
            off += 16
            md5 = b[off:off + 16]
            off += 16
            self.entries.append(Entry(path, offset, size, md5))
        self.data_start = off

    # ---------------------------------------------------------------- reading

    def names(self) -> set[str]:
        return {e.path for e in self.entries}

    def read(self, name: str) -> bytes:
        for e in self.entries:
            if e.path == name:
                return self.raw[e.offset:e.offset + e.size]
        raise KeyError(name)

    def extract_to(self, dest: Path, only: set[str] | None = None) -> int:
        """Write the pack's contents under `dest`, keeping the res:// paths as directories."""
        dest = Path(dest)
        written = 0
        for e in self.entries:
            if only is not None and e.path not in only:
                continue
            rel = e.path[len("res://"):] if e.path.startswith("res://") else e.path
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self.raw[e.offset:e.offset + e.size])
            written += 1
        return written


# ---------------------------------------------------------------- writing

def write_pck(out: Path, files: list[tuple[str, bytes]],
              engine: tuple[int, int, int] = ENGINE_VERSION) -> int:
    """Write a pack from (res://path, bytes) pairs, in the order given.

    The order matters: Godot reads the index sequentially and the engine looks files up by exact
    path, so the launcher keeps whatever order it was given (the order of the pack it came from)
    to make a repack as close to a rebuild as possible.
    """
    out = Path(out)
    header = struct.pack("<4sIIIII", MAGIC, PACK_FORMAT_VERSION, *engine, 0)[:20]
    header = MAGIC + struct.pack("<IIII", PACK_FORMAT_VERSION, *engine) + b"\x00" * 64
    header += struct.pack("<I", len(files))

    index_size = 0
    for name, data in files:
        raw = name.encode("utf-8")
        index_size += 4 + len(raw) + 16 + 16
    data_start = len(header) + index_size

    index = bytearray()
    offset = data_start
    for name, data in files:
        raw = name.encode("utf-8")
        index += struct.pack("<I", len(raw))
        index += raw
        index += struct.pack("<QQ", offset, len(data))
        index += b"\x00" * 16          # md5, as Godot leaves it
        offset += len(data)

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as f:
        f.write(header)
        f.write(bytes(index))
        for _name, data in files:
            f.write(data)
    return out.stat().st_size


def files_from_dir(root: Path, prefix: str = "res://") -> list[tuple[str, bytes]]:
    """Every file under `root`, as (prefix+relative path, bytes), in a stable order."""
    root = Path(root)
    out = []
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        out.append((prefix + rel, p.read_bytes()))
    return out
