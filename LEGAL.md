# Legal position, and why this repository is shaped the way it is

I am not a lawyer and this is not legal advice. It is a record of what the relevant licences
actually say, quoted, so you can judge for yourself and so nobody has to guess.

## 1. The game's licence

`Your Only Move Is HUSTLE` is by **Ian Sly**. The developer publishes the game's source
publicly — [github.com/uzkbwza/hustle](https://github.com/uzkbwza/hustle), linked by the author
on X — and that repository carries `LICENSE.txt`, quoted verbatim:

> Copyright (C) 2022 Ian Sly <ivysly@protonmail.com>
>
> All files contained in this repository are part of the Your Only Move Is HUSTLE code base.
>
> The Your Only Move Is HUSTLE project can not be copied and/or distributed without the express
> permission of Ian Sly <ivysly@protonmail.com>

Published source is **not** the same as a public licence. This is a reserved-rights notice: reading
it, building it, and modding your own copy is one thing; redistributing the code base or its assets
is another, and that needs permission.

**What follows from that for this repository:**

| Thing | Can it be here? |
| --- | --- |
| This project's own code (launcher, tools, AI, controller) | Yes — it is our work |
| A diff against an upstream file | Yes — it is an edit, not a copy of the work |
| The upstream file itself, unmodified, used as patch context | Only as much as a patch needs; it is here so patches apply and reverse exactly, it is **not** relicensed by this repo, and it is not runnable game code on its own |
| The full upstream source tree | **No** |
| Sprites, music, fonts, sounds | **No** |
| The compiled game or a `data.pck` | **No** |

## 2. What `localspot/` is

`localspot/` holds art and audio patches that were derived from the game's own assets (the splash
and title art, and the music track, whose change was a re-encode rather than a composition). That
makes them derivative of someone else's work, so they are **not committed here**.

The launcher applies them only if they are present on your disk. If `localspot/` is empty — which is
how a fresh clone starts — the build simply keeps the game's original art and audio. Nothing breaks:
the music loader logs a warning and skips the track.

If you made those edits on your own machine, from your own copy, keep them local.

## 3. What the launcher does, legally speaking

It reads a copy of the game **you already own**, on your own machine, and writes a modified copy
into `build/`. It does not download the game, decrypt it, or ship any of it. That is the same
position as any mod loader or patch tool: you are modifying your own copy for your own use.

It never writes into your install folder, so it cannot leave your copy broken.

## 4. Third-party code

| Component | Licence | Use here |
| --- | --- | --- |
| Godot Engine 3.5.1 | MIT | Not redistributed. The launcher's PCK writer is implemented from the format and checked against `core/io/pck_packer.cpp` (MIT). |
| This project's code | MIT | See `LICENSE`. |

## 5. If you fork this

* Keep `patch/original/` limited to what the patches need. Do not add the source tree.
* Never commit `localspot/`, `build/`, or a `.pck`.
* If you want to redistribute a playable build, get permission from Ian Sly first. Publishing a
  patcher is not the same as publishing the game, and that line matters.
* If you are the rights holder and want something here changed or removed, open an issue.
