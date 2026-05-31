local ADDON_NAME = ...

local BP = CreateFrame("Frame")
local db
local loaded = false
local loggedIn = false
local blockedCount = 0
local encounterActive = false
local encounterName = nil
local bossUnitSeen = false
local combatLogRegistered = false
local manualCombatLog = false
local shadowPounceEvents = 0
local lastShadowPounceEvent = nil
local trackingActive = false
local testMode = false
local history = {}
local roster = {}

local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS

local SAPRISH_NAMES = {
    ["saprish"] = true,
}

local SHADOW_POUNCE_SPELL_IDS = {
    [245742] = true,
}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb967ffBleedPredict:|r " .. tostring(message))
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
            local name = UnitName(unit)
            local guid = UnitGUID(unit)
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

local function IsKnownPartyGUID(guid)
    return GetRosterEntry(guid) ~= nil
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

local function StartTracking(reason, isTest)
    trackingActive = true
    testMode = isTest or false
    history = {}
    UpdateRoster()
    Print(reason or "Tracking started.")
    Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
end

local function StopTracking(reason)
    trackingActive = false
    testMode = false
    history = {}
    Print(reason or "Tracking stopped.")
end

local function RecordPounce(guid, name, source)
    local entry = GetRosterEntry(guid)
    if entry and entry.isTank then
        Print("Ignoring tank bleed candidate: " .. ColorizeName(entry.name, entry.classToken) .. ".")
        return
    end

    history[#history + 1] = {
        guid = guid,
        name = name or (entry and entry.name) or "Unknown",
        classToken = entry and entry.classToken,
    }

    Print(string.format("Bleed #%d detected on %s via %s.",
        #history,
        ColorizeName(history[#history].name, history[#history].classToken),
        source or "unknown"))
    Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
end

local function SimulateBleed()
    if trackingActive and not testMode then
        Print("Saprish tracking is active. Use /bleedpredict stop before starting a test.")
        return
    end

    if not trackingActive then
        StartTracking("Test mode started.", true)
    end

    local candidates = GetPossibleTargets()
    if #candidates == 0 then
        Print("No non-tank candidates found.")
        return
    end

    local chosen = candidates[1]
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

local function SetCombatLogRegistered(enabled, reason)
    if enabled and not combatLogRegistered then
        BP:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        combatLogRegistered = true
        Print("Combat-log diagnostics enabled" .. (reason and (" (" .. reason .. ").") or "."))
    elseif not enabled and combatLogRegistered then
        BP:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        combatLogRegistered = false
        Print("Combat-log diagnostics disabled" .. (reason and (" (" .. reason .. ").") or "."))
    end
end

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "status" then
        Print("Event-core diagnostic build is active.")
        Print("Loaded addon token: " .. tostring(ADDON_NAME))
        Print("ADDON_LOADED seen: " .. tostring(loaded))
        Print("PLAYER_LOGIN seen: " .. tostring(loggedIn))
        Print("Blocked-action events seen: " .. tostring(blockedCount))
        Print("Roster units tracked: " .. tostring(#roster))
        Print("Encounter active: " .. tostring(encounterActive) .. " " .. tostring(encounterName or ""))
        Print("Saprish boss unit seen: " .. tostring(bossUnitSeen))
        Print("Combat-log registered: " .. tostring(combatLogRegistered))
        Print("Manual combat-log mode: " .. tostring(manualCombatLog))
        Print("Tracking active: " .. tostring(trackingActive))
        Print("Test mode: " .. tostring(testMode))
        Print("Bleeds recorded: " .. tostring(#history))
        Print("Shadow Pounce combat-log events seen: " .. tostring(shadowPounceEvents))
        Print("Last Shadow Pounce event: " .. tostring(lastShadowPounceEvent or "none"))
        Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
        Print("No UI or aura scanning is loaded.")
    elseif input == "roster" then
        PrintRoster()
    elseif input == "cleu on" then
        manualCombatLog = true
        SetCombatLogRegistered(true, "manual")
    elseif input == "cleu off" then
        manualCombatLog = false
        if not encounterActive then
            SetCombatLogRegistered(false, "manual")
        else
            Print("Combat-log diagnostics remain enabled because the Saprish encounter is active.")
        end
    elseif input == "start" then
        StartTracking("Manual tracking started.", false)
        SetCombatLogRegistered(true, "manual tracking")
    elseif input == "stop" or input == "clear" then
        StopTracking("Tracking stopped.")
        if not encounterActive and not manualCombatLog then
            SetCombatLogRegistered(false, "tracking stopped")
        end
    elseif input == "test" then
        SimulateBleed()
    elseif input == "test stop" or input == "test clear" or input == "test reset" then
        StopTracking("Test mode stopped.")
    elseif input == "blocked" then
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
    else
        Print("/bleedpredict status - show event-core diagnostic status")
        Print("/bleedpredict roster - show current group roles")
        Print("/bleedpredict cleu on - manually enable combat-log diagnostics")
        Print("/bleedpredict cleu off - manually disable combat-log diagnostics")
        Print("/bleedpredict start - manually start tracking")
        Print("/bleedpredict stop - stop tracking")
        Print("/bleedpredict test - simulate a bleed")
        Print("/bleedpredict test stop - stop test mode")
        Print("/bleedpredict blocked - show blocked-action diagnostics")
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
        db.eventCoreLoaded = true
        db.loadedAddonName = ADDON_NAME
        loaded = true

    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        UpdateRoster()
        SLASH_BLEEDPREDICT1 = "/bleedpredict"
        SlashCmdList.BLEEDPREDICT = HandleSlash
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "ROLE_CHANGED_INFORM" then
        UpdateRoster()
    elseif event == "ENCOUNTER_START" then
        local encounterID, newEncounterName = ...
        if IsSaprishName(newEncounterName) then
            encounterActive = true
            encounterName = newEncounterName
            trackingActive = true
            testMode = false
            history = {}
            UpdateRoster()
            Print("Saprish encounter started: " .. tostring(newEncounterName) .. " (" .. tostring(encounterID) .. ").")
            Print("Possible next: " .. FormatEntries(GetPossibleTargets()))
            SetCombatLogRegistered(true, "Saprish encounter")
        end
    elseif event == "ENCOUNTER_END" then
        local encounterID, endedEncounterName = ...
        if encounterActive and IsSaprishName(endedEncounterName) then
            encounterActive = false
            trackingActive = false
            testMode = false
            encounterName = endedEncounterName
            Print("Saprish encounter ended: " .. tostring(endedEncounterName) .. " (" .. tostring(encounterID) .. ").")
            if not manualCombatLog then
                SetCombatLogRegistered(false, "Saprish encounter ended")
            end
        end
    elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        for index = 1, 5 do
            local unit = "boss" .. index
            if UnitExists(unit) and IsSaprishName(UnitName(unit)) then
                bossUnitSeen = true
                Print("Saprish boss unit seen: " .. tostring(unit) .. ".")
                SetCombatLogRegistered(true, "Saprish boss unit")
                break
            end
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _, spellID, spellName = CombatLogGetCurrentEventInfo()

        if IsShadowPounceSpell(spellID) then
            shadowPounceEvents = shadowPounceEvents + 1
            lastShadowPounceEvent = string.format("%s %s -> %s (%s)",
                subevent or "?",
                tostring(spellName or spellID),
                tostring(destName or "no target"),
                tostring(spellID))
            Print("Shadow Pounce combat log: " .. lastShadowPounceEvent)

            if trackingActive and (subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_DAMAGE") and IsKnownPartyGUID(destGUID) then
                RecordPounce(destGUID, destName, subevent)
            end
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
        Print(event .. ": addon=" .. tostring(addonName) .. " action=" .. tostring(blockedFunction) .. ". Saved for /bleedpredict blocked.")
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
BP:RegisterEvent("ADDON_ACTION_BLOCKED")
BP:RegisterEvent("ADDON_ACTION_FORBIDDEN")
