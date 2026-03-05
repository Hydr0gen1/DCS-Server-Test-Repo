-- =============================================================
-- utils.lua
-- Shared utility functions for DCS Core scripts.
-- Must be loaded before any other DCSCore module.
-- =============================================================

DCSCore       = DCSCore or {}
DCSCore.utils = {}

local U = DCSCore.utils

-- =============================================================
-- Logging
-- =============================================================

---@param level number  1=error, 2=info, 3=debug
---@param msg   string
function U.log(level, msg)
    local threshold = (DCSCore.config and DCSCore.config.admin and
                       DCSCore.config.admin.logLevel) or 2
    if level > threshold then return end
    local prefix = '[DCSCore] '
    env.info(prefix .. msg)
    if level == 1 then
        trigger.action.outText(prefix .. 'ERROR: ' .. msg, 20)
    end
end

function U.error(msg) U.log(1, msg) end
function U.info(msg)  U.log(2, msg) end
function U.debug(msg) U.log(3, msg) end

-- =============================================================
-- Safe Unit / Group Access
-- =============================================================

function U.getUnit(name)
    local u = Unit.getByName(name)
    if u and u:isExist() then return u end
    return nil
end

function U.getGroup(name)
    local g = Group.getByName(name)
    if g and g:isExist() then return g end
    return nil
end

-- =============================================================
-- Geometry / Distance
-- =============================================================

--- Flat 2-D distance using DCS x/z axes.
function U.dist2D(v1, v2)
    -- DCS can provide horizontal coordinates as {x,z} (Vec3) or {x,y} (Vec2).
    -- Treat Vec2.y as the horizontal "z" axis when .z is absent.
    local z1 = (v1.z ~= nil) and v1.z or (v1.y or 0)
    local z2 = (v2.z ~= nil) and v2.z or (v2.y or 0)
    local dx = v1.x - v2.x
    local dz = z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

function U.dist3D(v1, v2)
    local dx = v1.x - v2.x
    local dy = (v1.y or 0) - (v2.y or 0)
    local dz = (v1.z or 0) - (v2.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function U.vec3Add(a, b)
    return { x = a.x + b.x, y = (a.y or 0) + (b.y or 0), z = (a.z or 0) + (b.z or 0) }
end

function U.vec3Scale(v, s)
    return { x = v.x * s, y = (v.y or 0) * s, z = (v.z or 0) * s }
end

-- =============================================================
-- Zone Helpers
-- =============================================================

--- Returns a Vec3 for the centre of a named trigger zone, or nil.
function U.getZoneVec3(zoneName)
    local zone = trigger.misc.getZone(zoneName)
    if not zone then return nil end

    -- Some DCS APIs expose trigger-zone centers as Vec2 {x, y}, where y is
    -- the horizontal map axis (equivalent to Vec3.z). Others provide Vec3.
    if zone.point.z ~= nil then
        -- Preserve explicit 3D altitude data when provided.
        return { x = zone.point.x, y = zone.point.y, z = zone.point.z }
    end

    local z = zone.point.y
    local y = land.getHeight({ x = zone.point.x, y = z })
    return { x = zone.point.x, y = y, z = z }
end

--- Returns true when unit is inside the named trigger zone.
function U.unitInZone(unit, zoneName)
    if not unit or not unit:isExist() then return false end
    local zone = trigger.misc.getZone(zoneName)
    if not zone then return false end
    local pos = unit:getPosition().p
    return U.dist2D(pos, zone.point) <= zone.radius
end

--- Returns true when a unit is on the ground and nearly stationary.
---@param unit     userdata
---@param maxAGL   number   metres above ground level
---@param maxSpeed number   m/s
function U.isUnitGrounded(unit, maxAGL, maxSpeed)
    if not unit or not unit:isExist() then return false end
    local pos   = unit:getPosition().p
    local vel   = unit:getVelocity()
    local speed = math.sqrt(vel.x ^ 2 + vel.y ^ 2 + vel.z ^ 2)
    local agl   = pos.y - land.getHeight({ x = pos.x, y = pos.z })
    return agl <= maxAGL and speed <= maxSpeed
end

-- =============================================================
-- World Search
-- =============================================================

--- Return all live units within a sphere, optionally filtered by coalition.
---@param point      Vec3
---@param radius     number  metres
---@param sideFilter number|nil  coalition.side.* or nil for all
---@return table
function U.getUnitsInRadius(point, radius, sideFilter)
    local result = {}
    local volume = {
        id     = world.VolumeType.SPHERE,
        params = { point = point, radius = radius },
    }
    world.searchObjects(Object.Category.UNIT, volume, function(obj)
        if obj and obj:isExist() then
            if sideFilter == nil or obj:getCoalition() == sideFilter then
                table.insert(result, obj)
            end
        end
        return true
    end)
    return result
end

-- =============================================================
-- Messaging
-- =============================================================

function U.msgCoalition(side, text, duration)
    trigger.action.outTextForCoalition(side, text, duration or 10)
end

function U.msgAll(text, duration)
    trigger.action.outText(text, duration or 10)
end

-- =============================================================
-- Scheduling
-- =============================================================

function U.schedule(func, delay, args)
    timer.scheduleFunction(func, args, timer.getTime() + delay)
end

-- =============================================================
-- Table helpers
-- =============================================================

function U.tableContains(t, val)
    for _, v in ipairs(t) do
        if v == val then return true end
    end
    return false
end

function U.tableLength(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Shallow merge: copies keys from src into dst, returns dst.
function U.tableMerge(dst, src)
    for k, v in pairs(src) do dst[k] = v end
    return dst
end

U.info('utils.lua loaded')
