-- =============================================================
-- ctld_logistics.lua  (v2 — with SAM ammo + smart auto-resupply)
-- =============================================================
--
-- SUPPLY CHAIN (ARTILLERY)
--   Batteries have a finite round pool. Fires deducted via
--   server_core hook. Winchester → fire missions blocked.
--   Manual/auto convoys or nearby supply trucks restore rounds.
--
-- SAM AMMO TRACKING
--   Every SAM launcher type has a missile capacity (see table).
--   S_EVENT_SHOT tracks each missile fired. At LOW threshold a
--   warning is sent. At WINCHESTER the radar shuts off via
--   ALARM_STATE GREEN and the SAM is flagged for resupply.
--   After a resupply convoy arrives, a reload delay elapses
--   before radar is restored (realistic TEL reload time).
--
-- SMART AUTO-RESUPPLY CONVOYS
--   Every autoResupplyCheckInterval seconds all tracked batteries
--   and SAMs are evaluated:
--     1. Sort by urgency: Winchester > Critical (< 25%) > Low
--     2. Skip if a convoy is already en route
--     3. Deduct credits (if credits system loaded)
--     4. Find nearest HQ zone to the target
--     5. Clone convoy template there, drive directly to unit pos
--     6. Watch for arrival; apply resupply on arrival
--     7. If convoy is destroyed en route: refund half credits,
--        clear pending flag so another can be dispatched
--   maxAutoConvoysPerSide limits simultaneous auto convoys.
--
-- MANUAL CONVOY DISPATCH (F10 menu)
--   Players can dispatch a convoy from any configured HQ zone
--   toward the nearest FOB or drop zone. Credit cost deducted.
--
-- FOB TRACKING  /  JTAC REGISTRATION  /  SAM IADS REGISTRATION
--   Unchanged from v1 — see original comments.
--
-- PILOT EXTRACTION
--   S_EVENT_DEAD on player aircraft → ctld.createExtractZone().
--
-- Dependencies: MIST, ctld.lua (optional), credits.lua (optional)
-- =============================================================

DCSCore           = DCSCore or {}
DCSCore.logistics = {}

local LOG = DCSCore.logistics
local U   = DCSCore.utils

-- =============================================================
-- State tables
-- =============================================================

LOG._batteries          = {}  -- groupName -> { side, rounds, maxRounds, lastResupply, status }
LOG._samAmmo            = {}  -- groupName -> { side, missiles, maxMissiles, lastFired, status, lowWarned }
LOG._fobs               = {}  -- id        -> { pos, side, builtAt, name }
LOG._convoys            = {}  -- groupName -> { side, spawnTime, destination, destType, destPos, auto }
LOG._jtacs              = {}  -- unitName  -> { side, pos, registeredAt }
LOG._autoResupplyPending = {}  -- targetName -> true (suppress duplicate dispatch)

-- =============================================================
-- Constants
-- =============================================================

-- CTLD crate weight ranges that map to SAM systems (ciribob's ID scheme)
local SAM_CRATE_WEIGHT_MIN = 1003.0
local SAM_CRATE_WEIGHT_MAX = 1005.99
local JTAC_CRATE_WEIGHTS   = { 1001.01, 1001.11, 1006.01, 1006.11 }

-- Supply truck type-name substrings (manual resupply by proximity)
local SUPPLY_UNIT_TYPES = {
    'm-818', 'ural', 'kamaz', 'ammo', 'supply', 'hummer', 'hmmwv',
}

-- SAM-related DCS unit attributes for crate-assembly scanning
local SAM_ATTRIBUTES = { 'SAM SR', 'SAM TR', 'SAM LL', 'SAM CC', 'AAA' }

-- Missile capacity per SAM launcher unit type.
-- Key = DCS unit type name (exact, case-sensitive).
-- Value = missiles per launcher vehicle.
local SAM_LAUNCHER_MISSILES = {
    -- SA-6  Kub
    ['Kub 2P25 ln']              = 3,
    -- SA-11 BUK
    ['Buk 9A310M1']              = 4,
    ['SA-17 Buk M2 9A317 ln']    = 4,
    -- SA-17 BUK-M2
    ['Buk-M2 9A317 SP']          = 4,
    -- S-300 PS / PMU-1
    ['S-300PS 5P85C ln']         = 4,
    ['S-300PS 5P85D ln']         = 4,
    ['S-300PMU-1 5P85SE ln']     = 4,
    ['S-300PMU-1 5P85SU ln']     = 4,
    -- SA-3  Neva / Pechora
    ['5p73 s-125 ln']            = 4,
    ['Pechora 5P73']             = 4,
    -- HAWK
    ['Hawk ln']                  = 3,
    ['I-HAWK MIM-23B']           = 3,
    -- Patriot
    ['Patriot ln']               = 4,
    -- Roland
    ['Roland ADS']               = 2,
    -- Chaparral
    ['M48 Chaparral']            = 4,
    -- Avenger (Stinger)
    ['M1097 Avenger']            = 8,
    -- Linebacker
    ['M6 Linebacker']            = 4,
    -- SA-15 Tor
    ['Tor 9A331']                = 8,
    -- SA-8  Osa
    ['Osa 9A33 ln']              = 4,
    -- SA-13 Strela-10
    ['Strela-10M3']              = 4,
    -- SA-19 Tunguska (SAM component; cannon is unlimited)
    ['2S6 Tunguska']             = 8,
    -- NASAMS
    ['NASAMS_LN_B']              = 6,
    ['NASAMS_LN_C']              = 6,
    -- Gepard, Shilka — cannon only, no missile tracking
    ['Gepard']                   = 0,
    ['ZSU-23-4 Shilka']          = 0,
}

-- Ammo states (for logging / messaging)
local STATE_OK        = 'OK'
local STATE_LOW       = 'LOW'
local STATE_CRITICAL  = 'CRITICAL'
local STATE_WINCHESTER = 'WINCHESTER'

-- =============================================================
-- Battery ammo management
-- =============================================================

function LOG.registerBattery(groupName, side)
    local lcfg = DCSCore.config.logistics
    LOG._batteries[groupName] = {
        side         = side,
        rounds       = lcfg.batteryStartingRounds,
        maxRounds    = lcfg.batteryStartingRounds,
        lastResupply = timer.getTime(),
        status       = STATE_OK,
    }
    U.debug('LOGISTICS: battery registered — ' .. groupName)
end

function LOG.consumeAmmo(groupName, rounds)
    local bat = LOG._batteries[groupName]
    if not bat then return true end
    if bat.rounds <= 0 then return false end
    bat.rounds = math.max(0, bat.rounds - rounds)
    -- Update status
    local pct = bat.rounds / bat.maxRounds
    if bat.rounds == 0 then
        bat.status = STATE_WINCHESTER
    elseif pct < 0.25 then
        bat.status = STATE_CRITICAL
    elseif pct < 0.50 then
        bat.status = STATE_LOW
    else
        bat.status = STATE_OK
    end
    U.debug(string.format('LOGISTICS: %s fired %d rnds — %d left [%s]',
        groupName, rounds, bat.rounds, bat.status))
    return true
end

function LOG.hasAmmo(groupName)
    local bat = LOG._batteries[groupName]
    if not bat then return true end
    return bat.rounds > 0
end

function LOG.resupply(groupName, amount)
    local bat = LOG._batteries[groupName]
    if not bat then return end
    amount           = amount or DCSCore.config.logistics.ammoResupplyAmount
    bat.rounds       = math.min(bat.rounds + amount, bat.maxRounds)
    bat.lastResupply = timer.getTime()
    bat.status       = bat.rounds > 0 and STATE_OK or STATE_WINCHESTER
    LOG._autoResupplyPending[groupName] = nil
    U.info(string.format('LOGISTICS: %s resupplied +%d rnds (%d/%d)',
        groupName, amount, bat.rounds, bat.maxRounds))
    U.msgCoalition(bat.side,
        string.format('[LOGISTICS] %s resupplied — %d rounds ready.',
            groupName, bat.rounds), 12)
end

-- =============================================================
-- SAM ammo management
-- =============================================================

--- Scan a SAM group's units to calculate total starting missiles.
function LOG.initSAMAmmo(groupName, side)
    local group = U.getGroup(groupName)
    if not group or not group:isExist() then return end

    local total = 0
    for i = 1, group:getSize() do
        local unit = group:getUnit(i)
        if unit and unit:isExist() then
            local cap = SAM_LAUNCHER_MISSILES[unit:getTypeName()]
            if cap and cap > 0 then
                total = total + cap
            end
        end
    end

    if total == 0 then
        -- No known launcher types: skip tracking for this group
        U.debug('LOGISTICS: SAM ' .. groupName .. ' has no trackable launchers — skipping')
        return
    end

    LOG._samAmmo[groupName] = {
        side        = side,
        missiles    = total,
        maxMissiles = total,
        lastFired   = 0,
        status      = STATE_OK,
        lowWarned   = false,
    }
    U.debug(string.format('LOGISTICS: SAM %s initialized — %d missiles', groupName, total))
end

--- Called when a SAM group reaches zero missiles.
local function samWinchester(groupName, samData)
    samData.status = STATE_WINCHESTER

    local group = U.getGroup(groupName)
    if group and group:isExist() then
        group:getController():setOption(
            AI.Option.Ground.id.ALARM_STATE,
            AI.Option.Ground.val.ALARM_STATE.GREEN)
        -- Override IADS dark window to effectively permanent
        if DCSCore.iads then
            DCSCore.iads.goDark(groupName, 86400)
        end
    end

    U.msgCoalition(samData.side,
        '[LOGISTICS] SAM WINCHESTER: ' .. groupName ..
        ' — radar offline, awaiting resupply!', 25)
    U.info('LOGISTICS: SAM Winchester — ' .. groupName)
end

--- Restore SAM missiles and bring radar back online after reload delay.
function LOG.resupplySAM(groupName, amount)
    local samData = LOG._samAmmo[groupName]
    if not samData then return end

    amount             = amount or samData.maxMissiles
    samData.missiles   = math.min(samData.missiles + amount, samData.maxMissiles)
    samData.lowWarned  = false
    samData.status     = samData.missiles > 0 and STATE_OK or STATE_WINCHESTER
    LOG._autoResupplyPending[groupName] = nil

    local reloadDelay = DCSCore.config.logistics.samReloadDelay or 60

    U.msgCoalition(samData.side,
        string.format('[LOGISTICS] %s resupply arrived — reloading in %ds.',
            groupName, reloadDelay), 15)
    U.info(string.format('LOGISTICS: SAM %s resupplied +%d missiles (%d/%d) reload in %ds',
        groupName, amount, samData.missiles, samData.maxMissiles, reloadDelay))

    -- Restore radar after reload delay
    local side = samData.side
    timer.scheduleFunction(function()
        local group = U.getGroup(groupName)
        if group and group:isExist() and samData.missiles > 0 then
            group:getController():setOption(
                AI.Option.Ground.id.ALARM_STATE,
                AI.Option.Ground.val.ALARM_STATE.RED)
            if DCSCore.iads then
                DCSCore.iads._evading[groupName] = nil
            end
            U.msgCoalition(side,
                '[LOGISTICS] SAM ' .. groupName .. ' reloaded — radar online.', 15)
        end
    end, nil, timer.getTime() + reloadDelay)
end

-- =============================================================
-- SAM shot event handler
-- =============================================================

LOG._samShotHandler = {}

function LOG._samShotHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_SHOT then return end

    local weapon = event.weapon
    if not weapon or not weapon:isExist() then return end

    -- Must be a guided missile (category 3 = MISSILE)
    local desc = weapon:getDesc()
    if not desc or desc.category ~= 3 then return end

    local shooter = event.initiator
    if not shooter or not shooter:isExist() then return end
    if shooter:getCategory() ~= Object.Category.UNIT then return end

    local group = shooter:getGroup()
    if not group or not group:isExist() then return end

    local gname   = group:getName()
    local samData = LOG._samAmmo[gname]
    if not samData then return end

    -- Deduct one missile
    samData.missiles  = math.max(0, samData.missiles - 1)
    samData.lastFired = timer.getTime()

    local pct = samData.missiles / samData.maxMissiles
    if samData.missiles == 0 then
        samWinchester(gname, samData)
    elseif pct < 0.25 and not samData.lowWarned then
        samData.lowWarned = true
        samData.status    = STATE_CRITICAL
        U.msgCoalition(samData.side,
            string.format('[LOGISTICS] SAM CRITICAL: %s — %d/%d missiles remaining.',
                gname, samData.missiles, samData.maxMissiles), 18)
    elseif pct < 0.50 and samData.status == STATE_OK then
        samData.status = STATE_LOW
        U.msgCoalition(samData.side,
            string.format('[LOGISTICS] SAM LOW AMMO: %s — %d/%d missiles.',
                gname, samData.missiles, samData.maxMissiles), 12)
    end
end

-- =============================================================
-- Supply truck proximity polling  (manual trucks near batteries/SAMs)
-- =============================================================

local function isSupplyVehicle(unit)
    if not unit or not unit:isExist() then return false end
    local tn = string.lower(unit:getTypeName())
    for _, pat in ipairs(SUPPLY_UNIT_TYPES) do
        if string.find(tn, pat, 1, true) then return true end
    end
    return false
end

local function checkSupplyTrucks()
    local lcfg  = DCSCore.config.logistics
    local radius = lcfg.supplyRadiusBattery or 300

    -- Artillery batteries
    for battName, bat in pairs(LOG._batteries) do
        if bat.rounds < bat.maxRounds then
            local group = U.getGroup(battName)
            if group and group:isExist() then
                local u1 = group:getUnit(1)
                if u1 and u1:isExist() then
                    local candidates = U.getUnitsInRadius(u1:getPosition().p, radius, bat.side)
                    for _, c in ipairs(candidates) do
                        if isSupplyVehicle(c) then
                            local age = timer.getTime() - (bat.lastResupply or 0)
                            if age > 120 then
                                LOG.resupply(battName)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- SAM groups
    for samName, samData in pairs(LOG._samAmmo) do
        if samData.missiles < samData.maxMissiles then
            local group = U.getGroup(samName)
            if group and group:isExist() then
                local u1 = group:getUnit(1)
                if u1 and u1:isExist() then
                    local candidates = U.getUnitsInRadius(u1:getPosition().p, radius, samData.side)
                    for _, c in ipairs(candidates) do
                        if isSupplyVehicle(c) then
                            -- SAMs need 120s cooldown between truck resupplies too
                            local age = timer.getTime() - (samData.lastFired or 0)
                            if age > 120 then
                                LOG.resupplySAM(samName)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    timer.scheduleFunction(checkSupplyTrucks, nil,
        timer.getTime() + (DCSCore.config.logistics.supplyCheckInterval or 60))
end

-- =============================================================
-- Direct convoy dispatch (auto-resupply + manual to unit pos)
-- =============================================================

--- Spawn a convoy at the nearest HQ zone and drive it to `targetPos`.
--- `targetName` / `targetType` are used on arrival to apply resupply.
local function dispatchDirectConvoy(side, targetName, targetType, targetPos)
    if not mist then return false end

    local lcfg    = DCSCore.config.logistics
    local template = side == coalition.side.BLUE
                     and lcfg.blueConvoyTemplate
                     or  lcfg.redConvoyTemplate

    if not template or template == '' then
        U.error('LOGISTICS: no convoy template configured for side ' .. side)
        return false
    end

    -- Find nearest HQ zone
    local hqZones = side == coalition.side.BLUE
                    and lcfg.blueHQZones or lcfg.redHQZones
    if not hqZones or #hqZones == 0 then
        U.debug('LOGISTICS: no HQ zones configured — convoy not dispatched')
        return false
    end

    local bestHQ, bestDist = nil, math.huge
    for _, zName in ipairs(hqZones) do
        local zv = U.getZoneVec3(zName)
        if zv then
            local d = U.dist2D(zv, targetPos)
            if d < bestDist then bestDist = d; bestHQ = zName end
        end
    end
    if not bestHQ then return false end

    -- Clone convoy template at HQ
    local newGroup = mist.cloneInZone(template, bestHQ)
    if not newGroup then
        U.error('LOGISTICS: cloneInZone failed for template ' .. template)
        return false
    end

    local convoyName = newGroup:getName()
    LOG._convoys[convoyName] = {
        side      = side,
        spawnTime = timer.getTime(),
        destination = targetName,
        destType  = targetType,
        destPos   = { x=targetPos.x, y=targetPos.y, z=targetPos.z },
        auto      = true,
    }

    mist.groupToPoint(newGroup, targetPos)

    U.info(string.format('LOGISTICS: convoy %s dispatched from %s -> %s [%s]',
        convoyName, bestHQ, targetName, targetType))

    -- Watch for arrival or destruction
    LOG._watchDirectConvoy(convoyName, side, targetName, targetType)
    return true
end

function LOG._watchDirectConvoy(convoyName, side, targetName, targetType)
    timer.scheduleFunction(function()
        local state = LOG._convoys[convoyName]
        if not state then return end   -- already handled

        local group = U.getGroup(convoyName)
        if not group or not group:isExist() then
            -- Convoy destroyed
            LOG._convoys[convoyName] = nil
            LOG._autoResupplyPending[targetName] = nil

            -- Partial credit refund
            if DCSCore.credits then
                local cost    = targetType == 'sam'
                                and (DCSCore.config.logistics.samResupplyCost or 75)
                                or  (DCSCore.config.logistics.autoConvoyCost  or 50)
                local refund  = math.floor(cost * 0.5)
                DCSCore.credits.addCredits(side, refund, 'convoy-destroyed-refund')
                U.msgCoalition(side,
                    string.format('[LOGISTICS] Resupply convoy destroyed! Refund: %d cr.', refund), 20)
            else
                U.msgCoalition(side, '[LOGISTICS] Resupply convoy destroyed!', 20)
            end
            return
        end

        -- Update destination position (unit may have moved)
        local targetGroup = U.getGroup(targetName)
        if targetGroup and targetGroup:isExist() then
            local tu1 = targetGroup:getUnit(1)
            if tu1 and tu1:isExist() then
                state.destPos = tu1:getPosition().p
            end
        end

        local u1 = group:getUnit(1)
        if u1 and u1:isExist() then
            local dist = U.dist2D(u1:getPosition().p, state.destPos)
            if dist <= (DCSCore.config.logistics.supplyRadiusBattery or 300) then
                -- Arrived
                LOG._convoys[convoyName]         = nil
                LOG._autoResupplyPending[targetName] = nil

                if targetType == 'sam' then
                    LOG.resupplySAM(targetName)
                else
                    LOG.resupply(targetName)
                end
                return
            end
        end

        LOG._watchDirectConvoy(convoyName, side, targetName, targetType)
    end, nil, timer.getTime() + 30)
end

-- =============================================================
-- Manual convoy  (F10 menu → HQ zone → nearest FOB / drop zone)
-- =============================================================

function LOG.spawnConvoy(side, fromZoneName, toZoneName)
    if not mist then
        U.error('LOGISTICS: MIST required for convoy spawning')
        return false
    end

    local lcfg    = DCSCore.config.logistics
    local template = side == coalition.side.BLUE
                     and lcfg.blueConvoyTemplate
                     or  lcfg.redConvoyTemplate

    if not template or template == '' then
        U.msgCoalition(side, '[LOGISTICS] No convoy template configured.', 10)
        return false
    end

    local fromVec = U.getZoneVec3(fromZoneName)
    local toVec   = U.getZoneVec3(toZoneName)
    if not fromVec or not toVec then
        U.msgCoalition(side, '[LOGISTICS] Zone not found.', 10)
        return false
    end

    local newGroup = mist.cloneInZone(template, fromZoneName)
    if not newGroup then
        U.error('LOGISTICS: cloneInZone failed — ' .. template)
        return false
    end

    local convoyName = newGroup:getName()
    LOG._convoys[convoyName] = {
        side        = side,
        spawnTime   = timer.getTime(),
        destination = toZoneName,
        destType    = 'zone',
        destPos     = toVec,
        auto        = false,
    }

    mist.groupToPoint(newGroup, toVec)

    U.msgCoalition(side,
        '[LOGISTICS] Convoy dispatched: ' .. fromZoneName .. ' → ' .. toZoneName, 15)
    U.info('LOGISTICS: manual convoy ' .. convoyName .. ' -> ' .. toZoneName)

    LOG._watchZoneConvoy(convoyName, toVec, side)
    return true
end

function LOG._watchZoneConvoy(convoyName, destPos, side)
    timer.scheduleFunction(function()
        local state = LOG._convoys[convoyName]
        if not state then return end

        local group = U.getGroup(convoyName)
        if not group or not group:isExist() then
            LOG._convoys[convoyName] = nil
            U.msgCoalition(side, '[LOGISTICS] Convoy lost in transit!', 20)
            return
        end

        local u1 = group:getUnit(1)
        if u1 and u1:isExist() then
            local dist = U.dist2D(u1:getPosition().p, destPos)
            if dist <= (DCSCore.config.logistics.supplyRadiusFOB or 500) then
                LOG._convoys[convoyName] = nil
                -- Resupply all batteries & SAMs in the area
                local radius = DCSCore.config.logistics.supplyRadiusFOB or 500
                for battName, bat in pairs(LOG._batteries) do
                    if bat.side == side then
                        local g = U.getGroup(battName)
                        if g and g:isExist() then
                            local bu = g:getUnit(1)
                            if bu and bu:isExist() and
                               U.dist2D(bu:getPosition().p, destPos) <= radius then
                                LOG.resupply(battName)
                            end
                        end
                    end
                end
                for samName, samData in pairs(LOG._samAmmo) do
                    if samData.side == side then
                        local g = U.getGroup(samName)
                        if g and g:isExist() then
                            local su = g:getUnit(1)
                            if su and su:isExist() and
                               U.dist2D(su:getPosition().p, destPos) <= radius then
                                LOG.resupplySAM(samName)
                            end
                        end
                    end
                end
                U.msgCoalition(side,
                    '[LOGISTICS] Convoy arrived at ' .. state.destination ..
                    ' — area resupplied.', 20)
                return
            end
        end
        LOG._watchZoneConvoy(convoyName, destPos, side)
    end, nil, timer.getTime() + 30)
end

-- =============================================================
-- Smart auto-resupply  (periodic priority poll)
-- =============================================================

local function buildResupplyQueue()
    local queue = {}

    for battName, bat in pairs(LOG._batteries) do
        if not LOG._autoResupplyPending[battName] then
            local pct = bat.rounds / bat.maxRounds
            if pct <= (DCSCore.config.logistics.autoResupplyThreshold or 0.25) then
                table.insert(queue, {
                    name     = battName,
                    side     = bat.side,
                    pct      = pct,
                    type     = 'battery',
                    priority = bat.rounds == 0 and 1 or 2,
                })
            end
        end
    end

    for samName, samData in pairs(LOG._samAmmo) do
        if not LOG._autoResupplyPending[samName] then
            local pct = samData.missiles / samData.maxMissiles
            if pct <= (DCSCore.config.logistics.samAutoResupplyThreshold or 0.25) then
                table.insert(queue, {
                    name     = samName,
                    side     = samData.side,
                    pct      = pct,
                    type     = 'sam',
                    priority = samData.missiles == 0 and 1 or 2,
                })
            end
        end
    end

    -- Sort: Winchester first (priority 1), then lowest % within each priority
    table.sort(queue, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.pct < b.pct
    end)

    return queue
end

local function autoResupplyPoll()
    local lcfg = DCSCore.config.logistics
    if not lcfg.autoResupplyEnabled then
        timer.scheduleFunction(autoResupplyPoll, nil,
            timer.getTime() + (lcfg.autoResupplyCheckInterval or 120))
        return
    end

    -- Count active auto convoys per side
    local activeConvoys = { [coalition.side.BLUE] = 0, [coalition.side.RED] = 0 }
    for _, conv in pairs(LOG._convoys) do
        if conv.auto and conv.side then
            activeConvoys[conv.side] = (activeConvoys[conv.side] or 0) + 1
        end
    end

    local maxPerSide = lcfg.maxAutoConvoysPerSide or 2
    local queue      = buildResupplyQueue()

    for _, need in ipairs(queue) do
        if activeConvoys[need.side] < maxPerSide then
            -- Determine credit cost
            local cost = need.type == 'sam'
                         and (lcfg.samResupplyCost  or 75)
                         or  (lcfg.autoConvoyCost   or 50)

            local canAfford = true
            if DCSCore.credits then
                canAfford = DCSCore.credits.spendCredits(need.side, cost)
            end

            if canAfford then
                -- Get current unit position
                local targetPos = nil
                local group = U.getGroup(need.name)
                if group and group:isExist() then
                    local u1 = group:getUnit(1)
                    if u1 and u1:isExist() then targetPos = u1:getPosition().p end
                end

                if targetPos then
                    local ok = dispatchDirectConvoy(need.side, need.name, need.type, targetPos)
                    if ok then
                        LOG._autoResupplyPending[need.name] = true
                        activeConvoys[need.side] = activeConvoys[need.side] + 1
                        if DCSCore.credits then
                            U.msgCoalition(need.side,
                                string.format('[LOGISTICS] Auto-resupply convoy to %s — cost: %d cr (balance: %d)',
                                    need.name, cost,
                                    DCSCore.credits.getCredits(need.side)), 12)
                        end
                    elseif DCSCore.credits then
                        -- No HQ zones or template — refund
                        DCSCore.credits.addCredits(need.side, cost, 'auto-dispatch-failed-refund')
                    end
                end
            else
                -- Not enough credits — warn once per Winchester
                if need.priority == 1 then
                    U.msgCoalition(need.side,
                        string.format('[LOGISTICS] %s needs resupply but insufficient credits (%d needed).',
                            need.name, cost), 15)
                end
            end
        end
    end

    timer.scheduleFunction(autoResupplyPoll, nil,
        timer.getTime() + (lcfg.autoResupplyCheckInterval or 120))
end

-- =============================================================
-- FOB tracking
-- =============================================================

local function recordFOB(pos, side, label)
    local id = 'FOB_' .. math.random(10000, 99999)
    LOG._fobs[id] = { pos=pos, side=side, builtAt=timer.getTime(), name=label or id }
    U.msgCoalition(side,
        '[LOGISTICS] FOB established at ' ..
        (mist and mist.tostringMGRS(pos, 5) or '?'), 20)
    trigger.action.smoke(pos, trigger.smokeColor.Green)
    U.info('LOGISTICS: FOB recorded — ' .. (label or id))
end

function LOG._checkFOBBuilt(pos, side)
    local found = false
    world.searchObjects(Object.Category.STATIC, {
        id     = world.VolumeType.SPHERE,
        params = { point=pos, radius=200 },
    }, function(obj)
        if found then return false end
        if obj and obj:isExist() then
            local n = string.lower(obj:getName())
            if string.find(n, 'fob', 1, true) or string.find(n, 'ctld', 1, true) then
                recordFOB(obj:getPosition().p, side, obj:getName())
                found = true; return false
            end
        end
        return true
    end)
end

-- =============================================================
-- CTLD crate-drop callback
-- =============================================================

function LOG.onCrateDropped(args)
    local unit   = args and args.unit
    local side   = args and args.side
    local weight = args and args.crateWeight
    if not side then return end

    local dropPos = unit and unit:isExist() and unit:getPosition().p
    if not dropPos then return end

    local lcfg = DCSCore.config.logistics
    local snap = { x=dropPos.x, y=dropPos.y, z=dropPos.z }

    if weight and weight >= SAM_CRATE_WEIGHT_MIN and weight <= SAM_CRATE_WEIGHT_MAX then
        if lcfg.samAutoRegister then
            timer.scheduleFunction(function()
                LOG._scanForDeployedSAM(snap, side)
            end, nil, timer.getTime() + (lcfg.samBuildDelay or 45))
        end
    end

    if weight then
        for _, jw in ipairs(JTAC_CRATE_WEIGHTS) do
            if math.abs(weight - jw) < 0.01 then
                if lcfg.jtacAutoRegister then
                    timer.scheduleFunction(function()
                        LOG._scanForDeployedJTAC(snap, side)
                    end, nil, timer.getTime() + (lcfg.jtacScanDelay or 30))
                end
                break
            end
        end
    end

    local fobDelay = (DCSCore.config.ctld and DCSCore.config.ctld.fobBuildTime or 120) + 10
    timer.scheduleFunction(function()
        LOG._checkFOBBuilt(snap, side)
    end, nil, timer.getTime() + fobDelay)
end

-- =============================================================
-- Deployed SAM → IADS registration + ammo init
-- =============================================================

function LOG._scanForDeployedSAM(pos, side)
    if not iads then return end
    local registered = {}
    for _, unit in ipairs(U.getUnitsInRadius(pos, 400, side)) do
        if unit:isExist() then
            local hasSam = false
            for _, attr in ipairs(SAM_ATTRIBUTES) do
                if unit:hasAttribute(attr) then hasSam = true; break end
            end
            if hasSam then
                local grp = unit:getGroup()
                if grp and grp:isExist() then
                    local gname = grp:getName()
                    if not registered[gname] then
                        registered[gname] = true
                        if DCSCore.iads and DCSCore.iads._initialized then
                            iads.add(gname)
                        end
                        LOG.initSAMAmmo(gname, side)
                        U.msgCoalition(side,
                            '[LOGISTICS] SAM online + IADS linked: ' .. gname, 15)
                        U.info('LOGISTICS: deployed SAM registered — ' .. gname)
                    end
                end
            end
        end
    end
end

-- =============================================================
-- Deployed JTAC → artillery spotter
-- =============================================================

function LOG._scanForDeployedJTAC(pos, side)
    for _, unit in ipairs(U.getUnitsInRadius(pos, 200, side)) do
        if unit:isExist() then
            local tn = string.lower(unit:getTypeName())
            if string.find(tn, 'jtac', 1, true) or
               string.find(tn, 'skp',  1, true) or
               unit:hasAttribute('JTAC') then
                local uname = unit:getName()
                if not LOG._jtacs[uname] then
                    LOG._jtacs[uname] = { side=side, pos=unit:getPosition().p,
                                          registeredAt=timer.getTime() }
                    if ArtilleryEnhancement then
                        ArtilleryEnhancement:addSpotter(uname)
                    end
                    if DCSCore.artillery then
                        DCSCore.artillery.addSpotter(uname)
                    end
                    U.msgCoalition(side, '[LOGISTICS] JTAC deployed: ' .. uname, 15)
                    U.info('LOGISTICS: JTAC registered — ' .. uname)
                end
            end
        end
    end
end

-- =============================================================
-- Pilot extraction
-- =============================================================

LOG._extractionHandler = {}

function LOG._extractionHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_DEAD then return end
    if not DCSCore.config.logistics.extractionEnabled then return end

    local unit = event.initiator
    if not unit then return end
    if unit:getCategory() ~= Object.Category.UNIT then return end

    local desc = unit:getDesc()
    if not desc then return end
    if desc.category ~= 1 and desc.category ~= 2 then return end  -- air only
    if unit:getPlayerName() == nil then return end

    local side = unit:getCoalition()
    local pos  = unit:getPosition().p

    if ctld and ctld.createExtractZone then
        local smokeCol = side == coalition.side.BLUE
                         and trigger.smokeColor.Blue or trigger.smokeColor.Red
        ctld.createExtractZone('EXTRACT_' .. math.random(10000, 99999), nil, smokeCol)
        U.msgCoalition(side,
            '[LOGISTICS] Pilot down at ' ..
            (mist and mist.tostringMGRS(pos, 5) or '?') ..
            ' — extraction zone marked.', 30)
    end
end

-- =============================================================
-- F10 Logistics Menu
-- =============================================================

function LOG._buildF10Menu()
    if not DCSCore.config.logistics.f10MenuEnabled then return end

    local function ammoStatus(side)
        local lines = { '[LOGISTICS] Ammo Status:' }
        for name, bat in pairs(LOG._batteries) do
            if bat.side == side then
                table.insert(lines, string.format('  [ARTY] %s  %d/%d  [%s]%s',
                    name, bat.rounds, bat.maxRounds, bat.status,
                    LOG._autoResupplyPending[name] and '  ←convoy' or ''))
            end
        end
        for name, sam in pairs(LOG._samAmmo) do
            if sam.side == side then
                table.insert(lines, string.format('  [SAM]  %s  %d/%d msls  [%s]%s',
                    name, sam.missiles, sam.maxMissiles, sam.status,
                    LOG._autoResupplyPending[name] and '  ←convoy' or ''))
            end
        end
        if DCSCore.credits then
            table.insert(lines, string.format('Credits: %d',
                DCSCore.credits.getCredits(side)))
        end
        U.msgCoalition(side, table.concat(lines, '\n'), 30)
    end

    local function fobStatus(side)
        local lines = { '[LOGISTICS] FOBs:' }
        local n = 0
        for _, fob in pairs(LOG._fobs) do
            if fob.side == side then
                n = n + 1
                table.insert(lines, string.format('  %s  %s  (built %dm ago)',
                    fob.name,
                    mist and mist.tostringMGRS(fob.pos, 5) or '?',
                    math.floor((timer.getTime() - fob.builtAt) / 60)))
            end
        end
        if n == 0 then table.insert(lines, '  None built yet.') end
        U.msgCoalition(side, table.concat(lines, '\n'), 25)
    end

    local function jtacStatus(side)
        local lines = { '[LOGISTICS] JTACs:' }
        local n = 0
        for name, data in pairs(LOG._jtacs) do
            if data.side == side then
                n = n + 1
                local alive = U.getUnit(name) and 'ACTIVE' or 'LOST'
                table.insert(lines, '  ' .. name .. '  [' .. alive .. ']')
            end
        end
        if n == 0 then table.insert(lines, '  None deployed.') end
        U.msgCoalition(side, table.concat(lines, '\n'), 20)
    end

    local function convoyStatus(side)
        local lines = { '[LOGISTICS] Convoys:' }
        local n = 0
        for name, conv in pairs(LOG._convoys) do
            if conv.side == side then
                n = n + 1
                local age = math.floor((timer.getTime() - conv.spawnTime) / 60)
                table.insert(lines, string.format('  %s → %s  (%dm, %s)',
                    name, conv.destination, age,
                    conv.auto and 'auto' or 'manual'))
            end
        end
        if n == 0 then table.insert(lines, '  None active.') end
        U.msgCoalition(side, table.concat(lines, '\n'), 20)
    end

    local function toggleAutoResupply(side)
        local lcfg = DCSCore.config.logistics
        lcfg.autoResupplyEnabled = not lcfg.autoResupplyEnabled
        U.msgCoalition(side,
            '[LOGISTICS] Auto-resupply ' ..
            (lcfg.autoResupplyEnabled and 'ENABLED' or 'DISABLED'), 10)
    end

    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local sideLabel = side == coalition.side.BLUE and 'BLUE' or 'RED'
        local hqZones   = side == coalition.side.BLUE
                          and DCSCore.config.logistics.blueHQZones
                          or  DCSCore.config.logistics.redHQZones

        local root = missionCommands.addSubMenuForCoalition(side, 'Logistics', nil)

        missionCommands.addCommandForCoalition(side, 'Ammo Status',    root, ammoStatus,    side)
        missionCommands.addCommandForCoalition(side, 'FOB Status',     root, fobStatus,     side)
        missionCommands.addCommandForCoalition(side, 'JTAC Status',    root, jtacStatus,    side)
        missionCommands.addCommandForCoalition(side, 'Convoy Status',  root, convoyStatus,  side)
        missionCommands.addCommandForCoalition(side, 'Toggle Auto-Resupply', root,
            toggleAutoResupply, side)

        -- Manual convoy dispatch sub-menu
        if hqZones and #hqZones > 0 then
            local convMenu = missionCommands.addSubMenuForCoalition(
                side, 'Dispatch Convoy', root)

            for _, hqZone in ipairs(hqZones) do
                missionCommands.addCommandForCoalition(side,
                    'From ' .. hqZone, convMenu, function()
                        local cost = DCSCore.config.logistics.manualConvoyCost or 30
                        if DCSCore.credits then
                            if not DCSCore.credits.spendCredits(side, cost) then
                                U.msgCoalition(side,
                                    '[LOGISTICS] Insufficient credits (' ..
                                    cost .. ' needed).', 10)
                                return
                            end
                        end

                        -- Find nearest FOB or fall back to first drop zone
                        local dest = nil
                        for _, fob in pairs(LOG._fobs) do
                            if fob.side == side then dest = fob.name; break end
                        end
                        if not dest then
                            local dz = side == coalition.side.BLUE
                                       and DCSCore.config.ctld.blueDropZones
                                       or  DCSCore.config.ctld.redDropZones
                            dest = dz and dz[1] and dz[1].name
                        end

                        if dest then
                            LOG.spawnConvoy(side, hqZone, dest)
                            if DCSCore.credits then
                                U.msgCoalition(side,
                                    string.format('[LOGISTICS] Convoy dispatched — cost: %d cr (balance: %d)',
                                        cost, DCSCore.credits.getCredits(side)), 12)
                            end
                        else
                            if DCSCore.credits then
                                DCSCore.credits.addCredits(side, cost, 'no-dest-refund')
                            end
                            U.msgCoalition(side,
                                '[LOGISTICS] No destination found. Build a FOB first.', 10)
                        end
                    end)
            end
        end
    end

    U.info('LOGISTICS: F10 menus built')
end

-- =============================================================
-- SAM group auto-detection at setup
-- Scans all live ground groups for known launcher types.
-- =============================================================

local function initAllSAMGroups()
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local groups = coalition.getGroups(side, Group.Category.GROUND)
        if groups then
            for _, group in ipairs(groups) do
                if group and group:isExist() then
                    for i = 1, group:getSize() do
                        local unit = group:getUnit(i)
                        if unit and unit:isExist() then
                            local cap = SAM_LAUNCHER_MISSILES[unit:getTypeName()]
                            if cap and cap > 0 then
                                LOG.initSAMAmmo(group:getName(), side)
                                break  -- one launcher found = whole group tracked
                            end
                        end
                    end
                end
            end
        end
    end
end

-- =============================================================
-- Public API  /  Setup
-- =============================================================

function LOG.setup()
    local lcfg = DCSCore.config.logistics
    if not lcfg or not lcfg.enabled then
        U.info('LOGISTICS: disabled in config')
        return
    end

    -- Register artillery batteries
    local acfg = DCSCore.config.artillery
    for _, name in ipairs(acfg.blueBatteries) do
        LOG.registerBattery(name, coalition.side.BLUE)
    end
    for _, name in ipairs(acfg.redBatteries) do
        LOG.registerBattery(name, coalition.side.RED)
    end

    -- Auto-detect and init SAM groups
    if lcfg.samAmmoEnabled then
        initAllSAMGroups()
        world.addEventHandler(LOG._samShotHandler)
        U.info('LOGISTICS: SAM ammo tracking active')
    end

    -- Supply truck proximity poll
    timer.scheduleFunction(checkSupplyTrucks, nil,
        timer.getTime() + (lcfg.supplyCheckInterval or 60))

    -- Smart auto-resupply poll
    if lcfg.autoResupplyEnabled then
        timer.scheduleFunction(autoResupplyPoll, nil,
            timer.getTime() + (lcfg.autoResupplyCheckInterval or 120))
    end

    -- Pilot extraction
    if lcfg.extractionEnabled then
        world.addEventHandler(LOG._extractionHandler)
    end

    LOG._buildF10Menu()

    local battCount = U.tableLength(LOG._batteries)
    local samCount  = U.tableLength(LOG._samAmmo)
    U.info(string.format('LOGISTICS: setup complete — %d batteries, %d SAM groups tracked',
        battCount, samCount))
end

U.info('ctld_logistics.lua loaded')
