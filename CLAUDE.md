# DCS World Mission Scripting — Project Context

This project involves DCS World mission scripting using Lua via the Simulator Scripting Engine (SSE).
The primary libraries and scripts referenced are: **MIST**, **IADScript**, **Baron's CSAR**, **Dynamic Medevac**,
**Dynamic Extraction Team**, **Smarter SAM**, **Suppression Fire Script**, and **Artillery Enhancement Script**.

---

## Simulator Scripting Engine (SSE) — Core API

### Singletons (single-instance globals)

| Singleton         | Purpose                                        |
|-------------------|------------------------------------------------|
| `env`             | Environment / logging                          |
| `timer`           | Mission time, scheduled functions              |
| `land`            | Terrain height queries                         |
| `atmosphere`      | Wind, temperature                              |
| `world`           | Event handlers, object search                  |
| `coalition`       | Get groups/units/airbases by coalition         |
| `trigger`         | Trigger actions (messages, smoke, flags, etc.) |
| `coord`           | Coordinate conversion (LL ↔ MGRS ↔ vec3)       |
| `missionCommands` | Add F10 menu commands                          |
| `net`             | Multiplayer network functions                  |

### Class Hierarchy

```
Object
├── Scenery Object
└── Coalition Object
    ├── Unit
    ├── Airbase
    ├── Weapon
    ├── Static Object
    ├── Group
    ├── Controller
    ├── Spot
    └── Warehouse
```

### Key Enumerators

- `country.*` — Country IDs
- `AI.Option.Ground.id.*` / `AI.Option.Ground.val.*` — AI behavior options
- `AI.Option.Air.id.*` / `AI.Option.Air.val.*`
- `world.event.*` — Event IDs (e.g. `S_EVENT_SHOT`, `S_EVENT_HIT`, `S_EVENT_DEAD`)
- `coalition.side.*` — BLUE, RED, NEUTRAL
- `radio.*` — Radio modulation types
- `trigger.smokeColor.*` — Smoke colors (0=Green, 1=Red, 2=White, 3=Orange, 4=Blue)

### Commonly Used SSE Patterns

```lua
-- Get unit/group by name
local unit = Unit.getByName("UnitName")
local group = Group.getByName("GroupName")

-- Get unit position
local pos = unit:getPosition().p  -- Vec3 {x, y, z}  (y = altitude)

-- Trigger actions
trigger.action.outText("Message", 10)          -- display text 10s
trigger.action.smoke(vec3, trigger.smokeColor.Green)
trigger.action.setUserFlag("flagName", true)
trigger.action.getUserFlag("flagName")

-- Timer
timer.scheduleFunction(myFunc, args, timer.getTime() + delay)
timer.getTime()  -- seconds since mission start

-- Event handler
local handler = {}
function handler:onEvent(event)
  if event.id == world.event.S_EVENT_SHOT then
    local weapon = event.weapon
    local shooter = event.initiator
  end
end
world.addEventHandler(handler)

-- Controller / AI behavior
local ctrl = group:getController()
ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.OPEN_FIRE)
ctrl:setOption(AI.Option.Ground.id.ALARM_STATE, AI.Option.Ground.val.ALARM_STATE.RED)
-- ALARM_STATE: GREEN=0, YELLOW=1 (auto), RED=2

-- Get coalition units
coalition.getGroups(coalition.side.BLUE)
coalition.getPlayers()
```

---

## MIST (Mission Scripting Tools) — v4.5

**Dependency:** None. Load via `DO SCRIPT FILE` at mission start (Time More: 1 sec).
Always load MIST *before* any script that depends on it (Time More: 2 sec for dependent scripts).
MIST is too large for `DO SCRIPT` text box — must use `DO SCRIPT FILE`.

**Reference:** https://wiki.hoggitworld.com/view/Mission_Scripting_Tools_Documentation

### Function Categories

#### General Purpose

```lua
mist.makeUnitTable({'UnitName1', 'UnitName2'})
mist.getRandPointInCircle(center_vec3, radius)
mist.getRandomPointInZone(zoneName)
mist.getUnitsInZones(unitTable, zoneNames)
mist.getUnitsInMovingZones(unitTable, zoneUnitTable, radius)
mist.getUnitsLOS(unit1, unit2)
mist.getGroupsByAttribute(attribute)  -- e.g. 'Air', 'Ground', 'Ship'
mist.getUnitsByAttribute(attribute)
```

#### Flag Functions (no deep Lua knowledge needed)

```lua
mist.flagFunc.units_in_zones {
  units = {'UnitName1', 'UnitName2'},
  zones = {'ZoneName'},
  flag = 5000,
  stopflag = 15
}

mist.flagFunc.units_in_moving_zones {
  units = {'UnitName'},
  zone_units = {'AnchorUnit'},
  radius = 50,
  flag = 5001,
  stopflag = 15
}

mist.flagFunc.group_alive { group = 'GroupName', flag = 100 }
mist.flagFunc.group_dead  { group = 'GroupName', flag = 101 }
mist.flagFunc.group_alive_more_than { group = 'GroupName', num = 2, flag = 102 }
```

#### Unit Orientation

```lua
mist.getHeading(unit)           -- returns heading in radians
mist.getNorthCorrection(vec3)   -- magnetic declination
mist.getAttitude(unit)          -- pitch, roll, yaw
```

#### Coordinate Conversion

```lua
mist.makeVec2(x, y)
mist.makeVec3(x, y, z)
mist.zoneToVec3(zoneName)
mist.vecToWP(vec3, altitude, speed)   -- convert vec3 to waypoint table
```

#### Unit/Value Conversion

```lua
mist.utils.metersToNM(m)
mist.utils.metersToFeet(m)
mist.utils.mpsToKnots(mps)
mist.utils.toDegree(radians)
mist.utils.toRadian(degrees)
```

#### Group Orders

```lua
mist.groupToPoint(group, vec3)
mist.groupToRandomZone(group, zoneName)
mist.groupRandomDistSelf(group, dist, formation, maxOffset, minOffset)
mist.patrolRoute(group)
```

#### Group Data

```lua
mist.getGroupData(groupName)         -- full group data table
mist.getCurrentGroupData(groupName)  -- live position data
mist.getGroupRoute(groupName)
mist.groupIsDead(groupName)          -- returns true/false
```

#### Group Spawning

```lua
mist.dynAdd(groupData)               -- spawn group from data table
mist.dynAddStatic(staticData)
mist.cloneGroup(groupName, {x=..., y=...})
mist.cloneInZone(groupName, zoneName)
mist.teleportGroup(groupName, vec3)
mist.respawnGroup(groupName)
mist.getNextGroupId()
mist.getNextUnitId()
```

#### Scheduling / Events

```lua
mist.scheduleFunction(func, args, time)  -- one-shot schedule
mist.removeFunction(functionId)
mist.addEventHandler(handler)
mist.removeEventHandler(handler)
```

#### Messaging

```lua
mist.message.add({
  text = 'Hello',
  displayTime = 10,
  msgFor = {coa = {'blue'}},  -- or {units = {'UnitName'}}, {groups = {'GroupName'}}
})
mist.message.removeById(id)
```

#### Strings / Coordinates

```lua
mist.tostringMGRS(vec3, accuracy)
mist.tostringLL(vec3, DMS)    -- DMS=true for deg/min/sec, false for decimal
mist.tostringBR(fromVec3, toVec3)
mist.getMilString(degrees)    -- military mils
```

---

## IADScript (Integrated Air Defense Script) — v1 rev35/37

**Dependency:** MIST 4.0+. Load after MIST.
**Docs:** https://wiki.hoggitworld.com/view/IADScript_Documentation

### Setup

```lua
-- Load order in ME triggers:
-- Time More 1: DO SCRIPT FILE  → mist.lua
-- Time More 2: DO SCRIPT FILE  → iads_v1_r37.lua
-- Time More 3: DO SCRIPT       → iads setup lines

-- Add SAM sites
iads.add('SAM Group Name')
iads.addByPrefix('SA-6')     -- adds all groups whose name starts with prefix
iads.addAllByPrefix('SA')    -- adds all matching groups
```

### Settings (defined at top of iads lua file)

```lua
iads.settings = {
  level = 3,           -- 1-4 (1=always on, 4=most intelligent; 5=not implemented)
  linked = 'coalition', -- or 'country'
  radarSim = true,     -- check based on radar dish scan speed
  refreshRate = 15,    -- seconds between checks (when radarSim=false)
  addDuplicate = 'replace', -- or 'ignore'
  debug = false,
  debugMsgFor = {'all'},   -- {'blue'}, {'red'}
  debugWriteFiles = false,
  timeDelay = 10,      -- seconds after mission start before script activates
}
```

### Threat Levels

- `1` — All SAMs forced to search, lock/engage if in range
- `2` — Pure randomization (~50% off, 50% on/locking)
- `3` — Intelligent: larger SAMs search, smaller shut down; advanced tactics
- `4` — SAMs coordinate with each other based on radar coverage overlap

### Tips

- One SAM type per group (script not designed for mixed groups)
- IR missiles and AAA do NOT need to be added to IADS
- Do NOT use with regular ground forces — only dedicated SAM/radar groups
- Ships are not supported
- Test with `debug = true` to see status messages on screen

### Member Functions

```lua
iads.add(name, [relationship])
iads.destroy(iadsObj)
iads.goDark(iadsObj)       -- turn off radar
iads.search(iadsObj)       -- radar searching
iads.engage(iadsObj)       -- active engagement mode
iads.blink(iadsObj)        -- turn radar on/off rapidly
iads.displace(iadsObj)     -- move to random position
iads.displaceNearPoint(iadsObj, vec3, dist)
iads.getTracks(iadsObj)
iads.getStatus(iadsObj)
iads.checkToEngage(iadsObj)
```

---

## Baron's CSAR Script

**Dependency:** Slmod (server-side mod required on hosting machine).

### Key Config Variables

```lua
CSARMAXACTIVE = 2           -- max simultaneous CSAR helicopters
CSARRESCUEDISTANCE = 100    -- meters, radius for pilot pickup
CSARINSIGHTDISTANCE = 3000  -- meters, triggers 'in sight' message
CSARMAXAGL = 10             -- max altitude (meters AGL) for pickup
CSARMAXSPEED = 1            -- max speed (m/s) for pickup
CSARFLAREINTVL = 12         -- seconds between pilot flares
SMOKEINTVL = 270            -- seconds between smoke markers
NOEJECTPUNISHTIME = 300     -- seconds slot stays deactivated if no eject before rescue
CSARATTACKINGPUNISHTIME = 1800
ATTACKCSARPUNISHTIME = 1800
ATTACKFRIENDLYPUNISHTIME = 900
UNITSSTARTINGFLAG = 11000   -- flags used internally start here (needs 5 per monitored unit)
FLAGALWAYSFALSE = 10999
MESSAGESOUNDFILE = 'static.ogg'
```

### Setup in Mission Editor

1. Create trigger zones around all FARPs and airbases (landing zones)
2. Define `units` table: combat aircraft with `name`, `nameLong`, `nameShort`, `category`
3. Define `csar` table: rescue helicopters with `name`, `nameShort`, `rescueLimit`
4. Define `AIRFIELDS` table: `zone`, `category`, `capturable`, `flag`

### Pickup Requirements

- Distance from pilot < 100m
- Altitude (AGL) < 10m
- Speed < 1 m/s

### Chat Commands

- `-stl` — list deactivated slots and downed pilot locations

---

## Dynamic Medevac Script — v4.2

**Dependency:** MIST 3.0+ (v4.2+). Load MIST first, then Medevac.lua.
**GitHub:** https://github.com/RagnarDa/DCS-Mission-Scripts/tree/master/Medevac

### Key Config

```lua
medevac.medevacunits = {'HueyName1', 'HueyName2'}  -- unit names of medevac helicopters
medevac.bluemash = Unit.getByName("BlueMASH")       -- hospital unit, blue side
medevac.redmash = Unit.getByName("RedMASH")         -- hospital unit, red side
medevac.maxbleedtime = 600          -- seconds before casualty dies
medevac.bluesmokecolor = 0          -- 0=green, 1=red, 2=white, 3=orange, 4=blue
medevac.redsmokecolor = 1
medevac.requestdelay = 30           -- seconds before survivors call for help
medevac.coordtype = 2               -- 0=LL DMTM, 1=LL DMS, 2=MGRS, 3=Bullseye
medevac.displaymapcoordhint = true
medevac.bluecrewsurvivepercent = 50
medevac.redcrewsurvivepercent = 50
medevac.showbleedtimer = false
medevac.sar_pilots = true           -- enable SAR for downed pilots
medevac.clonenewgroups = false      -- respawn destroyed groups after rescue
```

### Behavior

- When a ground vehicle is destroyed, infantry spawns representing the crew
- Medevac notification sent with coordinates and smoke
- Pilot must fly to casualties, pick up, and deliver to MASH before bleed timer expires
- Multiple MASH units supported (one per side minimum)
- Known issue: Lat/Long coordinates broken; use MGRS or Bullseye instead

### ME Setup

1. Time More 1s → DO SCRIPT FILE: mist.lua
2. Time More 2s → DO SCRIPT FILE: Medevac.lua (or via initialization script)
3. Add MASH unit(s) — live ground unit, named exactly as in config
4. Add MEDEVAC helicopter units, named exactly as in `medevac.medevacunits`

---

## Dynamic Extraction Team Script

**Dependency:** MIST. Load MIST first.
**Author:** Psyrixx. **GitHub:** https://github.com/Psyrixx/dcsw-dynamic-extraction-team

### Behavior

- Extraction team spawns dynamically at helicopter's location when it lands
- Team spawns on the side of the Huey closest to the objective
- Team navigates to asset/objective, waits, then returns to helicopter for pickup
- Group deactivates (simulates pickup) rather than being killed
- Helicopter must be on the ground and stopped before team spawns

### Key MIST Functions Used

```lua
mist.flagFunc.units_in_zones { units, zones, flag, stopflag }
mist.flagFunc.units_in_moving_zones { units, zone_units, radius, flag, stopflag }
mist.getHeading(unit)
-- Spawning via groupData table with mist.dynAdd()
```

### Waypoint Data Pattern (used in many spawn scripts)

```lua
local groupData = {
  name = "GroupName",
  groupId = math.random(1111111, 9999999),
  hidden = false,
  units = {
    [1] = {
      x = spawnX,
      y = spawnZ,   -- NOTE: DCS uses x/z for ground position, y for altitude
      type = "Soldier M4",
      name = "UnitName",
      unitId = math.random(1111111, 9999999),
      heading = heading,
      skill = "Average",
      playerCanDrive = true,
    }
  },
  x = spawnX,
  y = spawnZ,
  start_time = 0,
  task = "Ground Nothing",
}
mist.dynAdd(groupData)
```

---

## Smarter SAM Script

**Dependency:** None (MIST optional for movement functions).

### Behavior

Detects SEAD missile launch events, causes targeted SAM to:

1. Randomly disperse (using `mist.groupRandomDistSelf`)
2. Set alarm state to GREEN (radar off)
3. After random delay (5–15s), restore alarm state to RED

### Core Pattern

```lua
local SEAD_launch = {}
function SEAD_launch:onEvent(event)
  if event.id == world.event.S_EVENT_SHOT then
    local weapon = event.weapon
    local missileName = weapon:getTypeName()
    -- Check if SEAD missile (AGM-88, KH-58, KH-25MPU, etc.)
    if missileName == "AGM_88" or missileName == "KH-58" then
      local targetUnit = Weapon.getTarget(weapon)
      local targetGroup = Unit.getGroup(targetUnit)
      local ctrl = targetGroup:getController()
      -- Scatter + go dark
      mist.groupRandomDistSelf(targetGroup, 300, 'Rank', 250, 20)
      ctrl:setOption(AI.Option.Ground.id.ALARM_STATE,
                     AI.Option.Ground.val.ALARM_STATE.GREEN)
      -- Schedule radar back on
      local delay = math.random(5, 15)
      timer.scheduleFunction(function()
        ctrl:setOption(AI.Option.Ground.id.ALARM_STATE,
                       AI.Option.Ground.val.ALARM_STATE.RED)
      end, nil, timer.getTime() + delay)
    end
  end
end
world.addEventHandler(SEAD_launch)
```

### Known SEAD Missile Type Names (DCS internal)

`"AGM_88"`, `"KH-58"`, `"KH-25MPU"`, `"AGM-45"`, `"ALARM"`, `"Kh-31P"`

---

## Suppression Fire Script

**Dependency:** None. Load once via `DO SCRIPT` or `DO SCRIPT FILE`.
**Affects:** Infantry, MANPADS, ZU-23, Ural-375 ZU-23

### Behavior

- Any hit on a suppressed unit type sets ROE to **Hold Fire** for ~15 seconds
- Subsequent hits extend suppression (with diminishing returns)
- After suppression ends: ROE returns to **Open Fire**
- Uses `S_EVENT_HIT` to detect impacts

### Key Config

```lua
local delay = math.random(15, 80)  -- randomize suppression duration (default base: 15s)
```

### Suppression Pattern

```lua
local function onHit(event)
  if event.id == world.event.S_EVENT_HIT then
    local target = event.target
    if target and target:getCategory() == Object.Category.UNIT then
      local group = target:getGroup()
      local ctrl = group:getController()
      ctrl:setOption(AI.Option.Ground.id.ROE,
                     AI.Option.Ground.val.ROE.WEAPON_HOLD)
      timer.scheduleFunction(function()
        ctrl:setOption(AI.Option.Ground.id.ROE,
                       AI.Option.Ground.val.ROE.OPEN_FIRE)
      end, nil, timer.getTime() + 15)
    end
  end
end
```

---

## Artillery Enhancement Script

**Dependency:** None. Load via `DO SCRIPT FILE`.
**Note:** Script is "as-is" — DCS 1.24+ increased direct fire range, which can break script control of artillery units.

### Features

- **Spotters:** Any unit (incl. aircraft/helos) can autonomously detect and prioritize targets
- **Firing Batteries:** Artillery groups that answer fire missions
- **Counterfire Radars:** Detect incoming shells, direct counter-battery fire
  - AN/TPQ-36, AN/TPQ-37 (US), ARK-1M Rys (Soviet) modeled
- **Survivability:** Artillery displaces after fire missions or when under fire
- **Nuclear Artillery:** M109 (W48, 0.072kt), 2S3/2S19 (ZBV3, 1kt)
- **Chain of command:** Hierarchy levels for centralized/decentralized fire support

### Basic Setup

```lua
-- Define a firing battery
ArtilleryEnhancement:addFiringBattery('BatteryGroupName')

-- Define a spotter
ArtilleryEnhancement:addSpotter('SpotterUnitName')

-- Define a counterfire radar
ArtilleryEnhancement:addCounterfireRadar('RadarUnitName', 'AN/TPQ-37')

-- Add nuclear shells to a battery
ArtilleryEnhancement:addNuclearShells('BatteryGroupName', 'W48')
```

---

## Common Patterns & Gotchas

### Coordinate System

- DCS uses **x** (north), **y** (altitude), **z** (east) — NOT standard x/y/z
- When working with 2D ground positions: use `vec.x` and `vec.z`
- `unit:getPosition().p` returns the Vec3 world position

### Safe Group/Unit Access

```lua
-- Always check existence before calling methods
local unit = Unit.getByName("Name")
if unit and unit:isExist() then
  -- safe to use
end
```

### Script Loading Order in ME

```
Time More 1s  → DO SCRIPT FILE: mist.lua          (always first if MIST needed)
Time More 2s  → DO SCRIPT FILE: iads.lua / medevac.lua / etc.
Time More 3s  → DO SCRIPT: configuration / setup calls
```

### Flag Management

- CSAR script uses 5 flags per monitored unit starting at `UNITSSTARTINGFLAG`
- Set a flag that's always false: `trigger.action.setUserFlag('FLAGALWAYSFALSE', false)`
- Check flags with `trigger.misc.getUserFlag(flagName)` (returns number, not bool)

### ROE Options

```lua
AI.Option.Ground.val.ROE.OPEN_FIRE        -- engage at will
AI.Option.Ground.val.ROE.RETURN_FIRE      -- only return fire
AI.Option.Ground.val.ROE.WEAPON_HOLD      -- suppressed / hold fire
AI.Option.Ground.val.ROE.OPEN_FIRE_WEAPON_FREE  -- unrestricted
```

### Alarm State Options

```lua
AI.Option.Ground.val.ALARM_STATE.AUTO   -- 0 (game decides)
AI.Option.Ground.val.ALARM_STATE.GREEN  -- 1 (radar off, passive)
AI.Option.Ground.val.ALARM_STATE.RED    -- 2 (fully alert, radar on)
```

---

---

## This Repository — DCS Server Core

### Architecture

All modules hang off a single global namespace table:

```lua
DCSCore = {
    utils      = {},   -- shared helpers (utils.lua)
    config     = {},   -- mission config  (config.lua)
    iads       = {},   -- IADS + SEAD evasion (iads_manager.lua)
    suppression= {},   -- suppression fire (suppression.lua)
    ctld       = {},   -- CTLD wrapper (ctld_config.lua)
    logistics  = {},   -- supply chain, SAM ammo, convoys (ctld_logistics.lua)
    credits    = {},   -- resource economy (credits.lua)
    artillery  = {},   -- counter-battery (artillery_manager.lua)
}
```

`server_core.lua` is the entry point. It calls `*.setup()` on every module in the
correct order, then wires cross-system hooks via function wrapping.

### Load Order

```
 1s  mist.lua                        (required)
 2s  iads_v1_r37.lua                 (optional)
 3s  ctld.lua                        (optional — ciribob CTLD)
 4s  ArtilleryEnhancement.lua        (optional)
 5s  scripts/utils.lua
 6s  scripts/config.lua
 7s  scripts/iads_manager.lua
 8s  scripts/suppression.lua
 9s  scripts/ctld_config.lua
10s  scripts/ctld_logistics.lua
11s  scripts/artillery_manager.lua
12s  scripts/credits.lua
13s  scripts/server_core.lua
```

---

### scripts/utils.lua

Shared helpers used by every other module.  All other modules alias `DCSCore.utils`
to a local `U`.

```lua
U.getUnit(name)                           -- nil-safe Unit.getByName + isExist check
U.getGroup(name)                          -- nil-safe Group.getByName + isExist check
U.dist2D(v1, v2)                          -- XZ distance between two Vec3s
U.dist3D(v1, v2)                          -- full 3D distance
U.getZoneVec3(zoneName)                   -- trigger zone centre as Vec3
U.isUnitGrounded(unit, maxAGL, maxSpeed)  -- helicopter grounded check
U.getUnitsInRadius(point, radius, side)   -- world.searchObjects sphere, optional side filter
U.msgCoalition(side, text, duration)
U.schedule(func, delay, args)             -- wraps timer.scheduleFunction
U.tableContains(t, val)
U.tableLength(t)                          -- counts keys (works on non-sequential tables)
U.info / U.debug / U.error(msg)           -- respects cfg.admin.logLevel (0=off 1=err 2=info 3=debug)
```

---

### scripts/config.lua

Single file for all mission-specific settings.  Operators edit this file only.

| Section | Purpose |
|---|---|
| `cfg.admin` | Log level, F10 menu toggles, status broadcast interval |
| `cfg.iads` | IADS level, SAM group name prefixes, SEAD missile list |
| `cfg.smarterSAM` | SEAD scatter radius/formation, radar-off delay range |
| `cfg.suppression` | Hold time, max hold, extension per hit |
| `cfg.ctld` | Transports, zones, FOB/JTAC limits, hover params |
| `cfg.logistics` | Battery rounds, convoy templates, HQ zones, SAM ammo, credit costs, auto-resupply thresholds |
| `cfg.credits` | Starting balances, enabled flag |
| `cfg.artillery` | Battery/spotter/radar group names, CB suppression settings |

Key `cfg.logistics` fields added for v2:

```lua
cfg.logistics = {
    -- SAM ammo
    samAmmoEnabled            = true,
    samReloadDelay            = 60,     -- seconds before radar re-activates after resupply

    -- Credit costs
    manualConvoyCost          = 30,
    autoConvoyCost            = 50,
    samResupplyCost           = 75,

    -- Auto-resupply
    autoResupplyEnabled       = true,
    autoResupplyThreshold     = 0.25,   -- battery rounds/max below which auto triggers
    samAutoResupplyThreshold  = 0.25,   -- SAM missiles/max below which auto triggers
    maxAutoConvoysPerSide     = 2,
    autoResupplyCheckInterval = 120,    -- seconds between polls
}
```

---

### scripts/iads_manager.lua — `DCSCore.iads`

Wraps IADScript (`iads`) and adds Smarter SAM SEAD evasion.

```lua
IM.setup()                        -- reads cfg.iads, calls iads.addAllByPrefix for each prefix
IM.goDark(groupName, duration)    -- force radar off for N seconds
IM.extendDark(groupName, extra)   -- extend existing dark window
IM.isEvading(groupName)           -- returns true while radar is forced off

-- Internal state
IM._evading  = {}   -- groupName -> { until, timer }
IM._initialized = false

-- Event handler (S_EVENT_SHOT): detects SEAD missiles from cfg.smarterSAM.seadMissiles,
-- calls mist.groupRandomDistSelf on target group, sets ALARM_STATE GREEN,
-- schedules ALARM_STATE RED after random delay in [radarOffMinDelay, radarOffMaxDelay]
```

**Cross-hook (server_core):** If a hit arrives via `suppression._suppress` on a group
that `iads.isEvading()` returns true for, the dark window is extended by 15s.

---

### scripts/suppression.lua — `DCSCore.suppression`

`S_EVENT_HIT` → sets ROE `WEAPON_HOLD` with diminishing-returns extension.

```lua
SUP.setup()
SUP.suppressGroup(groupName, duration)  -- manual suppress (used by ctld_config troop drop hook)
SUP.isSuppressed(groupName)             -- queried by credits.lua for suppression-assist bonus
SUP.clearSuppression(groupName)

-- Internal state
SUP._state = {}  -- groupName -> { expiry, hitCount }
```

Config: `baseHoldTime` (15s default), `maxHoldTime` (80s), `holdExtension` (10s/hit).

---

### scripts/ctld_config.lua — `DCSCore.ctld`

Configures ciribob's CTLD with the real ciribob API and provides a MIST fallback.

**ciribob zone format** (positional, NOT key-value):
```lua
-- Pickup: { zoneName, smokeColor, limit, "active"|"no", side, [flagNum] }
-- Drop:   { zoneName, smokeColor, side }
-- Waypoint: { zoneName, smokeColor, "active"|"no", side }
-- side: 1=RED  2=BLUE  0=both
```

**Callbacks** registered via `ctld.addCallback(fn)`.  `args.eventType` values:
- `"unitLoaded"` / `"unitDropped"` / `"cratePickup"` / `"crateDropped"`

```lua
CT._active   = false   -- set true after setup()
CT._manifest = {}      -- pilotUnitName -> { side, loadType, loadCount }

CT.setup()
CT.fallbackDrop(pilotUnitName, templateName, side)  -- MIST-based fallback
CT.onTroopDropHook(pilotUnit, side)                 -- suppresses enemies within 500m of LZ
```

**Cross-hook:** `onTroopDropHook` is called by both the ciribob callback and
the fallback path; it calls `DCSCore.suppression.suppressGroup` on nearby enemies.

---

### scripts/ctld_logistics.lua — `DCSCore.logistics`

v2 — Supply chain, SAM missile tracking, smart auto-resupply.

#### State tables

```lua
LOG._batteries          = {}  -- groupName -> { side, rounds, maxRounds, lastResupply, status }
LOG._samAmmo            = {}  -- groupName -> { side, missiles, maxMissiles, lastFired, status, lowWarned }
LOG._fobs               = {}  -- id        -> { pos, side, builtAt, name }
LOG._convoys            = {}  -- groupName -> { side, spawnTime, destination, destType, destPos, auto }
LOG._jtacs              = {}  -- unitName  -> { side, pos, registeredAt }
LOG._autoResupplyPending = {} -- targetName -> true (block duplicate dispatch)
```

#### Artillery battery API

```lua
LOG.registerBattery(groupName, side)       -- called by artillery_manager.setup()
LOG.consumeAmmo(groupName, rounds)         -- deducted by server_core wire on fireMission
LOG.hasAmmo(groupName)                     -- returns true if rounds > 0
LOG.resupply(groupName, amount)            -- restore rounds; amount defaults to cfg.ammoResupplyAmount
```

#### SAM ammo tracking

```lua
LOG.initSAMAmmo(groupName, side)    -- scans group units against SAM_LAUNCHER_MISSILES table
LOG.resupplySAM(groupName, amount)  -- restore missiles; schedules radar restore after samReloadDelay

-- States: 'OK'  'LOW' (<50%)  'CRITICAL' (<25%)  'WINCHESTER' (0)
```

`SAM_LAUNCHER_MISSILES` — per-unit-type missile capacity:

| System | Unit type name | Missiles |
|---|---|---|
| SA-6 Kub | `Kub 2P25 ln` | 3 |
| SA-11 BUK | `Buk 9A310M1` | 4 |
| S-300 PS | `S-300PS 5P85C ln` | 4 |
| HAWK | `Hawk ln` | 3 |
| Patriot | `Patriot ln` | 4 |
| SA-15 Tor | `Tor 9A331` | 8 |
| SA-8 Osa | `Osa 9A33 ln` | 4 |
| SA-19 Tunguska | `2S6 Tunguska` | 8 |
| Avenger | `M1097 Avenger` | 8 |
| NASAMS | `NASAMS_LN_B/C` | 6 |
| Gepard/Shilka | — | 0 (cannon, not tracked) |

**Winchester SAM behavior:**
1. `ALARM_STATE GREEN` set immediately (radar off)
2. `iads.goDark(groupName, 86400)` (24hr IADS dark)
3. On resupply: missiles restored, `IM._evading[groupName] = nil` cleared
4. After `samReloadDelay` seconds: `ALARM_STATE RED` restored

**SAM shot handler:** `LOG._samShotHandler` listens for `S_EVENT_SHOT` with
`weapon:getCategory() == Weapon.Category.MISSILE` (3).  Shooter unit's group is
looked up in `LOG._samAmmo`.

#### Supply truck proximity resupply

`checkSupplyTrucks()` runs every `supplyCheckInterval` seconds.
Supply vehicle types: `'M-818'`, `'KAMAZ Truck'`, `'Ural-375'`, `'Ural-4320'`, `'Tigr'`.
Any such unit within `supplyRadiusBattery` metres of a tracked battery or SAM
triggers a resupply.  SAMs require a 120s cooldown since last shot.

#### Convoy system

Two convoy paths exist:

**Zone convoy** (manual F10 dispatch):
```lua
LOG.spawnConvoy(side, fromZoneName, toZoneName)
-- Clones blueConvoyTemplate / redConvoyTemplate at fromZoneName
-- Drives to nearest FOB or first drop zone as fallback
-- LOG._watchZoneConvoy polls every 30s for arrival
```

**Direct convoy** (auto-resupply and SAM resupply):
```lua
dispatchDirectConvoy(side, targetName, targetType, targetPos)
-- Finds nearest HQ zone to targetPos
-- Clones template, drives to targetPos using mist.groupToPoint
-- LOG._watchDirectConvoy polls every 30s
-- On arrival: calls LOG.resupply() or LOG.resupplySAM() based on targetType
-- If convoy destroyed: 50% credit refund, clears _autoResupplyPending
```

`_watchDirectConvoy` re-reads target group's live position each poll cycle so
it tracks displacing artillery batteries.

#### Smart auto-resupply poll

`autoResupplyPoll()` runs every `autoResupplyCheckInterval` seconds:

1. Collects all batteries and SAMs below their threshold
2. Sorts by urgency: WINCHESTER → CRITICAL → LOW
3. Skips entries with `_autoResupplyPending[name] = true`
4. Caps at `maxAutoConvoysPerSide` active auto-convoys per coalition
5. Deducts `autoConvoyCost` or `samResupplyCost` credits via `DCSCore.credits.spendCredits()`
6. Calls `dispatchDirectConvoy()`

Only runs when `cfg.logistics.autoResupplyEnabled = true`.

#### CTLD integration

```lua
LOG.onCrateDropped(args)           -- called by ctld_config crateDropped callback
LOG._checkFOBBuilt(pos, side)      -- scans for static objects at crate pos after fobBuildTime
LOG._scanForDeployedSAM(pos, side) -- scans for SAM radar attributes; calls iads.add() + initSAMAmmo()
LOG._scanForDeployedJTAC(pos, side)-- scans for JTAC unit; registers with ArtilleryEnhancement + artillery_manager
```

FOB detection looks for DCS static objects (`world.searchObjects`) with SAM crate weight
in `[1003.0, 1005.99]`.

#### Pilot extraction

`LOG._extractionHandler` listens for `S_EVENT_DEAD` on player aircraft.
If `cfg.logistics.extractionEnabled` is true, calls `ctld.createExtractZone()` at the
crash site.

---

### scripts/credits.lua — `DCSCore.credits`

Kill-based resource economy.  Both coalitions maintain a credit pool.

```lua
CR.setup()
CR.addCredits(side, amount, reason)   -- reason is logged only
CR.spendCredits(side, amount)         -- returns false without deducting if insufficient
CR.getCredits(side)
CR.balanceStr()                       -- 'Credits — BLU: N  RED: N'
```

#### Kill value table (checked top-to-bottom; first attribute match wins)

| Category | Credits |
|---|---|
| Aircraft Carriers | 300 |
| Strategic bombers | 200 |
| Battleships | 200 |
| Fighters | 100 |
| Helicopters | 75 |
| SAM CC (command) | 120 |
| SAM SR/TR (radar) | 100 |
| SAM LL (launcher) | 75 |
| Tanks | 60 |
| MLRS | 70 |
| Artillery | 50 |
| IFV | 35 |
| APC | 25 |
| AAA | 30 |
| Trucks | 10 |
| Infantry | 5 |

**Suppression-assist bonus:** +10 credits when a unit dies while
`DCSCore.suppression.isSuppressed(groupName)` is true.

**F10 menu** (both coalitions, all players): Balance, How Credits Work.

---

### scripts/artillery_manager.lua — `DCSCore.artillery`

Counter-battery radar detection, fire missions, post-fire displacement.

```lua
ART.setup()
ART.fireMission(batteryName, targetPos, rounds, msgSide)  -- wrapped by server_core
ART.addSpotter(unitName, side)
ART.addBattery(groupName, side)

-- Internal state
ART._batteries = {}  -- groupName -> { side, displacing, lastFired }
ART._shells    = {}  -- tracked incoming shell objects
```

**server_core wire** — `wireLogisticsAmmo()` wraps `ART.fireMission`:
1. Calls `LOG.hasAmmo(batteryName)` — aborts and notifies coalition if Winchester
2. On success: calls `LOG.consumeAmmo(batteryName, rounds)`

---

### scripts/server_core.lua — Entry point (v1.2)

Calls `*.setup()` in dependency order:

```
suppression → iads → ctld → artillery → logistics → credits
```

Then wires cross-system hooks:

| Hook function | What it does |
|---|---|
| `wireIADSSuppression()` | Wraps `suppression._suppress`; extends SEAD dark window +15s if target is already evading |
| `wireArtilleryCTLD()` | Confirms CB impact → CTLD zone warning link (no patch needed) |
| `wireCTLDSuppression()` | Wraps `ctld.fallbackDrop` to call `onTroopDropHook` on success |
| `wireLogisticsAmmo()` | Wraps `artillery.fireMission` for Winchester check + ammo deduction |

Admin F10 menu (BLUE only) sections: IADS, Suppression, Artillery, CTLD, Logistics
(including SAM ammo summary), Credits (balance display + admin grant commands).

Status broadcast (every `statusInterval` seconds) reports: IADS evading count,
suppressed group count, displacing batteries, logistics winchester counts (arty + SAM),
credit balances.

---

### Cross-System Integration Map

```
SEAD missile fired
  └─► iads_manager: SAM scatters + ALARM_STATE GREEN
        └─► suppression hit while evading → dark window +15s

Ground unit hit
  └─► suppression: ROE WEAPON_HOLD for baseHoldTime
        └─► if unit dies while suppressed → credits: +10 bonus to opposing side

Artillery fires
  └─► server_core wire: consumeAmmo() deducted from logistics pool
        └─► if Winchester: fire blocked, player notified

Artillery shell impacts
  └─► artillery_manager: CB radar detects origin
        ├─► suppression: units near impact suppressed
        └─► nearest friendly battery fires CB mission

SAM fires missiles
  └─► logistics._samShotHandler: missiles decremented
        ├─► LOW (<50%): coalition warned
        ├─► CRITICAL (<25%): urgent warning
        └─► WINCHESTER (0): ALARM_STATE GREEN + IADS 24hr dark

Supply truck within supplyRadiusBattery (every 60s)
  └─► logistics: battery rounds restored
  └─► logistics: SAM missiles restored (if >120s since last shot)

auto-resupply poll (every autoResupplyCheckInterval)
  └─► logistics: batteries/SAMs below threshold → dispatchDirectConvoy
        └─► credits.spendCredits() deducted
              └─► on convoy destroyed: 50% refund

CTLD crate dropped
  └─► ctld_logistics: after fobBuildTime → scan for FOB
  └─► ctld_logistics: after samBuildDelay → scan for SAM → iads.add() + initSAMAmmo()
  └─► ctld_logistics: after jtacScanDelay → scan for JTAC → addSpotter()

CTLD troop drop
  └─► ctld_config.onTroopDropHook: enemies within 500m suppressed 20s

Player aircraft killed
  └─► logistics._extractionHandler: ctld.createExtractZone() at crash site

Unit killed (S_EVENT_DEAD)
  └─► credits._handler: award kill value to opposing coalition
        └─► if suppressed: +10 assist bonus
```

---

### Adding a New Module

1. Create `scripts/mymodule.lua`:
   ```lua
   DCSCore         = DCSCore or {}
   DCSCore.mymod   = {}
   local M = DCSCore.mymod
   local U = DCSCore.utils

   function M.setup()
       local cfg = DCSCore.config.mymod
       if not cfg or not cfg.enabled then return end
       -- ...
       U.info('MYMOD: initialized')
   end

   U.info('mymod.lua loaded')
   ```
2. Add a `cfg.mymod` block to `scripts/config.lua`
3. Add a `DO SCRIPT FILE` trigger in LOAD_ORDER.md (before `server_core.lua`)
4. Add `DCSCore.mymod.setup()` to the init sequence in `server_core.lua`
5. Add optional cross-system wiring in `server_core.lua` if needed

### Namespace Conventions

- All public functions on `DCSCore.*` (e.g. `DCSCore.logistics.resupply`)
- Internal state/helpers prefixed with `_` (e.g. `LOG._batteries`, `LOG._watchDirectConvoy`)
- Module local alias: `local M = DCSCore.mymod`; `local U = DCSCore.utils`
- Config always read as `DCSCore.config.section` (never cached at module level)

---

## Reference Links

- SSE Docs: https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation
- MIST Docs: https://wiki.hoggitworld.com/view/Mission_Scripting_Tools_Documentation
- MIST GitHub: https://github.com/mrSkortch/MissionScriptingTools
- IADS Docs: https://wiki.hoggitworld.com/view/IADScript_Documentation
- IADS GitHub: (see Grimes' ED Forums post)
- Dynamic Medevac GitHub: https://github.com/RagnarDa/DCS-Mission-Scripts/tree/master/Medevac
- Dynamic Extraction: https://github.com/Psyrixx/dcsw-dynamic-extraction-team
- Hoggit DCS Scripting Wiki: https://wiki.hoggitworld.com
