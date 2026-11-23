local _, ns = ...

-- Item tooltips (anywhere: bags, vendors, the auction house, links).
-- Patterns get who in the guild already knows the recipe and who could
-- learn it; items someone in the guild can craft get who that is.
local MAX_NAMES = 5
local patterns, crafted

-- dim: grey names instead of class colours (also for anyone marked offline).
local function names(list, dim)
    local muted = ns.Theme.Hex(ns.Theme.muted)
    local parts = {}
    for i, p in ipairs(list) do
        if i > MAX_NAMES then
            parts[#parts + 1] = muted .. "and " .. (#list - MAX_NAMES) .. " more|r"
            break
        end
        local c = not dim and not p.offline and p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
        local name = c and string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, p.name) or p.name
        parts[#parts + 1] = name .. (p.skill and p.skill > 0 and (muted .. " (" .. p.skill .. ")|r") or "")
    end
    return table.concat(parts, ", ")
end

local function addLines(tooltip, itemID)
    if not (itemID and ns.db and ns.RecipeDB) then
        return
    end
    patterns = patterns or ns.Data.PatternIndex(ns.RecipeDB)
    crafted = crafted or ns.Data.CraftedIndex(ns.RecipeDB)
    local pattern, made = patterns[itemID], crafted[itemID]
    if not pattern and not made then
        return
    end
    local model = ns.Window.Model()
    -- Online crafters first, in their class colour; offline ones grey.
    local makers = made and ns.Data.Makers(made, model.recipes) or {}
    if not pattern and #makers == 0 then
        return -- craftable, but by nobody in the guild: nothing to say
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("|T" .. ns.ICON .. ":14:14|t Marketplace", 0.55, 0.76, 1)
    if #makers > 0 then
        tooltip:AddLine("Crafted by: " .. names(makers), 1, 0.82, 0, true)
    end
    if not pattern then
        tooltip:Show()
        return
    end
    local known, canLearn, tooLow = ns.Data.PatternPeople(model.recipes[pattern.recipe], model.crafters, pattern.prof, pattern.skill)
    if #known > 0 then
        tooltip:AddLine("Known by: " .. names(known), 1, 0.82, 0, true)
    else
        tooltip:AddLine("Nobody in your guild knows it yet", 0.6, 0.6, 0.6, true)
    end
    if #canLearn > 0 then
        tooltip:AddLine("Could learn it: " .. names(canLearn), 1, 0.82, 0, true)
    end
    if #tooLow > 0 then
        tooltip:AddLine("Needs " .. pattern.skill .. ": " .. names(tooLow, true), 0.6, 0.6, 0.6, true)
    end
    tooltip:Show()
end
ns.AddPatternLines = addLines

local function itemIDOf(tooltip)
    local _, link = tooltip:GetItem()
    return link and tonumber(link:match("item:(%d+)"))
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip == GameTooltip or tooltip == ItemRefTooltip then
            addLines(tooltip, data and data.id or itemIDOf(tooltip))
        end
    end)
else
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tooltip and tooltip.HookScript then
            tooltip:HookScript("OnTooltipSetItem", function(self) addLines(self, itemIDOf(self)) end)
        end
    end
end
