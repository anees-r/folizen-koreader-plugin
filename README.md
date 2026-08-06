# Folizen KOReader plugin

One-way sync from your e-reader to your Folizen library: progress,
highlights, notes, and looked-up vocabulary words go up to the server;
nothing comes back down except a download queue and your sync settings.

## Status

This plugin was written directly against the Folizen server API
(`src/app/api/plugin/**` in the main repo) and against KOReader's
documented plugin conventions, but **it has not been run on a real
device or the KOReader desktop emulator** — there's no KOReader runtime
available in the environment this was built in. Treat it as a complete,
structurally-correct first draft that needs one normal round of
on-device debugging (the usual suspects: exact `require()` paths for
your installed KOReader version, and the annotations table shape if
you're on an older release) before you trust it with a real library.

## Installing

1. Copy the `folizen.koplugin/` folder into KOReader's `plugins/`
   directory (on the device, via USB, or through KOReader's own file
   manager), so you end up with `plugins/folizen.koplugin/main.lua` etc.
2. Restart KOReader.
3. Open any book → the hamburger/tools menu → **Folizen** → set your
   **Server URL** to your deployed Folizen app (e.g.
   `https://folizen.vercel.app`), then **Sign in to Folizen…** with the
   same username/email and password you use on the web.

## What it does

- **Progress sync** — every N page turns (configurable, default 5) and
  on closing a book, pushes current page / percent complete.
- **Highlights & notes sync** — full snapshot diff against the server on
  every sync, so edits and deletions on-device are reflected, not just
  additions.
- **Vocabulary sync** — ships up the bare word list from KOReader's own
  Vocabulary Builder; Folizen resolves definitions/pronunciation
  server-side, lazily, the first time you view them on the web.
- **Download queue** — Folizen → Download queue shows books you queued
  from the web app, lets you pick a folder, and downloads them.
- **Wi-Fi discipline** — never turns on Wi-Fi without asking first,
  unless you've explicitly enabled "Allow Folizen to turn on Wi-Fi
  automatically" in the plugin menu.

## Known gaps to close during on-device testing

- `highlights.lua` handles both the modern unified `annotations` table
  and the older per-page `highlight` table, but hasn't been validated
  against a real sidecar file of either shape.
- `vocabulary.lua` assumes Vocabulary Builder's sqlite schema has a
  `vocabulary(word, book_title)` shape; if your KOReader version's
  schema differs, it fails silently (by design — vocab sync should
  never be able to break page-turn sync) and just returns no words.
- `book_identity.lua` uses `document:fastDigest()` for a stable
  per-book key, falling back to `util.partialMD5`; confirm whichever is
  actually available on your KOReader version.
