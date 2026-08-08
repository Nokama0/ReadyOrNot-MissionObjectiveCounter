-- MissionObjectiveCounter/Scripts/source.lua
-- Reads mission state through UE4SS reflection. Read-only: this module calls
-- nothing that mutates game state.
-- The reflected signatures it targets, and the out-param calling convention
-- it works around, are written up in UE4SS-NOTES.md sections 8 and 2.
--
-- UE4SS-NOTES.md and the section numbers referenced below are in this
-- repository: https://github.com/Nokama0/ReadyOrNot-MissionObjectiveCounter
local M = {}

-- UE4SS embeds Lua 5.4.7, not LuaJIT, so there is no global `unpack`: a bare
-- unpack(...) raises and breaks every out-param read. One shim, used at every
-- call site below, correct under both dialects. See UE4SS-NOTES.md section 1.
local unpackList = table.unpack or unpack

local log = function() end
function M.setLogger(fn) log = fn end

-- Diagnostics are the one-time, per-mission discovery lines below, opt-in via
-- CONFIG.DIAGNOSTICS so a normal player's log stays quiet. Genuine failures,
-- such as a function that cannot be read, are never gated by this.
local diagEnabled = false
function M.setDiagnostics(enabled) diagEnabled = enabled end

local function try(fn, fallback)
    local ok, r = pcall(fn)
    if ok and r ~= nil then return r end
    return fallback
end

local function isLive(obj)
    if not obj then return false end
    if not try(function() return obj:IsValid() end, false) then return false end
    -- Class default objects carry the properties but none of the live state.
    local name = try(function() return obj:GetFullName() end, "")
    return not name:find("Default__", 1, true)
end

-- ---------------------------------------------------------------- resolution

local scoringManager, gameState

-- Forward declaration; defined below, next to the latches it clears.
local resetWarnings

-- Once-per-mission latches for resolve()'s missing-source reports, declared
-- ahead of it so it closes over these rather than falling through to globals.
local warnedNoScoring, warnedNoGameState = false, false
-- The matching arrival latches. A missing source announced once and never
-- corrected would stand as the log's account of the whole mission.
local warnedScoringArrived, warnedGameStateArrived = false, false

local function resolve()
    if not isLive(scoringManager) then
        scoringManager = try(function() return FindFirstOf("ScoringManager") end, nil)
        if not isLive(scoringManager) then scoringManager = nil end
    end
    if not isLive(gameState) then
        gameState = try(function() return FindFirstOf("ReadyOrNotGameState") end, nil)
        if not isLive(gameState) then gameState = nil end
    end

    -- Report a missing source once per mission, unconditionally. On a co-op
    -- client this is the difference between a diagnosable gap and silence.
    if scoringManager == nil and gameState ~= nil and not warnedNoScoring then
        warnedNoScoring = true
        log("no live ScoringManager here; counters and score groups are "
          .. "unavailable, objectives still are not")
    end
    if gameState == nil and scoringManager ~= nil and not warnedNoGameState then
        warnedNoGameState = true
        log("no live GameState here; the objective list is unavailable, "
          .. "counters still are not")
    end

    -- ...and report its arrival if it turns up later, once, the same way. On
    -- a joining client the GameState replicates before the ScoringManager, so
    -- a missing manager on the first poll is expected. Without these lines the
    -- log's account of a working mission stands as "unavailable".
    if scoringManager ~= nil and warnedNoScoring and not warnedScoringArrived then
        warnedScoringArrived = true
        log("a live ScoringManager resolved on a later poll; counters and "
          .. "score groups are available after all")
    end
    if gameState ~= nil and warnedNoGameState and not warnedGameStateArrived then
        warnedGameStateArrived = true
        log("a live GameState resolved on a later poll; the objective list "
          .. "is available after all")
    end

    -- Either source alone is worth showing a panel for.
    return scoringManager ~= nil or gameState ~= nil
end

function M.reset()
    scoringManager, gameState = nil, nil
    resetWarnings()
end

-- ------------------------------------------------------- out-param handling
-- UE4SS wants one fresh table per out-param, passed positionally, and fills
-- them keyed by each parameter's declared name. Whether older call shapes
-- also work on a given build is not knowable from a header dump, so every
-- call works the shape out from what came back and records it per function.
-- Guessing is how a reflected call runs cleanly and reads nothing at all.
-- See UE4SS-NOTES.md section 2 for the verbatim error strings.
local shapes = {}          -- function name -> resolved shape
local arityWarned = {}     -- function name -> already logged an arity mismatch
local typeWarned = {}      -- function name -> already logged a non-numeric value
local reasonWarned = {}    -- function name -> already logged the full failure reason
local tablesDiagLogged = {} -- function name -> already logged the tables-shape discovery line

-- Once-per-mission diagnostic latches. Unlike shapes, a durable fact about
-- the binding that deliberately survives reset, these are cleared each time.
local identityLogged = false
local reachabilityLogged = false
local groupSummaryLogged = false
local dialectLogged = false
local groupResolveLogged = false

--- Which route resolveGroupElement took most recently: ":get()" when the
--- inner struct's GroupName came back readable, "direct" otherwise. Recorded
--- so the diagnostic reports what readGroups actually relied on.
local lastGroupRoute = nil

--- Clear the once-per-mission log latches, called from reset().
-- Without this a second mission shows the symptom (every field a dash) with
-- none of the lines that explain it. shapes is deliberately not cleared: it
-- is the answer the probe exists to find, and it holds for the session.
resetWarnings = function()
    arityWarned, typeWarned, reasonWarned, tablesDiagLogged = {}, {}, {}, {}
    identityLogged, reachabilityLogged, groupSummaryLogged, dialectLogged =
        false, false, false, false
    groupResolveLogged = false
    warnedNoScoring, warnedNoGameState = false, false
    warnedScoringArrived, warnedGameStateArrived = false, false
    -- Not a latch, but per-mission all the same: left set, a mission whose
    -- score groups are never read would report the previous mission's route.
    lastGroupRoute = nil
end

-- Values arrive from the binding untyped and layout.lua assumes numbers, so
-- coerce here: tonumber turns anything else into nil, which every consumer
-- renders as a dash. A missing read must never be shown as 0.
-- Discarding silently left no trace anywhere, so it is logged, latched per
-- function because this sits in the poll path and one bad binding must not
-- mask another.
local function num(v, fnName, field)
    if v == nil then return nil end
    local n = tonumber(v)
    if n == nil and fnName and not typeWarned[fnName] then
        typeWarned[fnName] = true
        log("%s: %s is a %s, not a number; it is shown as a dash",
            fnName, field or "the return value", type(v))
    end
    return n
end

local function extract(fnName, names, ...)
    local n = select('#', ...)
    if n == 0 then return nil end
    local first = select(1, ...)

    -- Exactly one return value per out-param. A looser n >= #names would read
    -- past a leading value the binding might put first, shifting every field
    -- by one and producing plausible but wrong counts with no error at all.
    if n == #names and type(first) ~= "table" then
        shapes[fnName] = shapes[fnName] or "multi"
        local out = {}
        for i, key in ipairs(names) do
            out[key] = num((select(i, ...)), fnName, key)
        end
        return out
    end

    if n > #names and not arityWarned[fnName] then
        arityWarned[fnName] = true
        log("%s returned %d values for %d out-params; not reading positionally",
            fnName, n, #names)
    end

    if type(first) == "table" then
        -- Table-named: accept if AT LEAST ONE expected key is present, then
        -- populate every field independently. Requiring all keys cannot tell
        -- "wrong shape" from "one field failed", and would blank the siblings.
        local anyNamed = false
        for _, key in ipairs(names) do
            if first[key] ~= nil then anyNamed = true break end
        end
        if anyNamed then
            shapes[fnName] = shapes[fnName] or "table-named"
            local out = {}
            for _, key in ipairs(names) do
                out[key] = num(first[key], fnName, key)
            end
            return out
        end

        -- Table-indexed: same independent-per-field principle, probing each
        -- index directly since #first is undefined once the table has holes.
        local anyIndexed = false
        for i = 1, #names do
            if first[i] ~= nil then anyIndexed = true break end
        end
        if anyIndexed then
            shapes[fnName] = shapes[fnName] or "table-indexed"
            local out = {}
            for i, key in ipairs(names) do
                out[key] = num(first[i], fnName, key)
            end
            return out
        end
    end
    return nil
end

-- ------------------------------------------------------ tables out-param shape

--- Resolve one out-parameter by its own declared name, searching every table
--- passed to the call, in order. A live run confirmed UE4SS fills ONE table
--- (the first) with every out-param, keyed by its real parameter name, which
--- is exactly the `names` list callOut already passes. Searching all of them
--- also covers a build that fills each table with only its own key.
local function resolveByName(argTables, key)
    for i = 1, #argTables do
        local t = argTables[i]
        if type(t) == "table" and t[key] ~= nil then
            return t[key]
        end
    end
    return nil
end

--- Resolve a value out of one out-parameter table via its own conventions,
--- trying every candidate UE4SS might have written it under. Returns (value,
--- convention) or (nil, nil), and stays a fallback after resolveByName.
-- Order: the argument itself if already a number; t.Value; t[1]; and, if the
-- table holds exactly one pair, that pair's value.
local function resolveOutValue(t)
    if type(t) == "number" then return t, "self" end
    if type(t) ~= "table" then return nil, nil end
    if t.Value ~= nil then return t.Value, "Value" end
    if t[1] ~= nil then return t[1], "[1]" end
    local onlyVal, onlyKey, count = nil, nil, 0
    for k, v in pairs(t) do
        count = count + 1
        if count > 1 then return nil, nil end
        onlyVal, onlyKey = v, k
    end
    if count == 1 then
        return onlyVal, "single-key(" .. tostring(onlyKey) .. ")"
    end
    return nil, nil
end

-- ------------------------------------------------------------- diagnostics
-- Whether a call shape failed by raising, and with what message, or by
-- returning nothing usable, separates a function that cannot be reached from
-- one that hands back something unreadable, so it is captured rather than
-- thrown away. Every line here carries "[diag]" for one grep of UE4SS.log.
local DIAG = "[diag] "
local ERR_MAX = 160        -- keep one log line readable

--- Log a [diag] line, only when CONFIG.DIAGNOSTICS is on. Every one-time
--- discovery line goes through this, so DIAGNOSTICS = false guarantees none
--- can be emitted. callOut's "could not read" line is the one exception: an
--- ongoing failure rather than a discovery, so it stays unconditional.
local function diagLog(fmt, ...)
    if not diagEnabled then return end
    log(DIAG .. fmt, ...)
end

--- Render a pcall error value as a short, single-line, quoted string.
local function truncate(v)
    local s = tostring(v):gsub("[\r\n]+", " ")
    if #s > ERR_MAX then s = s:sub(1, ERR_MAX) .. "...(truncated)" end
    return s
end

--- Capture a call's return values without losing the count. `{f()}` alone
--- loses it when trailing values are nil, which this file treats as real.
local function capture(...)
    return select('#', ...), { ... }
end

--- Attempt one out-param call shape and report the outcome distinctly.
-- Returns (result, nil) on success, or (nil, detail) where detail is either
-- `raised "<message>"` or `returned N values`, so a call that errored and one
-- that completed unreadably are never conflated in the log.
local function callVariant(obj, fnName, names, args)
    local n, vals = 0, {}
    local ok, err = pcall(function()
        if args then
            n, vals = capture(obj[fnName](obj, unpackList(args, 1, #args)))
        else
            n, vals = capture(obj[fnName](obj))
        end
    end)
    if not ok then
        return nil, string.format('raised "%s"', truncate(err))
    end
    local result = extract(fnName, names, unpackList(vals, 1, n))
    if result then return result, nil end
    return nil, string.format("returned %d value%s", n, n == 1 and "" or "s")
end

--- Reduce a per-field convention map to one string: the shared convention
--- when every resolved field agreed, a breakdown when they did not.
local function summariseConvention(names, convByField)
    local first, uniform = nil, true
    for _, key in ipairs(names) do
        local c = convByField[key]
        if c then
            if first == nil then first = c
            elseif c ~= first then uniform = false end
        end
    end
    if first == nil then return nil end
    if uniform then return first end
    local parts = {}
    for _, key in ipairs(names) do
        parts[#parts + 1] = key .. "=" .. (convByField[key] or "unresolved")
    end
    return table.concat(parts, ", ")
end

--- Attempt the tables out-param shape: one fresh, empty table per out-param,
--- passed positionally, read back out of each table after the call. The
--- tables are built here per call and never hoisted or reused: UE4SS stores a
--- reference to what it is given, so a stale value in a reused table is
--- indistinguishable from one the engine just wrote.
-- Each field resolves by its own declared name first, then resolveOutValue's
-- candidates, then the positional return value, independently, so a binding
-- mixing conventions still comes out whole.
local function callTablesVariant(obj, fnName, names)
    local argTables = {}
    for i = 1, #names do argTables[i] = {} end

    local n, vals = 0, {}
    local ok, err = pcall(function()
        n, vals = capture(obj[fnName](obj, unpackList(argTables, 1, #argTables)))
    end)
    if not ok then
        return nil, string.format('raised "%s"', truncate(err)), nil, 0, {}
    end

    -- Return values are usable positionally only when their count matches the
    -- out-param count and none is itself a table, which extract() handles.
    local returnsUsable = n == #names
    if returnsUsable then
        for i = 1, n do
            if type(vals[i]) == "table" then returnsUsable = false break end
        end
    end

    local out, anyValue, convByField = {}, false, {}
    for i, key in ipairs(names) do
        local raw = resolveByName(argTables, key)
        local convention = raw ~= nil and "by-name" or nil
        if raw == nil then
            raw, convention = resolveOutValue(argTables[i])
        end
        if raw == nil and returnsUsable then
            raw = vals[i]
            if raw ~= nil then convention = "return value" end
        end
        if raw ~= nil then
            anyValue = true
            convByField[key] = convention
        end
        out[key] = num(raw, fnName, key)
    end

    if not anyValue then
        -- "tables empty" would contradict the discovery line one line away
        -- when the tables held content matching no known convention.
        local anyContent = false
        for i = 1, #argTables do
            local t = argTables[i]
            if type(t) == "table" and next(t) ~= nil then anyContent = true break end
        end
        local detail
        if anyContent then
            detail = string.format(
                "returned %d value%s, tables held data but none of it matched "
              .. "a known out-param name or position", n, n == 1 and "" or "s")
        else
            detail = string.format("returned %d value%s, tables empty",
                n, n == 1 and "" or "s")
        end
        return nil, detail, argTables, n, vals
    end
    return out, nil, argTables, n, vals, summariseConvention(names, convByField)
end

--- Log, once per function, what the tables shape actually found. Runs only
--- after a call that did not raise, since a raise is already reported by the
--- "could not read" line below.
-- wonBy is non-nil exactly when the call resolved, and names the winning
-- convention. When nil, the three branches below narrow down why, the last of
-- them dumping the table because that is the line that would reveal a
-- convention every candidate guessed wrong.
local function logTablesDiscovery(fnName, argTables, n, vals, wonBy)
    if tablesDiagLogged[fnName] then return end
    tablesDiagLogged[fnName] = true

    local first = argTables and argTables[1]
    local hasPairs = type(first) == "table" and next(first) ~= nil

    if wonBy then
        local parts = {}
        if hasPairs then
            for k, v in pairs(first) do
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
            table.sort(parts)
        end
        diagLog("out-param table for %s resolved via %s: %s",
            fnName, wonBy,
            hasPairs and table.concat(parts, ", ") or "(no keys in the first table)")
        return
    end

    if not hasPairs and n and n > 0 then
        local retParts = {}
        for i = 1, n do retParts[#retParts + 1] = tostring(vals[i]) end
        diagLog("out-param table for %s was empty; %d return value%s "
          .. "arrived instead: %s", fnName, n, n == 1 and "" or "s",
            table.concat(retParts, ", "))
        return
    end

    if not hasPairs then
        diagLog("out-param table for %s: first table is %s and empty, "
          .. "no return values arrived either", fnName, type(first))
        return
    end

    local typeParts = {}
    for k, v in pairs(first) do
        typeParts[#typeParts + 1] = string.format("%s=%s(%s)", tostring(k), type(v), tostring(v))
    end
    table.sort(typeParts)
    diagLog("out-param table for %s contained keys but none matched a "
      .. "known convention: %s", fnName, table.concat(typeParts, ", "))
end

--- Call a void UFunction whose parameters are all out-params. names must list
--- them in declaration order.
-- The tables shape is tried first because UE4SS's own error text says it
-- wants a table per out-param, not a placeholder value. The
-- positional-placeholder and no-args shapes stay as fallbacks.
local function callOut(obj, fnName, names)
    local tablesResult, tablesDetail, argTables, tN, tVals, wonBy =
        callTablesVariant(obj, fnName, names)
    if argTables then
        logTablesDiscovery(fnName, argTables, tN, tVals, wonBy)
    end
    if tablesResult then
        shapes[fnName] = shapes[fnName] or "tables"
        return tablesResult
    end

    local args = {}
    for i = 1, #names do args[i] = 0 end
    local result, argsDetail = callVariant(obj, fnName, names, args)
    if result then return result end

    local result2, multiDetail = callVariant(obj, fnName, names, nil)
    if result2 then return result2 end

    if not reasonWarned[fnName] then
        reasonWarned[fnName] = true
        log(DIAG .. "could not read %s: tables %s; args %s; multi %s",
            fnName, tablesDetail, argsDetail, multiDetail)
    end
    return {}
end

--- Which out-param shape the reads resolved to, as one string for the log.
-- One name when every function agreed, a per-function breakdown when they did
-- not: a single global would report whichever resolved first and hide it.
function M.callShape()
    local names = {}
    for fnName in pairs(shapes) do names[#names + 1] = fnName end
    if #names == 0 then return "unresolved" end
    table.sort(names)

    local uniform = true
    for _, fnName in ipairs(names) do
        if shapes[fnName] ~= shapes[names[1]] then uniform = false break end
    end
    if uniform then return shapes[names[1]] end

    local parts = {}
    for _, fnName in ipairs(names) do
        parts[#parts + 1] = fnName .. "=" .. shapes[fnName]
    end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------ mission-start diagnostics
-- Before asking whether the counts come back right, confirm what is actually
-- being called. Each logs once per mission regardless of VERBOSE, gated only
-- by CONFIG.DIAGNOSTICS: when that is on, a quiet run explained nothing.

--- Log the running Lua dialect: _VERSION, and whether table.unpack and the
--- global unpack each exist, so the dialect fact lives in the log itself.
--- See UE4SS-NOTES.md section 1.
local function logDialect()
    diagLog("lua dialect: _VERSION=%s, table.unpack=%s, unpack=%s",
        tostring(_VERSION),
        tostring(type(table.unpack) == "function"),
        tostring(type(unpack) == "function"))
end

--- Log the resolved scoring manager's full name and class name, to confirm
--- this is calling on the object it is believed to be calling on.
local function logIdentity(mgr)
    local fullName = try(function() return mgr:GetFullName() end, nil)
        or "(GetFullName failed)"

    local className = try(function()
        local cls = mgr:GetClass()
        if not cls then return nil end
        return try(function() return cls:GetFullName() end, nil)
            or try(function() return cls:GetFName():ToString() end, nil)
    end, nil) or "(class name unavailable)"

    diagLog("scoring manager resolved to %s (class %s)", fullName, className)
end

--- Log whether GetSuspectCount is reachable by name on the object, without
--- calling it, and whether StaticFindObject resolves the UFunction by path.
--- Together they tell "does not exist" from "cannot be called this way".
local function logReachability(mgr)
    local ok, v = pcall(function() return mgr.GetSuspectCount end)
    if not ok then
        diagLog("indexing GetSuspectCount on the scoring manager raised: \"%s\"",
            truncate(v))
    else
        diagLog("indexing GetSuspectCount on the scoring manager yields %s (type %s)",
            (v == nil and "nil" or "a value"), type(v))
    end

    local ok2, found = pcall(function()
        return StaticFindObject("/Script/ReadyOrNot.ScoringManager:GetSuspectCount")
    end)
    if not ok2 then
        diagLog("StaticFindObject for GetSuspectCount raised: \"%s\"", truncate(found))
        return
    end
    if found == nil then
        diagLog("StaticFindObject for GetSuspectCount: not found")
        return
    end
    local valid = try(function() return found:IsValid() end, "unknown")
    diagLog("StaticFindObject for GetSuspectCount: found, IsValid=%s", tostring(valid))
end

--- Log which route readGroups actually took for this mission's score groups,
--- and what it found. It reports the outcome of the path that really runs: a
--- diagnostic describing an unused path points at code that is not the fault,
--- which is worse than having no diagnostic at all.
local function logGroupRouteSummary(groups)
    local n = groups and #groups or 0
    if n == 0 then
        diagLog("score groups: readGroups found 0 groups (route %s)",
            lastGroupRoute or "unresolved")
        return
    end
    diagLog("score groups read via %s route, %d group%s, first is %s",
        lastGroupRoute or "unresolved", n, n == 1 and "" or "s",
        groups[1].name or "(unnamed group)")
end

-- ------------------------------------------------------------------ reading

--- Resolve one TArray<FScoreGroup> element to whichever struct actually
--- carries readable fields: the raw element reads every field as nil but
--- carries a callable get(). Whether THAT is readable rather than another
--- opaque wrapper is settled by testing GroupName on it, falling back to the
--- element. See UE4SS-NOTES.md section 3.
-- Called every tick, so its one [diag] line is latched per mission.
local function resolveGroupElement(g)
    -- Gated on a callable get(), not on type(g) == "userdata": a build
    -- exposing the same pattern through a table is handled identically.
    local getFn = try(function() return g.get end, nil)
    if type(getFn) ~= "function" then
        lastGroupRoute = "direct"
        return g
    end

    local ok1, inner = pcall(function() return g:get() end)
    if not ok1 or inner == nil then
        lastGroupRoute = "direct"
        return g
    end

    local ok2, name = pcall(function() return inner.GroupName end)
    if ok2 and name ~= nil then
        lastGroupRoute = ":get()"
        return inner
    end

    lastGroupRoute = "direct"
    if not groupResolveLogged then
        groupResolveLogged = true
        local metaOk, meta = pcall(getmetatable, inner)
        local metaDesc
        if type(inner) ~= "userdata" then
            metaDesc = "n/a (not userdata)"
        elseif not metaOk then
            metaDesc = string.format('raises "%s"', truncate(meta))
        else
            metaDesc = meta ~= nil and "present" or "absent"
        end
        local nameDesc
        if not ok2 then
            nameDesc = string.format('raised "%s"', truncate(name))
        elseif name == nil then
            nameDesc = "nil"
        else
            nameDesc = "a " .. type(name)
        end
        diagLog("score group element's get() result: type=%s, "
          .. "metatable=%s, GroupName=%s", type(inner), metaDesc, nameDesc)
    end
    return g
end

local function readObjectives(mgr)
    local status = {}
    if mgr then
        status = callOut(mgr, "GetObjectiveCompletionStatus",
            { "ObjectivesComplete", "ObjectivesFailed", "TotalObjectives" })
    end

    local out = {
        complete = status.ObjectivesComplete,
        failed   = status.ObjectivesFailed,
        total    = status.TotalObjectives,
        list     = {},
    }
    if not gameState then return out end

    local list = try(function() return gameState.MissionObjectives end, nil)
    if not list then return out end

    local count = try(function() return #list end, 0)
    for i = 1, count do
        local obj = try(function() return list[i] end, nil)
        if obj and try(function() return obj:IsValid() end, false) then
            local name = try(function() return obj.ObjectiveName:ToString() end, nil)
            out.list[#out.list + 1] = {
                name   = name or "(unnamed objective)",
                status = try(function() return obj.ObjectiveStatus end, nil),
                hidden = try(function() return obj.bHiddenObjective end, false),
            }
        end
    end
    return out
end

local function readGroups(mgr)
    local groups = try(function() return mgr:GetScoreGroups() end, nil)
    if not groups then return {} end

    local out = {}
    local count = try(function() return #groups end, 0)
    for i = 1, count do
        local g = try(function() return groups[i] end, nil)
        if g then
            -- The raw array element reads every field as nil, so every read
            -- below goes through the resolved element rather than through g.
            local element = resolveGroupElement(g)

            -- Deliberately NOT GetScoreCountFromGroup: that mixes input
            -- params with out-params, which callOut does not handle. These
            -- two take the group's Scores array plus a bool and return a
            -- plain int32. Coerced because layout.lua compares them directly
            -- and they do not pass through extract.
            local scores = try(function() return element.Scores end, nil)
            local given, total
            if scores then
                given = num(try(function()
                    return mgr:GetGivenScoreCountFromArray(scores, true) end, nil),
                    "GetGivenScoreCountFromArray")
                total = num(try(function()
                    return mgr:GetTotalScoreCountFromArray(scores, true) end, nil),
                    "GetTotalScoreCountFromArray")
            end
            out[#out + 1] = {
                name     = try(function() return element.GroupName:ToString() end, nil)
                             or "(unnamed group)",
                given    = given,
                total    = total,
                -- ObjectiveLevel is an enum layout.lua indexes a lookup table
                -- by directly, so anything but a Lua number reads as "other"
                -- for every row. num() latches one line if it is not.
                level    = num(try(function() return element.ObjectiveLevel end, nil),
                    "ScoreGroup", "ObjectiveLevel"),
                required = try(function() return element.bRequiredToClearMission end, false),
            }
        end
    end
    return out
end

--- Returns a stats table shaped exactly as layout.build expects. Fields that
--- could not be read are nil, never 0, so a failed read is never displayed as
--- a real count of zero.
function M.read()
    if not resolve() then
        -- The client's one unconditional diagnostic, so it must not assert
        -- what it cannot check: a joining client that IS in a mission but has
        -- resolved neither actor yet reaches here too, and claiming "not in a
        -- mission" would get a valid co-op run thrown away as operator error.
        return { ok = false,
                 reason = "neither a ScoringManager nor a GameState is live "
                       .. "yet; outside a mission this is expected" }
    end
    local mgr = scoringManager

    -- Diagnostics, each latched once per mission. Wrapped in pcall on top of
    -- their own try() guards: a raise must never reach the poll loop. The
    -- latch is set before the call so a raise cannot become a retry storm.
    if not dialectLogged then
        dialectLogged = true
        pcall(logDialect)
    end
    -- mgr may legitimately be nil (game state only). Both dereference it, so
    -- skip rather than emit a misleading "(GetFullName failed)" line.
    if mgr then
        if not identityLogged then
            identityLogged = true
            pcall(logIdentity, mgr)
        end
        if not reachabilityLogged then
            reachabilityLogged = true
            pcall(logReachability, mgr)
        end
    end

    -- Every scoring-manager-dependent read is skipped outright when mgr is
    -- nil, leaving these fields nil rather than 0: a co-op client with no
    -- live ScoringManager must never present that as a genuine zero count.
    local s, c, e, r, groups = nil, nil, nil, nil, nil
    if mgr then
        s = callOut(mgr, "GetSuspectCount",
            { "OutReported", "OutArrested", "OutKilled", "OutTotal" })
        c = callOut(mgr, "GetCivilianCount",
            { "OutReported", "OutInjured", "OutKilled", "OutArrested", "OutTotal" })
        e = callOut(mgr, "GetEvidenceCount",
            { "EvidenceCollected", "TotalEvidence" })
        r = callOut(mgr, "GetReportCount",
            { "ReportedCount", "TotalReports" })
        groups = readGroups(mgr)
    end

    -- Reports the outcome of readGroups above, not an independent probe, so
    -- it must run after it. Gated on mgr like the two above: with no manager
    -- this would latch a false "0 groups" on a client whose score groups were
    -- never attempted, and stay latched past the manager's arrival.
    if mgr and not groupSummaryLogged then
        groupSummaryLogged = true
        pcall(logGroupRouteSummary, groups)
    end

    return {
        ok = true,
        suspects  = s and { reported = s.OutReported, arrested = s.OutArrested,
                            killed = s.OutKilled, total = s.OutTotal } or nil,
        civilians = c and { reported = c.OutReported, injured = c.OutInjured,
                            killed = c.OutKilled, arrested = c.OutArrested,
                            total = c.OutTotal } or nil,
        evidence  = e and { collected = e.EvidenceCollected,
                            total = e.TotalEvidence } or nil,
        reports   = r and { reported = r.ReportedCount,
                            total = r.TotalReports } or nil,
        groups    = groups,
        objectives = readObjectives(mgr),
    }
end

return M
