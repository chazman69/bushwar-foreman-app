# Getting started — from zero to building in ~10 minutes

For Mike, Malvia, and anyone who joins the BUSHWAR map team later. Do this once;
after that your whole life is two buttons.

## What you need first (one-time)

1. **GitHub Desktop** — [desktop.github.com](https://desktop.github.com). Sign in with
   your GitHub account (the one invited to the map repo, `fireforce`). That's all you use it for:
   you never clone anything in it yourself.
2. **Arma Reforger Tools** (Workbench) — install from Steam, plus the Workshop
   dependencies listed in the map repo's `map/ADDON.md` (all the BUSHWAR asset packs).

That's it. Foreman downloads the map and links Workbench to it for you.

## Install Foreman (the app)

1. Download **`BUSHWAR-Foreman-Setup.exe`** from
   [the download page](https://github.com/chazman69/bushwar-foreman-app/releases/latest). No invite needed for this one.
2. Run it. It installs Foreman as a normal app — **Start Menu + Desktop icon +
   Add/Remove Programs entry**. You never deal with a folder; the app keeps itself
   up to date automatically every time you open it.
3. Say **Yes** to "Launch it now?".

## First run

1. Foreman asks to download the map: say **Yes** (a black window shows progress; the
   map is big, so the first time takes a while). Already have it? Say **No** and point
   at your `fireforce` folder instead.
2. Foreman links Workbench to the map by itself (you'll see a `[FIX] linked Workbench`
   line in the Activity box). No call, no command line.
3. The **Field Guide** opens automatically the first time — read it, it's short.
4. When you close it, **Doctor** checks your setup by itself (it asks your name once if
   it needs it). It ends with **ALL GOOD**, or with a list: screenshot that into the
   group chat before building.

## Every session after that

```
▶ START SESSION   →   build in Workbench   →   close Workbench   →   ⬆ SHIP SESSION
```

- **START SESSION** with Workbench closed — always. It pulls everyone's latest work
  (you build directly on `master`), then opens Workbench straight on the map.
- In Workbench: your cells, your own named layer. Stay inside the boundary your team agreed
  for you — honor system, no overlap (no in-engine tile claiming). Sculpted?
  **Save → regen normal map → Save.**
- **SHIP SESSION** when you stop: review the list (your sculpted tiles + placements
  ship; save-churn and the shared index are filtered automatically), type one line,
  **Confirm** — it lands straight on `master`. No review step, no pull request. Drop a
  one-liner in the group chat so the team knows what landed.

Not shipped = not done — but that's the whole job. Everything else (churn, unmergeable
files, push races, stale-copy traps) is Foreman's problem now, not yours.

## If something goes wrong

Every `[STOP]` message names its own fix. Beyond that: **Doctor**, then the group
chat, in that order. Never push through a warning, never resolve a "conflict" by
guessing — a human decides those.
