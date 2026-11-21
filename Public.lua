local _, ns = ...

-- Public listings over a hidden chat channel, for players outside your guild.
--
--   A:1:<hash>[:<code>]  "I have listings" (hash "0": I took them down).
--                        On the channel at login and after changes; by
--                        WHISPER in answer to a Q.
--   Q:1[:<code>]         "who has listings?" — on the channel, the first time
--                        someone opens the Public tab in a session.
--   R:1                  "send me your listings" — WHISPER.
--   B…E lines            the listings (see Listings.lua) — WHISPER.
--   G:1 / g:1            live check: ping and pong, by WHISPER.
--
-- Nothing is downloaded until you open the Public tab, so players who never
-- use it only hear the short A lines.
local Public = {}
ns.Public = Public

Public.PREFIX = "MktPublic"
Public.CHANNEL = "MarketplaceAddon"
Public.LIVE = 300       -- seconds a message from someone counts as "live"
Public.PING_WAIT = 6    -- seconds before an unanswered ping says "not responding"
Public.KEEP_DAYS = 14   -- listings not refreshed for this long are dropped
local QUERY_EVERY = 300

Public.seen = {}     -- [sender] = time of their last message
Public.pinged = {}   -- [sender] = time we pinged them
Public.active = false

local pendingHash = {} -- [sender] = hash announced but not downloaded yet
local decoders = {}
local lastAnnounced, lastQuery, joined

local function debug(msg)
    if ns.db and ns.db.settings.debug then
        ns.Print("|cff8c949fpublic:|r " .. msg)
    end
end

local function send(text, channel, target)
    ns.Sync.Send(text, channel, target, Public.PREFIX)
end

local function channelID()
    local id = GetChannelName and GetChannelName(Public.CHANNEL)
    return (id and id > 0) and id or nil
end

local function toChannel(text)
    local id = channelID()
    if id then
        send(text, "CHANNEL", id)
        return true
    end
    return false
end

function Public.Data()
    ns.db.public = ns.db.public or {}
    return ns.db.public
end

-- Your listed professions right now.
function Public.Mine()
    return ns.char and ns.Listings.Shareable(ns.char) or {}
end

function Public.MyHash()
    return ns.Listings.Hash(Public.Mine())
end

-- Tells the channel what we list; skipped when nothing changed. Nothing is
-- said by someone who never listed anything.
function Public.Announce(force)
    if not joined or not ns.char then
        return
    end
    local hash = Public.MyHash()
    if hash == "0" and (lastAnnounced == nil or lastAnnounced == "0") then
        return
    end
    if force or hash ~= lastAnnounced then
        if toChannel("A:" .. ns.Sync.VERSION .. ":" .. hash .. ":" .. ns.Sync.code) then
            lastAnnounced = hash
            debug("announced listings (" .. hash .. ")")
        end
    end
end

-- Announce shortly after the last edit in the listings editor.
local announceQueued = false
function Public.QueueAnnounce()
    if announceQueued then
        return
    end
    announceQueued = true
    C_Timer.After(3, function()
        announceQueued = false
        Public.Announce()
    end)
end

local function request(sender)
    pendingHash[sender] = nil
    C_Timer.After(math.random(1, 3), function() send("R:" .. ns.Sync.VERSION, "WHISPER", sender) end)
end

-- The Public tab was opened: ask who lists, fetch what was announced.
function Public.Activate()
    Public.active = true
    for sender in pairs(pendingHash) do
        request(sender)
    end
    if joined and (not lastQuery or time() - lastQuery > QUERY_EVERY) then
        lastQuery = time()
        toChannel("Q:" .. ns.Sync.VERSION .. ":" .. ns.Sync.code)
        debug("asked the channel for listings")
    end
end

-- Live check for listers we haven't heard from lately.
function Public.Ping(names)
    local now, any = time(), false
    for _, name in ipairs(names) do
        local seen, pinged = Public.seen[name], Public.pinged[name]
        if not (seen and now - seen < Public.LIVE) and not (pinged and now - pinged < 60) then
            Public.pinged[name] = now
            send("G:" .. ns.Sync.VERSION, "WHISPER", name)
            any = true
        end
    end
    if any then
        C_Timer.After(Public.PING_WAIT + 0.5, ns.Refresh)
    end
end

-- "live", "pinging", "noreply" or "offline" for someone who listed.
function Public.State(name, now)
    now = now or time()
    local seen, pinged = Public.seen[name], Public.pinged[name]
    if seen and now - seen < Public.LIVE then
        return "live"
    elseif pinged and (not seen or seen < pinged) then
        return now - pinged < Public.PING_WAIT and "pinging" or "noreply"
    end
    return "offline"
end

local handlers = {}

function handlers.A(sender, rest)
    local version, hash = rest:match("^(%d+):(%x+)")
    if version ~= ns.Sync.VERSION then
        return
    end
    local data = Public.Data()
    if hash == "0" then
        if data[sender] then
            data[sender] = nil
            debug(sender .. " took their listings down")
            ns.Refresh()
        end
        return
    end
    local known = data[sender]
    if known and known.hash == hash then
        known.updated = time()
        return
    end
    debug(string.format("%s lists something new (%s)", sender, hash))
    if Public.active then
        request(sender)
    else
        pendingHash[sender] = hash
    end
end

function handlers.Q(_, rest, channel, sender)
    if not rest:match("^" .. ns.Sync.VERSION) or channel ~= "CHANNEL" then
        return
    end
    local hash = Public.MyHash()
    if hash ~= "0" then
        C_Timer.After(math.random(1, 8), function()
            send("A:" .. ns.Sync.VERSION .. ":" .. Public.MyHash(), "WHISPER", sender)
        end)
    end
end

function handlers.R(sender, rest)
    if rest ~= ns.Sync.VERSION then
        return
    end
    local lines = ns.Listings.Encode(Public.Mine(), ns.char and ns.char.class)
    debug(string.format("%s asked for our listings: sending %d lines", sender, #lines))
    for _, line in ipairs(lines) do
        send(line, "WHISPER", sender)
    end
end

function handlers.G(sender)
    send("g:" .. ns.Sync.VERSION, "WHISPER", sender)
end

function handlers.g()
    ns.Refresh()
end

local function feed(sender, line)
    decoders[sender] = decoders[sender] or ns.Listings.NewDecoder()
    local professions, hash, class = decoders[sender].Feed(line)
    if professions then
        Public.Data()[sender] = { professions = professions, hash = hash, class = class, updated = time() }
        debug("received " .. sender .. "'s listings")
        ns.Refresh()
    end
end

function Public.OnMessage(prefix, text, channel, sender)
    if prefix ~= Public.PREFIX or not sender then
        return
    end
    local code = text:match("^A:%d+:%x+:(%x+)$") or text:match("^Q:%d+:(%x+)$")
    if code and code == ns.Sync.code then
        ns.Sync.LearnSelf(sender)
        return
    end
    if ns.Sync.IsMe(sender) then
        return
    end
    Public.seen[sender] = time()
    local kind, rest = text:match("^(%a):(.*)$")
    if handlers[kind] then
        handlers[kind](sender, rest, channel, sender)
    elseif kind and channel == "WHISPER" then
        feed(sender, text)
    end
end

-- Hide the "No player named X is currently playing." line a ping to an
-- offline lister causes.
local function hidePingErrors(_, _, msg)
    if not ERR_CHAT_PLAYER_NOT_FOUND_S then
        return false
    end
    local now = time()
    for name, at in pairs(Public.pinged) do
        if now - at < 15 and msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(name) then
            return true
        end
    end
    return false
end

local function hideChannel()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local chat = _G["ChatFrame" .. i]
        if chat and ChatFrame_RemoveChannel then
            ChatFrame_RemoveChannel(chat, Public.CHANNEL)
        end
    end
end

-- Joins the hidden channel (retrying while the client isn't ready), then
-- announces our listings.
function Public.Join(tries)
    tries = tries or 0
    if channelID() then
        joined = true
        hideChannel()
        Public.Announce(true)
        return
    end
    if tries > 6 then
        debug("couldn't join the listings channel")
        return
    end
    if JoinTemporaryChannel then
        JoinTemporaryChannel(Public.CHANNEL)
    end
    C_Timer.After(5, function() Public.Join(tries + 1) end)
end

-- Drops listings nobody refreshed for KEEP_DAYS.
function Public.Prune(now)
    local data = Public.Data()
    for sender, entry in pairs(data) do
        if (now - (entry.updated or 0)) > Public.KEEP_DAYS * 86400 then
            data[sender] = nil
        end
    end
end

function Public.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(Public.PREFIX)
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", hidePingErrors)
    end
    Public.Prune(time())
end
