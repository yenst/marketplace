local _, ns = ...

-- Reads the open profession window through Forever's C_TradeSkillUI and
-- stores what this character can craft. GetAllRecipeIDs lists every recipe of
-- the profession, learned or not; only learned ones count as craftable, but
-- all of them go into the shared recipe cache (name, icon, output, reagents),
-- so recipes guildmates share can be shown even if nobody here knows them.
local Scanner = {}
ns.Scanner = Scanner
-- Session-only metadata cache (not saved to SavedVariables so patches and
-- locale changes stay fresh and SavedVariables stay small).
Scanner.Cache = {}

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

-- Walks a category and its ancestors into `categories`, stopping on missing or
-- already-recorded IDs.
local function addCategories(categories, T, id)
    if not id or id == 0 or categories[id] or not T.GetCategoryInfo then
        return
    end
    local c = T.GetCategoryInfo(id)
    if c and c.name then
        categories[id] = { name = c.name, parent = c.parentCategoryID }
        addCategories(categories, T, c.parentCategoryID)
    end
end

local function collectRecipe(T, profession, meta, id)
    local info = T.GetRecipeInfo(id)
    if not info or skipped(info) then
        return
    end
    local cat = info.categoryID or 0
    local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(id, false)
    meta[id] = {
        name = info.name,
        icon = info.icon,
        item = schematic and schematic.outputItemID,
        qtyMin = schematic and schematic.quantityMin,
        qtyMax = schematic and schematic.quantityMax,
        prof = profession.id,
        cat = cat,
        reagents = reagentsOf(schematic),
    }
    if info.learned then
        profession.recipes[id] = cat
        addCategories(profession.categories, T, cat)
    end
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
    for _, id in ipairs(T.GetAllRecipeIDs and T.GetAllRecipeIDs() or {}) do
        collectRecipe(T, profession, meta, id)
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
    local cache = Scanner.Cache
    for id, m in pairs(meta) do
        cache[id] = m
    end
    return profession
end

local misses = {} -- recipe ID -> fallback meta or true, for lookups that failed

-- Recipe metadata for any recipe ID, from the session cache or looked up and
-- cached. Forever answers these lookups without the profession window open.
function Scanner.Meta(id)
    local cache = Scanner.Cache
    if cache[id] then
        return cache[id]
    end
    local T = C_TradeSkillUI
    if misses[id] then
        return misses[id] ~= true and misses[id] or nil
    end
    local info = T and T.GetRecipeInfo and T.GetRecipeInfo(id)
    if not info or not info.name then
        -- Remembered for the session, so redraws don't ask again (unless
        -- the spell name is still loading).
        local fallback = Scanner.CatalogMeta(id)
        if not fallback or fallback.name then
            misses[id] = fallback or true
        end
        return fallback
    end
    local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(id, false)
    local meta = {
        name = info.name,
        icon = info.icon,
        item = schematic and schematic.outputItemID,
        qtyMin = schematic and schematic.quantityMin,
        qtyMax = schematic and schematic.quantityMax,
        cat = info.categoryID or 0,
        reagents = reagentsOf(schematic),
    }
    cache[id] = meta
    return meta
end

-- For recipes the client can't describe: name from the spell, output from
-- the recipe catalog (RecipeDB). Not saved; reagents stay unknown.
local catalogIndex, catalogMeta = nil, {}
function Scanner.CatalogMeta(id)
    if catalogMeta[id] then
        return catalogMeta[id]
    end
    catalogIndex = catalogIndex or ns.Data.CatalogIndex(ns.RecipeDB)
    local found = catalogIndex[id]
    if not found then
        return nil
    end
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local spell = C_Spell.GetSpellInfo(id)
        name = type(spell) == "table" and spell.name or spell
    elseif GetSpellInfo then
        name = GetSpellInfo(id)
    end
    local meta = { name = name, item = found.entry.c, prof = found.prof, cat = 0, reagents = {} }
    if name then
        catalogMeta[id] = meta
    end
    return meta
end

-- This character's professions from the spellbook side (no window needed):
-- { [skillLine] = { name, skill, maxSkill } }, or nil if the client can't say.
local function professionInfos()
    if not (GetProfessions and GetProfessionInfo) then
        return nil
    end
    local out = {}
    for _, index in pairs({ GetProfessions() }) do
        local name, _, skill, maxSkill, _, _, skillLine = GetProfessionInfo(index)
        if skillLine then
            out[skillLine] = { name = name, skill = skill or 0, maxSkill = maxSkill or 0 }
        end
    end
    return next(out) and out or nil
end
Scanner.ProfessionInfos = professionInfos

local function learnedProfessions()
    local infos = professionInfos()
    if not infos then
        return nil
    end
    local set = {}
    for id in pairs(infos) do
        set[id] = true
    end
    return set
end

-- Forgets professions this character has since unlearned, so they stop
-- being shared. Only when the client's list uses the same skill-line ID
-- scheme (at least one learned ID matches a stored or known profession), so
-- a different ID scheme can't wipe them all.
function Scanner.DropUnlearned(char, learned)
    learned = learned or learnedProfessions()
    if not (char and char.professions and learned) then
        return false
    end
    local agrees = false
    for id in pairs(learned) do
        if char.professions[id] or (ns.RecipeDB and ns.RecipeDB[id]) or (ns.Data and ns.Data.GATHERING and ns.Data.GATHERING[id]) then
            agrees = true
            break
        end
    end
    if not agrees then
        return false
    end
    local dropped = false
    for id in pairs(char.professions) do
        if not learned[id] then
            char.professions[id] = nil
            dropped = true
        end
    end
    return dropped
end

-- Fast skill-only update (for SKILL_LINES_CHANGED): updates skill/maxSkill
-- on existing professions without querying every unlearned catalog recipe.
-- Returns changed, needsFullScan (true when a new catalog profession appeared).
function Scanner.SyncSkills(char, infos, catalog)
    if not (char and infos) then
        return false, false
    end
    char.professions = char.professions or {}
    local changed, needsFull = false, false
    for id, info in pairs(infos) do
        local p = char.professions[id]
        if p then
            if p.skill ~= info.skill or p.maxSkill ~= info.maxSkill then
                p.skill, p.maxSkill = info.skill, info.maxSkill
                changed = true
            end
        elseif catalog and catalog[id] then
            needsFull = true
        end
    end
    return changed, needsFull
end

local function quietScanRecipe(p, recipeID, T)
    if p.recipes[recipeID] then
        return false
    end
    local r = T.GetRecipeInfo(recipeID)
    if not (r and r.learned) then
        return false
    end
    local cat = r.categoryID or 0
    p.recipes[recipeID] = cat
    addCategories(p.categories, T, cat)
    return true
end

local function quietScanProfession(char, id, info, entries, T, now)
    local p = char.professions[id]
    if not p then
        p = { id = id, name = info.name, skill = 0, maxSkill = 0, recipes = {}, categories = {} }
        char.professions[id] = p
    end
    local changed = false
    if p.skill ~= info.skill or p.maxSkill ~= info.maxSkill then
        p.skill, p.maxSkill = info.skill, info.maxSkill
        changed = true
    end
    local found = false
    for recipeID in pairs(entries) do
        if quietScanRecipe(p, recipeID, T) then
            found = true
        end
    end
    if found then
        p.scannedAt = now
        changed = true
    end
    return changed
end

-- Without the profession window: for each profession the character has,
-- asks the client which catalog recipes are learned (Forever answers
-- GetRecipeInfo(id).learned with the window closed). Adds what it finds to
-- the character's records, never removes (a window scan is the full
-- truth, and can include recipes the catalog lacks). Category names come
-- along when the client gives them, else the recipe sits under "Other"
-- until someone opens that profession. Returns whether anything changed.
--   infos = Scanner.ProfessionInfos(), T = C_TradeSkillUI, catalog = ns.RecipeDB
function Scanner.QuietScan(char, infos, T, catalog, now)
    if not (char and infos and T and T.GetRecipeInfo and catalog) then
        return false
    end
    char.professions = char.professions or {}
    local changed = false
    for id, info in pairs(infos) do
        local entries = catalog[id]
        if entries and quietScanProfession(char, id, info, entries, T, now) then
            changed = true
        end
    end
    return changed
end

-- Quiet scan now, sharing what changed (after logging in, learning a
-- recipe or a skill change); bursts of events run it once.
-- skillsOnly: skip querying unlearned recipes unless a new profession appeared.
local quietPending, quietFull = false, false

local function runQuietScan(full)
    if not ns.char then
        return
    end
    local infos = professionInfos()
    local changed = Scanner.DropUnlearned(ns.char)
    local needsFull = full
    if not full then
        local skillChanged, newProf = Scanner.SyncSkills(ns.char, infos, ns.RecipeDB)
        changed = changed or skillChanged
        needsFull = newProf
    end
    if needsFull and Scanner.QuietScan(ns.char, infos, C_TradeSkillUI, ns.RecipeDB, ns.Now()) then
        changed = true
    end
    if not changed then
        return
    end
    if ns.db.settings.debug then
        ns.Print("updated professions without the profession window")
    end
    ns.Refresh()
    ns.Sync.Announce()
end

function Scanner.QuietQueue(delay, skillsOnly)
    if not skillsOnly then
        quietFull = true
    end
    if quietPending then
        return
    end
    quietPending = true
    C_Timer.After(delay or 2, function()
        local full = quietFull
        quietPending, quietFull = false, false
        runQuietScan(full)
    end)
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
        local stored = Scanner.Store(ns.char, profession, meta, ns.Now())
        if stored then
            if ns.db.settings.debug then
                ns.Print(string.format("scanned %s: %d recipes", stored.name, Scanner.Count(stored)))
            end
            ns.Refresh()
            ns.Sync.Announce()
        end
    end)
end
