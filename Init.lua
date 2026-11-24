local ADDON, ns = ...

-- Shared addon namespace, refresh pub/sub, chat printing, and formatting helpers.
ns.name = ADDON
ns.TITLE = "Marketplace"
ns.ICON = "Interface\\AddOns\\Marketplace\\Media\\icon"

local listeners = {}

-- UI pieces subscribe here; Core calls ns.Refresh() whenever recipe data changes.
function ns.OnRefresh(fn)
    listeners[#listeners + 1] = fn
end

function ns.Refresh()
    for _, fn in ipairs(listeners) do
        fn()
    end
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|T" .. ns.ICON .. ":14:14|t |cff8c7cf5" .. ns.TITLE .. "|r " .. msg)
end

-- Server epoch seconds when available, else local clock.
function ns.Now()
    return GetServerTime and GetServerTime() or time()
end

-- 12345 copper -> "1[g] 23[s] 45[c]" with the game's coin icons. Zero parts
-- are left out; amounts of 1g or more drop the copper.
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:%d:%d:1:0|t"
function ns.Coins(copper, size)
    copper = math.floor(copper or 0)
    size = size or 0
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    local function add(n, coin)
        parts[#parts + 1] = n .. COIN:format(coin, size, size)
    end
    if g > 0 then add(g, "Gold") end
    if s > 0 then add(s, "Silver") end
    if (c > 0 and g == 0) or #parts == 0 then add(c, "Copper") end
    return table.concat(parts, " ")
end

function ns.Plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end
