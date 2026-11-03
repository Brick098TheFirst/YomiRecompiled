#!/usr/bin/env python3
"""Work out what a Steam install actually contains, and what it would take to rebuild it.

    python3 diagnose.py "/path/to/steamapps/common/YourOnlyMoveIsHUSTLE"

Read-only. Touches nothing in the folder you point it at.
"""
from __future__ import annotations
import sys, collections
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from check_pack import inspect  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    folder = Path(sys.argv[1]).expanduser()
    info = inspect(folder)
    print(f"folder:  {folder}")
    print(f"files:   {info['files']}")
    print(f"kind:    {info['kind']}")
    print()
    for key, label in (("gd", "plain .gd scripts (patchable)"),
                       ("gdc", "compiled .gdc scripts"),
                       ("remap", ".gd.remap stubs"),
                       ("tscn", "text scenes (.tscn)"),
                       ("scn", "binary scenes (.scn/.res)"),
                       ("project_godot", "project.godot (patchable)"),
                       ("project_binary", "project.binary (compiled config)")):
        print(f"  {label:36} {info.get(key, 0)}")
    print()
    print("top folders:", ", ".join(f"{k} {v}" for k, v in info["top"].most_common(8)))
    print()
    if info["kind"].startswith("source"):
        print("VERDICT: this is a source build. The launcher can patch it directly.")
    else:
        print("VERDICT: this is a compiled release. The 27 patches are text edits and cannot")
        print("         be applied to it. See RECOMPILE.md for what rebuilding it would take.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
