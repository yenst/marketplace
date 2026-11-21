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

fire("ADDON_LOADED", "Marketplace")
fire("PLAYER_LOGIN")
assert(MarketplaceDB and MarketplaceDB.chars and MarketplaceDB.guilds, "saved data initialised")

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

print("smoke test passed")
