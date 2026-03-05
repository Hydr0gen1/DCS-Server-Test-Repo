-- =============================================================
-- artillery_manager.lua
-- Counter-battery detection, fire-mission assignment,
-- post-fire displacement, and radar survivability.
--
-- PRIMARY MODE  — delegates to ArtilleryEnhancement script
--                 when it is loaded.
-- BUILT-IN MODE — tracks S_EVENT_SHOT / S_EVENT_HIT to detect
--                 outgoing artillery and trigger CB responses.
--
-- Integrates with suppression.lua: CB impacts suppress
-- units near the impact point.
-- Integrates with ctld_config.lua: warns helicopters when
-- CB fire lands near a CTLD drop zone.
--
-- Dependencies (primary): ArtilleryEnhancement.lua, mist.lua
-- Dependencies (built-in): mist.lua (optional but recommended)
-- =============================================================

DCSCore           = DCSCore or {}
DCSCore.artillery = {}

local ART = DCSCore.artillery
local U   = DCSCore.utils

-- groupName -> { side, lastFired, displacing, pos }
ART._batteries = {}
-- Pending incoming-shell records: id -> { origin, side, groupName, fired }
ART._shells    = {}
-- Active fire missions: batteryName -> expiry
ART._missions  = {}

-- =============================================================
-- Artillery Enhancement Script — primary mode
-- =============================================================

local function configureArtilleryEnhancement()
    if not ArtilleryEnhancement then
        U.info('ARTILLERY: ArtilleryEnhancement not loaded — built-in CB active')
        return false
    end

    local cfg = DCSCore.config.artillery

    for _, name in ipairs(cfg.blueBatteries) do
        ArtilleryEnhancement:addFiringBattery(name)
    end
    for _, name in ipairs(cfg.redBatteries) do
        ArtilleryEnhancement:addFiringBattery(name)
    end
    for _, name in ipairs(cfg.blueSpotters) do
        ArtilleryEnhancement:addSpotter(name)
    end
    for _, name in ipairs(cfg.redSpotters) do
        ArtilleryEnhancement:addSpotter(name)
    end
    for _, r in ipairs(cfg.blueRadars) do
        ArtilleryEnhancement:addCounterfireRadar(r.unit, r.type)
    end
    for _, r in ipairs(cfg.redRadars) do
        ArtilleryEnhancement:addCounterfireRadar(r.unit, r.type)
    end

    U.info('ARTILLERY: ArtilleryEnhancement configured')
    return true
end

-- =============================================================
-- Weapon classification helpers
-- =============================================================

-- DCS Weapon.Category values: SHELL=4, ROCKET=5, BOMB=1, MISSILE=3
-- We treat shells and unguided rockets as "artillery" for CB purposes.
local ARTY_SHELL_PARTIALS = {
    -- Common shell/mortar type-name fragments (lower-cased for comparison)
    'm549', 'of-462', 'of-540', 'vog-', 'dpicm',
    'charge', 'frag_mortar', 'hm-', 'krasnopol',
}

local function isArtilleryWeapon(weapon)
    if not weapon or not weapon:isExist() then return false end

    local desc = weapon:getDesc()
    if not desc then return false end

    -- Category 4 = SHELL (most reliable check)
    if desc.category == 4 then return true end

    -- Unguided rockets used by BM-21, MLRS etc. (category 5, guidance = none)
    if desc.category == 5 then
        local guidance = desc.guidance
        -- guidance == 0 or nil => unguided
        if not guidance or guidance == 0 then return true end
    end

    -- Fallback: name pattern matching
    local typeName = string.lower(weapon:getTypeName())
    for _, pat in ipairs(ARTY_SHELL_PARTIALS) do
        if string.find(typeName, pat, 1, true) then return true end
    end

    return false
end

-- =============================================================
-- Shot tracking
-- =============================================================

ART._shotHandler = {}

function ART._shotHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_SHOT then return end

    local weapon = event.weapon
    if not isArtilleryWeapon(weapon) then return end

    local shooter = event.initiator
    if not shooter or not shooter:isExist() then return end

    local shooterGroup = shooter:getGroup()
    if not shooterGroup then return end

    local groupName   = shooterGroup:getName()
    local shooterSide = shooter:getCoalition()
    local shooterPos  = shooter:getPosition().p

    -- Update battery record
    ART._batteries[groupName]             = ART._batteries[groupName] or {}
    ART._batteries[groupName].lastFired   = timer.getTime()
    ART._batteries[groupName].side        = shooterSide
    ART._batteries[groupName].pos         = { x=shooterPos.x, y=shooterPos.y, z=shooterPos.z }
    ART._batteries[groupName].displacing  = ART._batteries[groupName].displacing or false

    -- Store shell record for CB tracking
    -- Key on weapon object pointer converted to string (best available unique id)
    local shellKey = tostring(weapon)
    ART._shells[shellKey] = {
        origin    = { x=shooterPos.x, y=shooterPos.y, z=shooterPos.z },
        side      = shooterSide,
        groupName = groupName,
        fired     = timer.getTime(),
    }

    -- Expire stale shell records after 3 min to prevent memory growth
    timer.scheduleFunction(function()
        ART._shells[shellKey] = nil
    end, nil, timer.getTime() + 180)

    U.debug('ARTILLERY: shot tracked — ' .. groupName ..
            ' (' .. weapon:getTypeName() .. ')')

    -- Schedule displacement
    if DCSCore.config.artillery.displaceAfterShot then
        ART._scheduleDisplacement(groupName)
    end
end

-- =============================================================
-- Impact / Counter-Battery detection
-- Uses S_EVENT_HIT: shell lands on a unit (most reliable event)
-- =============================================================

ART._hitHandler = {}

function ART._hitHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_HIT then return end

    local weapon = event.weapon
    if not isArtilleryWeapon(weapon) then return end

    local target = event.target
    if not target or not target:isExist() then return end

    local impactPos  = target:getPosition().p
    local impactSide = target:getCoalition()

    ART._processImpact(impactPos, impactSide, weapon)
end

function ART._processImpact(impactPos, impactSide, weapon)
    local cfg = DCSCore.config.artillery

    -- Find the matching outgoing shell record
    local origin, originGroup, originSide

    -- Prefer weapon-keyed match; fall back to side-based search
    local shellKey = tostring(weapon)
    local record   = ART._shells[shellKey]

    if record and record.side ~= impactSide then
        origin      = record.origin
        originGroup = record.groupName
        originSide  = record.side
        ART._shells[shellKey] = nil
    else
        -- Fallback: find the most recent opposing-side shell
        for k, rec in pairs(ART._shells) do
            if rec.side ~= impactSide then
                origin      = rec.origin
                originGroup = rec.groupName
                originSide  = rec.side
                ART._shells[k] = nil
                break
            end
        end
    end

    if not origin then return end

    -- Suppress units around the impact (cross-system)
    if cfg.cbSuppressionEnabled and DCSCore.suppression then
        local targets = U.getUnitsInRadius(impactPos, cfg.cbSuppressRadius, impactSide)
        for _, u in ipairs(targets) do
            if u:isExist() then
                local grp = u:getGroup()
                if grp and grp:isExist() then
                    DCSCore.suppression.suppressGroup(grp:getName(), cfg.cbHoldTime)
                end
            end
        end
    end

    -- Warn if impact is near a CTLD drop zone (cross-system)
    ART._warnCTLDZones(impactPos, impactSide)

    -- Notify both coalitions of detected origin
    local mgrs = mist and mist.tostringMGRS(origin, 5) or
        string.format('(x=%.0f z=%.0f)', origin.x, origin.z)

    U.msgCoalition(impactSide,
        '[CB RADAR] Artillery origin detected: ' .. mgrs ..
        ' (' .. (originGroup or '?') .. ')', 20)
    U.msgCoalition(originSide,
        '[CB RADAR] Counter-battery fire detected!', 10)

    -- Assign CB fire mission
    ART._assignFireMission(impactSide, origin, originGroup)

    U.info('ARTILLERY: CB triggered — origin=' .. (originGroup or mgrs))
end

-- =============================================================
-- CTLD zone warning (cross-system)
-- =============================================================

function ART._warnCTLDZones(impactPos, side)
    if not DCSCore.config.ctld then return end
    local ctldCfg = DCSCore.config.ctld
    local zones   = side == coalition.side.BLUE
        and ctldCfg.blueDropZones or ctldCfg.redDropZones

    for _, z in ipairs(zones) do
        local zVec = U.getZoneVec3(z.name)
        if zVec then
            local dist = U.dist2D(impactPos, zVec)
            if dist < 2000 then
                U.msgCoalition(side,
                    string.format('[ARTY WARNING] Artillery impact %.0fm from CTLD zone %s!',
                        dist, z.name), 20)
            end
        end
    end
end

-- =============================================================
-- Fire-Mission Assignment
-- =============================================================

--- Assign the nearest available friendly battery to fire on `targetPos`.
function ART._assignFireMission(friendlySide, targetPos, targetGroupName)
    local cfg       = DCSCore.config.artillery
    local batteries = friendlySide == coalition.side.BLUE
        and cfg.blueBatteries or cfg.redBatteries

    if #batteries == 0 then
        U.debug('ARTILLERY: no batteries configured for side ' .. friendlySide)
        return
    end

    -- Pick nearest non-displacing battery
    local bestName = nil
    local bestDist = math.huge

    for _, name in ipairs(batteries) do
        local group = U.getGroup(name)
        if group and group:isExist() then
            local state = ART._batteries[name]
            if not (state and state.displacing) then
                local unit1 = group:getUnit(1)
                if unit1 and unit1:isExist() then
                    local pos = unit1:getPosition().p
                    local d   = U.dist2D(pos, targetPos)
                    if d < bestDist then
                        bestDist = d
                        bestName = name
                    end
                end
            end
        end
    end

    if not bestName then
        U.debug('ARTILLERY: no available battery for CB mission')
        return
    end

    ART.fireMission(bestName, targetPos, 20, friendlySide)
end

-- =============================================================
-- Fire Mission (public)
-- =============================================================

--- Direct a battery to fire `rounds` at `targetPos`.
---@param batteryName  string
---@param targetPos    Vec3
---@param rounds       number  (default 20)
---@param msgSide      number|nil  coalition.side.* for player message
function ART.fireMission(batteryName, targetPos, rounds, msgSide)
    local group = U.getGroup(batteryName)
    if not group then
        U.error('ARTILLERY.fireMission: group not found — ' .. batteryName)
        return false
    end

    rounds = rounds or 20

    -- DCS FireAtPoint task (ground artillery)
    -- point.x = north, point.y = east (DCS 2D ground coord convention)
    group:getController():setTask({
        id = 'FireAtPoint',
        params = {
            point            = { x = targetPos.x, y = targetPos.z },
            radius           = 150,
            expendQty        = rounds,
            expendQtyEnabled = true,
            weaponType       = 4,   -- Weapon.Category.SHELL
        },
    })

    if msgSide then
        local mgrs = mist and mist.tostringMGRS(targetPos, 5) or
            string.format('(x=%.0f z=%.0f)', targetPos.x, targetPos.z)
        U.msgCoalition(msgSide,
            '[ARTY] Fire mission — ' .. batteryName ..
            ' firing ' .. rounds .. ' rnds at ' .. mgrs, 15)
    end

    U.info('ARTILLERY: fire mission — ' .. batteryName .. ' x' .. rounds)
    return true
end

-- =============================================================
-- Post-Fire Displacement
-- =============================================================

function ART._scheduleDisplacement(groupName)
    local cfg = DCSCore.config.artillery
    timer.scheduleFunction(function()
        local state = ART._batteries[groupName]
        if not state then return end

        local elapsed = timer.getTime() - (state.lastFired or 0)
        if elapsed < cfg.displaceDelay then
            -- Not quiet long enough — check again
            ART._scheduleDisplacement(groupName)
            return
        end

        if state.displacing then return end

        local group = U.getGroup(groupName)
        if not group or not group:isExist() then
            ART._batteries[groupName] = nil
            return
        end

        state.displacing = true
        U.debug('ARTILLERY: displacing ' .. groupName)

        if mist then
            mist.groupRandomDistSelf(
                group, cfg.displaceRadius, 'Cone', cfg.displaceRadius, 100)
        end

        -- Allow re-fire after displacement settles
        timer.scheduleFunction(function()
            if ART._batteries[groupName] then
                ART._batteries[groupName].displacing = false
            end
        end, nil, timer.getTime() + 120)

    end, nil, timer.getTime() + cfg.displaceDelay)
end

-- =============================================================
-- Counterfire Radar Survivability
-- Displaces a radar unit that is hit, keeping the sensor alive.
-- =============================================================

local function isConfiguredRadar(unitName)
    local cfg = DCSCore.config.artillery
    for _, r in ipairs(cfg.blueRadars) do
        if r.unit == unitName then return true end
    end
    for _, r in ipairs(cfg.redRadars) do
        if r.unit == unitName then return true end
    end
    return false
end

ART._radarSurvHandler = {}

function ART._radarSurvHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_HIT then return end

    local target = event.target
    if not target or not target:isExist() then return end

    local unitName = target:getName()
    if not isConfiguredRadar(unitName) then return end

    local group = target:getGroup()
    if group and group:isExist() and mist then
        mist.groupRandomDistSelf(group, 300, 'Cone', 250, 50)
        U.info('ARTILLERY: radar ' .. unitName .. ' displaced under fire')
    end
end

-- =============================================================
-- Public API
-- =============================================================

function ART.addBattery(groupName, side)
    ART._batteries[groupName] = {
        side       = side,
        lastFired  = 0,
        displacing = false,
    }
end

function ART.setup()
    local cfg = DCSCore.config.artillery
    if not cfg.enabled then
        U.info('ARTILLERY: disabled in config')
        return
    end

    -- Register batteries and radars from config tables
    for _, name in ipairs(cfg.blueBatteries) do
        ART.addBattery(name, coalition.side.BLUE)
    end
    for _, name in ipairs(cfg.redBatteries) do
        ART.addBattery(name, coalition.side.RED)
    end

    -- Try primary mode
    configureArtilleryEnhancement()

    -- Always register built-in CB handlers (they co-exist with ArtEnhancement)
    world.addEventHandler(ART._shotHandler)
    world.addEventHandler(ART._hitHandler)
    world.addEventHandler(ART._radarSurvHandler)

    local battCount = #cfg.blueBatteries + #cfg.redBatteries
    local radCount  = #cfg.blueRadars    + #cfg.redRadars
    U.info(string.format('ARTILLERY: setup complete — %d batteries, %d radars',
        battCount, radCount))
end

U.info('artillery_manager.lua loaded')
