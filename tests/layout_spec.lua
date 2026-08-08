-- tests/layout_spec.lua
package.path = "Scripts/?.lua;tests/?.lua;" .. package.path
local H = require("harness")
local L = require("layout")

-- fmt renders a missing read as a dash, never as zero. A failed read and a
-- genuine zero must be distinguishable on screen.
H.eq("fmt number", L.fmt(5), "5")
H.eq("fmt zero", L.fmt(0), "0")
H.eq("fmt nil", L.fmt(nil), "-")

H.eq("ratio normal", L.ratio(3, 7), "3 / 7")
H.eq("ratio nil numerator", L.ratio(nil, 7), "- / 7")
H.eq("ratio nil denominator", L.ratio(3, nil), "3 / -")

-- clamp guards the arrested+killed composite. The header dump gives names,
-- not semantics, so if those outcomes turn out to overlap the numerator must
-- not exceed the total, and the overflow must be reported.
H.eq("clamp under", { L.clamp(5, 12) }, { 5, false })
H.eq("clamp exact", { L.clamp(12, 12) }, { 12, false })
H.eq("clamp over", { L.clamp(14, 12) }, { 12, true })
-- L.clamp(nil, 12) returns nil as its first value. A table literal with a
-- nil hole has an undefined length under #, so the two return values are
-- asserted separately rather than compared as a { ... } literal.
local clamp_nil_num_value, clamp_nil_num_over = L.clamp(nil, 12)
H.eq("clamp nil num value", clamp_nil_num_value, nil)
H.eq("clamp nil num flag", clamp_nil_num_over, false)
H.eq("clamp nil den", { L.clamp(5, nil) }, { 5, false })

-- Regression tests for a harness bug: serialise() used to discard type
-- information (plain tostring()), so H.eq treated type-distinct values such
-- as 5 and "5" as equal. layout.fmt/ratio must return strings and
-- layout.clamp must return a number plus a boolean, so a future regression
-- returning the wrong type has to be caught here, not pass silently.
-- These compare serialise() output directly with Lua's native == (which is
-- always type-aware) rather than routing the type-confused pair through
-- H.eq itself, since a self-referential H.eq(5, "5") would inherit the very
-- bug being tested for.
H.eq("harness distinguishes number from string", H.serialise(5) == H.serialise("5"), false)
H.eq("harness distinguishes boolean from string", H.serialise(false) == H.serialise("false"), false)
H.eq("harness distinguishes nested number from string", H.serialise({ 5 }) == H.serialise({ "5" }), false)

local FULL = {
    suspects  = { reported = 6, arrested = 5, killed = 3, total = 12 },
    civilians = { reported = 6, injured = 0, killed = 0, arrested = 6, total = 9 },
    evidence  = { collected = 4, total = 7 },
    reports   = { reported = 3, total = 5 },
}

-- The numerator is arrested + killed only. Reported is NOT added in: a killed
-- suspect can also be reported, so including it would double count.
local rows, rowsOverflowed = L.counterRows(FULL)
-- The non-overflow path asserts the flag too. Only the overflow case used to
-- check it, so a regression that returned true unconditionally would have
-- passed every test while making main.lua warn on every clean mission.
H.eq("no overflow flagged", rowsOverflowed, false)
H.eq("suspects row", rows[1],
    { kind = "counter", label = "SUSPECTS", value = "8 / 12",
      detail = "6 reported \194\183 5 arrested \194\183 3 killed" })
H.eq("civilians row", rows[2],
    { kind = "counter", label = "CIVILIANS", value = "6 / 9",
      detail = "6 reported \194\183 0 injured \194\183 0 killed \194\183 6 arrested" })
H.eq("evidence row", rows[3],
    { kind = "counter", label = "EVIDENCE", value = "4 / 7", detail = "" })
H.eq("reports row", rows[4],
    { kind = "counter", label = "REPORTS", value = "3 / 5", detail = "" })

-- A category the mission does not contain is omitted rather than shown as 0/0.
local noEvidence = {
    suspects  = { reported = 0, arrested = 0, killed = 0, total = 4 },
    civilians = { reported = 0, injured = 0, killed = 0, arrested = 0, total = 0 },
    evidence  = { collected = 0, total = 0 },
    reports   = { reported = 0, total = 0 },
}
local rows2 = L.counterRows(noEvidence)
H.eq("only suspects survive", #rows2, 1)
H.eq("suspects zeroed", rows2[1].value, "0 / 4")

-- A failed read shows dashes and never fabricates a zero.
local partial = {
    suspects  = { reported = nil, arrested = nil, killed = nil, total = nil },
    civilians = { reported = 1, injured = 0, killed = 0, arrested = 1, total = 3 },
    evidence  = nil,
    reports   = nil,
}
local rows3 = L.counterRows(partial)
H.eq("partial suspects value", rows3[1].value, "- / -")
H.eq("partial count", #rows3, 2)

-- Overflow is clamped and reported, so a wrong assumption about outcome
-- exclusivity surfaces in the log instead of silently showing 14/12.
local over = {
    suspects  = { reported = 0, arrested = 10, killed = 4, total = 12 },
    civilians = nil, evidence = nil, reports = nil,
}
local rows4, overflowed = L.counterRows(over)
H.eq("overflow clamped", rows4[1].value, "12 / 12")
H.eq("overflow flagged", overflowed, true)

local CFG = { SHOW_COUNTERS = true, SHOW_SCOREGROUPS = true,
              SHOW_OBJECTIVES = true, SHOW_HIDDEN = true }

local GROUPS = {
    { name = "Suspects Apprehended", given = 5, total = 8, level = 0, required = true },
    { name = "Evidence Secured",     given = 4, total = 7, level = 1, required = false },
    { name = "Bonus Thing",          given = 2, total = 2, level = 2, required = false },
}

local grows = L.groupRows(GROUPS)
-- Header counts groups that are fully complete, over the number of groups.
H.eq("group header", grows[1],
    { kind = "section", label = "SCORE GROUPS", value = "1 / 3", detail = "" })
H.eq("group entry primary", grows[2],
    { kind = "entry", label = "primary", value = "5 / 8", detail = "Suspects Apprehended" })
H.eq("group entry secondary", grows[3],
    { kind = "entry", label = "secondary", value = "4 / 7", detail = "Evidence Secured" })
H.eq("group entry tertiary", grows[4],
    { kind = "entry", label = "tertiary", value = "2 / 2", detail = "Bonus Thing" })
H.eq("no groups yields nothing", #L.groupRows({}), 0)

-- A group is counted complete on given >= total, not given == total, which
-- differs from the spec on purpose: the header dump gives names, not
-- semantics, so if the game ever awards more than the listed total a
-- finished group must still read as finished rather than flipping back to
-- incomplete. Pinned here so it stays a decision and not an accident.
local OVERSHOOT = {
    { name = "Overshot", given = 9, total = 8, level = 0, required = true },
    { name = "Exact",    given = 2, total = 2, level = 1, required = false },
}
H.eq("group past its total still counts as complete", L.groupRows(OVERSHOOT)[1].value, "2 / 2")

local OBJ = {
    complete = 2, failed = 1, total = 5,
    list = {
        { name = "Neutralize the threat",      status = 1, hidden = false },
        { name = "Rescue all civilians",       status = 0, hidden = false },
        { name = "Locate the missing officer", status = 2, hidden = false },
        { name = "Secret stash",               status = 0, hidden = true  },
    },
}

local orows = L.objectiveRows(OBJ, CFG)
H.eq("objective header", orows[1],
    { kind = "section", label = "OBJECTIVES", value = "2 / 5", detail = "1 failed" })
H.eq("objective complete", orows[2],
    { kind = "entry", label = "done", value = "", detail = "Neutralize the threat" })
H.eq("objective active", orows[3],
    { kind = "entry", label = "active", value = "", detail = "Rescue all civilians" })
H.eq("objective failed", orows[4],
    { kind = "entry", label = "failed", value = "", detail = "Locate the missing officer" })
H.eq("hidden shown when enabled", orows[5].detail, "Secret stash")

-- Failed count is only shown when non-zero, so a clean run is not cluttered.
local clean = { complete = 3, failed = 0, total = 3, list = {} }
H.eq("no failed suffix", L.objectiveRows(clean, CFG)[1].detail, "")

-- SHOW_HIDDEN off omits hidden objectives entirely.
local hideCfg = { SHOW_COUNTERS = true, SHOW_SCOREGROUPS = true,
                  SHOW_OBJECTIVES = true, SHOW_HIDDEN = false }
H.eq("hidden omitted", #L.objectiveRows(OBJ, hideCfg), 4)

-- A long name is never truncated; the panel auto-sizes instead.
local longName = { complete = 0, failed = 0, total = 1, list = {
    { name = string.rep("A", 120), status = 0, hidden = false } } }
H.eq("long name intact", #L.objectiveRows(longName, CFG)[2].detail, 120)

-- build stitches the sections together with a title and blank separators.
local all = L.build({
    suspects = { reported = 6, arrested = 5, killed = 3, total = 12 },
    civilians = nil, evidence = nil, reports = nil,
    groups = GROUPS, objectives = OBJ,
}, CFG)
H.eq("title first", all[1], { kind = "title", label = "MISSION OBJECTIVES", value = "", detail = "" })
H.eq("build row count", #all, 14)  -- title 1 + blank 1 + counter 1 + blank 1 + groups 4 + blank 1 + objectives 5

-- Sections are individually switchable.
local onlyCounters = L.build({
    suspects = { reported = 6, arrested = 5, killed = 3, total = 12 },
    groups = GROUPS, objectives = OBJ,
}, { SHOW_COUNTERS = true, SHOW_SCOREGROUPS = false,
     SHOW_OBJECTIVES = false, SHOW_HIDDEN = true })
H.eq("counters only", #onlyCounters, 3)  -- title, blank, one counter row

-- groupRows must handle nil given/total without throwing.
local GROUPS_WITH_NILS = {
    { name = "Normal", given = 5, total = 8, level = 0, required = true },
    { name = "Nil Given", given = nil, total = 5, level = 1, required = false },
    { name = "Nil Total", given = 3, total = nil, level = 2, required = false },
    { name = "Both Nil", given = nil, total = nil, level = 0, required = false },
}
local nilGroups = L.groupRows(GROUPS_WITH_NILS)
H.eq("nil groups does not throw", #nilGroups > 0, true)
-- Only groups with both given and total non-nil can be counted as complete.
-- This fixture has no complete groups (5 < 8, nil < anything, anything < nil).
-- The header should show "0 / 4", which differs from "1 / 4" if the nil guard broke.
H.eq("nil groups complete count", nilGroups[1].value, "0 / 4")

-- Empty sections enabled in config must not leave stray blank rows.
local noGroupsOrObjs = L.build({
    suspects = { reported = 6, arrested = 5, killed = 3, total = 12 },
    civilians = nil, evidence = nil, reports = nil,
    groups = nil, objectives = nil,
}, { SHOW_COUNTERS = true, SHOW_SCOREGROUPS = true,
     SHOW_OBJECTIVES = true, SHOW_HIDDEN = true })
H.eq("no stray blank with empty sections", #noGroupsOrObjs, 3)  -- title 1, blank 1, counter 1

-- Both row builders are called with whatever source.lua managed to read,
-- which is nil outright when the read failed. The nil guards existed but
-- nothing exercised them, so a regression removing either would have thrown
-- inside the poll loop with the whole suite still green.
H.eq("objectiveRows nil is empty", #L.objectiveRows(nil, CFG), 0)
H.eq("groupRows nil is empty", #L.groupRows(nil), 0)

-- build's second return value is the overflow flag main.lua warns on once
-- per mission. Nothing asserted it anywhere, so a regression dropping it
-- would have silently disabled that warning with every test still passing.
local _, buildOverflowed = L.build({
    suspects = { reported = 0, arrested = 10, killed = 4, total = 12 },
    civilians = nil, evidence = nil, reports = nil,
    groups = GROUPS, objectives = OBJ,
}, CFG)
H.eq("build propagates overflow", buildOverflowed, true)

local _, buildClean = L.build({
    suspects = { reported = 6, arrested = 5, killed = 3, total = 12 },
    civilians = nil, evidence = nil, reports = nil,
    groups = GROUPS, objectives = OBJ,
}, CFG)
H.eq("build reports no overflow when clean", buildClean, false)

-- With counters switched off there is no numerator to overflow, so the flag
-- must be false rather than left undefined.
local _, buildNoCounters = L.build({
    suspects = { reported = 0, arrested = 10, killed = 4, total = 12 },
    groups = GROUPS, objectives = OBJ,
}, { SHOW_COUNTERS = false, SHOW_SCOREGROUPS = true,
     SHOW_OBJECTIVES = true, SHOW_HIDDEN = true })
H.eq("build overflow false with counters off", buildNoCounters, false)

-- A co-op client that can reach the game state but not the scoring manager
-- produces exactly this shape. layout must render the objective list and
-- omit everything else, with no stray blank separators.
local CLIENT_PARTIAL = {
    ok = true,
    suspects = nil, civilians = nil, evidence = nil, reports = nil,
    groups = nil,
    objectives = {
        complete = nil, failed = nil, total = nil,
        list = {
            { name = "Bring Order to Chaos", status = 0, hidden = false },
            { name = "Rescue All of the Civilians", status = 0, hidden = false },
        },
    },
}

local partialRows = L.build(CLIENT_PARTIAL, CFG)
-- title, blank, objectives header, two entries
H.eq("partial: row count", #partialRows, 5)
H.eq("partial: title first", partialRows[1].kind, "title")
H.eq("partial: no counter rows", (function()
    for _, r in ipairs(partialRows) do
        if r.kind == "counter" then return true end
    end
    return false
end)(), false)
H.eq("partial: objectives header dashes", partialRows[3],
    { kind = "section", label = "OBJECTIVES", value = "- / -", detail = "" })
H.eq("partial: first objective", partialRows[4].detail, "Bring Order to Chaos")

-- The inverse: scoring readable, game state not. The objective list is empty
-- but the header counts still come from the scoring manager.
local NO_GAMESTATE = {
    ok = true,
    suspects = { reported = 0, arrested = 1, killed = 2, total = 9 },
    civilians = nil, evidence = nil, reports = nil, groups = nil,
    objectives = { complete = 1, failed = 0, total = 4, list = {} },
}
local noGsRows = L.build(NO_GAMESTATE, CFG)
-- title, blank, one counter, blank, objectives header
H.eq("no gamestate: row count", #noGsRows, 5)
H.eq("no gamestate: counter present", noGsRows[3].value, "3 / 9")
H.eq("no gamestate: objectives header", noGsRows[5].value, "1 / 4")

-- Nothing readable at all still yields just the title, never a stray blank.
local NOTHING = { ok = true, objectives = nil }
H.eq("nothing readable: row count", #L.build(NOTHING, CFG), 1)

H.report()
