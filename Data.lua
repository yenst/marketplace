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

local function ownState(c, rosterEntry)
    if c.current then
        return "you"
    end
    if rosterEntry and rosterEntry.online then
        return "noaddon"
    end
    return "offline"
end

local function findUnambiguousMatch(pool, cls, skipPartial)
    local matched
    for _, cand in ipairs(pool) do
        local classOk = cls == true or not cand.class or cand.class == cls
        if not skipPartial[cand.short] and classOk then
            if matched then
                return nil -- ambiguous: multiple guildmates share this first name
            end
            matched = cand.short
        end
    end
    return matched
end

-- Only suppress a synced guildmate for a partial own character when the
-- first-name + class match is unambiguous (never hide other people who
-- share the same first name).
local function buildPartialSkips(partial, guildData, roster, taken)
    local candidates = {}
    for sender, entry in pairs(guildData or {}) do
        local short = Data.ShortName(sender)
        local first = short:match("^(%S+) ")
        if first and partial[first] and not taken[short] and next(entry.professions or {}) then
            local r = (roster or {})[short]
            candidates[first] = candidates[first] or {}
            candidates[first][#candidates[first] + 1] = { short = short, class = r and r.class }
        end
    end
    local skipPartial = {}
    for first, classes in pairs(partial) do
        local pool = candidates[first] or {}
        for _, cls in ipairs(classes) do
            local matched = findUnambiguousMatch(pool, cls, skipPartial)
            if matched then
                skipPartial[matched] = true
            end
        end
    end
    return skipPartial
end

local function guildCrafterState(sender, rosterEntry, seen)
    if rosterEntry and not rosterEntry.online then
        return "offline" -- logged off since we last heard from them
    end
    if (seen or {})[sender] then
        return "addon"
    end
    if rosterEntry and rosterEntry.online then
        return "noaddon"
    end
    return "offline"
end

-- ctx = {
--   own = { { key, name, class, professions, current = bool, partial = bool }, ... }
--   guildData = { [sender] = { professions, updated } }            synced guildmates
--   roster = { [shortName] = { online, class, lastOnline } }       guild roster
--   seen = { [sender] = time }                                     running the addon this session
--   trustRoster = bool   roster is complete: hide synced people not on it (left the guild)
-- }
-- Own characters may lack the full name others see them by ("Billy" for
-- "Billy Joel", own = { …, partial = true }); a synced entry whose first
-- name and class unambiguously match one of those is skipped.
-- Returns { { key, name, class, state, lastOnline, updated, professions, mine } }.
function Data.Crafters(ctx)
    local list, taken, partial = {}, {}, {}
    for _, c in ipairs(ctx.own or {}) do
        local short = Data.ShortName(c.name)
        local key = c.key or (taken[short] and (short .. "#" .. (#list + 1)) or short)
        if c.partial then
            partial[short] = partial[short] or {}
            partial[short][#partial[short] + 1] = c.class or true
        end
        local r = (ctx.roster or {})[short]
        list[#list + 1] = {
            key = key, name = short, class = c.class, mine = true, professions = c.professions or {},
            state = ownState(c, r),
            lastOnline = r and r.lastOnline,
        }
        taken[short] = true
    end
    local skipPartial = buildPartialSkips(partial, ctx.guildData, ctx.roster, taken)
    for sender, entry in pairs(ctx.guildData or {}) do
        local short = Data.ShortName(sender)
        local r = (ctx.roster or {})[short]
        local left = ctx.trustRoster and not r and not (ctx.seen or {})[sender]
        if not taken[short] and not skipPartial[short] and not left and next(entry.professions or {}) then
            list[#list + 1] = {
                key = short, name = short, class = r and r.class,
                state = guildCrafterState(sender, r, ctx.seen),
                lastOnline = r and r.lastOnline, updated = entry.updated,
                professions = entry.professions or {},
            }
            taken[short] = true
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function indexRecipe(recipes, profID, profName, categories, recipeID, cat, crafter)
    local r = recipes[recipeID]
    local c = categories and categories[cat]
    if not r then
        r = { id = recipeID, prof = profID, profName = profName, cat = cat, catName = c and c.name or "Other", crafters = {} }
        recipes[recipeID] = r
    elseif cat and cat ~= 0 and (r.cat == 0 or r.catName == "Other") then
        if c and c.name then
            r.cat, r.catName = cat, c.name
        elseif r.cat == 0 then
            r.cat = cat
        end
    end
    r.crafters[#r.crafters + 1] = crafter
end

local function mergeCatalogProfession(recipes, profID, profName, entries)
    for recipeID, entry in pairs(entries) do
        local r = recipes[recipeID]
        if not r then
            r = { id = recipeID, prof = profID, profName = profName, cat = 0, catName = "Other", crafters = {} }
            recipes[recipeID] = r
        end
        r.source, r.skill = entry, entry.s
    end
end

local function compareCrafters(a, b)
    local oa, ob = Data.STATE_ORDER[a.state], Data.STATE_ORDER[b.state]
    if oa ~= ob then
        return oa < ob
    end
    return a.name < b.name
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
                indexRecipe(recipes, profID, prof.name, p.categories, recipeID, cat, crafter)
            end
        end
    end
    for profID, entries in pairs(catalog or {}) do
        if not Data.GATHERING[profID] then
            local prof = professions[profID]
            local profName = (prof and prof.name) or (names and names[profID]) or ("Profession " .. profID)
            mergeCatalogProfession(recipes, profID, profName, entries)
        end
    end
    for _, r in pairs(recipes) do
        table.sort(r.crafters, compareCrafters)
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

-- Group sort sentinels: Favorites first, uncategorised recipes after real
-- category IDs, and "Not in your guild" last in both profession and All views.
local SORT_FAVORITES_ALL = ""
local SORT_FAVORITES_PROF = -1
local SORT_OTHER_CAT = 2 ^ 52
local SORT_NOBODY_PROF = 2 ^ 53
local SORT_NOBODY_ALL = "\255"

local function countOnline(crafters)
    local n = 0
    for _, c in ipairs(crafters) do
        if online(c.state) then
            n = n + 1
        end
    end
    return n
end

local function groupKey(profFilter, favorite, nobody, recipe)
    if favorite then
        return Data.FAVORITES
    end
    if nobody then
        return Data.NOBODY
    end
    if profFilter == "all" then
        return recipe.profName
    end
    return recipe.catName
end

-- The game numbers a profession's categories in the order its window shows
-- them; uncategorised recipes go last. Favourites come first in either view.
local function groupSortKey(profFilter, favorite, nobody, recipe)
    local isAll = profFilter == "all"
    if favorite then
        return isAll and SORT_FAVORITES_ALL or SORT_FAVORITES_PROF
    end
    if nobody then
        return isAll and SORT_NOBODY_ALL or SORT_NOBODY_PROF
    end
    if isAll then
        return recipe.profName
    end
    return recipe.cat == 0 and SORT_OTHER_CAT or recipe.cat
end

local function ensureGroup(acc, key, sortValue)
    if not acc.groups[key] then
        acc.groups[key] = {}
        acc.order[#acc.order + 1] = key
        acc.sortKey[key] = sortValue
    end
    return acc.groups[key]
end

local function collectRecipe(id, r, filter, query, metaOf, itemName, acc)
    -- Cheap checks first: the catalog has ~2000 recipes.
    if filter.prof ~= "all" and filter.prof ~= r.prof then
        return
    end
    local nobody = #r.crafters == 0
    if nobody and filter.prof == "all" and query == "" then
        return
    end
    if filter.member and not Data.Knows(r, filter.member) then
        return
    end
    local on = countOnline(r.crafters)
    if filter.onlineOnly and on == 0 then
        return
    end
    local favorite = filter.favorites and filter.favorites[id] or false
    local collapsedNobody = not favorite and nobody and query == "" and filter.collapsed and filter.collapsed[Data.NOBODY]
    if collapsedNobody then
        ensureGroup(acc, Data.NOBODY, groupSortKey(filter.prof, false, true, r))
        acc.collapsedCounts[Data.NOBODY] = (acc.collapsedCounts[Data.NOBODY] or 0) + 1
        acc.count = acc.count + 1
        return
    end
    local meta = metaOf(id) or {}
    if not matches(r, meta, query, itemName) then
        return
    end
    local key = groupKey(filter.prof, favorite, nobody, r)
    local list = ensureGroup(acc, key, groupSortKey(filter.prof, favorite, nobody, r))
    list[#list + 1] = {
        recipe = r,
        name = meta.name or ("Recipe " .. id),
        online = on,
        total = #r.crafters,
        favorite = favorite,
        skill = r.skill,
    }
    acc.count = acc.count + 1
end

Data.SORTS = {
    { key = "name", label = "Name (A-Z)", buttonLabel = "Sort: Name" },
    { key = "skill_asc", label = "Skill (low to high)", buttonLabel = "Sort: Skill low-high" },
    { key = "skill_desc", label = "Skill (high to low)", buttonLabel = "Sort: Skill high-low" },
    { key = "online", label = "Online first", buttonLabel = "Sort: Online" },
    { key = "crafters", label = "Most crafters", buttonLabel = "Sort: Crafters" },
}

local SORT_BY_KEY = {}
for _, s in ipairs(Data.SORTS) do
    SORT_BY_KEY[s.key] = s
end

-- Returns the Data.SORTS entry for key, or nil if unknown.
function Data.SortInfo(key)
    return key and SORT_BY_KEY[key] or nil
end

local SKILL_UNKNOWN_ASC = math.huge
local SKILL_UNKNOWN_DESC = -1

local function compareByName(a, b)
    return a.name < b.name
end

local function compareBySkillAsc(a, b)
    local sa, sb = a.skill or SKILL_UNKNOWN_ASC, b.skill or SKILL_UNKNOWN_ASC
    if sa ~= sb then
        return sa < sb
    end
    return a.name < b.name
end

local function compareBySkillDesc(a, b)
    local sa, sb = a.skill or SKILL_UNKNOWN_DESC, b.skill or SKILL_UNKNOWN_DESC
    if sa ~= sb then
        return sa > sb
    end
    return a.name < b.name
end

local function compareByOnline(a, b)
    if a.online ~= b.online then
        return a.online > b.online
    end
    if a.total ~= b.total then
        return a.total > b.total
    end
    return a.name < b.name
end

local function compareByCrafters(a, b)
    if a.total ~= b.total then
        return a.total > b.total
    end
    if a.online ~= b.online then
        return a.online > b.online
    end
    return a.name < b.name
end

local SORT_COMPARATORS = {
    name = compareByName,
    skill_asc = compareBySkillAsc,
    skill_desc = compareBySkillDesc,
    online = compareByOnline,
    crafters = compareByCrafters,
}

local function rowComparator(groupName, sort)
    if (not sort or sort == "name") and groupName == Data.NOBODY then
        return compareBySkillAsc
    end
    return SORT_COMPARATORS[sort] or compareByName
end

-- The recipe list the window draws: headers and rows. Favourite recipes are
-- grouped under a "Favorites" header at the top instead of their category;
-- recipes nobody in the guild has go under "Not in your guild" at the
-- bottom, by required skill by default (in All professions only when searching).
--   filter = { prof = "all" | profID, query, onlineOnly, collapsed = { [header] = true },
--              member = crafter key (only that member's patterns) or nil,
--              favorites = { [recipeID] = true },
--              sort = "name" | "skill_asc" | "skill_desc" | "online" | "crafters" }
--   metaOf(recipeID) -> { name, item, reagents } (name may be nil while loading)
--   itemName(itemID) -> name or nil
-- Returns items = { { header = true, label, count, collapsed } | { recipe, name, online, total } }
-- and the number of matching recipes.
function Data.List(recipes, filter, metaOf, itemName)
    local query = (filter.query or ""):match("^%s*(.-)%s*$"):lower()
    local acc = { groups = {}, order = {}, sortKey = {}, collapsedCounts = {}, count = 0 }
    for id, r in pairs(recipes) do
        collectRecipe(id, r, filter, query, metaOf, itemName, acc)
    end
    table.sort(acc.order, function(a, b)
        if acc.sortKey[a] == acc.sortKey[b] then
            return a < b
        end
        return acc.sortKey[a] < acc.sortKey[b]
    end)
    local items = {}
    for _, key in ipairs(acc.order) do
        local rows = acc.groups[key]
        local collapsed = filter.collapsed and filter.collapsed[key] or false
        items[#items + 1] = {
            header = true,
            label = key,
            count = acc.collapsedCounts[key] or #rows,
            collapsed = collapsed,
            favorites = key == Data.FAVORITES,
        }
        if not collapsed then
            table.sort(rows, rowComparator(key, filter.sort))
            for _, row in ipairs(rows) do
                items[#items + 1] = row
            end
        end
    end
    return items, acc.count
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

local function addRecipeMembers(byKey, recipe, prof)
    for _, c in ipairs(recipe.crafters) do
        local m = byKey[c.key]
        if not m then
            local p = prof ~= "all" and c.professions and c.professions[prof]
            m = { key = c.key, name = c.name, class = c.class, state = c.state, count = 0, skill = p and p.skill }
            byKey[c.key] = m
        end
        m.count = m.count + 1
    end
end

-- Members for the member filter, by name: those with any patterns in the
-- profession (or any at all). { { key, name, class, state, count, skill } }
-- (skill: their level in that profession; nil for "all")
function Data.Members(recipes, prof)
    local byKey = {}
    for _, r in pairs(recipes) do
        if prof == "all" or r.prof == prof then
            addRecipeMembers(byKey, r, prof)
        end
    end
    local list = {}
    for _, m in pairs(byKey) do
        list[#list + 1] = m
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Right-hand text of a recipe row (under the "Skill" column header): required
-- skill number when known, plus crafter count when sorting by crafters/online.
function Data.CrafterText(row, sort)
    local skillText = row.skill and tostring(row.skill) or nil
    if row.total == 0 then
        return skillText or ""
    end
    if sort == "crafters" or sort == "online" then
        local countText = ns.Plural(row.total, "crafter")
        return skillText and (countText .. " · " .. skillText) or countText
    end
    return skillText or ""
end

-- Status line under a crafter's name (nothing when online: the green dot
-- and coloured name say it; offline: when they were last seen).
function Data.StatusText(crafter, now)
    if crafter.state == "you" then
        return "You"
    elseif crafter.state == "addon" or crafter.state == "noaddon" then
        return "" -- the green dot says it
    end
    local ago = crafter.lastOnline
    if not ago and crafter.updated and now then
        ago = now - crafter.updated
    end
    if not ago then
        return crafter.mine and "Your character" or "Offline"
    end
    return (crafter.mine and "Your character · seen " or "Seen ") .. Data.Ago(ago) .. " ago"
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

local function vendorSourceText(entry, side, lookup)
    local where = zones(entry.v, side, 1, lookup)
    local text
    if #where > 0 then
        text = "Sold in " .. table.concat(where, ", ")
    elseif entry.v then
        text = "Sold by the other faction"
    else
        text = "Sold by a vendor"
    end
    if entry.mf then
        text = text .. " · " .. lookup.favor(entry.mf)
    end
    return text
end

local function questSourceText(entry, side, lookup)
    local parts = {}
    for _, quest in ipairs(entry.q or {}) do
        if not quest[3] or quest[3] == side then
            local title = lookup.quest(quest[1]) or "A quest"
            local zone = quest[2] and quest[2] > 0 and lookup.zone(quest[2])
            parts[#parts + 1] = zone and zone ~= "" and (title .. " in " .. zone) or title
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or "A quest for the other faction"
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
    if src:find("a", 1, true) then add("Known", "Every crafter starts with it") end
    if src:find("t", 1, true) then add("Trainer", entry.cost and lookup.money(entry.cost) or "") end
    if src:find("v", 1, true) then add("Vendor", vendorSourceText(entry, side, lookup)) end
    if src:find("q", 1, true) then add("Quest", questSourceText(entry, side, lookup)) end
    if src:find("d", 1, true) then add("Drop", "Dropped by monsters") end
    if src:find("c", 1, true) then add("Crafted", "Made by another profession") end
    if src:find("w", 1, true) then add("World", "Found in the world") end
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

-- Pattern tooltips ---------------------------------------------------------------

-- Recipe items (patterns, plans, …) to the recipe they teach:
-- { [itemID] = { recipe = recipeID, prof, skill } }.
function Data.PatternIndex(catalog)
    local index = {}
    for profID, entries in pairs(catalog or {}) do
        for recipeID, entry in pairs(entries) do
            if entry.t and not index[entry.t] then
                index[entry.t] = { recipe = recipeID, prof = profID, skill = entry.s or 0 }
            end
        end
    end
    return index
end

-- Who knows a recipe, who has the profession at the skill it needs but
-- hasn't learned it, and who has the profession below that skill: three
-- lists of { name, skill, class, state }, by name (the last by skill, highest
-- first).
--   recipe = Data.Index entry (or nil), crafters = Data.Crafters list
function Data.PatternPeople(recipe, crafters, prof, skill)
    local known, canLearn, tooLow, knows = {}, {}, {}, {}
    for _, c in ipairs(recipe and recipe.crafters or {}) do
        knows[c.key] = true
        local p = c.professions and c.professions[prof]
        known[#known + 1] = { name = c.name, skill = p and p.skill, class = c.class, state = c.state }
    end
    for _, c in ipairs(crafters or {}) do
        local p = c.professions and c.professions[prof]
        if p and not knows[c.key] then
            local person = { name = c.name, skill = p.skill, class = c.class, state = c.state }
            if (p.skill or 0) >= (skill or 0) then
                canLearn[#canLearn + 1] = person
            else
                tooLow[#tooLow + 1] = person
            end
        end
    end
    local byName = function(a, b) return a.name < b.name end
    table.sort(known, byName)
    table.sort(canLearn, byName)
    table.sort(tooLow, function(a, b)
        if (a.skill or 0) ~= (b.skill or 0) then
            return (a.skill or 0) > (b.skill or 0)
        end
        return a.name < b.name
    end)
    return known, canLearn, tooLow
end

-- Crafted item tooltips ----------------------------------------------------------

-- Items to the recipes that make them: { [itemID] = { recipeID, ... } }.
function Data.CraftedIndex(catalog)
    local index = {}
    for _, entries in pairs(catalog or {}) do
        for recipeID, entry in pairs(entries) do
            if entry.c then
                index[entry.c] = index[entry.c] or {}
                table.insert(index[entry.c], recipeID)
            end
        end
    end
    for _, list in pairs(index) do
        table.sort(list)
    end
    return index
end

-- Everyone who knows one of the recipes, online first, then by name:
-- { { name, skill, class, state, offline } }.
--   recipeIDs = a Data.CraftedIndex entry, recipes = Data.Index recipes
function Data.Makers(recipeIDs, recipes)
    local list, seen = {}, {}
    for _, id in ipairs(recipeIDs or {}) do
        local r = recipes[id]
        for _, c in ipairs(r and r.crafters or {}) do
            if not seen[c.key] then
                seen[c.key] = true
                local p = c.professions and c.professions[r.prof]
                list[#list + 1] = { name = c.name, skill = p and p.skill, class = c.class, state = c.state, offline = not online(c.state) }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.offline ~= b.offline then
            return b.offline
        end
        return a.name < b.name
    end)
    return list
end

-- Refresh button -----------------------------------------------------------------

-- The line next to the Refresh button, from Sync.RefreshState().
function Data.RefreshText(phase, got, total)
    if phase == "checking" then
        return "Checking with the guild…"
    elseif phase == "updating" then
        return total > 0 and string.format("Updating: %d of %d", got, total) or "Comparing with the guild…"
    elseif phase == "current" then
        return "Up to date"
    elseif phase == "alone" then
        return "Nobody else with Marketplace is online"
    elseif phase == "updated" then
        return "Updated " .. ns.Plural(got, "guildmate")
    elseif phase == "partial" then
        return string.format("Updated %d of %d; the rest will follow", got, total)
    end
    return ""
end
