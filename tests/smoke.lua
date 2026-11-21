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
assert(out[#out].channel == "GUILD" and out[#out].text:find("^H:1:%x+:%x+$"), "login hello goes to the guild")
-- Forever: messages come from "Tester Joel" though UnitName says "Tester".
-- Our own hello echoes back from the guild and teaches us that name.
MarketplaceDB.guilds["Test Guild"] = { ["Tester Joel"] = { hash = "x", professions = {} } }
addon(out[#out].text, "GUILD", "Tester Joel")
assert(ns.Sync.selfName == "Tester Joel", "own name learned from the echo")
assert(MarketplaceDB.guilds["Test Guild"]["Tester Joel"] == nil, "a stored copy of ourselves is dropped")
out = {}
addon("H:1:abcd1234", "WHISPER", "Tester Joel")
addon("R:1", "WHISPER", "Tester Joel")
assert(#out == 0, "messages from our own name are ignored")

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
addon("H:1:" .. danHash .. ":" .. ns.Sync.code, "GUILD", "Tester Joel")
assert(#out == 0, "our own guild echo is ignored")

-- The browser window with us and Dan in the guild.
GetNumGuildMembers = function() return 2 end
GetGuildRosterInfo = function(i)
    if i == 1 then return "Dan-Mirage", "", 0, 60, "Paladin", "", "", "", true, 0, "PALADIN" end
    return "Tester Joel-Mirage", "", 0, 60, "Warrior", "", "", "", true, 0, "WARRIOR"
end
C_GuildInfo = { GuildRoster = function() end }
RAID_CLASS_COLORS = { PALADIN = { r = 0.96, g = 0.55, b = 0.73 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
C_Item = {
    GetItemNameByID = function(id) return "Item " .. id end,
    GetItemIconByID = function() return 134400 end,
    GetItemQualityByID = function() return 3 end,
    GetItemCount = function() return 1 end,
}
C_TradeSkillUI.GetRecipeLink = function(id) return "|cffffd000|Henchant:" .. id .. "|h[Recipe]|h|r" end
C_TradeSkillUI.GetTradeSkillTexture = function() return 136241 end
local told, inserted
ChatFrame_SendTell = function(name) told = name end
ChatEdit_GetActiveWindow = function() return { Insert = function(_, text) inserted = text end } end
MarketplaceDB.recipes[18238] = { name = "Spotted Yellowtail", item = 13927, reagents = { { 13754, 1 } } }

local win = _G.MarketplaceWindow
SlashCmdList.MARKETPLACE("")
assert(win.shown, "window opens")
local function visibleRows()
    local list = {}
    for _, row in ipairs(win.rows) do
        if row.shown and row.item then list[#list + 1] = row.item end
    end
    return list
end
local rows = visibleRows()
assert(#rows >= 4, "headers and recipes listed")
assert(rows[1].header and rows[1].label == "Blacksmithing", "All groups by profession, alphabetical")
local tabsShown = 0
for _, tab in ipairs(win.tabs) do if tab.shown then tabsShown = tabsShown + 1 end end
assert(tabsShown == 10, "tabs: All plus the 9 crafting professions (got " .. tabsShown .. ")")
for _, tab in ipairs(win.tabs) do if tab.title == "Alchemy" then tab.scripts.OnClick(tab) end end
assert(win.empty.text:find("Nobody in your guild has shared Alchemy yet"), "empty profession tab explains itself")
assert(win.headTitle.text == "Alchemy" and win.barText.text == "0 of 0 crafters online", "header for an empty profession")

-- Cooking tab: Dan's Spotted Yellowtail under its category.
for _, tab in ipairs(win.tabs) do if tab.title == "Cooking" then tab.scripts.OnClick(tab) end end
rows = visibleRows()
assert(rows[1].header and rows[1].label == "Fish", "Cooking groups by category")
assert(rows[2].name == "Spotted Yellowtail", "Dan's recipe listed")
assert(win.selName.text:find("Spotted Yellowtail"), "first recipe selected and shown")
assert(win.reagents[1].shown and win.reagents[1].count.text == "1/1", "reagent with have/need")
assert(win.crafters[1].name.text == "Dan", "Dan listed as crafter")
win.crafters[1].whisper.scripts.OnClick(win.crafters[1].whisper)
assert(told == "Dan" and inserted:find("Henchant:18238"), "whisper opens a tell with the recipe link")

-- Auctionator: reagent prices, mats total, sell price, shopping list.
local lists = {}
Auctionator = { API = { v1 = {
    GetVendorPriceByItemID = function() return nil end,
    GetAuctionPriceByItemID = function(_, id) return id == 13754 and 2500 or (id == 13927 and 40000 or nil) end,
    GetAuctionAgeByItemID = function() return 2 end,
    ConvertToSearchString = function(_, term) return '"' .. term.searchString .. '";;;;;;;;;;;;;;;' .. (term.quantity or "") end,
    CreateShoppingList = function(_, name, strings) lists[name] = strings end,
} } }
C_Item.GetItemCount = function() return 0 end
win.crafters[1].whisper.scripts.OnClick(win.crafters[1].whisper) -- any redraw
for _, tab in ipairs(win.tabs) do if tab.title == "Cooking" then tab.scripts.OnClick(tab) end end
-- Money shows with coin icons; spell them as letters for the asserts.
local function plain(text) return (tostring(text):gsub("|TInterface\\MoneyFrame\\UI%-(%a)%a+Icon:[^|]*|t", function(c) return c:lower() end)) end
assert(win.reagents[1].price.shown and plain(win.reagents[1].price.text) == "25s", "reagent price: " .. tostring(win.reagents[1].price.text))
assert(plain(win.costLine.text):find("Mats 25s · you're short 25s"), "mats line: " .. tostring(win.costLine.text))
assert(plain(win.sellLine.text) == "Sells for 4g · seen 2d ago", "sell line: " .. tostring(win.sellLine.text))
assert(win.shop.shown, "shopping list button when something's missing")
win.shop.scripts.OnClick(win.shop)
assert(lists["Marketplace: Spotted Yellowtail"] and lists["Marketplace: Spotted Yellowtail"][1]:find('^"Item 13754"'), "shopping list created")
C_Item.GetItemCount = function() return 1 end

-- Collapse the header, then search across everything.
win.rows[1].scripts.OnClick(win.rows[1])
rows = visibleRows()
assert(#rows == 1 and rows[1].collapsed, "header collapses")
win.rows[1].scripts.OnClick(win.rows[1])
for _, tab in ipairs(win.tabs) do if tab.title == "All professions" then tab.scripts.OnClick(tab) end end
win.search:SetText("yellowtail")
win.search.scripts.OnTextChanged(win.search)
rows = visibleRows()
assert(#rows == 2 and rows[2].name == "Spotted Yellowtail", "search narrows the list")
win.search:SetText("")
win.search.scripts.OnTextChanged(win.search)
assert(win.footer.text:find("Data from 1 of 2 guild members"), "footer coverage: " .. tostring(win.footer.text))

-- My listings: list Blacksmithing publicly, unlist a recipe, give one its own terms.
local function pub(text, channel, sender) fire("CHAT_MSG_ADDON", "MktPublic", text, channel, sender) end
local function sentPublic(pattern, channel, target)
    for _, m in ipairs(out) do
        if m.prefix == "MktPublic" and m.text:find(pattern) and (not channel or m.channel == channel) and (not target or m.target == target) then return m end
    end
end
ns.Public.Join()
win.modes.mine.scripts.OnClick(win.modes.mine)
local mine = ns.MyListings.panel
assert(mine and mine.shown and not win.browse.shown, "My listings replaces the browser")
assert(mine.profTitle.text == "Blacksmithing", "first profession selected")
assert(mine.profs[1].badge.text == "Guild only", "not listed yet")
out = {}
mine.listToggle.scripts.OnClick(mine.listToggle)
assert(MarketplaceDB.chars["Tester-Mirage"].listings[164].on, "listed publicly")
assert(mine.profs[1].badge.text == "Public", "badge updates")
local announce = sentPublic("^A:1:%x+:" .. ns.Sync.code .. "$", "CHANNEL")
assert(announce, "listing announced on the channel")
mine.defaults.fee.gold:SetText("2")
mine.defaults.fee.gold.scripts.OnTextChanged(mine.defaults.fee.gold)
assert(MarketplaceDB.chars["Tester-Mirage"].listings[164].fee == 20000, "default fee saved")
assert(mine.rows[1].terms.text:find("Bring mats"), "recipe row shows the terms: " .. mine.rows[1].terms.text)
mine.rows[2].check.scripts.OnClick(mine.rows[2].check)
assert(mine.rows[2].terms.text == "not listed", "recipe unlisted")
mine.rows[1].scripts.OnClick(mine.rows[1])
assert(mine.ovToggle.shown, "own-terms switch for a listed recipe")
mine.ovToggle.scripts.OnClick(mine.ovToggle)
local own = MarketplaceDB.chars["Tester-Mirage"].listings[164].recipes[mine.rows[1].id]
assert(type(own) == "table" and own.fee == 20000, "own terms start from the defaults")
mine.override.mats.buttons.provide.scripts.OnClick(mine.override.mats.buttons.provide)
mine.override.price.gold:SetText("450")
mine.override.price.gold.scripts.OnTextChanged(mine.override.price.gold)
assert(own.mats == "provide" and own.price == 4500000, "own terms edited")
assert(mine.rows[1].custom.shown, "row marked as having own terms")
assert(mine.footer.text:find("Listed publicly: Blacksmithing %(1%)"), "footer: " .. mine.footer.text)

-- Public: our echo is ignored, others' questions and pings are answered.
out = {}
pub(announce.text, "CHANNEL", "Tester Joel")
assert(#out == 0, "own channel echo ignored")
pub("Q:1:abcdef", "CHANNEL", "Vell Storm")
assert(sentPublic("^A:1:%x+$", "WHISPER", "Vell Storm"), "a query gets our hash by whisper")
pub("G:1", "WHISPER", "Vell Storm")
assert(sentPublic("^g:1$", "WHISPER", "Vell Storm"), "ping answered")
out = {}
pub("R:1", "WHISPER", "Vell Storm")
local d, gotListing = ns.Listings.NewDecoder()
for _, m in ipairs(out) do gotListing = d.Feed(m.text) or gotListing end
assert(gotListing and gotListing[164] and gotListing[164].custom[mine.rows[1].id].price == 4500000, "our listings go out on request")

-- Grim lists Blacksmithing; we fetch it once the Public tab opens.
local grimChar = { class = "PALADIN", professions = { [164] = { id = 164, name = "Blacksmithing", skill = 300, maxSkill = 300, recipes = { [2665] = 7 }, categories = { [7] = { name = "Weapons", parent = 0 } } } } }
grimChar.listings = { [164] = { on = true, mats = "bring", fee = 50000, recipes = {} } }
local grimLines, grimHash = ns.Listings.Encode(ns.Listings.Shareable(grimChar), "PALADIN")
out = {}
pub("A:1:" .. grimHash .. ":123456", "CHANNEL", "Grim Bolt")
assert(not sentPublic("^R:1$"), "nothing fetched before the Public tab is opened")
win.modes.public.scripts.OnClick(win.modes.public)
assert(win.browse.shown and not mine.shown, "Public shows the browser again")
assert(sentPublic("^Q:1:", "CHANNEL"), "opening Public asks the channel")
assert(sentPublic("^R:1$", "WHISPER", "Grim Bolt"), "announced listings fetched")
for _, line in ipairs(grimLines) do pub(line, "WHISPER", "Grim Bolt") end
assert(MarketplaceDB.public["Grim Bolt"] and MarketplaceDB.public["Grim Bolt"].class == "PALADIN", "Grim's listings stored")
rows = visibleRows()
local found
for _, item in ipairs(rows) do
    if not item.header and item.recipe.id == 2665 then found = item end
end
assert(found and found.total == 2, "recipe listed by us and Grim")
win.selName.text = ""
for i, row in ipairs(win.rows) do if row.item == found then row.scripts.OnClick(row) end end
local grimRow
for _, row in ipairs(win.crafters) do if row.shown and row.name.text == "Grim Bolt" then grimRow = row end end
assert(grimRow, "Grim in the crafter list")
assert(grimRow.status.text:find("Live now · Bring mats"), "Grim live with terms: " .. grimRow.status.text)
assert(grimRow.fee.text:find("5"), "Grim's fee shown: " .. grimRow.fee.text)
grimRow.whisper.scripts.OnClick(grimRow.whisper)
assert(told == "Grim Bolt" and inserted:find("Marketplace listing"), "whisper a lister")
assert(win.footer.text:find("1 player listing publicly"), "public footer: " .. win.footer.text)

-- Taking our listings down tells the channel.
win.modes.mine.scripts.OnClick(win.modes.mine)
out = {}
mine.listToggle.scripts.OnClick(mine.listToggle)
assert(sentPublic("^A:1:0:", "CHANNEL"), "unlisting announces hash 0")
pub("A:1:0", "CHANNEL", "Grim Bolt")
assert(not MarketplaceDB.public["Grim Bolt"], "Grim's listings dropped when he unlists")
win.modes.guild.scripts.OnClick(win.modes.guild)
assert(win.browse.shown and not mine.shown, "back to the guild browser")

print("smoke test passed")
