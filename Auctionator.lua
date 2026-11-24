local _, ns = ...

-- Optional Auctionator integration through its public API (Auctionator.API.v1):
-- auction prices for reagents and crafted items, and a shopping list of the
-- reagents you're missing. Everything here is a no-op without Auctionator.
local AH = {}
ns.AH = AH

local CALLER = "Marketplace"

local function api()
    local a = _G.Auctionator
    return type(a) == "table" and type(a.API) == "table" and type(a.API.v1) == "table" and a.API.v1 or nil
end

function AH.Available()
    return api() ~= nil
end

local function call(name, ...)
    local v1 = api()
    if not v1 or type(v1[name]) ~= "function" then
        return nil
    end
    local ok, result = pcall(v1[name], CALLER, ...)
    if ok then
        return result
    end
    return nil
end

-- Unit price in copper for a reagent: vendor price when Auctionator knows it
-- (thread, flux, vials...), otherwise the last auction price.
function AH.Price(itemID)
    if not itemID then
        return nil
    end
    return call("GetVendorPriceByItemID", itemID) or call("GetAuctionPriceByItemID", itemID)
end

-- Last auction house price in copper (ignoring vendor prices, so crafted
-- items and limited-supply patterns reflect the auction house).
function AH.AuctionPrice(itemID)
    if not itemID then
        return nil
    end
    return call("GetAuctionPriceByItemID", itemID)
end

-- Craft yield (average count and display label, e.g. "x3" or "1-3") from a
-- catalog entry's `n` field or a scanned schematic's quantityMin/quantityMax.
function AH.CraftYield(n, meta)
    local lo, hi
    if type(n) == "number" and n > 1 then
        lo, hi = n, n
    elseif type(n) == "string" then
        local a, b = n:match("^(%d+)%-(%d+)$")
        if a and b then
            lo, hi = tonumber(a), tonumber(b)
        end
    elseif meta and meta.qtyMin and meta.qtyMin > 0 then
        lo = meta.qtyMin
        hi = meta.qtyMax and meta.qtyMax >= lo and meta.qtyMax or lo
    end
    if not lo or (lo == 1 and (not hi or hi == 1)) then
        return 1, nil
    end
    if hi and hi ~= lo then
        return (lo + hi) / 2, lo .. "-" .. hi
    end
    return lo, "x" .. lo
end

-- Days since the item was last seen at the auction house (nil if > 21 days
-- or never).
function AH.Age(itemID)
    return itemID and call("GetAuctionAgeByItemID", itemID) or nil
end

-- Pure cost breakdown for a recipe's reagents.
--   reagents = { { itemID, need }, ... }
--   priceOf(itemID) -> copper per unit or nil, countOf(itemID) -> how many you have
-- Returns { lines = { [i] = { cost, missing, missingCost } }, total, missingTotal,
--           unknown = number of reagents without a price,
--           missingUnknown = number of missing reagents without a price,
--           missing = { { itemID, count } } }
function AH.Costs(reagents, priceOf, countOf)
    local out = { lines = {}, total = 0, missingTotal = 0, unknown = 0, missingUnknown = 0, missing = {} }
    for i, r in ipairs(reagents or {}) do
        local id, need = r[1], r[2]
        local unit = priceOf(id)
        local short = math.max(0, need - (countOf(id) or 0))
        local line = { missing = short }
        if unit then
            line.cost = unit * need
            line.missingCost = unit * short
            out.total = out.total + line.cost
            out.missingTotal = out.missingTotal + line.missingCost
        else
            out.unknown = out.unknown + 1
            if short > 0 then
                out.missingUnknown = out.missingUnknown + 1
            end
        end
        if short > 0 then
            out.missing[#out.missing + 1] = { id, short }
        end
        out.lines[i] = line
    end
    return out
end

-- Creates (or replaces) the Auctionator shopping list "Marketplace: <recipe>"
-- with exact searches for the missing reagents. When the auction house is
-- open, it searches them straight away too. Returns the list name, or nil.
--   missing = { { itemID, count } }, nameOf(itemID) -> item name or nil
function AH.ShoppingList(recipeName, missing, nameOf)
    local v1 = api()
    if not v1 or #missing == 0 then
        return nil
    end
    local strings, names = {}, {}
    for _, m in ipairs(missing) do
        local name = nameOf(m[1])
        if name then
            names[#names + 1] = name
            strings[#strings + 1] = call("ConvertToSearchString", { searchString = name, isExact = true, quantity = m[2] })
                or ('"' .. name .. '"')
        end
    end
    if #strings == 0 then
        return nil
    end
    local listName = "Marketplace: " .. recipeName
    call("CreateShoppingList", listName, strings)
    local ahFrame = AuctionHouseFrame or AuctionFrame -- retail-style or classic auction house
    if ahFrame and ahFrame:IsShown() then
        call("MultiSearchExact", names)
    end
    return listName
end

-- Copper with coin icons, rounded to silver above 1g so it stays short.
function AH.Money(copper)
    if not copper then
        return ""
    end
    if copper >= 10000 then
        copper = math.floor(copper / 100 + 0.5) * 100
    end
    return ns.Coins(copper)
end
