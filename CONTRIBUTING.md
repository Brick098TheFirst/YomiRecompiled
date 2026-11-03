# Contributing

## The one rule

**Do not commit game files.** No `data.pck`, no unpacked game tree, no sprites or audio from the
game. See [LEGAL.md](LEGAL.md) — the short version is that the game's licence reserves
distribution rights, and this repository only stays publishable because it contains diffs instead.

Before you push:

```bash
git status --ignored --short | grep -v '^!!' || true   # nothing unexpected staged
python3 tools/build_patch.py --check                    # every diff still applies
python3 tools/check_compliance.py --game <install>      # nothing here is a copy of the game
python3 launcher.py --verify --game <your install>      # your copy matches these patches
```

`check_compliance.py` inspects what git would actually publish, so generated patched files left in
your working tree are fine — staging one is not.

## Changing an upstream file

1. Edit the file in an unpacked tree (`python3 launcher.py --unpack-only` gives you one, or
   the **Unpack only** button in the launcher window).
2. Regenerate the pair:

   ```bash
   python3 tools/build_patch.py      # applies patch/original + *.patch
   ```

   If you changed a file that was previously untouched, add its original to
   `patch/original/<path>` and write `patch/modified/<path>.patch` as a unified diff, then list it
   in `patch/index.json` under `upstream_edits`.

3. Keep the diff **narrow**. A whole-file rewrite is a copied file with a `diff` header on top, and
   that defeats the point.

## Adding your own file

Drop it under `patch/modified/<path>` and list it in `patch/index.json` under `new_files`. Files
that are entirely original should declare the MIT licence in a header comment.

## Testing

The launcher has no test suite beyond itself, but two checks matter:

* `tools/pck.py` round-trip: a pack written by `write_pck` from a `Pck`'s own entries must be
  byte-identical to the input pack.
* An end-to-end build: `python3 launcher.py --no-run` then run `build/game/` and confirm it reaches
  the title screen with no script errors.
