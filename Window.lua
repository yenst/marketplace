local _, ns = ...

local Theme, W, Data = ns.Theme, ns.W, ns.Data

-- The guild browser, laid out like the in-game profession window: header
-- with the profession and a bar where the skill bar sits, a recipe list
-- grouped under collapsible headers, and the selected recipe's reagents and
-- crafters below it. Profession tabs hang off the right edge like the
-- spellbook's.
local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 760, 680
local PAD = 14
local LIST_TOP = 132
local ROW_HEIGHT, ROWS = 20, 12
local LIST_HEIGHT = ROWS * ROW_HEIGHT + 6
local DETAIL_TOP = LIST_TOP + LIST_HEIGHT + 12
local CRAFTER_HEIGHT, CRAFTER_ROWS = 30, 4
local SOURCE_TOP = 18 + CRAFTER_ROWS * CRAFTER_HEIGHT + 10
local REAGENT_SLOTS, REAGENT_ROW = 8, 38
local TAB_SIZE, MAX_TABS = 36, 12
local MEMBER_ROWS = 12
local STAT_WIDTH = 120
local AUCTIONATOR_LOGO = "Interface\\AddOns\\Auctionator\\Images\\Logo"
local STAT_ICONS = {
    mats = "Interface\\Icons\\INV_Misc_Bag_10",
    short = "Interface\\Icons\\INV_Misc_Note_01",
    sells = "Interface\\Minimap\\Tracking\\Auctioneer",
}

local frame
local state = { prof = "all", query = "", onlineOnly = false, collapsed = { [Data.NOBODY] = true }, selected = nil, offset = 0, crafterOffset = 0 }
local model = { recipes = {}, professions = {}, tabs = {}, crafters = {}, items = {}, rosterSize = 0 }

-- Game data helpers ---------------------------------------------------------

local function itemName(id)
    if C_Item and C_Item.GetItemNameByID then
        return C_Item.GetItemNameByID(id)
    end
    return GetItemInfo and (GetItemInfo(id))
end

local function itemIcon(id)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(id)
    end
    return GetItemIcon and GetItemIcon(id)
end

local function itemQuality(id)
    if C_Item and C_Item.GetItemQualityByID then
        return C_Item.GetItemQualityByID(id)
    end
    return GetItemInfo and select(3, GetItemInfo(id))
end

local function itemCount(id)
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(id, true) or 0
    end
    return GetItemCount and GetItemCount(id, true) or 0
end

-- An item's real chat link, or nil while the client hasn't loaded it.
local function itemLink(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    return id and getInfo and select(2, getInfo(id)) or nil
end

-- Calls fn(link) with the item's chat link: now if it's loaded, else once
-- the client has loaded it (never with a bare "item:123").
local function withItemLink(id, fn)
    local link = itemLink(id)
    if link then
        fn(link)
    elseif Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(id)
        item:ContinueOnItemLoad(function()
            local loaded = item:GetItemLink() or itemLink(id)
            if loaded then
                fn(loaded)
            end
        end)
    end
end

-- Shift-click links the item in chat, ctrl-click previews it in the
-- dressing room. The modifier is read now; the link may come a moment
-- later if the item still has to load.
local function modifiedItemClick(id)
    if not (id and IsModifiedClick) then
        return
    end
    if IsModifiedClick("CHATLINK") then
        withItemLink(id, function(link)
            if ChatEdit_InsertLink then
                ChatEdit_InsertLink(link)
            end
        end)
    elseif IsModifiedClick("DRESSUP") then
        withItemLink(id, function(link)
            if DressUpItemLink then
                DressUpItemLink(link)
            end
        end)
    end
end

local function recipeLink(id)
    local T = C_TradeSkillUI
    return T and T.GetRecipeLink and T.GetRecipeLink(id)
end

local function professionTexture(id)
    local T = C_TradeSkillUI
    return T and T.GetTradeSkillTexture and T.GetTradeSkillTexture(id)
end

-- The classic crafting professions, named the way the client names them.
-- (GetAllProfessionTradeSkillLines on Forever returns several skill lines per
-- profession plus gathering ones, so it isn't used for the tabs.)
local function gameProfessions()
    local T = C_TradeSkillUI
    local list = {}
    for _, p in ipairs(Data.KNOWN_PROFESSIONS) do
        local info = T and T.GetProfessionInfoBySkillLineID and T.GetProfessionInfoBySkillLineID(p.id)
        local name = info and info.professionName
        list[#list + 1] = { id = p.id, name = (name and name ~= "") and name or p.name }
    end
    return list
end

-- A class's round icon, hidden when the class isn't known.
local function setClassIcon(tex, class)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(unpack(coords))
        tex:Show()
    else
        tex:Hide()
    end
end

local function classColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and { c.r, c.g, c.b, 1 } or Theme.text
end

-- Roster by short name: { online, class, lastOnline (seconds ago) }.
local function readRoster()
    local roster, size = {}, 0
    if not IsInGuild() or not GetNumGuildMembers then
        return roster, 0
    end
    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, _, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
        if name then
            size = size + 1
            local ago
            if not isOnline and GetGuildRosterLastOnline then
                local years, months, days, hours = GetGuildRosterLastOnline(i)
                if years then
                    ago = (((years * 365 + months * 30 + days) * 24) + hours) * 3600
                end
            end
            roster[Data.ShortName(name)] = { online = isOnline, class = classFile, lastOnline = ago }
        end
    end
    return roster, size
end

local function gather()
    local guild = IsInGuild() and GetGuildInfo("player") or nil
    local own = {}
    for _, c in pairs(ns.db.chars) do
        if c == ns.char or (guild and c.guild == guild) then
            own[#own + 1] = { name = c.fullName or c.name, class = c.class, professions = c.professions, current = c == ns.char, partial = not c.fullName }
        end
    end
    local roster, size = readRoster()
    local crafters = Data.Crafters({
        own = own,
        guildData = guild and ns.db.guilds[guild] or {},
        roster = roster,
        seen = ns.Sync.seen,
        trustRoster = ns.Sync.Members() ~= nil,
    })
    model.crafters, model.rosterSize = crafters, size
    local names = {}
    for _, p in ipairs(gameProfessions()) do
        names[p.id] = p.name
    end
    model.recipes, model.professions = Data.Index(crafters, ns.RecipeDB, names)
    model.builtAt = GetTime and GetTime() or time()
end

-- The browser's data for other parts of the addon (pattern tooltips),
-- rebuilt when older than 10 seconds.
function Window.Model()
    local now = GetTime and GetTime() or time()
    if not model.builtAt or now - model.builtAt > 10 then
        gather()
    end
    return model
end

-- Building blocks -------------------------------------------------------------

local function hoverTexture(parent)
    local t = parent:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(1, 1, 1, 0.04)
    t:Hide()
    return t
end

local function iconTile(parent, size)
    local tile = W.Panel(parent, Theme.bgRaised)
    tile:SetSize(size, size)
    tile.icon = tile:CreateTexture(nil, "ARTWORK")
    tile.icon:SetPoint("TOPLEFT", 1, -1)
    tile.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    tile.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return tile
end

local function whisper(name, link)
    if ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat("/w " .. name .. " ")
    end
    local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if editBox and link then
        editBox:Insert("Hi! Could you craft " .. link .. " for me? ")
    end
end

-- Where a recipe is learned: game lookups for Data.Sources.
local MERCHANTS_FAVOR = 3402
local STANDINGS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local sourceLookup = {
    zone = function(area)
        return C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(area)
    end,
    quest = function(id)
        local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
        if not title and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
            C_QuestLog.RequestLoadQuestByID(id)
        end
        return title
    end,
    factionName = function(id)
        if C_Reputation and C_Reputation.GetFactionDataByID then
            local data = C_Reputation.GetFactionDataByID(id)
            if data and data.name then
                return data.name
            end
        end
        return GetFactionInfoByID and (GetFactionInfoByID(id))
    end,
    standing = function(n)
        return _G["FACTION_STANDING_LABEL" .. n] or STANDINGS[n] or ("Standing " .. n)
    end,
    money = function(copper)
        return ns.Coins(copper)
    end,
    favor = function(n)
        local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(MERCHANTS_FAVOR)
        local icon = info and info.iconFileID and ("|T" .. info.iconFileID .. ":12:12|t ") or ""
        return n .. " " .. icon .. (info and info.name or "Merchant's Favor")
    end,
}

-- Favourites ---------------------------------------------------------------

-- The client's favourite star when it has the atlas (as in the auction
-- house), else the reputation star.
local function setStar(tex, on)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("auctionhouse-icon-favorite") then
        tex:SetAtlas(on and "auctionhouse-icon-favorite" or "auctionhouse-icon-favorite-off")
        tex:SetDesaturated(false)
        tex:SetAlpha(on and 1 or 0.5)
    else
        tex:SetTexture("Interface\\Common\\ReputationStar")
        tex:SetTexCoord(0, 0.5, 0, 0.5)
        tex:SetDesaturated(not on)
        tex:SetAlpha(on and 1 or 0.35)
    end
end

function Window.ToggleFavorite(recipeID)
    local favorites = ns.db.favorites
    favorites[recipeID] = not favorites[recipeID] or nil
    Window.Refresh()
end

-- Layout --------------------------------------------------------------------

local function buildHeader()
    local tile = iconTile(frame.browse, 42)
    tile:SetPoint("TOPLEFT", PAD, -42)
    frame.headIcon = tile.icon
    frame.headTitle = W.Text(frame.browse, 15)
    frame.headTitle:SetPoint("TOPLEFT", tile, "TOPRIGHT", 12, -2)

    local bar = W.Panel(frame.browse, { 0.02, 0.03, 0.04, 1 })
    bar:SetSize(300, 16)
    bar:SetPoint("BOTTOMLEFT", tile, "BOTTOMRIGHT", 12, 0)
    frame.barFill = bar:CreateTexture(nil, "ARTWORK")
    frame.barFill:SetPoint("TOPLEFT", 1, -1)
    frame.barFill:SetPoint("BOTTOMLEFT", 1, 1)
    frame.barFill:SetColorTexture(0.18, 0.48, 0.29, 1)
    frame.barText = W.Text(bar, 11, Theme.text, "CENTER")
    frame.barText:SetPoint("CENTER")

    local line = W.Line(frame.browse)
    line:SetPoint("TOPLEFT", PAD, -94)
    line:SetPoint("TOPRIGHT", -PAD, -94)
end

-- Sets (or with nil clears) the member filter.
local function setMember(key)
    state.member, state.offset = key, 0
    if frame.memberMenu then
        frame.memberMenu:Hide()
    end
    Window.Refresh()
end

local function buildMemberMenu()
    local menu = W.Panel(frame.browse, { 0.04, 0.06, 0.08, 1 })
    menu:SetSize(220, MEMBER_ROWS * ROW_HEIGHT + 8)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    menu:Hide()
    menu.offset = 0
    menu:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, math.min(math.max(0, #(self.entries or {}) - MEMBER_ROWS), self.offset - delta * 3))
        Window.DrawMemberMenu()
    end)
    menu.rows = {}
    for i = 1, MEMBER_ROWS do
        local row = CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * ROW_HEIGHT)
        row.hover = hoverTexture(row)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(6, 6)
        row.dot:SetPoint("LEFT", 6, 0)
        row.dot:SetColorTexture(unpack(Theme.online))
        row.class = row:CreateTexture(nil, "ARTWORK")
        row.class:SetSize(15, 15)
        row.class:SetPoint("LEFT", 16, 0)
        row.label = W.Text(row, 12)
        row.label:SetPoint("LEFT", 36, 0)
        row.label:SetPoint("RIGHT", -40, 0)
        row.count = W.Text(row, 11, Theme.muted, "RIGHT")
        row.count:SetPoint("RIGHT", -6, 0)
        row:SetScript("OnEnter", function(self) self.hover:Show() end)
        row:SetScript("OnLeave", function(self) self.hover:Hide() end)
        row:SetScript("OnClick", function(self) setMember(self.key or nil) end)
        menu.rows[i] = row
    end
    frame.memberMenu = menu
    frame:HookScript("OnHide", function() menu:Hide() end)
end

local function buildFilters()
    -- Redraw once typing pauses: every search scans the whole catalog.
    local searchToken
    frame.search = W.SearchBox(frame.browse, 520, "Search recipes, reagents or members", function(text)
        state.query, state.offset = text, 0
        local token = {}
        searchToken = token
        C_Timer.After(0.25, function()
            if searchToken == token then
                Window.Refresh()
            end
        end)
    end)
    frame.search:SetPoint("TOPLEFT", PAD, -102)
    frame.search:SetWidth(360)

    -- Member filter: only one guildmate's patterns.
    frame.member = W.Button(frame.browse, "All members", 170, 24, function()
        Window.ToggleMemberMenu()
    end)
    frame.member:SetPoint("LEFT", frame.search, "RIGHT", 10, 0)
    frame.member.text:ClearAllPoints()
    frame.member.text:SetPoint("LEFT", 10, 0)
    frame.member.text:SetPoint("RIGHT", -22, 0)
    frame.member.text:SetJustifyH("LEFT")
    local arrow = frame.member:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    buildMemberMenu()
    local online = W.Toggle(frame.browse, "Online only", function() return state.onlineOnly end, function(v)
        state.onlineOnly, state.offset = v, 0
        Window.Refresh()
    end)
    online:SetWidth(120)
    online:SetPoint("LEFT", frame.member, "RIGHT", 14, 0)
end

local function buildList()
    local list = W.Panel(frame.browse, { 0.04, 0.06, 0.08, 1 })
    list:SetPoint("TOPLEFT", PAD, -LIST_TOP)
    list:SetPoint("TOPRIGHT", -PAD, -LIST_TOP)
    list:SetHeight(LIST_HEIGHT)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, math.min(math.max(0, #model.items - ROWS), state.offset - delta * 3))
        Window.DrawList()
    end)
    frame.list = list

    frame.empty = W.Text(list, 12, Theme.muted, "CENTER")
    frame.empty:SetPoint("CENTER")
    frame.empty:SetWidth(520)
    frame.empty:SetWordWrap(true)

    frame.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 3, -3 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -3, -3 - (i - 1) * ROW_HEIGHT)
        row.hover = hoverTexture(row)
        -- Category headers sit on a shaded band so groups read at a glance.
        row.band = row:CreateTexture(nil, "BACKGROUND", nil, -1)
        row.band:SetAllPoints()
        row.band:SetColorTexture(1, 1, 1, 0.05)
        row.selectedBg = row:CreateTexture(nil, "BACKGROUND")
        row.selectedBg:SetAllPoints()
        row.selectedBg:SetColorTexture(Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.16)
        row.sign = W.Text(row, 13, Theme.accent)
        row.sign:SetPoint("LEFT", 7, 0)
        row.star = row:CreateTexture(nil, "ARTWORK")
        row.star:SetSize(13, 13)
        row.star:Hide()
        row.label = W.Text(row, 12)
        row.label:SetPoint("LEFT", 22, 0)
        row.label:SetPoint("RIGHT", -150, 0)
        row.count = W.Text(row, 11, Theme.muted, "RIGHT")
        row.count:SetPoint("RIGHT", -8, 0)
        row.count:SetWidth(110)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(6, 6)
        row.dot:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
        row.dot:SetColorTexture(unpack(Theme.online))
        row:SetScript("OnEnter", function(self)
            self.hover:Show()
            local link = self.item and not self.item.header and recipeLink(self.item.recipe.id)
            if link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            self.hover:Hide()
            GameTooltip:Hide()
        end)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            local item = self.item
            if not item then
                return
            end
            if button == "RightButton" then
                if not item.header then
                    Window.ToggleFavorite(item.recipe.id)
                end
                return
            end
            if item.header then
                state.collapsed[item.label] = not state.collapsed[item.label] or nil
                Window.Refresh()
                return
            end
            local link = recipeLink(item.recipe.id)
            if link and IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
                ChatEdit_InsertLink(link)
                return
            end
            if IsModifiedClick and IsModifiedClick("DRESSUP") then
                local meta = ns.Scanner.Meta(item.recipe.id)
                if meta and meta.item then
                    modifiedItemClick(meta.item)
                end
                return
            end
            state.selected, state.crafterOffset = item.recipe.id, 0
            Window.DrawList()
            Window.DrawDetail()
        end)
        frame.rows[i] = row
    end
end

local function buildDetail()
    local left = CreateFrame("Frame", nil, frame.browse)
    left:SetPoint("TOPLEFT", PAD, -DETAIL_TOP)
    left:SetSize(420, HEIGHT - DETAIL_TOP - 40)
    frame.detail = left

    local tile = iconTile(left, 40)
    tile:SetPoint("TOPLEFT")
    tile:EnableMouse(true)
    tile:SetScript("OnEnter", function(self)
        local link = state.selected and recipeLink(state.selected)
        if link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end
    end)
    tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tile:SetScript("OnMouseUp", function()
        local meta = state.selected and ns.Scanner.Meta(state.selected)
        if meta and meta.item then
            modifiedItemClick(meta.item)
        end
    end)
    frame.selTile = tile
    frame.selIcon = tile.icon
    frame.selName = W.Text(left, 14)
    frame.selName:SetPoint("TOPLEFT", tile, "TOPRIGHT", 10, -3)
    frame.selName:SetPoint("RIGHT", left, "RIGHT", -30, 0)
    local fav = CreateFrame("Button", nil, left)
    fav:SetSize(22, 22)
    fav:SetPoint("TOPRIGHT", 0, 0)
    fav.star = fav:CreateTexture(nil, "ARTWORK")
    fav.star:SetAllPoints()
    fav:SetScript("OnClick", function()
        if state.selected then
            Window.ToggleFavorite(state.selected)
        end
    end)
    fav:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.db.favorites[state.selected] and "Remove from favorites" or "Add to favorites", 1, 1, 1)
        GameTooltip:AddLine("Favorites are listed at the top. Right-click a recipe in the list to do the same.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    fav:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.favorite = fav
    frame.selSub = W.Text(left, 11, Theme.muted)
    frame.selSub:SetPoint("TOPLEFT", frame.selName, "BOTTOMLEFT", 0, -5)

    local label = W.Text(left, 11, Theme.muted)
    label:SetPoint("TOPLEFT", tile, "BOTTOMLEFT", 0, -10)
    label:SetText("Reagents")

    frame.reagents = {}
    for i = 1, REAGENT_SLOTS do
        local slot = W.Panel(left, { 0.04, 0.06, 0.08, 1 })
        slot:SetSize(204, 34)
        local col, rowIndex = (i - 1) % 2, math.floor((i - 1) / 2)
        slot:SetPoint("TOPLEFT", label, "BOTTOMLEFT", col * 212, -6 - rowIndex * REAGENT_ROW)
        slot.tile = iconTile(slot, 34)
        slot.tile:SetPoint("LEFT")
        slot.count = W.Text(slot.tile, 10, Theme.text, "RIGHT")
        W.SetFont(slot.count, 10, "OUTLINE")
        slot.count:SetPoint("BOTTOMRIGHT", -1, 2)
        slot.name = W.Text(slot, 11)
        slot.name:SetPoint("RIGHT", -4, 0)
        slot.price = W.Text(slot, 10, Theme.muted)
        slot.price:SetPoint("BOTTOMLEFT", slot.tile, "BOTTOMRIGHT", 8, 4)
        slot:EnableMouse(true)
        slot:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.itemID)
                GameTooltip:Show()
            end
        end)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slot:SetScript("OnMouseUp", function(self)
            if self.itemID then
                modifiedItemClick(self.itemID)
            end
        end)
        frame.reagents[i] = slot
    end
    frame.reagentLabel = label

    -- Track Recipe, as in the profession window: its reagents go to the
    -- objective tracker.
    frame.track = W.Toggle(left, "Track recipe", function()
        local T = C_TradeSkillUI
        return state.selected and T and T.IsRecipeTracked and T.IsRecipeTracked(state.selected, false) or false
    end, function(on)
        local T = C_TradeSkillUI
        if state.selected and T and T.SetRecipeTracked then
            T.SetRecipeTracked(state.selected, on, false)
        end
    end)
    frame.track:SetWidth(140)
    frame.track:SetPoint("BOTTOMLEFT", 0, 4)

    -- Auctionator: mats cost, what's missing and the sell price as small
    -- tiles, plus a shopping list button with Auctionator's logo.
    frame.stats = {}
    for i, key in ipairs({ "mats", "short", "sells" }) do
        local tile = W.Panel(left, { 0.04, 0.06, 0.08, 1 })
        tile:SetSize(STAT_WIDTH, 34)
        tile.icon = tile:CreateTexture(nil, "ARTWORK")
        tile.icon:SetSize(24, 24)
        tile.icon:SetPoint("LEFT", 5, 0)
        tile.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        tile.icon:SetTexture(STAT_ICONS[key])
        tile.label = W.Text(tile, 10, Theme.muted)
        tile.label:SetPoint("TOPLEFT", tile.icon, "TOPRIGHT", 7, 1)
        tile.label:SetPoint("RIGHT", -4, 0)
        tile.value = W.Text(tile, 12)
        tile.value:SetPoint("BOTTOMLEFT", tile.icon, "BOTTOMRIGHT", 7, -1)
        tile.value:SetPoint("RIGHT", -4, 0)
        tile:EnableMouse(true)
        W.Tooltip(tile, function(tooltip)
            tooltip:AddLine(tile.tipTitle or "", 1, 1, 1)
            if tile.tipText then
                tooltip:AddLine(tile.tipText, 0.7, 0.7, 0.7, true)
            end
        end)
        frame.stats[key] = tile
        frame.stats[i] = tile
    end
    frame.shop = W.IconButton(left, 34, AUCTIONATOR_LOGO, "AH", function()
        return "Auctionator shopping list",
            "Adds the reagents you're missing, with exact names and amounts, as a list in Auctionator's Shopping tab. Searches them right away if the auction house is open."
    end, function()
        local cost = frame.cost
        local meta = state.selected and ns.Scanner.Meta(state.selected)
        if not (cost and meta) then
            return
        end
        local listName = ns.AH.ShoppingList(meta.name or "recipe", cost.missing, itemName)
        if listName then
            ns.Print("Auctionator shopping list \"" .. listName .. "\" is ready: find it in the Shopping tab at the auction house.")
        end
    end)

    local divider = frame.browse:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(Theme.hairline))
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
    divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 12, 0)

    local right = CreateFrame("Frame", nil, frame.browse)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 26, 0)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -DETAIL_TOP)
    right:SetHeight(HEIGHT - DETAIL_TOP - 40)
    right:EnableMouseWheel(true)
    right:SetScript("OnMouseWheel", function(_, delta)
        local recipe = state.selected and model.recipes[state.selected]
        local total = recipe and #recipe.crafters or 0
        state.crafterOffset = math.max(0, math.min(math.max(0, total - CRAFTER_ROWS), state.crafterOffset - delta))
        Window.DrawDetail()
    end)
    local title = W.Text(right, 11, Theme.muted)
    title:SetPoint("TOPLEFT")
    title:SetText("Crafters")
    frame.crafterMore = W.Text(right, 11, Theme.muted, "RIGHT")
    frame.crafterMore:SetPoint("TOPRIGHT")

    frame.crafters = {}
    for i = 1, CRAFTER_ROWS do
        local row = CreateFrame("Frame", nil, right)
        row:SetHeight(CRAFTER_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -18 - (i - 1) * CRAFTER_HEIGHT)
        row:SetPoint("TOPRIGHT", 0, -18 - (i - 1) * CRAFTER_HEIGHT)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(8, 8)
        row.dot:SetPoint("LEFT", 4, 0)
        row.class = row:CreateTexture(nil, "ARTWORK")
        row.class:SetSize(22, 22)
        row.class:SetPoint("LEFT", 18, 0)
        row.name = W.Text(row, 12)
        row.name:SetPoint("TOPLEFT", 46, -2)
        row.name:SetPoint("RIGHT", -32, 0)
        row.status = W.Text(row, 11, Theme.muted)
        row.status:SetPoint("BOTTOMLEFT", 46, 2)
        row.status:SetPoint("RIGHT", -32, 0)
        row.whisper = W.IconButton(row, 24, "Interface\\ChatFrame\\UI-ChatIcon-Chat-Up", "W", function(self)
            return "Whisper " .. (self.target or ""), "Opens a tell with the recipe link in it."
        end, function(self)
            whisper(self.target, state.selected and recipeLink(state.selected))
        end)
        row.whisper:SetPoint("RIGHT")
        -- Click the name: only this member's patterns.
        row.pick = CreateFrame("Button", nil, row)
        row.pick:SetPoint("TOPLEFT")
        row.pick:SetPoint("BOTTOMRIGHT", -32, 0)
        row.pick:SetScript("OnClick", function(self)
            if self.key then
                setMember(self.key)
            end
        end)
        row.pick:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Show only " .. (self.name or "their") .. "'s patterns", 1, 1, 1)
            GameTooltip:Show()
        end)
        row.pick:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frame.crafters[i] = row
    end
    frame.nobody = W.Text(right, 12, Theme.muted)
    frame.nobody:SetPoint("TOPLEFT", 4, -24)
    frame.nobody:SetPoint("RIGHT")
    frame.nobody:SetWordWrap(true)
    frame.nobody:SetText("Nobody in your guild knows this recipe yet.")

    -- Where to learn it (from the recipe catalog); hover for the recipe item.
    local source = CreateFrame("Frame", nil, right)
    source:SetPoint("TOPLEFT", 0, -SOURCE_TOP)
    source:SetPoint("BOTTOMRIGHT")
    source:EnableMouse(true)
    source:SetScript("OnEnter", function(self)
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end
    end)
    source:SetScript("OnLeave", function() GameTooltip:Hide() end)
    source:SetScript("OnMouseUp", function(self)
        if self.itemID then
            modifiedItemClick(self.itemID) -- the pattern / recipe item
        end
    end)
    local line = W.Line(source)
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    local sourceTitle = W.Text(source, 11, Theme.muted)
    sourceTitle:SetPoint("TOPLEFT", 0, -8)
    sourceTitle:SetText("Where to learn it")
    frame.sourceSkill = W.Text(source, 11, Theme.muted, "RIGHT")
    frame.sourceSkill:SetPoint("TOPRIGHT", 0, -8)
    frame.sourceText = W.Text(source, 11)
    frame.sourceText:SetPoint("TOPLEFT", sourceTitle, "BOTTOMLEFT", 0, -6)
    frame.sourceText:SetPoint("BOTTOMRIGHT", 0, 2)
    frame.sourceText:SetJustifyV("TOP")
    frame.sourceText:SetWordWrap(true)
    frame.source = source
end

local function buildFooter()
    local line = W.Line(frame.browse, Theme.border)
    line:SetPoint("BOTTOMLEFT", 0, 26)
    line:SetPoint("BOTTOMRIGHT", 0, 26)
    frame.footer = W.Text(frame.browse, 11, Theme.muted)
    frame.footer:SetPoint("BOTTOMLEFT", 12, 8)
    -- Compares with the guild now; how it went is written next to it.
    frame.refresh = W.Button(frame.browse, "Refresh", 64, 18, function()
        ns.Sync.RequestLatest()
        Window.DrawSync()
    end)
    frame.refresh:SetPoint("BOTTOMRIGHT", -12, 4)
    W.Tooltip(frame.refresh, function(tip)
        tip:AddLine("Refresh")
        tip:AddLine("Asks the guild for recipes newer than the ones you have. What you already have isn't sent again.", 1, 1, 1, true)
    end)
    frame.syncText = W.Text(frame.browse, 11, Theme.muted, "RIGHT")
    frame.syncText:SetPoint("RIGHT", frame.refresh, "LEFT", -8, 0)
end

local function buildTabs()
    frame.tabs = {}
    for i = 1, MAX_TABS do
        local tab = W.IconButton(frame.browse, TAB_SIZE, nil, "?", nil, function(self)
            state.prof, state.offset, state.selected = self.prof, 0, nil
            Window.Refresh()
        end)
        tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", -1, -48 - (i - 1) * (TAB_SIZE + 4) - (i > 1 and 6 or 0))
        tab:Hide()
        frame.tabs[i] = tab
    end
end

local function build()
    frame = W.Window("MarketplaceWindow", WIDTH, HEIGHT)
    frame.subtitle:Hide()
    frame.browse = CreateFrame("Frame", nil, frame)
    frame.browse:SetAllPoints()
    buildHeader()
    buildFilters()
    buildList()
    buildDetail()
    buildFooter()
    buildTabs()
    frame:SetScript("OnShow", function()
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        elseif GuildRoster then
            GuildRoster()
        end
        Window.Refresh()
    end)
end

-- Drawing ---------------------------------------------------------------------

local function drawTabs()
    local list, byId = Data.Tabs(gameProfessions(), model.professions)
    model.tabs = byId
    local entries = { { prof = "all", label = "All professions", texture = ns.ICON } }
    for _, p in ipairs(list) do
        entries[#entries + 1] = { prof = p.id, label = p.name, texture = professionTexture(p.id) }
    end
    if state.prof ~= "all" and not byId[state.prof] then
        state.prof = "all"
    end
    for i, tab in ipairs(frame.tabs) do
        local e = entries[i]
        tab:SetShown(e ~= nil)
        if e then
            tab.prof, tab.title = e.prof, e.label
            tab:SetIcon(e.texture, e.label:sub(1, 2))
            tab:SetSelected(state.prof == e.prof)
        end
    end
end

-- Header: the profession, and a bar of how many of its patterns the guild
-- has unlocked (someone can craft them) out of all there are.
local function drawHeader()
    if state.prof == "all" then
        frame.headTitle:SetText("All professions")
        frame.headIcon:SetTexture(ns.ICON)
    else
        local p = model.tabs[state.prof]
        frame.headTitle:SetText(p.name)
        frame.headIcon:SetTexture(professionTexture(p.id) or ns.ICON)
    end
    local known, total = Data.Coverage(model.recipes, state.prof, state.member)
    frame.barFill:SetShown(known > 0)
    frame.barFill:SetWidth(math.max(1, 298 * (total > 0 and known / total or 0)))
    if state.member then
        frame.barText:SetText(string.format("%s knows %d of %d patterns", state.memberName or state.member, known, total))
    else
        frame.barText:SetText(string.format("%d of %d patterns unlocked", known, total))
    end
end

function Window.DrawList()
    if not frame then
        return
    end
    local items = model.items
    state.offset = math.max(0, math.min(state.offset, math.max(0, #items - ROWS)))
    for i, row in ipairs(frame.rows) do
        local item = items[state.offset + i]
        row.item = item
        row:SetShown(item ~= nil)
        if item and item.header then
            row.band:Show()
            row.sign:SetText(item.collapsed and "+" or "-")
            row.star:SetShown(item.favorites)
            if item.favorites then
                row.star:ClearAllPoints()
                row.star:SetPoint("LEFT", 20, 0)
                setStar(row.star, true)
            end
            row.label:SetPoint("LEFT", item.favorites and 38 or 22, 0)
            row.label:SetText(item.label)
            row.label:SetTextColor(unpack(Theme.text))
            row.label:SetAlpha(1)
            row.count:SetText(ns.Plural(item.count, "recipe"))
            row.dot:Hide()
            row.selectedBg:Hide()
        elseif item then
            row.band:Hide()
            local meta = ns.Scanner.Meta(item.recipe.id) or {}
            local quality = meta.item and itemQuality(meta.item)
            row.sign:SetText("")
            row.star:Hide()
            row.label:SetPoint("LEFT", 34, 0)
            row.label:SetText(Theme.QualityHex(quality or 1) .. item.name .. "|r")
            row.label:SetAlpha(item.total == 0 and 0.6 or 1)
            local text = Data.CrafterText(item)
            row.count:SetText(text)
            row.dot:SetShown(item.online > 0)
            row.dot:ClearAllPoints()
            if text == "" then
                row.dot:SetPoint("RIGHT", -10, 0)
            else
                row.dot:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
            end
            row.selectedBg:SetShown(item.recipe.id == state.selected)
        end
    end
    local count = model.count or 0
    if next(model.recipes) == nil then
        frame.empty:SetText("Nothing here yet. Open your profession windows once to scan them; guildmates who run Marketplace show up as they log in.")
    elseif count == 0 and state.prof ~= "all" and (state.query or "") == "" and not state.onlineOnly then
        local p = model.tabs and model.tabs[state.prof]
        frame.empty:SetText("Nobody in your guild has shared " .. (p and p.name or "this profession") .. " yet.")
    elseif count == 0 and state.member then
        frame.empty:SetText((state.memberName or state.member) .. " has no patterns here.")
    elseif count == 0 then
        frame.empty:SetText("No recipe matches.")
    else
        frame.empty:SetText("")
    end
end

local function setStat(tile, label, value, title, text)
    tile.label:SetText(label)
    tile.value:SetText(value)
    tile.tipTitle, tile.tipText = title, text
end

local function drawCosts(meta, reagents, cost)
    local ah = ns.AH.Available()
    for _, tile in ipairs(frame.stats) do
        tile:SetShown(ah)
    end
    frame.shop:SetShown(ah and #cost.missing > 0)
    if not ah then
        return
    end
    local rows = math.ceil(math.min(#reagents, REAGENT_SLOTS) / 2)
    local top = -10 - rows * REAGENT_ROW
    for i, tile in ipairs(frame.stats) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", frame.reagentLabel, "BOTTOMLEFT", (i - 1) * (STAT_WIDTH + 6), top)
    end
    frame.shop:ClearAllPoints()
    frame.shop:SetPoint("LEFT", frame.stats.sells, "RIGHT", 6, 0)

    local muted = Theme.Hex(Theme.muted)
    local unpriced = cost.unknown > 0 and string.format("%d reagent%s without an auction price %s left out.", cost.unknown, cost.unknown == 1 and "" or "s", cost.unknown == 1 and "is" or "are") or nil
    setStat(frame.stats.mats, "Mats cost", (#reagents > 0 and cost.total > 0) and (ns.AH.Money(cost.total) .. (cost.unknown > 0 and (muted .. " +?|r") or "")) or (muted .. "No price|r"),
        "What the reagents cost", unpriced or "From Auctionator's last scan.")

    if #cost.missing == 0 then
        setStat(frame.stats.short, "You're short", Theme.Hex(Theme.online) .. "Nothing|r", "You have every reagent", "Counts your bags and bank.")
    else
        setStat(frame.stats.short, "You're short", cost.missingTotal > 0 and (Theme.Hex(Theme.bad) .. ns.AH.Money(cost.missingTotal) .. "|r") or (Theme.Hex(Theme.bad) .. ns.Plural(#cost.missing, "reagent") .. "|r"),
            "What you still need to buy", "Counts your bags and bank. The button next to it makes an Auctionator shopping list of it.")
    end

    local sell = meta.item and ns.AH.Price(meta.item)
    local age = meta.item and ns.AH.Age(meta.item)
    local profit
    if sell and cost.total > 0 and cost.unknown == 0 then
        local diff = sell - cost.total
        profit = (diff >= 0 and "Profit over the mats: " or "Loss against the mats: ") .. ns.AH.Money(math.abs(diff))
    end
    local seen = age and (age == 0 and "Seen at the auction house today." or string.format("Last seen at the auction house %d day%s ago.", age, age == 1 and "" or "s")) or nil
    setStat(frame.stats.sells, age and (age == 0 and "Sells for · today" or string.format("Sells for · %dd ago", age)) or "Sells for",
        sell and ns.AH.Money(sell) or (muted .. "No price|r"),
        "Auction price of the crafted item", table.concat({ seen or "No auction price for it yet.", profit }, "\n"))
end

local function drawReagents(meta)
    local reagents = meta and meta.reagents or {}
    local cost = ns.AH.Costs(reagents, ns.AH.Price, itemCount)
    frame.cost = cost
    for i, slot in ipairs(frame.reagents) do
        local r = reagents[i]
        slot:SetShown(r ~= nil)
        if r then
            local id, need = r[1], r[2]
            local have = itemCount(id)
            local line = cost.lines[i]
            slot.itemID = id
            slot.tile.icon:SetTexture(itemIcon(id))
            slot.count:SetText(have .. "/" .. need)
            slot.count:SetTextColor(unpack(have >= need and Theme.text or Theme.bad))
            slot.name:SetText(itemName(id) or "…")
            slot.name:ClearAllPoints()
            slot.name:SetPoint("RIGHT", -4, 0)
            if line and line.cost then
                slot.name:SetPoint("TOPLEFT", slot.tile, "TOPRIGHT", 8, -4)
                slot.price:SetText(ns.AH.Money(line.cost))
                slot.price:Show()
            else
                slot.name:SetPoint("LEFT", slot.tile, "RIGHT", 8, 0)
                slot.price:Hide()
            end
        end
    end
    drawCosts(meta or {}, reagents, cost)
end

-- The game's own icons for where a recipe comes from (gossip trainer and
-- vendor icons, the quest "!", …) in place of the words.
local SOURCE_ICONS = {
    Trainer = "Interface\\GossipFrame\\TrainerGossipIcon",
    Vendor = "Interface\\GossipFrame\\VendorGossipIcon",
    Quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    Drop = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
    Reputation = "Interface\\Icons\\INV_Misc_Note_02",
    Known = "Interface\\Icons\\INV_Misc_Book_09",
    Crafted = "Interface\\Icons\\INV_Misc_Gear_01",
    World = "Interface\\Icons\\INV_Misc_Map_01",
    Source = "Interface\\Icons\\INV_Misc_QuestionMark",
}
local FACTION_ICONS = {
    ["Alliance only"] = "|TInterface\\TargetingFrame\\UI-PVP-Alliance:16:16:0:0:64:64:0:40:0:40|t",
    ["Horde only"] = "|TInterface\\TargetingFrame\\UI-PVP-Horde:16:16:0:0:64:64:0:40:0:40|t",
}

local function inlineIcon(path)
    return path and ("|T" .. path .. ":14:14:0:0|t") or ""
end

-- One line per source: "[vendor icon]  Sold in Stormwind", … plus the
-- recipe item (its icon) and its auction price when it can be bought.
local function drawSource(recipe)
    local entry = recipe.source
    local muted = Theme.Hex(Theme.muted)
    frame.source.itemID = entry and entry.t
    frame.sourceSkill:SetText(recipe.skill and ("Skill " .. recipe.skill) or "")
    if not entry then
        frame.sourceText:SetText(muted .. "Not in the recipe list Marketplace ships with.|r")
        return
    end
    local lines = {}
    for _, l in ipairs(Data.Sources(entry, UnitFactionGroup and UnitFactionGroup("player"), sourceLookup)) do
        if l.label == "Faction" and FACTION_ICONS[l.text] then
            lines[#lines + 1] = FACTION_ICONS[l.text] .. " " .. l.text
        else
            lines[#lines + 1] = inlineIcon(SOURCE_ICONS[l.label]) .. "  " .. l.text
        end
    end
    if entry.t then
        local icon = inlineIcon(itemIcon(entry.t) or SOURCE_ICONS.Source)
        if not entry.b then
            local price = ns.AH.Available() and ns.AH.Price(entry.t)
            lines[#lines + 1] = icon .. "  " .. (price and ("Pattern on the auction house: " .. ns.AH.Money(price)) or "Pattern can be traded")
        else
            lines[#lines + 1] = icon .. "  " .. muted .. "Pattern binds when picked up|r"
        end
    end
    frame.sourceText:SetText(table.concat(lines, "\n"))
end

function Window.DrawDetail()
    if not frame then
        return
    end
    local recipe = state.selected and model.recipes[state.selected]
    frame.detail:SetShown(recipe ~= nil)
    if not recipe then
        for _, row in ipairs(frame.crafters) do
            row:Hide()
        end
        frame.crafterMore:SetText("")
        frame.nobody:Hide()
        return
    end
    local meta = ns.Scanner.Meta(recipe.id) or {}
    local quality = meta.item and itemQuality(meta.item)
    frame.selIcon:SetTexture((meta.item and itemIcon(meta.item)) or meta.icon)
    setStar(frame.favorite.star, ns.db.favorites[recipe.id] == true)
    frame.selName:SetText(Theme.QualityHex(quality or 1) .. (meta.name or ("Recipe " .. recipe.id)) .. "|r")
    frame.selSub:SetText(recipe.profName .. (recipe.catName ~= "Other" and (" · " .. recipe.catName) or ""))
    drawReagents(meta)
    local T = C_TradeSkillUI
    frame.track:SetShown(T and T.SetRecipeTracked and T.IsRecipeTracked and true or false)
    frame.track:Update()

    local list = recipe.crafters
    state.crafterOffset = math.max(0, math.min(state.crafterOffset, math.max(0, #list - CRAFTER_ROWS)))
    for i, row in ipairs(frame.crafters) do
        local c = list[state.crafterOffset + i]
        row:SetShown(c ~= nil)
        if c then
            local onlineState = Data.IsOnline(c.state)
            row.dot:SetColorTexture(unpack(onlineState and Theme.online or Theme.offline))
            row.dot:SetAlpha((c.state == "noaddon" or c.state == "pinging") and 0.45 or 1)
            -- "Billy Joel (215)": their level in this recipe's profession.
            local p = c.professions and c.professions[recipe.prof]
            row.name:SetText(c.name .. (p and p.skill and p.skill > 0 and (Theme.Hex(Theme.muted) .. " (" .. p.skill .. ")|r") or ""))
            row.name:SetTextColor(unpack(onlineState and classColor(c.class) or Theme.muted))
            setClassIcon(row.class, c.class)
            row.class:SetDesaturated(not onlineState)
            row.class:SetAlpha(onlineState and 1 or 0.6)
            local status = Data.StatusText(c, time())
            row.status:SetText(status)
            row.name:ClearAllPoints()
            row.name:SetPoint("RIGHT", -32, 0)
            if status == "" then
                row.name:SetPoint("LEFT", 46, 0) -- online: the dot says it
            else
                row.name:SetPoint("TOPLEFT", 46, -2)
            end
            row.whisper.target = c.name
            row.pick.key, row.pick.name = c.key, c.name
            row.whisper:SetShown(c.state == "addon" or c.state == "noaddon")
        end
    end
    frame.crafterMore:SetText(#list > CRAFTER_ROWS and string.format("%d of %d  (scroll)", math.min(#list, state.crafterOffset + CRAFTER_ROWS), #list) or "")
    frame.nobody:SetShown(#list == 0)
    drawSource(recipe)
end

function Window.DrawMemberMenu()
    local menu = frame.memberMenu
    if not menu:IsShown() then
        return
    end
    local entries = { { name = "All members" } }
    for _, m in ipairs(Data.Members(model.recipes, state.prof)) do
        entries[#entries + 1] = m
    end
    menu.entries = entries
    local rows = math.min(#entries, MEMBER_ROWS)
    menu:SetHeight(rows * ROW_HEIGHT + 8)
    menu.offset = math.max(0, math.min(menu.offset, #entries - MEMBER_ROWS))
    for i, row in ipairs(menu.rows) do
        local e = entries[menu.offset + i]
        row:SetShown(e ~= nil)
        if e then
            row.key = e.key or false -- false: "All members"
            row.label:SetText(e.name .. (e.skill and e.skill > 0 and (Theme.Hex(Theme.muted) .. " (" .. e.skill .. ")|r") or ""))
            local selected = e.key == state.member
            row.label:SetTextColor(unpack(e.key and classColor(e.class) or Theme.text))
            setClassIcon(row.class, e.key and e.class)
            row.label:SetAlpha((selected or not state.member and not e.key) and 1 or 0.85)
            row.count:SetText(e.count and tostring(e.count) or "")
            row.dot:SetShown(e.state ~= nil and Data.IsOnline(e.state))
        end
    end
end

function Window.ToggleMemberMenu()
    local menu = frame.memberMenu
    if menu:IsShown() then
        menu:Hide()
        return
    end
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", frame.member, "BOTTOMLEFT", 0, -2)
    menu.offset = 0
    menu:Show()
    Window.DrawMemberMenu()
end

local function drawFooter()
    local others = 0
    for _, c in ipairs(model.crafters) do
        if not c.mine then
            others = others + 1
        end
    end
    if model.rosterSize > 0 then
        frame.footer:SetText(string.format("Data from %d of %s", others, ns.Plural(model.rosterSize, "guild member")))
    else
        frame.footer:SetText("Not in a guild: showing your own characters")
    end
end

-- The Refresh button and how the last refresh went.
function Window.DrawSync()
    if not frame or not frame:IsShown() then
        return
    end
    local phase, got, total = ns.Sync.RefreshState()
    frame.syncText:SetText(Data.RefreshText(phase, got, total))
    frame.refresh:SetDisabled(model.rosterSize == 0 or phase == "checking" or phase == "updating")
end
ns.Sync.OnRefresh = Window.DrawSync

function Window.Refresh()
    if not frame or not frame:IsShown() then
        return
    end
    gather()
    drawTabs()
    state.favorites = ns.db.favorites
    state.memberName = nil
    for _, c in ipairs(model.crafters) do
        if c.key == state.member then
            state.memberName = c.name
        end
    end
    frame.member:SetLabel(state.memberName or (state.member or "All members"))
    model.items, model.count = Data.List(model.recipes, state, function(id) return ns.Scanner.Meta(id) end, itemName)
    if not state.selected or not model.recipes[state.selected] then
        state.selected = nil
        for _, item in ipairs(model.items) do
            if not item.header then
                state.selected = item.recipe.id
                break
            end
        end
    end
    drawHeader()
    Window.DrawList()
    Window.DrawDetail()
    drawFooter()
    Window.DrawSync()
    Window.DrawMemberMenu()
end

-- Tracking changed elsewhere (the profession window, the tracker).
function Window.TrackingChanged()
    if frame and frame:IsShown() and frame.track then
        frame.track:Update()
    end
end

-- Item names and icons load lazily; redraw once a burst of them arrived.
local redrawQueued = false
function Window.ItemDataArrived()
    if redrawQueued or not frame or not frame:IsShown() then
        return
    end
    redrawQueued = true
    C_Timer.After(0.3, function()
        redrawQueued = false
        Window.Refresh()
    end)
end

function Window.Show()
    if not frame then
        build()
    end
    frame:Show()
    if frame.Raise then
        frame:Raise()
    end
end

function Window.Toggle()
    if not frame then
        build()
    end
    frame:SetShown(not frame:IsShown())
end

ns.OnRefresh(Window.Refresh)
