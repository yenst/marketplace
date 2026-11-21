-- Plain-Lua tests for Marketplace's non-UI modules. Run from the repo root:
--   lua5.1 tests/run.lua
date, time = os.date, os.time

local ns = {}
for _, file in ipairs({ "Init" }) do
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

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    os.exit(1)
end
