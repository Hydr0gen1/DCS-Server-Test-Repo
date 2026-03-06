# DCS Server Core — Mission Editor Load Order

All scripts are loaded via **Mission Editor → Triggers → ONCE at mission start**.
Use a separate trigger action per file with incrementing **Time More** values.

## Required External Scripts (obtain separately)

| Script | Source | Required? |
|---|---|---|
| `mist.lua` | [MIST GitHub](https://github.com/mrSkortch/MissionScriptingTools) | **Yes** |
| `MOOSE.lua` | [MOOSE GitHub](https://github.com/FlightControl-Master/MOOSE) | No (Zone Capture features) |
| `Moose_DualCoalitionZoneCapture.lua` | [iTracerFacer GitHub](https://github.com/iTracerFacer/Moose_DualCoalitionZoneCapture) | No (Zone Capture features) |
| `Moose_DynamicGroundBattle_Plugin.lua` | Same repo as above | No (dynamic ground spawns) |
| `ctld.lua` | [ciribob CTLD](https://github.com/ciribob/DCS-CTLD) | No — but strongly recommended |
| `iads_v1_r37.lua` | [Hoggit IADS Docs](https://wiki.hoggitworld.com/view/IADScript_Documentation) | No (IADS features) |
| `ArtilleryEnhancement.lua` | ED Forums (Grimes) | No (enhanced arty AI) |

Audio files required by CTLD: `beacon.ogg`, `beaconsilent.ogg` — add to mission archive.

## Trigger Setup

Create one trigger per row. All are **ONCE / Time More**.

```
Time  Action               File
────  ───────────────────  ─────────────────────────────────────────────
 1 s  DO SCRIPT FILE       mist.lua
 2 s  DO SCRIPT FILE       MOOSE.lua                    (optional — zone capture)
 3 s  DO SCRIPT FILE       iads_v1_r37.lua              (optional)
 4 s  DO SCRIPT FILE       ctld.lua                     (optional)
 5 s  DO SCRIPT FILE       ArtilleryEnhancement.lua     (optional)
 6 s  DO SCRIPT FILE       Moose_DualCoalitionZoneCapture.lua    (optional)
 7 s  DO SCRIPT FILE       Moose_DynamicGroundBattle_Plugin.lua  (optional)
 8 s  DO SCRIPT FILE       scripts/utils.lua
 9 s  DO SCRIPT FILE       scripts/config.lua
10 s  DO SCRIPT FILE       scripts/iads_manager.lua
11 s  DO SCRIPT FILE       scripts/suppression.lua
12 s  DO SCRIPT FILE       scripts/ctld_config.lua
13 s  DO SCRIPT FILE       scripts/ctld_logistics.lua
14 s  DO SCRIPT FILE       scripts/artillery_manager.lua
15 s  DO SCRIPT FILE       scripts/credits.lua
16 s  DO SCRIPT FILE       scripts/zone_capture.lua     (optional — zone capture)
17 s  DO SCRIPT FILE       scripts/server_core.lua
```

> **Tip:** Place all `.lua` files in the same folder as your `.miz`, or use
> absolute paths if the server has a fixed Saved Games directory.
>
> **MOOSE note:** MOOSE.lua is large (~5 MB). It must load before
> `Moose_DualCoalitionZoneCapture.lua`. Give MOOSE a 1–2 s head-start if
> you observe initialisation errors.

## Minimum Viable Load (no external scripts)

Suppression + built-in counter-battery only:

```
1 s   mist.lua
8 s   scripts/utils.lua
9 s   scripts/config.lua
11 s  scripts/suppression.lua
14 s  scripts/artillery_manager.lua
17 s  scripts/server_core.lua
```

Modules not loaded are silently skipped by `server_core.lua`.

## Configuration Checklist (`scripts/config.lua`)

| Section | Key things to fill in |
|---|---|
| `cfg.iads` | `redPrefixes` — SAM group name prefixes |
| `cfg.ctld` | `blueTransports`, `bluePickupZones`, `blueDropZones` |
| `cfg.artillery` | `blueBatteries`, `blueSpotters`, `blueRadars` |
| `cfg.logistics` | `blueHQZones`, convoy templates, `batteryStartingRounds` |

## CTLD Zone Setup (Mission Editor)

For each zone listed in `cfg.ctld.*Zones`, create a **Trigger Zone** in the ME
with the exact same name. Zones needed:

| Purpose | Config key | Example zone name |
|---|---|---|
| Troops & crates available | `bluePickupZones` | `CTLD_Blue_Pickup_1` |
| Troop unload / FOB site | `blueDropZones` | `CTLD_Blue_Drop_1` |
| Troop patrol objective | `blueWaypointZones` | `CTLD_Blue_WP_1` |
| Supply convoy origin | `blueHQZones` | `Blue_HQ_Zone_1` |

## Logistics System Overview

### Battery Ammo Pool
- Each battery starts with `batteryStartingRounds` rounds.
- Every `artillery_manager.fireMission()` call deducts from the pool.
- A battery at zero rounds ("Winchester") refuses further fire missions.
- Any supply truck (`M-818`, `KAMAZ`, `Ural-375`) within
  `supplyRadiusBattery` metres auto-resupplies the battery on the
  next 60-second poll.

### Supply Convoys
1. Player opens **F10 → Logistics → Dispatch Convoy → From \<HQ Zone\>**
2. A clone of the convoy template group spawns at the HQ zone and drives
   toward the nearest known FOB (or first drop zone as fallback).
3. On arrival it resupplies all batteries within `supplyRadiusFOB` metres.
4. If the convoy is destroyed en route, no resupply occurs.

### FOB Construction
1. CTLD pilots fly crates to a drop zone — `fobCratesRequired` crates needed.
2. After `fobBuildTime` seconds ciribob's script assembles the FOB.
3. `ctld_logistics` detects the new static object and records the FOB.
4. The FOB appears in **F10 → Logistics → FOB Status**.
5. Subsequent convoys can use the FOB as a resupply waypoint.

### JTAC Crate → Artillery Spotter
1. A JTAC crate (Hummer JTAC / SKP-11 / MQ-9 drone) is flown out and dropped.
2. After `jtacScanDelay` seconds the area is scanned for the assembled unit.
3. The found unit is registered with `ArtilleryEnhancement:addSpotter()` and
   `artillery_manager.addSpotter()` so it can direct counter-battery missions.
4. Appears in **F10 → Logistics → JTAC Status**.

### Deployed SAM → IADS Auto-Registration
1. A SAM-system crate (HAWK, Patriot, BUK, KUB, S-300, etc.) is assembled.
2. After `samBuildDelay` seconds the area is scanned for units with SAM
   radar attributes.
3. The found group is added to the IADS network via `iads.add()`.
4. IADS then manages its radar behaviour at the configured threat level.

### Pilot Extraction Zones
- When a player aircraft is killed, `ctld.createExtractZone()` is called
  at the crash site.
- CTLD-equipped helicopters can use the standard CTLD extract menu to
  recover the pilot.

## Full Cross-System Integration Map

```
SEAD missile fired
  └─► iads_manager: SAM scatters + radar off (Smarter SAM)
        └─► suppression: hit while evading → dark window extended

Ground unit hit
  └─► suppression: ROE → WEAPON_HOLD for baseHoldTime
        └─► iads_manager: SAM hit while evading → dark window extended

Artillery fired
  └─► artillery_manager: records shot, starts displacement timer
  └─► logistics: deducts rounds from battery pool
        └─► if Winchester: fire mission blocked, player notified

Artillery shell impacts
  └─► artillery_manager: CB radar detects origin
        ├─► suppression: units near impact suppressed
        ├─► ctld_logistics: warns if CTLD drop zone within 2 km
        └─► artillery_manager: nearest friendly battery fires CB mission

Supply truck near battery (every 60 s poll)
  └─► logistics: battery ammo restored if rounds < max

Supply convoy arrives at FOB
  └─► logistics: all batteries within supplyRadiusFOB resupplied

CTLD troop drop
  └─► ctld_config: onTroopDropHook
        └─► suppression: enemies within 500 m suppressed 20 s

CTLD SAM crate assembled (samBuildDelay after drop)
  └─► ctld_logistics: area scanned for SAM units
        └─► iads_manager: new SAM group added to IADS network

CTLD JTAC crate assembled (jtacScanDelay after drop)
  └─► ctld_logistics: area scanned for JTAC unit
        ├─► ArtilleryEnhancement: addSpotter()
        └─► artillery_manager: addSpotter()

Player aircraft killed
  └─► ctld_logistics: extraction zone created at crash site

─── Zone Capture (every pollInterval seconds) ─────────────────

Zone enters "Attacked" state
  └─► zone_capture: defenders inside zone suppressed (suppressDuration s)
  └─► zone_capture: attackCredits awarded to attacking coalition

Zone captured (coalition changes)
  └─► zone_capture: captureCredits awarded to capturing coalition
  └─► zone_capture: all-coalition outText broadcast
  └─► zone_capture: zone-specific SAM prefixes added to capturing side's IADS
  └─► zone_capture: logistics._checkFOBBuilt() called at zone position
  └─► zone_capture (if artilleryOnCapture=true):
        └─► artillery_manager.fireMission() on zone centre (nearest old-owner battery)
              └─► wireLogisticsAmmo: ammo deducted, Winchester check applied

Zone defended (Attacked → Guarded, same coalition)
  └─► zone_capture: defenseCredits awarded to defending coalition
```

## F10 Menu Layout

```
[ADMIN] Server Core          (BLUE coalition, admin only)
  ├── IADS
  │     ├── Status
  │     └── Set level 1 / 2 / 3 / 4
  ├── Suppression
  │     ├── Status
  │     └── Toggle on/off
  ├── Artillery
  │     ├── Battery Status
  │     └── Pending CB Shells
  ├── CTLD
  │     └── Lift Manifest
  ├── Logistics
  │     ├── Ammo Summary
  │     ├── SAM Ammo Summary
  │     └── FOB / Convoy Status
  ├── Zone Capture            (only present when zone_capture.lua is loaded)
  │     ├── Zone Status
  │     ├── Toggle Broadcasts
  │     ├── Toggle Suppress-on-Attack
  │     └── Toggle Arty Harassment
  └── Credits
        ├── Balance (both sides)
        ├── Add 100 to BLUE (admin)
        └── Add 100 to RED (admin)

Logistics                    (BLUE coalition, all players)
  ├── Ammo Status
  ├── SAM Status
  ├── FOB Status
  ├── JTAC Status
  ├── Dispatch Convoy
  │     └── From <HQ Zone 1>  …
  ├── Convoy Status
  └── Toggle Auto-Resupply

Credits                      (both coalitions, all players)
  ├── Balance
  └── How Credits Work

CTLD                         (built-in ciribob F10 menus)
  └── (standard CTLD menu — Actions, Load, Unload, Crates, etc.)
```
