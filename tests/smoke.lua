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

-- Timers run when the test says so (flush), so waits can be raced.
local timers = {}
C_Timer.After = function(_, fn) timers[#timers + 1] = fn end
local function flush()
    while #timers > 0 do
        local fn = table.remove(timers, 1)
        fn()
    end
end
local function sent(pattern)
    for _, m in ipairs(out) do
        if m.text:find(pattern) then return m end
    end
end

ns.Sync.Announce(true)
flush()
assert(#out == 1 and out[1].channel == "GUILD" and out[1].text:find("^H:2:%x+:%x+:" .. ("%x"):rep(64) .. "$"), "login hello with digest")
local hello = out[1].text
-- Forever: messages come from "Tester Joel" though UnitName says "Tester".
-- Our own hello echoes back from the guild and teaches us that name.
MarketplaceDB.guilds["Test Guild"] = { ["Tester Joel"] = { hash = "x", professions = {} } }
addon(hello, "GUILD", "Tester Joel")
assert(ns.Sync.selfName == "Tester Joel", "own name learned from the echo")
assert(MarketplaceDB.guilds["Test Guild"]["Tester Joel"] == nil, "a stored copy of ourselves is dropped")
-- The scan earlier waited for our name; now our copy goes out.
out = {}
flush()
assert(sent("^B:2:%x+:%d+:$"), "our copy, once our name is known")
out = {}
addon("R:2:Tester Joel=" .. ns.Sync.MyHash(), "GUILD", "Tester Joel")
addon("H:2:abcd1234:abcdef:" .. ("0"):rep(64), "WHISPER", "Dan-Mirage")
flush()
assert(#out == 0, "our own messages and whispers are ignored")

-- Dan broadcasts his recipes.
local dan = { [185] = { id = 185, name = "Cooking", skill = 150, maxSkill = 150, recipes = { [18238] = 2489 }, categories = { [2489] = { name = "Fish", parent = 0 } } } }
local danLines, danHash = ns.Sync.Encode(dan, nil, 1000)
for _, line in ipairs(danLines) do addon(line, "GUILD", "Dan-Mirage") end
local stored = MarketplaceDB.guilds["Test Guild"]["Dan-Mirage"]
assert(stored and stored.hash == danHash and stored.stamp == 1000 and stored.professions[185].recipes[18238], "Dan's recipes are stored")
assert(ns.Sync.seen["Dan-Mirage"], "Dan counts as running the addon")

local myHash = ns.Sync.MyHash()
local function digestOf(state) return ns.Sync.Digest(state) end
local bothKnown = { ["Dan-Mirage"] = { hash = danHash }, ["Tester Joel"] = { hash = myHash } }

-- Dan logs in knowing only himself: we say we're here and list the buckets
-- that differ (the one we're in).
out = {}
addon("H:2:" .. danHash .. ":aaaaaa:" .. digestOf({ ["Dan-Mirage"] = { hash = danHash } }), "GUILD", "Dan-Mirage")
flush()
assert(sent("^A:2:" .. myHash .. "$"), "presence reply")
local myBucket = ns.Sync.BucketOf("Tester Joel")
assert(sent("^L:2:Dan%-Mirage:" .. myBucket .. ":0:.*Tester Joel=" .. myHash .. "=%d+"), "our bucket listed for Dan")

-- Up to date: just the presence line.
out = {}
addon("H:2:" .. danHash .. ":aaaaaa:" .. digestOf(bothKnown), "GUILD", "Dan-Mirage")
flush()
assert(#out == 1 and out[1].text:find("^A:2:"), "same digest: nothing but presence")

-- Someone else lists our bucket first: we stay quiet.
out = {}
addon("H:2:" .. danHash .. ":aaaaaa:" .. digestOf({ ["Dan-Mirage"] = { hash = danHash } }), "GUILD", "Dan-Mirage")
addon("L:2:Dan-Mirage:" .. myBucket .. ":0:Tester Joel=" .. myHash .. "=1", "GUILD", "Gus-Mirage")
flush()
assert(not sent("^L:"), "someone else listed it")

-- Dan asks for our copy: one broadcast on GUILD.
out = {}
addon("R:2:Tester Joel=" .. myHash, "GUILD", "Dan-Mirage")
flush()
local decoder, got = ns.Sync.NewDecoder()
for _, m in ipairs(out) do
    assert(m.channel == "GUILD", "copies go to the guild")
    got = decoder.Feed(m.text) or got
end
assert(got and got[164], "Dan gets our Blacksmithing")

-- A list that lacks us: we send ours.
out = {}
addon("L:2:Ivy-Mirage:" .. myBucket .. ":0:", "GUILD", "Gus-Mirage")
flush()
assert(sent("^B:2:" .. myHash .. ":%d+:$"), "missing from a list: we send our copy")

-- Gus lists Eve (offline); we don't have her: ask, and take Gus's copy.
local eve = { [197] = { id = 197, name = "Tailoring", skill = 75, maxSkill = 150, recipes = { [2330] = 0 }, categories = {} } }
local eveLines, eveHash = ns.Sync.Encode(eve, "Eve-Mirage", 50)
local eveBucket = ns.Sync.BucketOf("Eve-Mirage")
out = {}
addon("L:2:Ivy-Mirage:" .. eveBucket .. ":0:Eve-Mirage=" .. eveHash .. "=50", "GUILD", "Gus-Mirage")
flush()
assert(sent("^R:2:Eve%-Mirage=" .. eveHash .. "$"), "ask the guild for Eve's copy")
for _, line in ipairs(eveLines) do addon(line, "GUILD", "Gus-Mirage") end
local eveStored = MarketplaceDB.guilds["Test Guild"]["Eve-Mirage"]
assert(eveStored and eveStored.via == "Gus-Mirage" and eveStored.professions[197].recipes[2330], "Eve's recipes stored via Gus")

-- Someone else asks first: we don't ask too.
out = {}
addon("L:2:Ivy-Mirage:" .. ns.Sync.BucketOf("Kim-Mirage") .. ":0:Kim-Mirage=1234abcd=5", "GUILD", "Gus-Mirage")
addon("R:2:Kim-Mirage=1234abcd", "GUILD", "Lou-Mirage")
flush()
assert(not sent("^R:"), "Lou already asked for Kim")

-- Older relayed copies are ignored; an old copy of us makes us send ours.
local oldEve = { [197] = { id = 197, name = "Tailoring", skill = 1, maxSkill = 75, recipes = { [2329] = 0 }, categories = {} } }
for _, line in ipairs((ns.Sync.Encode(oldEve, "Eve-Mirage", 10))) do addon(line, "GUILD", "Fenna-Mirage") end
assert(MarketplaceDB.guilds["Test Guild"]["Eve-Mirage"].hash == eveHash, "older copy ignored")
out = {}
for _, line in ipairs((ns.Sync.Encode(oldEve, "Tester Joel", 10))) do addon(line, "GUILD", "Fenna-Mirage") end
flush()
assert(not MarketplaceDB.guilds["Test Guild"]["Tester Joel"], "no relayed copy of ourselves")
assert(sent("^B:2:" .. myHash .. ":%d+:$"), "a stale copy of us going round: we send ours")
for _, line in ipairs((ns.Sync.Encode(oldEve, "Mo-Mirage", time() + 3 * 86400))) do addon(line, "GUILD", "Fenna-Mirage") end
assert(not MarketplaceDB.guilds["Test Guild"]["Mo-Mirage"], "copies stamped in the future are ignored")

-- A list lacking Eve: we'd relay her, but Kim starts first, so we don't.
out = {}
addon("L:2:Hana-Mirage:" .. eveBucket .. ":0:", "GUILD", "Gus-Mirage")
addon(eveLines[1], "GUILD", "Kim-Mirage")
flush()
assert(not sent("Eve%-Mirage"), "Kim's sending Eve: we drop ours")
-- Nobody else does: we relay her.
out = {}
addon("L:2:Hana-Mirage:" .. eveBucket .. ":0:", "GUILD", "Gus-Mirage")
flush()
local relayDecoder, relayed, relayOwner = ns.Sync.NewDecoder()
for _, m in ipairs(out) do
    local p, _, o = relayDecoder.Feed(m.text)
    if p then relayed, relayOwner = p, o end
end
assert(relayed and relayed[197] and relayOwner == "Eve-Mirage", "we relay Eve's recipes")
out = {}
addon("R:2:Eve-Mirage=" .. eveHash, "GUILD", "Hana-Mirage")
flush()
assert(sent("^B:2:" .. eveHash .. ":50:Eve%-Mirage$"), "asked for Eve: we relay her")

-- A copy already queued (but not started) is dropped when someone else
-- starts the same one first.
local throttle = true
local realSend = C_ChatInfo.SendAddonMessage
C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
    if throttle then return 3 end
    return realSend(prefix, text, channel, target)
end
out = {}
addon("L:2:Hana-Mirage:" .. eveBucket .. ":0:", "GUILD", "Gus-Mirage")
table.remove(timers, 1)() -- our wait runs out: Eve's copy is queued, throttled
addon(eveLines[1], "GUILD", "Kim-Mirage")
throttle = false
flush()
assert(not sent("Eve%-Mirage"), "queued copy dropped when Kim started first")
C_ChatInfo.SendAddonMessage = realSend

-- Someone with nothing left to share: an empty copy replaces theirs.
local pia = { [197] = { id = 197, name = "Tailoring", skill = 5, maxSkill = 75, recipes = { [2387] = 0 }, categories = {} } }
for _, line in ipairs((ns.Sync.Encode(pia, nil, 100))) do addon(line, "GUILD", "Pia-Mirage") end
assert(next(MarketplaceDB.guilds["Test Guild"]["Pia-Mirage"].professions), "Pia's recipes")
for _, line in ipairs((ns.Sync.Encode({}, nil, 200))) do addon(line, "GUILD", "Pia-Mirage") end
assert(not next(MarketplaceDB.guilds["Test Guild"]["Pia-Mirage"].professions), "Pia dropped her profession")
flush()

-- A new scan: one broadcast; nothing again until it changes.
out = {}
ns.Sync.Announce()
flush()
assert(#out == 0, "unchanged since our last copy: nothing sent")
me.professions[164].recipes[9999] = 7
ns.Sync.Announce()
ns.Sync.Announce()
flush()
local copies = 0
for _, m in ipairs(out) do if m.text:find("^B:") then copies = copies + 1 end end
assert(copies == 1, "changed recipes: one copy to the guild")
me.professions[164].recipes[9999] = nil
myHash = ns.Sync.MyHash()

-- Periodic check: Dan's digest matched ours a moment ago, so none is due;
-- 20 minutes later one is, until someone's digest matches again.
out = {}
ns.Sync.Check()
assert(#out == 0, "a digest matched ours recently: no check")
local realTime = time
time = function() return realTime() + 1200 end
ns.Sync.Check()
flush() -- after a random wait
assert(sent("^D:2:%x+$"), "periodic digest check")
out = {}
local full = { ["Dan-Mirage"] = { hash = danHash }, ["Tester Joel"] = { hash = myHash }, ["Eve-Mirage"] = { hash = eveHash }, ["Pia-Mirage"] = { hash = ns.Sync.Hash({}) } }
addon("D:2:" .. digestOf(full), "GUILD", "Dan-Mirage")
flush()
ns.Sync.Check()
flush()
assert(#out == 0, "someone's digest matched ours: no check needed")
time = realTime
C_Timer.After = function(_, fn) fn() end

SlashCmdList.MARKETPLACE("guild")
assert(chat[#chat - 1]:find("Dan%-Mirage: Cooking 150 %(1%) · addon running"), "/mkt guild lists Dan")
assert(chat[#chat]:find("Eve%-Mirage: Tailoring 75 %(1%) · not seen this session · via Gus%-Mirage"), "and Eve, relayed by Gus")
SlashCmdList.MARKETPLACE("debug")
assert(MarketplaceDB.settings.debug, "debug on")
addon("H:2:" .. danHash .. ":aaaaaa:" .. digestOf(full), "GUILD", "Dan-Mirage")
local shown
for i = #chat - 3, #chat do if chat[i] and chat[i]:find("hello from Dan%-Mirage") then shown = true end end
assert(shown, "debug shows sync activity")
SlashCmdList.MARKETPLACE("debug")

out = {}
addon(hello, "GUILD", "Tester Joel")
assert(#out == 0, "our own guild echo is ignored")

-- The browser window with us and Dan in the guild.
GetNumGuildMembers = function() return 3 end
GetGuildRosterInfo = function(i)
    if i == 1 then return "Dan-Mirage", "", 0, 60, "Paladin", "", "", "", true, 0, "PALADIN" end
    if i == 3 then return "Eve-Mirage", "", 0, 40, "Mage", "", "", "", false, 0, "MAGE" end
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

CLASS_ICON_TCOORDS = { PALADIN = { 0.5, 0.75, 0.5, 0.75 }, WARRIOR = { 0, 0.25, 0, 0.25 } }
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
assert(win.headTitle.text == "Alchemy" and win.barText.text:find("^0 of %d+ patterns unlocked$"), "header: " .. win.barText.text)
-- Nobody has Alchemy: its whole catalog sits under a collapsed group.
rows = visibleRows()
assert(#rows == 1 and rows[1].header and rows[1].label == "Not in your guild" and rows[1].collapsed and rows[1].count > 100,
    "recipes nobody has, collapsed")
C_Map = { GetAreaInfo = function(area) return "Zone " .. area end }
UnitFactionGroup = function() return "Alliance" end
win.rows[1].scripts.OnClick(win.rows[1])
rows = visibleRows()
assert(not rows[1].collapsed and rows[2].total == 0 and rows[2].skill <= rows[3].skill, "expanded, lowest skill first")
assert(win.rows[2].count.text == "Skill " .. rows[2].skill, "skill instead of crafters")
win.rows[2].scripts.OnClick(win.rows[2])
assert(win.nobody.shown, "nobody knows it")
assert(win.sourceText.text ~= "", "where to learn it")
assert(win.sourceSkill.text == "Skill " .. rows[2].skill, "required skill")
win.rows[1].scripts.OnClick(win.rows[1]) -- collapse it again

-- Cooking tab: Dan's Spotted Yellowtail under its category.
for _, tab in ipairs(win.tabs) do if tab.title == "Cooking" then tab.scripts.OnClick(tab) end end
rows = visibleRows()
assert(rows[1].header and rows[1].label == "Fish", "Cooking groups by category")
assert(rows[2].name == "Spotted Yellowtail", "Dan's recipe listed")
assert(win.selName.text:find("Spotted Yellowtail"), "first recipe selected and shown")
assert(win.reagents[1].shown and win.reagents[1].count.text == "1/1", "reagent with have/need")
assert(win.crafters[1].name.text == "Dan", "Dan listed as crafter")
assert(not win.nobody.shown, "has crafters")
assert(win.crafters[1].class.shown, "class icon next to Dan")
assert(win.sourceText.text:find("Vendor") and win.sourceText.text:find("Zone 440"), "sold in Tanaris: " .. win.sourceText.text)
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
assert(plain(win.stats.mats.value.text) == "25s", "mats tile: " .. tostring(win.stats.mats.value.text))
assert(plain(win.stats.short.value.text):find("25s"), "short tile: " .. tostring(win.stats.short.value.text))
assert(plain(win.stats.sells.value.text) == "4g" and win.stats.sells.label.text == "Sells for · 2d ago", "sells tile")
assert(win.stats.sells.tipText:find("Profit over the mats: 3g 75s") or plain(win.stats.sells.tipText):find("Profit over the mats: 3g 75s"), "profit in tooltip: " .. plain(win.stats.sells.tipText))
assert(win.shop.shown, "shopping list button when something's missing")
win.shop.scripts.OnClick(win.shop)
assert(lists["Marketplace: Spotted Yellowtail"] and lists["Marketplace: Spotted Yellowtail"][1]:find('^"Item 13754"'), "shopping list created")
C_Item.GetItemCount = function() return 1 end

-- Collapse the header, then search across everything.
win.rows[1].scripts.OnClick(win.rows[1])
rows = visibleRows()
assert(#rows == 2 and rows[1].collapsed and rows[2].label == "Not in your guild", "header collapses")
win.rows[1].scripts.OnClick(win.rows[1])
for _, tab in ipairs(win.tabs) do if tab.title == "All professions" then tab.scripts.OnClick(tab) end end
win.search:SetText("yellowtail")
win.search.scripts.OnTextChanged(win.search)
rows = visibleRows()
assert(#rows == 2 and rows[2].name == "Spotted Yellowtail", "search narrows the list")
win.search:SetText("")
win.search.scripts.OnTextChanged(win.search)
assert(win.footer.text:find("Data from 2 of 3 guild members"), "footer coverage: " .. tostring(win.footer.text))

-- Favourites: right-click a recipe, it moves under "Favorites" at the top.
for _, tab in ipairs(win.tabs) do if tab.title == "Cooking" then tab.scripts.OnClick(tab) end end
rows = visibleRows()
win.rows[2].scripts.OnClick(win.rows[2], "RightButton")
assert(MarketplaceDB.favorites[18238], "favourite saved")
rows = visibleRows()
assert(rows[1].header and rows[1].label == "Favorites" and rows[2].name == "Spotted Yellowtail", "favourites listed first")
win.favorite.scripts.OnClick(win.favorite)
assert(not MarketplaceDB.favorites[18238], "star in the details removes it again")
assert(visibleRows()[1].label == "Fish", "back in its category")

-- Member filter: pick Dan from the dropdown, then clear it again.
win.member.scripts.OnClick(win.member)
assert(win.memberMenu.shown and win.memberMenu.rows[1].label.text == "All members", "member menu")
local danRow
for _, row in ipairs(win.memberMenu.rows) do if row.shown and row.label.text == "Dan" then danRow = row end end
assert(danRow and danRow.count.text == "1", "Dan in the menu with 1 pattern here")
assert(danRow.class.shown and not win.memberMenu.rows[1].class.shown, "class icons in the member menu, none for All members")
danRow.scripts.OnClick(danRow)
assert(not win.memberMenu.shown and win.member.text.text == "Dan", "filtered to Dan")
assert(win.barText.text:find("^Dan knows 1 of %d+ patterns$"), "header: " .. win.barText.text)
for _, item in ipairs(visibleRows()) do
    assert(item.header or item.recipe.id == 18238, "only Dan's patterns")
end
win.member.scripts.OnClick(win.member)
win.memberMenu.rows[1].scripts.OnClick(win.memberMenu.rows[1])
assert(win.member.text.text == "All members", "filter cleared")
-- Clicking a crafter's name in the details filters to them too.
win.crafters[1].pick.scripts.OnClick(win.crafters[1].pick)
assert(win.member.text.text == "Dan", "crafter name filters")
win.member.scripts.OnClick(win.member)
win.memberMenu.rows[1].scripts.OnClick(win.memberMenu.rows[1])

-- Modified clicks: the crafted item (shift links, ctrl previews), its
-- reagents, and the recipe pattern.
local clicked, dressed = {}, {}
local modifier = "CHATLINK"
IsModifiedClick = function(kind) return kind == modifier end
C_Item.GetItemInfo = function(id) return "Item " .. id, "|cffffffff|Hitem:" .. id .. "::::::::|h[Item " .. id .. "]|h|r" end
ChatEdit_InsertLink = function(link) clicked[#clicked + 1] = link return true end
DressUpItemLink = function(link) dressed[#dressed + 1] = link end
win.selTile.scripts.OnMouseUp(win.selTile)
win.reagents[1].scripts.OnMouseUp(win.reagents[1])
win.source.scripts.OnMouseUp(win.source)
assert(clicked[1]:find("|Hitem:13927:") and clicked[2]:find("|Hitem:13754:") and clicked[3]:find("|Hitem:13939:"),
    "item, reagent and pattern linked: " .. table.concat(clicked, " "))
modifier = "DRESSUP"
win.selTile.scripts.OnMouseUp(win.selTile)
assert(dressed[1] and dressed[1]:find("|Hitem:13927:"), "ctrl-click previews the item")
-- Not loaded yet: the link goes in once the item has loaded, never as "item:123".
modifier = "CHATLINK"
C_Item.GetItemInfo = function() return nil end
local waiting
Item = { CreateFromItemID = function(_, id)
    return { ContinueOnItemLoad = function(_, fn) waiting = fn end,
             GetItemLink = function() return "|cffffffff|Hitem:" .. id .. "::::::::|h[Item " .. id .. "]|h|r" end }
end }
clicked = {}
win.selTile.scripts.OnMouseUp(win.selTile)
assert(#clicked == 0 and waiting, "waits for the item")
waiting()
assert(clicked[1] and clicked[1]:find("|Hitem:13927:"), "then links the real item")
Item, IsModifiedClick = nil, nil

-- The Guild & Communities window (loaded on demand) gets a Marketplace tab.
CommunitiesFrame = CreateFrame("Frame", "CommunitiesFrame")
CommunitiesFrame.GuildInfoTab = CreateFrame("CheckButton")
for _, f in ipairs(allFrames) do
    if rawget(f, "events") and f.events.ADDON_LOADED and f ~= eventFrame then
        f.scripts.OnEvent(f, "ADDON_LOADED", "Blizzard_Communities")
    end
end
assert(ns.guildTab and ns.guildTab.shown, "guild window tab")
win:Hide()
ns.guildTab.scripts.OnClick(ns.guildTab)
assert(win.shown, "the tab opens Marketplace")

print("smoke test passed")
