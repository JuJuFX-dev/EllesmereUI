-- Player Aura frames (Buffs/Debuffs): movable exclusively via EllesmereUI's
-- UnlockMode instead of Blizzard's Edit Mode. Standalone deferred-init entry,
-- zero edits to EUI_UnlockMode.lua. Must load AFTER EUI_UnlockMode.lua in the
-- .toc (needs the wrapped RegisterUnlockElements + _deferredInits already set up).

EllesmereUI._deferredInits[#EllesmereUI._deferredInits + 1] = function()

EllesmereUI._playerAuraPositionKeys = {
    PlayerBuffs = "buffs",
    PlayerDebuffs = "debuffs",
}
EllesmereUI._playerAuraAnchorGuards = {}

function EllesmereUI.GetPlayerAuraPositionDB()
    if not EllesmereUIDB then return nil end
    if not EllesmereUIDB.playerAuraPositions then
        EllesmereUIDB.playerAuraPositions = {}
    end
    return EllesmereUIDB.playerAuraPositions
end

function EllesmereUI.GetPlayerAuraPosition(key)
    local db = EllesmereUI.GetPlayerAuraPositionDB()
    local positionKey = EllesmereUI._playerAuraPositionKeys[key]
    return db and positionKey and db[positionKey] or nil
end

-- Mirrors the non-CENTER branch of EUI_UnlockMode.lua's MigrateAndApplyPosition
-- (private local there). Our own DB only ever stores TOPLEFT/TOPLEFT (that's
-- what the generic mover's OnDragStop writes), so the CENTER/CENTER
-- grow-direction branch never applies to us and doesn't need duplicating.
function EllesmereUI.ApplyPlayerAuraPosition(key)
    local frame = key == "PlayerBuffs" and _G.BuffFrame or _G.DebuffFrame
    local pos = EllesmereUI.GetPlayerAuraPosition(key)
    if not frame or not pos or not pos.point then return end
    local px, py = pos.x or 0, pos.y or 0
    local PP = EllesmereUI.PP
    if PP and PP.SnapForES then
        local es = frame:GetEffectiveScale()
        px = PP.SnapForES(px, es)
        py = PP.SnapForES(py, es)
    end
    pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, px, py)
    end)
end

function EllesmereUI.ShowPlayerAuraEditModeLockNotice()
    if not EllesmereUI._playerAuraEditModeNoticeShown then
        EllesmereUI.Print(EllesmereUI.L("|cff0cd29fEllesmereUI: |rPlayer Aura positions are managed by EllesmereUI. Edit Mode movement is disabled."))
        EllesmereUI._playerAuraEditModeNoticeShown = true
    end
end

function EllesmereUI.InstallPlayerAuraAnchorGuard(key)
    local frame = key == "PlayerBuffs" and _G.BuffFrame or _G.DebuffFrame
    if not frame or EllesmereUI._playerAuraAnchorGuards[frame] or not frame.ApplySystemAnchor then return end
    EllesmereUI._playerAuraAnchorGuards[frame] = true

    -- Block Blizzard's own Edit Mode drag at the source (Selection sub-frame),
    -- same pattern as LockCooldownViewerFrames for CDM.
    frame:SetMovable(false)
    local selection = frame.Selection
    if selection then
        selection:SetScript("OnDragStart", EllesmereUI.ShowPlayerAuraEditModeLockNotice)
        selection:SetScript("OnDragStop", nil)
    end

    hooksecurefunc(frame, "ApplySystemAnchor", function()
        -- Don't fight EllesmereUI's own live drag/pending (uncommitted) edits.
        -- Blizzard's grid rebuild (buff gain/loss, not just Edit Mode) calls
        -- this constantly -- reapplying our saved DB position mid-edit is
        -- exactly what caused the border-jump/flicker bug.
        if EllesmereUI._unlockModeActive then return end
        if not EllesmereUI.GetPlayerAuraPosition(key) then return end
        C_Timer.After(0, function()
            if EllesmereUI._unlockModeActive then return end
            EllesmereUI.ApplyPlayerAuraPosition(key)
        end)
    end)
end

local function SavePlayerAuraPosition(key, point, relPoint, x, y)
    local db = EllesmereUI.GetPlayerAuraPositionDB()
    local positionKey = EllesmereUI._playerAuraPositionKeys[key]
    if db and positionKey then
        db[positionKey] = { point = point, relPoint = relPoint, x = x, y = y }
    end
end

local function ClearPlayerAuraPosition(key)
    local db = EllesmereUI.GetPlayerAuraPositionDB()
    local positionKey = EllesmereUI._playerAuraPositionKeys[key]
    if db and positionKey then db[positionKey] = nil end
end

local function ApplyPlayerAuraElement(key)
    EllesmereUI.InstallPlayerAuraAnchorGuard(key)
    EllesmereUI.ApplyPlayerAuraPosition(key)
end

local function GetPlayerAuraSize(key)
    local frame = key == "PlayerBuffs" and _G.BuffFrame or _G.DebuffFrame
    if not frame then return 0, 0 end
    local w, h = frame:GetWidth(), frame:GetHeight()
    if key == "PlayerBuffs" then
        local btn = frame.CollapseAndExpandButton
        if btn and btn:IsShown() then
            w = w + btn:GetWidth()
        end
    end
    return w, h
end

EllesmereUI:RegisterUnlockElements({
    {
        key = "PlayerBuffs",
        label = "Buffs",
        order = 950,
        noResize = true,
        getFrame = function() return _G.BuffFrame end,
        getRightInset = function()
            if not C_CVar or C_CVar.GetCVar("collapseExpandBuffs") ~= "0" then return 0 end
            local button = _G.BuffFrame and _G.BuffFrame.CollapseAndExpandButton
            return button and button:GetWidth() or 0
        end,
        loadPosition = function(key) return EllesmereUI.GetPlayerAuraPosition(key) end,
        savePosition = SavePlayerAuraPosition,
        clearPosition = ClearPlayerAuraPosition,
        applyPosition = ApplyPlayerAuraElement,
    },
    {
        key = "PlayerDebuffs",
        label = "Debuffs",
        order = 951,
        noResize = true,
        getFrame = function() return _G.DebuffFrame end,
        getSize = GetPlayerAuraSize,
        loadPosition = function(key) return EllesmereUI.GetPlayerAuraPosition(key) end,
        savePosition = SavePlayerAuraPosition,
        clearPosition = ClearPlayerAuraPosition,
        applyPosition = ApplyPlayerAuraElement,
    },
}, "EllesmereUI")

-- Late registration (see EUI_UnlockMode.lua's own comment on CDM: "some addons
-- like CDM need applyPosition to build/initialize frames"): we register after
-- the core file's own initial ApplySavedPositions() sweep already ran, so that
-- sweep never saw us. Apply once now, ourselves.
ApplyPlayerAuraElement("PlayerBuffs")
ApplyPlayerAuraElement("PlayerDebuffs")

end