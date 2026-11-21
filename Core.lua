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
    ns.db = db
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
    ns.Theme.Load()
end

for event in pairs(handlers) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)

-- Slash command -------------------------------------------------------------

local HELP = {
    "/marketplace (or /mkt) - open the browser",
    "/mkt probe - check which profession and messaging APIs this client has",
    "/mkt probe trade - with a profession window open, save its recipe data for development",
}

local COMMANDS = {
    [""] = function() ns.Window.Toggle() end,
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
