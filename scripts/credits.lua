-- =============================================================
-- credits.lua
-- Resource credit system for both coalitions.
--
-- EARNING CREDITS
--   • S_EVENT_DEAD: kills award credits to the opposing coalition.
--     Values are tiered by unit class (naval > air > armor > SAM >
--     artillery > soft targets > infantry).
--   • Bonus credits when artillery CB suppression leads directly
--     to a kill (unit dies while suppressed — detected here).
--   • Starting credits configured in cfg.credits.
--
-- SPENDING CREDITS
--   • Manual convoy dispatch:     cfg.logistics.manualConvoyCost
--   • Auto artillery resupply:    cfg.logistics.autoConvoyCost
--   • Auto SAM resupply:          cfg.logistics.samResupplyCost
--   • Credits.spendCredits() returns false without deducting if
--     the coalition cannot afford it — callers must check.
--
-- F10 MENU
--   • "Credits" sub-menu shows current balance for each coalition.
--     Available to all players (not just admins).
-- =============================================================

DCSCore         = DCSCore or {}
DCSCore.credits = {}

local CR = DCSCore.credits
local U  = DCSCore.utils

-- =============================================================
-- Credit pool  (initialized in setup())
-- =============================================================

CR._pool = {}   -- coalition.side.* -> number

-- =============================================================
-- Kill value table
-- Attributes are checked top-to-bottom; first match wins.
-- Uses DCS unit attribute strings.
-- =============================================================

local KILL_VALUES = {
    -- ── Naval ─────────────────────────────────────────────────
    { attr = 'Aircraft Carriers', credits = 300 },
    { attr = 'Battleships',       credits = 200 },
    { attr = 'Cruisers',          credits = 150 },
    { attr = 'Destroyers',        credits = 120 },
    { attr = 'Frigates',          credits = 80  },
    { attr = 'Ships',             credits = 60  },  -- generic ship fallback

    -- ── Air ───────────────────────────────────────────────────
    { attr = 'Strategic bombers', credits = 200 },
    { attr = 'Bombers',           credits = 150 },
    { attr = 'Attack aircraft',   credits = 120 },
    { attr = 'Fighters',          credits = 100 },
    { attr = 'Helicopters',       credits = 75  },
    { attr = 'UAVs',              credits = 50  },

    -- ── SAM systems (highest-value ground) ────────────────────
    { attr = 'SAM CC',            credits = 120 },  -- command/control
    { attr = 'SAM SR',            credits = 100 },  -- search radar
    { attr = 'SAM TR',            credits = 100 },  -- track radar
    { attr = 'SAM LL',            credits = 75  },  -- launcher

    -- ── Armor ─────────────────────────────────────────────────
    { attr = 'Tanks',             credits = 60  },
    { attr = 'IFV',               credits = 35  },
    { attr = 'APC',               credits = 25  },

    -- ── Fire support ──────────────────────────────────────────
    { attr = 'MLRS',              credits = 70  },
    { attr = 'Artillery',         credits = 50  },
    { attr = 'AAA',               credits = 30  },
    { attr = 'MANPADS',           credits = 20  },

    -- ── Soft targets ──────────────────────────────────────────
    { attr = 'Trucks',            credits = 10  },
    { attr = 'Vehicles',          credits = 15  },  -- generic vehicle fallback
    { attr = 'Ground vehicles',   credits = 15  },
    { attr = 'Infantry',          credits = 5   },
}

-- Bonus credits when a unit dies while suppressed by our system.
-- (Confirms that the suppression actually contributed to the kill.)
local SUPPRESSION_KILL_BONUS = 10

-- =============================================================
-- Internal helpers
-- =============================================================

local function getKillValue(unit)
    if not unit or not unit:isExist() then return 0 end
    for _, entry in ipairs(KILL_VALUES) do
        if unit:hasAttribute(entry.attr) then
            return entry.credits
        end
    end
    return 0
end

local function opposingSide(side)
    if side == coalition.side.BLUE then return coalition.side.RED  end
    if side == coalition.side.RED  then return coalition.side.BLUE end
    return nil
end

-- =============================================================
-- Event handler
-- =============================================================

CR._handler = {}

function CR._handler:onEvent(event)
    if event.id ~= world.event.S_EVENT_DEAD then return end

    local unit = event.initiator
    if not unit then return end
    if unit:getCategory() ~= Object.Category.UNIT then return end

    local deadSide = unit:getCoalition()
    local earnSide = opposingSide(deadSide)
    if not earnSide then return end   -- neutral, skip

    local value = getKillValue(unit)
    if value <= 0 then return end

    -- Base kill credit
    CR.addCredits(earnSide, value, unit:getTypeName())

    -- Suppression assist bonus
    if DCSCore.suppression then
        local groupName = unit:getGroup() and unit:getGroup():getName()
        if groupName and DCSCore.suppression.isSuppressed(groupName) then
            CR.addCredits(earnSide, SUPPRESSION_KILL_BONUS,
                'suppression-assist:' .. unit:getTypeName())
        end
    end
end

-- =============================================================
-- Public API
-- =============================================================

--- Add credits to a coalition.
---@param side    number  coalition.side.*
---@param amount  number
---@param reason  string  logged only
function CR.addCredits(side, amount, reason)
    CR._pool[side] = (CR._pool[side] or 0) + amount
    U.debug(string.format('CREDITS: +%d [%s] %s → total %d',
        amount,
        side == coalition.side.BLUE and 'BLU' or 'RED',
        reason or '',
        CR._pool[side]))
end

--- Spend credits.  Returns true on success, false if insufficient.
---@param side    number  coalition.side.*
---@param amount  number
---@return boolean
function CR.spendCredits(side, amount)
    local current = CR._pool[side] or 0
    if current < amount then
        U.debug(string.format('CREDITS: insufficient [%s] need %d have %d',
            side == coalition.side.BLUE and 'BLU' or 'RED', amount, current))
        return false
    end
    CR._pool[side] = current - amount
    U.debug(string.format('CREDITS: -%d [%s] → remaining %d',
        amount,
        side == coalition.side.BLUE and 'BLU' or 'RED',
        CR._pool[side]))
    return true
end

--- Return current balance for a coalition.
---@param side number  coalition.side.*
---@return number
function CR.getCredits(side)
    return CR._pool[side] or 0
end

--- Build a short balance string for status messages.
function CR.balanceStr()
    return string.format('Credits — BLU: %d  RED: %d',
        CR.getCredits(coalition.side.BLUE),
        CR.getCredits(coalition.side.RED))
end

-- =============================================================
-- F10 menu  (visible to all players)
-- =============================================================

local function buildF10Menus()
    local function showBalance(side)
        local bal = CR.getCredits(side)
        -- Also show recent spending breakdown (last 3 transactions)
        U.msgCoalition(side,
            string.format('[CREDITS] Balance: %d cr', bal), 12)
    end

    local function creditHelp(side)
        local lines = {
            '[CREDITS] How to earn:',
            '  Infantry kill:    +5',
            '  Vehicle kill:     +15',
            '  Armor kill:       +25-60',
            '  Artillery kill:   +50',
            '  SAM kill:         +75-120',
            '  Aircraft kill:    +75-150',
            '  Suppression assist: +10 bonus',
            '',
            '[CREDITS] Costs:',
            string.format('  Manual convoy:    %d cr',
                (DCSCore.config.logistics and DCSCore.config.logistics.manualConvoyCost) or 30),
            string.format('  Auto arty resup:  %d cr',
                (DCSCore.config.logistics and DCSCore.config.logistics.autoConvoyCost) or 50),
            string.format('  SAM resupply:     %d cr',
                (DCSCore.config.logistics and DCSCore.config.logistics.samResupplyCost) or 75),
        }
        U.msgCoalition(side, table.concat(lines, '\n'), 30)
    end

    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local m = missionCommands.addSubMenuForCoalition(side, 'Credits', nil)
        missionCommands.addCommandForCoalition(side, 'Balance', m, showBalance, side)
        missionCommands.addCommandForCoalition(side, 'How Credits Work', m, creditHelp, side)
    end
end

-- =============================================================
-- Setup
-- =============================================================

function CR.setup()
    local cfg = DCSCore.config.credits
    if not cfg or not cfg.enabled then
        U.info('CREDITS: disabled in config')
        return
    end

    CR._pool[coalition.side.BLUE] = cfg.blueStartingCredits or 500
    CR._pool[coalition.side.RED]  = cfg.redStartingCredits  or 500

    world.addEventHandler(CR._handler)
    buildF10Menus()

    U.info(string.format('CREDITS: initialized — BLU=%d  RED=%d',
        CR._pool[coalition.side.BLUE], CR._pool[coalition.side.RED]))
end

U.info('credits.lua loaded')
