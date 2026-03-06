-- =============================================================
-- zone_capture.lua
-- DCSCore integration module for Moose_DualCoalitionZoneCapture
--
-- Hooks into the MOOSE ZONE_CAPTURE_COALITION state machine via
-- a lightweight poll loop to fire cross-system events when zones
-- change hands or come under attack:
--
--   • Credits awarded to capturing / defending coalitions
--   • Defenders suppressed when a zone enters "Attacked" state
--   • Optional artillery harassment on newly-captured zones
--   • Optional logistics FOB registration at captured zone positions
--   • Zone-specific IADS SAM prefix application on capture
--   • Admin F10 menu and periodic status broadcast entries
--
-- Dependencies:
--   MOOSE.lua                           (required for zone capture)
--   Moose_DualCoalitionZoneCapture.lua  (defines zoneCaptureObjects, zoneNames)
--   DCSCore.utils, DCSCore.config       (required)
--   DCSCore.credits, DCSCore.suppression, DCSCore.logistics,
--   DCSCore.artillery, DCSCore.iads     (optional — hooks only fire if loaded)
--
-- Load order in Mission Editor:
--   Load MOOSE.lua, then Moose_DualCoalitionZoneCapture.lua,
--   then Moose_DynamicGroundBattle_Plugin.lua (optional),
--   then this module, then scripts/server_core.lua.
-- =============================================================

DCSCore             = DCSCore or {}
DCSCore.zoneCapture = {}

local ZC = DCSCore.zoneCapture
local U  = DCSCore.utils

-- =============================================================
-- Internal state
-- =============================================================

ZC._initialized = false

-- Per-zone tracking table.
-- [zoneName] = { coalition=<side>, state=<string>, lastChange=<time> }
ZC._zones = {}

-- =============================================================
-- Internal helpers
-- =============================================================

local function sideName(side)
    if side == coalition.side.BLUE then return 'BLUE'
    elseif side == coalition.side.RED  then return 'RED'
    else return 'NEUTRAL' end
end

--- Safely call a MOOSE method that may not exist on all framework versions.
local function mooseCall(obj, method, ...)
    if obj and obj[method] then
        local ok, result = pcall(obj[method], obj, ...)
        if ok then return result end
    end
    return nil
end

-- =============================================================
-- Zone event handlers (called internally by the poll loop)
-- =============================================================

--- Zone has been captured by a new coalition.
local function onZoneCaptured(zoneName, newSide, oldSide)
    local cfg = DCSCore.config.zoneCapture

    ZC._zones[zoneName].coalition  = newSide
    ZC._zones[zoneName].lastChange = timer.getTime()

    U.info(string.format('ZONE CAPTURE: %s captured by %s (from %s)',
        zoneName, sideName(newSide), sideName(oldSide)))

    -- Credits: award to capturing coalition
    if cfg.captureCredits > 0 and DCSCore.credits then
        DCSCore.credits.addCredits(newSide, cfg.captureCredits,
            'zone-capture-' .. zoneName)
        U.msgCoalition(newSide,
            string.format('[ZONE] %s captured — +%d credits!',
                zoneName, cfg.captureCredits), 20)
    end

    -- Global broadcast (outText reaches all players)
    if cfg.broadcastCaptures then
        trigger.action.outText(
            string.format('[ZONE] %s captured by %s!',
                zoneName, sideName(newSide)), 20)
    end

    -- IADS: apply any zone-specific SAM prefixes for the new owner
    local samPrefixes = cfg.zoneSAMPrefixes and cfg.zoneSAMPrefixes[zoneName]
    if samPrefixes and DCSCore.iads and DCSCore.iads._initialized and iads then
        for _, prefix in ipairs(samPrefixes) do
            local ok, err = pcall(iads.addAllByPrefix, prefix)
            if not ok then
                U.error('ZONE CAPTURE: iads.addAllByPrefix("' .. prefix ..
                    '") failed: ' .. tostring(err))
            end
        end
        U.info('ZONE CAPTURE: IADS SAM prefixes applied for zone ' .. zoneName)
    end

    -- Logistics: try to register a FOB at the zone centre
    if cfg.fobOnCapture and DCSCore.logistics then
        local zoneVec3 = U.getZoneVec3(zoneName)
        if zoneVec3 then
            timer.scheduleFunction(function()
                DCSCore.logistics._checkFOBBuilt(zoneVec3, newSide)
            end, nil, timer.getTime() + 5)
        end
    end

    -- Artillery: harassment fire on the newly-captured zone from the old owner
    if cfg.artilleryOnCapture and DCSCore.artillery and DCSCore.logistics then
        local zoneVec3 = U.getZoneVec3(zoneName)
        if zoneVec3 then
            -- Find the nearest non-displacing, ammo-capable battery for the old owner
            local bestBattery, bestDist = nil, math.huge
            for battName, bat in pairs(DCSCore.artillery._batteries) do
                if bat.side == oldSide and not bat.displacing then
                    if DCSCore.logistics.hasAmmo(battName) then
                        local grp = U.getGroup(battName)
                        if grp and grp:isExist() then
                            local u1 = grp:getUnit(1)
                            if u1 and u1:isExist() then
                                local d = U.dist2D(u1:getPosition().p, zoneVec3)
                                if d < bestDist then
                                    bestDist    = d
                                    bestBattery = battName
                                end
                            end
                        end
                    end
                end
            end

            if bestBattery then
                local r   = cfg.artilleryTargetRadius or 200
                local ang = math.random() * 2 * math.pi
                local targetPos = {
                    x = zoneVec3.x + math.cos(ang) * math.random(0, r),
                    y = zoneVec3.y,
                    z = zoneVec3.z + math.sin(ang) * math.random(0, r),
                }
                -- Slight delay so displacement/logistics wires have time to settle
                timer.scheduleFunction(function()
                    DCSCore.artillery.fireMission(
                        bestBattery, targetPos,
                        cfg.artilleryRoundsPerMission or 5, oldSide)
                end, nil, timer.getTime() + 10)
                U.info(string.format('ZONE CAPTURE: harassment fire ordered on %s by %s',
                    zoneName, bestBattery))
            end
        end
    end
end

--- Zone has entered "Attacked" state — enemy units contesting it.
local function onZoneAttacked(zoneName, defenderSide)
    local cfg         = DCSCore.config.zoneCapture
    local attackerSide = defenderSide == coalition.side.BLUE
                         and coalition.side.RED or coalition.side.BLUE

    U.info(string.format('ZONE CAPTURE: %s under attack (defender: %s)',
        zoneName, sideName(defenderSide)))

    -- Suppress defenders currently inside the zone
    if cfg.suppressOnAttack and DCSCore.suppression then
        local zoneVec3 = U.getZoneVec3(zoneName)
        if zoneVec3 then
            local radius   = cfg.suppressRadius   or 800
            local duration = cfg.suppressDuration or 20
            local units    = U.getUnitsInRadius(zoneVec3, radius, defenderSide)
            local suppressedGroups = {}
            for _, unit in ipairs(units) do
                if unit and unit:isExist() then
                    local grp = unit:getGroup()
                    if grp and grp:isExist() then
                        local gname = grp:getName()
                        if not suppressedGroups[gname] then
                            suppressedGroups[gname] = true
                            DCSCore.suppression.suppressGroup(gname, duration)
                        end
                    end
                end
            end
        end
    end

    -- Small credit reward for pressuring the zone
    if cfg.attackCredits and cfg.attackCredits > 0 and DCSCore.credits then
        DCSCore.credits.addCredits(attackerSide, cfg.attackCredits,
            'zone-attack-' .. zoneName)
    end
end

--- Zone returned to "Guarded" after being attacked — attack repelled.
local function onZoneDefended(zoneName, defenderSide)
    local cfg = DCSCore.config.zoneCapture

    U.info(string.format('ZONE CAPTURE: %s defended by %s',
        zoneName, sideName(defenderSide)))

    if cfg.defenseCredits > 0 and DCSCore.credits then
        DCSCore.credits.addCredits(defenderSide, cfg.defenseCredits,
            'zone-defense-' .. zoneName)
        U.msgCoalition(defenderSide,
            string.format('[ZONE] %s defended! +%d credits.',
                zoneName, cfg.defenseCredits), 15)
    end
end

--- Zone has become neutral (no units occupying it).
local function onZoneEmpty(zoneName)
    U.info('ZONE CAPTURE: ' .. zoneName .. ' is now neutral/empty')
end

-- =============================================================
-- Poll loop — detects state changes by diffing snapshots
-- =============================================================

local function pollZones()
    if not zoneCaptureObjects then return end

    for i, zoneCapture in ipairs(zoneCaptureObjects) do
        -- Resolve zone name: prefer MOOSE method, fall back to parallel array
        local zoneName
        local zone = mooseCall(zoneCapture, 'GetZone')
        if zone then zoneName = mooseCall(zone, 'GetName') end
        if not zoneName and zoneNames then zoneName = zoneNames[i] end
        if not zoneName then zoneName = 'Zone_' .. tostring(i) end

        -- Read current state from MOOSE FSM
        -- MOOSE uses GetState(); some older builds may use GetCurrentState()
        local currentCoalition = mooseCall(zoneCapture, 'GetCoalition') or 0
        local currentState     = mooseCall(zoneCapture, 'GetState')
                              or mooseCall(zoneCapture, 'GetCurrentState')
                              or 'Unknown'

        -- Initialise tracking entry on first poll (no events fired on init)
        if not ZC._zones[zoneName] then
            ZC._zones[zoneName] = {
                coalition  = currentCoalition,
                state      = currentState,
                lastChange = timer.getTime(),
            }
        else
            local prev = ZC._zones[zoneName]

            -- ── Coalition change → zone captured by new side ──────
            if currentCoalition ~= prev.coalition then
                local oldSide      = prev.coalition
                prev.coalition     = currentCoalition
                prev.lastChange    = timer.getTime()
                onZoneCaptured(zoneName, currentCoalition, oldSide)
            end

            -- ── State transition ──────────────────────────────────
            if currentState ~= prev.state then
                local prevState = prev.state
                prev.state      = currentState

                if currentState == 'Attacked' then
                    onZoneAttacked(zoneName, currentCoalition)
                elseif currentState == 'Guarded' and prevState == 'Attacked' then
                    -- Coalition unchanged → attacker repelled
                    onZoneDefended(zoneName, currentCoalition)
                elseif currentState == 'Empty' then
                    onZoneEmpty(zoneName)
                end
            end
        end
    end

    -- Reschedule for next cycle
    timer.scheduleFunction(pollZones, nil,
        timer.getTime() + (DCSCore.config.zoneCapture.pollInterval or 15))
end

-- =============================================================
-- Public query API
-- =============================================================

--- Returns the coalition side currently owning `zoneName`, or 0 (neutral).
function ZC.getZoneCoalition(zoneName)
    return ZC._zones[zoneName] and ZC._zones[zoneName].coalition or 0
end

--- Returns a snapshot of all tracked zone states.
--- { [zoneName] = { coalition, state, lastChange }, ... }
function ZC.getZoneStatus()
    local out = {}
    for name, data in pairs(ZC._zones) do
        out[name] = {
            coalition  = data.coalition,
            state      = data.state,
            lastChange = data.lastChange,
        }
    end
    return out
end

--- Returns aggregate zone counts by ownership.
--- { blue=N, red=N, neutral=N, contested=N }
function ZC.getZoneCounts()
    local counts = { blue = 0, red = 0, neutral = 0, contested = 0 }
    for _, data in pairs(ZC._zones) do
        local st = data.state or ''
        if st == 'Attacked' then
            counts.contested = counts.contested + 1
        elseif data.coalition == coalition.side.BLUE then
            counts.blue    = counts.blue    + 1
        elseif data.coalition == coalition.side.RED then
            counts.red     = counts.red     + 1
        else
            counts.neutral = counts.neutral + 1
        end
    end
    return counts
end

-- =============================================================
-- Setup
-- =============================================================

function ZC.setup()
    local cfg = DCSCore.config.zoneCapture
    if not cfg or not cfg.enabled then
        U.info('ZONE CAPTURE: disabled in config — skipping setup')
        return
    end

    if not zoneCaptureObjects or #zoneCaptureObjects == 0 then
        U.error('ZONE CAPTURE: zoneCaptureObjects global not found or empty. ' ..
            'Ensure Moose_DualCoalitionZoneCapture.lua is loaded before server_core.lua.')
        return
    end

    -- First poll runs 5 s after setup so MOOSE schedulers can settle
    timer.scheduleFunction(pollZones, nil, timer.getTime() + 5)

    ZC._initialized = true
    U.info(string.format('ZONE CAPTURE: setup complete — %d zones monitored',
        #zoneCaptureObjects))
end

U.info('zone_capture.lua loaded')
