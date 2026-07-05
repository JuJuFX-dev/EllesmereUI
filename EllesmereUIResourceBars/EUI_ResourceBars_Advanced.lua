-------------------------------------------------------------------------------
--  EUI_ResourceBars_Advanced.lua
--  Advanced options page for the Resource Bars display tab. Selected via the
--  Simple | Advanced sub-menu at the top of the display page.
--
--  Intent (mirrors the Raid Frames party-frame model): per-spec fine-grained
--  control over everything on the Simple page. You pick a spec to configure;
--  every section starts SYNCED to Simple (shown behind a "Synced with Simple
--  Mode" overlay) and can be individually unsynced + customised for that spec.
--
--  ns.ERB_BuildAdvancedPage(parent, yOffset) -> totalHeight  (same contract as
--  BuildBarDisplayPage: builds into `parent` from the negative yOffset and
--  returns the absolute page height).
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
--  Data
-------------------------------------------------------------------------------
local function DB()
    local db = _G._ERB_AceDB
    return db and db.profile
end

-- The player's own specs: { { specID, name }, ... }.
local function GetPlayerSpecs()
    local out = {}
    local n = (GetNumSpecializations and GetNumSpecializations()) or 0
    for i = 1, n do
        local id, name = GetSpecializationInfo(i)
        if id and name then out[#out + 1] = { specID = id, name = name } end
    end
    return out
end

local function SpecName(specID)
    if not specID then return "?" end
    local _, name = GetSpecializationInfoByID(specID)
    return name or ("Spec " .. tostring(specID))
end

local function GetAdvancedSpecs()
    local p = DB(); if not p then return {} end
    if not p.advancedSpecs then p.advancedSpecs = {} end
    return p.advancedSpecs
end

local function FindAdvSpec(specID)
    for i, e in ipairs(GetAdvancedSpecs()) do
        if e.specID == specID then return e, i end
    end
end

local function GetSelectedSpecID()
    local p = DB(); return p and p.advancedSelectedSpec
end

local function SetSelectedSpecID(id)
    local p = DB(); if p then p.advancedSelectedSpec = id end
end

-- Recursive deep copy (used to snapshot a global config table into a per-spec
-- override when a section is unsynced -- "copy-on-unsync"). Handles nested
-- tables like thresholdSpecs.
local function CopyTable(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = (type(v) == "table") and CopyTable(v) or v
    end
    return out
end

-------------------------------------------------------------------------------
--  Page
-------------------------------------------------------------------------------
function ns.ERB_BuildAdvancedPage(parent, yOffset)
    local W    = EllesmereUI.Widgets
    local PP   = EllesmereUI.PanelPP
    local CPAD = EllesmereUI.CONTENT_PAD or 16
    local EG   = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }
    local y    = yOffset
    local _, h

    local created = GetAdvancedSpecs()

    -- Only the current character's specs are configurable here (the dropdown and
    -- the Add list are both current-char only). A shared profile can hold specs
    -- from other characters, so gate the selection on the player's own specs --
    -- otherwise `sel` would default to a foreign spec and wrongly enable the row.
    local playerSpecSet = {}
    for _, sp in ipairs(GetPlayerSpecs()) do playerSpecSet[sp.specID] = true end

    -- Resolve the selected spec: drop a stale (removed) selection; ignore a
    -- foreign selection for this render (without clearing it, so that character
    -- keeps it); default to the first current-char spec, else none.
    local sel = GetSelectedSpecID()
    if sel and not FindAdvSpec(sel) then sel = nil; SetSelectedSpecID(nil) end
    if sel and not playerSpecSet[sel] then sel = nil end
    if not sel then
        for _, e in ipairs(created) do
            if playerSpecSet[e.specID] then sel = e.specID; SetSelectedSpecID(sel); break end
        end
    end

    _, h = W:SectionHeader(parent, "CONFIGURE SPEC", y);  y = y - h

    ---------------------------------------------------------------------------
    --  Row: created-spec dropdown + Add / Remove buttons
    ---------------------------------------------------------------------------
    do
        local ROW_H = 30
        local DDW   = 220

		local currentCharSpecs = {}
		for _, sp in ipairs(GetPlayerSpecs()) do
			currentCharSpecs[sp.specID] = true
		end

        -- Dropdown values: the created specs
		local vals, order = {}, {}
		local matched = false
		for _, e in ipairs(created) do
			if currentCharSpecs[e.specID] then
				vals[e.specID] = SpecName(e.specID)
				order[#order + 1] = e.specID
				matched = true
			end
		end

        local dd = EllesmereUI.BuildDropdownControl(
            parent, DDW, parent:GetFrameLevel() + 5,
            vals, order,
            function()
				if matched then return GetSelectedSpecID() else return EllesmereUI.L("No specs added") end
			end,
            function(key)
                if key and key ~= 0 then
                    SetSelectedSpecID(key)
                    EllesmereUI:RefreshPage(true)
                end
            end
        )
        dd:SetHeight(ROW_H)
        PP.Point(dd, "TOPLEFT", parent, "TOPLEFT", CPAD, y)
        -- No specs yet: nothing to pick, so disable
        if not matched then
            dd:SetEnabled(false)
            dd:SetAlpha(0.5)
        end

        -- Small themed button helper (square, hover-accented).
        local function MakeButton(label, width, anchorTo, onClick)
            local btn = CreateFrame("Button", nil, parent)
            btn:SetSize(width, ROW_H)
            btn:SetPoint("LEFT", anchorTo, "RIGHT", 10, 0)
            local bg = EllesmereUI.SolidTex(btn, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
            local brd = EllesmereUI.MakeBorder(btn, 1, 1, 1, 0.25, PP)
            local lbl = EllesmereUI.MakeFont(btn, 13, nil, 1, 1, 1)
            lbl:SetPoint("CENTER")
            lbl:SetText(EllesmereUI.L(label))
            lbl:SetTextColor(1, 1, 1, 0.8)
            btn:SetScript("OnEnter", function()
                bg:SetColorTexture(0.16, 0.16, 0.17, 0.95)
                if brd and brd.SetColor then brd:SetColor(EG.r, EG.g, EG.b, 0.7) end
            end)
            btn:SetScript("OnLeave", function()
                bg:SetColorTexture(0.10, 0.10, 0.11, 0.9)
                if brd and brd.SetColor then brd:SetColor(1, 1, 1, 0.25) end
            end)
            btn:SetScript("OnClick", onClick)
            return btn
        end

        -- Add: pick from the player's specs that aren't configured yet.
        local addBtn = MakeButton("+ Add Spec", 110, dd, function(self)
            local items = {}
            for _, sp in ipairs(GetPlayerSpecs()) do
                if not FindAdvSpec(sp.specID) then
                    local sid = sp.specID
                    items[#items + 1] = { text = sp.name, onClick = function()
                        local list = GetAdvancedSpecs()
                        list[#list + 1] = { specID = sid, enabled = true, sync = {} }
                        SetSelectedSpecID(sid)
                        if _G._ERB_Apply then _G._ERB_Apply() end
                        EllesmereUI:RefreshPage(true)
                    end }
                end
            end
            if #items == 0 then
                items[#items + 1] = { text = "All specs added", isDisabled = function() return true end }
            end
            EllesmereUI.ShowContextMenu(self, items)
        end)

        -- Remove: delete the selected spec's config -> that spec reverts to
        -- Simple. Rebuild the live bar so it reverts immediately. Only when a
        -- spec is actually selected.
        if sel then
            MakeButton("Remove", 90, addBtn, function()
                EllesmereUI:ShowConfirmPopup({
                    title       = EllesmereUI.L("Remove Advanced Spec"),
                    message     = EllesmereUI.Lf("Remove advanced settings for \"%1$s\"? It will revert to Simple mode.", SpecName(sel)),
                    confirmText = EllesmereUI.L("Remove"),
                    cancelText  = EllesmereUI.L("Cancel"),
                    onConfirm   = function()
                        local _, idx = FindAdvSpec(sel)
                        if idx then table.remove(GetAdvancedSpecs(), idx) end
                        SetSelectedSpecID(nil)
                        if _G._ERB_Apply then _G._ERB_Apply() end
                        EllesmereUI:RefreshPage(true)
                    end,
                })
            end)
        end

        -- Enabled toggle: off => this spec uses Simple (config
        -- preserved). Always shown; disabled until a spec exists to configure.
        local enLbl = EllesmereUI.MakeFont(parent, 12, nil, 1, 1, 1)
        enLbl:SetAlpha(0.7)
        local enToggle = EllesmereUI.BuildToggleControl(
            parent, parent:GetFrameLevel() + 5,
            function() local en = FindAdvSpec(GetSelectedSpecID()); return en ~= nil and en.enabled ~= false end,
            function(v)
                local en = FindAdvSpec(GetSelectedSpecID()); if not en then return end
                en.enabled = v
                if _G._ERB_Apply then _G._ERB_Apply() end
                EllesmereUI:RefreshPage(true)
            end,
            { sizeRatio = 0.95 }
        )
        enToggle:ClearAllPoints()
        PP.Point(enToggle, "RIGHT", parent, "TOPRIGHT", -CPAD, y - ROW_H / 2)
        enLbl:SetPoint("RIGHT", enToggle, "LEFT", -8, 0)
        enLbl:SetText(EllesmereUI.L("Enabled"))
        if not sel then
            enToggle:SetScript("OnClick", nil)
            enToggle:EnableMouse(false)
            enToggle:SetEnabled(false)
            enToggle:SetAlpha(0.35)
            enLbl:SetAlpha(0.3)
            local enDis = CreateFrame("Frame", nil, parent)
            enDis:SetAllPoints(enToggle)
            enDis:SetFrameLevel(enToggle:GetFrameLevel() + 5)
            enDis:EnableMouse(true)
            enDis:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(enDis, EllesmereUI.L("Add a spec first to configure it"))
            end)
            enDis:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        end

        y = y - ROW_H - 18
    end

    ---------------------------------------------------------------------------
    --  Body
    ---------------------------------------------------------------------------
    if not sel then
        local body = EllesmereUI.MakeFont(parent, 13, nil, 1, 1, 1)
        body:SetAlpha(0.5)
        body:SetJustifyH("CENTER")
        body:SetPoint("TOP", parent, "TOP", 0, y - 40)
        body:SetText(EllesmereUI.L("Add a spec above to configure its bars separately from Simple mode."))
        y = y - 140
        return math.abs(y)
    end

    local e = (FindAdvSpec(sel))

    if e and e.enabled == false then
        local body = EllesmereUI.MakeFont(parent, 13, nil, 1, 1, 1)
        body:SetAlpha(0.5)
        body:SetJustifyH("CENTER")
        body:SetPoint("TOP", parent, "TOP", 0, y - 40)
        body:SetText(EllesmereUI.L("Advanced is off for this spec, its bars use Simple mode.") .. "\n"
            .. EllesmereUI.L("Turn on Enabled above to customise (saved settings are kept.)"))
        y = y - 140
        return math.abs(y)
    end

    -- Sections render in the same order as Simple: Class Resource -> Power ->
    -- Health, down the page.

    -- CLASS RESOURCE BAR (override = e.secondary).
    if ns.ERB_BuildClassResourceSection then
        local cSynced = not (e and e.secondary)
        y = ns.ERB_BuildClassResourceSection(parent, y, {
            cfg      = function() return e and e.secondary end,
            advanced = true,
            specID   = sel,
            synced   = cSynced,
            onToggleSync = function()
                if not e then return end
                if cSynced then
                    e.secondary = CopyTable(DB().secondary)
                else
                    e.secondary = nil
                end
                if _G._ERB_Apply then _G._ERB_Apply() end
                EllesmereUI:RefreshPage(true)
            end,
        })
    end

    -- POWER BAR (per-spec sync model, override = e.primary).
    if ns.ERB_BuildPowerSection then
        local pSynced = not (e and e.primary)
        y = ns.ERB_BuildPowerSection(parent, y, {
            cfg      = function() return e and e.primary end,
            advanced = true,
            specID   = sel,
            synced   = pSynced,
            onToggleSync = function()
                if not e then return end
                if pSynced then
                    e.primary = CopyTable(DB().primary)
                else
                    e.primary = nil
                end
                if _G._ERB_Apply then _G._ERB_Apply() end
                EllesmereUI:RefreshPage(true)
            end,
        })
    end

    -- HEALTH BAR (override = e.health).
    if ns.ERB_BuildHealthSection then
        local synced = not (e and e.health)
        y = ns.ERB_BuildHealthSection(parent, y, {
            cfg      = function() return e and e.health end,
            advanced = true,
            specID   = sel,
            synced   = synced,
            onToggleSync = function()
                if not e then return end
                if synced then
                    e.health = CopyTable(DB().health)   -- copy-on-unsync
                else
                    e.health = nil                       -- re-sync to Simple
                end
                if _G._ERB_Apply then _G._ERB_Apply() end  -- rebuild the live bar
                EllesmereUI:RefreshPage(true)
            end,
        })
    end

    return math.abs(y)
end
