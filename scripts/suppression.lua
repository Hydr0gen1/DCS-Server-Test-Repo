-- =============================================================
-- suppression.lua
-- Ground-unit suppression fire system.
--
-- Any hit on an eligible unit sets ROE to WEAPON_HOLD for
-- `baseHoldTime` seconds.  Repeated hits extend suppression
-- (with diminishing returns) up to `maxHoldTime`.
-- After suppression expires ROE is restored to OPEN_FIRE.
--
-- Integrates with iads_manager: hits on SAM groups that are
-- already SEAD-evading extend their radar-off window.
--
-- No external dependencies.
-- =============================================================

DCSCore            = DCSCore or {}
DCSCore.suppression = {}

local SUP = DCSCore.suppression
local U   = DCSCore.utils

-- groupName -> { expiry: number, hitCount: number }
SUP._state = {}

-- =============================================================
-- Core suppression logic
-- =============================================================

local function applyROEHold(group)
    group:getController():setOption(
        AI.Option.Ground.id.ROE,
        AI.Option.Ground.val.ROE.WEAPON_HOLD
    )
end

local function liftROE(group)
    if group and group:isExist() then
        group:getController():setOption(
            AI.Option.Ground.id.ROE,
            AI.Option.Ground.val.ROE.OPEN_FIRE
        )
    end
end

-- Polls until the suppression window has truly expired, then lifts ROE.
-- Uses a recursive reschedule rather than a fixed timer so that extensions
-- applied between calls are always honoured.
local function scheduleLiftCheck(groupName)
    local cfg = DCSCore.config.suppression
    timer.scheduleFunction(function()
        local state = SUP._state[groupName]
        if not state then return end  -- already cleared externally

        if timer.getTime() < state.expiry then
            -- Still suppressed — reschedule
            scheduleLiftCheck(groupName)
            return
        end

        -- Suppression expired
        SUP._state[groupName] = nil
        local group = U.getGroup(groupName)
        liftROE(group)
        U.debug('SUP: suppression lifted on ' .. groupName)
    end, nil, timer.getTime() + cfg.baseHoldTime)
end

--- Apply or extend suppression on a group.
function SUP._suppress(group)
    local cfg  = DCSCore.config.suppression
    local name = group:getName()
    local now  = timer.getTime()

    local state = SUP._state[name]

    if state then
        -- Extend with diminishing returns
        local extension = cfg.holdExtension / (state.hitCount + 1)
        local newExpiry = math.min(state.expiry + extension, now + cfg.maxHoldTime)
        SUP._state[name] = { expiry = newExpiry, hitCount = state.hitCount + 1 }
        U.debug(string.format('SUP: extended %s hit#%d +%.1fs (expires in %.0fs)',
            name, state.hitCount + 1, extension, newExpiry - now))
        -- Cross-hook: if this is a SEAD-evading SAM, extend its dark window too
        if DCSCore.iads and DCSCore.iads.isEvading(name) then
            DCSCore.iads.extendDark(name, extension)
        end
        return
    end

    -- New suppression
    SUP._state[name] = { expiry = now + cfg.baseHoldTime, hitCount = 1 }
    applyROEHold(group)
    U.debug('SUP: suppressing ' .. name .. ' for ' .. cfg.baseHoldTime .. 's')
    scheduleLiftCheck(name)
end

-- =============================================================
-- Hit Event Handler
-- =============================================================

SUP._handler = {}

function SUP._handler:onEvent(event)
    if event.id ~= world.event.S_EVENT_HIT then return end

    local cfg = DCSCore.config.suppression
    if not cfg.enabled then return end

    local target = event.target
    if not target or not target:isExist() then return end
    if target:getCategory() ~= Object.Category.UNIT then return end

    -- Optional attribute filter (e.g. 'Infantry')
    if cfg.unitAttribute and not target:hasAttribute(cfg.unitAttribute) then
        return
    end

    local group = target:getGroup()
    if not group or not group:isExist() then return end

    SUP._suppress(group)
end

-- =============================================================
-- Public API
-- =============================================================

--- Manually suppress a group for `duration` seconds.
function SUP.suppressGroup(groupName, duration)
    local group = U.getGroup(groupName)
    if not group then
        U.error('SUP.suppressGroup: group not found — ' .. groupName)
        return
    end
    local cfg    = DCSCore.config.suppression
    local saved  = cfg.baseHoldTime
    cfg.baseHoldTime = duration or saved
    SUP._suppress(group)
    cfg.baseHoldTime = saved
end

--- Returns true if the group is currently suppressed.
function SUP.isSuppressed(groupName)
    local state = SUP._state[groupName]
    return state ~= nil and timer.getTime() < state.expiry
end

--- Immediately clear suppression from a group (used by admin commands).
function SUP.clearSuppression(groupName)
    local state = SUP._state[groupName]
    if not state then return end
    SUP._state[groupName] = nil
    local group = U.getGroup(groupName)
    liftROE(group)
    U.info('SUP: suppression manually cleared on ' .. groupName)
end

function SUP.setup()
    world.addEventHandler(SUP._handler)
    U.info('SUPPRESSION: hit event handler registered')
end

U.info('suppression.lua loaded')
