local ADDON_NAME = ...

local BP = CreateFrame("Frame")
local db
local loaded = false
local loggedIn = false
local blockedCount = 0

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb967ffBleedPredict:|r " .. tostring(message))
end

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "status" then
        Print("Event-core diagnostic build is active.")
        Print("Loaded addon token: " .. tostring(ADDON_NAME))
        Print("ADDON_LOADED seen: " .. tostring(loaded))
        Print("PLAYER_LOGIN seen: " .. tostring(loggedIn))
        Print("Blocked-action events seen: " .. tostring(blockedCount))
        Print("No UI, encounter tracking, combat-log tracking, or aura scanning is loaded.")
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
        SLASH_BLEEDPREDICT1 = "/bleedpredict"
        SlashCmdList.BLEEDPREDICT = HandleSlash
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
BP:RegisterEvent("ADDON_ACTION_BLOCKED")
BP:RegisterEvent("ADDON_ACTION_FORBIDDEN")
