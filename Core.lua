local ADDON_NAME = ...

local BP = CreateFrame("Frame")
local db
local loaded = false
local loggedIn = false
local blockedCount = 0
local roster = {}

local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS

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
            local _, classToken = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit)

            if name then
                roster[#roster + 1] = {
                    unit = unit,
                    name = name,
                    classToken = classToken,
                    role = role,
                }
            end
        end
    end
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

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "status" then
        Print("Event-core diagnostic build is active.")
        Print("Loaded addon token: " .. tostring(ADDON_NAME))
        Print("ADDON_LOADED seen: " .. tostring(loaded))
        Print("PLAYER_LOGIN seen: " .. tostring(loggedIn))
        Print("Blocked-action events seen: " .. tostring(blockedCount))
        Print("Roster units tracked: " .. tostring(#roster))
        Print("No UI, encounter tracking, combat-log tracking, or aura scanning is loaded.")
    elseif input == "roster" then
        PrintRoster()
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
BP:RegisterEvent("ADDON_ACTION_BLOCKED")
BP:RegisterEvent("ADDON_ACTION_FORBIDDEN")
