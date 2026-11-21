local _, ns = ...

local Theme, W = ns.Theme, ns.W
local Window = {}
ns.Window = Window

local frame

-- Placeholder browser window; the real layout comes after the UI research.
local function build()
    frame = W.Window("MarketplaceWindow", 720, 460, "Guild")
    local hint = W.Text(frame, 13, Theme.muted, "CENTER")
    hint:SetPoint("CENTER")
    hint:SetText("The profession browser goes here.")
end

function Window.Toggle()
    if not frame then
        build()
    end
    frame:SetShown(not frame:IsShown())
end
