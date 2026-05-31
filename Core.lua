local ADDON_NAME = ...

local BP = CreateFrame("Frame")
local db
local loaded = false
local loggedIn = false

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
        Print("No UI, encounter tracking, combat-log tracking, aura scanning, or blocked-action hook is loaded.")
    else
        Print("/bleedpredict status - show event-core diagnostic status")
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
    end
end

BP:SetScript("OnEvent", OnEvent)
BP:RegisterEvent("ADDON_LOADED")
BP:RegisterEvent("PLAYER_LOGIN")
