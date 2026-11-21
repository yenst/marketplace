-- Plain-Lua tests for Marketplace's non-UI modules. Run from the repo root:
--   lua5.1 tests/run.lua
date, time = os.date, os.time

local ns = {}
for _, file in ipairs({ "Init", "Scanner", "Sync", "Data" }) do
    assert(loadfile(file .. ".lua"))("Marketplace", ns)
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

test("FormatMoney", function()
    eq(ns.FormatMoney(0), "0c")
    eq(ns.FormatMoney(12345), "1g 23s 45c")
    eq(ns.FormatMoney(450000), "45g")
    eq(ns.FormatMoney(250), "2s 50c")
end)

test("Plural", function()
    eq(ns.Plural(1, "recipe"), "1 recipe")
    eq(ns.Plural(3, "recipe"), "3 recipes")
end)

-- A fake C_TradeSkillUI shaped like Forever's (from /mkt probe trade).
local function fakeTradeSkill(overrides)
    local recipes = {
        [1230171] = { name = "Sharpening Wheel", categoryID = 2489, learned = true, icon = 135243 },
        [1263073] = { name = "Master Forge", categoryID = 2489, learned = false, icon = 4374708 },
        [460460] = { name = "Sulfuron Hammer", categoryID = 0, learned = true, icon = 136192 },
        [999] = { name = "Recraft Gear", categoryID = 2489, learned = true, isRecraft = true },
    }
    local T = {
        IsTradeSkillReady = function() return true end,
        IsTradeSkillLinked = function() return false end,
        IsTradeSkillGuild = function() return false end,
        IsNPCCrafting = function() return false end,
        GetBaseProfessionInfo = function()
            return { professionID = 164, professionName = "Blacksmithing", skillLevel = 215, maxSkillLevel = 300 }
        end,
        GetAllRecipeIDs = function() return { 1230171, 1263073, 460460, 999 } end,
        GetRecipeInfo = function(id)
            local r = recipes[id]
            r.recipeID = id
            return r
        end,
        GetCategoryInfo = function(id)
            if id == 2489 then return { name = "Camping", parentCategoryID = 2425 } end
            if id == 2425 then return { name = "Tools", parentCategoryID = 0 } end
        end,
        GetRecipeSchematic = function(id)
            return {
                outputItemID = id + 1,
                reagentSlotSchematics = {
                    { required = true, quantityRequired = 2, reagents = { { itemID = 2840 } } },
                    { required = false, quantityRequired = 1, reagents = { { itemID = 7777 } } },
                },
            }
        end,
    }
    for k, v in pairs(overrides or {}) do T[k] = v end
    return T
end

test("Scanner.Collect keeps learned recipes and their categories", function()
    local prof, meta = ns.Scanner.Collect(fakeTradeSkill())
    eq(prof.id, 164, "profession id")
    eq(prof.name, "Blacksmithing")
    eq(prof.skill, 215)
    eq(prof.recipes[1230171], 2489, "learned recipe with its category")
    eq(prof.recipes[460460], 0, "uncategorised learned recipe")
    eq(prof.recipes[1263073], nil, "unlearned recipe isn't craftable")
    eq(prof.recipes[999], nil, "recrafts are skipped")
    eq(ns.Scanner.Count(prof), 2)
    eq(prof.categories[2489].name, "Camping")
    eq(prof.categories[2425].name, "Tools", "parent category is kept for headers")
    eq(meta[1263073].name, "Master Forge", "unlearned recipes still go into the cache")
    eq(meta[1230171].item, 1230172, "output item")
    eq(#meta[1230171].reagents, 1, "only required reagents")
    eq(meta[1230171].reagents[1][1], 2840)
    eq(meta[1230171].reagents[1][2], 2)
end)

test("Scanner.Collect ignores linked, guild and NPC windows", function()
    eq(ns.Scanner.Collect(fakeTradeSkill({ IsTradeSkillLinked = function() return true end })), nil, "linked")
    eq(ns.Scanner.Collect(fakeTradeSkill({ IsTradeSkillGuild = function() return true end })), nil, "guild")
    eq(ns.Scanner.Collect(fakeTradeSkill({ IsNPCCrafting = function() return true end })), nil, "npc")
    eq(ns.Scanner.Collect(fakeTradeSkill({ IsTradeSkillReady = function() return false end })), nil, "not ready")
    eq(ns.Scanner.Collect(nil), nil, "no API")
end)

test("Scanner.Store saves per profession and fills the cache", function()
    ns.db = { recipes = {} }
    local char = {}
    local prof, meta = ns.Scanner.Collect(fakeTradeSkill())
    ns.Scanner.Store(char, prof, meta, 1000)
    eq(char.professions[164].scannedAt, 1000)
    eq(ns.db.recipes[1263073].prof, 164)
    eq(ns.Scanner.Store(char, nil, nil, 1), nil, "nothing to store")
end)

-- A big profession: 120 long recipe IDs, names with separators in them.
local function bigProfessions()
    local recipes, categories = {}, {}
    for i = 1, 120 do
        recipes[1260000 + i] = 2400 + (i % 7)
    end
    for c = 2400, 2406 do
        categories[c] = { name = "Cat: " .. c .. "; part=2", parent = 2425 }
    end
    return {
        [164] = { id = 164, name = "Blacksmithing", skill = 215, maxSkill = 300, scannedAt = 1795251763, recipes = recipes, categories = categories },
        [129] = { id = 129, name = "First Aid", skill = 180, maxSkill = 225, scannedAt = 1795251763, recipes = { [3275] = 0 }, categories = {} },
    }
end

test("Sync.Encode lines fit an addon message", function()
    local lines = ns.Sync.Encode(bigProfessions())
    assert(#lines > 5, "split into several lines")
    for _, line in ipairs(lines) do
        assert(#line <= 250, "line too long: " .. #line)
    end
end)

test("Sync round trip keeps professions, recipes and categories", function()
    local original = bigProfessions()
    local lines, hash = ns.Sync.Encode(original)
    local decoder = ns.Sync.NewDecoder()
    local got, gotHash
    for _, line in ipairs(lines) do
        got, gotHash = decoder.Feed(line)
    end
    assert(got, "transfer completes")
    eq(gotHash, hash)
    eq(ns.Sync.Hash(got), hash, "same fingerprint after decoding")
    eq(got[164].skill, 215)
    eq(got[164].name, "Blacksmithing")
    eq(got[164].recipes[1260001], 2401)
    eq(got[164].categories[2401].name, "Cat  2401  part 2", "separators in names are blanked")
    eq(got[164].categories[2401].parent, 2425)
    eq(got[129].recipes[3275], 0)
end)

test("Sync decoder drops incomplete or mismatched transfers", function()
    local lines = ns.Sync.Encode(bigProfessions())
    local decoder = ns.Sync.NewDecoder()
    for i, line in ipairs(lines) do
        if i ~= 3 then -- a lost line
            eq(decoder.Feed(line), nil, "nothing until a complete transfer")
        end
    end
    eq(decoder.Feed("E:deadbeef"), nil, "end without a begin")
    eq(ns.Sync.NewDecoder().Feed("B:2:abcd"), nil, "other protocol versions are ignored")
end)

test("Sync.Hash changes with recipes and skill", function()
    local a = bigProfessions()
    local h = ns.Sync.Hash(a)
    a[129].skill = 181
    assert(ns.Sync.Hash(a) ~= h, "skill change")
    a[129].skill = 180
    eq(ns.Sync.Hash(a), h, "back to the same")
    a[129].recipes[3276] = 0
    assert(ns.Sync.Hash(a) ~= h, "new recipe")
end)

test("Sync.Shareable leaves out professions without recipes", function()
    local s = ns.Sync.Shareable({ [356] = { recipes = {} }, [185] = { recipes = { [1] = 0 } } })
    eq(s[356], nil, "fishing")
    assert(s[185], "cooking")
end)

-- Data: a guild with me (Billy), my offline alt, Dan (addon running),
-- Fenna (online, no addon this session) and Kael (offline).
local function bs(recipes) return { name = "Blacksmithing", recipes = recipes, categories = { [10] = { name = "Weapons" }, [11] = { name = "Armor" } } } end
local function ctx()
    return {
        own = {
            { name = "Billy Joel", class = "PALADIN", current = true, professions = { [164] = bs({ [1] = 10, [2] = 11 }) } },
            { name = "Billy Alt", class = "MAGE", professions = { [185] = { name = "Cooking", recipes = { [7] = 0 } } } },
        },
        guildData = {
            ["Dan Pal"] = { updated = 100, professions = { [164] = bs({ [1] = 10 }) } },
            ["Fenna Frost-Mirage"] = { updated = 100, professions = { [164] = bs({ [3] = 11 }) } },
            ["Kael Sun"] = { updated = 100, professions = { [164] = bs({ [1] = 10, [3] = 11 }) } },
            ["Billy Joel"] = { updated = 1, professions = { [164] = bs({ [9] = 10 }) } },
        },
        roster = {
            ["Dan Pal"] = { online = true, class = "PALADIN" },
            ["Fenna Frost"] = { online = true, class = "MAGE" },
            ["Kael Sun"] = { online = false, class = "WARRIOR", lastOnline = 2 * 86400 },
        },
        seen = { ["Dan Pal"] = 5 },
    }
end
local META = { [1] = { name = "Arcanite Reaper", reagents = { { 500, 12 } } }, [2] = { name = "Lionheart Helm" }, [3] = { name = "Imperial Plate" }, [7] = { name = "Chili" } }
local function metaOf(id) return META[id] end
local function itemName(id) return id == 500 and "Arcanite Bar" or nil end

test("Data.Crafters merges own characters, synced guildmates and roster state", function()
    local list = ns.Data.Crafters(ctx())
    local by = {}
    for _, c in ipairs(list) do by[c.name] = c end
    eq(by["Billy Joel"].state, "you")
    eq(by["Billy Joel"].professions[164].recipes[9], nil, "own scan wins over a stale synced copy of ourselves")
    eq(by["Billy Alt"].state, "offline", "own alt not in the roster as online")
    eq(by["Dan Pal"].state, "addon")
    eq(by["Fenna Frost"].state, "noaddon", "realm suffix stripped, online in roster")
    eq(by["Fenna Frost"].class, "MAGE")
    eq(by["Kael Sun"].state, "offline")
end)

test("Data.Index lists crafters per recipe, online first", function()
    local recipes, profs = ns.Data.Index(ns.Data.Crafters(ctx()))
    local reaper = recipes[1]
    eq(#reaper.crafters, 3)
    eq(reaper.crafters[1].name, "Billy Joel", "you first")
    eq(reaper.crafters[2].name, "Dan Pal", "then addon running")
    eq(reaper.crafters[3].name, "Kael Sun", "then offline")
    eq(reaper.catName, "Weapons")
    eq(recipes[7].catName, "Other", "category 0")
    local list = ns.Data.ProfessionList(profs)
    eq(list[1].name, "Blacksmithing")
    eq(list[2].name, "Cooking")
end)

test("Data.List groups by category, filters and collapses", function()
    local recipes = ns.Data.Index(ns.Data.Crafters(ctx()))
    local items, count = ns.Data.List(recipes, { prof = 164, query = "" }, metaOf, itemName)
    eq(count, 3)
    eq(items[1].header and items[1].label, "Armor")
    eq(items[2].name, "Imperial Plate")
    eq(items[3].name, "Lionheart Helm")
    eq(items[4].label, "Weapons")
    eq(items[5].name, "Arcanite Reaper")
    eq(ns.Data.CrafterText(items[5]), "3 · 2 online")

    items = ns.Data.List(recipes, { prof = "all", query = "" }, metaOf, itemName)
    eq(items[1].label, "Blacksmithing", "All groups by profession")

    items, count = ns.Data.List(recipes, { prof = "all", query = "bar" }, metaOf, itemName)
    eq(count, 1, "search matches reagent names")
    eq(items[2].name, "Arcanite Reaper")
    items, count = ns.Data.List(recipes, { prof = "all", query = "kael" }, metaOf, itemName)
    eq(count, 2, "search matches crafter names")

    items = ns.Data.List(recipes, { prof = 164, query = "", collapsed = { Armor = true } }, metaOf, itemName)
    eq(items[1].collapsed, true)
    eq(items[2].label, "Weapons", "collapsed group hides its rows")

    items, count = ns.Data.List(recipes, { prof = 185, query = "", onlineOnly = true }, metaOf, itemName)
    eq(count, 0, "only an offline alt has Chili")
end)

test("Data.StatusText", function()
    eq(ns.Data.StatusText({ state = "you" }), "You")
    eq(ns.Data.StatusText({ state = "addon" }), "Online")
    eq(ns.Data.StatusText({ state = "offline", lastOnline = 2 * 86400 }), "Offline · seen 2d ago")
    eq(ns.Data.StatusText({ state = "offline", updated = 1000 }, 1000 + 5 * 3600), "Offline · seen 5h ago")
    eq(ns.Data.StatusText({ state = "offline", mine = true }), "Your character")
end)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    os.exit(1)
end
