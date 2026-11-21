local ADDON, ns = ...

local DEFAULT_SETTINGS = {
    minimapButton = true,
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
    -- Recipe metadata by recipe ID: { name, icon, item, prof, cat, reagents }.
    db.recipes = db.recipes or {}
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

-- "Blacksmithing 215/300 (84 recipes), Cooking 120/150 (31 recipes)"
local function professionSummary(c)
    local parts = {}
    for _, p in pairs(c.professions or {}) do
        parts[#parts + 1] = string.format("%s %d/%d (%s)", p.name, p.skill, p.maxSkill, ns.Plural(ns.Scanner.Count(p), "recipe"))
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none yet; open a profession window to scan it"
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
    if name == ADDON then
        initDB()
        events:UnregisterEvent("ADDON_LOADED")
    end
end

function handlers.PLAYER_LOGIN()
    loadCharacter()
    ns.Theme.Load()
end

handlers.TRADE_SKILL_SHOW = function() ns.Scanner.Queue() end
handlers.TRADE_SKILL_LIST_UPDATE = handlers.TRADE_SKILL_SHOW
handlers.TRADE_SKILL_DATA_SOURCE_CHANGED = handlers.TRADE_SKILL_SHOW

for event in pairs(handlers) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)

-- Slash command -------------------------------------------------------------

local HELP = {
    "/marketplace (or /mkt) - open the browser",
    "/mkt status - what Marketplace knows about this character's professions",
    "/mkt probe - check which profession and messaging APIs this client has",
    "/mkt probe trade - with a profession window open, save its recipe data for development",
}

local COMMANDS = {
    [""] = function() ns.Window.Toggle() end,
    status = function() ns.Print("Professions: " .. professionSummary(ns.char)) end,
    probe = function(args)
        if args == "trade" then
            ns.Probe.Trade()
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
