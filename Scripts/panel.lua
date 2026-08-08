-- MissionObjectiveCounter/Scripts/panel.lua
-- Builds a UMG subtree and injects it into the live HUD's UOverlay.
-- Resolution independence comes from slot alignment, content auto-sizing,
-- Slate-unit column widths and a ScaleBox, and from there being no pixel
-- coordinate anywhere in the file. See UE4SS-NOTES.md section 6.
--
-- UE4SS-NOTES.md and the section numbers referenced below are in this
-- repository: https://github.com/Nokama0/ReadyOrNot-MissionObjectiveCounter
local M = {}

local log = function() end
function M.setLogger(fn) log = fn end

local function try(fn, fallback)
    local ok, r = pcall(fn)
    if ok and r ~= nil then return r end
    return fallback
end

-- UMG enum values as declared in the engine's own headers, written out as
-- plain integers because that is what the Lua side hands back to the engine.
-- See UE4SS-NOTES.md section 9.
local VIS_HITTEST_INVISIBLE, VIS_COLLAPSED = 3, 1
local HALIGN = { Fill = 0, Left = 1, Center = 2, Right = 3 }
local VALIGN = { Fill = 0, Top = 1, Center = 2, Bottom = 3 }
local STRETCH_USER_SPECIFIED = 7

local ANCHORS = {
    TopLeft     = { h = HALIGN.Left,  v = VALIGN.Top },
    TopRight    = { h = HALIGN.Right, v = VALIGN.Top },
    BottomLeft  = { h = HALIGN.Left,  v = VALIGN.Bottom },
    BottomRight = { h = HALIGN.Right, v = VALIGN.Bottom },
}

local LABEL_W, VALUE_W = 150.0, 90.0

-- Only successful lookups are cached. Caching a miss would turn one transient
-- StaticFindObject failure into a permanently dead panel for the session.
local classCache = {}
local function classOf(path)
    local cached = classCache[path]
    if cached then return cached end
    local found = try(function() return StaticFindObject(path) end, nil)
    if found then classCache[path] = found end
    return found
end

-- Every widget this mod constructs carries this prefix, which is what makes a
-- panel left by a previous script instance identifiable. See removeStalePanels.
local NAME_PREFIX = "MOC_"

-- Widget names must be unique within their outer, and a hot reload starts a
-- fresh Lua state while the previous instance's MOC_ widgets are still alive:
-- asking StaticConstructObject for a name still taken makes the engine
-- replace that object in place. See UE4SS-NOTES.md section 7.
local counter = 0
pcall(function()
    local addr = tonumber(tostring({}):match("(%x+)%s*$"), 16) or 0
    counter = (addr + math.floor(os.clock() * 1000)) % 1000000
end)

-- Every string handed to FName is interned by UE4SS. Builds before 2026-06-14
-- keyed that pool on a string_view into the caller's buffer, so a collected
-- Lua string left a dangling key. A permanent reference outlives the entry.
local pinnedNames = {}

--- Construct a UMG widget. Only `named` ones carry the MOC_ prefix
--- removeStalePanels matches, and only the outermost widget needs it.
local function construct(shortName, outer, named)
    local cls = classOf("/Script/UMG." .. shortName)
    if not cls then return nil end
    if not named then
        return try(function() return StaticConstructObject(cls, outer) end, nil)
    end
    counter = counter + 1
    local name = NAME_PREFIX .. shortName .. counter
    pinnedNames[#pinnedNames + 1] = name
    return try(function()
        return StaticConstructObject(cls, outer, FName(name))
    end, nil)
end

local function make(shortName, outer)
    return construct(shortName, outer, false)
end

local function makeNamed(shortName, outer)
    return construct(shortName, outer, true)
end

--- Write text to a widget. Returns whether the write actually landed.
local function setText(widget, s)
    return (pcall(function() widget:SetText(FText(s or "")) end))
end

--- Push text only when it changed; most polls repeat what is already on
--- screen. Cached only after a successful write, since recording a failed one
--- would freeze that cell for the life of the panel. Returns whether it wrote.
local function setTextIfChanged(row, key, widget, s)
    s = s or ""
    if row[key] == s then return false end
    if not setText(widget, s) then return false end
    row[key] = s
    return true
end

-- Status colour is an enhancement on top of the text prefix layout.lua
-- already writes into entry rows, so it is never load-bearing.
-- Latent coupling: layout.groupRows emits kind = "entry" too, so score-group
-- rows reach this lookup and stay uncoloured only because their labels are
-- "primary"/"secondary"/"tertiary". Renaming one to "done" or "failed" would
-- silently colour score groups as objective statuses.
local STATUS_COLOR = {
    done   = { 0.35, 0.85, 0.35, 1.0 },
    failed = { 0.90, 0.30, 0.30, 1.0 },
}

-- SetColorAndOpacity takes an FSlateColor, not a bare FLinearColor, and which
-- Lua table shape the binding accepts for that nested struct is unknown, so
-- probe each in order and cache the winner. See UE4SS-NOTES.md section 6.
local COLOR_SHAPES = {
    function(widget, rgba)
        widget:SetColorAndOpacity({
            SpecifiedColor = FLinearColor(rgba[1], rgba[2], rgba[3], rgba[4]),
            ColorUseRule   = 0,
        })
    end,
    function(widget, rgba)
        widget:SetColorAndOpacity({
            SpecifiedColor = { R = rgba[1], G = rgba[2], B = rgba[3], A = rgba[4] },
            ColorUseRule   = 0,
        })
    end,
}

local function applyStatusColor(handle, widget, label)
    if handle.colorDisabled then return end
    local rgba = STATUS_COLOR[label]
    if not rgba then return end

    if handle.colorShape then
        local ok = pcall(COLOR_SHAPES[handle.colorShape], widget, rgba)
        if not ok then
            handle.colorDisabled = true
            log("could not set row status colour, disabling colour for this panel")
        end
        return
    end

    for i, shape in ipairs(COLOR_SHAPES) do
        if pcall(shape, widget, rgba) then
            handle.colorShape = i
            log("row status colour uses shape " .. i .. ", caching it for this panel")
            return
        end
    end

    handle.colorDisabled = true
    log("could not set row status colour with any known shape, disabling colour for this panel")
end

-- UBorder ships with an opaque brush tinted white, so an unstyled Border
-- renders as a solid rectangle over the HUD. The FLinearColor table shape is
-- probed like the row colour above. Padding is in Slate units, not pixels.
local BORDER_RGBA = { 0.0, 0.0, 0.0, 0.55 }
local BORDER_PADDING = { Left = 12, Top = 8, Right = 12, Bottom = 8 }

local function styleBorder(border)
    local ok = pcall(function()
        border:SetBrushColor({ R = BORDER_RGBA[1], G = BORDER_RGBA[2],
                               B = BORDER_RGBA[3], A = BORDER_RGBA[4] })
    end)
    if not ok then
        ok = pcall(function()
            border:SetBrushColor(FLinearColor(BORDER_RGBA[1], BORDER_RGBA[2],
                                              BORDER_RGBA[3], BORDER_RGBA[4]))
        end)
    end
    if not ok then
        log("could not set the panel background colour with any known shape; "
          .. "it may render as an opaque block")
    end
    if not pcall(function() border:SetPadding(BORDER_PADDING) end) then
        log("could not set the panel padding")
    end
end

-- Copy the font from a text block already in the HUD so the panel inherits the
-- game's typeface instead of shipping one. Falls back to the engine default.
local function inheritFont(dst, hud)
    pcall(function()
        local donor = hud.CommandTriggerKey_Text
        if donor and donor:IsValid() then dst.Font = donor.Font end
    end)
end

local function newText(outer, hud)
    local t = make("TextBlock", outer)
    if not t then return nil end
    inheritFont(t, hud)
    return t
end

-- USizeBox gates WidthOverride behind bOverride_WidthOverride, so assigning
-- the raw float alone silently leaves the column auto-sized. SetWidthOverride
-- is the real call; the raw writes are a fallback if it is not surfaced.
local function sized(outer, width, child)
    local box = make("SizeBox", outer)
    if not box then return child end
    pcall(function() box:SetWidthOverride(width) end)
    pcall(function()
        box.WidthOverride = width
        box.bOverride_WidthOverride = true
    end)
    pcall(function() box:AddChild(child) end)
    return box
end

-- Rows whose text belongs in the first column and would be cut off by it. The
-- label column is sized for "CIVILIANS", not "MISSION OBJECTIVES", so these
-- kinds render as one spanning text block instead of three columns.
local SPAN_KINDS = { title = true, section = true }

--- Text for a spanning row: the label, plus value and detail when they carry
--- anything, so a heading reads as one line instead of three clipped columns.
local function spanText(data)
    local parts = { data.label or "" }
    if data.value and data.value ~= "" then parts[#parts + 1] = data.value end
    if data.detail and data.detail ~= "" then parts[#parts + 1] = data.detail end
    return table.concat(parts, "  ")
end

--- One display row. Spanning kinds get a single text block; everything else
--- gets three columns in a horizontal box.
local function buildRow(outer, hud, kind)
    if SPAN_KINDS[kind] then
        local t = newText(outer, hud)
        if not t then return nil end
        return { widget = t, span = t }
    end

    local hbox = make("HorizontalBox", outer)
    if not hbox then return nil end
    local label, value, detail =
        newText(outer, hud), newText(outer, hud), newText(outer, hud)
    if not (label and value and detail) then return nil end

    pcall(function() hbox:AddChildToHorizontalBox(sized(outer, LABEL_W, label)) end)
    pcall(function() hbox:AddChildToHorizontalBox(sized(outer, VALUE_W, value)) end)
    pcall(function() hbox:AddChildToHorizontalBox(detail) end)

    return { widget = hbox, label = label, value = value, detail = detail }
end

--- The structural signature of a row list: two lists with the same signature
--- can share widgets. Count alone is not enough, since a row's widget
--- structure depends on its kind.
local function shapeOf(rows)
    local parts = {}
    for i, r in ipairs(rows) do parts[i] = r.kind or "" end
    return table.concat(parts, ",")
end

--- Remove any panel a previous script instance left in the overlay. Hot
--- reload starts a new Lua state and does not touch the widget tree, so
--- without this every reload stacks another panel on the last. Only
--- MOC_-prefixed widgets are touched, so an unrelated HUD child is safe.
--- Matches are collected before removal because each removal shifts the
--- remaining children down a slot. Best effort: a stale panel is cosmetic.
local function removeStalePanels(root)
    local removed = 0
    pcall(function()
        local count = tonumber(try(function() return root:GetChildrenCount() end, nil))
        if not count then return end

        local stale = {}
        for i = 0, count - 1 do          -- GetChildAt is zero-based
            local child = try(function() return root:GetChildAt(i) end, nil)
            local name = child
                and try(function() return child:GetFName():ToString() end, nil)
            if type(name) == "string"
                and name:sub(1, #NAME_PREFIX) == NAME_PREFIX then
                stale[#stale + 1] = child
            end
        end

        -- RemoveChild reports whether it found the child. Only an explicit
        -- false counts as a failure: a binding returning nothing would not.
        for _, child in ipairs(stale) do
            local ok, gone = pcall(function() return root:RemoveChild(child) end)
            if ok and gone ~= false then removed = removed + 1 end
        end
    end)

    -- Silent in the ordinary case: a first load has nothing to clean up.
    if removed > 0 then
        log("removed " .. removed .. " stale panel(s) left by a previous "
          .. "script instance, most likely from a hot reload")
    end
end

--- The object's full name, or a placeholder. Used only in failure reasons, so
--- it must never raise: a name is what tells a CDO from a live instance.
local function fullNameOf(obj)
    local name = try(function() return obj:GetFullName() end, nil)
    if type(name) == "string" then return name end
    return "an object whose name could not be read"
end

--- Attach a panel to a HUD widget. Returns a handle, or nil and a one line
--- reason. Failures are returned rather than logged: main.lua retries this
--- every 250 ms while a HUD settles, so a line here would be written sixty
--- times over. The caller reports the last reason once, on giving up.
function M.attach(hud, cfg)
    cfg = cfg or {}
    local root = try(function() return hud.CanvasPanel_Root end, nil)
    -- Reported separately because the causes differ: a nil read means the
    -- named child is not bound yet (UE4SS-NOTES.md section 5), while a failed
    -- IsValid() means the HUD itself is not usable.
    if not root then
        return nil, "CanvasPanel_Root read as nil on " .. fullNameOf(hud)
    end
    if not try(function() return root:IsValid() end, false) then
        return nil, "CanvasPanel_Root is not a valid object on " .. fullNameOf(hud)
    end

    -- Before anything is constructed, so a name this instance is about to ask
    -- for is already unparented by the time it is requested.
    removeStalePanels(root)

    -- Named: the only widget added to the overlay, so the only one to find again.
    local scaleBox = makeNamed("ScaleBox", hud)
    local border   = make("Border", hud)
    local vbox     = make("VerticalBox", hud)
    if not (scaleBox and border and vbox) then
        return nil, "could not construct the panel widgets for "
            .. fullNameOf(hud)
    end

    -- UScaleBox has no override bitfield behind Stretch, so unlike the
    -- SizeBox widths above, the plain field assignment is correct here.
    pcall(function() scaleBox.Stretch = STRETCH_USER_SPECIFIED end)
    pcall(function() scaleBox:SetUserSpecifiedScale(cfg.SCALE or 1.0) end)
    -- Styling is best effort and never aborts the attach: an unstyled panel
    -- is ugly, a panel that failed to attach shows nothing at all.
    styleBorder(border)
    pcall(function() border:AddChild(vbox) end)
    pcall(function() scaleBox:AddChild(border) end)

    local slot = try(function() return root:AddChildToOverlay(scaleBox) end, nil)
    if not slot then
        return nil, "AddChildToOverlay returned no slot on " .. fullNameOf(hud)
    end

    local anchor = ANCHORS[cfg.ANCHOR] or ANCHORS.TopRight
    pcall(function() slot:SetHorizontalAlignment(anchor.h) end)
    pcall(function() slot:SetVerticalAlignment(anchor.v) end)
    pcall(function() slot:SetPadding({
        Left = cfg.MARGIN, Top = cfg.MARGIN,
        Right = cfg.MARGIN, Bottom = cfg.MARGIN }) end)

    local handle = {
        hud = hud, container = scaleBox, vbox = vbox,
        rows = {}, wantedShape = nil,
        colorDisabled = false, colorShape = nil,
    }

    function handle:isValid()
        return try(function() return self.container:IsValid() end, false)
    end

    function handle:setVisible(on)
        pcall(function()
            self.container:SetVisibility(on and VIS_HITTEST_INVISIBLE or VIS_COLLAPSED)
        end)
    end

    --- Rows are built once and only their text is updated afterwards, so a
    --- visible panel does not allocate widgets every poll. The gate is the
    --- row shape, not the count, because widget structure depends on kind. A
    --- rebuild goes into a scratch list swapped in only once every row built,
    --- and wantedShape is recorded first, so a partial failure logs once.
    function handle:setRows(rows)
        rows = rows or {}
        local n = #rows
        local shape = shapeOf(rows)
        if shape ~= self.wantedShape then
            self.wantedShape = shape
            local built, complete = {}, true
            for i = 1, n do
                local r = buildRow(self.hud, self.hud, rows[i].kind)
                if not r then complete = false break end
                built[#built + 1] = r
            end
            if complete then
                pcall(function() self.vbox:ClearChildren() end)
                self.rows = built
                for _, r in ipairs(self.rows) do
                    pcall(function() self.vbox:AddChildToVerticalBox(r.widget) end)
                end
            else
                log("could not build all " .. n .. " rows, keeping the previous panel state")
            end
        end
        -- A rebuild swaps in fresh row tables, so the tracking below starts
        -- empty exactly when the widgets are new.
        for i, r in ipairs(self.rows) do
            local data = rows[i]
            if data then
                if r.span then
                    setTextIfChanged(r, "lastSpan", r.span, spanText(data))
                else
                    local labelChanged =
                        setTextIfChanged(r, "lastLabel", r.label, data.label)
                    setTextIfChanged(r, "lastValue", r.value, data.value)
                    setTextIfChanged(r, "lastDetail", r.detail, data.detail)
                    -- Colour follows the label, so it only reapplies on a change.
                    if data.kind == "entry" and labelChanged then
                        applyStatusColor(self, r.label, data.label)
                    end
                end
            end
        end
    end

    handle:setVisible(false)
    log("panel attached to HUD overlay")
    return handle
end

return M
