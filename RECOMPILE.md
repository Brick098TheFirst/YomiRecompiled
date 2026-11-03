# Decompiling a Steam install, patching it, and rebuilding it

**Short answer: yes, and the launcher does it for you.** Point it at the Steam install. It
recovers the project out of the pack, applies all 27 patches, imports the textures, and launches
the rebuilt game. The output is the patched game, not the vanilla one.

This replaces an earlier version of this document which said the pipeline was not viable. That
conclusion was wrong, and the measurements that produced it were made on the wrong step: it judged
recovery by hand-running `--txt-to-bin` / `--bin-to-txt` on individual files instead of by running
`--recover` on the pack, which is what the launcher actually uses. The corrected evidence is below.

## What it measures

Everything here was run against real game files, not a mock-up:

| Test | Result |
|---|---|
| All 27 patches against a real `--recover` output | **27 / 27 apply** |
| Those 27 files vs the original source | **0 differ — byte-identical** |
| Scripts compiled then decompiled (504 compiled) | **18 / 18 round-trip byte-identical** (deep sample) |
| Rebuilt game launched from the recovered tree | **title screen, 0 errors** |
| Patched files vs the reference build | **27 / 27 byte-identical** |

The recovery test used a full `--recover` of the shipped pack — 4,957 files in, and out came
`project.godot` plus **504 `.gd`** and **330 `.tscn`**. Every patch target exists in that output and
every patch applies to it.

## How the launcher does it

```
launcher.py --game <steam install>
```

1. **Detect.** If the folder has `project.godot`, it is already source and goes straight to step 3.
   If it has a compiled `project.binary` and `.gdc` bytecode, it is a release, and it is recovered.
2. **Recover.** GDRE Tools (`--recover`) unpacks the pack and converts the binary project file back
   to `project.godot`. Scripts that come back as `.gdc` are decompiled in one batch per folder —
   the project has 31 repeated script names (every character has its own `AirDash.gd`), so a single
   flat output folder would silently lose scripts.
3. **Patch.** The 27 diffs are applied to the recovered tree, plus the 6 files that are ours alone.
   Anything that will not apply is reported, never skipped silently.
4. **Import.** A recovery has the PNGs and the `.import` sidecars but not the compiled `.stex`
   textures those sidecars point at, so no image loads until they are rebuilt. The launcher opens
   the project in the engine and waits for the import to finish (about two minutes; it must not be
   closed early, or the scan aborts and almost nothing is imported).
5. **Build and run.** The patched tree is what runs. There is no separate "recompile to a pack" step
   and none is needed: Godot runs a project directory directly, and that is what the deliverable is.

GDRE (`v2.7.4`, ~34 MB) and, if you do not already have one, Godot 3.5.1 (~37 MB) are downloaded on
first use and cached in `~/.cache/full-project`. Neither is bundled, both because they are large
third-party binaries and because fetching them at run time keeps this repository to our own code.

Your Steam install's own executable cannot stand in for Godot: an exported Godot game has its pack
attached and refuses to load a project directory ("no main scene defined in the project"), even for
a project that a real editor binary runs fine. That is why the engine is a separate download.

## The limits that are real

These are the honest caveats. None of them stops the build working; all of them are worth knowing.

- **Comments and formatting do not survive a compile.** Decompiled scripts are behaviourally
  identical but lose comments, and `-100` may come back as `- 100`. This is why the patches are
  applied to the **recovered** tree rather than to decompiled individual scripts: the recovered
  tree is the tree the diffs were written against. A patch that *added* a comment would not survive
  a later recompile-and-decompile cycle.
- **Recovery needs a genuine compiled project file.** A pack whose `project.binary` is not a real
  `ECFG` binary cannot be recovered; GDRE emits an empty `project.godot` skeleton and every
  config-level patch fails. Real game packs are fine — this only bites hand-built test packs.
- **A recovery needs one import pass**, which is why step 4 exists. It is the slowest step, and the
  launcher does it for you.
- **`project.godot` is applied as a whole file, not as a diff.** It is rebuilt from a compiled
  binary, so its comments, blank lines and key order belong to the decompiler rather than the
  original, and the diff cannot land on it. The repository ships the finished patched file, so the
  result is identical either way.

## Reproducing the checks

```bash
# recover a pack and look at what came out
gdre_tools.x86_64 --headless --recover=YourOnlyMoveIsHUSTLE.pck --output=./rec

# do all 27 diffs apply to that tree?
cd rec && for p in ../patch/modified/*.patch; do
  patch --dry-run -s -p1 "${p##*/}" < "$p" && echo "ok ${p##*/}"
done
```

`tools/recompile/diagnose.py` reports what a given folder is (source, release, or neither) and what
the launcher will do with it. `tools/recompile/check_pack.py` inspects a pack before you touch it.
