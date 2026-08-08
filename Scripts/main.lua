-- MissionObjectiveCounter/Scripts/main.lua
-- Entry point: config, the game-thread scheduling tiers, the HUD attach
-- chain, the poll loop and the hotkey. Read-only; it mutates no game state.
-- Everything here that crosses into Unreal must run on the game thread.
-- See UE4SS-NOTES.md section 4.
--
-- UE4SS-NOTES.md and the section numbers referenced below are in this
-- repository: https://github.com/Nokama0/ReadyOrNot-MissionObjectiveCounter

-- Logged on load, so UE4SS.log names the build that is actually installed.
local VERSION = "1.1"

-- CONFIG.TOGGLE_KEY is an opaque UE4SS Key value with no reliable to-string,
-- so this is kept in sync with it by hand for log messages.
local TOGGLE_KEY_NAME = "F7"

local CONFIG = {
    TOGGLE_KEY       = Key.F7,     -- clear of F8 and of UE4SS's own dumpers
    MODIFIER_KEYS    = {},
    START_VISIBLE    = false,
    SCALE            = 1.0,        -- raise if it reads small at high DPI
    ANCHOR           = "TopRight", -- TopLeft | TopRight | BottomLeft | BottomRight
    MARGIN           = 24,
    POLL_MS          = 500,
    SHOW_COUNTERS    = true,
    SHOW_SCOREGROUPS = true,
    SHOW_OBJECTIVES  = true,
    SHOW_HIDDEN      = true,       -- reveal hidden objectives
    VERBOSE          = false,      -- quiet by default; this ships to others
    DIAGNOSTICS      = false,      -- extra one-time diagnostics in UE4SS.log,
                                    -- useful when something is not working
}

local HUD_CLASS =
    "/Game/Blueprints/Widgets/HUD/W_HumanCharacter_HUD_V2.W_HumanCharacter_HUD_V2_C"

-- NotifyOnNewObject takes the full object path above; FindAllOf and
-- FindFirstOf take this generated class short name.
local HUD_SHORT_NAME = "W_HumanCharacter_HUD_V2_C"

local layout = require("layout")
local source = require("source")
local panel  = require("panel")

-- All logging goes through UE4SS, so it lands in UE4SS.log with no path baked in.
local function formatMessage(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    return msg
end

local function log(fmt, ...)
    if not CONFIG.VERBOSE then return end
    print("[MissionObjectiveCounter] " .. formatMessage(fmt, ...) .. "\n")
end

local function warn(fmt, ...)
    print("[MissionObjectiveCounter] " .. formatMessage(fmt, ...) .. "\n")
end

local function try(fn, fallback)
    local ok, r = pcall(fn)
    if ok and r ~= nil then return r end
    return fallback
end

-- Unconditional warnings latched by call site, so a fault that recurs every
-- poll produces one line, not one per poll. Cleared wholesale in attachTo.
local latched = {}
local function latchedWarn(key, fmt, ...)
    if latched[key] then return end
    latched[key] = true
    -- Every caller is a scheduler or keybind callback, so a raise here would
    -- unwind straight back into UE4SS.
    pcall(warn, fmt, ...)
end

-- ------------------------------------------------------------- game thread
-- ExecuteWithDelay does NOT marshal onto the game thread; the
-- ExecuteInGameThread family does. Reading UObjects or mutating UMG off the
-- game thread crashes the game intermittently. The tiers below are probed,
-- never assumed, and tier 3 refuses to poll rather than fall back to raw
-- ExecuteWithDelay, the configuration that crashed. See UE4SS-NOTES.md 4.
local HAS_GAME_THREAD_DELAY = type(ExecuteInGameThreadWithDelay) == "function"
local HAS_GAME_THREAD       = type(ExecuteInGameThread) == "function"
local HAS_DELAY             = type(ExecuteWithDelay) == "function"
local HAS_IS_IN_GAME_THREAD = type(IsInGameThread) == "function"

--- Which tier this build supports: "delayed", "composed" or "none". Resolved
--- at load, since UE4SS does not gain or lose exports mid-session.
local SCHEDULER_TIER =
    (HAS_GAME_THREAD_DELAY and "delayed")
    or (HAS_DELAY and HAS_GAME_THREAD and "composed")
    or "none"

--- Schedule fn to run on the game thread in delayMs milliseconds.
-- Returns true when the work reached something that will run it there. Tier 3
-- returns false without scheduling, which callers must treat as "stop".
local function scheduleOnGameThread(delayMs, fn)
    if SCHEDULER_TIER == "delayed" then
        return (pcall(ExecuteInGameThreadWithDelay, delayMs, fn))
    end
    if SCHEDULER_TIER == "composed" then
        return (pcall(ExecuteWithDelay, delayMs, function()
            -- Runs on UE4SS's own thread and touches nothing in Unreal; it
            -- only hands fn on. A failure here is past where the caller could
            -- be told, so it is latched and the work dropped, never run.
            if not pcall(ExecuteInGameThread, fn) then
                latchedWarn("composedMarshal",
                    "the delay fired but the work could not be handed to "
                 .. "ExecuteInGameThread; it was dropped rather than run off "
                 .. "the game thread")
            end
        end))
    end
    return false
end

--- Whether this call is provably running on the game thread right now. A
--- build that cannot answer reports false, so the caller marshals anyway.
local function onGameThreadNow()
    if not HAS_IS_IN_GAME_THREAD then return false end
    return try(function() return IsInGameThread() end, false) == true
end

--- Run fn on the game thread: inline when provably on it already, and on the
--- next scheduled slot otherwise. Never raises, because its callers are UE4SS
--- callbacks. One rung wider than scheduleOnGameThread since no delay is
--- needed, so a bare ExecuteInGameThread can still marshal a one-shot.
-- Failures are latched, not swallowed: silence leaves no symptom at all.
local function runOnGameThread(fn)
    local function guarded()
        local ok, err = pcall(fn)
        if not ok then
            latchedWarn("marshalled",
                "a callback marshalled onto the game thread failed: %s",
                tostring(err))
        end
    end

    if onGameThreadNow() then
        guarded()
        return true
    end
    if HAS_GAME_THREAD_DELAY then
        return (pcall(ExecuteInGameThreadWithDelay, 0, guarded))
    end
    if HAS_GAME_THREAD then
        return (pcall(ExecuteInGameThread, guarded))
    end
    return false
end

-- Per-entry-point latches for the thread assertions below, cleared in
-- attachTo so each mission states the answer once per entry point.
local threadReported = {}

--- State, once per mission per entry point and unconditionally, whether it is
--- on the game thread. A fix resting on belief would be no better than none.
local function reportThread(entryPoint)
    if threadReported[entryPoint] then return end
    threadReported[entryPoint] = true

    if not HAS_IS_IN_GAME_THREAD then
        warn("%s: this UE4SS build does not provide IsInGameThread, so which "
          .. "thread it runs on cannot be stated", entryPoint)
        return
    end

    local inGame = try(function() return IsInGameThread() end, nil)
    if inGame == nil then
        warn("%s: IsInGameThread could not be read", entryPoint)
    elseif inGame then
        warn("%s is running on the game thread", entryPoint)
    else
        warn("%s is NOT running on the game thread; that is the condition "
          .. "that crashed the game during development and it should be "
          .. "reported", entryPoint)
    end
end

-- source.lua's read path has no latch of its own and runs once per tick, so
-- warn() is wired in behind a dedup on the formatted message.
local sourceMessagesSeen = {}
local function sourceLog(fmt, ...)
    local msg = formatMessage(fmt, ...)
    if sourceMessagesSeen[msg] then return end
    sourceMessagesSeen[msg] = true
    warn("%s", msg)
end

source.setLogger(sourceLog)
source.setDiagnostics(CONFIG.DIAGNOSTICS)
panel.setLogger(warn)

local active = nil            -- current panel handle
local visible = CONFIG.START_VISIBLE
local polling = false
local warnedOverflow = false
local warnedRead = false
local warnedNoPanel = false   -- latch: the hotkey pressed with nothing attached
local firstPressLogged = false -- latch: log the mission's first hotkey press once
local warnedToggleSchedule = false -- latch: the hotkey could not be marshalled
local shapeLogged = false     -- latch: log source.callShape() once per mission
local readFailures = 0        -- consecutive failed reads, drives the backoff

-- The newest poll loop's generation. A tick carries the one it was scheduled
-- under and returns the instant a newer exists. `polling` is a claim, not a
-- proof: a dropped tick would leave it true with nothing pending. Bumping
-- this first is what makes clearing the claim safe.
local pollSeq = 0

local MAX_POLL_MS = 5000

--- One poll's worth of work. Split out from tick so the whole of it can be
--- wrapped in a single pcall without also swallowing the reschedule.
local function pollOnce()
    local stats = source.read()
    if stats.ok then
        readFailures = 0
        warnedRead = false
        -- One unconditional line per mission naming which out-param binding
        -- shape worked. Latched on a RESOLVED shape, not the first successful
        -- read: a joining client's first polls succeed with no callOut behind
        -- them and would latch a false "unresolved".
        if not shapeLogged then
            local shape = source.callShape()
            if shape ~= "unresolved" then
                shapeLogged = true
                warn("out-param call shape resolved: %s", shape)
            end
        end
        local rows, overflowed = layout.build(stats, CONFIG)
        if overflowed and not warnedOverflow then
            warnedOverflow = true
            warn("a category numerator exceeded its total and was clamped; "
              .. "arrested and killed may not be exclusive outcomes")
        end
        active:setRows(rows)
        active:setVisible(true)
    else
        -- Unconditional: inside a mission this is the line that explains an
        -- empty panel on a client. warnedRead latches it to once per mission.
        readFailures = readFailures + 1
        active:setVisible(false)
        if not warnedRead then
            warnedRead = true
            warn("panel hidden: %s", stats.reason or "unknown")
        end
    end
end

-- The loop runs only while the panel is visible, so toggled off it costs
-- nothing during normal play.
local function tick(seq)
    -- Superseded, so stop without touching `polling`: that flag now belongs
    -- to the loop which retired this one, and clearing it would allow a third.
    if seq ~= pollSeq then return end

    -- Before the guard below, which itself reads into Unreal. Guarded because
    -- this runs from a scheduler callback and a raise would strand the loop.
    pcall(reportThread, "the poll loop")

    if not visible or not active or not active:isValid() then
        polling = false
        return
    end

    -- The reschedule below is unconditional and everything above it that can
    -- raise is wrapped: together they keep the loop alive.
    local ok, err = pcall(pollOnce)
    if not ok then
        readFailures = readFailures + 1
        -- Guarded for the same reason pollOnce is: a raise here would land
        -- between the guarded poll and the reschedule and strand the loop.
        pcall(sourceLog, "poll failed: %s", tostring(err))
    end

    -- With no live ScoringManager every tick repeats FindFirstOf, and
    -- visibility persists across missions so the ready room can sit here for
    -- a long time. Repeated object traversal destabilises the game, so back
    -- off until a read succeeds.
    local delay = math.min(CONFIG.POLL_MS * math.max(readFailures, 1), MAX_POLL_MS)

    -- Clearing `polling` on failure lets the next attach or hotkey press start
    -- a fresh loop; leaving it set blocks startPolling for the session. Which
    -- scheduler this is decides the thread the whole loop runs on.
    if SCHEDULER_TIER == "none" then
        -- No delayed game-thread route on this build, so no repeating poll.
        -- Nothing is logged here: the load-time line states the mode once.
        polling = false
        return
    end

    if not scheduleOnGameThread(delay, function() tick(seq) end) then
        polling = false
        -- Otherwise the panel freezes on stale numbers as though they were
        -- live, with nothing in the log to say so.
        latchedWarn("pollSchedule",
            "could not schedule the next poll onto the game thread; the panel "
         .. "is frozen on the numbers it last read until it is toggled off and "
         .. "on again, or a new mission attaches a fresh panel")
    end
end

local function startPolling()
    if polling then return end
    polling = true
    pollSeq = pollSeq + 1
    tick(pollSeq)
end

--- The half of a hotkey press that touches Unreal, split out of toggle so
--- toggle itself can be pure Lua state and this can be marshalled. `wanted`
--- is captured at press time, so a press always applies its own outcome.
local function applyToggle(wanted)
    reportThread("the hotkey path")

    if not active or not active:isValid() then
        -- Unconditional: the only line the "this HUD widget class is
        -- different here" case can produce, since nothing else fires with no
        -- panel attached.
        if not warnedNoPanel then
            warnedNoPanel = true
            -- This line already says what the first-press line below would,
            -- so latch that too rather than print two overlapping lines.
            firstPressLogged = true
            warn("toggled %s but no panel is attached yet; if you are in a "
              .. "mission, the HUD widget this mod attaches to was never "
              .. "constructed here", wanted and "on" or "off")
        end
        return
    end

    if not firstPressLogged then
        firstPressLogged = true
        -- Unconditional, first press of the mission only: this times the gap
        -- from "character HUD constructed" to someone checking the panel.
        warn("first hotkey press this mission turned the panel %s; a panel "
          .. "is attached", wanted and "on" or "off")
    else
        log("toggled %s", wanted and "on" or "off")
    end

    if wanted then
        startPolling()
    else
        active:setVisible(false)
    end
end

--- The callback UE4SS invokes on the hotkey.
-- It flips one Lua boolean and schedules, reading and writing nothing in
-- Unreal, so it is correct whichever thread UE4SS delivers keybinds on:
-- RegisterKeyBindAsync exists separately, which says the two differ in
-- threading without saying which way round, so this makes it not matter.
local function toggle()
    visible = not visible
    local wanted = visible
    if runOnGameThread(function() applyToggle(wanted) end) then return end

    -- Marshalling is the only route from a press to a widget, so a scheduling
    -- failure means the press did nothing. pcall'd: this is a UE4SS callback.
    if not warnedToggleSchedule then
        warnedToggleSchedule = true
        pcall(warn, "could not schedule the panel toggle onto the game thread; "
          .. "this hotkey press had no effect")
    end
end

-- Cheap enough to cost nothing and patient enough to outlast a slow level
-- load. See UE4SS-NOTES.md section 5 for why an attach has to retry at all.
local ATTACH_RETRY_MS = 250
local ATTACH_RETRY_FOR_MS = 15000

-- The newest attach chain's number. A chain stops the moment a later attachTo
-- takes over, so two chains can never retry at once.
local attachSeq = 0
-- The HUD the newest chain is retrying for, nil when none is pending, so a
-- duplicate attach for a HUD already being worked on is ignored.
local pendingHud = nil
-- fullNameOf(pendingHud), kept in step with it at every assigning site. See
-- attachTo's identity comparison for why a name is tracked alongside.
local pendingHudName = nil

-- What fullNameOf returns when a name cannot be read. attachTo's identity
-- comparison must never treat two unnamed objects as the same object.
local UNKNOWN_OBJECT_NAME = "an object whose name could not be read"

--- The object's full name, or a placeholder. Never raises, always a string.
local function fullNameOf(obj)
    local name = try(function() return obj:GetFullName() end, nil)
    if type(name) == "string" then return name end
    return UNKNOWN_OBJECT_NAME
end

--- Whether this is a live instance rather than a class default object. CDOs
--- carry the properties but no live state, and have no widget tree.
local function isLive(obj)
    if not obj then return false end
    if not try(function() return obj:IsValid() end, false) then return false end
    return not fullNameOf(obj):find("Default__", 1, true)
end

--- Point the mod at a HUD, from either of the two paths that can find one. A
--- HUD not attached to before means a new level, so caches and latches are
--- stale. The attach is retried rather than attempted once: named children
--- such as CanvasPanel_Root are bound after the object exists, so one nil
--- read is not proof the HUD is unsuitable. See UE4SS-NOTES.md section 5.
local function attachTo(hud)
    if not isLive(hud) then
        warn("not attaching to %s: it is not a live HUD instance (an invalid "
          .. "object, or the class default object that NotifyOnNewObject can "
          .. "hand back)", fullNameOf(hud))
        return
    end

    -- A stable identity independent of Lua userdata identity: GetFullName
    -- reads the UObject's own name, equal across two calls about one HUD.
    local hudName = fullNameOf(hud)
    local hudNameUsable = hudName ~= UNKNOWN_OBJECT_NAME

    -- `==` is a fast path for builds whose UObject userdata has a working
    -- equality metamethod. The hudName comparison alongside it is what
    -- guarantees a repeat attach is recognised on builds that do not.
    if active and try(function() return active:isValid() end, false)
        and (active.hud == hud
            or (hudNameUsable and active.hudName == hudName)) then
        log("already attached to this HUD, ignoring the second attach path")
        return
    end
    -- The name match alone is not enough: Unreal reuses object name suffixes
    -- per outer, so a new mission's HUD can share a GetFullName() with one
    -- still pending, and the liveness check stops that dropping its attach.
    if pendingHud == hud
        or (hudNameUsable and pendingHudName == hudName
            and try(function() return pendingHud:IsValid() end, false)) then
        log("an attach to this HUD is already being retried, ignoring the "
          .. "second attach path")
        return
    end

    -- The closest thing to "the mission started" this mod can observe, and
    -- printed before attachment is attempted, so it survives a chain that
    -- gives up.
    warn("character HUD constructed")

    source.reset()
    warnedOverflow, warnedRead, shapeLogged = false, false, false
    -- Cleared here rather than on a successful attach, so a mission still
    -- retrying can report a hotkey press that found nothing.
    warnedNoPanel = false
    firstPressLogged = false
    warnedToggleSchedule = false
    readFailures = 0
    sourceMessagesSeen = {}
    threadReported = {}
    latched = {}

    -- After the clear above, not at the top of attachTo: that clear resets
    -- this entry point's own latch and would wipe the line just written.
    reportThread("the attach path")

    -- The previous panel belonged to the previous HUD. Dropping it here also
    -- stops the poll loop by its own guard until this chain attaches.
    active = nil

    -- Reclaim the poll loop whatever state the last one was left in. Bumping
    -- the generation first is what makes clearing the claim safe.
    pollSeq = pollSeq + 1
    polling = false

    attachSeq = attachSeq + 1
    pendingHud = hud
    pendingHudName = hudName
    local seq = attachSeq
    local attempts, elapsed, lastReason = 0, 0, "unknown"

    -- Runs at 0 ms, then every ATTACH_RETRY_MS. Everything that crosses into
    -- Unreal, or that formats and prints, is wrapped: this is called back from
    -- a scheduler. It builds a UMG subtree, so every retry is on the game thread.
    local function step()
        if seq ~= attachSeq then return end     -- superseded, silently
        if not try(function() return hud:IsValid() end, false) then
            pendingHud = nil
            pendingHudName = nil
            log("the HUD went invalid, stopping the attach retries")
            return
        end

        attempts = attempts + 1
        local ok, handle, reason = pcall(panel.attach, hud, CONFIG)
        if not ok then
            handle, reason = nil, "panel.attach raised: " .. tostring(handle)
        end

        if handle then
            pendingHud = nil
            pendingHudName = nil
            active = handle
            -- Cached so the identity check above needs no re-read per call.
            active.hudName = hudName
            -- Unconditional, and only when it took more than one go: this is
            -- the line that proves the widget tree arrives after the object.
            if attempts > 1 then
                pcall(warn, "panel attached on attempt %d, about %d ms after "
                  .. "the HUD was first seen", attempts, elapsed)
            end
            if visible then startPolling() end
            return
        end

        lastReason = reason or "unknown"
        elapsed = elapsed + ATTACH_RETRY_MS
        if elapsed < ATTACH_RETRY_FOR_MS then
            -- Nothing is logged per attempt. Sixty lines saying the same
            -- thing would bury the one line that says which attempt worked.
            if scheduleOnGameThread(ATTACH_RETRY_MS, step) then return end
            pendingHud = nil
            pendingHudName = nil
            pcall(warn, "gave up attaching after %d attempt(s) over about "
              .. "%d ms because the next retry could not be scheduled; last "
              .. "reason: %s", attempts, elapsed - ATTACH_RETRY_MS, lastReason)
            return
        end

        pendingHud = nil
        pendingHudName = nil
        pcall(warn, "gave up attaching after %d attempts over about %d ms; "
          .. "last reason: %s", attempts, elapsed, lastReason)
    end

    step()
end

-- UObject construction happens on the game thread, so this notification most
-- likely already arrives there. "Most likely" is not a basis for building a
-- UMG subtree, so it marshals; runOnGameThread runs inline when it can prove it.
local ok, err = pcall(function()
    NotifyOnNewObject(HUD_CLASS, function(hud)
        runOnGameThread(function() attachTo(hud) end)
    end)
end)

if ok then
    log("watching for %s", HUD_CLASS)
else
    warn("NotifyOnNewObject failed: %s", tostring(err))
end

--- A HUD instance that already exists, or nil.
-- FindAllOf is preferred because FindFirstOf can hand back the CDO and then
-- there is no second candidate; FindFirstOf stays as a fallback. Neither
-- walks the whole object array: ForEachUObject destabilises the game.
local function findLiveHud()
    local all = try(function() return FindAllOf(HUD_SHORT_NAME) end, nil)
    if all then
        local count = try(function() return #all end, 0)
        for i = 1, count do
            local hud = try(function() return all[i] end, nil)
            if isLive(hud) then return hud end
        end
    end

    local first = try(function() return FindFirstOf(HUD_SHORT_NAME) end, nil)
    if isLive(first) then return first end
    return nil
end

-- NotifyOnNewObject fires on construction only, so it cannot see a HUD that
-- already exists: the normal state after a hot reload. Marshalled because mod
-- load runs on UE4SS's own thread while findLiveHud reads live UObjects. A
-- failure just leaves the notification above as the fallback.
local lookupScheduled = runOnGameThread(function()
    local liveOk, liveErr = pcall(function()
        local hud = findLiveHud()
        if not hud then return end
        log("found an already-constructed %s, attaching to it", HUD_SHORT_NAME)
        attachTo(hud)
    end)
    if not liveOk then
        warn("could not look for an existing HUD: %s; waiting for the next one "
          .. "to be constructed instead", tostring(liveErr))
    end
end)
if not lookupScheduled then
    warn("could not schedule the existing-HUD lookup onto the game thread; "
      .. "waiting for the next HUD to be constructed instead")
end

-- The three-argument RegisterKeyBind with an empty modifier table is not
-- known to work in UE4SS; the two-argument form is. A failed registration is
-- logged unconditionally: a dead hotkey looks exactly like a dead mod.
local hasModifiers = CONFIG.MODIFIER_KEYS and #CONFIG.MODIFIER_KEYS > 0

--- Whether this key is already bound, from a previous run of this file.
-- Hot reload re-runs main.lua in the same process, so an unconditional
-- RegisterKeyBind leaves two handlers on one key: both fire on one press, the
-- panel toggles twice, and the key reads as dead. IsKeyBindRegistered is
-- probed, not assumed.
local function alreadyBound()
    if type(IsKeyBindRegistered) ~= "function" then return false end
    return try(function()
        if hasModifiers then
            return IsKeyBindRegistered(CONFIG.TOGGLE_KEY, CONFIG.MODIFIER_KEYS)
        end
        return IsKeyBindRegistered(CONFIG.TOGGLE_KEY)
    end, false) == true
end

local bindSkipped = alreadyBound()
local bindOk, bindErr = true, nil
if not bindSkipped then
    bindOk, bindErr = pcall(function()
        if hasModifiers then
            RegisterKeyBind(CONFIG.TOGGLE_KEY, CONFIG.MODIFIER_KEYS, toggle)
        else
            RegisterKeyBind(CONFIG.TOGGLE_KEY, toggle)
        end
    end)
end

-- Whether RegisterKeyBind reports failure by raising or by silently doing
-- nothing is not established. The pcall covers the first; this unconditional
-- line covers the second, so "failed" and "succeeded but never fires" are two
-- different lines. The skipped case is expected on a hot reload, not a fault.
if bindSkipped then
    warn("v%s loaded; %s was already bound, most likely by this mod before a "
      .. "hot reload, so it was left alone", VERSION, TOGGLE_KEY_NAME)
elseif bindOk then
    warn("v%s loaded; RegisterKeyBind for %s returned without error",
        VERSION, TOGGLE_KEY_NAME)
else
    warn("v%s loaded; RegisterKeyBind for %s failed: %s",
        VERSION, TOGGLE_KEY_NAME, tostring(bindErr))
end

-- Which threading tier this run is in, stated once on every build. A silent
-- tier 3 is indistinguishable in a log from a mod that never worked.
if SCHEDULER_TIER == "delayed" then
    warn("game reads and widget updates are scheduled with "
      .. "ExecuteInGameThreadWithDelay, so they run on the game thread")
elseif SCHEDULER_TIER == "composed" then
    warn("this UE4SS build does not provide ExecuteInGameThreadWithDelay, so "
      .. "game reads and widget updates take their delay through "
      .. "ExecuteWithDelay and are then handed to ExecuteInGameThread; they "
      .. "still run on the game thread")
else
    warn("this UE4SS build provides no way to run delayed work on the game "
      .. "thread, so the mod cannot guarantee game-thread execution on it. "
      .. "The panel's repeating updates are disabled rather than run the way "
      .. "that crashed a co-op client during development; the panel may still "
      .. "attach and show a single reading. Updating UE4SS is the fix")
end
