-- =============================================================
-- iads_manager.lua
-- Wraps IADScript setup and adds Smarter SAM SEAD-evasion logic.
--
-- External dependency: iads_v1_r37.lua loaded BEFORE this file.
-- Optional:           mist.lua for scatter movement.
-- =============================================================

DCSCore      = DCSCore or {}
DCSCore.iads = {}

local IM = DCSCore.iads
local U  = DCSCore.utils

-- groupName -> mission-time at which evasion expires (nil if not evading)
IM._evading     = {}
IM._initialized = false

-- =============================================================
-- IADS Initialisation
-- =============================================================

function IM.initialize()
    local cfg = DCSCore.config.iads

    if not iads then
        U.error('IADS_MANAGER: iads global not found — load iads_v1_r37.lua first')
        return false
    end

    -- Apply settings
    iads.settings.level        = cfg.level
    iads.settings.linked       = cfg.linked
    iads.settings.radarSim     = cfg.radarSim
    iads.settings.refreshRate  = cfg.refreshRate
    iads.settings.timeDelay    = cfg.timeDelay
    iads.settings.debug        = cfg.debug
    iads.settings.addDuplicate = 'replace'

    -- Add RED SAM groups by prefix
    for _, prefix in ipairs(cfg.redPrefixes) do
        iads.addAllByPrefix(prefix)
    end

    -- Add explicit group names
    for _, groupName in ipairs(cfg.redGroups) do
        iads.add(groupName)
    end
    for _, groupName in ipairs(cfg.blueGroups) do
        iads.add(groupName)
    end

    IM._initialized = true
    U.info('IADS_MANAGER: initialized — level ' .. cfg.level)
    return true
end

-- =============================================================
-- Smarter SAM — SEAD Evasion Event Handler
-- =============================================================

IM._seadHandler = {}

function IM._seadHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_SHOT then return end

    local cfg = DCSCore.config.smarterSAM
    if not cfg.enabled then return end

    local weapon = event.weapon
    if not weapon or not weapon:isExist() then return end

    local missileName = weapon:getTypeName()
    if not U.tableContains(cfg.seadMissiles, missileName) then return end

    -- Resolve the targeted unit from the weapon's seeker
    local targetUnit = Weapon.getTarget(weapon)
    if not targetUnit or not targetUnit:isExist() then return end

    local targetGroup = Unit.getGroup(targetUnit)
    if not targetGroup or not targetGroup:isExist() then return end

    local groupName = targetGroup:getName()

    -- Don't stack evasion if already evading
    if IM._evading[groupName] and timer.getTime() < IM._evading[groupName] then
        return
    end

    local delay = math.random(cfg.radarOffMinDelay, cfg.radarOffMaxDelay)
    IM._evading[groupName] = timer.getTime() + delay

    U.debug('IADS_MANAGER: SEAD evasion — ' .. groupName ..
            ' (' .. missileName .. ') dark for ' .. delay .. 's')

    -- Scatter
    if mist then
        mist.groupRandomDistSelf(
            targetGroup,
            cfg.scatterRadius,
            cfg.scatterFormation,
            cfg.scatterMaxOffset,
            cfg.scatterMinOffset
        )
    end

    -- Radar off
    local ctrl = targetGroup:getController()
    ctrl:setOption(AI.Option.Ground.id.ALARM_STATE,
                   AI.Option.Ground.val.ALARM_STATE.GREEN)

    -- Schedule radar back on — capture group reference to avoid stale name lookup
    local groupRef = targetGroup
    timer.scheduleFunction(function()
        if groupRef and groupRef:isExist() then
            groupRef:getController():setOption(
                AI.Option.Ground.id.ALARM_STATE,
                AI.Option.Ground.val.ALARM_STATE.RED
            )
            U.debug('IADS_MANAGER: ' .. groupName .. ' radar restored')
        end
        IM._evading[groupName] = nil
    end, nil, timer.getTime() + delay)

    -- SEAD pilot acknowledgement
    U.msgCoalition(coalition.side.BLUE,
        '[SEAD] ' .. groupName .. ' radar going dark for ~' .. delay .. 's', 8)
end

-- =============================================================
-- Public API
-- =============================================================

--- Force a SAM group dark for `duration` seconds (used by cross-system hooks).
function IM.goDark(groupName, duration)
    duration = duration or 30
    local group = U.getGroup(groupName)
    if not group then return end

    group:getController():setOption(AI.Option.Ground.id.ALARM_STATE,
                                     AI.Option.Ground.val.ALARM_STATE.GREEN)
    IM._evading[groupName] = timer.getTime() + duration

    timer.scheduleFunction(function()
        local g = U.getGroup(groupName)
        if g then
            g:getController():setOption(AI.Option.Ground.id.ALARM_STATE,
                                         AI.Option.Ground.val.ALARM_STATE.RED)
        end
        IM._evading[groupName] = nil
    end, nil, timer.getTime() + duration)
end

--- Returns true if the named SAM group is currently in evasion.
function IM.isEvading(groupName)
    return IM._evading[groupName] ~= nil and
           timer.getTime() < IM._evading[groupName]
end

--- Extend an existing evasion window (called by suppression cross-hook).
function IM.extendDark(groupName, extraSeconds)
    if not IM._evading[groupName] then return end
    IM._evading[groupName] = IM._evading[groupName] + extraSeconds
    U.debug('IADS_MANAGER: dark window extended +' .. extraSeconds ..
            's for ' .. groupName)
end

function IM.setup()
    IM.initialize()
    world.addEventHandler(IM._seadHandler)
    U.info('IADS_MANAGER: SEAD event handler registered')
end

U.info('iads_manager.lua loaded')
