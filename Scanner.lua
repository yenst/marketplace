local _, ns = ...

-- Reads the open profession window through Forever's C_TradeSkillUI and
-- stores what this character can craft. GetAllRecipeIDs lists every recipe of
-- the profession, learned or not; only learned ones count as craftable, but
-- all of them go into the shared recipe cache (name, icon, output, reagents),
-- so recipes guildmates share can be shown even if nobody here knows them.
local Scanner = {}
ns.Scanner = Scanner

-- Recipes that aren't something you'd ask a crafter for.
local function skipped(info)
    return info.isDummyRecipe or info.isRecraft or info.isSalvageRecipe or info.isGatheringRecipe
end

-- { {itemID, count}, ... } from a recipe schematic's required reagent slots.
local function reagentsOf(schematic)
    local out = {}
    for _, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        if slot.required ~= false and type(first) == "table" and first.itemID then
            out[#out + 1] = { first.itemID, slot.quantityRequired or 1 }
        end
    end
    return out
end

-- Pure scan: returns the profession record and recipe metadata, or nil when
-- the window isn't showing this character's own, ready profession.
--   profession = { id, name, skill, maxSkill, recipes = { [recipeID] = categoryID },
--                  categories = { [categoryID] = { name, parent } } }
--   meta       = { [recipeID] = { name, icon, item, prof, cat, reagents } }
function Scanner.Collect(T)
    if type(T) ~= "table" or not T.IsTradeSkillReady or not T.IsTradeSkillReady() then
        return nil
    end
    if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
        or (T.IsNPCCrafting and T.IsNPCCrafting()) then
        return nil
    end
    local base = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    if not base or not base.professionID or base.professionID == 0 then
        return nil
    end
    local profession = {
        id = base.professionID,
        name = base.professionName,
        skill = base.skillLevel or 0,
        maxSkill = base.maxSkillLevel or 0,
        recipes = {},
        categories = {},
    }
    local meta = {}

    local function addCategory(id)
        if not id or id == 0 or profession.categories[id] or not T.GetCategoryInfo then
            return
        end
        local c = T.GetCategoryInfo(id)
        if c and c.name then
            profession.categories[id] = { name = c.name, parent = c.parentCategoryID }
            addCategory(c.parentCategoryID)
        end
    end

    for _, id in ipairs(T.GetAllRecipeIDs and T.GetAllRecipeIDs() or {}) do
        local info = T.GetRecipeInfo(id)
        if info and not skipped(info) then
            local cat = info.categoryID or 0
            local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(id, false)
            meta[id] = {
                name = info.name,
                icon = info.icon,
                item = schematic and schematic.outputItemID,
                prof = profession.id,
                cat = cat,
                reagents = reagentsOf(schematic),
            }
            if info.learned then
                profession.recipes[id] = cat
                addCategory(cat)
            end
        end
    end
    return profession, meta
end

-- Saves a scan for the current character. Returns the profession record.
function Scanner.Store(char, profession, meta, now)
    if not profession then
        return nil
    end
    profession.scannedAt = now
    char.professions = char.professions or {}
    char.professions[profession.id] = profession
    local cache = ns.db.recipes
    for id, m in pairs(meta) do
        cache[id] = m
    end
    return profession
end

-- Number of learned recipes in a profession record.
function Scanner.Count(profession)
    local n = 0
    for _ in pairs(profession and profession.recipes or {}) do
        n = n + 1
    end
    return n
end

-- Event wiring: scan shortly after the list settles, at most once per burst.
local pending = false
function Scanner.Queue()
    if pending then
        return
    end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        if not ns.char then
            return
        end
        local profession, meta = Scanner.Collect(C_TradeSkillUI)
        local stored = Scanner.Store(ns.char, profession, meta, time())
        if stored then
            if ns.db.settings.debug then
                ns.Print(string.format("scanned %s: %d recipes", stored.name, Scanner.Count(stored)))
            end
            ns.Refresh()
        end
    end)
end
