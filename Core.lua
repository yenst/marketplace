local ADDON, ns = ...

-- Addon lifecycle: SavedVariables init, login/guild/tradeskill event wiring,
-- and /marketplace (/mkt) slash commands.
local DEFAULT_SETTINGS = {
    tooltips = true,
}

local function initDB()
    MarketplaceDB = MarketplaceDB or {}
    local db = MarketplaceDB
    db.version = 1
    db.settings = db.settings or {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        if db.settings[key] == nil then
            db.settings[key] = value
        end
    end
    -- Your own characters' recipes, by "Name-Realm".
    db.chars = db.chars or {}
    -- What guildmates shared, by guild name, then "Name-Realm".
    db.guilds = db.guilds or {}
    -- Favourite recipes (account-wide): { [recipeID] = true }.
    db.favorites = db.favorites or {}
    db.recipes = nil -- recipe metadata is now session-only; clear old saved cache
    db.public = nil  -- public listings were dropped; clear what an earlier build saved
    ns.db = db
end

-- GetRealmName() can come back empty at login (seen on WoW Forever, see
-- planTo60). Fall back to the realm this name was last seen on.
local function realmFor(name)
    local realm = GetRealmName()
    if realm and realm ~= "" then
        return realm
    end
    local best
    for _, c in pairs(ns.db.chars) do
        if c.name == name and c.realm and c.realm ~= "" and (not best or (c.lastSeen or 0) > (best.lastSeen or 0)) then
            best = c
        end
    end
    return best and best.realm or ""
end

local function loadCharacter()
    local name = UnitName("player")
    local realm = realmFor(name)
    local key = name .. "-" .. realm
    local c = ns.db.chars[key] or { professions = {} }
    ns.db.chars[key] = c
    c.name, c.realm = name, realm
    c.class = select(2, UnitClass("player"))
    c.lastSeen = time()
    ns.char = c
end

-- Once the realm is known, moves a character saved as "Name-" (blank realm
-- at login) to "Name-Realm". Scans in either entry are kept, newest first.
local function fixRealm()
    local c = ns.char
    if not c or (c.realm and c.realm ~= "") then
        return
    end
    local realm = GetRealmName()
    if not realm or realm == "" then
        return
    end
    local strayKey, key = c.name .. "-", c.name .. "-" .. realm
    local target = ns.db.chars[key]
    if target then
        target.professions = target.professions or {}
        for id, p in pairs(c.professions or {}) do
            local old = target.professions[id]
            if not old or (old.scannedAt or 0) <= (p.scannedAt or 0) then
                target.professions[id] = p
            end
        end
        target.class, target.lastSeen = c.class, c.lastSeen
    else
        target = c
        ns.db.chars[key] = c
    end
    target.realm = realm
    if ns.db.chars[strayKey] == c then
        ns.db.chars[strayKey] = nil
    end
    ns.char = target
end

-- "Blacksmithing 215/300 (84 recipes), Cooking 120/150 (31 recipes)"
local function professionSummary(c)
    local parts = {}
    for _, p in pairs(c.professions or {}) do
        parts[#parts + 1] = string.format("%s %d/%d (%s)", p.name or "?", p.skill or 0, p.maxSkill or 0, ns.Plural(ns.Scanner.Count(p), "recipe"))
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none yet; open a profession window to scan it"
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}
local helloReady = false -- the login hello's wait is over

function handlers.ADDON_LOADED(name)
    if name == ADDON then
        initDB()
        ns.Sync.Init()
        events:UnregisterEvent("ADDON_LOADED")
    end
end

-- Which guild this character is in, so its alts' recipes show in that guild.
-- Don't wipe a saved guild name while IsInGuild() is true and GetGuildInfo()
-- hasn't populated yet right after login.
local function noteGuild()
    if not ns.char then
        return
    end
    if not IsInGuild() then
        ns.char.guild = nil
    else
        local guild = GetGuildInfo("player")
        if guild and guild ~= "" then
            ns.char.guild = guild
        end
    end
end

function handlers.PLAYER_LOGIN()
    loadCharacter()
    fixRealm()
    noteGuild()
    ns.Theme.Load()
    if ns.Minimap then ns.Minimap.Init() end
    if ns.GuildTab then ns.GuildTab.Init() end
    C_Timer.After(5, fixRealm)
    ns.Sync.RequestRoster()
    -- Give the guild roster and realm name a moment before saying hello.
    C_Timer.After(10, function()
        noteGuild()
        helloReady = true
        ns.Sync.EnsureHello()
        ns.Scanner.QuietQueue(0) -- share professions without opening their windows
    end)
end

function handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
    ns.Sync.OnMessage(prefix, text, channel, sender)
end

function handlers.PLAYER_ENTERING_WORLD()
    fixRealm()
end

function handlers.PLAYER_GUILD_UPDATE()
    noteGuild()
    if ns.GuildTab then ns.GuildTab.Update() end
    if helloReady then
        ns.Sync.EnsureHello() -- joined a guild mid-session
    end
    ns.Refresh()
end

local rosterPending = false
function handlers.GUILD_ROSTER_UPDATE()
    noteGuild()
    if helloReady then
        ns.Sync.EnsureHello()
    end
    if not rosterPending then
        rosterPending = true
        C_Timer.After(0.5, function()
            rosterPending = false
            ns.Window.Refresh()
        end)
    end
end

-- Quest titles (recipe sources) load on demand.
function handlers.TRACKED_RECIPE_UPDATE()
    ns.Window.TrackingChanged()
end

function handlers.QUEST_DATA_LOAD_RESULT()
    ns.Window.ItemDataArrived()
end

function handlers.GET_ITEM_INFO_RECEIVED()
    ns.Window.ItemDataArrived()
end

-- A recipe learned: scan catalog for newly learned recipes without the window.
-- A skill change alone only checks skill/maxSkill (unless a new profession appeared).
function handlers.NEW_RECIPE_LEARNED()
    if helloReady then
        ns.Scanner.QuietQueue(2, false)
    end
end

function handlers.SKILL_LINES_CHANGED()
    if helloReady then
        ns.Scanner.QuietQueue(2, true)
    end
end

handlers.TRADE_SKILL_SHOW = function() ns.Scanner.Queue() end
handlers.TRADE_SKILL_LIST_UPDATE = handlers.TRADE_SKILL_SHOW
handlers.TRADE_SKILL_DATA_SOURCE_CHANGED = handlers.TRADE_SKILL_SHOW

for event in pairs(handlers) do
    pcall(events.RegisterEvent, events, event) -- some events don't exist on every client
end
events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)

-- Slash command -------------------------------------------------------------

local HELP = {
    "/marketplace (or /mkt) - open the browser",
    "/mkt status - what Marketplace knows about this character's professions",
    "/mkt guild - guildmates' professions received so far",
    "/mkt tooltips - show / hide guild crafters on item and pattern tooltips",
    "/mkt minimap - show / hide the minimap button",
    "/mkt debug - show / hide guild sync activity in chat",
    "/mkt probe - check which profession and messaging APIs this client has",
    "/mkt probe trade - with a profession window open, save its recipe data for development",
}

local COMMANDS = {
    [""] = function() ns.Window.Toggle() end,
    status = function() ns.Print("Professions: " .. professionSummary(ns.char)) end,
    guild = function()
        for _, line in ipairs(ns.Sync.Report()) do
            ns.Print(line)
        end
    end,
    tooltips = function()
        ns.db.settings.tooltips = not ns.db.settings.tooltips
        ns.Print("Item tooltips " .. (ns.db.settings.tooltips and "on" or "off") .. ".")
    end,
    minimap = function() ns.ToggleMinimapButton() end,
    debug = function()
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print("Sync debug output " .. (ns.db.settings.debug and "on" or "off") .. ".")
    end,
    probe = function(args)
        if args == "trade" then
            ns.Probe.Trade()
        elseif args == "resolve" then
            ns.Probe.Resolve()
        else
            ns.Probe.Run()
        end
    end,
}

SLASH_MARKETPLACE1, SLASH_MARKETPLACE2 = "/marketplace", "/mkt"
SlashCmdList.MARKETPLACE = function(input)
    local command, args = input:match("^%s*(%S*)%s*(.-)%s*$")
    local handler = COMMANDS[command:lower()]
    if handler then
        handler(args)
    else
        for _, line in ipairs(HELP) do
            ns.Print(line)
        end
    end
end
