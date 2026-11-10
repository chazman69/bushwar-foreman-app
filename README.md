# BUSHWAR Foreman

One window for building the BUSHWAR Grand Reef map together without stepping on each
other. It wraps the whole session ritual — the same proven logic as the map repo's
`PICKUP.bat` / `PUTDOWN.bat`, plus live team status and a setup doctor.

**Install like a normal app:** run **`BUSHWAR-Foreman-Setup.exe`** (from
[the download page](https://github.com/chazman69/bushwar-foreman-app/releases/latest); no GitHub invite needed). It installs to a
per-user app directory, adds **Start Menu + Desktop icons and an Add/Remove Programs
entry** — users only ever see the app. Under the hood the install is a git clone, so
Foreman **self-updates on every launch**. Uninstall from Windows Settings → Apps, like
anything else.

*Dev path:* clone this repo and double-click `FOREMAN.exe` directly (`FOREMAN.bat` is the
fallback launcher). `tools\build-exe.ps1` rebuilds both exes from `tools\launcher.cs` +
`tools\setup.cs`; `tools\make-assets.ps1` regenerates the icon/logo from the official
mark (`assets\bw-mark.png`).

---

## What it does

| Button | What happens |
|--------|--------------|
| **▶ START SESSION** | Refuses if Workbench is open or you have unshipped work → pulls the latest `master` → opens Workbench straight on the map (`-gproj`, found through your Steam libraries). You build directly on `master`. *The "pull first, then open Workbench" habit, enforced.* |
| **⬆ SHIP SESSION** | Scans your work and shows the plan: which sculpted tiles ship, which **save-churn tiles get auto-discarded** (Workbench rewrites all ~1,155 tiles on save — shipping that collides with everyone), and that the shared index (`resourceDatabase.rdb`) is kept out (it can't merge; Workbench regenerates it). On **Confirm**, before anything is filtered, it **backs up your whole session**: a local git ref *and* a hidden backup on GitHub (see *Getting work back*); no backup, no ship. Then the **STICK GATE**: if you changed a base layer while someone else holds the layer stick, the ship waits (nothing dropped) until they hand it back. **Every real layer edit ships**, whatever name is on the layer — layers have no owners; the only layer change left out is a Workbench re-save whose content is **identical** to master's (compared entity by entity to 1 mm, never by count). The **PREFAB GUARD** checks **every** layer you changed for objects that lost their prefab link (what Workbench does when an addon the map depends on, usually the Fireforce props pack, is missing or out of date on your machine: the objects turn into invisible empty entities and the next ship wipes them for the whole team). A prefab-less object that carries its own mesh (a raw `.xob` placed as a GenericEntity, like modular walls or windows) is deliberate work, not an empty entity, and never trips it (v0.26.2). It offers **REPAIR** (re-attach the links from the copy on `master`, keep the rest of your session) or **DISCARD** (back to master's copy), and there is **no ship-anyway**. Type a one-liner, **Confirm** → commit, **push straight to `master`** — no review step, no PR. If a teammate shipped seconds earlier, their work is slotted underneath yours automatically; a genuine same-file conflict stops dead for a human, with your work committed on your machine. |
| **✋ TAP IN / TAP OUT** | The **LAYER STICK**: one person in the base layers at a time (`default`, `Forests`, `Vegetation`, `Water` and the road layers `Roads1/2`, `Dirt1/2`, `Footpaths1/2`). They are one unmergeable file each, so two people's edits to one can't be combined and somebody redoes their work by hand. TAP IN puts your name in `collaboration/LAYER-STICK.md` on `master`. **While you hold it, nobody else's base-layer edits can ship** (theirs wait on their PC; nothing is dropped), and anyone who changes a base layer anyway gets a warning within ~30 s of saving. **Shipping hands the stick back automatically.** Stick free when you ship? Your base-layer edits just ship. Tapping out never drops anything. If a teammate holds it, the button says who. Tapping in refuses on a stale copy. |
| **⟳ Refresh** | Re-reads your repo state, the ship plan, and the team panel. |
| **✚ Doctor** | Checks git, the repo, GitHub reachability, your git identity, the **Workbench junction** (the "Tools reads a stale copy" trap), **Workbench's last start** (if a recent Workbench log shows "Can't initialize engine" / the base game not found, START SESSION opens the project list instead and says to verify Tools in Steam; a clean or missing log means a normal direct launch), and **the dependency prefabs**: it reads every prefab path the world layers use, including inside packed Workshop addons (`data.pak`), and names any folder (`ModularStructurePieces/`, `Agricultural/`, …) it can't find on your machine, i.e. a missing or out-of-date props pack, *before* Workbench can strip anything. START SESSION runs the same check after pulling. |

## Getting work back

Since v0.26 (2026-10-20) Foreman backs up everything you haven't shipped, **twice**, before
it pushes, pulls over, repairs or drops anything:

- **On this PC:** a local git ref, `refs/foreman/safety/<yyyyMMdd-HHmmss>` (newest 60 kept).
- **On GitHub:** the same snapshot pushed as `refs/backup/<your git name>/<yyyyMMdd-HHmmss-ms>`
  (newest 60 per person kept). It is **not a branch**: it doesn't show in GitHub's branch
  list and normal clones never download it, but anyone on the team can fetch it, so work
  survives a dead PC.

When: before every **SHIP** (no backup, no ship), before **START** lands a leftover commit,
before a **stick tap**, right after **Workbench closes**, and **every 30 minutes** while
Foreman is open and you have unshipped work (`backup.autoMinutes` in `foreman.config.json`).
Snapshots leave out only terrain-tile save noise and the resource index. Each PC can only
back up its own work, so **keep Foreman open while you build**. **Doctor** shows both counts.
PUTDOWN backs up the same way.

```
# this PC
git -C <map clone> for-each-ref refs/foreman/safety/
git -C <map clone> checkout refs/foreman/safety/<stamp> -- <path/to/file.layer>

# GitHub (any PC, anyone's backups)
git -C <map clone> ls-remote origin "refs/backup/*"
git -C <map clone> fetch origin refs/backup/<name>/<stamp>
git -C <map clone> show --stat FETCH_HEAD
git -C <map clone> checkout FETCH_HEAD -- <path/to/file.layer>
```

*Why it exists:* up to v0.25 SHIP judged a base-layer change by entity **count**, and
reverted it silently when the count matched and you didn't hold the stick. Moving a road's
spline points or nudging a building keeps the count, so those edits vanished; that is how
Joe's road fixes on Mike's side were lost on 2026-10-18. v0.26 compares content instead,
drops no real edit, has no layer owners, and keeps every session recoverable off the PC.

**The team panel** shows: stray branches (old unshipped work — should be empty), the last
commits landed on `master` (the team's changelog), who holds the **layer stick** (base
layers), and any WORLD-LOCK claims (global terrain passes).

**Workbench indicator** (top right) goes orange while Tools is running — START/SHIP
refuse to run until it's closed, because Workbench only reads files at load and keeps
writing them until it exits.

## First run

1. Clone this repo anywhere (GitHub Desktop: *File → Clone repository*).
2. Double-click **`FOREMAN.bat`**.
3. If it can't find your map repo clone automatically, it offers to download it (or lets
   you point at the `fireforce` folder once; saved to `%LOCALAPPDATA%\BushwarForeman\local.json`).
4. On every launch it links Workbench to that clone by itself
   (`addons\Grand Reef` → `<clone>\map`, a junction, no admin rights). Existing links of
   either shape (to the repo root or to `map`) are left alone, and a link whose clone was
   moved or deleted is replaced. Only a stale duplicate folder needs a click: Doctor moves
   it to `ArmaReforgerWorkbench\addons_STALE_BACKUP\` (nothing is deleted).

## The ritual (unchanged, just automated)

**START SESSION → build in Workbench (stay inside your team-agreed boundary and your own
named layer — honor system, no overlap) → save / regen normal map / save → close Workbench
→ SHIP SESSION → drop a one-liner in chat.**

*(No in-engine tile claiming, and no pull request — SHIP lands straight on `master`. If two
people ever touch the same tile, SHIP catches it and stops.)*

Rules of the road live in the map repo:
[`collaboration/`](https://github.com/chazman69/fireforce/tree/master/collaboration)
(lanes, terrain-sculpting model, WORLD-LOCK).

## For other projects (the framework part)

Everything project-specific lives in **`foreman.config.json`** — repo URL, default
branch, the terrain tile pattern, the never-commit list, the WORLD-LOCK path. Point it
at a different Reforger team repo and Foreman runs that project's ritual instead.

## Dev notes

- Single-file Windows PowerShell 5.1 + WPF (`src/foreman.ps1`). No dependencies.
- Headless check: `powershell -STA -File src\foreman.ps1 -SmokeTest` (loads config,
  git, XAML, computes a real ship plan — no window).
- The churn/ship rules come from the live two-builder test of 2026-07-06 (see the map
  repo's `collaboration/terrain-sculpting.md` §gate for the recorded findings). If the
  build side (Joe) revises the churn heuristic, update `Get-ShipPlan` **and** the map
  repo's `putdown.ps1` together.
