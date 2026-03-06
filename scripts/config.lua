-- =============================================================
-- config.lua
-- Mission-specific configuration for DCS Server Core.
--
-- EDIT THIS FILE to match your mission's group/unit names,
-- zone names, and desired behaviour settings.
-- =============================================================

DCSCore        = DCSCore or {}
DCSCore.config = {}

local cfg = DCSCore.config

-- =============================================================
-- Admin / Logging
-- =============================================================
cfg.admin = {
    logLevel       = 2,     -- 0=off  1=errors  2=info  3=debug
    f10MenuBlue    = true,  -- enable F10 admin menu for BLUE coalition
    f10MenuRed     = false,
    statusInterval = 300,   -- seconds between periodic log broadcast (0=off)
}

-- =============================================================
-- IADS — Integrated Air Defense
-- =============================================================
cfg.iads = {
    level       = 3,          -- 1=always on  2=random  3=intelligent  4=coordinated
    linked      = 'coalition',
    radarSim    = true,        -- simulate radar scan speed
    refreshRate = 15,          -- seconds between checks when radarSim=false
    timeDelay   = 15,          -- seconds after mission start before IADS activates
    debug       = false,

    -- All groups whose names START WITH any of these prefixes are auto-added.
    -- Extend or trim as needed for your theatre.
    redPrefixes  = { 'SA-', 'SAM-', 'S-300', 'S-400', 'BUK', 'TOR',
                     'OSA', 'TUNGUSKA', 'SHILKA', 'SA6', 'SA10', 'SA11',
                     'SA15', 'SA19', 'HAWK', 'PATRIOT', 'ROLAND' },
    bluePrefixes = {},

    -- Explicit group names (full match, case-sensitive).
    redGroups    = {},
    blueGroups   = {},
}

-- =============================================================
-- Smarter SAM — SEAD Evasion
-- =============================================================
cfg.smarterSAM = {
    enabled           = true,
    scatterRadius     = 300,   -- metres to disperse on SEAD detection
    scatterFormation  = 'Rank',
    scatterMaxOffset  = 250,
    scatterMinOffset  = 20,
    radarOffMinDelay  = 8,     -- seconds radar stays off (minimum)
    radarOffMaxDelay  = 25,    -- seconds radar stays off (maximum)

    -- DCS internal weapon type-names that trigger evasion.
    -- Add new SEAD missiles here as needed.
    seadMissiles = {
        'AGM_88', 'AGM-88B', 'AGM-88C',
        'KH-58',  'Kh-58U',
        'KH-25MPU',
        'AGM-45',
        'ALARM',
        'Kh-31P',
    },
}

-- =============================================================
-- Suppression Fire
-- =============================================================
cfg.suppression = {
    enabled       = true,
    baseHoldTime  = 15,   -- seconds ROE is set to WEAPON_HOLD after first hit
    maxHoldTime   = 80,   -- suppression cannot extend beyond this
    holdExtension = 10,   -- seconds added per subsequent hit (diminishing)

    -- Set to a DCS attribute string (e.g. 'Infantry') to limit suppression
    -- to that unit type only.  nil = apply to all ground units.
    unitAttribute = nil,
}

-- =============================================================
-- CTLD — Complete Troops and Logistics Deployment
-- Requires ciribob's ctld.lua (https://github.com/ciribob/DCS-CTLD)
-- Falls back to lightweight MIST mode if ctld.lua is absent.
--
-- Zone table fields used by ctld_config.lua:
--   name    string   ME trigger zone name
--   smoke   string   "green"|"red"|"blue"|"orange"|"white"|"none"
--   limit   number   -1=unlimited, 0-20=group cap  (pickup zones only)
--   active  bool     true=starts enabled  (pickup zones only)
--   flag    number   optional ME flag to track remaining groups
-- =============================================================
cfg.ctld = {
    enabled = true,

    -- ── Transport helicopter unit names ──────────────────────
    blueTransports = {
        -- 'UH-1H Blue 1',
        -- 'CH-47 Blue 1',
    },
    redTransports = {
        -- 'Mi-8 Red 1',
    },

    -- ── Pickup zones (troops and crates available here) ──────
    bluePickupZones = {
        -- { name='CTLD_Blue_Pickup_1', smoke='green',  limit=-1, active=true  },
        -- { name='CTLD_Blue_Pickup_2', smoke='green',  limit=5,  active=true  },
    },
    redPickupZones = {
        -- { name='CTLD_Red_Pickup_1',  smoke='orange', limit=-1, active=true  },
    },

    -- ── Drop / offload zones ─────────────────────────────────
    blueDropZones = {
        -- { name='CTLD_Blue_Drop_1', smoke='blue' },
    },
    redDropZones = {
        -- { name='CTLD_Red_Drop_1',  smoke='red'  },
    },

    -- ── Waypoint zones (dropped troops patrol toward these) ──
    blueWaypointZones = {
        -- { name='CTLD_Blue_WP_1', smoke='white', active=true },
    },
    redWaypointZones = {
        -- { name='CTLD_Red_WP_1',  smoke='white', active=true },
    },

    -- ── Behaviour parameters ─────────────────────────────────
    defaultTroopCount  = 10,    -- soldiers per load (default)
    pickupRadius       = 200,   -- metres — max distance from zone centre
    extractRadius      = 125,   -- metres — max extract distance
    maxAGL             = 15,    -- metres AGL for grounded check
    maxSpeed           = 2,     -- m/s for grounded check
    minHoverAGL        = 7.5,   -- metres — minimum hover height for crate load
    maxHoverAGL        = 12.0,  -- metres — maximum hover height for crate load
    hoverLoadTime      = 10,    -- seconds to hover before crate attaches
    fastRopeMaxAGL     = 18.28, -- metres — 60 ft fast-rope safety limit
    msgDuration        = 15,    -- seconds player messages are displayed

    -- ── FOB ──────────────────────────────────────────────────
    fobCratesRequired  = 3,     -- crates to build a FOB
    fobBuildTime       = 120,   -- seconds to assemble after last crate placed

    -- ── JTAC limits ──────────────────────────────────────────
    jtacLimitBlue      = 10,
    jtacLimitRed       = 10,

    -- ── AA/SAM system limits ─────────────────────────────────
    aaLimitBlue        = 20,
    aaLimitRed         = 20,

    -- ── Late-activated ME templates (fallback MIST mode only) ─
    troopTemplates = {
        blue = {
            infantry = 'CTLD_Blue_Infantry_Template',
            manpads  = 'CTLD_Blue_MANPADS_Template',
            atgm     = 'CTLD_Blue_ATGM_Template',
        },
        red = {
            infantry = 'CTLD_Red_Infantry_Template',
            manpads  = 'CTLD_Red_MANPADS_Template',
            atgm     = 'CTLD_Red_ATGM_Template',
        },
    },
}

-- =============================================================
-- Logistics — supply chain, convoys, FOB management
-- =============================================================
cfg.logistics = {
    enabled = true,
    f10MenuEnabled = true,

    -- ── Battery ammo pool ────────────────────────────────────
    batteryStartingRounds = 100,   -- rounds per battery at mission start
    ammoResupplyAmount    = 100,   -- rounds restored per truck resupply
    supplyCheckInterval   = 60,    -- seconds between truck-proximity polls
    supplyRadiusBattery   = 300,   -- metres — truck must be within to resupply
    supplyRadiusFOB       = 500,   -- metres — FOB supply radius for convoys

    -- ── Supply convoys ───────────────────────────────────────
    -- HQ zones: ME trigger zones where convoys spawn.
    -- Must match zone names created in Mission Editor.
    blueHQZones = {
        -- 'Blue_HQ_Zone_1',
    },
    redHQZones = {
        -- 'Red_HQ_Zone_1',
    },

    -- Late-activated convoy group templates in the ME.
    blueConvoyTemplate = 'Blue_Supply_Convoy',
    redConvoyTemplate  = 'Red_Supply_Convoy',

    -- ── JTAC auto-registration ────────────────────────────────
    jtacAutoRegister = true,   -- register CTLD-deployed JTACs as arty spotters
    jtacScanDelay    = 30,     -- seconds after crate drop to scan for unit

    -- ── SAM auto-IADS registration ────────────────────────────
    samAutoRegister  = true,   -- add assembled CTLD SAM systems to IADS
    samBuildDelay    = 45,     -- seconds after crate assembly to scan area

    -- ── Radio beacons ─────────────────────────────────────────
    fobBeaconLife    = 30,     -- minutes, FOB beacon battery life

    -- ── Downed-pilot extraction ────────────────────────────────
    extractionEnabled = true,

    -- ── SAM ammo limits ───────────────────────────────────────
    -- Each SAM launcher tracks its missile count.  When exhausted the
    -- launcher goes dark until a supply convoy delivers a resupply.
    samAmmoEnabled   = true,
    samReloadDelay   = 60,     -- seconds after resupply before radar re-activates

    -- ── Credit costs for logistics actions ────────────────────
    manualConvoyCost  = 30,    -- credits to dispatch a player-requested convoy
    autoConvoyCost    = 50,    -- credits for an auto-resupply convoy (battery)
    samResupplyCost   = 75,    -- credits for an auto-resupply convoy (SAM)

    -- ── Auto-resupply (smart convoy dispatch) ─────────────────
    autoResupplyEnabled       = true,
    autoResupplyThreshold     = 0.25,  -- battery rounds/max ratio that triggers auto
    samAutoResupplyThreshold  = 0.25,  -- SAM missiles/max ratio that triggers auto
    maxAutoConvoysPerSide     = 2,     -- max simultaneous auto-convoys per coalition
    autoResupplyCheckInterval = 120,   -- seconds between auto-resupply polls
}

-- =============================================================
-- Credits — resource economy
-- =============================================================
cfg.credits = {
    enabled             = true,
    blueStartingCredits = 500,   -- credits awarded to BLUE at mission start
    redStartingCredits  = 500,   -- credits awarded to RED  at mission start
}

-- =============================================================
-- Artillery & Counter-Battery
-- =============================================================
cfg.artillery = {
    enabled = true,

    -- Firing battery group names.
    blueBatteries = {
        -- 'Blue M109 Battery 1',
        -- 'Blue M270 Battery 1',
    },
    redBatteries = {
        -- 'Red 2S3 Battery 1',
        -- 'Red BM-21 Battery 1',
    },

    -- Spotter unit names (aircraft, JTAC, ground scouts).
    blueSpotters = {
        -- 'Blue JTAC 1',
    },
    redSpotters = {
        -- 'Red JTAC 1',
    },

    -- Counterfire radar unit names and their DCS type identifier.
    -- Supported types: 'AN/TPQ-36', 'AN/TPQ-37', 'ARK-1M Rys'
    blueRadars = {
        -- { unit = 'Blue TPQ-37 1', type = 'AN/TPQ-37' },
    },
    redRadars = {
        -- { unit = 'Red ARK-1M 1', type = 'ARK-1M Rys' },
    },

    -- Post-fire displacement
    displaceAfterShot = true,
    displaceRadius    = 500,  -- metres — random disperse distance
    displaceDelay     = 60,   -- seconds of silence before displacing

    -- Counter-battery suppression of units near impact
    cbSuppressionEnabled = true,
    cbSuppressRadius     = 400,  -- metres around impact to suppress
    cbHoldTime           = 30,   -- seconds of suppression applied
}

-- =============================================================
-- Zone Capture — Moose_DualCoalitionZoneCapture integration
-- Requires: MOOSE.lua + Moose_DualCoalitionZoneCapture.lua
-- =============================================================
cfg.zoneCapture = {
    enabled = true,

    -- Seconds between zone-state poll cycles.
    -- Lower = more responsive (finer detection); higher = less CPU overhead.
    pollInterval = 15,

    -- ── Credit rewards ───────────────────────────────────────
    captureCredits = 50,   -- awarded to the coalition that captures a zone
    defenseCredits = 25,   -- awarded when a zone is successfully defended
                           --   (state: Attacked → Guarded, coalition unchanged)
    attackCredits  = 5,    -- awarded to attacker when a zone enters Attacked

    -- ── Broadcast ─────────────────────────────────────────────
    -- Send an all-coalition outText message on each capture event.
    broadcastCaptures = true,

    -- ── Zone-specific SAM IADS prefixes ───────────────────────
    -- When a zone is captured, SAM groups whose names start with any
    -- listed prefix are added to the new owner's IADS network.
    -- Configure per zone name (must match ME trigger zone name exactly).
    -- Example:
    --   zoneSAMPrefixes = {
    --     ['Capture Zone-1'] = { 'SA6-North-', 'TOR-North-' },
    --     ['Capture Zone-2'] = { 'HAWK-East-' },
    --   },
    zoneSAMPrefixes = {},

    -- ── Defender suppression on attack ────────────────────────
    -- When a zone enters "Attacked" state, friendly units inside are
    -- briefly suppressed (ROE → WEAPON_HOLD) to simulate assault chaos.
    -- Requires DCSCore.suppression to be loaded.
    suppressOnAttack = true,
    suppressRadius   = 800,  -- metres around zone centre to scan for defenders
    suppressDuration = 20,   -- seconds of suppression applied

    -- ── Artillery harassment on capture ───────────────────────
    -- When a zone is captured, the former owner fires a short harassment
    -- mission at the zone centre from its nearest available battery.
    -- Requires DCSCore.artillery + DCSCore.logistics to be loaded.
    artilleryOnCapture        = false,
    artilleryTargetRadius     = 200,  -- metres of random offset from zone centre
    artilleryRoundsPerMission = 5,

    -- ── Logistics FOB registration on capture ─────────────────
    -- After a zone is captured, scan the zone centre for static objects
    -- that qualify as a FOB and register them with the logistics system.
    -- Requires DCSCore.logistics to be loaded.
    fobOnCapture = true,
}

DCSCore.utils.info('config.lua loaded')
