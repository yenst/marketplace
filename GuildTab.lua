local _, ns = ...

-- A Marketplace tab on the Guild & Communities window, under its own side
-- tabs (Chat, Roster, Guild Benefits, Guild Info). Blizzard_Communities
-- loads on demand, so this waits for it.
local TAB_KEYS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }
local tab

local function isSideTab(child, right)
    if child == tab or not child:IsShown() or not right then
        return false
    end
    local left, bottom = child:GetLeft(), child:GetBottom()
    local width = child:GetWidth() or 0
    return left and bottom and left >= right - 8 and width > 0 and width < 80
end

-- The lowest tab hanging off the window's right edge: Blizzard's (some are
-- shown or hidden only after the window opens) or another addon's.
local function lowestTab(frame)
    local right = frame:GetRight()
    local best, bestBottom
    for _, child in ipairs({ frame:GetChildren() }) do
        if isSideTab(child, right) then
            local bottom = child:GetBottom()
            if not bestBottom or bottom < bestBottom then
                best, bestBottom = child, bottom
            end
        end
    end
    if best then
        return best
    end
    for i = #TAB_KEYS, 1, -1 do
        local t = frame[TAB_KEYS[i]]
        if type(t) == "table" and t:IsShown() then
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

local GuildTab = {}
ns.GuildTab = GuildTab

-- Again once the window has settled (tabs appear a frame or two later);
-- coalesced so bursts of tab Show/Hide hooks don't stack redundant timers.
local placePending = false
local function placeSoon()
    place()
    if placePending then
        return
    end
    placePending = true
    C_Timer.After(0, place)
    C_Timer.After(0.3, function()
        placePending = false
        place()
    end)
end

local function onClick(self)
    if self.SetChecked then
        self:SetChecked(false)
    end
    ns.Window.Show()
end

local events
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
    end
    ns.guildTab = tab
    if events then
        events:UnregisterEvent("ADDON_LOADED")
    end
    frame:HookScript("OnShow", placeSoon)
    for _, key in ipairs(TAB_KEYS) do
        local t = frame[key]
        if type(t) == "table" and t.HookScript then
            t:HookScript("OnShow", placeSoon)
            t:HookScript("OnHide", placeSoon)
        end
    end
    placeSoon()
end

function GuildTab.Update()
    if tab then
        placeSoon()
    end
end

function GuildTab.Init()
    create()
    if not tab and not events then
        events = CreateFrame("Frame")
        events:RegisterEvent("ADDON_LOADED")
        events:SetScript("OnEvent", function(_, _, name)
            if name == "Blizzard_Communities" then
                create()
            end
        end)
    end
end
