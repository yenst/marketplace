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

-- Unit price in copper: the last auction price, or what a vendor sells it for
-- when Auctionator knows that (thread, flux, vials...).
function AH.Price(itemID)
    if not itemID then
        return nil
    end
    return call("GetVendorPriceByItemID", itemID) or call("GetAuctionPriceByItemID", itemID)
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
--           unknown = number of reagents without a price, missing = { { itemID, count } } }
function AH.Costs(reagents, priceOf, countOf)
    local out = { lines = {}, total = 0, missingTotal = 0, unknown = 0, missing = {} }
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
