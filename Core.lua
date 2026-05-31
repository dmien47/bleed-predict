local ADDON_NAME = ...

local BP = CreateFrame("Frame")

local DB_DEFAULTS = {
    debug = true,
    locked = false,
    point = { "CENTER", "CENTER", 0, 120 },
}

local SAPRISH_NAMES = {
    ["saprish"] = true,
}

local SHADOW_POUNCE_AURA_IDS = {
    [245742] = true,
}

local DETECTION_COOLDOWN_SECONDS = 2.0
local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS

local db
local loaded = false
local loggedIn = false
local blockedCount = 0

local active = false
local testMode = false
local forceShow = false
local encounterName = nil
local bossUnitSeen = false
local lastDetectionTime = 0
local lastDetectionGUID = nil

local roster = {}
local auraCache = {}
local history = {}
local auraDebugLog = {}

local frame
local titleText
local statusText
local targetsText
local historyText

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

local function IsShadowPounceAura(aura)
    if not aura then
        return false
    end

    if aura.spellId and SHADOW_POUNCE_AURA_IDS[aura.spellId] then
        return true
    end

    return aura.name and string.lower(aura.name) == "shadow pounce"
end

local function IsDisplayWanted()
    return active or forceShow
end

local function UnitIterator()
    local units = {}

    if IsInRaid() then
        for index = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. index
        end
    elseif IsInGroup() then
        units[#units + 1] = "player"
        for index = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. index
        end
    else
        units[#units + 1] = "player"
    end

    return units
end

local function UpdateRoster()
    roster = {}

    for _, unit in ipairs(UnitIterator()) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            local name = UnitName(unit)
            local _, classToken = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit)

            if guid and name then
                roster[#roster + 1] = {
                    unit = unit,
                    guid = guid,
                    name = name,
                    classToken = classToken,
                    role = role,
                    isTank = role == "TANK",
                    order = #roster + 1,
                }
            end
        end
    end
end

local function GetRosterEntry(guid)
    if not guid then
        return nil
    end

    UpdateRoster()

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
        return "instance:" .. tostring(aura.auraInstanceID)
    end

    return string.format("spell:%s:%s", tostring(aura.spellId or 0), tostring(aura.name or ""))
end

local function GetIgnoredAuraReason(aura)
    if not aura or not aura.name then
        return "missing-name"
    end

    if aura.sourceUnit and UnitIsPlayer(aura.sourceUnit) then
        return "player-source"
    end

    return nil
end

local function AddAuraDebug(message)
    auraDebugLog[#auraDebugLog + 1] = message
    if #auraDebugLog > 20 then
        table.remove(auraDebugLog, 1)
    end
    Debug(message)
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

    local names = {}
    for _, entry in ipairs(entries) do
        names[#names + 1] = ColorizeName(entry.name, entry.classToken)
    end

    return table.concat(names, "  ")
end

local function SetSavedFramePoint()
    if not frame then
        return
    end

    local point = db.point or DB_DEFAULTS.point
    frame:ClearAllPoints()
    frame:SetPoint(point[1] or "CENTER", UIParent, point[2] or "CENTER", point[3] or 0, point[4] or 120)
end

local function CreateDisplay()
    if frame then
        return
    end

    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(230, 96)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

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

    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0.05, 0.05, 0.08, 0.88)

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

local function UpdateDisplay()
    if not frame and IsDisplayWanted() then
        CreateDisplay()
    end

    if not frame then
        return
    end

    if not IsDisplayWanted() then
        frame:Hide()
        return
    end

    frame:Show()

    if testMode then
        statusText:SetText(string.format("Test mode - %d bleed%s seen", #history, #history == 1 and "" or "s"))
    elseif active then
        statusText:SetText(string.format("Saprish active - %d bleed%s seen", #history, #history == 1 and "" or "s"))
    else
        statusText:SetText("Waiting for Saprish")
    end

    targetsText:SetText(FormatEntries(GetPossibleTargets()))

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
end

local function StartTracking(reason, isTest)
    active = true
    testMode = isTest or false
    history = {}
    lastDetectionTime = 0
    lastDetectionGUID = nil
    UpdateRoster()
    SnapshotAuras()
    UpdateDisplay()
    Print(reason or "Tracking started.")
    Debug("Possible next: " .. FormatEntries(GetPossibleTargets()))
end

local function StopTracking(reason)
    active = false
    testMode = false
    history = {}
    lastDetectionTime = 0
    lastDetectionGUID = nil
    UpdateDisplay()
    Print(reason or "Tracking stopped.")
end

local function FormatAuraDebug(entry, aura, prefix)
    return string.format("%s %s aura=%s/%s source=%s duration=%s expires=%s",
        prefix or "Aura",
        ShortName(entry.name) or "unknown",
        tostring(aura and aura.name or "unknown"),
        tostring(aura and aura.spellId or "?"),
        tostring(aura and aura.sourceUnit or "nil"),
        tostring(aura and aura.duration or "nil"),
        tostring(aura and aura.expirationTime or "nil"))
end

local function RecordPounce(guid, name, source, aura)
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

    local entry = GetRosterEntry(guid)
    if entry and entry.isTank then
        Debug("Ignoring tank bleed candidate: " .. ColorizeName(entry.name, entry.classToken) .. ".")
        return
    end

    history[#history + 1] = {
        guid = guid,
        name = name or (entry and entry.name) or "Unknown",
        classToken = entry and entry.classToken,
        auraName = aura and aura.name,
        auraSpellID = aura and aura.spellId,
    }

    lastDetectionTime = now
    lastDetectionGUID = guid

    Debug(string.format("Bleed #%d detected on %s via %s%s.",
        #history,
        ColorizeName(history[#history].name, history[#history].classToken),
        source or "unknown",
        aura and (" (" .. tostring(aura.name) .. "/" .. tostring(aura.spellId or "?") .. ")") or ""))

    UpdateDisplay()
end

local function ScanForNewAuras(source)
    if not active then
        return
    end

    local candidates = {}
    local pounceCandidates = {}

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

            if isNew then
                local ignoredReason = GetIgnoredAuraReason(aura)
                local candidate = {
                    guid = guid,
                    name = entry.name,
                    aura = aura,
                }

                AddAuraDebug(FormatAuraDebug(entry, aura, ignoredReason and ("New ignored(" .. ignoredReason .. ")") or "New candidate"))

                if IsShadowPounceAura(aura) then
                    pounceCandidates[#pounceCandidates + 1] = candidate
                elseif not ignoredReason then
                    candidates[#candidates + 1] = candidate
                end
            end

            if key then
                cache[key] = true
            end
        end
    end

    if #pounceCandidates == 1 then
        local candidate = pounceCandidates[1]
        RecordPounce(candidate.guid, candidate.name, source or "Shadow Pounce aura", candidate.aura)
    elseif #pounceCandidates > 1 then
        Debug("Multiple Shadow Pounce-looking auras seen; not choosing automatically.")
    elseif #candidates == 1 then
        local candidate = candidates[1]
        RecordPounce(candidate.guid, candidate.name, source or "new harmful aura", candidate.aura)
    elseif #candidates > 1 then
        local names = {}
        for _, candidate in ipairs(candidates) do
            names[#names + 1] = string.format("%s:%s/%s",
                ShortName(candidate.name) or "unknown",
                candidate.aura.name or "unknown",
                tostring(candidate.aura.spellId or "?"))
        end
        Debug("Multiple new harmful auras seen; not choosing automatically: " .. table.concat(names, ", "))
    end
end

local function PrintCurrentAuras()
    local any = false
    for _, entry in ipairs(GetNonTanks()) do
        for index = 1, 40 do
            local aura = GetAuraData(entry.unit, index)
            if not aura then
                break
            end

            any = true
            Print(FormatAuraDebug(entry, aura, "Current"))
        end
    end

    if not any then
        Print("No harmful auras visible on non-tanks.")
    end
end

local function PrintAuraDebugLog()
    if #auraDebugLog == 0 then
        Print("No aura debug entries recorded.")
        return
    end

    for index, message in ipairs(auraDebugLog) do
        Print(index .. ": " .. message)
    end
end

local function SimulateBleed()
    if active and not testMode then
        Print("Saprish tracking is active. Use /bp stop before starting a test.")
        return
    end

    if not active then
        StartTracking("Test mode started.", true)
    end

    local candidates = GetPossibleTargets()
    if #candidates == 0 then
        Print("No non-tank candidates found.")
        return
    end

    local chosen = candidates[1]
    lastDetectionTime = 0
    RecordPounce(chosen.guid, chosen.name, "test command")
end

local function PrintRoster()
    UpdateRoster()

    if #roster == 0 then
        Print("Roster is empty.")
        return
    end

    local names = {}
    for _, entry in ipairs(roster) do
        names[#names + 1] = string.format("%s:%s", ColorizeName(entry.name, entry.classToken), entry.role or "NONE")
    end

    Print("Roster: " .. table.concat(names, ", "))
end

local function PrintBlockedActions()
    local blockedActions = db and db.blockedActions or {}
    if #blockedActions == 0 then
        Print("No blocked actions recorded by this addon.")
        return
    end

    local first = math.max(1, #blockedActions - 4)
    for index = first, #blockedActions do
        local blocked = blockedActions[index]
        Print(string.format("Blocked %d: %s addon=%s action=%s at %s",
            index,
            blocked.event or "?",
            blocked.addon or "?",
            blocked.action or "?",
            blocked.time or "?"))
    end
end

local function PrintHelp()
    Print("/bp show - show the prediction box")
    Print("/bp hide - hide the prediction box outside Saprish")
    Print("/bp lock - lock or unlock dragging")
    Print("/bp debug - toggle debug output")
    Print("/bp roster - show current group roles")
    Print("/bp auras - show current harmful non-tank auras")
    Print("/bp auradebug - show recent new aura diagnostics")
    Print("/bp status - show addon state")
    Print("/bp start - manually start aura-based tracking")
    Print("/bp stop - stop tracking")
    Print("/bp test - simulate a bleed")
    Print("/bp test stop - stop test mode")
    Print("/bp blocked - show blocked-action diagnostics")
    Print("/bp blocked clear - clear blocked-action diagnostics")
end

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "show" then
        forceShow = true
        UpdateDisplay()
        Print("Frame shown. Use /bp hide to return to Saprish-only display.")
    elseif input == "hide" then
        forceShow = false
        UpdateDisplay()
        Print("Frame will only show during Saprish tracking or /bp test.")
    elseif input == "lock" then
        db.locked = not db.locked
        Print(db.locked and "Frame locked." or "Frame unlocked. Drag it with left mouse.")
    elseif input == "debug" then
        db.debug = not db.debug
        Print(db.debug and "Debug output ON." or "Debug output OFF.")
    elseif input == "roster" then
        PrintRoster()
    elseif input == "auras" then
        PrintCurrentAuras()
    elseif input == "auradebug" then
        PrintAuraDebugLog()
    elseif input == "status" then
        Print("Loaded: " .. tostring(loaded) .. ", logged in: " .. tostring(loggedIn) .. ", active: " .. tostring(active) .. ", test: " .. tostring(testMode))
        Print("Encounter: " .. tostring(encounterName or "none") .. ", Saprish boss unit seen: " .. tostring(bossUnitSeen))
        Print("Bleeds recorded: " .. tostring(#history))
        Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
        Print("Combat-log detection is disabled; this build uses UNIT_AURA only.")
    elseif input == "start" then
        StartTracking("Manual aura-based tracking started.", false)
    elseif input == "stop" or input == "clear" then
        StopTracking("Tracking stopped.")
    elseif input == "test" then
        SimulateBleed()
    elseif input == "test stop" or input == "test clear" or input == "test reset" then
        StopTracking("Test mode stopped.")
    elseif input == "reset" then
        db.point = { "CENTER", "CENTER", 0, 120 }
        SetSavedFramePoint()
        StopTracking("Position and tracking reset.")
    elseif input == "blocked" then
        PrintBlockedActions()
    elseif input == "blocked clear" then
        if db then
            db.blockedActions = {}
        end
        blockedCount = 0
        Print("Blocked-action diagnostics cleared.")
    elseif input == "cleu on" or input == "cleu off" then
        Print("Combat-log detection is disabled because this client forbids COMBAT_LOG_EVENT_UNFILTERED registration from this addon.")
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
        db.visible = nil
        db.alwaysShow = nil
        loaded = true

    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        UpdateRoster()
        SnapshotAuras()

        SLASH_BLEEDPREDICT1 = "/bp"
        SLASH_BLEEDPREDICT2 = "/bleedpredict"
        SlashCmdList.BLEEDPREDICT = HandleSlash

        Print("Loaded. Type /bp for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "ROLE_CHANGED_INFORM" then
        UpdateRoster()
        if active then
            SnapshotAuras()
        end
        UpdateDisplay()

    elseif event == "ENCOUNTER_START" then
        local encounterID, newEncounterName = ...
        if IsSaprishName(newEncounterName) then
            encounterName = newEncounterName
            StartTracking("Saprish encounter started: " .. tostring(newEncounterName) .. " (" .. tostring(encounterID) .. ").", false)
        end

    elseif event == "ENCOUNTER_END" then
        local encounterID, endedEncounterName = ...
        if active and IsSaprishName(endedEncounterName) then
            encounterName = endedEncounterName
            StopTracking("Saprish encounter ended: " .. tostring(endedEncounterName) .. " (" .. tostring(encounterID) .. ").")
        end

    elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        for index = 1, 5 do
            local unit = "boss" .. index
            if UnitExists(unit) and IsSaprishName(UnitName(unit)) then
                bossUnitSeen = true
                if not active then
                    StartTracking("Saprish boss unit seen: " .. tostring(unit) .. ".", false)
                end
                break
            end
        end

    elseif event == "UNIT_AURA" then
        local unit = ...
        if active and unit and UnitExists(unit) then
            ScanForNewAuras("UNIT_AURA")
        end

    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local addonName, blockedFunction = ...
        BleedPredictDB = BleedPredictDB or {}
        db = BleedPredictDB
        db.blockedActions = db.blockedActions or {}
        blockedCount = blockedCount + 1
        db.blockedActions[#db.blockedActions + 1] = {
            event = event,
            addon = tostring(addonName),
            action = tostring(blockedFunction),
            time = date and date("%Y-%m-%d %H:%M:%S") or tostring(GetTime()),
        }
        Print(event .. ": addon=" .. tostring(addonName) .. " action=" .. tostring(blockedFunction) .. ". Saved for /bp blocked.")
    end
end

BP:SetScript("OnEvent", OnEvent)
BP:RegisterEvent("ADDON_LOADED")
BP:RegisterEvent("PLAYER_LOGIN")
BP:RegisterEvent("PLAYER_ENTERING_WORLD")
BP:RegisterEvent("GROUP_ROSTER_UPDATE")
BP:RegisterEvent("ROLE_CHANGED_INFORM")
BP:RegisterEvent("ENCOUNTER_START")
BP:RegisterEvent("ENCOUNTER_END")
BP:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
BP:RegisterEvent("UNIT_AURA")
BP:RegisterEvent("ADDON_ACTION_BLOCKED")
BP:RegisterEvent("ADDON_ACTION_FORBIDDEN")
