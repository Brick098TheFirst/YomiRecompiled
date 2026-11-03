"""Read a game folder or .pck and report what kind of build it is. No dependencies."""
from __future__ import annotations
import collections, struct
from pathlib import Path

MAGIC = b"GDPC"


def read_pck(path: Path) -> dict[str, bytes]:
    raw = Path(path).read_bytes()
    if raw[:4] != MAGIC:
        raise SystemExit(f"{path} is not a Godot pack")
    fmt, major, minor, patch = struct.unpack_from("<IIII", raw, 4)
    off = 4 + 16 + 64
    (count,) = struct.unpack_from("<I", raw, off)
    off += 4
    out = {}
    for _ in range(count):
        (n,) = struct.unpack_from("<I", raw, off)
        off += 4
        name = raw[off:off + n].decode("utf-8")
        off += n
        o, s = struct.unpack_from("<QQ", raw, off)
        off += 16 + 16
        out[name[6:] if name.startswith("res://") else name] = raw[o:o + s]
    return out


def inspect(folder: Path) -> dict:
    folder = Path(folder)
    pcks = sorted(folder.glob("*.pck"))
    if pcks:
        names = list(read_pck(pcks[0]))
    else:
        names = [p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()]
    ext = collections.Counter(Path(n).suffix.lower() for n in names)
    if ".gd.remap" in ext:            # keep the stub count out of the .remap bucket
        ext[".gd"] = sum(1 for n in names if n.endswith(".gd"))
    top = collections.Counter(n.split("/")[0] for n in names)
    gd, gdc, remap = ext[".gd"], ext[".gdc"], sum(1 for n in names if n.endswith(".gd.remap"))
    source = (("project.godot" in names) and gd > 50 and gdc == 0)
    if source:
        kind = "source build (patchable)"
    elif gdc or remap or "project.binary" in names:
        kind = "compiled export (NOT patchable with text diffs)"
    else:
        kind = "unrecognised"
    return {"files": len(names), "kind": kind, "gd": gd, "gdc": gdc, "remap": remap,
            "tscn": ext[".tscn"], "scn": ext[".scn"] + ext[".res"],
            "project_godot": int("project.godot" in names),
            "project_binary": int("project.binary" in names), "top": top}


if __name__ == "__main__":
    import sys
    print(inspect(Path(sys.argv[1])))
