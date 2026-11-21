-- Loads the whole addon against a mocked WoW API and clicks through it, to
-- catch nil errors and typos without the game. Run from the repo root:
--   lua5.1 tests/smoke.lua
date, time = os.date, os.time

-- Mock frames: any unknown method is a no-op returning nil.
local Frame = {}
local function newFrame(kind)
    return setmetatable({ scripts = {}, shown = true, text = "", kind = kind }, Frame)
end
local returns = {
    GetWidth = 500, GetHeight = 300, GetVerticalScroll = 0, GetVerticalScrollRange = 100,
    GetFont = "Fonts\\FRIZQT__.TTF", NumLines = 0,
}
Frame.__index = function(_, key)
    if returns[key] ~= nil then
        return function() return returns[key] end
    end
    return rawget(Frame, key) or function() end
end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = function(...)
        if old then old(...) end
        fn(...)
    end
end
function Frame:Fire(name, ...) if self.scripts[name] then self.scripts[name](self, ...) end end
function Frame:Show() self.shown = true; self:Fire("OnShow") end
function Frame:Hide() self.shown = false end
function Frame:SetShown(v) if v then self:Show() else self:Hide() end end
function Frame:IsShown() return self.shown end
function Frame:SetText(t) self.text = t end
function Frame:GetText() return self.text end
function Frame:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Frame:CreateTexture() return newFrame("Texture") end
function Frame:CreateFontString() return newFrame("FontString") end
function Frame:RegisterEvent(e) local ev = rawget(self, "events") or {}; rawset(self, "events", ev); ev[e] = true end
function Frame:GetItem() return "Wolf Pelt", "|cffffffff|Hitem:750::::::::30:::::|h[Wolf Pelt]|h|r" end
function Frame:AddLine(text) rawset(self, "lastLine", text) end

local allFrames = {}
function CreateFrame(kind, name, parent)
    local f = newFrame(kind)
    rawset(f, "parent", parent)
    allFrames[#allFrames + 1] = f
    if name then _G[name] = f end
    return f
end
UIParent, WorldFrame = newFrame("Frame"), newFrame("Frame")
GameTooltip = newFrame("GameTooltip")
local chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg)
    msg = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t ", "")
    chat[#chat + 1] = msg
    print("[chat] " .. msg)
end }
UISpecialFrames, SlashCmdList = {}, {}
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
tinsert, wipe = table.insert, function(t) for k in pairs(t) do t[k] = nil end return t end
C_AddOns = { IsAddOnLoaded = function() return false end }
C_Timer = { After = function(_, fn) fn() end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = function() return 0 end }
IsInGuild = function() return false end
UnitName = function() return "Tester" end
GetRealmName = function() return "Mirage" end

local ns = {}
for line in io.lines("Marketplace.toc") do
    if line:match("%.lua$") then
        assert(loadfile(line))("Marketplace", ns)
    end
end
local eventFrame
for _, f in ipairs(allFrames) do
    if rawget(f, "events") and f.events.PLAYER_LOGIN then eventFrame = f end
end
local function fire(event, ...) eventFrame.scripts.OnEvent(eventFrame, event, ...) end

UnitClass = function() return "Warrior", "WARRIOR", 1 end
-- A character saved under a blank realm (Forever sometimes reports "" at
-- login) moves to the real realm once it's known.
MarketplaceDB = { chars = { ["Tester-"] = { name = "Tester", realm = "", professions = { [185] = { id = 185, name = "Cooking", skill = 13, maxSkill = 75, scannedAt = 5, recipes = {} } } } } }
local realRealm = GetRealmName
GetRealmName = function() return "" end
fire("ADDON_LOADED", "Marketplace")
fire("PLAYER_LOGIN")
assert(MarketplaceDB.chars["Tester-"], "blank realm: stays under Tester- for now")
GetRealmName = realRealm
fire("PLAYER_ENTERING_WORLD")
assert(not MarketplaceDB.chars["Tester-"], "stray entry removed once the realm is known")
assert(MarketplaceDB.chars["Tester-Mirage"].professions[185], "its scans moved to Tester-Mirage")
assert(MarketplaceDB and MarketplaceDB.chars and MarketplaceDB.guilds, "saved data initialised")

UnitClass = function() return "Warrior", "WARRIOR", 1 end
SlashCmdList.MARKETPLACE("status")

SlashCmdList.MARKETPLACE("")
assert(_G.MarketplaceWindow and _G.MarketplaceWindow.shown, "slash command opens the window")
SlashCmdList.MARKETPLACE("")
assert(not _G.MarketplaceWindow.shown, "slash command toggles the window closed")
SlashCmdList.MARKETPLACE("help")
assert(#chat > 0, "unknown command prints help")

GetBuildInfo = function() return "1.60.1", "69893", "Nov 2026", 16001 end
IsInGuild = function() return true end
local sent = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(_, msg, kind) sent[#sent + 1] = kind; return 0 end,
}
JoinTemporaryChannel, LeaveChannelByName = function() end, function() end
GetChannelName = function() return 5 end
SlashCmdList.MARKETPLACE("probe")
assert(sent[1] == "GUILD" and sent[2] == "CHANNEL", "probe sends over guild and channel")

date = os.date
C_TradeSkillUI = {
    GetAllRecipeIDs = function() return { 2665, 3115 } end,
    GetRecipeInfo = function(id) return { recipeID = id, name = "Recipe " .. id, categoryID = 7, learned = true } end,
    GetCategoryInfo = function() return { name = "Weapons" } end,
}
SlashCmdList.MARKETPLACE("probe trade")
assert(MarketplaceDB.probe and MarketplaceDB.probe.recipeCount == 2, "trade probe saves recipes")
assert(MarketplaceDB.probe.recipes[1].category[1].name == "Weapons", "trade probe saves categories")

-- Opening a profession window scans it.
C_TradeSkillUI.IsTradeSkillReady = function() return true end
C_TradeSkillUI.GetBaseProfessionInfo = function()
    return { professionID = 164, professionName = "Blacksmithing", skillLevel = 215, maxSkillLevel = 300 }
end
fire("TRADE_SKILL_SHOW")
local me = MarketplaceDB.chars["Tester-Mirage"]
assert(me and me.professions[164], "profession window gets scanned")
assert(MarketplaceDB.recipes[2665].name == "Recipe 2665", "recipe cache filled")
SlashCmdList.MARKETPLACE("status")
assert(chat[#chat]:find("Blacksmithing 215/300 %(2 recipes%)"), "status lists the scan")

C_Spell = { GetSpellInfo = function(id) return { name = "Spell " .. id } end }
SlashCmdList.MARKETPLACE("probe resolve")
assert(MarketplaceDB.probeResolve and #MarketplaceDB.probeResolve.results > 0, "resolve probe records results")

-- Guild sync between us (Tester) and Dan, who also runs Marketplace.
GetNormalizedRealmName = function() return "Mirage" end
GetGuildInfo = function() return "Test Guild" end
local out = {}
C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
    out[#out + 1] = { prefix = prefix, text = text, channel = channel, target = target }
    return 0
end
local function addon(text, channel, sender) fire("CHAT_MSG_ADDON", "Marketplace", text, channel, sender) end
local function sentTo(target, pattern)
    for _, m in ipairs(out) do
        if m.target == target and m.text:find(pattern) then return true end
    end
end

ns.Sync.Announce(true)
assert(out[#out].channel == "GUILD" and out[#out].text:find("^H:1:%x+$"), "login hello goes to the guild")

local dan = { [185] = { id = 185, name = "Cooking", skill = 150, maxSkill = 150, scannedAt = 1, recipes = { [18238] = 2489 }, categories = { [2489] = { name = "Fish", parent = 0 } } } }
local danLines, danHash = ns.Sync.Encode(dan)
out = {}
addon("H:1:" .. danHash, "GUILD", "Dan-Mirage")
assert(sentTo("Dan-Mirage", "^R:1$"), "unknown hash: ask Dan for his recipes")
assert(sentTo("Dan-Mirage", "^H:1:"), "and tell Dan what we have")
assert(ns.Sync.seen["Dan-Mirage"], "Dan counts as running the addon")
for _, line in ipairs(danLines) do addon(line, "WHISPER", "Dan-Mirage") end
local stored = MarketplaceDB.guilds["Test Guild"]["Dan-Mirage"]
assert(stored and stored.hash == danHash and stored.professions[185].recipes[18238], "Dan's recipes are stored")

out = {}
addon("H:1:" .. danHash, "WHISPER", "Dan-Mirage")
assert(not sentTo("Dan-Mirage", "^R:1$"), "known hash: no new request")

out = {}
addon("R:1", "WHISPER", "Dan-Mirage")
local decoder, got = ns.Sync.NewDecoder()
for _, m in ipairs(out) do
    assert(m.target == "Dan-Mirage" and m.channel == "WHISPER", "our recipes go to Dan by whisper")
    got = decoder.Feed(m.text) or got
end
assert(got and got[164], "Dan gets our Blacksmithing")

SlashCmdList.MARKETPLACE("guild")
assert(chat[#chat]:find("Dan%-Mirage: Cooking 150 %(1%) · addon running"), "/mkt guild lists Dan")
SlashCmdList.MARKETPLACE("debug")
assert(MarketplaceDB.settings.debug, "debug on")
addon("H:1:" .. danHash, "WHISPER", "Dan-Mirage")
assert(chat[#chat]:find("hello from Dan%-Mirage over WHISPER %(up to date%)"), "debug shows sync activity")
SlashCmdList.MARKETPLACE("debug")

out = {}
addon("H:1:" .. danHash, "GUILD", "Tester-Mirage")
assert(#out == 0, "our own guild echo is ignored")

print("smoke test passed")
