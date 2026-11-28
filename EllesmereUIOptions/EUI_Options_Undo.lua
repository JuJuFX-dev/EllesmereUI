if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_Options_Undo.lua
--  Step-by-step undo for the options panel. The widget factory brackets each
--  write with _UndoBegin/_UndoEnd; a step keeps the widget's own getter and
--  setter and its value before and after, and undo replays that setter with
--  the old value. Memory only (last 20 steps), nothing is saved.
-------------------------------------------------------------------------------
local EllesmereUI = _G.EllesmereUI
local L = EllesmereUI.L
local PP = EllesmereUI.PanelPP
local GetTime, InCombatLockdown, type, select, pcall, unpack = GetTime, InCombatLockdown, type, select, pcall, unpack
local floor, format = math.floor, string.format
local isSecret = issecretvalue   -- nil on clients without secret values

local MAX_STEPS = 20
local SLIDER_MERGE = 1.5        -- seconds: a drag or wheel burst is one step
local list = {}
local gen = 0                   -- bumped by every wipe; a write spanning one is dropped
local applying = false
local cur = nil                 -- the step whose setter is running
local scratch = { n = 0 }
local btn, UpdateButton

local function Pack(t, ...)
    local n = select("#", ...)
    for i = n + 1, t.n or 0 do t[i] = nil end
    t.n = n
    for i = 1, n do t[i] = (select(i, ...)) end
    return t
end

-- true / false, or nil when a value cannot be compared (secret, table, function).
local function Same(a, b)
    if a.n ~= b.n then return false end
    for i = 1, a.n do
        local x, y = a[i], b[i]
        if isSecret and (isSecret(x) or isSecret(y)) then return nil end
        local tx, ty = type(x), type(y)
        if tx == "table" or ty == "table" or tx == "function" or ty == "function" then return nil end
        if tx == "number" and ty == "number" then
            if math.abs(x - y) > 1e-6 then return false end
        elseif x ~= y then
            return false
        end
    end
    return true
end

local function SessionActive()
    local so = EllesmereUI.SpecOverrides_EditSessionActive
    return so and so() or false
end

local function Recording()
    if applying or EllesmereUI._prebuilding then return false end
    local mf = _G.EllesmereUIFrame
    if not (mf and mf:IsShown()) then return false end
    return not SessionActive()
end

-- The slot a write belongs to, read BEFORE the setter runs: a setter that
-- rebuilds the page dresses the same frames again for other slots. Same walk
-- as the Spec Overrides attribution; a cog popup continues at the cog button
-- that opened it (_owner), so its rows name the slot they belong to. inPanel
-- is false for EUI windows outside the options panel that use the same widgets.
local function SlotOf(frame)
    local label, section, inPanel, noUndo
    local n, hops = frame, 0
    while n and hops < 40 do
        if n._noUndo then noUndo = true end
        local cc = n._captureCfg
        if not label and (cc or n._labelText) then
            -- A slot with a swatch or cog promotes its cfg into a "multi" one; the row's own cfg is its first accessor.
            local own = cc and cc.accessors and cc.accessors[1] or cc
            if own and own.noUndo then noUndo = true end
            label = cc and cc.text or n._labelText
            local row = n._isOptionRow and n or (n.GetParent and n:GetParent())
            local hdr = row and row._sectionHeader
            section = hdr and hdr._sectionName
        end
        if n == _G.EllesmereUIFrame or n == EllesmereUI._colorPickerPopup then
            inPanel = true
        end
        n = (n._euiOptionsPopup and n._owner) or (n.GetParent and n:GetParent()) or nil
        hops = hops + 1
    end
    return label, section, inPanel, noUndo
end

local function ReadInto(t, get) Pack(t, get()) end

local function Trim()
    while #list > MAX_STEPS do table.remove(list, 1) end
end

-- A write the history cannot undo, so undo never jumps back over it.
local function PushBarrier()
    local top = list[#list]
    if not top or top.barrier then return end
    list[#list + 1] = { barrier = true }
    Trim()
end

local function Wipe()
    wipe(list)
    gen = gen + 1
    cur = nil
    if UpdateButton then UpdateButton() end
end
EllesmereUI._UndoWipe = Wipe

--- Called by the widget factory before a setter runs. get/set: the caller's own
--- accessors (before any factory wrapper). kind: "toggle" | "slider" |
--- "dropdown" | "color". fmt: slider step or dropdown values. group: a token
--- that keeps several writes in one step (one color picker opening).
--- Returns the step to hand to _UndoEnd, or nil when this write is not recorded.
function EllesmereUI._UndoBegin(frame, get, set, kind, fmt, group)
    if not (get and set) or not Recording() then return nil end
    local now = GetTime()
    -- A write from inside another write's setter belongs to that step. A step
    -- left over from a setter that raised (older t0) is simply replaced.
    if cur and cur.t0 == now then return nil end
    local label, section, inPanel, noUndo = SlotOf(frame)
    if noUndo or not inPanel then return nil end
    local top = list[#list]
    local e
    if top and not top.barrier and ((group and top.group == group)
        or (kind == "slider" and not group and top.set == set and top.t and now - top.t < SLIDER_MERGE)) then
        e = top
    else
        local old = {}
        if not pcall(ReadInto, old, get) then return nil end
        e = { set = set, get = get, old = old, new = { n = 0 }, kind = kind, fmt = fmt,
              group = group, label = label, section = section,
              module = EllesmereUI:GetActiveModule(), page = EllesmereUI:GetActivePage(),
              profile = EllesmereUI.GetActiveProfileName(), fresh = true }
    end
    e.gen, e.blocked, e.t0 = gen, nil, now
    cur = e
    return e
end

function EllesmereUI._UndoEnd(e)
    if not e or cur ~= e then return end
    cur = nil
    local drop
    if e.blocked or e.gen ~= gen then
        drop = true
    else
        local same
        if pcall(ReadInto, e.new, e.get) then same = Same(e.old, e.new) end
        drop = same ~= false
        -- Not comparable (secret, table) or unreadable: a write undo cannot replay.
        if same == nil then e.blocked = true end
    end
    e.t = GetTime()
    if drop then
        if not e.fresh and list[#list] == e then list[#list] = nil end
        if e.blocked and e.gen == gen then PushBarrier() end
    elseif e.fresh then
        e.fresh = nil
        list[#list + 1] = e
        Trim()
    end
    UpdateButton()
end

-- A setter that opens a confirmation or reload prompt has effects undo cannot replay.
local function BlockCurrent() if cur then cur.blocked = true end end
hooksecurefunc(EllesmereUI, "ShowConfirmPopup", BlockCurrent)
hooksecurefunc(EllesmereUI, "RequestReload", BlockCurrent)

-- Every options write notifies; one that no step covers (text inputs, checkbox
-- dropdowns, noUndo rows, module-own writes) becomes a barrier. The factory
-- notifies before _UndoEnd, so a recorded write still has cur set here.
hooksecurefunc(EllesmereUI, "_NotifySettingWrite", function(frame)
    if cur or type(frame) ~= "table" or not list[1] or not Recording() then return end
    local _, _, inPanel = SlotOf(frame)
    if inPanel then
        PushBarrier()
        UpdateButton()
    end
end)

-- Data replaced wholesale: steps would replay onto other values.
for _, name in ipairs({ "SwitchProfile", "ApplyProfileData", "SpecOverrides_OnSpecChanged" }) do
    if EllesmereUI[name] then hooksecurefunc(EllesmereUI, name, Wipe) end
end
-- A deep link that pre-selects a unit, bar or type (search, Unlock Mode, What's New):
-- the page's rows then edit another element. The selector setters themselves stay
-- free of it, since the search prebuild runs them for every variant.
hooksecurefunc(EllesmereUI, "NavigateToElementSettings", function(_, _, _, _, preSelectFn)
    if preSelectFn then Wipe() end
end)

-------------------------------------------------------------------------------
--  Text
-------------------------------------------------------------------------------
local function Crumb(e)
    local parts = {}
    local title = e.module and EllesmereUI:GetModuleTitle(e.module)
    if title then parts[#parts + 1] = L(title) end
    if e.section then parts[#parts + 1] = L(e.section) end
    if e.label then parts[#parts + 1] = L(e.label) end
    return table.concat(parts, " > ")
end

local function ValueText(e, t)
    local v, k = t[1], e.kind
    if k == "toggle" then return v and EllesmereUI.L("On") or EllesmereUI.L("Off") end
    if k == "color" then
        local r, g, b = t[1], t[2], t[3]
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return format("#%02X%02X%02X", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
        end
    elseif k == "slider" and type(v) == "number" then
        local step, dec = e.fmt, 0
        if type(step) == "number" and step > 0 and step < 1 then
            dec = math.min(3, math.ceil(-math.log10(step) - 1e-9))
        end
        return format("%." .. dec .. "f", v)
    elseif k == "dropdown" then
        local vals = e.fmt
        if type(vals) == "function" then
            local ok, r = pcall(vals)
            vals = ok and r or nil
        end
        local s = type(vals) == "table" and vals[v] or nil
        if type(s) == "table" then s = s.text end
        if type(s) == "string" then return L(s) end
    end
    return tostring(v)
end

local function Describe(e)
    return EllesmereUI.Lf("%1$s: %2$s to %3$s", Crumb(e), ValueText(e, e.old), ValueText(e, e.new))
end

local function TipText()
    if SessionActive() then return EllesmereUI.L("Undo is off while editing overrides.") end
    local e = list[#list]
    if not e then return EllesmereUI.L("Nothing to undo") end
    if e.barrier then return EllesmereUI.L("Undo") .. "\n" .. EllesmereUI.L("The last change can't be undone.") end
    return EllesmereUI.L("Undo") .. "\n" .. Describe(e)
end

-- The result of a click, shown at the button for a moment.
local noticeTok = 0
local function Notice(text)
    if not (btn and btn:IsVisible()) then return end
    noticeTok = noticeTok + 1
    local tok = noticeTok
    EllesmereUI.ShowWidgetTooltip(btn, text)
    C_Timer.After(2.5, function()
        if tok == noticeTok and not btn:IsMouseOver() then EllesmereUI.HideWidgetTooltip() end
    end)
end
hooksecurefunc(EllesmereUI, "ShowWidgetTooltip", function(owner)
    if owner ~= btn then noticeTok = noticeTok + 1 end
end)

-------------------------------------------------------------------------------
--  Undo
-------------------------------------------------------------------------------

function EllesmereUI.UndoLast()
    if InCombatLockdown() or applying or SessionActive() then return end
    local mf = _G.EllesmereUIFrame
    if not (mf and mf:IsShown()) then return end
    local e = list[#list]
    if not e then return end
    list[#list] = nil
    if e.barrier then
        Notice(EllesmereUI.L("The last change can't be undone."))
        UpdateButton()
        return
    end
    if e.profile ~= EllesmereUI.GetActiveProfileName() then
        Wipe()
        Notice(EllesmereUI.L("Undo history cleared."))
        return
    end
    -- On the step's own page: a setter may read the open tab (Raid Frames party/raid).
    if e.module and (e.module ~= EllesmereUI:GetActiveModule() or e.page ~= EllesmereUI:GetActivePage()) then
        EllesmereUI:SelectModule(e.module)
        if e.page then EllesmereUI:SelectPage(e.page) end
        if EllesmereUI:GetActiveModule() ~= e.module or EllesmereUI:GetActivePage() ~= e.page then
            Notice(EllesmereUI.Lf("%1$s could not be opened and was skipped.", Crumb(e)))
            UpdateButton()
            return
        end
    end
    -- Changed since by something that writes outside the widgets (Unlock Mode,
    -- presets, import, Apply to All): never overwrite that.
    if not pcall(ReadInto, scratch, e.get) or Same(scratch, e.new) ~= true then
        Notice(EllesmereUI.Lf("%1$s was changed elsewhere and was skipped.", Crumb(e)))
        UpdateButton()
        return
    end
    applying = true
    local ok, err = pcall(e.set, unpack(e.old, 1, e.old.n))
    applying = false
    EllesmereUI._settingsChanged = true
    if not ok then geterrorhandler()(err) end
    EllesmereUI:RefreshPage()
    if e.section then
        EllesmereUI:NavigateToElementSettings(e.module, e.page, e.section, nil, e.label)
    end
    Notice(EllesmereUI.Lf("Undone: %1$s", Describe(e)))
    UpdateButton()
end

-------------------------------------------------------------------------------
--  Tab bar button (left of the overrides glyph, or of the module search)
-------------------------------------------------------------------------------
UpdateButton = function()
    if not btn then return end
    local on = list[1] and not SessionActive()
    btn._baseAlpha = on and 0.9 or 0.3
    if not btn:IsMouseOver() then btn:SetAlpha(btn._baseAlpha) end
end

local function PlaceButton()
    local tb = EllesmereUI._tabBar
    local sf = tb and tb._searchFrame
    if not sf then return end
    if not btn then
        btn = CreateFrame("Button", nil, tb)
        PP.Size(btn, 26, 26)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        PP.Size(tex, 18, 18)
        PP.Point(tex, "CENTER", btn, "CENTER", 0, 0)
        tex:SetTexture(EllesmereUI.UNDO_ICON)
        btn:SetScript("OnEnter", function(self)
            self:SetAlpha(1)
            EllesmereUI.ShowWidgetTooltip(self, TipText)
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetAlpha(self._baseAlpha or 0.3)
            EllesmereUI.HideWidgetTooltip()
        end)
        btn:SetScript("OnClick", function() EllesmereUI.UndoLast() end)
    end
    btn:SetParent(tb)
    btn:SetFrameLevel(tb:GetFrameLevel() + 2)
    btn:ClearAllPoints()
    local so = tb._specOvBtn
    if so and so:IsShown() then
        PP.Point(btn, "RIGHT", so, "LEFT", -10, 0)
    elseif sf:IsShown() then
        PP.Point(btn, "RIGHT", sf, "LEFT", -10, 0)
    else
        PP.Point(btn, "RIGHT", sf, "RIGHT", 0, 0)
    end
    btn:Show()
    UpdateButton()
end

-- The toolbar shows or hides the glyph and the search per module (SelectModule).
hooksecurefunc(EllesmereUI, "SelectModule", PlaceButton)
-- An override session starting or ending repaints the page.
hooksecurefunc(EllesmereUI, "RefreshPage", function() if UpdateButton then UpdateButton() end end)
