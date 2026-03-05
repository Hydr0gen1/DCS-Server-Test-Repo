-- =============================================================
-- ctld_logistics.lua
-- Realistic logistics layer built on top of CTLD.
--
-- Features
-- ────────
-- SUPPLY CHAIN
--   • Artillery batteries have a finite ammo pool (rounds).
--     Fires deducted via a hook in artillery_manager.fireMission().
--     "Winchester" batteries refuse fire missions until resupplied.
--   • Supply trucks (M-818, KAMAZ, Ural) within supplyRadiusBattery
--     of a battery automatically top it up when the logistics
--     poll runs (every supplyCheckInterval seconds).
--   • Supply convoys can be ordered from HQ via the F10 menu.
--     A MIST-cloned convoy group drives from an HQ zone to a
--     designated FOB, then resupplies all batteries in range.
--
-- FOB TRACKING
--   • Listens for the ctld "crateDropped" callback.  After
--     fobBuildTime seconds it scans the drop area for a newly
--     assembled FOB static or group and records its position.
--   • Recorded FOBs act as forward resupply waypoints for convoys
--     and show up in the logistics F10 status report.
--
-- JTAC AUTO-REGISTRATION
--   • When a JTAC crate is dropped and assembled, the new JTAC
--     unit is registered as an artillery spotter so counter-battery
--     missions can be directed through it.
--
-- SAM AUTO-REGISTRATION WITH IADS
--   • When any SAM-system crate is assembled, nearby units with
--     SAM attributes are found and their group is added to the
--     IADS network automatically.
--
-- EXTRACTION ZONES
--   • ctld.createExtractZone() is called around downed-pilot
--     markers (from DEAD events) to let helicopters extract them.
--
-- Dependencies: MIST, ctld.lua (optional but strongly recommended)
-- =============================================================

DCSCore            = DCSCore or {}
DCSCore.logistics  = {}

local LOG = DCSCore.logistics
local U   = DCSCore.utils

-- =============================================================
-- State tables
-- =============================================================

-- groupName -> { side, rounds, maxRounds, lastResupply }
LOG._batteries  = {}

-- id -> { pos, side, builtAt, name }
LOG._fobs       = {}

-- groupName -> { side, spawnTime, destination }
LOG._convoys    = {}

-- unitName -> { side, pos, registeredAt }
LOG._jtacs      = {}

-- Weight IDs from ciribob CTLD that represent SAM-system crates
-- (any crate whose weight falls in 1003.xx – 1005.xx range is an AA/SAM system)
local SAM_CRATE_WEIGHT_MIN = 1003.0
local SAM_CRATE_WEIGHT_MAX = 1005.99

-- JTAC crate weight IDs
local JTAC_CRATE_WEIGHTS = { 1001.01, 1001.11, 1006.01, 1006.11 }

-- Supply unit DCS type-name substrings (trucks/APCs used as supply vehicles)
local SUPPLY_UNIT_TYPES = {
    'm-818', 'ural', 'kamaz', 'ammo', 'supply',
    'logistics', 'hummer', 'hmmwv',
}

-- SAM-related DCS unit attributes to scan for after crate assembly
local SAM_ATTRIBUTES = { 'SAM SR', 'SAM TR', 'SAM LL', 'SAM CC', 'AAA' }

-- =============================================================
-- Battery ammo management
-- =============================================================

--- Register a battery with the logistics pool.
--- Called by server_core after artillery_manager.setup().
function LOG.registerBattery(groupName, side)
    local lcfg = DCSCore.config.logistics
    LOG._batteries[groupName] = {
        side         = side,
        rounds       = lcfg.batteryStartingRounds,
        maxRounds    = lcfg.batteryStartingRounds,
        lastResupply = timer.getTime(),
    }
    U.debug('LOGISTICS: battery registered — ' .. groupName)
end

--- Deduct rounds from a battery.  Returns false if Winchester.
function LOG.consumeAmmo(groupName, rounds)
    local bat = LOG._batteries[groupName]
    if not bat then return true end   -- untracked battery: always OK

    if bat.rounds <= 0 then
        return false   -- Winchester
    end

    bat.rounds = math.max(0, bat.rounds - rounds)
    U.debug(string.format('LOGISTICS: %s fired %d rnds — %d remaining',
        groupName, rounds, bat.rounds))
    return true
end

--- Returns true if the battery has rounds remaining.
function LOG.hasAmmo(groupName)
    local bat = LOG._batteries[groupName]
    if not bat then return true end   -- untracked: assume OK
    return bat.rounds > 0
end

--- Resupply a battery to full.
function LOG.resupply(groupName, amount)
    local bat = LOG._batteries[groupName]
    if not bat then return end
    amount        = amount or DCSCore.config.logistics.ammoResupplyAmount
    bat.rounds    = math.min(bat.rounds + amount, bat.maxRounds)
    bat.lastResupply = timer.getTime()
    U.info(string.format('LOGISTICS: %s resupplied +%d rnds (%d/%d)',
        groupName, amount, bat.rounds, bat.maxRounds))
    U.msgCoalition(bat.side,
        '[LOGISTICS] ' .. groupName .. ' resupplied — ' ..
        bat.rounds .. ' rounds ready.', 12)
end

-- =============================================================
-- Supply truck proximity polling
-- =============================================================

local function isSupplyVehicle(unit)
    if not unit or not unit:isExist() then return false end
    local typeName = string.lower(unit:getTypeName())
    for _, pattern in ipairs(SUPPLY_UNIT_TYPES) do
        if string.find(typeName, pattern, 1, true) then return true end
    end
    return false
end

local function checkSupplyTrucks()
    local lcfg  = DCSCore.config.logistics
    local radius = lcfg.supplyRadiusBattery

    for battName, bat in pairs(LOG._batteries) do
        local group = U.getGroup(battName)
        if group and group:isExist() then
            local unit1 = group:getUnit(1)
            if unit1 and unit1:isExist() then
                local battPos = unit1:getPosition().p

                -- Find friendly supply vehicles in range
                local candidates = U.getUnitsInRadius(battPos, radius, bat.side)
                for _, candidate in ipairs(candidates) do
                    if isSupplyVehicle(candidate) then
                        local timeSince = timer.getTime() - (bat.lastResupply or 0)
                        -- Only resupply once per interval to prevent spam
                        if bat.rounds < bat.maxRounds and timeSince > 120 then
                            LOG.resupply(battName)
                            break
                        end
                    end
                end
            end
        end
    end

    -- Reschedule
    timer.scheduleFunction(checkSupplyTrucks, nil,
        timer.getTime() + (DCSCore.config.logistics.supplyCheckInterval or 60))
end

-- =============================================================
-- Supply Convoy system
-- =============================================================

--- Spawn a supply convoy from an HQ zone toward a destination zone.
--- Uses MIST cloneInZone + groupToPoint to drive the convoy.
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
        U.msgCoalition(side,
            '[LOGISTICS] No convoy template configured.', 10)
        return false
    end

    -- Check HQ zone exists
    local fromVec = U.getZoneVec3(fromZoneName)
    local toVec   = U.getZoneVec3(toZoneName)
    if not fromVec or not toVec then
        U.msgCoalition(side, '[LOGISTICS] Zone not found.', 10)
        return false
    end

    -- Clone the template at the HQ zone
    local newGroup = mist.cloneInZone(template, fromZoneName)
    if not newGroup then
        U.error('LOGISTICS: failed to clone convoy template — ' .. template)
        return false
    end

    local convoyName = newGroup:getName()
    LOG._convoys[convoyName] = {
        side        = side,
        spawnTime   = timer.getTime(),
        destination = toZoneName,
        destPos     = toVec,
    }

    -- Order the convoy to drive to the destination
    mist.groupToPoint(newGroup, toVec)

    U.msgCoalition(side,
        '[LOGISTICS] Supply convoy dispatched from ' .. fromZoneName ..
        ' to ' .. toZoneName, 15)
    U.info('LOGISTICS: convoy ' .. convoyName .. ' dispatched -> ' .. toZoneName)

    -- Monitor arrival
    LOG._watchConvoyArrival(convoyName, toVec, side)
    return true
end

function LOG._watchConvoyArrival(convoyName, destPos, side)
    timer.scheduleFunction(function()
        local state = LOG._convoys[convoyName]
        if not state then return end   -- convoy was cleared

        local group = U.getGroup(convoyName)
        if not group or not group:isExist() then
            -- Convoy destroyed
            LOG._convoys[convoyName] = nil
            U.msgCoalition(side,
                '[LOGISTICS] Supply convoy lost in transit!', 20)
            return
        end

        local unit1 = group:getUnit(1)
        if unit1 and unit1:isExist() then
            local pos  = unit1:getPosition().p
            local dist = U.dist2D(pos, destPos)

            if dist <= (DCSCore.config.logistics.supplyRadiusFOB or 500) then
                -- Arrived — resupply all batteries within FOB radius
                LOG._convoys[convoyName] = nil
                LOG._convoyResupplyArea(destPos, side)
                U.msgCoalition(side,
                    '[LOGISTICS] Supply convoy arrived at ' ..
                    state.destination .. ' — batteries resupplied.', 20)
                return
            end
        end

        -- Not arrived yet — check again in 30s
        LOG._watchConvoyArrival(convoyName, destPos, side)
    end, nil, timer.getTime() + 30)
end

function LOG._convoyResupplyArea(pos, side)
    local radius = DCSCore.config.logistics.supplyRadiusFOB or 500
    for battName, bat in pairs(LOG._batteries) do
        if bat.side == side then
            local group = U.getGroup(battName)
            if group and group:isExist() then
                local unit1 = group:getUnit(1)
                if unit1 and unit1:isExist() then
                    if U.dist2D(unit1:getPosition().p, pos) <= radius then
                        LOG.resupply(battName)
                    end
                end
            end
        end
    end
end

-- =============================================================
-- FOB tracking
-- =============================================================

local function recordFOB(pos, side, label)
    local id = 'FOB_' .. math.random(10000, 99999)
    LOG._fobs[id] = {
        pos       = pos,
        side      = side,
        builtAt   = timer.getTime(),
        name      = label or id,
    }
    U.msgCoalition(side,
        '[LOGISTICS] FOB established at ' ..
        (mist and mist.tostringMGRS(pos, 5) or '?'), 20)
    U.info('LOGISTICS: FOB recorded — ' .. (label or id))

    -- Place a radio beacon at the FOB
    if ctld and ctld.createRadioBeaconAtZone then
        -- ciribob beacon API requires a zone name; we create a named zone
        -- dynamically — but DCS doesn't support dynamic zone creation.
        -- Instead, fire a smoke marker at the FOB position as fallback.
        trigger.action.smoke(pos, trigger.smokeColor.Green)
    end
end

-- =============================================================
-- CTLD crate-drop handler
-- Called by ctld_config.lua's ciribob callback on "crateDropped".
-- =============================================================

function LOG.onCrateDropped(args)
    local unit   = args and args.unit
    local side   = args and args.side
    local weight = args and args.crateWeight

    if not side then return end

    local dropPos = unit and unit:isExist()
                    and unit:getPosition().p
                    or nil
    if not dropPos then return end

    local lcfg = DCSCore.config.logistics

    -- ── SAM crate → schedule IADS auto-registration ──────────
    if weight and weight >= SAM_CRATE_WEIGHT_MIN
               and weight <= SAM_CRATE_WEIGHT_MAX then
        if lcfg.samAutoRegister then
            local buildDelay = lcfg.samBuildDelay or 45
            local scanPos    = { x=dropPos.x, y=dropPos.y, z=dropPos.z }
            timer.scheduleFunction(function()
                LOG._scanForDeployedSAM(scanPos, side)
            end, nil, timer.getTime() + buildDelay)
            U.debug('LOGISTICS: SAM crate dropped — scan scheduled in ' ..
                    buildDelay .. 's')
        end
    end

    -- ── JTAC crate → schedule spotter registration ───────────
    if weight then
        for _, jw in ipairs(JTAC_CRATE_WEIGHTS) do
            if math.abs(weight - jw) < 0.01 then
                if lcfg.jtacAutoRegister then
                    local scanDelay = lcfg.jtacScanDelay or 30
                    local scanPos   = { x=dropPos.x, y=dropPos.y, z=dropPos.z }
                    timer.scheduleFunction(function()
                        LOG._scanForDeployedJTAC(scanPos, side)
                    end, nil, timer.getTime() + scanDelay)
                    U.debug('LOGISTICS: JTAC crate dropped — scan scheduled in ' ..
                            scanDelay .. 's')
                end
                break
            end
        end
    end

    -- ── FOB crate → watch for assembly completion ─────────────
    -- ciribob fires crateDropped for individual crates.
    -- We schedule a check after buildTimeFOB seconds to see if a
    -- new static object has appeared (FOB tent / bunker).
    local fobDelay = (DCSCore.config.ctld.fobBuildTime or 120) + 10
    local snapPos  = { x=dropPos.x, y=dropPos.y, z=dropPos.z }
    timer.scheduleFunction(function()
        LOG._checkFOBBuilt(snapPos, side)
    end, nil, timer.getTime() + fobDelay)
end

function LOG._checkFOBBuilt(pos, side)
    -- Search for static objects with FOB/tent attributes near the drop point.
    -- ciribob's FOB spawns a static named "FOB_*" or "CTLD_FOB_*".
    local volume = {
        id     = world.VolumeType.SPHERE,
        params = { point = pos, radius = 200 },
    }
    local found = false
    world.searchObjects(Object.Category.STATIC, volume, function(obj)
        if found then return false end
        if obj and obj:isExist() then
            local name = string.lower(obj:getName())
            if string.find(name, 'fob', 1, true) or
               string.find(name, 'ctld', 1, true) then
                recordFOB(obj:getPosition().p, side, obj:getName())
                found = true
                return false
            end
        end
        return true
    end)
end

-- =============================================================
-- Deployed SAM scanning → IADS auto-registration
-- =============================================================

function LOG._scanForDeployedSAM(pos, side)
    if not DCSCore.iads or not DCSCore.iads._initialized then return end
    if not iads then return end

    local units = U.getUnitsInRadius(pos, 400, side)
    local registered = {}

    for _, unit in ipairs(units) do
        if unit:isExist() then
            local hasSamAttr = false
            for _, attr in ipairs(SAM_ATTRIBUTES) do
                if unit:hasAttribute(attr) then
                    hasSamAttr = true
                    break
                end
            end

            if hasSamAttr then
                local grp = unit:getGroup()
                if grp and grp:isExist() then
                    local gname = grp:getName()
                    if not registered[gname] then
                        registered[gname] = true
                        iads.add(gname)
                        U.info('LOGISTICS: deployed SAM added to IADS — ' .. gname)
                        U.msgCoalition(side,
                            '[LOGISTICS] SAM system online and linked to IADS: ' ..
                            gname, 15)
                    end
                end
            end
        end
    end
end

-- =============================================================
-- Deployed JTAC scanning → Artillery spotter registration
-- =============================================================

function LOG._scanForDeployedJTAC(pos, side)
    local units = U.getUnitsInRadius(pos, 200, side)

    for _, unit in ipairs(units) do
        if unit:isExist() then
            local typeName = string.lower(unit:getTypeName())
            -- Ciribob JTAC unit type names contain 'jtac', 'skp', 'hummer'
            if string.find(typeName, 'jtac', 1, true) or
               string.find(typeName, 'skp', 1, true) or
               unit:hasAttribute('JTAC') then

                local uname = unit:getName()
                if not LOG._jtacs[uname] then
                    LOG._jtacs[uname] = {
                        side         = side,
                        pos          = unit:getPosition().p,
                        registeredAt = timer.getTime(),
                    }

                    -- Register with ArtilleryEnhancement if available
                    if ArtilleryEnhancement then
                        ArtilleryEnhancement:addSpotter(uname)
                        U.info('LOGISTICS: JTAC registered with ArtEnhancement — ' .. uname)
                    end

                    -- Also register with our artillery_manager spotter list
                    if DCSCore.artillery then
                        DCSCore.artillery.addSpotter(uname)
                    end

                    U.msgCoalition(side,
                        '[LOGISTICS] JTAC deployed and registered: ' .. uname, 15)
                end
            end
        end
    end
end

-- =============================================================
-- Extraction zone creation for downed pilots
-- Triggered by S_EVENT_DEAD on player-controlled aircraft.
-- =============================================================

LOG._extractionHandler = {}

function LOG._extractionHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_DEAD then return end

    local lcfg = DCSCore.config.logistics
    if not lcfg.extractionEnabled then return end

    local unit = event.initiator
    if not unit then return end

    -- Only care about player-controlled aircraft (not AI, not ground)
    if unit:getCategory() ~= Object.Category.UNIT then return end
    local desc = unit:getDesc()
    if not desc then return end
    -- Category 1 = Airplane, 2 = Helicopter
    if desc.category ~= 1 and desc.category ~= 2 then return end
    if unit:getPlayerName() == nil then return end   -- AI, skip

    local side = unit:getCoalition()
    local pos  = unit:getPosition().p

    -- Create a CTLD extraction zone at the crash site
    if ctld and ctld.createExtractZone then
        local zoneName = 'EXTRACT_' .. math.random(10000, 99999)
        local smokeCol = side == coalition.side.BLUE
                         and trigger.smokeColor.Blue
                         or  trigger.smokeColor.Red
        ctld.createExtractZone(zoneName, nil, smokeCol)

        local mgrs = mist and mist.tostringMGRS(pos, 5) or '?'
        U.msgCoalition(side,
            '[LOGISTICS] Pilot down — extraction zone created at ' .. mgrs ..
            '\nUse CTLD extract menu to recover.',
            30)
        U.info('LOGISTICS: extraction zone created at ' ..
               (unit:getPlayerName() or '?') .. ' crash site')
    end
end

-- =============================================================
-- F10 Logistics Menu
-- =============================================================

function LOG._buildF10Menu()
    local lcfg = DCSCore.config.logistics
    if not lcfg.f10MenuEnabled then return end

    -- BLUE logistics menu
    local blueRoot = missionCommands.addSubMenuForCoalition(
        coalition.side.BLUE, 'Logistics', nil)

    -- Battery ammo status
    missionCommands.addCommandForCoalition(coalition.side.BLUE,
        'Ammo Status', blueRoot, function()
            local lines = { '[LOGISTICS] Battery Ammo:' }
            for name, bat in pairs(LOG._batteries) do
                if bat.side == coalition.side.BLUE then
                    local pct = math.floor(bat.rounds / bat.maxRounds * 100)
                    local status = bat.rounds == 0 and 'WINCHESTER'
                               or  bat.rounds < bat.maxRounds * 0.25 and 'LOW'
                               or  'OK'
                    table.insert(lines, string.format(
                        '  %s  %d/%d (%d%%)  [%s]',
                        name, bat.rounds, bat.maxRounds, pct, status))
                end
            end
            U.msgCoalition(coalition.side.BLUE, table.concat(lines, '\n'), 25)
        end)

    -- FOB status
    missionCommands.addCommandForCoalition(coalition.side.BLUE,
        'FOB Status', blueRoot, function()
            local lines = { '[LOGISTICS] Active FOBs:' }
            local count = 0
            for _, fob in pairs(LOG._fobs) do
                if fob.side == coalition.side.BLUE then
                    count = count + 1
                    local mgrs = mist and mist.tostringMGRS(fob.pos, 5) or '?'
                    local age  = math.floor((timer.getTime() - fob.builtAt) / 60)
                    table.insert(lines, string.format(
                        '  %s  %s  (built %dm ago)', fob.name, mgrs, age))
                end
            end
            if count == 0 then
                table.insert(lines, '  None built yet.')
            end
            U.msgCoalition(coalition.side.BLUE, table.concat(lines, '\n'), 25)
        end)

    -- Active JTACs
    missionCommands.addCommandForCoalition(coalition.side.BLUE,
        'JTAC Status', blueRoot, function()
            local lines = { '[LOGISTICS] Deployed JTACs:' }
            local count = 0
            for name, data in pairs(LOG._jtacs) do
                if data.side == coalition.side.BLUE then
                    count = count + 1
                    local unit = U.getUnit(name)
                    local alive = unit and 'ACTIVE' or 'LOST'
                    table.insert(lines, '  ' .. name .. '  [' .. alive .. ']')
                end
            end
            if count == 0 then
                table.insert(lines, '  None deployed.')
            end
            U.msgCoalition(coalition.side.BLUE, table.concat(lines, '\n'), 20)
        end)

    -- Convoy dispatch (dynamic sub-menu per HQ zone)
    local lcfgCtld = DCSCore.config.ctld
    if #(lcfg.blueHQZones or {}) > 0 then
        local convMenu = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Dispatch Convoy', blueRoot)

        for _, hqZone in ipairs(lcfg.blueHQZones) do
            -- For each FOB, add a dispatch option
            -- We generate one entry per HQ → first FOB for simplicity;
            -- missions with multiple FOBs should extend this loop.
            missionCommands.addCommandForCoalition(coalition.side.BLUE,
                'From ' .. hqZone, convMenu, function()
                    -- Pick the first known blue FOB as destination
                    local destZone = nil
                    for _, fob in pairs(LOG._fobs) do
                        if fob.side == coalition.side.BLUE then
                            destZone = fob.name; break
                        end
                    end
                    if not destZone then
                        -- Fall back to first configured drop zone
                        local dz = DCSCore.config.ctld.blueDropZones
                        destZone = dz and dz[1] and dz[1].name
                    end
                    if destZone then
                        LOG.spawnConvoy(coalition.side.BLUE, hqZone, destZone)
                    else
                        U.msgCoalition(coalition.side.BLUE,
                            '[LOGISTICS] No destination zone found. Build a FOB first.', 10)
                    end
                end)
        end
    end

    -- Convoy status
    missionCommands.addCommandForCoalition(coalition.side.BLUE,
        'Convoy Status', blueRoot, function()
            local n = U.tableLength(LOG._convoys)
            U.msgCoalition(coalition.side.BLUE,
                '[LOGISTICS] Active convoys: ' .. n, 10)
        end)

    U.info('LOGISTICS: F10 menu built')
end

-- =============================================================
-- Public API
-- =============================================================

function LOG.setup()
    local lcfg = DCSCore.config.logistics
    if not lcfg or not lcfg.enabled then
        U.info('LOGISTICS: disabled in config')
        return
    end

    -- Register pre-placed batteries from artillery config
    local acfg = DCSCore.config.artillery
    for _, name in ipairs(acfg.blueBatteries) do
        LOG.registerBattery(name, coalition.side.BLUE)
    end
    for _, name in ipairs(acfg.redBatteries) do
        LOG.registerBattery(name, coalition.side.RED)
    end

    -- Start supply-truck polling
    timer.scheduleFunction(checkSupplyTrucks, nil,
        timer.getTime() + (lcfg.supplyCheckInterval or 60))

    -- Downed-pilot extraction handler
    if lcfg.extractionEnabled then
        world.addEventHandler(LOG._extractionHandler)
    end

    -- F10 menu
    LOG._buildF10Menu()

    local battCount = U.tableLength(LOG._batteries)
    U.info('LOGISTICS: setup complete — ' .. battCount .. ' batteries tracked')
end

U.info('ctld_logistics.lua loaded')
