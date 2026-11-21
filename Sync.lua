local _, ns = ...

-- Guild sync over hidden addon messages.
--
--   H:1:<hash>   "this is what I have" — to GUILD at login and after a scan
--                that changed something; by WHISPER back to a newcomer.
--   R:1          "send me your recipes" — WHISPER, when a hash is new to us.
--   B:1:<hash>, P:…, C:…, I:…, E:<hash>
--                the recipes themselves, by WHISPER, in lines under 255 bytes.
--
-- Only recipe and category IDs travel: every client can look up a recipe's
-- name, icon and reagents from its ID (checked on Forever with /mkt probe
-- resolve). Category names are sent once per profession.
local Sync = {}
ns.Sync = Sync

Sync.PREFIX = "Marketplace"
Sync.VERSION = "1"
local MAX_LINE = 250

-- Codec ---------------------------------------------------------------------

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- Names travel inside ':'/';'/'='/',' separated lines.
local function clean(text)
    return (tostring(text or ""):gsub("[:;=,]", " "))
end

-- Fingerprint of everything that's shared: professions, skills, recipe IDs.
function Sync.Hash(professions)
    local parts = {}
    for _, id in ipairs(sortedKeys(professions)) do
        local p = professions[id]
        parts[#parts + 1] = id .. "/" .. (p.skill or 0) .. "/" .. (p.maxSkill or 0)
        for _, recipe in ipairs(sortedKeys(p.recipes)) do
            parts[#parts + 1] = tostring(recipe)
        end
    end
    local text, h = table.concat(parts, ","), 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- Only professions with something to craft are shared (not Fishing etc.).
function Sync.Shareable(professions)
    local out = {}
    for id, p in pairs(professions or {}) do
        if next(p.recipes or {}) then
            out[id] = p
        end
    end
    return out
end

-- Appends "<head><item><sep><item>…" lines, each at most MAX_LINE bytes.
local function chunk(lines, head, items, sep)
    local line, count = head, 0
    for _, item in ipairs(items) do
        if count > 0 and #line + #sep + #item > MAX_LINE then
            lines[#lines + 1] = line
            line, count = head, 0
        end
        line = line .. (count > 0 and sep or "") .. item
        count = count + 1
    end
    if count > 0 then
        lines[#lines + 1] = line
    end
end

function Sync.Encode(professions)
    local hash = Sync.Hash(professions)
    local lines = { "B:" .. Sync.VERSION .. ":" .. hash }
    for _, id in ipairs(sortedKeys(professions)) do
        local p = professions[id]
        lines[#lines + 1] = string.format("P:%d:%d:%d:%d:%s", id, p.skill or 0, p.maxSkill or 0, p.scannedAt or 0, clean(p.name))
        local cats = {}
        for _, cat in ipairs(sortedKeys(p.categories)) do
            local c = p.categories[cat]
            cats[#cats + 1] = cat .. "=" .. (c.parent or 0) .. "=" .. clean(c.name)
        end
        chunk(lines, "C:" .. id .. ":", cats, ";")
        local recipes = {}
        for _, recipe in ipairs(sortedKeys(p.recipes)) do
            recipes[#recipes + 1] = recipe .. "." .. (p.recipes[recipe] or 0)
        end
        chunk(lines, "I:" .. id .. ":", recipes, ",")
    end
    lines[#lines + 1] = "E:" .. hash
    return lines, hash
end

-- Collects one sender's B…E lines. Feed returns (professions, hash) once a
-- complete, matching transfer has arrived; nil otherwise.
function Sync.NewDecoder()
    local pending
    local decoder = {}
    function decoder.Feed(line)
        local kind, rest = line:match("^(%u):(.*)$")
        if kind == "B" then
            local version, hash = rest:match("^(%d+):(%x+)$")
            pending = version == Sync.VERSION and { hash = hash, professions = {} } or nil
        elseif not pending then
            return nil
        elseif kind == "P" then
            local id, skill, maxSkill, at, name = rest:match("^(%d+):(%d+):(%d+):(%d+):(.*)$")
            if id then
                pending.professions[tonumber(id)] = {
                    id = tonumber(id), name = name, skill = tonumber(skill), maxSkill = tonumber(maxSkill),
                    scannedAt = tonumber(at), recipes = {}, categories = {},
                }
            end
        elseif kind == "C" or kind == "I" then
            local id, list = rest:match("^(%d+):(.*)$")
            local p = id and pending.professions[tonumber(id)]
            if p and kind == "C" then
                for cat, parent, name in list:gmatch("(%d+)=(%d+)=([^;]*)") do
                    p.categories[tonumber(cat)] = { name = name, parent = tonumber(parent) }
                end
            elseif p then
                for recipe, cat in list:gmatch("(%d+)%.(%d+)") do
                    p.recipes[tonumber(recipe)] = tonumber(cat)
                end
            end
        elseif kind == "E" then
            local done = pending
            pending = nil
            if done and rest == done.hash and Sync.Hash(done.professions) == done.hash then
                return done.professions, done.hash
            end
        end
        return nil
    end
    return decoder
end

-- Transport -----------------------------------------------------------------

-- Who has talked to us this session (= is running Marketplace), by full name.
Sync.seen = {}

local function debug(msg)
    if ns.db and ns.db.settings.debug then
        ns.Print("|cff8c949fsync:|r " .. msg)
    end
end

local queue, pumping = {}, false

-- Sends queued lines a few per second; a throttled send is retried.
local function pump()
    local item = queue[1]
    if not item then
        pumping = false
        return
    end
    local result = C_ChatInfo.SendAddonMessage(Sync.PREFIX, item.text, item.channel, item.target)
    local codes = Enum and Enum.SendAddonMessageResult or {}
    local throttled = result == (codes.AddonMessageThrottle or 3) or result == (codes.ChannelThrottle or 8)
    if not throttled then
        table.remove(queue, 1)
    end
    C_Timer.After(0.25, pump)
end

local function send(text, channel, target)
    queue[#queue + 1] = { text = text, channel = channel, target = target }
    if not pumping then
        pumping = true
        pump()
    end
end

local function myShare()
    return Sync.Shareable(ns.char and ns.char.professions)
end

function Sync.MyHash()
    return Sync.Hash(myShare())
end

-- Forever reports "Billy" from UnitName but messages arrive from "Billy Joel",
-- so names can't tell us apart from others. Our guild hellos carry a random
-- per-session code instead; the echo that comes back with it is us, and its
-- sender is the name everyone else sees.
Sync.code = string.format("%06x", math.random(0, 16777215))
Sync.selfName = nil

local function isMe(sender)
    if Sync.selfName then
        return sender == Sync.selfName
    end
    local name, realm = UnitName("player"), GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" then
        return sender == name .. "-" .. realm or sender == name
    end
    return (sender:match("^[^-]+")) == name
end

-- Our own guild hello came back: remember the name it came from.
local function learnSelf(sender)
    Sync.selfName = sender
    if ns.char then
        ns.char.fullName = sender
    end
    local data = Sync.GuildData()
    if data then
        data[sender] = nil -- an earlier version could store us as a guildmate
    end
end

-- Saved guild data: db.guilds[guild][sender] = { professions, hash, updated }.
function Sync.GuildData()
    local guild = IsInGuild() and GetGuildInfo("player")
    if not guild then
        return nil
    end
    ns.db.guilds[guild] = ns.db.guilds[guild] or {}
    return ns.db.guilds[guild]
end

local lastAnnounced
-- Tells the guild what we have; skipped when nothing changed since last time.
function Sync.Announce(force)
    if not IsInGuild() or not ns.char then
        return
    end
    local hash = Sync.MyHash()
    if force or hash ~= lastAnnounced then
        lastAnnounced = hash
        debug("hello to guild (" .. hash .. ")")
        send("H:" .. Sync.VERSION .. ":" .. hash .. ":" .. Sync.code, "GUILD")
    end
end

local decoders = {}
local handlers = {}

function handlers.H(sender, rest, channel)
    local version, hash = rest:match("^(%d+):(%x+)")
    if version ~= Sync.VERSION then
        return
    end
    local data = Sync.GuildData()
    local known = data and data[sender]
    debug(string.format("hello from %s over %s (%s)", sender, channel, known and known.hash == hash and "up to date" or "new"))
    if data and (not known or known.hash ~= hash) and hash ~= Sync.Hash({}) then
        C_Timer.After(math.random(1, 4), function() send("R:" .. Sync.VERSION, "WHISPER", sender) end)
    end
    -- A guild-wide hello is someone logging in: tell them what we have.
    if channel == "GUILD" and next(myShare()) then
        C_Timer.After(math.random(2, 8), function() send("H:" .. Sync.VERSION .. ":" .. Sync.MyHash(), "WHISPER", sender) end)
    end
end

function handlers.R(sender, rest)
    if rest ~= Sync.VERSION then
        return
    end
    local lines = Sync.Encode(myShare())
    debug(string.format("%s asked for our recipes: sending %d lines", sender, #lines))
    for _, line in ipairs(lines) do
        send(line, "WHISPER", sender)
    end
end

local function feed(sender, line)
    decoders[sender] = decoders[sender] or Sync.NewDecoder()
    local professions, hash = decoders[sender].Feed(line)
    local data = professions and Sync.GuildData()
    if data then
        data[sender] = { professions = professions, hash = hash, updated = time() }
        debug("received " .. sender .. "'s recipes")
        ns.Refresh()
    end
end

function Sync.OnMessage(prefix, text, channel, sender)
    if prefix ~= Sync.PREFIX or not sender then
        return
    end
    local code = text:match("^H:%d+:%x+:(%x+)$")
    if code and code == Sync.code then
        learnSelf(sender)
        return
    end
    if isMe(sender) then
        return
    end
    Sync.seen[sender] = time()
    local kind, rest = text:match("^(%u):(.*)$")
    if handlers[kind] then
        handlers[kind](sender, rest, channel)
    elseif kind and channel == "WHISPER" then
        feed(sender, text)
    end
end

-- Chat lines for /mkt guild: one per guildmate we have data for.
function Sync.Report()
    local data = Sync.GuildData()
    if not data then
        return { "Not in a guild." }
    end
    local lines, names = {}, {}
    for name in pairs(data) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local entry, parts = data[name], {}
        for _, p in pairs(entry.professions or {}) do
            local n = 0
            for _ in pairs(p.recipes or {}) do n = n + 1 end
            parts[#parts + 1] = string.format("%s %d (%d)", p.name or "?", p.skill or 0, n)
        end
        table.sort(parts)
        local state = Sync.seen[name] and "|cff4dcc73addon running|r" or "|cff8c949fnot seen this session|r"
        lines[#lines + 1] = string.format("%s: %s · %s", name, #parts > 0 and table.concat(parts, ", ") or "no professions", state)
    end
    if #lines == 0 then
        lines[1] = "No guildmate data yet. Guildmates need Marketplace and to be online."
    end
    return lines
end

function Sync.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(Sync.PREFIX)
end
