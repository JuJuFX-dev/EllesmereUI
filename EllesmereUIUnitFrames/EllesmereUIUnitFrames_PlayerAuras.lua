-------------------------------------------------------------------------------
--  EllesmereUIUnitFrames_PlayerAuras.lua
--  Simple reskin of Blizzard's standalone BuffFrame / DebuffFrame icons.
--  No reparenting, no repositioning -- Blizzard controls layout via Edit Mode.
-------------------------------------------------------------------------------
local addon, ns = ...

local GetFFD = EllesmereUI._GetFFD

local ICON_ZOOM = 0.055  -- fallback crop (same as totem bar); user values in profile
local BLIZZARD_AURA_ICON_SIZE = 30 -- visible icon inside the native 32px aura button

-- Learned native grid step (icon size + Blizzard's built-in 5px padding),
-- in whatever offset units SetPoint reports (already UIScale-adjusted, so
-- not necessarily a whole number of "real" pixels). Populated lazily from
-- the first couple of genuine Blizzard SetPoint calls per container -- see
-- the padding hook in SkinAuraButton. Kept separate for buffs/debuffs since
-- their icon sizes/padding can differ.
local _paGridStep = {
    buff   = { x = nil, y = nil },
    debuff = { x = nil, y = nil },
}
local PADDING_NATIVE = 5 -- Blizzard's own Edit Mode minimum for iconPadding

--  Settings helper (moved up here: DebuffTypeBorderColors below needs it
--  for its live DB lookups).
-------------------------------------------------------------------------------
local function PA()
    local db = ns.db
    return db and db.profile and db.profile.playerAuras
end

local function FormatCompactDuration(timeLeft, style)
    if timeLeft >= 86400 then
        return string.format("%dd", math.floor(timeLeft / 86400 + 0.5))
    end
    if style == "colon" then
        if timeLeft >= 3600 then
            return string.format("%d:%02d",
                math.floor(timeLeft / 3600),
                math.floor((timeLeft % 3600) / 60))
        end
        if timeLeft >= 60 then
            return string.format("%d:%02d", math.floor(timeLeft / 60), math.floor(timeLeft % 60))
        end
        return string.format("%d", math.floor(timeLeft + 0.5))
    end
    if timeLeft >= 3600 then
        return string.format("%dh", math.floor(timeLeft / 3600 + 0.5))
    end
    if style == "seconds" then
        return string.format("%d", math.floor(timeLeft + 0.5))
    end
    if timeLeft >= 60 then
        return string.format("%dm", math.floor(timeLeft / 60 + 0.5))
    end
    return string.format("%d", math.floor(timeLeft + 0.5))
end

--  Debuff type -> border color lookup (for "Color Border by Debuff Type").
-------------------------------------------------------------------------------
local function HexColor(hex)
    -- Guard against malformed/short hex strings so a bad value can't throw
    -- (arithmetic on nil) -- falls back to white if parsing fails.
    if type(hex) ~= "string" or #hex < 6 then
        return 1, 1, 1
    end
    local rn = tonumber(hex:sub(1, 2), 16)
    local gn = tonumber(hex:sub(3, 4), 16)
    local bn = tonumber(hex:sub(5, 6), 16)
    if not (rn and gn and bn) then
        return 1, 1, 1
    end
    return rn / 255, gn / 255, bn / 255
end

-- Fallback defaults (identical to the previous hard-coded values). Used only
-- when no DB value has been saved yet for a given channel, e.g. fresh
-- profiles or profiles saved before this option existed.
local DEBUFF_TYPE_DEFAULT_HEX = {
    None       = "e63333",
    Magic      = "3399ff",
    Curse      = "9900ff",
    Disease    = "996600",
    Poison     = "009900",
    Bleed      = "ff3399",
    --["Bad Dispel"] = "0dd9f0",
    --Stealable  = "ede88c",
    --Energy     = "ff8000",
}

-- DB field prefix for each dispel type. Flat, scalar fields on
-- db.profile.playerAuras (…R/…G/…B/…A), mirroring the existing
-- borderR/borderG/borderB/borderA pattern already used in this table.
-- This is entirely local to the Player Auras module -- no relation to the
-- global color system (EllesmereUI.lua's GetCustomColorsDB/CLASS_COLOR_MAP/
-- etc.), and no relation to the separate dispelColorMagic/dispelColorCurse/
-- etc. player-frame health-overlay colors, which remain untouched.
local DEBUFF_TYPE_DB_PREFIX = {
    None    = "debuffTypeColorNone",
    Magic   = "debuffTypeColorMagic",
    Curse   = "debuffTypeColorCurse",
    Disease = "debuffTypeColorDisease",
    Poison  = "debuffTypeColorPoison",
    Bleed   = "debuffTypeColorBleed",
}

-- Live-reads the current DB values (via PA()) on every index access,
-- falling back to the static defaults above when a channel hasn't been set
-- yet. Only ever consulted from BuildDispelTypeCurve(), which is itself
-- cached and only rebuilt via InvalidateDispelCurve() -- so this "live
-- lookup" cost is paid once per color change, not once per aura update.
local DebuffTypeBorderColors = setmetatable({}, {
    __index = function(_, key)
        local prefix = DEBUFF_TYPE_DB_PREFIX[key]
        if not prefix then return nil end

        local defHex = DEBUFF_TYPE_DEFAULT_HEX[key]
        local dr, dg, db_ = 1, 1, 1
        if defHex then dr, dg, db_ = HexColor(defHex) end

        local cfg = PA()
        local r = cfg and cfg[prefix .. "R"]
        local g = cfg and cfg[prefix .. "G"]
        local b = cfg and cfg[prefix .. "B"]
        local a = cfg and cfg[prefix .. "A"]

        if r == nil then r = dr end
        if g == nil then g = dg end
        if b == nil then b = db_ end
        if a == nil then a = 1 end

        return { r, g, b, a }
    end,
})

-------------------------------------------------------------------------------
--  Dispel-type curve (Secret-Values-safe border coloring)
-------------------------------------------------------------------------------
-- Indices match Blizzard's internal dispel-type enumeration as consumed by
-- C_UnitAuras.GetAuraDispelTypeColor's curve lookup. Bleed has no contiguous
-- slot in that enum (it's not a "real" dispel type) -- 11 is the index
-- Blizzard's own UI code uses for it there; verify against
-- Enum.DispelType / the relevant Blizzard FrameXML if this ever needs
-- re-checking on a client update.
local DISPEL_TYPE_INDEX = {
    None    = 0,
    Magic   = 1,
    Curse   = 2,
    Disease = 3,
    Poison  = 4,
    Bleed = 11,
}

-- Built lazily on first use (not at file load) so a missing API on an older
-- client can't break addon load entirely -- SkinAuraButton just falls back
-- to the static config border color if this stays nil.
local dispelCurve
local dispelCurveAttempted = false

-- Bumped on every InvalidateDispelCurve() call. Used by
-- GetDebuffTypeBorderColor() to know its per-button cached color
-- (ffd._paLastBorderColor) was computed against a now-stale curve, so it
-- gets recomputed immediately instead of only on the next aura change.
local dispelCurveVersion = 0

local function BuildDispelTypeCurve()
    if dispelCurveAttempted then return dispelCurve end
    dispelCurveAttempted = true

    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor) then
        return nil
    end

    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateColorCurve()
        c:SetType(Enum.LuaCurveType.Step) -- discrete types, no blending between them
        for key, index in pairs(DISPEL_TYPE_INDEX) do
            local col = DebuffTypeBorderColors[key]
            if col then
                c:AddPoint(index, CreateColor(col[1], col[2], col[3], col[4]))
            end
        end
        return c
    end)

    if ok then
        dispelCurve = curve
    end
    return dispelCurve
end

-- Forces BuildDispelTypeCurve() to rebuild (picking up current DB colors)
-- on its next call. Called from every color setter in the Options UI so a
-- color change is reflected immediately, without requiring /reload.
local function InvalidateDispelCurve()
    dispelCurve = nil
    dispelCurveAttempted = false
    dispelCurveVersion = dispelCurveVersion + 1
end
ns.InvalidateDispelCurve = InvalidateDispelCurve

-------------------------------------------------------------------------------
-- Was UpdateDebuffTypeBorderColor: now a pure color resolver, since
-- ApplySecretSafeBorderStyle bakes r/g/b/a into its own internally-managed
-- edge textures (state._secretBorderEdges) at call time -- there is no
-- post-hoc SetColorTexture step to hook into anymore.
local function GetDebuffTypeBorderColor(btn, ffd, cfg)
    local bR, bG, bB, bA = cfg.borderR or 0, cfg.borderG or 0, cfg.borderB or 0, cfg.borderA or 1

    local curve = BuildDispelTypeCurve()
    if curve then
        local buttonInfo = btn.buttonInfo
        local index = buttonInfo and buttonInfo.index
        if index then
            local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, btn.unit or "player", index, "HARMFUL")
            local auraInstanceID = ok and auraData and auraData.auraInstanceID
            if auraInstanceID then
                if ffd._paLastAuraInstanceID == auraInstanceID
                    and ffd._paLastBorderColor
                    and ffd._paLastCurveVersion == dispelCurveVersion then
                    local c = ffd._paLastBorderColor
                    bR, bG, bB, bA = c[1], c[2], c[3], c[4]
                else
                    local ok2, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, btn.unit or "player", auraInstanceID, curve)
                    if ok2 and color then
                        -- color:GetRGBA() may return Secret Values here (in combat /
                        -- M+ / instances). Previously this was confirmed safe because
                        -- it went straight into SetColorTexture. It now flows into
                        -- ApplySecretSafeBorderStyle instead (SetVertexColor for
                        -- textured borders, ApplyBorderStyle for solid) -- NOT yet
                        -- verified against Secret Values for either path. Test both
                        -- border-texture modes in combat/M+ before shipping.
                        local ok3, r, g, b, a = pcall(color.GetRGBA, color)
                        if ok3 then
                            bR, bG, bB, bA = r, g, b, a
                        end
                    end
                    ffd._paLastAuraInstanceID = auraInstanceID
                    ffd._paLastBorderColor = { bR, bG, bB, bA }
                    ffd._paLastCurveVersion = dispelCurveVersion
                end
            else
                ffd._paLastAuraInstanceID = nil
                ffd._paLastBorderColor = nil
                ffd._paLastCurveVersion = nil
            end
        end
    end

    return bR, bG, bB, bA
end

-------------------------------------------------------------------------------
--  Per-button skinning
-------------------------------------------------------------------------------
local function SkinAuraButton(btn, isDebuff)
    local cfg = PA()
    if not cfg then return end
    -- Skip layout anchors
    if btn.isAuraAnchor then return end

    local ffd = GetFFD(btn)
    if not ffd then return end

    -- Fingerprint of everything that influences this button's appearance.
    -- If nothing relevant changed and the button is already skinned, bail
    -- out immediately -- no region scans, no ClearAllPoints/SetPoint, no
    -- texture/font calls. This is what kills both the CPU cost AND the
    -- visible "jumping" of the duration/count text on every refresh pass.
    --
    -- Compared field-by-field against cached values on ffd instead of
    -- building a table + table.concat string every call -- this avoids
    -- two allocations per button on every single UpdateGridLayout firing,
    -- even in the (very common) case where nothing actually changed.
    local noBlizzBorderV  = (cfg.noBlizzardBorder ~= false) and 1 or 0
    local noBorderDebuffsV = cfg.noBorderDebuffs and 1 or 0
    local borderSizeV = cfg.borderSize or 1
    local borderRV = cfg.borderR or 0
    local borderGV = cfg.borderG or 0
    local borderBV = cfg.borderB or 0
    local borderAV = cfg.borderA or 1
    local durSizeV = cfg.durationTextSize or 11
    local durPosV = cfg.durationPosition or ""
    local durOXV = cfg.durationOffsetX or 0
    local durOYV = cfg.durationOffsetY or 0
    local stackSizeV = cfg.stackTextSize or 11
    local stackPosV = cfg.stackPosition or ""
    local stackOXV = cfg.stackOffsetX or 0
    local stackOYV = cfg.stackOffsetY or 0
    local isDebuffV = isDebuff and 1 or 0
    local colorByDebuffTypeV = cfg.colorBorderByDebuffType and 1 or 0
    local iconZoomV = (isDebuff and cfg.debuffIconZoom or cfg.buffIconZoom) or ICON_ZOOM
    local showTextV = cfg.showText ~= false and 1 or 0
    -- debuffTypeV intentionally not read/compared here -- btn.buttonInfo.debuffType
    -- is a Secret Value in tainted addon execution; comparing it (even via ==)
    -- throws a Lua error. Border coloring by debuff type is instead done via
    -- GetDebuffTypeBorderColor() further down, which uses the Secret-Values
    -- -safe C_UnitAuras.GetAuraDispelTypeColor curve API.

    if ffd._paSkinned
        and ffd._paNoBlizzBorder == noBlizzBorderV
        and ffd._paNoBorderDebuffs == noBorderDebuffsV
        and ffd._paBorderSize == borderSizeV
        and ffd._paBorderR == borderRV
        and ffd._paBorderG == borderGV
        and ffd._paBorderB == borderBV
        and ffd._paBorderA == borderAV
        and ffd._paDurSize == durSizeV
        and ffd._paDurPos == durPosV
        and ffd._paDurOX == durOXV
        and ffd._paDurOY == durOYV
        and ffd._paStackSize == stackSizeV
        and ffd._paStackPos == stackPosV
        and ffd._paStackOX == stackOXV
        and ffd._paStackOY == stackOYV
        and ffd._paIsDebuff == isDebuffV
        and ffd._paColorByDebuffType == colorByDebuffTypeV
        and ffd._paIconZoom == iconZoomV
        and ffd._paShowText == showTextV
    then
        -- Everything static already matches -- but if debuff-type coloring is
        -- active, the aura occupying this slot can still have changed (same
        -- button/icon, different debuff) without any of the above changing.
        -- That's a Secret Value we can't detect via fingerprint comparison,
        -- so when this mode is on we cheaply re-apply just the border color
        -- every pass instead of skipping entirely. This is 4 SetColorTexture
        -- calls, not a full re-skin -- no region scans, no SetPoint, no font
        -- calls -- so it stays in line with the 0-performance-impact goal.
    if isDebuffV == 1 and colorByDebuffTypeV == 1 and (not cfg.borderTexture or cfg.borderTexture == "" or cfg.borderTexture == "solid") and ffd._paBorder then
        local bR, bG, bB, bA = GetDebuffTypeBorderColor(btn, ffd, cfg)
        EllesmereUI.SetBorderStyleColor(ffd._paBorder, bR, bG, bB, bA)
    end
        return
    end

    ffd._paNoBlizzBorder = noBlizzBorderV
    ffd._paNoBorderDebuffs = noBorderDebuffsV
    ffd._paBorderSize = borderSizeV
    ffd._paBorderR = borderRV
    ffd._paBorderG = borderGV
    ffd._paBorderB = borderBV
    ffd._paBorderA = borderAV
    ffd._paDurSize = durSizeV
    ffd._paDurPos = durPosV
    ffd._paDurOX = durOXV
    ffd._paDurOY = durOYV
    ffd._paStackSize = stackSizeV
    ffd._paStackPos = stackPosV
    ffd._paStackOX = stackOXV
    ffd._paStackOY = stackOYV
    ffd._paIsDebuff = isDebuffV
    ffd._paColorByDebuffType = colorByDebuffTypeV
    ffd._paIconZoom = iconZoomV
    ffd._paShowText = showTextV

    -- Icon zoom crop (btn.Icon is a Frame in Midnight; find the Texture inside)
    local iconFrame = btn.Icon
    local iconTex
    if iconFrame then
        -- Try known child names first
        iconTex = iconFrame.Texture or iconFrame.texture
        -- Fallback: scan for the first Texture region
        if not iconTex and iconFrame.GetRegions then
            -- Snapshot regions once instead of re-calling GetRegions() inside
            -- the loop (select(i, GetRegions()) would re-walk the full vararg
            -- list every iteration -- O(n^2) for n regions).
            local regions = { iconFrame:GetRegions() }
            for i = 1, #regions do
                local r = regions[i]
                if r and r:IsObjectType("Texture") and r.SetTexCoord then
                    iconTex = r
                    break
                end
            end
        end
        -- iconFrame itself might be a Texture (pre-Midnight)
        if not iconTex and iconFrame.SetTexCoord then
            iconTex = iconFrame
        end
    end
    if iconTex and iconTex.SetTexCoord then
        local z
        if isDebuff then z = cfg.debuffIconZoom else z = cfg.buffIconZoom end
        z = z or ICON_ZOOM
        iconTex:SetTexCoord(z, 1 - z, z, 1 - z)
    end

    -- Hide any extra Blizzard border/skin textures nested inside the icon
    -- frame itself. In Midnight, btn.Icon is a Frame and can contain its own
    -- border region (this is what shows up as e.g. the purple temporary-
    -- weapon-enchant frame) separate from btn.Border. We hide every texture
    -- region except the icon texture we just found, so any such overlay
    -- disappears regardless of its name. Alpha only, never Hide(), to avoid
    -- taint on Blizzard's secure-adjacent frames.
    local noBlizzardBorder = cfg.noBlizzardBorder ~= false
    if iconFrame and iconFrame.GetRegions and iconFrame ~= btn then
        -- Snapshot regions once (see comment above for why).
        local regions = { iconFrame:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r and r ~= iconTex and r.IsObjectType and r:IsObjectType("Texture") and r.SetAlpha then
                r:SetAlpha(noBlizzardBorder and 0 or 1)
            end
        end
    end

    -- Some border/skin textures (notably on temporary weapon-enchant
    -- buttons, e.g. "...TempEnchant1") are parented directly to the button
    -- itself rather than to btn.Icon. Scan the button's own regions too and
    -- hide anything that isn't the icon texture, the Count/Duration text, or
    -- one of our own custom edge textures.
    if btn.GetRegions then
        local edges = ffd._paEdges
        -- Snapshot regions once (see comment above for why).
        local regions = { btn:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r and r.IsObjectType and r:IsObjectType("Texture") and r.SetAlpha then
                local isIcon  = (r == iconTex)
                local isOurs  = edges and (r == edges.top or r == edges.bottom or r == edges.left or r == edges.right)
                local isKnown = (r == btn.Icon) or (r == btn.Count) or (r == btn.Duration)
                if not (isIcon or isOurs or isKnown) then
                    r:SetAlpha(noBlizzardBorder and 0 or 1)
                end
            end
        end
    end

    -- Some button templates also skin the button itself (Normal/Pushed/
    -- Highlight texture) which can bleed a colored frame around the icon.
    if btn.GetNormalTexture then
        local nt = btn:GetNormalTexture()
        if nt then nt:SetAlpha(noBlizzardBorder and 0 or 1) end
    end

    -- Hide Blizzard's plain border (alpha, not Hide, to avoid taint).
    -- For debuffs we still allow keeping it, since its color communicates
    -- the debuff type (magic/curse/poison/disease) which has gameplay value.
    -- For buffs there is no such gameplay value, so it is always removed --
    -- our own clean pixel border (below) is drawn in its place regardless.
    if btn.Border then
        local keepBlizzBorder = isDebuff and cfg.noBorderDebuffs
        if keepBlizzBorder then
            btn.Border:SetAlpha(1)
        else
            btn.Border:SetAlpha(0)
        end
    end

    -- Duration text styling (btn.Duration may be a Frame containing a FontString)
    local durFS = btn.Duration
    if durFS and not durFS.SetFont and durFS.GetRegions then
        -- Duration is a Frame; find the FontString inside.
        -- Snapshot regions once (see comment above for why).
        local regions = { durFS:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r and r.SetFont then durFS = r; break end
        end
    end
    if durFS and durFS.SetFont and not ffd._paDurHooked
        and type(btn.UpdateDuration) == "function" then
        ffd._paDurHooked = true
        local fs = durFS
        hooksecurefunc(btn, "UpdateDuration", function(_, timeLeft)
            local pa = PA()
            local style = pa and pa.durationFormat
            if not style or style == "blizzard" then return end
            if type(timeLeft) ~= "number" then return end
            if issecretvalue and issecretvalue(timeLeft) then return end
            if timeLeft <= 0 then return end
            fs:SetText(FormatCompactDuration(timeLeft, style))
        end)
    end

    if durFS and durFS.SetFont then
        if cfg.showText then
            local fontPath = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("unitFrames") or STANDARD_TEXT_FONT
            -- Duration count always uses a forced OUTLINE, SLUG flag (keeps the digits
            -- crisp regardless of the user's global font-outline setting).
            EllesmereUI.ApplyIconTextFont(durFS, fontPath, cfg.durationTextSize or 11, "unitFrames")
            durFS:SetDrawLayer("OVERLAY", 7)
            if durFS and not durFS._paColorHooked then
                durFS._paColorHooked = true
                hooksecurefunc(durFS, "SetVertexColor", function(self, r, g, b, a)
                    if self._paApplyingColor then return end -- Rekursionsschutz
                    -- Live-read the config here (same pattern as the SetAlpha/
                    -- SetPoint hooks below) instead of using the "cfg" upvalue
                    -- captured at hook-creation time -- this hook is only
                    -- attached once per FontString, so a stale "cfg" would
                    -- silently stop reacting to later showText changes.
                    local liveCfg = PA()
                    if not liveCfg then return end
                    self._paApplyingColor = true
                    if liveCfg.showText then
                        self:SetVertexColor(1, 1, 1, 1)
                    end
                    self._paApplyingColor = false
                end)
            end

            -- Reposition duration text (Top/Bottom + X/Y offset) relative to the icon.
            -- Cheap re-anchor on our own FontString reference; no taint risk.
            local durAnchor = btn.Icon or btn
            local durOX = cfg.durationOffsetX or 0
            local durOY = cfg.durationOffsetY or 0
            durFS:ClearAllPoints()
            if cfg.durationPosition == "top" then
                durFS:SetPoint("TOP", durAnchor, "TOP", durOX, durOY)
            else
                durFS:SetPoint("BOTTOM", durAnchor, "BOTTOM", durOX, durOY)
            end

            -- Alpha only, never Hide() -- Blizzard's own aura update code keeps
            -- touching this FontString (SetText on every tick), so a Hide() call
            -- would just get fought over every refresh. Alpha sticks regardless
            -- of what Blizzard does to visibility/text.
            durFS:SetAlpha(showTextV == 1 and 1 or 0)

            -- Blizzard's own countdown-tick code resets alpha on this FontString
            -- too (same mechanism that forced the SetVertexColor hook above --
            -- it recolors/refreshes the text as the duration ticks down), which
            -- silently undid our SetAlpha(0) a moment after we set it. Same
            -- hook-with-recursion-guard pattern as SetPoint/SetVertexColor below
            -- so our "showText" choice always wins, whenever Blizzard touches it.
            if not durFS._paAlphaHooked then
                durFS._paAlphaHooked = true
                hooksecurefunc(durFS, "SetAlpha", function(self)
                    if self._paApplyingAlpha then return end
                    local liveCfg = PA()
                    if not liveCfg then return end
                    self._paApplyingAlpha = true
                    self:SetAlpha(liveCfg.showText ~= false and 1 or 0)
                    self._paApplyingAlpha = false
                end)
            end

            -- Blizzard re-anchors this FontString on its own during zone/instance
            -- transitions (its own UpdateGridLayout-style code runs again after
            -- a loading screen), which silently undoes our positioning above --
            -- this is what caused the duration text to jump back after entering
            -- a dungeon. Rather than guess at *when* Blizzard does this and race
            -- it with our own timing, we hook SetPoint itself (same pattern as
            -- the SetVertexColor hook below) so that any external SetPoint call,
            -- whenever it happens, is immediately followed by our own anchor.
            -- The recursion guard prevents this from calling itself.
            if not durFS._paPointHooked then
                durFS._paPointHooked = true
                hooksecurefunc(durFS, "SetPoint", function(self)
                    if self._paApplyingPoint then return end
                    local liveCfg = PA()
                    if not liveCfg then return end
                    self._paApplyingPoint = true
                    self:ClearAllPoints()
                    local anchor = btn.Icon or btn
                    if liveCfg.durationPosition == "top" then
                        self:SetPoint("TOP", anchor, "TOP", liveCfg.durationOffsetX or 0, liveCfg.durationOffsetY or 0)
                    else
                        self:SetPoint("BOTTOM", anchor, "BOTTOM", liveCfg.durationOffsetX or 0, liveCfg.durationOffsetY or 0)
                    end
                    self._paApplyingPoint = false
                end)
            end
        else
            -- Same alpha-only approach as the stack text below, instead of
            -- SetTextColor -- keeps both hide mechanisms consistent.
            durFS:SetAlpha(0)
        end
    end

    -- Count text styling
    local countFS = btn.Count
    if countFS and not countFS.SetFont and countFS.GetRegions then
        -- Snapshot regions once (see comment above for why).
        local regions = { countFS:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r and r.SetFont then countFS = r; break end
        end
    end
    if countFS and countFS.SetFont then
        local fontPath = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("unitFrames") or STANDARD_TEXT_FONT
        -- Stack count always uses a forced OUTLINE, SLUG flag (keeps the digits
        -- crisp regardless of the user's global font-outline setting).
        EllesmereUI.ApplyIconTextFont(countFS, fontPath, cfg.stackTextSize or 11, "unitFrames")
        countFS:SetDrawLayer("OVERLAY", 7)

        -- Reposition stack count text (Top/Bottom + X/Y offset) relative to the icon.
        -- Cheap re-anchor on our own FontString reference; no taint risk.
        local countAnchor = btn.Icon or btn
        local countOX = cfg.stackOffsetX or 0
        local countOY = cfg.stackOffsetY or 0
        countFS:ClearAllPoints()
        if cfg.stackPosition == "top" then
            countFS:SetPoint("TOP", countAnchor, "TOP", countOX, countOY)
        else
            countFS:SetPoint("BOTTOM", countAnchor, "BOTTOM", countOX, countOY)
        end

        -- Same alpha-only approach as the duration text above.
        countFS:SetAlpha(showTextV == 1 and 1 or 0)

        -- Same "Blizzard re-touches this FontString" problem as the duration
        -- text above (alpha reset on countdown-tick-style updates, re-anchor
        -- reset after loading screens). Same hook-with-recursion-guard
        -- pattern, applied to the stack/count text so its position and
        -- visibility survive Blizzard's own refresh code the same way
        -- duration's does.
        if not countFS._paAlphaHooked then
            countFS._paAlphaHooked = true
            hooksecurefunc(countFS, "SetAlpha", function(self)
                if self._paApplyingAlpha then return end
                local liveCfg = PA()
                if not liveCfg then return end
                self._paApplyingAlpha = true
                self:SetAlpha(liveCfg.showText ~= false and 1 or 0)
                self._paApplyingAlpha = false
            end)
        end

        if not countFS._paPointHooked then
            countFS._paPointHooked = true
            hooksecurefunc(countFS, "SetPoint", function(self)
                if self._paApplyingPoint then return end
                local liveCfg = PA()
                if not liveCfg then return end
                self._paApplyingPoint = true
                self:ClearAllPoints()
                local anchor = btn.Icon or btn
                if liveCfg.stackPosition == "top" then
                    self:SetPoint("TOP", anchor, "TOP", liveCfg.stackOffsetX or 0, liveCfg.stackOffsetY or 0)
                else
                    self:SetPoint("BOTTOM", anchor, "BOTTOM", liveCfg.stackOffsetX or 0, liveCfg.stackOffsetY or 0)
                end
                self._paApplyingPoint = false
            end)
        end
    end

    -- Padding compensation (bypasses Edit Mode's 5px minimum on iconPadding).
    -- Deliberately does NOT touch AuraContainer.iconPadding or call
    -- UpdateGridLayout() -- doing so marks AuraContainer/EditModeManager
    -- itself as "addon-tainted" for the rest of the session, which broke
    -- unrelated EditMode saves (e.g. the Damage Meter window) with a
    -- "secret value" comparison error the moment EditMode's own Save/Reset
    -- pass touched anything it manages. Hooking SetPoint on the button
    -- itself (like the Duration/Count FontString hooks above) never
    -- touches AuraContainer, so it carries no such taint risk.
    --
    -- Blizzard's own grid layout re-anchors each button with x/y offsets
    -- that are cumulative multiples of a fixed "step" (icon size + its
    -- built-in 5px padding) per column/row -- e.g. observed offsets of
    -- 0, -35, -70, -105... (columns) and 0, -45, -90... (rows), NOT a
    -- single "-5" per button as originally assumed. We learn that native
    -- step per layout pass (from the smallest nonzero offset seen on each
    -- axis so far in this pass), derive each button's column/row index
    -- from its offset, then rebuild the offset using the user's desired
    -- padding instead of Blizzard's native 5px.
    --
    -- The learned step is deliberately NOT cached across passes: Edit
    -- Mode's own preview grid appears to use different native spacing
    -- than the normal in-world grid, so a step learned once and reused
    -- forever produced inconsistent results depending on which context
    -- triggered first. Instead we reset it every time we see a button
    -- anchored at (0,0) -- that's always the very first button of a
    -- fresh pass (row 1, column 1, no offset yet), a reliable pass
    -- boundary marker.
    local gridKey = isDebuff and "debuff" or "buff"
    if not btn._paPaddingHooked then
        btn._paPaddingHooked = true
        hooksecurefunc(btn, "SetPoint", function(self, point, relTo, relPoint, x, y)
            if self._paApplyingPadding then return end -- Rekursionsschutz

            local liveCfg = PA()
            if not liveCfg or not liveCfg.enabled then return end

            local step = _paGridStep[gridKey]

            if x == 0 and y == 0 then
                -- New pass starting -- forget whatever step we learned
                -- during a previous (possibly different-context) pass.
                step.x, step.y = nil, nil
                return -- nothing to compensate on the anchor button itself
            end

            -- Learn the native step from the smallest nonzero offset seen
            -- on each axis so far in this pass.
            if x and x ~= 0 then
                local ax = math.abs(x)
                if not step.x or ax < step.x then step.x = ax end
            end
            if y and y ~= 0 then
                local ay = math.abs(y)
                if not step.y or ay < step.y then step.y = ay end
            end

            -- Blizzard's OWN current padding, read live from the container
            -- (a plain read -- never written here, so no taint risk). This
            -- is normally 5 (Edit Mode's minimum) but the user can raise it
            -- higher via Blizzard's native slider; hardcoding 5 here caused
            -- our own padding to effectively stack on top of theirs
            -- whenever they'd set Edit Mode's slider above its minimum.
            local container = isDebuff and DebuffFrame and DebuffFrame.AuraContainer
                                        or BuffFrame and BuffFrame.AuraContainer
            local nativePadding = (container and container.iconPadding) or PADDING_NATIVE

            local desired = isDebuff and (liveCfg.paddingDebuffs or nativePadding)
                                       or (liveCfg.paddingBuffs or nativePadding)
            if desired == nativePadding then return end -- nothing to compensate

            local function rebuild(offset, nativeStep)
                -- Compensate this axis only if we've actually learned its
                -- native step (e.g. row 1 never has a nonzero y, so
                -- step.y stays nil for the whole row -- that's fine,
                -- offset is 0 there anyway and needs no compensation).
                if not offset or offset == 0 or not nativeStep then return offset end
                local newStep = (nativeStep - nativePadding) + desired
                local idx = math.floor(math.abs(offset) / nativeStep + 0.5)
                if idx == 0 then return offset end
                local sign = offset < 0 and -1 or 1
                return sign * idx * newStep
            end

            local newX = rebuild(x, step.x)
            local newY = rebuild(y, step.y)

            if newX ~= x or newY ~= y then
                self._paApplyingPadding = true
                self:SetPoint(point, relTo, relPoint, newX, newY)
                self._paApplyingPadding = false
            end
        end)
    end

    local anchorFrame = iconFrame or btn
    local bs = cfg.borderSize or 1
    local skipBorder = isDebuff and cfg.noBorderDebuffs
    local border = ffd._paBorder
    if not border then
        border = CreateFrame("Frame", nil, btn)
        border:EnableMouse(false)
        ffd._paBorder = border
    end
    border:SetFrameLevel(cfg.borderBehind and math.max(0, btn:GetFrameLevel() - 1) or (btn:GetFrameLevel() + 10))
    border:ClearAllPoints()
    border:SetPoint("CENTER", anchorFrame, "CENTER", 0, 0)
    border:SetSize(BLIZZARD_AURA_ICON_SIZE, BLIZZARD_AURA_ICON_SIZE)
    -- Duration/Count are direct regions on btn; a child Frame's FrameLevel
    -- always composites its entire content above ALL of the parent's own
    -- regions, regardless of draw layer/sublevel -- so border (btn's
    -- FrameLevel + 10) always wins against btn's own OVERLAY regions.
    -- Reparenting the two FontStrings onto a frame above `border` is the
    -- only way to guarantee they render on top. Same pattern as
    -- EllesmereUIBags.lua's countFS:SetParent(textOverlay).
    local textOverlay = ffd._paTextOverlay
    if not textOverlay then
        textOverlay = CreateFrame("Frame", nil, btn)
        textOverlay:SetAllPoints()
        ffd._paTextOverlay = textOverlay
    end
    textOverlay:SetFrameLevel(border:GetFrameLevel() + 1)
    if durFS and durFS.SetParent then durFS:SetParent(textOverlay) end
    if countFS and countFS.SetParent then countFS:SetParent(textOverlay) end
    local isSolidBorder = not cfg.borderTexture or cfg.borderTexture == "" or cfg.borderTexture == "solid"

    local bR, bG, bB, bA
    if isDebuff and cfg.colorBorderByDebuffType and isSolidBorder then
        bR, bG, bB, bA = GetDebuffTypeBorderColor(btn, ffd, cfg)
    else
        bR, bG, bB, bA = cfg.borderR or 0, cfg.borderG or 0, cfg.borderB or 0, cfg.borderA or 1
    end

    EllesmereUI.ApplySecretSafeBorderStyle(border, ffd,
        (bs > 0 and not skipBorder) and bs or 0,
        bR, bG, bB, bA,
        cfg.borderTexture or "solid",
        cfg.borderTextureOffset, cfg.borderTextureOffsetY,
        cfg.borderTextureShiftX, cfg.borderTextureShiftY,
        "unitframes", bs)

        ffd._paSkinned = true
    end

-------------------------------------------------------------------------------
--  Iterate and skin all visible aura buttons on a frame
-------------------------------------------------------------------------------
local function SkinAllButtons(frame, isDebuff)
    if not frame or not frame.auraFrames then return end
    for _, btn in pairs(frame.auraFrames) do
        if btn and btn.Icon and not btn.isAuraAnchor then
            SkinAuraButton(btn, isDebuff)
        end
    end
end

-------------------------------------------------------------------------------
--  Full refresh (called on setting change or UNIT_AURA)
-------------------------------------------------------------------------------
local function RefreshAll()
    if not (PA() and PA().enabled) then return end
    SkinAllButtons(BuffFrame, false)
    SkinAllButtons(DebuffFrame, true)
end
ns.RefreshPlayerAuras = RefreshAll

-------------------------------------------------------------------------------
--  Debounced refresh trigger. UpdateGridLayout can fire multiple times per
--  frame (UNIT_AURA batches, cooldown swipe updates, mouseover, etc). Without
--  this, every single firing would queue its own C_Timer.After(0, RefreshAll),
--  causing several redundant skin passes per visible frame -- which is what
--  produced the flicker/jumping text. This collapses them into exactly one.
-------------------------------------------------------------------------------
local refreshQueued = false
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        RefreshAll()
    end)
end

-------------------------------------------------------------------------------
--  Scale helper (applies iconSize via SetScale on AuraContainer)
-------------------------------------------------------------------------------
local _appliedBuffScale, _appliedDebuffScale

local function ApplyScale()
    local cfg = PA()
    if not cfg or not cfg.enabled then return end
    local nativeSize = 32
    local scale = (cfg.iconSize or nativeSize) / nativeSize

    if BuffFrame and BuffFrame.AuraContainer then
        if _appliedBuffScale ~= scale then
            BuffFrame.AuraContainer:SetScale(scale)
            _appliedBuffScale = scale
        end
    end
    if DebuffFrame and DebuffFrame.AuraContainer then
        if _appliedDebuffScale ~= scale then
            DebuffFrame.AuraContainer:SetScale(scale)
            _appliedDebuffScale = scale
        end
    end
end
ns.ApplyPlayerAuraScale = ApplyScale

-------------------------------------------------------------------------------
--  Padding helper.
--  The actual padding compensation happens per-button via the
--  hooksecurefunc(btn, "SetPoint", ...) hook registered in SkinAuraButton
--  (see PADDING_NATIVE / btn._paPaddingHooked above). That hook only fires
--  when Blizzard itself re-anchors a button, which only happens on a real
--  grid rebuild (icon count/row count changing, zone transitions, Edit
--  Mode resets) -- NOT on every simple aura tick. So a padding value
--  changing in the DB would otherwise sit invisible until the next
--  incidental rebuild.
--
--  No polling/watcher needed here: the options panel's PASet() already
--  calls ns.ApplyPlayerAuraPadding() directly on every change (same
--  pattern it uses for ns.RefreshPlayerAuras()/ns.ApplyPlayerAuraScale()),
--  so this only ever runs in direct response to an actual change, with
--  zero cost otherwise.
--
--  NOTE ON FORCING A LIVE REBUILD: toggling BuffFrame/DebuffFrame
--  visibility via Hide()/Show() was tried first and confirmed (via
--  in-game testing) to NOT force Blizzard to re-run its grid layout --
--  padding changes only became visible after a real Blizzard-triggered
--  rebuild (/reload, a zone transition, or opening/closing Edit Mode).
--  Instead, this toggles the "collapseExpandBuffs" CVar (already used
--  elsewhere in this file to control the same BuffFrame/DebuffFrame
--  layout), since Blizzard's own layout code is what reacts to that CVar
--  changing -- flipping it and flipping it back forces a real,
--  Blizzard-driven relayout pass rather than us calling any
--  AuraContainer/UpdateGridLayout method ourselves. The flip-back happens
--  on the next frame (C_Timer.After(0, ...)) rather than immediately, in
--  case Blizzard's CVAR_UPDATE handling only reacts once per frame and
--  would otherwise see the two writes cancel out with no visible effect.
--  This still needs to be confirmed in-game -- if it doesn't force a
--  rebuild either, the padding change will keep waiting for a genuine
--  Blizzard-triggered one, same as before.
-------------------------------------------------------------------------------
local function ForceAuraGridRebuild()
    local current = C_CVar.GetCVar("collapseExpandBuffs")
    if not current then return end
    local flipped = (current == "1") and "0" or "1"
    C_CVar.SetCVar("collapseExpandBuffs", flipped)
    C_Timer.After(0, function()
        C_CVar.SetCVar("collapseExpandBuffs", current)
    end)
end

local function ApplyPadding()
    local cfg = PA()
    if not cfg or not cfg.enabled then return end

    ForceAuraGridRebuild()
    RefreshAll()
end
ns.ApplyPlayerAuraPadding = ApplyPadding


-------------------------------------------------------------------------------
--  External Defensives Frame -- standalone EUI frame showing the external
--  defensive buffs currently on the player (Pain Suppression, Ironbark, ...),
--  matched by the engine's native EXTERNAL_DEFENSIVE aura filter. Cheap by
--  construction: the C side filters the enumeration (almost always zero
--  matches), the event is player-only UNIT_AURA, countdowns render through
--  the engine's Cooldown widget (no ticker, no OnUpdate), and nothing --
--  frames, font object, event registration -- exists until first enabled.
-------------------------------------------------------------------------------
local EDF_FILTER  = "HELPFUL|EXTERNAL_DEFENSIVE"
local EDF_SPACING = 4
local C_UA = C_UnitAuras
local EDF_GetAuraDuration = C_UA and C_UA.GetAuraDuration
local EDF_GetAppCount     = C_UA and C_UA.GetAuraApplicationDisplayCount
-- Classification tokens are NOT slot-fetch filters on 12.0 -- membership is
-- tested per aura instance, exactly like ns.EUIAuraFilter does for the unit
-- frame elements (fetch broad HELPFUL, then IsAuraFilteredOutByInstanceID).
local EDF_IsFilteredOut   = C_UA and C_UA.IsAuraFilteredOutByInstanceID

local edfRoot
local edfButtons = {}
local edfEvt
local edfFont
local edfIDs   = {}  -- ordered shown auraInstanceIDs
local edfIcons = {}  -- [auraInstanceID] = icon fileID

local function ED()
    local db = ns.db
    return db and db.profile and db.profile.externalDefensives
end

local function EDF_StyleButton(btn, cfg)
    local size = cfg.iconSize or 32
    btn:SetSize(size, size)
    btn:ClearAllPoints()
    -- Growth direction: the first icon pins to one edge of the frame and
    -- later icons extend toward the other.
    if (cfg.growDirection or "right") == "left" then
        btn:SetPoint("RIGHT", edfRoot, "RIGHT", -((btn._index - 1) * (size + EDF_SPACING)), 0)
    else
        btn:SetPoint("LEFT", edfRoot, "LEFT", (btn._index - 1) * (size + EDF_SPACING), 0)
    end

    local z = cfg.iconZoom or ICON_ZOOM
    btn._icon:SetTexCoord(z, 1 - z, z, 1 - z)

    local cd = btn._cd
    if cd.SetHideCountdownNumbers then
        cd:SetHideCountdownNumbers(cfg.showText == false)
    end
    -- SetCountdownFont takes the NAME of a named font object, not the object.
    if edfFont and cd.SetCountdownFont then cd:SetCountdownFont("EUI_EDF_CountdownFont") end
    -- Custom duration formats via the engine formatter (nil-guarded: on
    -- clients without it the dropdown falls back to the native format).
    if cd.SetCountdownFormatter then
        local style = cfg.durationFormat
        if style and style ~= "blizzard" then
            cd:SetCountdownFormatter(function(timeLeft)
                if type(timeLeft) ~= "number" then return end
                if issecretvalue and issecretvalue(timeLeft) then return end
                if timeLeft <= 0 then return end
                return FormatCompactDuration(timeLeft, style)
            end)
        else
            cd:SetCountdownFormatter(nil)
        end
    end

    if btn._count then
        local fontPath = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("unitFrames") or STANDARD_TEXT_FONT
        EllesmereUI.ApplyIconTextFont(btn._count, fontPath, cfg.textSize or 11, "unitFrames")
    end

    local bs = cfg.borderSize or 1
    local host = btn._borderHost
    host:SetFrameLevel(cfg.borderBehind and math.max(0, btn:GetFrameLevel() - 1) or (btn:GetFrameLevel() + 2))
    EllesmereUI.ApplyBorderStyle(host, bs,
        cfg.borderR or 0, cfg.borderG or 0, cfg.borderB or 0, cfg.borderA or 1,
        cfg.borderTexture or "solid",
        cfg.borderTextureOffset, cfg.borderTextureOffsetY,
        cfg.borderTextureShiftX, cfg.borderTextureShiftY,
        "unitframes", bs)
end

local function EDF_CreateButton(i)
    local btn = CreateFrame("Frame", nil, edfRoot)
    btn._index = i
    btn:EnableMouse(false)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    btn._icon = icon

    local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetReverse(true)
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    btn._cd = cd

    local borderHost = CreateFrame("Frame", nil, btn)
    borderHost:SetAllPoints(btn)
    borderHost:EnableMouse(false)
    btn._borderHost = borderHost

    -- Count + border live on a host above the cooldown, so the permanent-aura
    -- alpha mask on the cd (see EDF_Update) never takes them down with it.
    local txtHost = CreateFrame("Frame", nil, btn)
    txtHost:SetAllPoints()
    txtHost:SetFrameLevel(cd:GetFrameLevel() + 1)
    local cnt = txtHost:CreateFontString(nil, "OVERLAY")
    cnt:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    btn._count = cnt

    edfButtons[i] = btn
    local cfg = ED()
    if cfg then EDF_StyleButton(btn, cfg) end
    return btn
end

local function EDF_IsExternal(iid)
    return iid and EDF_IsFilteredOut
        and not EDF_IsFilteredOut("player", iid, EDF_FILTER)
end

-- Arm one button's engine-rendered pieces (duration swipe/countdown + count).
local function EDF_ArmButton(btn, iid)
    local cd = btn._cd
    if cd and EDF_GetAuraDuration then
        local durObj = EDF_GetAuraDuration("player", iid)
        if durObj and cd.SetCooldownFromDurationObject then
            cd:SetCooldownFromDurationObject(durObj)
            -- Permanent/no-duration auras return a degenerate (0,0) duration
            -- whose armed cooldown strobes; mask with alpha, never branch on
            -- the (possibly secret) IsZero.
            if durObj.IsZero and cd.SetAlphaFromBoolean then
                cd:SetAlphaFromBoolean(durObj:IsZero(), 0, 1)
            elseif cd.SetAlpha then
                cd:SetAlpha(1)
            end
        else
            cd:Clear()
        end
    end
    if btn._count then
        if EDF_GetAppCount then
            btn._count:SetText(EDF_GetAppCount("player", iid, 2, 1000) or "")
        else
            btn._count:SetText("")
        end
    end
end

local function EDF_Display()
    local n = #edfIDs
    for i = 1, n do
        local iid = edfIDs[i]
        local btn = edfButtons[i] or EDF_CreateButton(i)
        btn._icon:SetTexture(edfIcons[iid])
        EDF_ArmButton(btn, iid)
        btn:Show()
    end
    for i = n + 1, #edfButtons do edfButtons[i]:Hide() end
end

local function EDF_FullScan()
    wipe(edfIDs); wipe(edfIcons)
    if C_UA and C_UA.GetAuraSlots and C_UA.GetAuraDataBySlot then
        local slots = { C_UA.GetAuraSlots("player", "HELPFUL") }
        for i = 2, #slots do
            local aura = C_UA.GetAuraDataBySlot("player", slots[i])
            local iid = aura and aura.auraInstanceID
            if iid and EDF_IsExternal(iid) then
                edfIDs[#edfIDs + 1] = iid
                edfIcons[iid] = aura.icon
            end
        end
    end
end

-- Incremental UNIT_AURA processing: steady-state cost is proportional to the
-- CHANGE (usually one added/removed aura tested with one C call), never to
-- the player's full buff list. Full rescans only on login/full updates.
local function EDF_Update(_, _, _, updateInfo)
    local cfg = ED()
    if not (cfg and cfg.enabled and edfRoot) then return end

    if not updateInfo or updateInfo.isFullUpdate then
        EDF_FullScan()
        EDF_Display()
        return
    end

    local changed = false
    if updateInfo.addedAuras then
        for _, aura in ipairs(updateInfo.addedAuras) do
            local iid = aura.auraInstanceID
            if aura.isHelpful and iid and not edfIcons[iid] and EDF_IsExternal(iid) then
                edfIDs[#edfIDs + 1] = iid
                edfIcons[iid] = aura.icon
                changed = true
            end
        end
    end
    if updateInfo.removedAuraInstanceIDs then
        for _, iid in ipairs(updateInfo.removedAuraInstanceIDs) do
            if edfIcons[iid] then
                edfIcons[iid] = nil
                for i = #edfIDs, 1, -1 do
                    if edfIDs[i] == iid then table.remove(edfIDs, i); break end
                end
                changed = true
            end
        end
    end
    if changed then
        EDF_Display()
    elseif updateInfo.updatedAuraInstanceIDs then
        -- Refresh duration/stacks in place for tracked auras only.
        for _, iid in ipairs(updateInfo.updatedAuraInstanceIDs) do
            if edfIcons[iid] then
                for i = 1, #edfIDs do
                    if edfIDs[i] == iid then
                        local btn = edfButtons[i]
                        if btn then EDF_ArmButton(btn, iid) end
                        break
                    end
                end
            end
        end
    end
end

local function EDF_ApplyStyle()
    local cfg = ED()
    if not (cfg and edfRoot) then return end
    if edfFont then
        local fontPath = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("unitFrames") or STANDARD_TEXT_FONT
        -- Icon-text convention: forced "OUTLINE, SLUG" like every other unit
        -- frame icon text, with the global "Outline Icon Text" setting able
        -- to route this to the user's font + font outline instead.
        EllesmereUI.ApplyIconTextFont(edfFont, fontPath, cfg.textSize or 11, "unitFrames")
    end
    local size = cfg.iconSize or 32
    edfRoot:SetSize(4 * size + 3 * EDF_SPACING, size)
    for _, btn in ipairs(edfButtons) do EDF_StyleButton(btn, cfg) end
end

local function EDF_ApplyPosition()
    if not edfRoot then return end
    local cfg = ED()
    local pos = cfg and cfg.unlockPos
    edfRoot:ClearAllPoints()
    if pos and pos.point then
        edfRoot:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        edfRoot:SetPoint("CENTER", UIParent, "CENTER", 0, -220)
    end
end

local function EDF_RegisterUnlock()
    if not (EllesmereUI.RegisterUnlockElements and EllesmereUI.MakeUnlockElement) then return end
    local MK = EllesmereUI.MakeUnlockElement
    EllesmereUI:RegisterUnlockElements({
        MK({
            key      = "EUF_ExternalDefensives",
            label    = "External Defensives",
            group    = "Unit Frames",
            order    = 450,
            noResize = true,
            getFrame = function() return edfRoot end,
            getSize  = function()
                local cfg = ED()
                local size = (cfg and cfg.iconSize) or 32
                return 4 * size + 3 * EDF_SPACING, size
            end,
            isHidden = function()
                local cfg = ED()
                return not (cfg and cfg.enabled)
            end,
            savePos = function(_, point, relPoint, x, y)
                if not point then return end
                local cfg = ED(); if not cfg then return end
                cfg.unlockPos = { point = point, relPoint = relPoint or point, x = x, y = y }
                if not EllesmereUI._unlockActive then EDF_ApplyPosition() end
            end,
            loadPos = function()
                local cfg = ED()
                local pos = cfg and cfg.unlockPos
                if not pos then return nil end
                return { point = pos.point, relPoint = pos.relPoint or pos.point, x = pos.x, y = pos.y }
            end,
            clearPos = function()
                local cfg = ED()
                if cfg then cfg.unlockPos = nil end
                EDF_ApplyPosition()
            end,
            applyPos = EDF_ApplyPosition,
        }),
    }, "EllesmereUIUnitFrames")
end

-- Live enable/disable + full restyle. Zero footprint while never enabled:
-- no frames, no font object, no event registration.
local function EDF_Setup()
    local cfg = ED()
    local enabled = cfg and cfg.enabled
    if enabled and not edfRoot then
        edfRoot = CreateFrame("Frame", "EUF_ExternalDefensives", UIParent)
        edfRoot:EnableMouse(false)
        edfFont = CreateFont("EUI_EDF_CountdownFont")
        edfEvt = CreateFrame("Frame")
        edfEvt:SetScript("OnEvent", EDF_Update)
        EDF_RegisterUnlock()
    end
    if not edfRoot then return end
    if enabled then
        edfEvt:RegisterUnitEvent("UNIT_AURA", "player")
        EDF_ApplyPosition()
        EDF_ApplyStyle()
        edfRoot:Show()
        EDF_Update()
    else
        edfEvt:UnregisterEvent("UNIT_AURA")
        edfRoot:Hide()
    end
end
ns.RefreshExternalDefensives = EDF_Setup

local edfInit = CreateFrame("Frame")
edfInit:RegisterEvent("PLAYER_LOGIN")
edfInit:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    -- Same UF-db-init delay the skin below uses.
    C_Timer.After(1, EDF_Setup)
end)

-------------------------------------------------------------------------------
--  Initialization
-------------------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")

        -- Delay to let UF db initialize
        C_Timer.After(1, function()
            -- Sync the "Hide Collapsing Arrow" CVar from the (account/profile-scoped)
            -- DB on every login, on every character -- independent of the aura-skin
            -- "enabled" flag below, since this is just a Blizzard CVar toggle, not
            -- part of the reskin itself.
            do
                local cfg = PA()
                if cfg then
                    local wantHidden = cfg.hideCollapseArrow ~= false
                    local desired = wantHidden and "0" or "1"
                    if C_CVar.GetCVar("collapseExpandBuffs") ~= desired then
                        C_CVar.SetCVar("collapseExpandBuffs", desired)
                    end
                end
            end

            local cfg = PA()
            if not cfg or not cfg.enabled then return end

            -- Apply scale
            ApplyScale()

            -- Apply padding once on login (subsequent changes come straight
            -- from the options panel's PASet(), which already calls
            -- ns.ApplyPlayerAuraPadding() on every change -- see comment
            -- above ApplyPadding()).
            --
            -- One-time cleanup: an earlier build of this file persisted a
            -- "_paPaddingWatcherInstalled" flag straight into the
            -- SavedVariables profile (via rawset on cfg). That flag is
            -- dead now but harmless -- this just removes it if present so
            -- old profiles don't carry it forever.
            if cfg._paPaddingWatcherInstalled ~= nil then
                cfg._paPaddingWatcherInstalled = nil
            end
            ApplyPadding()

            -- Initial skin pass
            RefreshAll()

            -- Hook aura updates to catch new/changed buttons. This never
            -- writes to AuraContainer.iconPadding or calls UpdateGridLayout
            -- itself -- it only queues our own debounced re-skin pass, so
            -- there's no re-entrancy/recursion risk even though the hook
            -- also fires on the UpdateGridLayout calls that Blizzard's own
            -- layout logic (and, indirectly, our per-button SetPoint hook)
            -- triggers. Padding itself is no longer mirrored from
            -- AuraContainer.iconPadding -- since we never change that field
            -- anymore, it always reads back as Blizzard's native 5px, and
            -- writing it into cfg.paddingBuffs/paddingDebuffs here would
            -- immediately clobber the user's own slider value on every
            -- layout pass.
            if BuffFrame and BuffFrame.AuraContainer then
                hooksecurefunc(BuffFrame.AuraContainer, "UpdateGridLayout", function()
                    QueueRefresh()
                end)
            end
            if DebuffFrame and DebuffFrame.AuraContainer then
                hooksecurefunc(DebuffFrame.AuraContainer, "UpdateGridLayout", function()
                    QueueRefresh()
                end)
            end

            -- PLAYER_ENTERING_WORLD fires on every loading screen (zone/
            -- instance change, reload, login). Blizzard's AuraContainer can
            -- reset its scale during this transition, which is what caused
            -- the icons to visibly "jump" back to native size right after
            -- a zone change. ApplyScale() itself is cheap -- it early-outs
            -- via _appliedBuffScale/_appliedDebuffScale if nothing changed --
            -- so re-running it here on every world-enter is effectively
            -- free in the common case and only does real work when Blizzard
            -- actually reset something. QueueRefresh (already debounced) is
            -- called alongside it to catch any button skin state lost in
            -- the same rebuild.
            self:RegisterEvent("PLAYER_ENTERING_WORLD")
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        local cfg = PA()
        if not cfg or not cfg.enabled then return end
        ApplyScale()
        QueueRefresh()
    end
end)
