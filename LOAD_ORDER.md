# DCS Server Core — Mission Editor Load Order

All scripts are loaded via **Mission Editor → Triggers → ONCE at mission start**.
Use a separate trigger action per file with incrementing **Time More** values.

## Required External Scripts (obtain separately)

| Script | Source | Required? |
|---|---|---|
| `mist.lua` | [MIST GitHub](https://github.com/mrSkortch/MissionScriptingTools) | **Yes** |
| `iads_v1_r37.lua` | [Hoggit IADS Docs](https://wiki.hoggitworld.com/view/IADScript_Documentation) | No (IADS features) |
| `ctld.lua` | [ciribob CTLD](https://github.com/ciribob/DCS-CTLD) | No (CTLD features) |
| `ArtilleryEnhancement.lua` | ED Forums (Grimes) | No (enhanced arty AI) |

## Trigger Setup

Create one trigger per row.  All are **ONCE / Time More**.

```
Time  Action               File
────  ───────────────────  ───────────────────────────────────────
 1 s  DO SCRIPT FILE       mist.lua
 2 s  DO SCRIPT FILE       iads_v1_r37.lua          (optional)
 3 s  DO SCRIPT FILE       ctld.lua                 (optional)
 4 s  DO SCRIPT FILE       ArtilleryEnhancement.lua (optional)
 5 s  DO SCRIPT FILE       scripts/utils.lua
 6 s  DO SCRIPT FILE       scripts/config.lua
 7 s  DO SCRIPT FILE       scripts/iads_manager.lua
 8 s  DO SCRIPT FILE       scripts/suppression.lua
 9 s  DO SCRIPT FILE       scripts/ctld_config.lua
10 s  DO SCRIPT FILE       scripts/artillery_manager.lua
11 s  DO SCRIPT FILE       scripts/server_core.lua
```

> **Tip:** Place all `.lua` files in the same folder as your `.miz` file, or
> use absolute paths if your server has a fixed Saved Games directory.

## Minimum Viable Load (no external scripts)

If you only have MIST and want suppression + built-in counter-battery:

```
1 s   mist.lua
5 s   scripts/utils.lua
6 s   scripts/config.lua
8 s   scripts/suppression.lua
10 s  scripts/artillery_manager.lua
11 s  scripts/server_core.lua
```

Modules not loaded will be silently skipped by `server_core.lua`.

## Configuration Checklist

After installing, edit **`scripts/config.lua`**:

1. **IADS** — add your SAM group name prefixes to `cfg.iads.redPrefixes`
2. **Suppression** — adjust `baseHoldTime` / `maxHoldTime` to taste
3. **CTLD** — add helicopter unit names and trigger zone names
4. **Artillery** — add battery group names, spotter unit names, radar unit names

## Cross-System Integration Map

```
SEAD missile fired
  └─► iads_manager: SAM scatters + radar off (Smarter SAM)
        └─► suppression: if SAM group also takes a hit,
                         dark window is extended further

Ground unit hit
  └─► suppression: ROE → WEAPON_HOLD for baseHoldTime
        └─► iads_manager: if the unit is a SEAD-evading SAM,
                           dark window extended

Artillery shell fires
  └─► artillery_manager: battery records lastFired
        └─► displacement timer starts

Artillery shell impacts a unit
  └─► artillery_manager: CB radar detects origin
        ├─► suppression: units near impact suppressed (cbHoldTime)
        ├─► ctld_config: warns if drop zone is within 2 km
        └─► artillery_manager: nearest friendly battery fires CB mission

CTLD troop drop (ciribob or fallback)
  └─► ctld_config: onTroopDropHook
        └─► suppression: enemies within 500 m suppressed 20 s
```

## F10 Admin Menu (BLUE coalition)

Enable with `cfg.admin.f10MenuBlue = true` in `config.lua`.

```
[ADMIN] Server Core
  ├── IADS
  │     ├── Status
  │     ├── Set level 1 / 2 / 3 / 4
  ├── Suppression
  │     ├── Status
  │     └── Toggle on/off
  ├── Artillery
  │     ├── Battery Status
  │     └── Pending CB Shells
  └── CTLD
        └── Lift Manifest
```
