local _, ns = ...

-- Public listings: which of your recipes you offer to anyone (not just your
-- guild), and on what terms. Kept free of UI and network code.
--
-- Saved per character, per profession:
--   char.listings[profID] = {
--     on = true,                      listed publicly
--     mats = "bring" | "provide" | "either",
--     fee = copper,                   crafting fee (with the buyer's mats)
--     price = copper or nil,          price with my mats; nil = mats + fee
--     tips = true,                    "tips" instead of a fixed fee
--     recipes = { [recipeID] = false | terms },   unlisted, or own terms
--   }
-- terms = { mats, fee, price, tips }
local Listings = {}
ns.Listings = Listings

Listings.MATS = { "bring", "provide", "either" }
Listings.MATS_LABEL = { bring = "Bring mats", provide = "Mats included", either = "Either" }
Listings.MATS_CODE = { bring = "b", provide = "p", either = "e" }
local FROM_CODE = { b = "bring", p = "provide", e = "either" }

function Listings.New()
    return { on = false, mats = "bring", fee = 0, price = nil, tips = false, recipes = {} }
end

-- The listing settings of one of the character's professions (created on
-- first use).
function Listings.Get(char, profID)
    char.listings = char.listings or {}
    local l = char.listings[profID]
    if not l then
        l = Listings.New()
        char.listings[profID] = l
    end
    l.recipes = l.recipes or {}
    return l
end

local function defaultTerms(l)
    return { mats = l.mats or "bring", fee = l.fee or 0, price = l.price, tips = l.tips or false }
end

-- Terms for one recipe, or nil when it isn't listed.
function Listings.Terms(l, recipeID)
    if not l or not l.on then
        return nil
    end
    local own = l.recipes and l.recipes[recipeID]
    if own == false then
        return nil
    elseif type(own) == "table" then
        return own
    end
    return defaultTerms(l)
end

function Listings.IsCustom(l, recipeID)
    return type(l and l.recipes and l.recipes[recipeID]) == "table"
end

-- "Tips", "Free", or the fee in coins. coins(copper) formats money.
function Listings.FeeText(terms, coins)
    if terms.tips then
        return "Tips"
    elseif (terms.fee or 0) == 0 then
        return "Free"
    end
    return coins(terms.fee)
end

-- What it costs with the crafter's mats: a fixed price, or "mats + fee".
function Listings.PriceText(terms, coins)
    if terms.price then
        return coins(terms.price)
    end
    if terms.tips then
        return "Mats + tips"
    end
    return (terms.fee or 0) > 0 and ("Mats + " .. coins(terms.fee)) or "Mats only"
end

-- One line of terms, e.g. "2g", "Mats + 2g", "2g · or mats + 2g".
function Listings.Summary(terms, coins)
    if terms.mats == "provide" then
        return Listings.PriceText(terms, coins)
    elseif terms.mats == "either" then
        return Listings.FeeText(terms, coins) .. " · or " .. Listings.PriceText(terms, coins):gsub("^M", "m")
    end
    return Listings.FeeText(terms, coins)
end

-- Comparable cost for "from …" in lists: the fee with your own mats, or the
-- fixed price when the crafter only sells with mats. Tips count as 0.
function Listings.SortCost(terms)
    if terms.tips then
        return 0
    end
    if terms.mats == "provide" then
        return terms.price or terms.fee or 0
    end
    return terms.fee or 0
end

-- What a character publishes: listed professions with their listed recipes.
--   { [profID] = { id, name, skill, maxSkill, categories, terms = default,
--                  recipes = { [recipeID] = cat }, custom = { [recipeID] = terms } } }
function Listings.Shareable(char)
    local out = {}
    for profID, l in pairs(char.listings or {}) do
        local p = char.professions and char.professions[profID]
        if l.on and p and next(p.recipes or {}) then
            local entry = {
                id = profID, name = p.name, skill = p.skill, maxSkill = p.maxSkill,
                categories = p.categories or {}, terms = defaultTerms(l), recipes = {}, custom = {},
            }
            for recipeID, cat in pairs(p.recipes) do
                local own = l.recipes[recipeID]
                if own ~= false then
                    entry.recipes[recipeID] = cat
                    if type(own) == "table" then
                        entry.custom[recipeID] = own
                    end
                end
            end
            if next(entry.recipes) then
                out[profID] = entry
            end
        end
    end
    return out
end

-- Number of listed recipes and how many have their own terms.
function Listings.Counts(l, profession)
    local listed, custom, total = 0, 0, 0
    for recipeID in pairs(profession and profession.recipes or {}) do
        total = total + 1
        local own = l and l.recipes and l.recipes[recipeID]
        if own ~= false then
            listed = listed + 1
        end
        if type(own) == "table" then
            custom = custom + 1
        end
    end
    return listed, custom, total
end

-- Codec ---------------------------------------------------------------------
--   B:1:<hash>
--   N:<class>                            (not part of the hash)
--   P:<prof>:<skill>:<max>:<terms>:<name>
--   C:<prof>:<cat>=<parent>=<name>;…
--   I:<prof>:<recipe>.<cat>,…            listed on the default terms
--   X:<prof>:<recipe>.<cat>.<terms>,…    listed on their own terms
--   E:<hash>
-- terms = <mats code>/<fee>/<price or empty>/<tips 0|1>

function Listings.EncodeTerms(t)
    return table.concat({ Listings.MATS_CODE[t.mats] or "b", math.floor(t.fee or 0), t.price and math.floor(t.price) or "", t.tips and 1 or 0 }, "/")
end

function Listings.DecodeTerms(text)
    local mats, fee, price, tips = (text or ""):match("^(%a)/(%d+)/(%d*)/([01])$")
    if not mats then
        return nil
    end
    return { mats = FROM_CODE[mats] or "bring", fee = tonumber(fee), price = tonumber(price), tips = tips == "1" }
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function clean(text)
    return (tostring(text or ""):gsub("[:;=,]", " "))
end

local function body(shared)
    local lines = {}
    for _, id in ipairs(sortedKeys(shared)) do
        local p = shared[id]
        lines[#lines + 1] = string.format("P:%d:%d:%d:%s:%s", id, p.skill or 0, p.maxSkill or 0, Listings.EncodeTerms(p.terms), clean(p.name))
        local cats = {}
        for _, cat in ipairs(sortedKeys(p.categories)) do
            local c = p.categories[cat]
            cats[#cats + 1] = cat .. "=" .. (c.parent or 0) .. "=" .. clean(c.name)
        end
        ns.Sync.Chunk(lines, "C:" .. id .. ":", cats, ";")
        local plain, custom = {}, {}
        for _, recipe in ipairs(sortedKeys(p.recipes)) do
            local cat = p.recipes[recipe] or 0
            if p.custom[recipe] then
                custom[#custom + 1] = recipe .. "." .. cat .. "." .. Listings.EncodeTerms(p.custom[recipe])
            else
                plain[#plain + 1] = recipe .. "." .. cat
            end
        end
        ns.Sync.Chunk(lines, "I:" .. id .. ":", plain, ",")
        ns.Sync.Chunk(lines, "X:" .. id .. ":", custom, ",")
    end
    return lines
end

-- Fingerprint of everything published; "0" when nothing is.
function Listings.Hash(shared)
    if not next(shared) then
        return "0"
    end
    return ns.Sync.Djb2(table.concat(body(shared), "\n"))
end

-- class (e.g. "WARRIOR") rides along in an N line outside the hash, so
-- people outside your guild see your name in class colour.
function Listings.Encode(shared, class)
    local lines = body(shared)
    local hash = ns.Sync.Djb2(table.concat(lines, "\n"))
    table.insert(lines, 1, "B:" .. ns.Sync.VERSION .. ":" .. hash)
    if class then
        table.insert(lines, 2, "N:" .. clean(class))
    end
    lines[#lines + 1] = "E:" .. hash
    return lines, hash
end

-- Feed(line) returns (professions, hash, class) once a complete transfer
-- arrived.
-- Decoded professions look like Shareable()'s, plus terms per recipe in
-- custom.
function Listings.NewDecoder()
    local pending
    local decoder = {}
    function decoder.Feed(line)
        local kind, rest = line:match("^(%u):(.*)$")
        if kind == "B" then
            local version, hash = rest:match("^(%d+):(%x+)$")
            pending = version == ns.Sync.VERSION and { hash = hash, professions = {}, lines = {} } or nil
            return nil
        elseif not pending then
            return nil
        elseif kind == "E" then
            local done = pending
            pending = nil
            if rest == done.hash and ns.Sync.Djb2(table.concat(done.lines, "\n")) == done.hash then
                return done.professions, done.hash, done.class
            end
            return nil
        elseif kind == "N" then
            pending.class = rest ~= "" and rest or nil
            return nil
        end
        pending.lines[#pending.lines + 1] = line
        if kind == "P" then
            local id, skill, maxSkill, terms, name = rest:match("^(%d+):(%d+):(%d+):([^:]+):(.*)$")
            terms = Listings.DecodeTerms(terms)
            if id and terms then
                pending.professions[tonumber(id)] = {
                    id = tonumber(id), name = name, skill = tonumber(skill), maxSkill = tonumber(maxSkill),
                    terms = terms, recipes = {}, categories = {}, custom = {},
                }
            end
            return nil
        end
        local id, list = rest:match("^(%d+):(.*)$")
        local p = id and pending.professions[tonumber(id)]
        if not p then
            return nil
        end
        if kind == "C" then
            for cat, parent, name in list:gmatch("(%d+)=(%d+)=([^;]*)") do
                p.categories[tonumber(cat)] = { name = name, parent = tonumber(parent) }
            end
        elseif kind == "I" then
            for recipe, cat in list:gmatch("(%d+)%.(%d+)") do
                p.recipes[tonumber(recipe)] = tonumber(cat)
            end
        elseif kind == "X" then
            for recipe, cat, terms in list:gmatch("(%d+)%.(%d+)%.([^,]+)") do
                local t = Listings.DecodeTerms(terms)
                if t then
                    p.recipes[tonumber(recipe)] = tonumber(cat)
                    p.custom[tonumber(recipe)] = t
                end
            end
        end
        return nil
    end
    return decoder
end
