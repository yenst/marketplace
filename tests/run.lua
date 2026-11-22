-- Plain-Lua tests for Marketplace's non-UI modules. Run from the repo root:
--   lua5.1 tests/run.lua
date, time = os.date, os.time

local ns = {}
for _, file in ipairs({ "Init", "Scanner", "Sync", "Data", "Auctionator" }) do
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
    eq(ns.Sync.NewDecoder().Feed("B:1:abcd"), nil, "other protocol versions are ignored")
end)

test("Sync.Hash changes with recipes, categories and max skill, not skill", function()
    local a = bigProfessions()
    local h = ns.Sync.Hash(a)
    a[129].skill = 181
    eq(ns.Sync.Hash(a), h, "levelling alone doesn't change it")
    a[129].maxSkill = 300
    assert(ns.Sync.Hash(a) ~= h, "max skill")
    a[129].maxSkill = 225
    eq(ns.Sync.Hash(a), h, "back to the same")
    a[129].recipes[3276] = 0
    assert(ns.Sync.Hash(a) ~= h, "new recipe")
    a[129].recipes[3276] = nil
    a[129].categories[5] = { name = "x" }
    assert(ns.Sync.Hash(a) ~= h, "category")
end)

test("Sync.Newer: newer stamp wins, ties by hash", function()
    assert(ns.Sync.Newer({ hash = "aaaa", stamp = 2 }, { hash = "ffff", stamp = 1 }))
    assert(ns.Sync.Newer({ hash = "ffff", stamp = 1 }, { hash = "aaaa", stamp = 1 }))
    assert(not ns.Sync.Newer({ hash = "aaaa", stamp = 1 }, { hash = "ffff", stamp = 1 }))
end)

test("Scanner.DropUnlearned forgets professions only when the client agrees", function()
    local char = { professions = { [164] = {}, [185] = {} } }
    ns.Scanner.DropUnlearned(char, { [999] = true })
    assert(char.professions[164] and char.professions[185], "no overlap: IDs differ, keep everything")
    ns.Scanner.DropUnlearned(char, { [164] = true })
    assert(char.professions[164] and not char.professions[185], "Cooking unlearned")
end)

test("Sync.Shareable leaves out professions without recipes", function()
    local s = ns.Sync.Shareable({ [356] = { recipes = {} }, [185] = { recipes = { [1] = 0 } } })
    eq(s[356], nil, "fishing")
    assert(s[185], "cooking")
end)

test("Sync relayed copies carry their owner and stamp", function()
    local lines, hash = ns.Sync.Encode(bigProfessions(), "Eve Moon-Mirage", 1800000000)
    eq(lines[1], "B:2:" .. hash .. ":1800000000:Eve Moon-Mirage")
    local decoder, got, gotHash, owner, stamp = ns.Sync.NewDecoder()
    for _, line in ipairs(lines) do
        got, gotHash, owner, stamp = decoder.Feed(line)
    end
    assert(got and got[164], "transfer completes")
    eq(gotHash, hash)
    eq(owner, "Eve Moon-Mirage")
    eq(stamp, 1800000000)
    local _, _, direct = ns.Sync.ParseBegin("B:2:abcd:5:")
    eq(direct, nil, "own copies have no owner")
    eq(ns.Sync.Stamp(bigProfessions()), 1795251763)
end)

test("Sync packs numbers 5 bits per character", function()
    for _, n in ipairs({ 0, 1, 31, 32, 1023, 1024, 18238, 1260001, 4294967295 }) do
        local packed = ns.Sync.PackInt(n)
        local got, pos = ns.Sync.UnpackInt(packed .. "x", 1)
        eq(got, n, "round trip " .. n)
        eq(pos, #packed + 1)
    end
    eq(#ns.Sync.PackInt(31), 1)
    eq(#ns.Sync.PackInt(1023), 2)
end)

test("Sync copies are compact", function()
    -- 240 recipes spread evenly over 12 categories (worst case for the
    -- deltas): 8 lines, against 14 before packing.
    local recipes, n = {}, 0
    for id = 2000, 30000, 117 do
        n = n + 1
        recipes[id] = 100 + n % 12
    end
    local cats = {}
    for c = 100, 111 do cats[c] = { name = "Category " .. c, parent = 0 } end
    local lines = ns.Sync.Encode({ [164] = { name = "Blacksmithing", skill = 300, maxSkill = 300, recipes = recipes, categories = cats } })
    assert(n >= 230, "enough recipes")
    assert(#lines <= 8, "lines: " .. #lines)
end)

test("Sync digests: buckets that differ", function()
    local a = { Ann = { hash = "aaaa", stamp = 1 }, Bob = { hash = "bbbb", stamp = 1 } }
    local b = { Ann = { hash = "aaaa", stamp = 1 }, Bob = { hash = "b2b2", stamp = 2 } }
    local da, db = ns.Sync.Digest(a), ns.Sync.Digest(b)
    eq(#da, 64)
    eq(ns.Sync.Digest({ Bob = a.Bob, Ann = a.Ann }), da, "order doesn't matter")
    local diff = ns.Sync.DiffBuckets(da, db)
    eq(#diff, 1)
    eq(diff[1], ns.Sync.BucketOf("Bob"))
    eq(#ns.Sync.DiffBuckets(da, da), 0)
end)

test("Sync.Compare: newer or unknown copies are wanted, ours are offered", function()
    local function bucketMates(n)
        -- owners that land in the same bucket as "Ann"
        local out, b = {}, ns.Sync.BucketOf("Ann")
        local i = 0
        while #out < n do
            i = i + 1
            if ns.Sync.BucketOf("P" .. i) == b then out[#out + 1] = "P" .. i end
        end
        return out, b
    end
    local p, bucket = bucketMates(5)
    local mine = {
        [p[1]] = { hash = "aaaa", stamp = 100 }, -- same as listed
        [p[2]] = { hash = "bbbb", stamp = 100 }, -- listed is newer
        [p[3]] = { hash = "cccc", stamp = 100 }, -- ours is newer
        [p[4]] = { hash = "dddd", stamp = 100 }, -- not listed
    }
    local list = {
        [p[1]] = { hash = "aaaa", stamp = 100 },
        [p[2]] = { hash = "b2b2", stamp = 200 },
        [p[3]] = { hash = "c0c0", stamp = 50 },
        [p[5]] = { hash = "eeee", stamp = 10 },  -- unknown to us
        Me = { hash = "ffff", stamp = 999 },
    }
    local wanted, offer = ns.Sync.Compare(list, mine, bucket, function(o) return o == "Me" end)
    table.sort(wanted); table.sort(offer)
    eq(table.concat(wanted, ","), table.concat({ p[2], p[5] }, ","))
    local expect = { p[3], p[4] }; table.sort(expect)
    eq(table.concat(offer, ","), table.concat(expect, ","))
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
test("Data.Crafters: someone who logged off isn't online, even if seen", function()
    local c = ctx()
    c.seen["Kael Sun"] = 5
    for _, crafter in ipairs(ns.Data.Crafters(c)) do
        if crafter.name == "Kael Sun" then eq(crafter.state, "offline") end
        if crafter.name == "Dan Pal" then eq(crafter.state, "addon") end
    end
end)

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
    eq(items[1].header and items[1].label, "Weapons", "categories in the game's order (by ID), not alphabetical")
    eq(items[2].name, "Arcanite Reaper")
    eq(items[3].label, "Armor")
    eq(items[4].name, "Imperial Plate")
    eq(items[5].name, "Lionheart Helm")
    eq(ns.Data.CrafterText(items[2]), "", "no text: the green dot shows someone is online")

    items = ns.Data.List(recipes, { prof = "all", query = "" }, metaOf, itemName)
    eq(items[1].label, "Blacksmithing", "All groups by profession")

    items, count = ns.Data.List(recipes, { prof = "all", query = "bar" }, metaOf, itemName)
    eq(count, 1, "search matches reagent names")
    eq(items[2].name, "Arcanite Reaper")
    items, count = ns.Data.List(recipes, { prof = "all", query = "kael" }, metaOf, itemName)
    eq(count, 2, "search matches crafter names")

    items = ns.Data.List(recipes, { prof = 164, query = "", collapsed = { Weapons = true } }, metaOf, itemName)
    eq(items[1].collapsed, true)
    eq(items[2].label, "Armor", "collapsed group hides its rows")

    items, count = ns.Data.List(recipes, { prof = 185, query = "", onlineOnly = true }, metaOf, itemName)
    eq(count, 0, "only an offline alt has Chili")
end)

test("Data.Tabs lists every crafting profession, shared or not", function()
    local _, profs = ns.Data.Index(ns.Data.Crafters(ctx()))
    local game = { { id = 171, name = "Alchemy" }, { id = 164, name = "Blacksmithing" }, { id = 182, name = "Herbalism" }, { id = 186, name = "Mining" } }
    local list, byId = ns.Data.Tabs(game, profs)
    local names = {}
    for _, p in ipairs(list) do names[#names + 1] = p.name end
    eq(table.concat(names, ","), "Alchemy,Blacksmithing,Cooking,Mining", "sorted, gathering left out, shared Cooking added")
    eq(next(byId[171].crafters), nil, "nobody has Alchemy")
    list = ns.Data.Tabs({ { id = 171, name = "Alchemy" }, { id = 2485, name = "Alchemy" } }, {})
    eq(#list, 1, "same profession under two skill lines shows once")
    assert(byId[164].crafters["Dan Pal"], "Blacksmithing keeps its crafters")
end)

test("AH.Costs totals reagents and what you're missing", function()
    local prices = { [1] = 500, [2] = 10000 } -- 5s and 1g; item 3 has no price
    local have = { [1] = 20, [2] = 1, [3] = 0 }
    local c = ns.AH.Costs({ { 1, 16 }, { 2, 6 }, { 3, 4 } }, function(id) return prices[id] end, function(id) return have[id] end)
    eq(c.total, 16 * 500 + 6 * 10000)
    eq(c.missingTotal, 5 * 10000, "only the 5 Gold Bars you lack")
    eq(c.unknown, 1)
    eq(#c.missing, 2, "short on items 2 and 3")
    eq(c.missing[1][1], 2)
    eq(c.missing[1][2], 5)
    eq(c.lines[1].missing, 0)
    eq(c.lines[3].cost, nil, "no price, no cost")
end)

test("AH without Auctionator does nothing", function()
    eq(ns.AH.Available(), false)
    eq(ns.AH.Price(123), nil)
    eq(ns.AH.ShoppingList("X", { { 1, 2 } }, function() return "Bar" end), nil)
    local plain = function(text) return (text:gsub("|TInterface\\MoneyFrame\\UI%-(%a)%a+Icon:[^|]*|t", function(c) return c:lower() end)) end
    eq(plain(ns.AH.Money(123456)), "12g 35s", "rounded to silver above 1g")
    eq(plain(ns.Coins(250)), "2s 50c")
    eq(plain(ns.Coins(0)), "0c")
    eq(plain(ns.Coins(10005)), "1g", "no copper next to gold")
    assert(ns.Coins(10000):find("UI-GoldIcon", 1, true), "gold coin texture")
end)

test("Data.StatusText", function()
    eq(ns.Data.StatusText({ state = "you" }), "You")
    eq(ns.Data.StatusText({ state = "addon" }), "", "online: the dot says it")
    eq(ns.Data.StatusText({ state = "offline", lastOnline = 2 * 86400 }), "Seen 2d ago")
    eq(ns.Data.StatusText({ state = "offline", updated = 1000 }, 1000 + 5 * 3600), "Seen 5h ago")
    eq(ns.Data.StatusText({ state = "offline", mine = true }), "Your character")
end)

test("Data.List favorites", function()
    local c = { name = "Dan", state = "addon" }
    local recipes = {
        [1] = { id = 1, prof = 164, profName = "Blacksmithing", cat = 10, catName = "Weapons", crafters = { c } },
        [2] = { id = 2, prof = 164, profName = "Blacksmithing", cat = 11, catName = "Armor", crafters = { c } },
        [3] = { id = 3, prof = 185, profName = "Cooking", cat = 3, catName = "Fish", crafters = { c } },
    }
    local meta = function(id) return { name = "R" .. id } end
    local items = ns.Data.List(recipes, { prof = 164, query = "", favorites = { [2] = true } }, meta, function() end)
    eq(items[1].label, "Favorites", "favorites first in a profession")
    assert(items[1].favorites, "header marked")
    eq(items[2].recipe.id, 2)
    eq(items[3].label, "Weapons", "then the categories")
    eq(#items, 4, "favourite not repeated in its category")
    items = ns.Data.List(recipes, { prof = "all", query = "", favorites = { [3] = true } }, meta, function() end)
    eq(items[1].label, "Favorites", "favorites first under All too")
    eq(items[3].label, "Blacksmithing")
end)


test("Data.Index adds catalog recipes nobody has", function()
    local catalog = { [185] = { [7] = { s = 1, src = "t" }, [8] = { s = 50, src = "v" } }, [356] = { [9] = { s = 1 } } }
    local recipes = ns.Data.Index(ns.Data.Crafters(ctx()), catalog, { [185] = "Cooking" })
    eq(#recipes[7].crafters, 1, "the alt's Chili keeps its crafter")
    eq(recipes[7].skill, 1)
    eq(#recipes[8].crafters, 0, "nobody has recipe 8")
    eq(recipes[8].profName, "Cooking")
    eq(recipes[9], nil, "gathering professions are left out")
    local items = ns.Data.List(recipes, { prof = 185 }, metaOf, itemName)
    eq(items[#items - 1].label, ns.Data.NOBODY, "nobody's recipes come last")
    eq(ns.Data.CrafterText(items[#items]), "Skill 50")
    local all = ns.Data.List(recipes, { prof = "all" }, metaOf, itemName)
    for _, item in ipairs(all) do
        assert(item.label ~= ns.Data.NOBODY, "not in All professions unless searching")
    end
end)

test("Scanner.QuietScan finds learned recipes without the window", function()
    local T = {
        GetRecipeInfo = function(id) return { learned = id == 2660 or id == 2663, categoryID = id == 2660 and 50 or 0 } end,
        GetCategoryInfo = function(id) return id == 50 and { name = "Materials", parentCategoryID = 0 } or nil end,
    }
    local catalog = { [164] = { [2660] = {}, [2663] = {}, [16745] = {} }, [999] = { [1] = {} } }
    local char = { professions = { [164] = { id = 164, recipes = { [12260] = 7 }, categories = { [7] = { name = "Armor" } } } } }
    local infos = { [164] = { name = "Blacksmithing", skill = 40, maxSkill = 75 }, [333] = { name = "Enchanting", skill = 1, maxSkill = 75 } }
    assert(ns.Scanner.QuietScan(char, infos, T, catalog, 123), "changed")
    local p = char.professions[164]
    eq(p.recipes[2660], 50); eq(p.recipes[2663], 0); eq(p.recipes[16745], nil)
    eq(p.recipes[12260], 7, "window-scanned recipes are kept")
    eq(p.categories[50].name, "Materials")
    eq(p.skill, 40); eq(p.scannedAt, 123)
    eq(char.professions[333], nil, "no catalog: nothing to look up")
    assert(not ns.Scanner.QuietScan(char, infos, T, catalog, 124), "second run: nothing new")
end)

test("Member filter: one guildmate's patterns", function()
    local recipes = ns.Data.Index(ns.Data.Crafters(ctx()))
    local items = ns.Data.List(recipes, { prof = 164, member = "Fenna Frost" }, metaOf, itemName)
    local names = {}
    for _, item in ipairs(items) do
        if not item.header then names[#names + 1] = item.name end
    end
    eq(table.concat(names, ","), "Imperial Plate", "only Fenna's recipe")
    local known, total = ns.Data.Coverage(recipes, 164, "Kael Sun")
    eq(known, 2); eq(total, 3)
    local members = ns.Data.Members(recipes, 164)
    local list = {}
    for _, m in ipairs(members) do list[#list + 1] = m.name .. "=" .. m.count end
    eq(table.concat(list, ","), "Billy Joel=2,Dan Pal=1,Fenna Frost=1,Kael Sun=2")
end)

test("Pattern tooltip people: who knows it, who could learn it", function()
    local index = ns.Data.PatternIndex({ [164] = { [3] = { s = 200, t = 777 }, [4] = { s = 1 } } })
    eq(index[777].recipe, 3); eq(index[777].prof, 164); eq(index[777].skill, 200)
    local crafters = ns.Data.Crafters(ctx())
    for _, c in ipairs(crafters) do
        if c.professions[164] then c.professions[164].skill = ({ ["Billy Joel"] = 250, ["Dan Pal"] = 150, ["Fenna Frost"] = 300, ["Kael Sun"] = 220 })[c.name] end
    end
    local recipes = ns.Data.Index(crafters)
    local known, canLearn = ns.Data.PatternPeople(recipes[3], crafters, 164, 200)
    local function list(l) local out = {} for _, p in ipairs(l) do out[#out + 1] = p.name .. "=" .. tostring(p.skill) end return table.concat(out, ",") end
    eq(list(known), "Fenna Frost=300,Kael Sun=220")
    eq(list(canLearn), "Billy Joel=250", "Dan's 150 is too low")
    known, canLearn = ns.Data.PatternPeople(nil, crafters, 164, 200)
    eq(#known, 0)
end)

test("Data.Coverage counts patterns the guild knows", function()
    local recipes = {
        [1] = { prof = 164, crafters = { {} } },
        [2] = { prof = 164, crafters = {} },
        [3] = { prof = 185, crafters = { {} } },
    }
    local known, total = ns.Data.Coverage(recipes, 164)
    eq(known, 1); eq(total, 2)
    known, total = ns.Data.Coverage(recipes, "all")
    eq(known, 2); eq(total, 3)
end)

test("Data.Sources says where to learn a recipe", function()
    local lookup = {
        zone = function(a) return ({ [1519] = "Stormwind City", [1637] = "Orgrimmar", [440] = "Tanaris" })[a] end,
        quest = function(id) return id == 7 and "A Fishy Peril" or nil end,
        factionName = function(id) return id == 529 and "Argent Dawn" or nil end,
        standing = function(n) return ({ [6] = "Honored" })[n] end,
        money = function(c) return c .. "c" end,
        favor = function(n) return n .. " favor" end,
    }
    local lines = ns.Data.Sources({ src = "tv", cost = 500, mf = 30, v = { { 1519, "A" }, { 1637, "H" }, { 440 } }, rep = { 529, 6 } }, "Alliance", lookup)
    eq(lines[1].label, "Trainer"); eq(lines[1].text, "500c")
    eq(lines[2].label, "Vendor"); eq(lines[2].text, "Sold in Stormwind City, Tanaris · 30 favor", "own faction's vendors only")
    eq(lines[3].text, "Needs Honored with Argent Dawn")
    lines = ns.Data.Sources({ src = "q", q = { { 7, 440, "H", 40 } } }, "Alliance", lookup)
    eq(lines[1].text, "A quest for the other faction")
    lines = ns.Data.Sources({ src = "qd", q = { { 7, 440, nil, 40 } }, side = "H" }, "Alliance", lookup)
    eq(lines[1].text, "Horde only")
    eq(lines[2].text, "A Fishy Peril in Tanaris")
    eq(lines[3].label, "Drop")
    eq(ns.Data.Sources({}, "Alliance", lookup)[1].text, "Unknown")
end)

test("RecipeDB loads and covers the crafting professions", function()
    local db = {}
    assert(loadfile("RecipeDB.lua"))("Marketplace", db)
    for _, prof in ipairs({ 171, 164, 185, 333, 202, 129, 165, 197, 186 }) do
        assert(db.RecipeDB[prof] and next(db.RecipeDB[prof]), "profession " .. prof)
    end
    eq(db.RecipeDB[185][18238].c, 6887, "Spotted Yellowtail")
end)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    os.exit(1)
end
