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
-- CTLD — Combined Arms Troop Load / Drop
-- Requires ciribob's ctld.lua (https://github.com/ciribob/DCS-CTLD)
-- OR operates in lightweight fallback mode using MIST if ctld.lua
-- is not present.
-- =============================================================
cfg.ctld = {
    enabled = true,

    -- Unit names of player-controlled transport helicopters.
    blueTransports = {
        -- 'UH-1H Blue 1',
        -- 'UH-60 Blue 1',
    },
    redTransports = {
        -- 'Mi-8 Red 1',
    },

    -- Trigger zone names (created in Mission Editor).
    bluePickupZones = {
        -- { name = 'CTLD_Blue_Pickup_1', smoke = trigger.smokeColor.Green  },
        -- { name = 'CTLD_Blue_Pickup_2', smoke = trigger.smokeColor.Green  },
    },
    redPickupZones = {
        -- { name = 'CTLD_Red_Pickup_1',  smoke = trigger.smokeColor.Orange },
    },
    blueDropZones = {
        -- { name = 'CTLD_Blue_Drop_1',   smoke = trigger.smokeColor.Blue   },
    },
    redDropZones = {
        -- { name = 'CTLD_Red_Drop_1',    smoke = trigger.smokeColor.Red    },
    },

    -- Late-activated group templates in the ME used by fallback mode.
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

    pickupRadius = 200,  -- metres — helicopter must be within this of zone centre
    maxAGL       = 15,   -- metres AGL for grounded check
    maxSpeed     = 2,    -- m/s for grounded check
    msgDuration  = 15,   -- seconds player messages are displayed
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

DCSCore.utils.info('config.lua loaded')
