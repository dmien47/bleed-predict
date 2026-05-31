local ADDON_NAME = ...

local BP = CreateFrame("Frame", "BleedPredictEventFrame")
_G.BleedPredict = BP

local DB_DEFAULTS = {
    debug = true,
    locked = false,
    visible = true,
    point = { "CENTER", "CENTER", 0, 120 },
}

local SHADOW_POUNCE_SPELL_IDS = {
    [245742] = true,
}

local SAPRISH_NAMES = {
    ["saprish"] = true,
}

local DETECTION_WINDOW_SECONDS = 2.0
local DETECTION_COOLDOWN_SECONDS = 2.0

local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS

local db
local frame
local titleText
local statusText
local targetsText
local historyText

local active = false
local pounceWindowUntil = 0
local roster = {}
local unitsByGUID = {}
local auraCache = {}
local history = {}
local lastDetectionTime = 0
local lastDetectionGUID
local pendingDamage = {}

local function CopyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            if type(value) == "table" then
                target[key] = {}
                CopyDefaults(target[key], value)
            else
                target[key] = value
            end
        elseif type(value) == "table" and type(target[key]) == "table" then
            CopyDefaults(target[key], value)
        end
    end
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb967ffBleedPredict:|r " .. tostring(message))
end

local function Debug(message)
    if db and db.debug then
        Print(message)
    end
end

local function ShortName(name)
    if not name then
        return nil
    end

    if Ambiguate then
        return Ambiguate(name, "short")
    end

    return string.match(name, "^[^-]+") or name
end

local function ColorizeName(name, classToken)
    local color = classToken and CLASS_COLORS and CLASS_COLORS[classToken]
    if not color then
        return ShortName(name) or "Unknown"
    end

    local red = math.floor((color.r or 1) * 255 + 0.5)
    local green = math.floor((color.g or 1) * 255 + 0.5)
    local blue = math.floor((color.b or 1) * 255 + 0.5)

    return string.format("|cff%02x%02x%02x%s|r", red, green, blue, ShortName(name) or "Unknown")
end

local function IsSaprishName(name)
    name = name and string.lower(name)
    return name and SAPRISH_NAMES[name]
end

local function IsShadowPounceSpell(spellID)
    return spellID and SHADOW_POUNCE_SPELL_IDS[spellID]
end

local function UnitIterator()
    local units = {}

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. i
        end
    elseif IsInGroup() then
        units[#units + 1] = "player"
        for i = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. i
        end
    else
        units[#units + 1] = "player"
    end

    return units
end

local function IsTankUnit(unit)
    return UnitGroupRolesAssigned(unit) == "TANK"
end

local function GetAuraData(unit, index)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        return C_UnitAuras.GetAuraDataByIndex(unit, index, "HARMFUL")
    end

    local name, icon, count, dispelType, duration, expirationTime, source, isStealable, nameplateShowPersonal, spellID = UnitAura(unit, index, "HARMFUL")
    if not name then
        return nil
    end

    return {
        name = name,
        icon = icon,
        applications = count,
        dispelName = dispelType,
        duration = duration,
        expirationTime = expirationTime,
        sourceUnit = source,
        isStealable = isStealable,
        nameplateShowPersonal = nameplateShowPersonal,
        spellId = spellID,
    }
end

local function AuraKey(aura)
    if not aura then
        return nil
    end

    if aura.auraInstanceID then
        return "instance:" .. aura.auraInstanceID
    end

    return string.format("spell:%s:%s", tostring(aura.spellId or 0), tostring(aura.name or ""))
end

local function IsIgnoredAura(aura)
    if not aura then
        return true
    end

    if not aura.name then
        return true
    end

    -- Player-created debuffs and self-maintenance effects are noisy during Mythic+.
    if aura.sourceUnit and UnitIsPlayer(aura.sourceUnit) then
        return true
    end

    return false
end

local function UpdateRoster()
    roster = {}
    unitsByGUID = {}

    for _, unit in ipairs(UnitIterator()) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            local name = UnitName(unit)
            local localizedClass, classToken = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit)

            if guid and name then
                local entry = {
                    unit = unit,
                    guid = guid,
                    name = name,
                    shortName = ShortName(name),
                    classToken = classToken,
                    localizedClass = localizedClass,
                    role = role,
                    isTank = role == "TANK",
                    order = #roster + 1,
                }

                roster[#roster + 1] = entry
                unitsByGUID[guid] = unit
            end
        end
    end
end

local function GetRosterEntry(guid)
    local unit = guid and unitsByGUID[guid]
    if unit and UnitExists(unit) then
        local name = UnitName(unit)
        local _, classToken = UnitClass(unit)
        return {
            unit = unit,
            guid = guid,
            name = name,
            shortName = ShortName(name),
            classToken = classToken,
            role = UnitGroupRolesAssigned(unit),
            isTank = IsTankUnit(unit),
        }
    end

    for _, entry in ipairs(roster) do
        if entry.guid == guid then
            return entry
        end
    end
end

local function GetNonTanks()
    UpdateRoster()

    local nonTanks = {}
    for _, entry in ipairs(roster) do
        if not entry.isTank then
            nonTanks[#nonTanks + 1] = entry
        end
    end

    return nonTanks
end

local function UpdateAuraCacheForUnit(unit)
    if not UnitExists(unit) then
        return
    end

    local guid = UnitGUID(unit)
    if not guid then
        return
    end

    auraCache[guid] = auraCache[guid] or {}
    local cache = auraCache[guid]

    for index = 1, 40 do
        local aura = GetAuraData(unit, index)
        if not aura then
            break
        end

        local key = AuraKey(aura)
        if key then
            cache[key] = true
        end
    end
end

local function SnapshotAuras()
    auraCache = {}

    for _, unit in ipairs(UnitIterator()) do
        UpdateAuraCacheForUnit(unit)
    end
end

local function GetHistoryIndex(guid)
    for index = #history, 1, -1 do
        if history[index].guid == guid then
            return index
        end
    end

    return 0
end

local function GetPossibleTargets()
    local nonTanks = GetNonTanks()
    local candidates = {}

    if #history < 2 then
        local alreadyChosen = {}
        for _, event in ipairs(history) do
            alreadyChosen[event.guid] = true
        end

        for _, entry in ipairs(nonTanks) do
            if not alreadyChosen[entry.guid] then
                candidates[#candidates + 1] = entry
            end
        end

        return candidates
    end

    table.sort(nonTanks, function(left, right)
        local leftIndex = GetHistoryIndex(left.guid)
        local rightIndex = GetHistoryIndex(right.guid)

        if leftIndex == rightIndex then
            return left.order < right.order
        end

        return leftIndex < rightIndex
    end)

    for index = 1, math.min(2, #nonTanks) do
        candidates[#candidates + 1] = nonTanks[index]
    end

    return candidates
end

local function FormatEntries(entries)
    if not entries or #entries == 0 then
        return "|cffaaaaaaNone known|r"
    end

    local pieces = {}
    for _, entry in ipairs(entries) do
        pieces[#pieces + 1] = ColorizeName(entry.name, entry.classToken)
    end

    return table.concat(pieces, "  ")
end

local function UpdateDisplay()
    if not frame then
        return
    end

    if db.visible then
        frame:Show()
    else
        frame:Hide()
        return
    end

    local candidates = GetPossibleTargets()
    local status

    if active then
        status = string.format("Saprish active - %d bleed%s seen", #history, #history == 1 and "" or "s")
    else
        status = "Waiting for Saprish"
    end

    statusText:SetText(status)
    targetsText:SetText(FormatEntries(candidates))

    if #history == 0 then
        historyText:SetText("|cffaaaaaaNo bleed targets detected yet|r")
    else
        local recent = {}
        local first = math.max(1, #history - 4)
        for index = first, #history do
            local event = history[index]
            recent[#recent + 1] = ColorizeName(event.name, event.classToken)
        end
        historyText:SetText("Last: " .. table.concat(recent, " > "))
    end

    local height = 92
    frame:SetHeight(height)
end

local function ResetFight(reason)
    active = false
    pounceWindowUntil = 0
    history = {}
    lastDetectionTime = 0
    lastDetectionGUID = nil
    pendingDamage = {}
    SnapshotAuras()
    UpdateDisplay()

    if reason then
        Debug(reason)
    end
end

local function StartFight(reason)
    active = true
    pounceWindowUntil = 0
    history = {}
    lastDetectionTime = 0
    lastDetectionGUID = nil
    pendingDamage = {}
    UpdateRoster()
    SnapshotAuras()
    UpdateDisplay()
    Debug(reason or "Saprish tracking started.")
end

local function RecordPounce(guid, name, source, auraName, spellID)
    if not guid then
        return
    end

    local now = GetTime()
    if now - lastDetectionTime < DETECTION_COOLDOWN_SECONDS then
        if guid == lastDetectionGUID then
            Debug("Ignoring duplicate bleed detection for " .. (ShortName(name) or "unknown") .. ".")
        else
            Debug("Ignoring conflicting bleed detection during cooldown: " .. (ShortName(name) or "unknown") .. ".")
        end
        return
    end

    if not active then
        StartFight("Saprish tracking started from Shadow Pounce detection.")
    end

    local entry = GetRosterEntry(guid)
    if entry and entry.isTank then
        Debug("Ignoring tank bleed candidate: " .. ColorizeName(entry.name, entry.classToken) .. ".")
        return
    end

    local event = {
        guid = guid,
        name = name or (entry and entry.name) or "Unknown",
        classToken = entry and entry.classToken,
        source = source,
        auraName = auraName,
        spellID = spellID,
        time = now,
    }

    history[#history + 1] = event
    lastDetectionTime = now
    lastDetectionGUID = guid
    pounceWindowUntil = 0
    pendingDamage = {}

    Debug(string.format("Bleed #%d detected on %s via %s%s.",
        #history,
        ColorizeName(event.name, event.classToken),
        source or "unknown",
        auraName and (" (" .. auraName .. ")") or ""))

    UpdateDisplay()
end

local function BeginPounceWindow(source)
    if not active then
        StartFight("Saprish tracking started from Shadow Pounce combat log.")
    end

    pounceWindowUntil = GetTime() + DETECTION_WINDOW_SECONDS
    pendingDamage = {}
    Debug("Shadow Pounce event seen; watching party debuffs for target inference.")

    C_Timer.After(0.10, function() BP:ScanForPounceAuras(source or "timed aura scan") end)
    C_Timer.After(0.35, function() BP:ScanForPounceAuras(source or "timed aura scan") end)
    C_Timer.After(0.75, function() BP:ScanForPounceAuras(source or "timed aura scan") end)
    C_Timer.After(1.25, function() BP:ScanForPounceAuras(source or "timed aura scan") end)
    C_Timer.After(DETECTION_WINDOW_SECONDS, function() BP:ResolvePendingDamage() end)
end

function BP:ScanForPounceAuras(source)
    if not active then
        return
    end

    local now = GetTime()
    local inWindow = pounceWindowUntil > now
    local candidates = {}

    for _, entry in ipairs(GetNonTanks()) do
        local unit = entry.unit
        local guid = entry.guid
        auraCache[guid] = auraCache[guid] or {}
        local cache = auraCache[guid]

        for index = 1, 40 do
            local aura = GetAuraData(unit, index)
            if not aura then
                break
            end

            local key = AuraKey(aura)
            local isNew = key and not cache[key]

            if isNew and not IsIgnoredAura(aura) then
                candidates[#candidates + 1] = {
                    guid = guid,
                    name = entry.name,
                    classToken = entry.classToken,
                    aura = aura,
                }
            end

            if key then
                cache[key] = true
            end
        end
    end

    if #candidates == 1 and (inWindow or now - lastDetectionTime > DETECTION_COOLDOWN_SECONDS) then
        local candidate = candidates[1]
        RecordPounce(candidate.guid, candidate.name, source or "new debuff fallback", candidate.aura.name, candidate.aura.spellId)
    elseif #candidates > 1 then
        local names = {}
        for _, candidate in ipairs(candidates) do
            names[#names + 1] = string.format("%s:%s/%s", ShortName(candidate.name) or "unknown", candidate.aura.name or "unknown", tostring(candidate.aura.spellId or "?"))
        end
        Debug("Multiple new harmful auras seen, not choosing automatically: " .. table.concat(names, ", "))
    end
end

function BP:ResolvePendingDamage()
    if pounceWindowUntil > GetTime() then
        return
    end

    local count = 0
    local onlyGUID
    local onlyName

    for guid, data in pairs(pendingDamage) do
        count = count + 1
        onlyGUID = guid
        onlyName = data.name
    end

    if count == 1 and GetTime() - lastDetectionTime > DETECTION_COOLDOWN_SECONDS then
        RecordPounce(onlyGUID, onlyName, "single Shadow Pounce damage event", nil, 245742)
    elseif count > 1 then
        Debug("Shadow Pounce damage hit multiple non-tanks; waiting for a debuff signal instead.")
    end

    pendingDamage = {}
end

local function IsKnownPartyGUID(guid)
    if not guid then
        return false
    end

    if not unitsByGUID[guid] then
        UpdateRoster()
    end

    return unitsByGUID[guid] ~= nil
end

local function HandleCombatLog()
    local timestamp, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _, spellID, spellName = CombatLogGetCurrentEventInfo()

    if IsShadowPounceSpell(spellID) then
        Debug(string.format("Combat log: %s %s -> %s (%s)", subevent or "?", spellName or spellID, ShortName(destName) or "no target", tostring(spellID)))

        if subevent == "SPELL_AURA_APPLIED" and IsKnownPartyGUID(destGUID) then
            RecordPounce(destGUID, destName, "Shadow Pounce aura", spellName, spellID)
            return
        end

        if (subevent == "SPELL_CAST_START" or subevent == "SPELL_CAST_SUCCESS") then
            BeginPounceWindow("Shadow Pounce combat log")
            return
        end

        if subevent == "SPELL_DAMAGE" and IsKnownPartyGUID(destGUID) then
            local entry = GetRosterEntry(destGUID)
            if entry and not entry.isTank then
                if pounceWindowUntil <= GetTime() then
                    BeginPounceWindow("Shadow Pounce damage")
                end
                pendingDamage[destGUID] = { name = destName, timestamp = timestamp }
            end
        end
    end
end

local function SetSavedFramePoint()
    local point = db.point or DB_DEFAULTS.point
    frame:ClearAllPoints()
    frame:SetPoint(point[1] or "CENTER", UIParent, point[2] or "CENTER", point[3] or 0, point[4] or 120)
end

local function CreateDisplay()
    frame = CreateFrame("Frame", "BleedPredictFrame", UIParent, "BackdropTemplate")
    frame:SetSize(210, 92)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.88)
    frame:SetBackdropBorderColor(0.55, 0.35, 0.85, 0.9)

    frame:SetScript("OnDragStart", function(self)
        if not db.locked then
            self:StartMoving()
        end
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint(1)
        db.point = { point, relativePoint, xOfs, yOfs }
    end)

    SetSavedFramePoint()

    titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", 10, -8)
    titleText:SetText("Bleed Predict")

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -5)
    statusText:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    statusText:SetJustifyH("LEFT")

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -8)
    label:SetText("Next:")

    targetsText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    targetsText:SetPoint("LEFT", label, "RIGHT", 6, 0)
    targetsText:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    targetsText:SetJustifyH("LEFT")

    historyText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    historyText:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    historyText:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    historyText:SetJustifyH("LEFT")
end

local function PrintHelp()
    Print("/bp show - show the prediction box")
    Print("/bp hide - hide the prediction box")
    Print("/bp lock - lock or unlock dragging")
    Print("/bp debug - toggle debug chat output")
    Print("/bp reset - reset position and fight history")
    Print("/bp start - manually start Saprish tracking")
    Print("/bp stop - manually stop Saprish tracking")
    Print("/bp test - simulate the next bleed using your current party roster")
    Print("/bp status - print current non-tank roster and history")
end

local function PrintStatus()
    local nonTanks = GetNonTanks()
    Print("Debug is " .. (db.debug and "ON" or "OFF") .. ". Tracking is " .. (active and "ACTIVE" or "inactive") .. ".")
    Print("Non-tanks: " .. FormatEntries(nonTanks))
    Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
end

local function SimulateBleed()
    local candidates = GetPossibleTargets()
    if #candidates == 0 then
        Print("No non-tank candidates found. Join a party or set roles, then try /bp test again.")
        return
    end

    if not active then
        StartFight("Test mode started.")
    end

    local chosen = candidates[1]
    lastDetectionTime = 0
    RecordPounce(chosen.guid, chosen.name, "test command")
end

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "show" then
        db.visible = true
        UpdateDisplay()
    elseif input == "hide" then
        db.visible = false
        UpdateDisplay()
    elseif input == "lock" then
        db.locked = not db.locked
        Print(db.locked and "Frame locked." or "Frame unlocked. Drag it with left mouse.")
    elseif input == "debug" then
        db.debug = not db.debug
        Print(db.debug and "Debug output ON." or "Debug output OFF.")
    elseif input == "reset" then
        db.point = { "CENTER", "CENTER", 0, 120 }
        SetSavedFramePoint()
        ResetFight("Position and fight history reset.")
    elseif input == "start" then
        StartFight("Manual Saprish tracking started.")
    elseif input == "stop" then
        ResetFight("Manual Saprish tracking stopped.")
    elseif input == "test" then
        SimulateBleed()
    elseif input == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= ADDON_NAME then
            return
        end

        BleedPredictDB = BleedPredictDB or {}
        db = BleedPredictDB
        CopyDefaults(db, DB_DEFAULTS)

        CreateDisplay()
        UpdateRoster()
        SnapshotAuras()
        UpdateDisplay()

        SLASH_BLEEDPREDICT1 = "/bp"
        SLASH_BLEEDPREDICT2 = "/bleedpredict"
        SlashCmdList.BLEEDPREDICT = HandleSlash

        Print("Loaded. Type /bp for commands.")
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "ROLE_CHANGED_INFORM" then
        UpdateRoster()
        SnapshotAuras()
        UpdateDisplay()
    elseif event == "ENCOUNTER_START" then
        local encounterID, encounterName = ...
        if IsSaprishName(encounterName) then
            StartFight("Encounter started: " .. tostring(encounterName) .. " (" .. tostring(encounterID) .. ").")
        end
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName = ...
        if active and IsSaprishName(encounterName) then
            ResetFight("Encounter ended: " .. tostring(encounterName) .. " (" .. tostring(encounterID) .. ").")
        end
    elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        for index = 1, 5 do
            local unit = "boss" .. index
            if UnitExists(unit) and IsSaprishName(UnitName(unit)) and not active then
                StartFight("Saprish boss unit engaged.")
                break
            end
        end
    elseif event == "UNIT_AURA" then
        local unit = ...
        if active and unit and UnitExists(unit) then
            BP:ScanForPounceAuras("new harmful aura")
        elseif unit then
            UpdateAuraCacheForUnit(unit)
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLog()
    end
end

BP:SetScript("OnEvent", OnEvent)
BP:RegisterEvent("ADDON_LOADED")
BP:RegisterEvent("PLAYER_ENTERING_WORLD")
BP:RegisterEvent("GROUP_ROSTER_UPDATE")
BP:RegisterEvent("ROLE_CHANGED_INFORM")
BP:RegisterEvent("ENCOUNTER_START")
BP:RegisterEvent("ENCOUNTER_END")
BP:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
BP:RegisterEvent("UNIT_AURA")
BP:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
