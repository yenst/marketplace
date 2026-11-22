local _, ns = ...

-- Minimap button through LibDataBroker + LibDBIcon (embedded by the
-- packager, or from another addon). Without them there's no button; the
-- slash command and the guild window tab still open Marketplace.
local function setup()
    local LibStub = _G.LibStub
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (ldb and icon) then
        return
    end
    local launcher = ldb:NewDataObject("Marketplace", {
        type = "launcher",
        text = "Marketplace",
        icon = ns.ICON,
        OnClick = function() ns.Window.Toggle() end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Marketplace", 1, 1, 1)
            tooltip:AddLine("Click to see who in the guild can craft what.", 0.7, 0.7, 0.7)
        end,
    })
    local settings = ns.db.settings
    settings.minimap = settings.minimap or { hide = not settings.minimapButton }
    icon:Register("Marketplace", launcher, settings.minimap)
    ns.minimapIcon = icon
end

-- /mkt minimap
function ns.ToggleMinimapButton()
    local icon, settings = ns.minimapIcon, ns.db.settings
    if not icon then
        ns.Print("The minimap button needs LibDBIcon, which isn't loaded.")
        return
    end
    settings.minimap.hide = not settings.minimap.hide
    if settings.minimap.hide then
        icon:Hide("Marketplace")
    else
        icon:Show("Marketplace")
    end
    ns.Print("Minimap button " .. (settings.minimap.hide and "hidden" or "shown") .. ".")
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", setup)
