local ADDON_NAME = ...

BleedPredictDB = BleedPredictDB or {}
BleedPredictDB.zeroFrameLoaded = true
BleedPredictDB.loadedAddonName = ADDON_NAME

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb967ffBleedPredict:|r " .. tostring(message))
end

local function HandleSlash(input)
    input = string.lower(strtrim(input or ""))

    if input == "status" then
        Print("Zero-frame diagnostic build is active.")
        Print("No frames, events, UI, encounter tracking, combat-log tracking, or aura scanning are loaded.")
    elseif input == "blocked" then
        Print("Blocked-action capture is disabled in the zero-frame diagnostic build.")
    else
        Print("/bleedpredict status - show zero-frame diagnostic status")
        Print("/bleedpredict blocked - explain why blocked-action capture is unavailable")
    end
end

SLASH_BLEEDPREDICT1 = "/bleedpredict"
SlashCmdList.BLEEDPREDICT = HandleSlash
