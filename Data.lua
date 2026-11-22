local _, ns = ...

-- The browser's model, kept free of UI code so it can be tested: who can
-- craft what (your characters plus what guildmates synced), their online
-- state, and the grouped, filtered recipe list the window draws.
local Data = {}
ns.Data = Data

-- Display order of crafter states in a recipe's crafter list.
Data.STATE_ORDER = { you = 0, addon = 1, noaddon = 2, offline = 3 }
local ONLINE = { you = true, addon = true, noaddon = true }

-- "Billy Joel-Realm" -> "Billy Joel". Forever sends names without a realm,
-- the roster may add one; this lines them up.
function Data.ShortName(name)
    return (tostring(name or ""):gsub("%-[^%-]*$", ""))
end

local function online(state)
    return ONLINE[state] == true
end
Data.IsOnline = online

-- ctx = {
--   own = { { name, class, professions, current = bool }, ... }   your characters in this guild
--   guildData = { [sender] = { professions, updated } }            synced guildmates
--   roster = { [shortName] = { online, class, lastOnline } }       guild roster
--   seen = { [sender] = time }                                     running the addon this session
--   trustRoster = bool   roster is complete: hide synced people not on it (left the guild)
-- }
-- Own characters may lack the full name others see them by ("Billy" for
-- "Billy Joel", own = { …, partial = true }); a synced entry whose first
-- name and class match one of those is that character, so it's skipped.
-- Returns { { key, name, class, state, lastOnline, updated, professions, mine } }.
function Data.Crafters(ctx)
    local list, taken, partial = {}, {}, {}
    for _, c in ipairs(ctx.own or {}) do
        if c.partial then
            partial[c.name] = c.class or true
        end
        local short = Data.ShortName(c.name)
        local r = (ctx.roster or {})[short]
        list[#list + 1] = {
            key = short, name = short, class = c.class, mine = true, professions = c.professions or {},
            state = c.current and "you" or (r and r.online and "noaddon" or "offline"),
            lastOnline = r and r.lastOnline,
        }
        taken[short] = true
    end
    for sender, entry in pairs(ctx.guildData or {}) do
        local short = Data.ShortName(sender)
        local r = (ctx.roster or {})[short]
        local first = short:match("^(%S+) ")
        local mineToo = first and partial[first] and (partial[first] == true or not r or r.class == partial[first])
        local left = ctx.trustRoster and not r and not (ctx.seen or {})[sender]
        if not taken[short] and not mineToo and not left and next(entry.professions or {}) then
            local state = "offline"
            if r and not r.online then
                state = "offline" -- logged off since we last heard from them
            elseif (ctx.seen or {})[sender] then
                state = "addon"
            elseif r and r.online then
                state = "noaddon"
            end
            list[#list + 1] = {
                key = short, name = short, class = r and r.class, state = state,
                lastOnline = r and r.lastOnline, updated = entry.updated,
                professions = entry.professions or {},
            }
            taken[short] = true
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- recipes = { [recipeID] = { prof, profName, cat, catName, crafters = {...},
--                             source (catalog entry or nil), skill } }
-- professions = { [profID] = { id, name, crafters = { [key] = crafter } } }
--   catalog = ns.RecipeDB: { [profID] = { [recipeID] = entry } }, adds every
--             recipe nobody has (with no crafters)
--   names   = { [profID] = name } for professions nobody has
function Data.Index(crafters, catalog, names)
    local recipes, professions = {}, {}
    for _, crafter in ipairs(crafters) do
        for profID, p in pairs(crafter.professions) do
            local prof = professions[profID]
            if not prof then
                prof = { id = profID, name = p.name or ("Profession " .. profID), crafters = {} }
                professions[profID] = prof
            end
            prof.crafters[crafter.key] = crafter
            for recipeID, cat in pairs(p.recipes or {}) do
                local r = recipes[recipeID]
                if not r then
                    local c = p.categories and p.categories[cat]
                    r = { id = recipeID, prof = profID, profName = prof.name, cat = cat, catName = c and c.name or "Other", crafters = {} }
                    recipes[recipeID] = r
                end
                r.crafters[#r.crafters + 1] = crafter
            end
        end
    end
    for profID, entries in pairs(catalog or {}) do
        if not Data.GATHERING[profID] then
            local profName = (professions[profID] and professions[profID].name) or (names and names[profID]) or ("Profession " .. profID)
            for recipeID, entry in pairs(entries) do
                local r = recipes[recipeID]
                if not r then
                    r = { id = recipeID, prof = profID, profName = profName, cat = 0, catName = "Other", crafters = {} }
                    recipes[recipeID] = r
                end
                r.source, r.skill = entry, entry.s
            end
        end
    end
    for _, r in pairs(recipes) do
        table.sort(r.crafters, function(a, b)
            local oa, ob = Data.STATE_ORDER[a.state], Data.STATE_ORDER[b.state]
            if oa ~= ob then
                return oa < ob
            end
            return a.name < b.name
        end)
    end
    return recipes, professions
end

-- Professions without recipes: nothing to ask a crafter for.
Data.GATHERING = { [182] = true, [393] = true, [356] = true } -- Herbalism, Skinning, Fishing

-- Fallback when the client can't list its professions.
Data.KNOWN_PROFESSIONS = {
    { id = 171, name = "Alchemy" }, { id = 164, name = "Blacksmithing" }, { id = 333, name = "Enchanting" },
    { id = 202, name = "Engineering" }, { id = 165, name = "Leatherworking" }, { id = 197, name = "Tailoring" },
    { id = 186, name = "Mining" }, { id = 185, name = "Cooking" }, { id = 129, name = "First Aid" },
}

-- Every crafting profession for the side tabs, whether anyone shares it or
-- not, sorted by name: { id, name, crafters = { [key] = crafter } }.
--   gameList = { { id, name }, ... } from the client (or KNOWN_PROFESSIONS)
function Data.Tabs(gameList, professions)
    local byId, byName, list = {}, {}, {}
    local function add(id, name)
        if Data.GATHERING[id] or byId[id] or byName[name] then
            return
        end
        byName[name] = true
        local entry = { id = id, name = name, crafters = professions[id] and professions[id].crafters or {} }
        byId[id] = entry
        list[#list + 1] = entry
    end
    for _, g in ipairs(gameList or {}) do
        if g.id and g.name and g.name ~= "" then
            add(g.id, g.name)
        end
    end
    for id, p in pairs(professions) do
        add(id, p.name)
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list, byId
end

-- Professions sorted by name, for the side tabs.
function Data.ProfessionList(professions)
    local list = {}
    for _, p in pairs(professions) do
        list[#list + 1] = p
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function matches(recipe, meta, query, itemName)
    if query == "" then
        return true
    end
    if meta.name and meta.name:lower():find(query, 1, true) then
        return true
    end
    for _, c in ipairs(recipe.crafters) do
        if c.name:lower():find(query, 1, true) then
            return true
        end
    end
    for _, reagent in ipairs(meta.reagents or {}) do
        local name = itemName(reagent[1])
        if name and name:lower():find(query, 1, true) then
            return true
        end
    end
    return false
end

Data.FAVORITES = "Favorites"
Data.NOBODY = "Not in your guild"

-- The recipe list the window draws: headers and rows. Favourite recipes are
-- grouped under a "Favorites" header at the top instead of their category;
-- recipes nobody in the guild has go under "Not in your guild" at the
-- bottom, by required skill (in All professions only when searching).
--   filter = { prof = "all" | profID, query, onlineOnly, collapsed = { [header] = true },
--              member = crafter key (only that member's patterns) or nil,
--              favorites = { [recipeID] = true } }
--   metaOf(recipeID) -> { name, item, reagents } (name may be nil while loading)
--   itemName(itemID) -> name or nil
-- Returns items = { { header = true, label, count, collapsed } | { recipe, name, online, total } }
-- and the number of matching recipes.
function Data.List(recipes, filter, metaOf, itemName)
    local query = (filter.query or ""):lower()
    local groups, order, sortKey = {}, {}, {}
    local count = 0
    for id, r in pairs(recipes) do
        local nobody = #r.crafters == 0
        -- Cheap checks first: the catalog has ~2000 recipes.
        if (filter.prof == "all" or filter.prof == r.prof) and not (nobody and filter.prof == "all" and query == "")
            and (not filter.member or Data.Knows(r, filter.member)) then
            local on = 0
            for _, c in ipairs(r.crafters) do
                if online(c.state) then
                    on = on + 1
                end
            end
            local meta = (not filter.onlineOnly or on > 0) and (metaOf(id) or {})
            if meta and matches(r, meta, query, itemName) then
                local favorite = filter.favorites and filter.favorites[id] or false
                local key = favorite and Data.FAVORITES or (nobody and Data.NOBODY)
                    or (filter.prof == "all" and r.profName or r.catName)
                if not groups[key] then
                    groups[key] = {}
                    order[#order + 1] = key
                    -- The game numbers a profession's categories in the order
                    -- its window shows them; uncategorised recipes go last.
                    -- Favourites come first in either view.
                    if favorite then
                        sortKey[key] = filter.prof == "all" and "" or -1
                    elseif nobody then
                        sortKey[key] = filter.prof == "all" and "\255" or 2 ^ 53
                    else
                        sortKey[key] = filter.prof == "all" and r.profName or (r.cat == 0 and 2 ^ 52 or r.cat)
                    end
                end
                local list = groups[key]
                list[#list + 1] = { recipe = r, name = meta.name or ("Recipe " .. id), online = on, total = #r.crafters, favorite = favorite, skill = r.skill }
                count = count + 1
            end
        end
    end
    table.sort(order, function(a, b)
        if sortKey[a] == sortKey[b] then
            return a < b
        end
        return sortKey[a] < sortKey[b]
    end)
    local items = {}
    for _, key in ipairs(order) do
        local rows = groups[key]
        if key == Data.NOBODY then
            table.sort(rows, function(a, b)
                if (a.skill or 0) ~= (b.skill or 0) then
                    return (a.skill or 0) < (b.skill or 0)
                end
                return a.name < b.name
            end)
        else
            table.sort(rows, function(a, b) return a.name < b.name end)
        end
        local collapsed = filter.collapsed and filter.collapsed[key] or false
        items[#items + 1] = { header = true, label = key, count = #rows, collapsed = collapsed, favorites = key == Data.FAVORITES }
        if not collapsed then
            for _, row in ipairs(rows) do
                items[#items + 1] = row
            end
        end
    end
    return items, count
end

-- Whether the member (crafter key) can craft a recipe.
function Data.Knows(recipe, member)
    for _, c in ipairs(recipe.crafters) do
        if c.key == member then
            return true
        end
    end
    return false
end

-- Patterns the guild (or one member) knows out of all there are, for one
-- profession or "all": known, total.
function Data.Coverage(recipes, prof, member)
    local known, total = 0, 0
    for _, r in pairs(recipes) do
        if prof == "all" or r.prof == prof then
            total = total + 1
            if (member and Data.Knows(r, member)) or (not member and #r.crafters > 0) then
                known = known + 1
            end
        end
    end
    return known, total
end

-- Members for the member filter, by name: those with any patterns in the
-- profession (or any at all). { { key, name, class, state, count } }
function Data.Members(recipes, prof)
    local byKey = {}
    for _, r in pairs(recipes) do
        if prof == "all" or r.prof == prof then
            for _, c in ipairs(r.crafters) do
                local m = byKey[c.key]
                if not m then
                    m = { key = c.key, name = c.name, class = c.class, state = c.state, count = 0 }
                    byKey[c.key] = m
                end
                m.count = m.count + 1
            end
        end
    end
    local list = {}
    for _, m in pairs(byKey) do
        list[#list + 1] = m
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Right-hand text of a recipe row: "Skill 165" when nobody has it, else
-- nothing (the green dot says someone's online).
function Data.CrafterText(row)
    if row.total == 0 then
        return row.skill and ("Skill " .. row.skill) or "Nobody"
    end
    return ""
end

-- Status line under a crafter's name.
function Data.StatusText(crafter, now)
    if crafter.state == "you" then
        return "You"
    elseif crafter.state == "addon" then
        return "Online"
    elseif crafter.state == "noaddon" then
        return "Online"
    end
    local ago = crafter.lastOnline
    if not ago and crafter.updated and now then
        ago = now - crafter.updated
    end
    if not ago then
        return crafter.mine and "Your character" or "Offline"
    end
    return (crafter.mine and "Your character · " or "Offline · ") .. "seen " .. Data.Ago(ago) .. " ago"
end

-- Seconds as "5m", "3h", "2d".
function Data.Ago(seconds)
    if seconds < 3600 then
        return math.max(1, math.floor(seconds / 60)) .. "m"
    elseif seconds < 86400 then
        return math.floor(seconds / 3600) .. "h"
    end
    return math.floor(seconds / 86400) .. "d"
end

-- Where to learn a recipe ------------------------------------------------------

-- Catalog entries by recipe ID: { [recipeID] = { entry, prof } }.
function Data.CatalogIndex(catalog)
    local index = {}
    for profID, entries in pairs(catalog or {}) do
        for recipeID, entry in pairs(entries) do
            index[recipeID] = { entry = entry, prof = profID }
        end
    end
    return index
end

local FACTION_CODE = { Alliance = "A", Horde = "H" }

-- Zone names for a list of { area, faction } (or quest { id, area, faction })
-- usable by the player's faction, without repeats.
local function zones(locations, faction, areaIndex, lookup)
    local out, seen = {}, {}
    for _, loc in ipairs(locations or {}) do
        local side = loc[areaIndex + 1]
        if not side or side == faction then
            local name = lookup.zone(loc[areaIndex])
            if name and name ~= "" and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

-- Lines saying where a recipe is learned, from its catalog entry.
--   faction = "Alliance" | "Horde"
--   lookup = { zone(areaID), quest(questID), factionName(id), standing(n),
--              money(copper), favor(n) } -> text or nil
-- Returns { { label, text } } (label: "Trainer", "Vendor", …).
function Data.Sources(entry, faction, lookup)
    if not entry then
        return {}
    end
    local side = FACTION_CODE[faction]
    local lines = {}
    local function add(label, text)
        lines[#lines + 1] = { label = label, text = text or "" }
    end
    if entry.side and entry.side ~= side then
        add("Faction", (entry.side == "A" and "Alliance" or "Horde") .. " only")
    end
    local src = entry.src or ""
    if src:find("a", 1, true) then
        add("Known", "Every crafter starts with it")
    end
    if src:find("t", 1, true) then
        add("Trainer", entry.cost and lookup.money(entry.cost) or "")
    end
    if src:find("v", 1, true) then
        local where = zones(entry.v, side, 1, lookup)
        local text = #where > 0 and ("Sold in " .. table.concat(where, ", ")) or (entry.v and "Sold by the other faction" or "Sold by a vendor")
        if entry.mf then
            text = text .. " · " .. lookup.favor(entry.mf)
        end
        add("Vendor", text)
    end
    if src:find("q", 1, true) then
        local parts = {}
        for _, quest in ipairs(entry.q or {}) do
            if not quest[3] or quest[3] == side then
                local title = lookup.quest(quest[1])
                local zone = quest[2] and quest[2] > 0 and lookup.zone(quest[2])
                parts[#parts + 1] = (title or "A quest") .. (zone and zone ~= "" and (" in " .. zone) or "")
            end
        end
        add("Quest", #parts > 0 and table.concat(parts, "; ") or "A quest for the other faction")
    end
    if src:find("d", 1, true) then
        add("Drop", "Dropped by monsters")
    end
    if src:find("c", 1, true) then
        add("Crafted", "Made by another profession")
    end
    if src:find("w", 1, true) then
        add("World", "Found in the world")
    end
    for i = 1, #(entry.rep or {}), 2 do
        local name = lookup.factionName(entry.rep[i])
        if name then
            add("Reputation", "Needs " .. lookup.standing(entry.rep[i + 1]) .. " with " .. name)
        end
    end
    if #lines == 0 then
        add("Source", "Unknown")
    end
    return lines
end

