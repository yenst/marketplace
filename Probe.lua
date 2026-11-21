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

-- Copies a value into plain saved data: functions become "function",
-- nesting stops at `depth`.
local function plain(value, depth)
    if type(value) == "function" then
        return "function"
    elseif type(value) ~= "table" then
        return value
    elseif depth <= 0 then
        return "table"
    end
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            out[k] = plain(v, depth - 1)
        end
    end
    return out
end

local function try(fn, ...)
    if type(fn) ~= "function" then
        return "missing"
    end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        return "error: " .. tostring(a)
    end
    return { plain(a, 4), plain(b, 4), plain(c, 4) }
end

-- /mkt probe trade, with a profession window open: saves the modern
-- tradeskill API's function list and a few sample recipes to
-- MarketplaceDB.probe (written to disk on /reload or logout).
function Probe.Trade()
    local T = C_TradeSkillUI
    if type(T) ~= "table" then
        ns.Print("C_TradeSkillUI is missing on this client")
        return
    end
    local out = { at = date("%Y-%m-%d %H:%M"), build = { GetBuildInfo() }, functions = {} }
    for name, value in pairs(T) do
        out.functions[#out.functions + 1] = name .. (type(value) == "function" and "" or (" (" .. type(value) .. ")"))
    end
    table.sort(out.functions)
    out.isTradeSkillReady = try(T.IsTradeSkillReady)
    out.baseProfession = try(T.GetBaseProfessionInfo)
    out.childProfession = try(T.GetChildProfessionInfo)
    out.tradeSkillLine = try(T.GetTradeSkillLine)
    out.isLinked = try(T.IsTradeSkillLinked)
    out.isGuild = try(T.IsTradeSkillGuild)
    local ids = type(T.GetAllRecipeIDs) == "function" and T.GetAllRecipeIDs() or {}
    out.recipeCount = #ids
    out.recipes = {}
    for i = 1, math.min(#ids, 4) do
        local id = ids[i]
        local info = type(T.GetRecipeInfo) == "function" and T.GetRecipeInfo(id) or nil
        out.recipes[i] = {
            id = id,
            info = plain(info, 3),
            link = try(T.GetRecipeLink, id),
            itemLink = try(T.GetRecipeItemLink, id),
            numReagents = try(T.GetRecipeNumReagents, id),
            reagent1 = try(T.GetRecipeReagentInfo, id, 1),
            reagentLink1 = try(T.GetRecipeReagentItemLink, id, 1),
            schematic = try(T.GetRecipeSchematic, id, false),
            category = info and info.categoryID and try(T.GetCategoryInfo, info.categoryID) or "none",
            spell = try(GetSpellInfo, id),
        }
    end
    MarketplaceDB.probe = out
    ns.Print(string.format("saved %d functions and %d of %d recipes; /reload to write them to disk",
        #out.functions, #out.recipes, #ids))
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
