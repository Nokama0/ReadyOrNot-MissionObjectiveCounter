-- MissionObjectiveCounter/Scripts/layout.lua
-- Pure. No engine calls, no globals from UE4SS. Everything here is unit
-- tested headlessly under Lua 5.4, matching UE4SS's embedded interpreter,
-- which matters because a formatting bug that only shows up in game costs a
-- round trip through the game to find.
local M = {}

local MISSING = "-"

--- Render a possibly-missing count. nil means the read failed and must not be
--- shown as 0, which would be indistinguishable from a real empty category.
function M.fmt(n)
    if n == nil then return MISSING end
    return tostring(n)
end

function M.ratio(num, den)
    return M.fmt(num) .. " / " .. M.fmt(den)
end

--- Clamp a composite numerator to its total. Returns the clamped value and
--- whether it overflowed, so the caller can log the anomaly once.
function M.clamp(num, den)
    if num == nil or den == nil then return num, false end
    if num > den then return den, true end
    return num, false
end

local DOT = " \194\183 "  -- UTF-8 middle dot, written as bytes so the file
                          -- stays ASCII-safe through any editor or copy step.

local function joinParts(parts)
    return table.concat(parts, DOT)
end

--- Build the label/value/detail rows for the four raw categories.
-- Returns the rows and whether any composite numerator overflowed its total.
function M.counterRows(stats)
    local rows, overflowed = {}, false

    local function add(label, num, den, parts)
        -- A category with a zero total is not present in this mission.
        if den == 0 then return end
        local clamped, over = M.clamp(num, den)
        if over then overflowed = true end
        rows[#rows + 1] = {
            kind = "counter",
            label = label,
            value = M.ratio(clamped, den),
            detail = joinParts(parts),
        }
    end

    local s = stats.suspects
    if s then
        -- arrested + killed are mutually exclusive outcomes so they sum.
        -- reported overlaps with killed and is shown separately only.
        local handled = nil
        if s.arrested ~= nil and s.killed ~= nil then
            handled = s.arrested + s.killed
        end
        add("SUSPECTS", handled, s.total, {
            M.fmt(s.reported) .. " reported",
            M.fmt(s.arrested) .. " arrested",
            M.fmt(s.killed) .. " killed",
        })
    end

    local c = stats.civilians
    if c then
        local handled = nil
        if c.arrested ~= nil and c.killed ~= nil then
            handled = c.arrested + c.killed
        end
        add("CIVILIANS", handled, c.total, {
            M.fmt(c.reported) .. " reported",
            M.fmt(c.injured) .. " injured",
            M.fmt(c.killed) .. " killed",
            M.fmt(c.arrested) .. " arrested",
        })
    end

    local e = stats.evidence
    if e then add("EVIDENCE", e.collected, e.total, {}) end

    local r = stats.reports
    if r then add("REPORTS", r.reported, r.total, {}) end

    return rows, overflowed
end

local LEVEL_NAME = { [0] = "primary", [1] = "secondary", [2] = "tertiary" }
local STATUS_NAME = { [0] = "active", [1] = "done", [2] = "failed" }

--- Score groups are the game's own graded objective taxonomy, which is what
--- the results screen actually marks you against.
function M.groupRows(groups)
    if not groups or #groups == 0 then return {} end
    local complete = 0
    for _, g in ipairs(groups) do
        if g.given ~= nil and g.total ~= nil and g.given >= g.total then
            complete = complete + 1
        end
    end
    local rows = {
        { kind = "section", label = "SCORE GROUPS",
          value = M.ratio(complete, #groups), detail = "" },
    }
    for _, g in ipairs(groups) do
        rows[#rows + 1] = {
            kind = "entry",
            label = LEVEL_NAME[g.level] or "other",
            value = M.ratio(g.given, g.total),
            detail = g.name or "",
        }
    end
    return rows
end

--- Status is carried as a text prefix rather than by colour alone. Colour is
--- applied on top in panel.lua as an enhancement, so if setting FSlateColor
--- through the Lua binding fails the panel is still fully readable.
function M.objectiveRows(objectives, cfg)
    if not objectives then return {} end
    local failedText = ""
    if objectives.failed ~= nil and objectives.failed > 0 then
        failedText = objectives.failed .. " failed"
    end
    local rows = {
        { kind = "section", label = "OBJECTIVES",
          value = M.ratio(objectives.complete, objectives.total),
          detail = failedText },
    }
    for _, o in ipairs(objectives.list or {}) do
        if cfg.SHOW_HIDDEN or not o.hidden then
            rows[#rows + 1] = {
                kind = "entry",
                label = STATUS_NAME[o.status] or "unknown",
                value = "",
                detail = o.name or "",
            }
        end
    end
    return rows
end

local function appendAll(dest, src)
    for _, row in ipairs(src) do dest[#dest + 1] = row end
end

--- The single entry point. Returns display rows and whether any composite
--- numerator overflowed, which main.lua logs once.
function M.build(stats, cfg)
    local rows = {
        { kind = "title", label = "MISSION OBJECTIVES", value = "", detail = "" },
    }
    local overflowed = false

    local function section(src)
        if #src == 0 then return end
        rows[#rows + 1] = { kind = "blank", label = "", value = "", detail = "" }
        appendAll(rows, src)
    end

    if cfg.SHOW_COUNTERS then
        local counters, over = M.counterRows(stats)
        overflowed = over
        section(counters)
    end
    if cfg.SHOW_SCOREGROUPS then section(M.groupRows(stats.groups)) end
    if cfg.SHOW_OBJECTIVES then section(M.objectiveRows(stats.objectives, cfg)) end

    return rows, overflowed
end

return M
