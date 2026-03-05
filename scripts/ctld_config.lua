-- =============================================================
-- ctld_config.lua
-- Combined Arms Troop Load / Drop integration.
--
-- PRIMARY MODE  — Configures ciribob's ctld.lua when it is
--                 already loaded (recommended for full feature set).
--                 https://github.com/ciribob/DCS-CTLD
--
-- FALLBACK MODE — A lightweight MIST-based troop-spawn system
--                 used automatically when ctld.lua is absent.
--                 Supports infantry drops from grounded helicopters
--                 using late-activated ME group templates.
--
-- Dependencies (primary):  ctld.lua, mist.lua
-- Dependencies (fallback):  mist.lua
-- =============================================================

DCSCore      = DCSCore or {}
DCSCore.ctld = {}

local CT = DCSCore.ctld
local U  = DCSCore.utils

-- pilotUnitName -> { side, template } — tracks what a helicopter is carrying
CT._manifest = {}
-- true once ciribob ctld is configured or fallback is active
CT._active   = false

-- =============================================================
-- Primary Mode — ciribob's ctld.lua
-- =============================================================

function CT._configureCiribob()
    if not ctld then return false end

    local cfg = DCSCore.config.ctld

    ctld.enableCrates           = true
    ctld.enableSmokeDrop        = true
    ctld.enableRappelling       = false
    ctld.enableFastRopeLoad     = false
    ctld.maxTroopsCarried       = 10
    ctld.maxCratesCarried       = 1
    ctld.checkPickupDistance    = cfg.pickupRadius
    ctld.maxAGL                 = cfg.maxAGL
    ctld.maxSpeed               = cfg.maxSpeed
    ctld.msgDuration            = cfg.msgDuration

    -- Combine both side transports into one list for ciribob
    ctld.transportPilotNames = {}
    for _, name in ipairs(cfg.blueTransports) do
        table.insert(ctld.transportPilotNames, name)
    end
    for _, name in ipairs(cfg.redTransports) do
        table.insert(ctld.transportPilotNames, name)
    end

    -- Pickup zones
    ctld.pickupZones = {}
    for _, z in ipairs(cfg.bluePickupZones) do
        table.insert(ctld.pickupZones, {
            zone   = z.name,
            smoke  = z.smoke or trigger.smokeColor.Green,
            side   = coalition.side.BLUE,
            active = true,
        })
    end
    for _, z in ipairs(cfg.redPickupZones) do
        table.insert(ctld.pickupZones, {
            zone   = z.name,
            smoke  = z.smoke or trigger.smokeColor.Orange,
            side   = coalition.side.RED,
            active = true,
        })
    end

    -- Drop-off zones
    ctld.dropOffZones = {}
    for _, z in ipairs(cfg.blueDropZones) do
        table.insert(ctld.dropOffZones, {
            zone   = z.name,
            smoke  = z.smoke or trigger.smokeColor.Blue,
            side   = coalition.side.BLUE,
            active = true,
        })
    end
    for _, z in ipairs(cfg.redDropZones) do
        table.insert(ctld.dropOffZones, {
            zone   = z.name,
            smoke  = z.smoke or trigger.smokeColor.Red,
            side   = coalition.side.RED,
            active = true,
        })
    end

    U.info('CTLD: ciribob ctld.lua configured')
    return true
end

-- =============================================================
-- Fallback Mode — MIST-based troop spawn
-- =============================================================

--- Spawn a copy of a late-activated ME template near `pilotUnit`.
-- The clone spawns on the side of the helicopter facing away from
-- the objective (pilot-side), offset by ~30 m.
local function spawnTemplate(templateName, pilotUnit, side)
    if not mist then
        U.error('CTLD fallback: MIST not loaded')
        return false
    end

    local pos     = pilotUnit:getPosition().p
    local heading = mist.getHeading(pilotUnit)

    -- Offset to the left of the helicopter
    local offsetDist = 30
    local spawnX = pos.x + offsetDist * math.cos(heading + math.pi / 2)
    local spawnZ = pos.z + offsetDist * math.sin(heading + math.pi / 2)

    local templateData = mist.getGroupData(templateName)
    if not templateData then
        U.error('CTLD fallback: template not found — ' .. templateName)
        return false
    end

    -- Deep-copy and relocate
    local cloneData       = mist.utils.deepCopy(templateData)
    cloneData.groupId     = mist.getNextGroupId()
    cloneData.name        = templateName .. '_drop_' .. math.random(1000, 9999)
    cloneData.hidden      = false
    cloneData.start_time  = 0
    cloneData.x           = spawnX
    cloneData.y           = spawnZ

    for _, unitData in ipairs(cloneData.units) do
        local dx        = unitData.x - templateData.x
        local dz        = unitData.y - templateData.y
        unitData.x      = spawnX + dx
        unitData.y      = spawnZ + dz
        unitData.unitId = mist.getNextUnitId()
    end

    mist.dynAdd(cloneData)
    return true
end

--- Attempt a troop-drop from the given pilot unit using the fallback system.
function CT.fallbackDrop(pilotUnitName, templateName, side)
    local cfg  = DCSCore.config.ctld
    local unit = U.getUnit(pilotUnitName)

    if not unit then
        U.msgCoalition(side, '[CTLD] Pilot unit not found: ' .. pilotUnitName, 10)
        return false
    end

    if not U.isUnitGrounded(unit, cfg.maxAGL, cfg.maxSpeed) then
        U.msgCoalition(side,
            '[CTLD] Must be on the ground and stationary to deploy troops.', 8)
        return false
    end

    local pos = unit:getPosition().p

    -- Check proximity to a pickup zone
    local pickupZones = side == coalition.side.BLUE
        and cfg.bluePickupZones or cfg.redPickupZones
    local inZone = false
    for _, z in ipairs(pickupZones) do
        local zVec = U.getZoneVec3(z.name)
        if zVec and U.dist2D(pos, zVec) <= cfg.pickupRadius then
            inZone = true
            break
        end
    end
    if not inZone then
        U.msgCoalition(side,
            '[CTLD] Not within a pickup zone (' .. cfg.pickupRadius .. 'm).', 8)
        return false
    end

    if not spawnTemplate(templateName, unit, side) then return false end

    CT._manifest[pilotUnitName] = nil
    local mgrs = mist and mist.tostringMGRS(pos, 5) or '?'
    U.msgCoalition(side,
        '[CTLD] Troops deployed at ' .. mgrs, cfg.msgDuration)
    U.info('CTLD: fallback drop by ' .. pilotUnitName ..
           ' template=' .. templateName)
    return true
end

-- =============================================================
-- Suppression on insertion (cross-system hook)
-- Called by server_core after CTLD confirms a drop.
-- Suppresses enemies within 500 m of the drop point for 20 s.
-- =============================================================

function CT.onTroopDropHook(pilotUnit, side)
    if not DCSCore.suppression then return end

    local pos      = pilotUnit:getPosition().p
    local enemySide = side == coalition.side.BLUE
        and coalition.side.RED or coalition.side.BLUE
    local enemies  = U.getUnitsInRadius(pos, 500, enemySide)

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
-- F10 Menu
-- =============================================================

local function buildF10Menus()
    local cfg = DCSCore.config.ctld
    if not mist then return end   -- menus use MGRS coords

    local function listZones(side)
        local zones = side == coalition.side.BLUE
            and cfg.bluePickupZones or cfg.redPickupZones
        if #zones == 0 then
            U.msgCoalition(side, '[CTLD] No pickup zones configured.', 10)
            return
        end
        local msg = '[CTLD] Pickup zones:\n'
        for i, z in ipairs(zones) do
            local vec  = U.getZoneVec3(z.name)
            local coord = vec and mist.tostringMGRS(vec, 5) or 'unknown'
            msg = msg .. i .. '. ' .. z.name .. '  ' .. coord .. '\n'
        end
        U.msgCoalition(side, msg, 20)
    end

    local function dropStatus(side)
        local count = 0
        for _, data in pairs(CT._manifest) do
            if data.side == side then count = count + 1 end
        end
        U.msgCoalition(side,
            '[CTLD] Helicopters with troops aboard: ' .. count, 10)
    end

    -- BLUE menu
    if #cfg.blueTransports > 0 or #cfg.bluePickupZones > 0 then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'CTLD', nil)
        missionCommands.addCommandForCoalition(
            coalition.side.BLUE, 'List Pickup Zones', m, listZones, coalition.side.BLUE)
        missionCommands.addCommandForCoalition(
            coalition.side.BLUE, 'Troop Lift Status', m, dropStatus, coalition.side.BLUE)
    end

    -- RED menu
    if #cfg.redTransports > 0 or #cfg.redPickupZones > 0 then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.RED, 'CTLD', nil)
        missionCommands.addCommandForCoalition(
            coalition.side.RED, 'List Pickup Zones', m, listZones, coalition.side.RED)
        missionCommands.addCommandForCoalition(
            coalition.side.RED, 'Troop Lift Status', m, dropStatus, coalition.side.RED)
    end
end

-- =============================================================
-- ciribob onTroopDrop hook (wired if available)
-- =============================================================

local function hookCiribobCallbacks()
    if not ctld then return end

    -- ciribob exposes ctld.onTroopDrop = function(unit, zone, side)
    -- Wrap it to fire our cross-system suppression hook.
    local original = ctld.onTroopDrop
    if original then
        ctld.onTroopDrop = function(unit, zone, side)
            original(unit, zone, side)
            CT.onTroopDropHook(unit, side)
        end
        U.info('CTLD: ciribob onTroopDrop hook installed')
    end
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

    local usedCiribob = CT._configureCiribob()
    if not usedCiribob then
        U.info('CTLD: ctld.lua not present — fallback MIST mode active')
    end

    hookCiribobCallbacks()
    buildF10Menus()

    CT._active = true
    U.info('CTLD: setup complete (ciribob=' .. tostring(usedCiribob) .. ')')
end

U.info('ctld_config.lua loaded')
