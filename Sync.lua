local _, ns = ...

-- Guild sync over hidden addon messages, all on the GUILD channel (only
-- guildmates can send there, and one send reaches everyone who's behind).
--
-- Everyone keeps the recipes they received and passes them on, so a
-- guildmate's recipes reach people who were never online at the same time.
-- Each owner's copy has a hash and a stamp (server time of the owner's last
-- change); the newer stamp wins, the owner's own copy always does.
--
--   H:2:<hash>:<code>:<digest>   login hello. digest: 16 buckets of owners,
--                                4 hex digits each, over everything we hold.
--   A:2:<hash>                   "I run Marketplace too", once per hello.
--   D:2:<digest>                 periodic check (every 15 min, skipped when
--                                someone else's digest already matched ours).
--   L:2:<to>:<bucket>:<more>:<owner>=<hash>=<stamp>,…
--                                what's in a bucket whose digest differed;
--                                the first one heard stops the others.
--   R:2:<owner>=<hash>,…         "someone please send these copies".
--   S:2:<profession>=<skill>,…   the sender's current skill levels (not in
--                                the hash: levelling alone sends just this).
--   B:2:<hash>:<stamp>:<owner> P… C… I… E:<hash>
--                                a copy (owner empty = the sender's own).
--
-- Who answers: whoever's wait (hashed from the owner and their own name, so
-- it differs per sender) runs out first; the rest hear it and drop theirs.
-- The owner, if online, goes first.
--
-- Only recipe and category IDs travel, recipe IDs as sorted deltas packed
-- 5 bits per character. Every client looks up names, icons and reagents
-- from the IDs. Category names are sent once per profession.
local Sync = {}
ns.Sync = Sync

Sync.PREFIX = "Marketplace"
Sync.VERSION = "2"
Sync.BUCKETS = 16
local MAX_LINE = 250
local DAY = 86400

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

-- 8 hex digit fingerprint of a string.
function Sync.Djb2(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- Fingerprint of what's shared: professions, max skill, recipe and category
-- IDs. The current skill is left out, so levelling alone doesn't resend a
-- copy; it travels along with the next real change.
function Sync.Hash(professions)
    local parts = {}
    for _, id in ipairs(sortedKeys(professions)) do
        local p = professions[id]
        parts[#parts + 1] = id .. "/" .. (p.maxSkill or 0)
        for _, recipe in ipairs(sortedKeys(p.recipes)) do
            parts[#parts + 1] = tostring(recipe)
        end
        parts[#parts + 1] = "c"
        for _, cat in ipairs(sortedKeys(p.categories)) do
            parts[#parts + 1] = tostring(cat)
        end
    end
    return Sync.Djb2(table.concat(parts, ","))
end

-- Whether copy a (hash, stamp) beats copy b: newer stamp, ties by hash so
-- every client picks the same one.
function Sync.Newer(a, b)
    if a.stamp ~= b.stamp then
        return a.stamp > b.stamp
    end
    return a.hash > b.hash
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

-- Latest scan time in a set of professions: the stamp of copies saved
-- before stamps were sent.
function Sync.Stamp(professions)
    local stamp = 0
    for _, p in pairs(professions or {}) do
        stamp = math.max(stamp, p.scannedAt or 0)
    end
    return stamp
end

-- Appends "<head><item><sep><item>…" lines, each at most MAX_LINE bytes.
function Sync.Chunk(lines, head, items, sep)
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

-- Numbers as 5 bits per character, low bits first; characters 32-63 of the
-- alphabet mean "more follows".
local ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local DIGIT = {}
for i = 1, #ALPHA do
    DIGIT[ALPHA:sub(i, i)] = i - 1
end

function Sync.PackInt(n)
    local out = {}
    repeat
        local d = n % 32
        n = (n - d) / 32
        local v = d + (n > 0 and 32 or 0)
        out[#out + 1] = ALPHA:sub(v + 1, v + 1)
    until n == 0
    return table.concat(out)
end

-- Returns the number at pos and the position after it, or nil.
function Sync.UnpackInt(text, pos)
    local n, mul = 0, 1
    while true do
        local v = DIGIT[text:sub(pos, pos)]
        if not v then
            return nil
        end
        pos = pos + 1
        n = n + (v % 32) * mul
        if v < 32 then
            return n, pos
        end
        mul = mul * 32
    end
end

local GROUP = 16 -- recipes per packed group: small, so lines fill up

-- One profession's recipes as packed groups: category, count, ID deltas.
local function packRecipes(recipes)
    local byCat = {}
    for id, cat in pairs(recipes) do
        byCat[cat] = byCat[cat] or {}
        table.insert(byCat[cat], id)
    end
    local groups = {}
    for _, cat in ipairs(sortedKeys(byCat)) do
        local ids = byCat[cat]
        table.sort(ids)
        for first = 1, #ids, GROUP do
            local last = math.min(first + GROUP - 1, #ids)
            local out, prev = { Sync.PackInt(cat), Sync.PackInt(last - first + 1) }, 0
            for i = first, last do
                out[#out + 1] = Sync.PackInt(ids[i] - prev)
                prev = ids[i]
            end
            groups[#groups + 1] = table.concat(out)
        end
    end
    return groups
end

local function unpackRecipes(text, into)
    local pos = 1
    while pos <= #text do
        local cat, count
        cat, pos = Sync.UnpackInt(text, pos)
        if not cat then return end
        count, pos = Sync.UnpackInt(text, pos)
        if not count then return end
        local prev = 0
        for _ = 1, count do
            local delta
            delta, pos = Sync.UnpackInt(text, pos)
            if not delta then return end
            prev = prev + delta
            into[prev] = cat
        end
    end
end

-- owner: set when relaying someone else's recipes.
function Sync.Encode(professions, owner, stamp)
    local hash = Sync.Hash(professions)
    stamp = stamp or Sync.Stamp(professions)
    local lines = { string.format("B:%s:%s:%d:%s", Sync.VERSION, hash, stamp, owner or "") }
    for _, id in ipairs(sortedKeys(professions)) do
        local p = professions[id]
        lines[#lines + 1] = string.format("P:%d:%d:%d:%s", id, p.skill or 0, p.maxSkill or 0, clean(p.name):sub(1, 60))
        local cats = {}
        for _, cat in ipairs(sortedKeys(p.categories)) do
            local c = p.categories[cat]
            cats[#cats + 1] = cat .. "=" .. (c.parent or 0) .. "=" .. clean(c.name):sub(1, 60)
        end
        Sync.Chunk(lines, "C:" .. id .. ":", cats, ";")
        Sync.Chunk(lines, "I:" .. id .. ":", packRecipes(p.recipes or {}), "")
    end
    lines[#lines + 1] = "E:" .. hash
    return lines, hash
end

-- Parses a copy's first line: hash, stamp, owner (nil: the sender's own).
function Sync.ParseBegin(line)
    local version, hash, stamp, owner = line:match("^B:(%d+):(%x+):(%d+):(.*)$")
    if version ~= Sync.VERSION then
        return nil
    end
    return hash, tonumber(stamp), owner ~= "" and owner or nil
end

local function decodeProfession(pending, rest)
    local id, skill, maxSkill, name = rest:match("^(%d+):(%d+):(%d+):(.*)$")
    if not id then
        return
    end
    pending.professions[tonumber(id)] = {
        id = tonumber(id), name = name, skill = tonumber(skill), maxSkill = tonumber(maxSkill),
        scannedAt = pending.stamp, recipes = {}, categories = {},
    }
end

local function decodeProfessionChunk(pending, kind, rest)
    local id, list = rest:match("^(%d+):(.*)$")
    local p = id and pending.professions[tonumber(id)]
    if not p then
        return
    end
    if kind == "C" then
        for cat, parent, name in list:gmatch("(%d+)=(%d+)=([^;]*)") do
            p.categories[tonumber(cat)] = { name = name, parent = tonumber(parent) }
        end
    else
        unpackRecipes(list, p.recipes)
    end
end

-- Collects one sender's B…E lines. Feed returns (professions, hash, owner,
-- stamp) once a complete, matching copy has arrived (owner only for a
-- relayed copy); nil otherwise.
function Sync.NewDecoder()
    local pending
    local decoder = {}
    function decoder.Feed(line)
        local kind, rest = line:match("^(%u):(.*)$")
        if kind == "B" then
            local hash, stamp, owner = Sync.ParseBegin(line)
            pending = hash and { hash = hash, stamp = stamp, owner = owner, professions = {} } or nil
        elseif not pending then
            return nil
        elseif kind == "P" then
            decodeProfession(pending, rest)
        elseif kind == "C" or kind == "I" then
            decodeProfessionChunk(pending, kind, rest)
        elseif kind == "E" then
            local done = pending
            pending = nil
            if done and rest == done.hash and Sync.Hash(done.professions) == done.hash then
                return done.professions, done.hash, done.owner, done.stamp
            end
        end
        return nil
    end
    return decoder
end

-- Digests -------------------------------------------------------------------

local function shortName(name)
    return (tostring(name or ""):gsub("%-[^%-]*$", ""))
end

-- Bucket 0-15 an owner falls in.
function Sync.BucketOf(owner)
    return tonumber(Sync.Djb2(owner):sub(-4), 16) % Sync.BUCKETS
end

-- state = { [owner] = { hash, stamp } } -> 64 hex digits, 4 per bucket.
function Sync.Digest(state)
    local buckets = {}
    for b = 0, Sync.BUCKETS - 1 do
        buckets[b] = {}
    end
    for _, owner in ipairs(sortedKeys(state)) do
        local list = buckets[Sync.BucketOf(owner)]
        list[#list + 1] = owner .. "=" .. state[owner].hash
    end
    local out = {}
    for b = 0, Sync.BUCKETS - 1 do
        out[#out + 1] = #buckets[b] > 0 and Sync.Djb2(table.concat(buckets[b], ",")):sub(1, 4) or "0000"
    end
    return table.concat(out)
end

-- Buckets (0-based) where two digests differ.
function Sync.DiffBuckets(a, b)
    local out = {}
    for i = 0, Sync.BUCKETS - 1 do
        if a:sub(i * 4 + 1, i * 4 + 4) ~= b:sub(i * 4 + 1, i * 4 + 4) then
            out[#out + 1] = i
        end
    end
    return out
end

-- What to do about a bucket list someone posted, against what we hold:
-- wanted = owners whose listed copy is newer or unknown to us;
-- offer = owners where we hold something newer, or that the list lacks.
-- skip(owner) leaves out ourselves and people who left.
function Sync.Compare(list, state, bucket, skip)
    local wanted, offer = {}, {}
    for _, owner in ipairs(sortedKeys(list)) do
        local e, mine = list[owner], state[owner]
        if not (skip and skip(owner)) then
            if not mine or (mine.hash ~= e.hash and Sync.Newer(e, mine)) then
                wanted[#wanted + 1] = owner
            elseif mine.hash ~= e.hash then
                offer[#offer + 1] = owner
            end
        end
    end
    for _, owner in ipairs(sortedKeys(state)) do
        if not list[owner] and Sync.BucketOf(owner) == bucket and not (skip and skip(owner)) then
            offer[#offer + 1] = owner
        end
    end
    return wanted, offer
end

-- Transport -----------------------------------------------------------------

-- Who has talked to us this session (= is running Marketplace), by full name.
Sync.seen = {}

local function debug(msg)
    if ns.db and ns.db.settings.debug then
        ns.Print("|cff8c949fsync:|r " .. msg)
    end
end

local function now()
    return ns.Now()
end

-- Outgoing lines: control lines go ahead of copies; a copy's lines carry a
-- tag (its owner) so a copy someone else already sent can be dropped.
local queue, pumping = {}, false

-- Sends one line every 0.25s; a throttled (or refused) line is retried
-- after a second, up to 10 times. An error drops the line, not the queue.
local function pump()
    local item = queue[1]
    if not item then
        pumping = false
        return
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, item.prefix, item.text, item.channel, item.target)
    local codes = Enum and Enum.SendAddonMessageResult or {}
    local retry = ok and (result == false or result == (codes.AddonMessageThrottle or 3) or result == (codes.ChannelThrottle or 8))
    if retry then
        item.tries = (item.tries or 0) + 1
        retry = item.tries < 10
    end
    if not retry then
        table.remove(queue, 1)
        item.sent = true
    end
    C_Timer.After(retry and 1 or 0.25, pump)
end

local function enqueue(item, control)
    if control then
        local at = 1
        while queue[at] and queue[at].control do
            at = at + 1
        end
        item.control = true
        table.insert(queue, at, item)
    else
        queue[#queue + 1] = item
    end
    if not pumping then
        pumping = true
        pump()
    end
end

local function control(text)
    enqueue({ prefix = Sync.PREFIX, text = text, channel = "GUILD" }, true)
end

local function sendCopyLines(lines, tag)
    for i, line in ipairs(lines) do
        enqueue({ prefix = Sync.PREFIX, text = line, channel = "GUILD", tag = tag, first = i == 1 })
    end
end

-- A copy of this owner is queued and hasn't started going out yet.
local function unstarted(tag)
    for _, item in ipairs(queue) do
        if item.tag == tag and item.first then
            return true
        end
    end
    return false
end

-- Drops queued lines of a copy.
local function dequeue(tag)
    for i = #queue, 1, -1 do
        if queue[i].tag == tag then
            table.remove(queue, i)
        end
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
-- sender is the name everyone else sees (also saved for next time).
Sync.code = string.format("%06x", math.random(0, 16777215))
Sync.selfName = nil

function Sync.IsMe(sender)
    if Sync.selfName then
        return sender == Sync.selfName
    end
    if ns.char and ns.char.fullName and sender == ns.char.fullName then
        return true
    end
    local name, realm = UnitName("player"), GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" then
        return sender == name .. "-" .. realm or sender == name
    end
    return (sender:match("^[^-]+")) == name
end

-- The name others know us by, if we know it yet.
local function selfKey()
    return Sync.selfName or (ns.char and ns.char.fullName)
end

-- Our own guild hello came back: remember the name it came from.
function Sync.LearnSelf(sender)
    Sync.selfName = sender
    if Sync.ownWaiting then
        Sync.ownWaiting = false
        C_Timer.After(1, function() Sync.SendOwnSoon() end)
    end
    if ns.char then
        ns.char.fullName = sender
    end
    local data = Sync.GuildData()
    if data then
        data[sender] = nil -- an earlier version could store us as a guildmate
    end
end

-- Saved guild data: db.guilds[guild][owner] = { professions, hash, stamp, updated, via }.
function Sync.GuildData()
    local guild = IsInGuild() and GetGuildInfo("player")
    if not guild then
        return nil
    end
    ns.db.guilds[guild] = ns.db.guilds[guild] or {}
    return ns.db.guilds[guild]
end

-- Our stamp: moves on (server time) whenever what we share changes.
local function ownStamp()
    local c = ns.char
    local hash = Sync.MyHash()
    if c.shareHash ~= hash or not c.shareStamp then
        c.shareHash = hash
        c.shareStamp = math.max(now(), (c.shareStamp or 0) + 1)
    end
    return c.shareStamp
end

local function entryStamp(entry)
    return entry.stamp or Sync.Stamp(entry.professions)
end

-- Everyone in the guild by short name (value: online or not), or nil when
-- it can't be trusted to say who left: not loaded yet, offline members
-- hidden, rows missing (the game says there are more members than it
-- lists), still changing (right after login it fills in over a few
-- seconds, online members first), or our own name missing from it (the
-- roster spells names differently from addon messages).
Sync.ROSTER_SETTLE = 60 -- seconds the roster must have kept its size
local rosterSize, rosterSince
local function members()
    local total = GetNumGuildMembers and GetNumGuildMembers() or 0
    if total == 0 or (GetGuildRosterShowOffline and not GetGuildRosterShowOffline()) then
        return nil
    end
    local set, named = {}, 0
    for i = 1, total do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            set[shortName(name)] = isOnline and true or false
            named = named + 1
        end
    end
    if named ~= rosterSize then
        rosterSize, rosterSince = named, time()
    end
    if named < total or time() - rosterSince < Sync.ROSTER_SETTLE then
        return nil
    end
    local me = Sync.selfName or (ns.char and ns.char.fullName)
    if not me or set[shortName(me)] == nil then
        return nil
    end
    return set
end
Sync.Members = members

local function isSelf(owner)
    return Sync.IsMe(owner) or owner == selfKey()
end

-- Someone we heard from this session is in the guild, whatever the roster says.
local function leftGuild(roster, owner)
    return roster ~= nil and roster[shortName(owner)] == nil and not Sync.seen[owner]
end

-- What we hold, ourselves included: { [owner] = { hash, stamp } }.
local function myState(roster)
    local state = {}
    local data = Sync.GuildData() or {}
    for owner, e in pairs(data) do
        if e.hash and e.professions and not isSelf(owner) and not leftGuild(roster, owner) then
            state[owner] = { hash = e.hash, stamp = entryStamp(e) }
        end
    end
    -- Ourselves, also once we have nothing left to share (so others drop
    -- what they hold of us).
    local key = selfKey()
    if key and ns.char and (next(myShare()) or ns.char.shareStamp) then
        state[key] = { hash = Sync.MyHash(), stamp = ownStamp() }
    end
    return state
end

-- A wait of 0.5-4.5s that differs per sender: hashed from key and our name.
local function jitter(key)
    local h = tonumber(Sync.Djb2(key .. "|" .. (selfKey() or UnitName("player") or "")):sub(1, 4), 16)
    return 0.5 + (h % 4000) / 1000
end

-- Sending copies ------------------------------------------------------------

Sync.DEBOUNCE, Sync.MIN_INTERVAL, Sync.ASKED_INTERVAL = 30, 120, 15
local SELF = "@self"           -- tag/pending key for our own copy
local pendingSend = {}         -- owner (or SELF) -> token of a scheduled copy
local lastOwnAt = -math.huge
local schedule

-- "164=215,186=120": our skill levels, to tell when they changed.
local function skillLine()
    local items = {}
    for _, id in ipairs(sortedKeys(myShare())) do
        items[#items + 1] = id .. "=" .. (ns.char.professions[id].skill or 0)
    end
    return table.concat(items, ",")
end

local SKILLS = "@skills" -- pending key for a skill update
local lastSkillsAt = -math.huge

local function sendCopy(owner)
    if owner == SKILLS then
        local line = skillLine()
        if line ~= "" and line ~= ns.char.sentSkills and Sync.selfName then
            ns.char.sentSkills, lastSkillsAt = line, time()
            debug("our skill levels to the guild: " .. line)
            control("S:" .. Sync.VERSION .. ":" .. line)
        end
        return
    end
    if owner == SELF then
        if not Sync.selfName then
            -- Our hello hasn't echoed back yet, so we can't yet tell our
            -- own copy from a guildmate's: send once it has.
            Sync.ownWaiting = true
            return
        end
        local share = myShare()
        if not next(share) and not ns.char.shareStamp then
            return -- never shared anything
        end
        local lines, hash = Sync.Encode(share, nil, ownStamp())
        lastOwnAt = time()
        ns.char.sentHash = hash -- saved: no resend next session if unchanged
        ns.char.sentSkills = skillLine() -- the copy carries the levels
        debug(string.format("our recipes to the guild: %d lines", #lines))
        sendCopyLines(lines, SELF)
        return
    end
    local data = Sync.GuildData()
    local entry = data and data[owner]
    if entry and entry.professions then
        local lines = Sync.Encode(entry.professions, owner, entryStamp(entry))
        debug(string.format("relaying %s's recipes: %d lines", owner, #lines))
        sendCopyLines(lines, owner)
    end
end

function schedule(owner, delay)
    if pendingSend[owner] or unstarted(owner) then
        return
    end
    local token = {}
    pendingSend[owner] = token
    C_Timer.After(delay, function()
        if pendingSend[owner] == token then
            pendingSend[owner] = nil
            sendCopy(owner)
        end
    end)
end

-- Our own copy. changed: after a scan (waits DEBOUNCE, at most every
-- MIN_INTERVAL); otherwise someone needs it (soon, at most every 15s).
local function scheduleOwn(changed)
    if changed then
        if Sync.MyHash() == ns.char.sentHash then
            -- Same recipes; only levels may have moved: a one-line update.
            if skillLine() ~= ns.char.sentSkills then
                schedule(SKILLS, math.max(Sync.DEBOUNCE, lastSkillsAt + Sync.MIN_INTERVAL - time()))
            end
            return
        end
        schedule(SELF, math.max(Sync.DEBOUNCE, lastOwnAt + Sync.MIN_INTERVAL - time()))
    else
        schedule(SELF, math.max(0.2, lastOwnAt + Sync.ASKED_INTERVAL - time()))
    end
end

-- Someone else started the same copy: drop ours unless it's already going out.
function Sync.SendOwnSoon()
    scheduleOwn(false)
end

local function cancel(owner)
    pendingSend[owner] = nil
    if unstarted(owner) then
        dequeue(owner)
    end
end

-- Asking for copies -----------------------------------------------------------

local REQUEST_TIMEOUT = 30
local requested = {}   -- owner -> { hash, at } asked for (by us or someone)
local wanted = {}      -- owner -> { hash, stamp } to ask for in the next R
local askPending = false
local retried = {}     -- owner -> hash once re-asked (bounded by guild size)
local want

local function haveOrNewer(owner, hash, stamp)
    local data = Sync.GuildData()
    local entry = data and data[owner]
    if not entry then
        return false
    end
    return entry.hash == hash or (stamp ~= nil and entryStamp(entry) >= stamp)
end

local function askedRecently(owner, hash)
    local r = requested[owner]
    return r and r.hash == hash and time() - r.at < REQUEST_TIMEOUT
end

local function flushAsks()
    askPending = false
    local items = {}
    for _, owner in ipairs(sortedKeys(wanted)) do
        local w = wanted[owner]
        items[#items + 1] = owner .. "=" .. w.hash
        requested[owner] = { hash = w.hash, at = time() }
    end
    local asked = wanted
    wanted = {}
    -- No copy came: ask once more after the timeout (unless a newer copy arrived).
    C_Timer.After(REQUEST_TIMEOUT + 5, function()
        for owner, w in pairs(asked) do
            if not haveOrNewer(owner, w.hash, w.stamp) and retried[owner] ~= w.hash then
                retried[owner] = w.hash
                want(owner, w.hash, w.stamp)
            end
        end
    end)
    local lines = {}
    Sync.Chunk(lines, "R:" .. Sync.VERSION .. ":", items, ",")
    for _, line in ipairs(lines) do
        control(line)
    end
    if #items > 0 then
        debug(string.format("asked the guild for %d copies", #items))
    end
end

function want(owner, hash, stamp)
    if askedRecently(owner, hash) or haveOrNewer(owner, hash, stamp) then
        return
    end
    wanted[owner] = { hash = hash, stamp = stamp }
    if not askPending then
        askPending = true
        C_Timer.After(jitter("ask"), flushAsks)
    end
end

-- Refresh on demand ------------------------------------------------------------

-- The window's Refresh button posts our digest right away. Whoever holds
-- something different lists the buckets that differ, as after a hello, and
-- reconciling those lists asks only for copies newer than ours (and sends
-- the ones where ours is newer). Nobody answers a digest they agree with,
-- so silence means we're up to date.
Sync.REFRESH_GAP = 30     -- seconds between two refreshes
Sync.REFRESH_QUIET = 10   -- no list for us by then: nobody differs
Sync.REFRESH_SETTLE = 6   -- nothing more to wait for: done after this long
Sync.REFRESH_GIVE_UP = 45 -- copies we asked for didn't come: stop waiting

-- { at, phase, gen, wanted = { [owner] = hash }, pending, got, listed, done }
-- phase: "checking", "updating", then "current", "alone", "updated" or "partial".
local refresh

local function refreshChanged()
    if Sync.OnRefresh then
        Sync.OnRefresh()
    end
end

-- Guildmates running Marketplace who are online (or, without a roster we
-- can trust, heard this session).
local function peersOnline()
    local roster, n = members(), 0
    for sender in pairs(Sync.seen) do
        if not roster or roster[shortName(sender)] then
            n = n + 1
        end
    end
    return n
end

local function refreshFinish(r)
    if r.pending > 0 then
        r.phase = "partial"
    elseif r.got > 0 then
        r.phase = "updated"
    elseif r.listed or peersOnline() > 0 then
        r.phase = "current"
    else
        r.phase = "alone"
    end
    r.done = time()
    refreshChanged()
    local left = r.at + Sync.REFRESH_GAP - time()
    if left > 0 and C_Timer and C_Timer.After then
        C_Timer.After(left, function()
            if refresh == r then
                refreshChanged()
            end
        end)
    end
end

-- Something happened: the refresh is over once nothing else does for delay.
local function refreshWait(r, delay)
    r.gen = r.gen + 1
    local gen = r.gen
    C_Timer.After(delay, function()
        if refresh == r and r.gen == gen and not r.done then
            refreshFinish(r)
        end
    end)
end

local function refreshing()
    return refresh and not refresh.done and refresh or nil
end

-- phase, copies received, copies asked for; nil before the first refresh.
function Sync.RefreshState()
    if refresh then
        return refresh.phase, refresh.got, refresh.got + refresh.pending
    end
end

-- Seconds until another manual refresh is allowed (0 when ready).
function Sync.RefreshCooldown()
    if not refresh then
        return 0
    end
    if not refresh.done then
        return Sync.REFRESH_GAP
    end
    return math.max(0, refresh.at + Sync.REFRESH_GAP - time())
end

-- Bucket lists ----------------------------------------------------------------

local pendingList = {}  -- "to|bucket" -> token
local incoming = {}     -- "sender|to|bucket" -> list being received

local function postList(to, bucket)
    local state, items = myState(members()), {}
    for _, owner in ipairs(sortedKeys(state)) do
        if Sync.BucketOf(owner) == bucket then
            items[#items + 1] = owner .. "=" .. state[owner].hash .. "=" .. state[owner].stamp
        end
    end
    local head = string.format("L:%s:%s:%d:", Sync.VERSION, to, bucket)
    local lines = {}
    Sync.Chunk(lines, head .. "1:", items, ",")
    if #lines == 0 then
        lines[1] = head .. "1:"
    end
    lines[#lines] = head .. "0:" .. lines[#lines]:sub(#head + 3)
    for _, line in ipairs(lines) do
        control(line)
    end
end

local function scheduleList(to, bucket)
    local key = to .. "|" .. bucket
    if pendingList[key] then
        return
    end
    local token = {}
    pendingList[key] = token
    C_Timer.After(jitter(key), function()
        if pendingList[key] == token then
            pendingList[key] = nil
            postList(to, bucket)
        end
    end)
end

-- Someone's digest differs from ours in some buckets: list ours (unless
-- someone else does first).
local function answerDigest(to, digest)
    local diff = Sync.DiffBuckets(Sync.Digest(myState(members())), digest)
    debug(string.format("digest from %s: %d buckets differ", to, #diff))
    for _, bucket in ipairs(diff) do
        scheduleList(to, bucket)
    end
end

-- A complete bucket list: ask for what's newer, send what the list lacks.
-- Returns the owners whose listed copy we want.
local function reconcile(list, bucket)
    local roster = members()
    local state = myState(roster)
    local key = selfKey()
    local listed, mine = key and list[key], key and state[key]
    if mine and listed and listed.hash ~= mine.hash then
        if listed.stamp >= ns.char.shareStamp then
            ns.char.shareStamp = listed.stamp + 1 -- a copy of us that looks newer than us
        end
        scheduleOwn(false)
    elseif mine and not listed and Sync.BucketOf(key) == bucket then
        scheduleOwn(false)
    end
    local wantedOwners, offer = Sync.Compare(list, state, bucket, function(owner)
        return owner == key or isSelf(owner) or leftGuild(roster, owner)
    end)
    for _, owner in ipairs(wantedOwners) do
        want(owner, list[owner].hash, list[owner].stamp)
    end
    for _, owner in ipairs(offer) do
        schedule(owner, jitter(owner))
    end
    return wantedOwners
end

-- Handlers --------------------------------------------------------------------

local handlers = {}
local presencePending = false  -- coalesce simultaneous login hellos into one A reply
local lastMatchAt = -math.huge -- last time someone's digest matched ours

local function ready()
    return ns.char ~= nil and Sync.GuildData() ~= nil
end

local function matches(digest)
    if digest == Sync.Digest(myState(members())) then
        lastMatchAt = time()
        return true
    end
end

function handlers.H(sender, rest)
    local version, _, _, digest = rest:match("^(%d+):(%x+):(%x+):(%x+)$")
    if version ~= Sync.VERSION or not ready() then
        return
    end
    debug("hello from " .. sender)
    if not presencePending then
        presencePending = true
        C_Timer.After(math.random() * 6, function()
            presencePending = false
            control("A:" .. Sync.VERSION .. ":" .. Sync.MyHash())
        end)
    end
    if not matches(digest) then
        answerDigest(sender, digest)
    end
end

function handlers.A() end -- Sync.seen is all it's for

-- Someone's skill levels moved: update their stored copy (not its hash).
function handlers.S(sender, rest)
    local version, list = rest:match("^(%d+):(.*)$")
    local data = version == Sync.VERSION and Sync.GuildData()
    local entry = data and data[sender]
    if not (entry and entry.professions) then
        return
    end
    for id, skill in list:gmatch("(%d+)=(%d+)") do
        local p = entry.professions[tonumber(id)]
        if p then
            p.skill = tonumber(skill)
        end
    end
    ns.Refresh()
end

function handlers.D(sender, rest)
    local version, digest = rest:match("^(%d+):(%x+)$")
    if version == Sync.VERSION and ready() and not matches(digest) then
        answerDigest(sender, digest)
    end
end

function handlers.L(sender, rest)
    local version, to, bucket, more, list = rest:match("^(%d+):([^:]+):(%d+):(%d):(.*)$")
    if version ~= Sync.VERSION then
        return
    end
    bucket = tonumber(bucket)
    pendingList[to .. "|" .. bucket] = nil -- someone listed it: we needn't
    local key = sender .. "|" .. to .. "|" .. bucket
    local into = incoming[key]
    if not into or time() - into.at > 30 then -- a lost last line: start over
        into = { at = time(), list = {} }
        incoming[key] = into
    end
    for owner, hash, stamp in list:gmatch("([^,=]+)=(%x+)=(%d+)") do
        into.list[owner] = { hash = hash, stamp = tonumber(stamp) }
    end
    -- A list for us while the Refresh button waits: it counts what's coming.
    local r = isSelf(to) and refreshing()
    if r then
        r.phase, r.listed = "updating", true
    end
    if more == "0" then
        incoming[key] = nil
    end
    if more == "0" and ready() then
        for _, owner in ipairs(reconcile(into.list, bucket)) do
            if r and not r.wanted[owner] then
                r.wanted[owner] = into.list[owner].hash
                r.pending = r.pending + 1
            end
        end
    end
    if r then
        refreshWait(r, (more ~= "0" or r.pending > 0) and Sync.REFRESH_GIVE_UP or Sync.REFRESH_SETTLE)
        refreshChanged()
    end
end

function handlers.R(sender, rest)
    local version, list = rest:match("^(%d+):(.*)$")
    if version ~= Sync.VERSION or not ready() then
        return
    end
    local data, key = Sync.GuildData(), selfKey()
    for owner, hash in list:gmatch("([^,=]+)=(%x+)") do
        if wanted[owner] and wanted[owner].hash == hash then
            wanted[owner] = nil -- someone else asked: we needn't
        end
        requested[owner] = { hash = hash, at = time() }
        if owner == key or isSelf(owner) then
            scheduleOwn(false)
        else
            local entry = data[owner]
            if entry and entry.hash == hash then
                schedule(owner, jitter(owner))
            end
        end
    end
end

-- Receiving copies ------------------------------------------------------------

local decoders = {}

-- A copy is starting: whoever was about to send the same one can stop.
local function onBegin(sender, line)
    local hash, stamp, owner = Sync.ParseBegin(line)
    if not hash then
        return
    end
    owner = owner or sender
    if wanted[owner] and wanted[owner].hash == hash then
        wanted[owner] = nil
    end
    if isSelf(owner) then
        if ns.char and hash == Sync.MyHash() then
            cancel(SELF)
        end
        return
    end
    local data = Sync.GuildData()
    local mine = data and data[owner]
    if (pendingSend[owner] or unstarted(owner))
        and (not mine or not Sync.Newer({ hash = mine.hash, stamp = entryStamp(mine) }, { hash = hash, stamp = stamp })) then
        cancel(owner)
    end
end

local function storeRelayed(data, sender, professions, hash, owner, stamp)
    if isSelf(owner) then
        if hash ~= Sync.MyHash() then
            -- An old (or forged) copy of us is going round: send ours.
            if stamp >= ownStamp() then
                ns.char.shareStamp = stamp + 1
            end
            scheduleOwn(false)
        end
        return false
    end
    local known = data[owner]
    local stale = known and (known.hash == hash or not Sync.Newer({ hash = hash, stamp = stamp }, { hash = known.hash, stamp = entryStamp(known) }))
    if stale or leftGuild(members(), owner) then
        return false
    end
    -- updated: the owner's last change, the last time we know they were on.
    data[owner] = { professions = professions, hash = hash, stamp = stamp, updated = stamp, via = sender }
    debug(string.format("received %s's recipes via %s", owner, sender))
    return true
end

local function store(sender, professions, hash, owner, stamp)
    local data = Sync.GuildData()
    if not data or not ns.char then
        return
    end
    if stamp > now() + DAY then
        debug("ignored a copy from " .. sender .. " stamped in the future")
        return
    end
    if not owner then
        data[sender] = { professions = professions, hash = hash, stamp = stamp, updated = now() }
        debug("received " .. sender .. "'s recipes")
    elseif not storeRelayed(data, sender, professions, hash, owner, stamp) then
        return
    end
    local key = owner or sender
    requested[key] = nil
    retried[key] = nil
    local r = refreshing()
    if r and r.wanted[key] then
        r.wanted[key] = nil
        r.pending, r.got = r.pending - 1, r.got + 1
        refreshWait(r, r.pending > 0 and Sync.REFRESH_GIVE_UP or Sync.REFRESH_SETTLE)
    end
    ns.Refresh()
end

local function feed(sender, line)
    if line:sub(1, 2) == "B:" then
        onBegin(sender, line)
    end
    decoders[sender] = decoders[sender] or Sync.NewDecoder()
    local professions, hash, owner, stamp = decoders[sender].Feed(line)
    if professions then
        store(sender, professions, hash, owner, stamp)
    end
end

function Sync.OnMessage(prefix, text, channel, sender)
    if prefix ~= Sync.PREFIX or not sender or channel ~= "GUILD" then
        return -- guild only: nobody outside it can send there
    end
    local code = text:match("^H:%d+:%x+:(%x+):")
    local me = UnitName("player") or ""
    if code and code == Sync.code and sender:sub(1, #me) == me then
        Sync.LearnSelf(sender)
        return
    end
    if Sync.IsMe(sender) then
        return
    end
    Sync.seen[sender] = time()
    local kind, rest = text:match("^(%u):(.*)$")
    if handlers[kind] then
        handlers[kind](sender, rest)
    elseif kind then
        feed(sender, text)
    end
end

-- Announcing ------------------------------------------------------------------

-- Asks the server for the guild roster (needed to tell who left and who's
-- online).
function Sync.RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Clears per-guild session state when switching to a different guild mid-session.
local function resetSession()
    Sync.seen = {}
    decoders = {}
    requested, wanted, retried = {}, {}, {}
    pendingSend, pendingList, incoming = {}, {}, {}
    presencePending = false
    lastMatchAt = -math.huge
    refresh = nil
    rosterSize, rosterSince = nil, nil
end

-- At login (force): hello with our digest; whoever differs lists the
-- buckets that differ. Otherwise (a scan changed something): schedule a
-- broadcast of our recipes.
function Sync.Announce(force, tries)
    if not IsInGuild() or not ns.char then
        return
    end
    if not force then
        scheduleOwn(true)
        return
    end
    if not Sync.GuildData() then
        -- The guild name isn't known yet right after login: try again
        -- (every 5s for 5 minutes; joining a guild also calls this).
        tries = (tries or 0) + 1
        if tries <= 60 then
            C_Timer.After(5, function() Sync.Announce(true, tries) end)
        end
        return
    end
    local guild = GetGuildInfo("player")
    if Sync.helloGuild and Sync.helloGuild ~= guild then
        resetSession()
    end
    Sync.helloGuild = guild
    Sync.RequestRoster()
    debug("hello to guild")
    control(string.format("H:%s:%s:%s:%s", Sync.VERSION, Sync.MyHash(), Sync.code, Sync.Digest(myState(members()))))
end

-- Said hello in the guild we're in now? Otherwise (joined one, or the
-- login hello gave up) say it.
function Sync.EnsureHello()
    if IsInGuild() and GetGuildInfo("player") and Sync.helloGuild ~= GetGuildInfo("player") then
        Sync.Announce(true)
    end
end

-- Every 15 minutes: compare digests again, unless someone's matched ours
-- since the last check (then the guild already agrees). A random wait first,
-- so clients that started together don't all send one.
Sync.CHECK_INTERVAL = 900
function Sync.Check(immediate)
    if not IsInGuild() or not ready() or time() - lastMatchAt < Sync.CHECK_INTERVAL then
        return
    end
    if immediate ~= true then
        C_Timer.After(math.random() * 60, function() Sync.Check(true) end)
        return
    end
    Sync.RequestRoster()
    control("D:" .. Sync.VERSION .. ":" .. Sync.Digest(myState(members())))
end

-- The Refresh button: compare with the guild now. Returns true, or false and
-- why not: "guild" (not in one, or not ready yet) or "wait" (one is running,
-- or just ran).
function Sync.RequestLatest()
    if not IsInGuild() or not ready() then
        return false, "guild"
    end
    if refresh and (not refresh.done or time() - refresh.at < Sync.REFRESH_GAP) then
        return false, "wait"
    end
    local r = { at = time(), phase = "checking", gen = 0, wanted = {}, pending = 0, got = 0 }
    refresh = r
    Sync.RequestRoster()
    debug("refresh: digest to the guild")
    control("D:" .. Sync.VERSION .. ":" .. Sync.Digest(myState(members())))
    refreshWait(r, Sync.REFRESH_QUIET)
    refreshChanged()
    return true
end

-- Chat lines for /mkt guild: one per guildmate we have data for.
function Sync.Report()
    local data = Sync.GuildData()
    if not data then
        return { "Not in a guild." }
    end
    local lines, names = {}, {}
    for name, entry in pairs(data) do
        if next(entry.professions or {}) then -- not those who stopped sharing
            names[#names + 1] = name
        end
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
        if entry.via then
            state = state .. " · |cff8c949fvia " .. entry.via .. "|r"
        end
        lines[#lines + 1] = string.format("%s: %s · %s", name, #parts > 0 and table.concat(parts, ", ") or "no professions", state)
    end
    if #lines == 0 then
        lines[1] = "No guildmate data yet. Guildmates need Marketplace and to be online."
    end
    return lines
end

function Sync.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(Sync.PREFIX)
    if C_Timer.NewTicker then
        C_Timer.NewTicker(Sync.CHECK_INTERVAL, function() Sync.Check() end)
    end
end
