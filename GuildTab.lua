local _, ns = ...

-- A Marketplace tab on the Guild & Communities window, under its own side
-- tabs (Chat, Roster, Guild Benefits, Guild Info). Blizzard_Communities
-- loads on demand, so this waits for it.
local TAB_KEYS = { "GuildInfoTab", "GuildBenefitsTab", "RosterTab", "ChatTab" }
local tab

local function lowestTab(frame)
    for _, key in ipairs(TAB_KEYS) do
        local t = frame[key]
        if t and t:IsShown() then
            return t
        end
    end
end

local function place()
    local frame = CommunitiesFrame
    if not (frame and tab) then
        return
    end
    tab:ClearAllPoints()
    local anchor = lowestTab(frame)
    if anchor then
        tab:SetPoint("TOP", anchor, "BOTTOM", 0, -6)
    else
        tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 1, -36)
    end
    tab:SetShown(IsInGuild())
end

local function onClick(self)
    if self.SetChecked then
        self:SetChecked(false)
    end
    ns.Window.Show()
end

local function create()
    local frame = CommunitiesFrame
    if tab or not frame then
        return
    end
    -- Blizzard's side tab look where the client has the template.
    local ok, button = pcall(CreateFrame, "CheckButton", "MarketplaceGuildTab", frame, "CommunitiesFrameTabTemplate")
    if ok and button and type(button.Icon) == "table" then
        tab = button
        tab.Icon:SetTexture(ns.ICON)
        tab.tooltip = "Marketplace"
        tab:SetScript("OnClick", onClick)
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Marketplace", 1, 1, 1)
            GameTooltip:AddLine("Who in the guild can craft what.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        tab = ns.W.IconButton(frame, 40, ns.ICON, "Mkt", function()
            return "Marketplace", "Who in the guild can craft what."
        end, onClick)
        tab:SetIcon(ns.ICON, "Mkt")
    end
    ns.guildTab = tab
    frame:HookScript("OnShow", place)
    place()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
    if (event == "ADDON_LOADED" and name == "Blizzard_Communities") or event == "PLAYER_LOGIN" then
        create()
    end
end)
