-- =============================================================
-- server_core.lua
-- Main entry point.  Initialises all subsystems in the correct
-- order and wires up cross-system integrations.
--
-- LOAD ORDER (Mission Editor triggers — Time More):
--   1 s  → DO SCRIPT FILE  mist.lua
--   2 s  → DO SCRIPT FILE  MOOSE.lua                          (optional — zone capture)
--   3 s  → DO SCRIPT FILE  iads_v1_r37.lua                    (optional)
--   4 s  → DO SCRIPT FILE  ctld.lua                           (optional — ciribob CTLD)
--   5 s  → DO SCRIPT FILE  ArtilleryEnhancement.lua           (optional)
--   6 s  → DO SCRIPT FILE  Moose_DualCoalitionZoneCapture.lua (optional)
--   7 s  → DO SCRIPT FILE  Moose_DynamicGroundBattle_Plugin.lua (optional)
--   8 s  → DO SCRIPT FILE  scripts/utils.lua
--   9 s  → DO SCRIPT FILE  scripts/config.lua
--  10 s  → DO SCRIPT FILE  scripts/iads_manager.lua
--  11 s  → DO SCRIPT FILE  scripts/suppression.lua
--  12 s  → DO SCRIPT FILE  scripts/ctld_config.lua
--  13 s  → DO SCRIPT FILE  scripts/ctld_logistics.lua
--  14 s  → DO SCRIPT FILE  scripts/artillery_manager.lua
--  15 s  → DO SCRIPT FILE  scripts/credits.lua
--  16 s  → DO SCRIPT FILE  scripts/zone_capture.lua            (optional — zone capture)
--  17 s  → DO SCRIPT FILE  scripts/server_core.lua              ← THIS FILE
-- =============================================================

DCSCore = DCSCore or {}

-- =============================================================
-- Startup banner
-- =============================================================

local function printBanner()
    local lines = {
        '==============================================',
        '  DCS Server Core  v1.3',
        '  IADS | SmartSAM | Suppression | CTLD',
        '  Logistics | Counter-Battery | Credits',
        '  Zone Capture Integration',
        '==============================================',
    }
    for _, l in ipairs(lines) do
        env.info('[DCSCore] ' .. l)
    end
end

-- =============================================================
-- Dependency report
-- =============================================================

local DEPS = {
    { label = 'MIST',                 global = 'mist',                 required = true  },
    { label = 'IADScript',            global = 'iads',                 required = false },
    { label = 'ciribob CTLD',         global = 'ctld',                 required = false },
    { label = 'ArtilleryEnhancement', global = 'ArtilleryEnhancement', required = false },
    { label = 'MOOSE Zone Capture',   global = 'zoneCaptureObjects',   required = false },
}

-- Internal modules are checked separately (they use namespace, not _G key)
local INTERNAL_MODS = {
    { label = 'DCSCore.logistics',   mod = function() return DCSCore.logistics   end },
    { label = 'DCSCore.credits',     mod = function() return DCSCore.credits     end },
    { label = 'DCSCore.zoneCapture', mod = function() return DCSCore.zoneCapture end },
}

local function reportDependencies()
    local allOk = true
    for _, d in ipairs(DEPS) do
        local present = (_G[d.global] ~= nil)
        local status  = present and 'OK'
                     or (d.required and '*** MISSING ***' or 'not loaded (optional)')
        env.info('[DCSCore] dep  ' .. d.label .. ': ' .. status)
        if d.required and not present then allOk = false end
    end
    for _, d in ipairs(INTERNAL_MODS) do
        local present = (d.mod() ~= nil)
        env.info('[DCSCore] mod  ' .. d.label .. ': ' .. (present and 'OK' or 'not loaded (optional)'))
    end
    return allOk
end

-- =============================================================
-- Cross-system integration wiring
-- These functions are called after all modules are set up.
-- They apply only when both sides of a hook are present.
-- =============================================================

--- Suppression hits on a SAM group that is already SEAD-evading
--- extend its radar-off window rather than just ROE-holding it.
local function wireIADSSuppression()
    if not DCSCore.iads or not DCSCore.suppression then return end

    local origSuppress = DCSCore.suppression._suppress
    DCSCore.suppression._suppress = function(group)
        origSuppress(group)

        local name = group:getName()
        if DCSCore.iads.isEvading(name) then
            -- A hit while already dark gives 15 extra seconds of radar-off
            DCSCore.iads.extendDark(name, 15)
            DCSCore.utils.debug(
                'CORE: suppression hit extended SEAD dark window for ' .. name)
        end
    end

    DCSCore.utils.info('CORE: IADS <-> Suppression hook wired')
end

--- Counter-battery impacts also warn helicopters near CTLD drop zones.
--- (The actual warning lives in artillery_manager._warnCTLDZones, which
---  already reads DCSCore.config.ctld — this hook just confirms the link.)
local function wireArtilleryCTLD()
    if not DCSCore.artillery or not DCSCore.ctld then return end
    -- Nothing extra to patch; artillery_manager calls _warnCTLDZones
    -- internally for every confirmed CB impact.
    DCSCore.utils.info('CORE: Artillery <-> CTLD zone-warning link confirmed')
end

--- Artillery fireMission() deducts from the logistics ammo pool.
--- Batteries that are Winchester are blocked until a supply truck arrives.
local function wireLogisticsAmmo()
    if not DCSCore.logistics or not DCSCore.artillery then return end

    local origFire = DCSCore.artillery.fireMission
    DCSCore.artillery.fireMission = function(batteryName, targetPos, rounds, msgSide)
        if not DCSCore.logistics.hasAmmo(batteryName) then
            local bat  = DCSCore.artillery._batteries[batteryName]
            local side = bat and bat.side or msgSide
            if side then
                DCSCore.utils.msgCoalition(side,
                    '[LOGISTICS] ' .. batteryName ..
                    ' is WINCHESTER — awaiting resupply.', 15)
            end
            return false
        end

        local ok = origFire(batteryName, targetPos, rounds, msgSide)
        if ok then
            DCSCore.logistics.consumeAmmo(batteryName, rounds or 20)
        end
        return ok
    end

    DCSCore.utils.info('CORE: Artillery <-> Logistics ammo hook wired')
end

--- Zone capture events (capture, defence, attack) feed credits, suppression,
--- logistics FOB scanning, and artillery harassment automatically via the
--- zone_capture.lua module's poll loop.  This wire simply confirms the
--- artillery.fireMission path is already patched by wireLogisticsAmmo().
local function wireZoneCaptureIntegration()
    if not DCSCore.zoneCapture then return end
    -- zone_capture.lua calls DCSCore.credits / suppression / logistics / artillery
    -- APIs directly at event time.  wireLogisticsAmmo() (below) has already
    -- wrapped artillery.fireMission with the Winchester + ammo-deduction check,
    -- so harassment fire missions automatically go through the logistics gate.
    DCSCore.utils.info('CORE: ZoneCapture <-> Credits/Suppression/Logistics/IADS wired')
end

--- After a CTLD troop drop the helicopter's approach suppresses nearby enemies.
--- We wrap the fallback drop path here; the ciribob path is already hooked
--- inside ctld_config.lua via hookCiribobCallbacks().
local function wireCTLDSuppression()
    if not DCSCore.ctld or not DCSCore.suppression then return end

    -- Fallback drop wrapper
    local origDrop = DCSCore.ctld.fallbackDrop
    DCSCore.ctld.fallbackDrop = function(pilotUnitName, templateName, side)
        local ok = origDrop(pilotUnitName, templateName, side)
        if ok then
            local unit = DCSCore.utils.getUnit(pilotUnitName)
            if unit then
                DCSCore.ctld.onTroopDropHook(unit, side)
            end
        end
        return ok
    end

    DCSCore.utils.info('CORE: CTLD fallback <-> Suppression insertion hook wired')
end

-- =============================================================
-- Admin F10 Menu  (BLUE coalition by default)
-- =============================================================

local function buildAdminMenu()
    local cfg = DCSCore.config.admin
    if not cfg.f10MenuBlue then return end

    local root = missionCommands.addSubMenuForCoalition(
        coalition.side.BLUE, '[ADMIN] Server Core', nil)

    -- ── IADS ─────────────────────────────────────────────────
    if DCSCore.iads and DCSCore.iads._initialized then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'IADS', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Status', m, function()
                local n = DCSCore.utils.tableLength(DCSCore.iads._evading)
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    string.format('[IADS] level=%d  SAMs evading=%d',
                        DCSCore.config.iads.level, n), 12)
            end)

        for _, lvl in ipairs({ 1, 2, 3, 4 }) do
            missionCommands.addCommandForCoalition(coalition.side.BLUE,
                'Set level ' .. lvl, m, function()
                    if iads then
                        iads.settings.level = lvl
                        DCSCore.utils.msgCoalition(coalition.side.BLUE,
                            '[IADS] Level set to ' .. lvl, 8)
                    end
                end)
        end
    end

    -- ── Suppression ──────────────────────────────────────────
    if DCSCore.suppression then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Suppression', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Status', m, function()
                local n = DCSCore.utils.tableLength(DCSCore.suppression._state)
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[SUP] Groups suppressed: ' .. n, 10)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Toggle on/off', m, function()
                local c = DCSCore.config.suppression
                c.enabled = not c.enabled
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[SUP] Suppression ' .. (c.enabled and 'ENABLED' or 'DISABLED'), 8)
            end)
    end

    -- ── Artillery ────────────────────────────────────────────
    if DCSCore.artillery then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Artillery', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Battery Status', m, function()
                local lines = { '[ARTY] Batteries:' }
                for name, state in pairs(DCSCore.artillery._batteries) do
                    local sideStr = state.side == coalition.side.BLUE and 'BLU' or 'RED'
                    local dispStr = state.displacing and 'DISP' or 'STATIC'
                    local age     = math.floor(timer.getTime() - (state.lastFired or 0))
                    table.insert(lines, string.format(
                        '  %s [%s|%s] last fired %ds ago', name, sideStr, dispStr, age))
                end
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    table.concat(lines, '\n'), 25)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Pending CB Shells', m, function()
                local n = DCSCore.utils.tableLength(DCSCore.artillery._shells)
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[ARTY] Tracked incoming shells: ' .. n, 10)
            end)
    end

    -- ── CTLD ─────────────────────────────────────────────────
    if DCSCore.ctld and DCSCore.ctld._active then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'CTLD', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Lift Manifest', m, function()
                local n = DCSCore.utils.tableLength(DCSCore.ctld._manifest)
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[CTLD] Helicopters with cargo: ' .. n, 10)
            end)
    end

    -- ── Logistics ─────────────────────────────────────────────
    if DCSCore.logistics then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Logistics', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Ammo Summary', m, function()
                local lines  = { '[LOGISTICS] Ammo:' }
                local total  = 0
                local low    = 0
                local winch  = 0
                for name, bat in pairs(DCSCore.logistics._batteries) do
                    if bat.side == coalition.side.BLUE then
                        total = total + 1
                        if bat.rounds == 0 then winch = winch + 1
                        elseif bat.rounds < bat.maxRounds * 0.25 then low = low + 1 end
                        table.insert(lines, string.format(
                            '  %s  %d/%d', name, bat.rounds, bat.maxRounds))
                    end
                end
                table.insert(lines, string.format(
                    'Batteries: %d  Low: %d  Winchester: %d', total, low, winch))
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    table.concat(lines, '\n'), 25)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'SAM Ammo Summary', m, function()
                local lines = { '[LOGISTICS] SAM Ammo:' }
                local count = 0
                for name, s in pairs(DCSCore.logistics._samAmmo) do
                    if s.side == coalition.side.BLUE then
                        count = count + 1
                        table.insert(lines, string.format(
                            '  %s  %d/%d  [%s]',
                            name, s.missiles, s.maxMissiles, s.status))
                    end
                end
                if count == 0 then
                    table.insert(lines, '  (none tracked)')
                end
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    table.concat(lines, '\n'), 25)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'FOB / Convoy Status', m, function()
                local fobs    = DCSCore.utils.tableLength(DCSCore.logistics._fobs)
                local convoys = DCSCore.utils.tableLength(DCSCore.logistics._convoys)
                local jtacs   = DCSCore.utils.tableLength(DCSCore.logistics._jtacs)
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    string.format('[LOGISTICS] FOBs: %d  Convoys: %d  JTACs: %d',
                        fobs, convoys, jtacs), 12)
            end)
    end

    -- ── Zone Capture ──────────────────────────────────────────
    if DCSCore.zoneCapture and DCSCore.zoneCapture._initialized then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Zone Capture', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Zone Status', m, function()
                local counts = DCSCore.zoneCapture.getZoneCounts()
                local lines  = {
                    string.format('[ZONE] BLU:%d  RED:%d  Neutral:%d  Contested:%d',
                        counts.blue, counts.red, counts.neutral, counts.contested)
                }
                for name, data in pairs(DCSCore.zoneCapture._zones) do
                    local owner
                    if data.coalition == coalition.side.BLUE then owner = 'BLU'
                    elseif data.coalition == coalition.side.RED then owner = 'RED'
                    else owner = 'NEU' end
                    table.insert(lines, string.format('  %-24s [%s] %s',
                        name, owner, data.state or '?'))
                end
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    table.concat(lines, '\n'), 30)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Toggle Broadcasts', m, function()
                local c = DCSCore.config.zoneCapture
                c.broadcastCaptures = not c.broadcastCaptures
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[ZONE] Capture broadcasts ' ..
                    (c.broadcastCaptures and 'ENABLED' or 'DISABLED'), 8)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Toggle Suppress-on-Attack', m, function()
                local c = DCSCore.config.zoneCapture
                c.suppressOnAttack = not c.suppressOnAttack
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[ZONE] Suppress-on-attack ' ..
                    (c.suppressOnAttack and 'ENABLED' or 'DISABLED'), 8)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Toggle Arty Harassment', m, function()
                local c = DCSCore.config.zoneCapture
                c.artilleryOnCapture = not c.artilleryOnCapture
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[ZONE] Artillery harassment ' ..
                    (c.artilleryOnCapture and 'ENABLED' or 'DISABLED'), 8)
            end)
    end

    -- ── Credits ───────────────────────────────────────────────
    if DCSCore.credits then
        local m = missionCommands.addSubMenuForCoalition(
            coalition.side.BLUE, 'Credits', root)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Balance (both sides)', m, function()
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[CREDITS] ' .. DCSCore.credits.balanceStr(), 12)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Add 100 to BLUE (admin)', m, function()
                DCSCore.credits.addCredits(coalition.side.BLUE, 100, 'admin-grant')
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[CREDITS] +100 granted to BLUE. ' ..
                    DCSCore.credits.balanceStr(), 10)
            end)

        missionCommands.addCommandForCoalition(coalition.side.BLUE,
            'Add 100 to RED (admin)', m, function()
                DCSCore.credits.addCredits(coalition.side.RED, 100, 'admin-grant')
                DCSCore.utils.msgCoalition(coalition.side.BLUE,
                    '[CREDITS] +100 granted to RED. ' ..
                    DCSCore.credits.balanceStr(), 10)
            end)
    end

    DCSCore.utils.info('CORE: admin F10 menu built')
end

-- =============================================================
-- Periodic status log
-- =============================================================

local function startStatusBroadcast()
    local interval = DCSCore.config.admin.statusInterval
    if not interval or interval <= 0 then return end

    local function broadcast()
        local parts = { '[DCSCore] status —' }

        if DCSCore.iads then
            local evading = DCSCore.utils.tableLength(DCSCore.iads._evading)
            table.insert(parts,
                'IADS lvl=' .. DCSCore.config.iads.level ..
                ' evading=' .. evading)
        end

        if DCSCore.suppression then
            table.insert(parts,
                'SUP=' .. DCSCore.utils.tableLength(DCSCore.suppression._state))
        end

        if DCSCore.artillery then
            local disp = 0
            for _, s in pairs(DCSCore.artillery._batteries) do
                if s.displacing then disp = disp + 1 end
            end
            table.insert(parts, 'ARTY disp=' .. disp)
        end

        if DCSCore.logistics then
            local winch = 0
            for _, b in pairs(DCSCore.logistics._batteries) do
                if b.rounds == 0 then winch = winch + 1 end
            end
            local samWinch = 0
            for _, s in pairs(DCSCore.logistics._samAmmo) do
                if s.status == 'WINCHESTER' then samWinch = samWinch + 1 end
            end
            local fobs    = DCSCore.utils.tableLength(DCSCore.logistics._fobs)
            local convoys = DCSCore.utils.tableLength(DCSCore.logistics._convoys)
            table.insert(parts,
                'LOG fobs=' .. fobs .. ' convoys=' .. convoys ..
                ' winch=' .. winch .. ' samWinch=' .. samWinch)
        end

        if DCSCore.zoneCapture and DCSCore.zoneCapture._initialized then
            local counts = DCSCore.zoneCapture.getZoneCounts()
            table.insert(parts,
                string.format('ZONES blu=%d red=%d neut=%d cont=%d',
                    counts.blue, counts.red, counts.neutral, counts.contested))
        end

        if DCSCore.credits then
            table.insert(parts, DCSCore.credits.balanceStr())
        end

        env.info(table.concat(parts, '  '))
        timer.scheduleFunction(broadcast, nil, timer.getTime() + interval)
    end

    timer.scheduleFunction(broadcast, nil, timer.getTime() + interval)
    DCSCore.utils.info('CORE: status broadcast every ' .. interval .. 's')
end

-- =============================================================
-- Main initialisation
-- =============================================================

local function init()
    printBanner()

    -- Guard against missing prerequisites
    if not DCSCore.utils then
        env.error('[DCSCore] FATAL: utils.lua not loaded — aborting')
        return
    end
    if not DCSCore.config then
        DCSCore.utils.error('CORE: config.lua not loaded — aborting')
        return
    end

    DCSCore.utils.info('CORE: beginning subsystem init')

    local depsOk = reportDependencies()
    if not depsOk then
        DCSCore.utils.error('CORE: required dependency missing — some features disabled')
    end

    -- ── Subsystem setup (order matters) ──────────────────────
    if DCSCore.suppression then
        DCSCore.suppression.setup()
    end

    if DCSCore.iads then
        DCSCore.iads.setup()
    end

    if DCSCore.ctld then
        DCSCore.ctld.setup()
    end

    if DCSCore.artillery then
        DCSCore.artillery.setup()
    end

    -- Logistics must come after artillery (reads battery list) and
    -- after CTLD (listens to its callbacks).
    if DCSCore.logistics then
        DCSCore.logistics.setup()
    end

    -- Credits must come after logistics (spend/refund hooks use logistics).
    if DCSCore.credits then
        DCSCore.credits.setup()
    end

    -- Zone capture must come after credits, suppression, logistics, and artillery
    -- are all set up so that the poll-loop hooks have live systems to call into.
    if DCSCore.zoneCapture then
        DCSCore.zoneCapture.setup()
    end

    -- ── Cross-system hooks ────────────────────────────────────
    wireIADSSuppression()
    wireArtilleryCTLD()
    wireCTLDSuppression()
    wireLogisticsAmmo()
    wireZoneCaptureIntegration()

    -- ── Admin UI & status ─────────────────────────────────────
    buildAdminMenu()
    startStatusBroadcast()

    DCSCore.utils.info('CORE: all systems active')
    trigger.action.outText('[DCSCore] Server scripts loaded and active.', 15)
end

-- Schedule one tick after load so all globals are settled
timer.scheduleFunction(init, nil, timer.getTime() + 1)

DCSCore.utils.info('server_core.lua loaded — init scheduled')
