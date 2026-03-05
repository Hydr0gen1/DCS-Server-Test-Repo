-- =============================================================
-- ctld_config.lua
-- Configures ciribob's CTLD (Complete Troops and Logistics
-- Deployment) using the real ctld.lua API, and provides a
-- lightweight MIST-based fallback when ctld.lua is absent.
--
-- LOAD ORDER: after mist.lua and ctld.lua (see LOAD_ORDER.md)
-- GitHub: https://github.com/ciribob/DCS-CTLD
--
-- Zone table format (ciribob API):
--   pickupZone: { zoneName, smokeColor, limit, "active"|"no", side, [flagNum] }
--   dropZone:   { zoneName, smokeColor, side }
--   wayptZone:  { zoneName, smokeColor, "active"|"no", side }
--
--   smokeColor: "green" "red" "blue" "orange" "white" -1/"none"
--   limit:  -1 = unlimited,  0-20 = max groups available at zone
--   side:    0 = both,  1 = RED,  2 = BLUE
-- =============================================================

DCSCore      = DCSCore or {}
DCSCore.ctld = {}

local CT = DCSCore.ctld
local U  = DCSCore.utils

CT._active   = false   -- true once setup() completes
CT._manifest = {}      -- pilotUnitName -> { side, loadType, loadCount }

-- =============================================================
-- Per-aircraft load limits (override ciribob defaults as needed)
-- =============================================================

local UNIT_LOAD_LIMITS = {
    ['Mi-8MT']       = 16,
    ['Mi-24P']       = 4,
    ['UH-1H']        = 10,
    ['CH-47Fbl1']    = 33,
    ['SH-60B']       = 6,
    ['Ka-50']        = 0,
    ['C-130']        = 80,
    ['C-130J-30']    = 80,
    ['IL-76MD']      = 90,
    ['Hercules']     = 30,
}

-- =============================================================
-- Primary Mode — ciribob ctld.lua
-- =============================================================

function CT._configureCiribob()
    if not ctld then return false end

    local cfg  = DCSCore.config.ctld
    local lcfg = DCSCore.config.logistics or {}

    -- ── Behaviour flags ─────────────────────────────────────
    ctld.enableCrates              = true
    ctld.enableSmokeDrop           = true
    ctld.enableFastRopeInsertion   = true
    ctld.enabledFOBBuilding        = true
    ctld.enabledRadioBeaconDrop    = true
    ctld.enableRepackingVehicles   = true
    ctld.staticBugFix              = true
    ctld.slingLoad                 = false   -- off: causes DCS physics crash

    -- ── Loading parameters ───────────────────────────────────
    ctld.numberOfTroops            = cfg.defaultTroopCount or 10
    ctld.maximumDistanceLogistic   = cfg.pickupRadius      or 200
    ctld.maxExtractDistance        = cfg.extractRadius     or 125
    ctld.hoverTime                 = cfg.hoverLoadTime     or 10
    ctld.minimumHoverHeight        = cfg.minHoverAGL       or 7.5
    ctld.maximumHoverHeight        = cfg.maxHoverAGL       or 12.0
    ctld.fastRopeMaximumHeight     = cfg.fastRopeMaxAGL    or 18.28

    -- ── FOB ─────────────────────────────────────────────────
    ctld.cratesRequiredForFOB      = cfg.fobCratesRequired or 3
    ctld.buildTimeFOB              = cfg.fobBuildTime      or 120
    ctld.troopPickupAtFOB          = true
    ctld.forceCrateToBeMoved       = true   -- crates must be moved before unpacking

    -- ── JTAC limits ─────────────────────────────────────────
    ctld.JTAC_LIMIT_BLUE           = cfg.jtacLimitBlue     or 10
    ctld.JTAC_LIMIT_RED            = cfg.jtacLimitRed      or 10
    ctld.JTAC_smokeOn_BLUE         = true
    ctld.JTAC_smokeOn_RED          = true
    ctld.JTAC_allowStandbyMode     = true

    -- ── AA limits ────────────────────────────────────────────
    ctld.AASystemLimitBLUE         = cfg.aaLimitBlue       or 20
    ctld.AASystemLimitRED          = cfg.aaLimitRed        or 20

    -- ── Radio beacons ────────────────────────────────────────
    ctld.deployedBeaconBattery     = lcfg.fobBeaconLife    or 30   -- minutes

    -- ── Per-aircraft load limits ─────────────────────────────
    for unitType, limit in pairs(UNIT_LOAD_LIMITS) do
        ctld.unitLoadLimits = ctld.unitLoadLimits or {}
        ctld.unitLoadLimits[unitType] = limit
    end

    -- ── Transport unit names ─────────────────────────────────
    -- ciribob expects a flat list of unit names
    ctld.transportPilotNames = {}
    for _, name in ipairs(cfg.blueTransports) do
        table.insert(ctld.transportPilotNames, name)
    end
    for _, name in ipairs(cfg.redTransports) do
        table.insert(ctld.transportPilotNames, name)
    end

    -- ── Pickup zones ─────────────────────────────────────────
    -- Format: { zoneName, smokeColor, limit, "active"|"no", side, [flagNum] }
    ctld.pickupZones = {}
    for _, z in ipairs(cfg.bluePickupZones) do
        table.insert(ctld.pickupZones, {
            z.name,
            z.smoke  or "green",
            z.limit  or -1,
            z.active and "active" or "no",
            2,           -- BLUE
            z.flag,      -- optional flag number
        })
    end
    for _, z in ipairs(cfg.redPickupZones) do
        table.insert(ctld.pickupZones, {
            z.name,
            z.smoke  or "orange",
            z.limit  or -1,
            z.active and "active" or "no",
            1,           -- RED
            z.flag,
        })
    end

    -- ── Drop zones ───────────────────────────────────────────
    -- Format: { zoneName, smokeColor, side }
    ctld.dropZones = {}
    for _, z in ipairs(cfg.blueDropZones) do
        table.insert(ctld.dropZones, { z.name, z.smoke or "blue",   2 })
    end
    for _, z in ipairs(cfg.redDropZones) do
        table.insert(ctld.dropZones, { z.name, z.smoke or "red",    1 })
    end

    -- ── Waypoint zones (patrol routes for dropped troops) ────
    ctld.waypointZones = {}
    for _, z in ipairs(cfg.blueWaypointZones or {}) do
        table.insert(ctld.waypointZones,
            { z.name, z.smoke or "white", z.active and "active" or "no", 2 })
    end
    for _, z in ipairs(cfg.redWaypointZones or {}) do
        table.insert(ctld.waypointZones,
            { z.name, z.smoke or "white", z.active and "active" or "no", 1 })
    end

    U.info('CTLD: ciribob configured — ' ..
           #ctld.pickupZones .. ' pickup zones, ' ..
           #ctld.dropZones .. ' drop zones')
    return true
end

-- =============================================================
-- Callback registration (ciribob's event system)
-- ctld.addCallback(fn) where fn receives an args table:
--   args.eventType  "unitLoaded" | "unitDropped" | "cratePickup"
--                   | "crateDropped" | "jtacStatus"
--   args.unit       the transport helicopter unit
--   args.side       coalition.side.*
--   (additional fields vary by event type)
-- =============================================================

function CT._registerCallbacks()
    if not ctld or not ctld.addCallback then
        U.debug('CTLD: ctld.addCallback not available')
        return
    end

    ctld.addCallback(function(args)
        if not args or not args.eventType then return end

        local evType = args.eventType
        local unit   = args.unit
        local side   = args.side

        -- ── Troops loaded ────────────────────────────────────
        if evType == 'unitLoaded' then
            if unit and unit:isExist() then
                local name = unit:getName()
                CT._manifest[name] = { side = side, loadType = 'troops' }
                U.debug('CTLD: troops loaded onto ' .. name)
            end

        -- ── Troops dropped ───────────────────────────────────
        elseif evType == 'unitDropped' then
            if unit and unit:isExist() then
                local name = unit:getName()
                CT._manifest[name] = nil

                -- Insertion suppression cross-hook
                CT.onTroopDropHook(unit, side)

                U.info('CTLD: troops dropped from ' .. name)
            end

        -- ── Crate picked up ──────────────────────────────────
        elseif evType == 'cratePickup' then
            if unit and unit:isExist() then
                CT._manifest[unit:getName()] = {
                    side = side, loadType = 'crate',
                    crateWeight = args.crateWeight,
                }
                U.debug('CTLD: crate picked up by ' .. unit:getName())
            end

        -- ── Crate dropped ────────────────────────────────────
        elseif evType == 'crateDropped' then
            -- Notify logistics module so it can watch for SAM/JTAC assembly
            if DCSCore.logistics and DCSCore.logistics.onCrateDropped then
                DCSCore.logistics.onCrateDropped(args)
            end
            if unit and unit:isExist() then
                CT._manifest[unit:getName()] = nil
            end
            U.debug('CTLD: crate dropped')
        end
    end)

    U.info('CTLD: callbacks registered via ctld.addCallback')
end

-- =============================================================
-- Fallback Mode — MIST-based troop spawn
-- Used automatically when ctld.lua is not loaded.
-- Spawns a copy of a late-activated ME group template near
-- the grounded helicopter.
-- =============================================================

local function spawnTemplate(templateName, pilotUnit, side)
    if not mist then
        U.error('CTLD fallback: MIST not loaded')
        return false
    end

    local pos     = pilotUnit:getPosition().p
    local heading = mist.getHeading(pilotUnit)
    local dist    = 30
    local spawnX  = pos.x + dist * math.cos(heading + math.pi / 2)
    local spawnZ  = pos.z + dist * math.sin(heading + math.pi / 2)

    local tplData = mist.getGroupData(templateName)
    if not tplData then
        U.error('CTLD fallback: template not found — ' .. templateName)
        return false
    end

    local clone          = mist.utils.deepCopy(tplData)
    clone.groupId        = mist.getNextGroupId()
    clone.name           = templateName .. '_drop_' .. math.random(1000, 9999)
    clone.hidden         = false
    clone.start_time     = 0
    clone.x              = spawnX
    clone.y              = spawnZ

    for _, ud in ipairs(clone.units) do
        local dx = ud.x - tplData.x
        local dz = ud.y - tplData.y
        ud.x      = spawnX + dx
        ud.y      = spawnZ + dz
        ud.unitId = mist.getNextUnitId()
    end

    mist.dynAdd(clone)
    return true
end

function CT.fallbackDrop(pilotUnitName, templateName, side)
    local cfg  = DCSCore.config.ctld
    local unit = U.getUnit(pilotUnitName)

    if not unit then
        U.msgCoalition(side, '[CTLD] Unit not found: ' .. pilotUnitName, 8)
        return false
    end
    if not U.isUnitGrounded(unit, cfg.maxAGL or 15, cfg.maxSpeed or 2) then
        U.msgCoalition(side, '[CTLD] Must be on the ground to deploy troops.', 8)
        return false
    end

    local pos       = unit:getPosition().p
    local zones     = side == coalition.side.BLUE
                      and cfg.bluePickupZones or cfg.redPickupZones
    local inZone    = false
    for _, z in ipairs(zones) do
        local zv = U.getZoneVec3(z.name)
        if zv and U.dist2D(pos, zv) <= (cfg.pickupRadius or 200) then
            inZone = true; break
        end
    end
    if not inZone then
        U.msgCoalition(side, '[CTLD] Not within a pickup zone.', 8)
        return false
    end

    if not spawnTemplate(templateName, unit, side) then return false end

    CT._manifest[pilotUnitName] = nil
    CT.onTroopDropHook(unit, side)
    local mgrs = mist and mist.tostringMGRS(pos, 5) or '?'
    U.msgCoalition(side,
        '[CTLD] Troops deployed at ' .. mgrs, cfg.msgDuration or 15)
    U.info('CTLD: fallback drop — ' .. pilotUnitName .. ' template=' .. templateName)
    return true
end

-- =============================================================
-- Cross-system hook — insertion suppression
-- Called by both the ciribob callback and the fallback path.
-- =============================================================

function CT.onTroopDropHook(pilotUnit, side)
    if not DCSCore.suppression then return end

    local pos       = pilotUnit:getPosition().p
    local enemySide = side == coalition.side.BLUE
                      and coalition.side.RED or coalition.side.BLUE
    local enemies   = U.getUnitsInRadius(pos, 500, enemySide)

    for _, enemy in ipairs(enemies) do
        if enemy:isExist() then
            local grp = enemy:getGroup()
            if grp and grp:isExist() then
                DCSCore.suppression.suppressGroup(grp:getName(), 20)
            end
        end
    end

    U.info('CTLD: insertion suppression applied near ' .. pilotUnit:getName())
end

-- =============================================================
-- Public API
-- =============================================================

function CT.setup()
    local cfg = DCSCore.config.ctld
    if not cfg.enabled then
        U.info('CTLD: disabled in config')
        return
    end

    local primary = CT._configureCiribob()
    if primary then
        CT._registerCallbacks()
    else
        U.info('CTLD: ctld.lua not present — MIST fallback active')
    end

    CT._active = true
    U.info('CTLD: setup complete (primary=' .. tostring(primary) .. ')')
end

U.info('ctld_config.lua loaded')
