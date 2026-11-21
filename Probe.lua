local _, ns = ...

-- /mkt probe: reports which profession and addon-message APIs this client
-- has, and whether addon messages over a custom channel get through. Used to
-- pick the scanner and the public-listing transport per client.
local Probe = {}
ns.Probe = Probe

local PREFIX = "MktProbe"
local CHANNEL = "MktProbe" .. math.random(1000, 9999)

local function has(path)
    local value = _G
    for part in path:gmatch("[^.]+") do
        if type(value) ~= "table" then
            return false
        end
        value = value[part]
    end
    return value ~= nil
end

local function line(label, ok, extra)
    ns.Print(label .. ": " .. (ok and "|cff4dcc73yes|r" or "|cffff5c5cno|r") .. (extra and ("  " .. extra) or ""))
end

local listener
local function listen()
    if listener then
        return
    end
    listener = CreateFrame("Frame")
    listener:RegisterEvent("CHAT_MSG_ADDON")
    listener:SetScript("OnEvent", function(_, _, prefix, message, channel)
        if prefix == PREFIX then
            ns.Print("received '" .. tostring(message) .. "' over " .. tostring(channel))
        end
    end)
end

function Probe.Run()
    local version, build, _, toc = GetBuildInfo()
    ns.Print(string.format("client %s (%s), interface %s", tostring(version), tostring(build), tostring(toc)))
    line("Classic tradeskill API (GetTradeSkillInfo)", has("GetTradeSkillInfo"))
    line("Classic recipe links (GetTradeSkillRecipeLink)", has("GetTradeSkillRecipeLink"))
    line("Classic craft API (GetCraftInfo, Enchanting)", has("GetCraftInfo"))
    line("Modern tradeskill API (C_TradeSkillUI.GetAllRecipeIDs)", has("C_TradeSkillUI.GetAllRecipeIDs"))
    line("C_ChatInfo.SendAddonMessage", has("C_ChatInfo.SendAddonMessage"))

    if not has("C_ChatInfo.SendAddonMessage") then
        return
    end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    listen()
    if IsInGuild() then
        local result = C_ChatInfo.SendAddonMessage(PREFIX, "guild ping", "GUILD")
        ns.Print("GUILD send result: " .. tostring(result))
    else
        ns.Print("GUILD send: skipped (not in a guild)")
    end

    -- Join a throwaway channel, send to it, leave again a few seconds later.
    JoinTemporaryChannel(CHANNEL)
    C_Timer.After(2, function()
        local id = GetChannelName(CHANNEL)
        if not id or id == 0 then
            ns.Print("CHANNEL: couldn't join a test channel")
            return
        end
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "channel ping", "CHANNEL", id)
        ns.Print("CHANNEL send result: " .. (ok and tostring(result) or ("error: " .. tostring(result))))
        C_Timer.After(3, function()
            LeaveChannelByName(CHANNEL)
            ns.Print("probe done (no 'received ... over CHANNEL' line above means channel addon messages don't arrive)")
        end)
    end)
end
