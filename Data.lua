local _, ns = ...

-- The browser's model, kept free of UI code so it can be tested: who can
-- craft what (your characters plus what guildmates synced), their online
-- state, and the grouped, filtered recipe list the window draws.
local Data = {}
ns.Data = Data

-- Display order of crafter states in a recipe's crafter list.
Data.STATE_ORDER = { you = 0, addon = 1, noaddon = 2, offline = 3 }

-- "Billy Joel-Realm" -> "Billy Joel". Forever sends names without a realm,
-- the roster may add one; this lines them up.
function Data.ShortName(name)
    return (tostring(name or ""):gsub("%-[^%-]*$", ""))
end

local function online(state)
    return state ~= "offline"
end

-- ctx = {
--   own = { { name, class, professions, current = bool }, ... }   your characters in this guild
--   guildData = { [sender] = { professions, updated } }            synced guildmates
--   roster = { [shortName] = { online, class, lastOnline } }       guild roster
--   seen = { [sender] = time }                                     running the addon this session
-- }
-- Returns { { key, name, class, state, lastOnline, updated, professions, mine } }.
function Data.Crafters(ctx)
    local list, taken = {}, {}
    for _, c in ipairs(ctx.own or {}) do
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
        if not taken[short] then
            local r = (ctx.roster or {})[short]
            local state = "offline"
            if (ctx.seen or {})[sender] then
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

-- recipes = { [recipeID] = { prof, profName, cat, catName, crafters = {...} } }
-- professions = { [profID] = { id, name, crafters = { [key] = crafter } } }
function Data.Index(crafters)
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
    local byId, list = {}, {}
    local function add(id, name)
        if Data.GATHERING[id] or byId[id] then
            return
        end
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

-- The recipe list the window draws: headers and rows.
--   filter = { prof = "all" | profID, query, onlineOnly, collapsed = { [header] = true } }
--   metaOf(recipeID) -> { name, item, reagents } (name may be nil while loading)
--   itemName(itemID) -> name or nil
-- Returns items = { { header = true, label, count, collapsed } | { recipe, name, online, total } }
-- and the number of matching recipes.
function Data.List(recipes, filter, metaOf, itemName)
    local query = (filter.query or ""):lower()
    local groups, order = {}, {}
    local count = 0
    for id, r in pairs(recipes) do
        if filter.prof == "all" or filter.prof == r.prof then
            local meta = metaOf(id) or {}
            local on = 0
            for _, c in ipairs(r.crafters) do
                if online(c.state) then
                    on = on + 1
                end
            end
            if (not filter.onlineOnly or on > 0) and matches(r, meta, query, itemName) then
                local key = filter.prof == "all" and r.profName or r.catName
                if not groups[key] then
                    groups[key] = {}
                    order[#order + 1] = key
                end
                local list = groups[key]
                list[#list + 1] = { recipe = r, name = meta.name or ("Recipe " .. id), online = on, total = #r.crafters }
                count = count + 1
            end
        end
    end
    table.sort(order)
    local items = {}
    for _, key in ipairs(order) do
        local rows = groups[key]
        table.sort(rows, function(a, b) return a.name < b.name end)
        local collapsed = filter.collapsed and filter.collapsed[key] or false
        items[#items + 1] = { header = true, label = key, count = #rows, collapsed = collapsed }
        if not collapsed then
            for _, row in ipairs(rows) do
                items[#items + 1] = row
            end
        end
    end
    return items, count
end

-- "2 · 1 online", "3 · offline"
function Data.CrafterText(row)
    if row.online > 0 then
        return string.format("%d · %d online", row.total, row.online)
    end
    return string.format("%d · offline", row.total)
end

-- Status line under a crafter's name.
function Data.StatusText(crafter, now)
    if crafter.state == "you" then
        return "You"
    elseif crafter.state == "addon" then
        return "Online"
    elseif crafter.state == "noaddon" then
        return "Online · Marketplace not running"
    end
    local ago = crafter.lastOnline
    if not ago and crafter.updated and now then
        ago = now - crafter.updated
    end
    if not ago then
        return crafter.mine and "Your character" or "Offline"
    end
    local text
    if ago < 3600 then
        text = math.max(1, math.floor(ago / 60)) .. "m"
    elseif ago < 86400 then
        text = math.floor(ago / 3600) .. "h"
    else
        text = math.floor(ago / 86400) .. "d"
    end
    return (crafter.mine and "Your character · " or "Offline · ") .. "seen " .. text .. " ago"
end
