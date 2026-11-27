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
local LIST_HEADER_HEIGHT = 20
local ROW_HEIGHT, ROWS = 20, 11
local LIST_HEIGHT = LIST_HEADER_HEIGHT + ROWS * ROW_HEIGHT + 6
local DETAIL_TOP = LIST_TOP + LIST_HEIGHT + 12
local CRAFTER_HEIGHT, CRAFTER_ROWS = 30, 4
local SOURCE_TOP = 18 + CRAFTER_ROWS * CRAFTER_HEIGHT + 10
local REAGENT_SLOTS, REAGENT_ROW = 8, 38
local TAB_SIZE, MAX_TABS = 36, 12
local MEMBER_ROWS = 12
local SEARCH_WIDTH = 284
local DROPDOWN_WIDTH = 156
local SORT_MENU_WIDTH = 168
local ONLINE_WIDTH = 106
local STAT_WIDTH = 120
local AUCTIONATOR_LOGO = "Interface\\AddOns\\Auctionator\\Images\\Logo"
local STAT_ICONS = {
    mats = "Interface\\Icons\\INV_Misc_Bag_10",
    short = "Interface\\Icons\\INV_Misc_Note_01",
    sells = "Interface\\Minimap\\Tracking\\Auctioneer",
}

local frame
local state = { prof = "all", query = "", onlineOnly = false, sort = "name", collapsed = { [Data.NOBODY] = true }, selected = nil, offset = 0, crafterOffset = 0 }
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

-- Puts a link in the open chat edit box. Newer clients have this in
-- ChatFrameUtil; the old global is the fallback.
local function insertLink(link)
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        return ChatFrameUtil.InsertLink(link)
    elseif ChatEdit_InsertLink then
        return ChatEdit_InsertLink(link)
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
            insertLink(link)
        end)
    elseif IsModifiedClick("DRESSUP") then
        withItemLink(id, function(link)
            if DressUpItemLink then
                DressUpItemLink(link)
            end
        end)
    end
end

-- The game's link for a recipe; where it has none (it doesn't always for
-- recipes of professions you don't have), one built the same way.
local function recipeLink(id)
    local T = C_TradeSkillUI
    local link = T and T.GetRecipeLink and T.GetRecipeLink(id)
    if link then
        return link
    end
    local meta = ns.Scanner.Meta(id)
    if not (meta and meta.name) then
        return nil
    end
    local recipe = model.recipes[id]
    local label = recipe and recipe.profName and (recipe.profName .. ": " .. meta.name) or meta.name
    return string.format("|cffffd000|Henchant:%d|h[%s]|h|r", id, label)
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

local function rosterLastOnline(index)
    if not GetGuildRosterLastOnline then
        return nil
    end
    local years, months, days, hours = GetGuildRosterLastOnline(index)
    if not years then
        return nil
    end
    return (((years * 365 + months * 30 + days) * 24) + hours) * 3600
end

-- Roster by short name: { online, class, lastOnline (seconds ago) }.
local function readRoster()
    local roster, size = {}, 0
    if not IsInGuild() or not GetNumGuildMembers then
        return roster, 0
    end
    local myGuid = UnitGUID and UnitGUID("player")
    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, _, _, _, isOnline, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if name then
            size = size + 1
            local short = Data.ShortName(name)
            if myGuid and guid and guid == myGuid and ns.char and not ns.char.rosterName then
                ns.char.rosterName = short
            end
            local ago = not isOnline and rosterLastOnline(i) or nil
            roster[short] = { online = isOnline, class = classFile, lastOnline = ago }
        end
    end
    return roster, size
end

local function gather()
    local guild = IsInGuild() and GetGuildInfo("player") or nil
    local own = {}
    for k, c in pairs(ns.db.chars) do
        if c == ns.char or (guild and c.guild == guild) then
            local full = c.fullName or c.rosterName
            own[#own + 1] = { key = not full and k or nil, name = full or c.name, class = c.class, professions = c.professions, current = c == ns.char, partial = not full }
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

-- Opens a tell to name with a request for the recipe in it. Newer clients
-- moved the chat functions into ChatFrameUtil; the old globals are the
-- fallback.
local function activeEditBox()
    local U = ChatFrameUtil
    return (U and U.GetActiveWindow and U.GetActiveWindow())
        or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
        or nil
end

local function whisper(name, link)
    local U = ChatFrameUtil
    if U and U.SendTell then
        U.SendTell(name)
    elseif ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    elseif U and U.OpenChat then
        U.OpenChat("/w " .. name .. " ")
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat("/w " .. name .. " ")
    end
    if not link then
        return
    end
    -- The game writes "/w name " into the edit box on its next frame
    -- (editBox.setText is 1 until then) and turns it into the tell header;
    -- anything inserted before that is overwritten. So wait for it.
    local text = "Hi! Could you craft " .. link .. " for me? "
    local tries = 0
    local function insert()
        local editBox = activeEditBox()
        if editBox and editBox.setText ~= 1 then
            local chatType = editBox.GetAttribute and editBox:GetAttribute("chatType")
            if not chatType or chatType == "WHISPER" then
                editBox:Insert(text)
            end
            return
        end
        tries = tries + 1
        if tries <= 20 and C_Timer and C_Timer.After then
            C_Timer.After(0.05, insert)
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.05, insert)
    else
        insert()
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

local function hideMenus()
    if not frame then
        return
    end
    if frame.memberMenu then
        frame.memberMenu:Hide()
    end
    if frame.sortMenu then
        frame.sortMenu:Hide()
    end
end

-- Sets (or with nil clears) the member filter.
local function setMember(key)
    state.member, state.offset, state.selected = key, 0, nil
    hideMenus()
    Window.Refresh()
end

local function setSort(key)
    if not Data.SortInfo(key) then
        return
    end
    state.sort, state.offset = key, 0
    if ns.db and ns.db.settings then
        ns.db.settings.sort = key
    end
    hideMenus()
    Window.Refresh()
end

local function dropdownButton(parent, label, width, onClick)
    local button = W.Button(parent, label, width, 24, onClick)
    button.text:ClearAllPoints()
    button.text:SetPoint("LEFT", 10, 0)
    button.text:SetPoint("RIGHT", -22, 0)
    button.text:SetJustifyH("LEFT")
    local arrow = button:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    return button
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
    menu.scroll = W.ScrollBar(menu, function(offset)
        menu.offset = offset
        Window.DrawMemberMenu()
    end)
    menu.scroll:SetPoint("TOPRIGHT", -3, -4)
    menu.scroll:SetPoint("BOTTOMRIGHT", -3, 4)
    menu.rows = {}
    for i = 1, MEMBER_ROWS do
        local row = CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -12, -4 - (i - 1) * ROW_HEIGHT)
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
end

local function buildSortMenu()
    local menu = W.Panel(frame.browse, { 0.04, 0.06, 0.08, 1 })
    menu:SetSize(SORT_MENU_WIDTH, #Data.SORTS * ROW_HEIGHT + 8)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu:Hide()
    menu.rows = {}
    for i, option in ipairs(Data.SORTS) do
        local row = CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * ROW_HEIGHT)
        row.key = option.key
        row.hover = hoverTexture(row)
        row.label = W.Text(row, 12)
        row.label:SetPoint("LEFT", 8, 0)
        row.label:SetPoint("RIGHT", -8, 0)
        row.label:SetText(option.label)
        row:SetScript("OnEnter", function(self) self.hover:Show() end)
        row:SetScript("OnLeave", function(self) self.hover:Hide() end)
        row:SetScript("OnClick", function(self) setSort(self.key) end)
        menu.rows[i] = row
    end
    frame.sortMenu = menu
end

local function buildFilters()
    -- Redraw once typing pauses: every search scans the whole catalog.
    local searchToken
    frame.search = W.SearchBox(frame.browse, SEARCH_WIDTH, "Search recipes, reagents or members", function(text)
        state.query, state.offset, state.selected = text, 0, nil
        local token = {}
        searchToken = token
        C_Timer.After(0.25, function()
            if searchToken == token then
                Window.Refresh()
            end
        end)
    end)
    frame.search:SetPoint("TOPLEFT", PAD, -102)
    frame.search:HookScript("OnEditFocusGained", hideMenus)

    -- Member filter: only one guildmate's patterns.
    frame.member = dropdownButton(frame.browse, "All members", DROPDOWN_WIDTH, function()
        Window.ToggleMemberMenu()
    end)
    frame.member:SetPoint("LEFT", frame.search, "RIGHT", 8, 0)
    buildMemberMenu()

    -- Sort order for recipes within each group.
    frame.sort = dropdownButton(frame.browse, "Sort: Name", DROPDOWN_WIDTH, function()
        Window.ToggleSortMenu()
    end)
    frame.sort:SetPoint("LEFT", frame.member, "RIGHT", 8, 0)
    buildSortMenu()

    frame:HookScript("OnHide", hideMenus)
    frame:HookScript("OnMouseDown", hideMenus)

    local online = W.Toggle(frame.browse, "Online only", function() return state.onlineOnly end, function(v)
        state.onlineOnly, state.offset, state.selected = v, 0, nil
        hideMenus()
        Window.Refresh()
    end)
    online:SetWidth(ONLINE_WIDTH)
    online:SetPoint("LEFT", frame.sort, "RIGHT", 14, 0)
end

local function onListRowClick(self, button)
    hideMenus()
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
    if link and IsModifiedClick and IsModifiedClick("CHATLINK") then
        insertLink(link)
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
end

local function buildListRow(list, index)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 3, -LIST_HEADER_HEIGHT - 3 - (index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", -12, -LIST_HEADER_HEIGHT - 3 - (index - 1) * ROW_HEIGHT)
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
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(6, 6)
    row.dot:SetPoint("LEFT", 20, 0)
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
    row:SetScript("OnClick", onListRowClick)
    return row
end

local function drawListHeader()
    if not (frame and frame.colRecipe and frame.colSkill) then
        return
    end
    local skillSorted = state.sort == "skill_asc" or state.sort == "skill_desc"
    frame.colRecipe.label:SetTextColor(unpack(state.sort == "name" and Theme.accent or Theme.muted))
    frame.colSkill.label:SetTextColor(unpack(skillSorted and Theme.accent or Theme.muted))
end

local function columnHeaderButton(parent, label, width, justify, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button.label = W.Text(button, 11, Theme.muted, justify)
    button.label:SetAllPoints()
    button.label:SetText(label)
    button:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(Theme.text)) end)
    button:SetScript("OnLeave", drawListHeader)
    button:SetScript("OnClick", onClick)
    return button
end

local function buildListHeader(list)
    local header = CreateFrame("Frame", nil, list)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(LIST_HEADER_HEIGHT)
    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.03)
    local line = W.Line(header)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")

    frame.colRecipe = columnHeaderButton(header, "Recipe", 120, "LEFT", function()
        setSort("name")
    end)
    frame.colRecipe:SetPoint("TOPLEFT", 24, 0)
    frame.colRecipe:SetPoint("BOTTOMLEFT", 24, 0)

    -- Aligns with row.count's right edge (row -12 + count -8 = -20 from list, -19 from header).
    frame.colSkill = columnHeaderButton(header, "Skill", 80, "RIGHT", function()
        setSort(state.sort == "skill_asc" and "skill_desc" or "skill_asc")
    end)
    frame.colSkill:SetPoint("TOPRIGHT", -19, 0)
    frame.colSkill:SetPoint("BOTTOMRIGHT", -19, 0)
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
    buildListHeader(list)
    frame.listScroll = W.ScrollBar(list, function(offset)
        state.offset = offset
        Window.DrawList()
    end)
    frame.listScroll:SetPoint("TOPRIGHT", -3, -(LIST_HEADER_HEIGHT + 3))
    frame.listScroll:SetPoint("BOTTOMRIGHT", -3, 3)

    frame.empty = W.Text(list, 12, Theme.muted, "CENTER")
    frame.empty:SetPoint("CENTER", 0, -LIST_HEADER_HEIGHT / 2)
    frame.empty:SetWidth(520)
    frame.empty:SetWordWrap(true)

    frame.rows = {}
    for i = 1, ROWS do
        frame.rows[i] = buildListRow(list, i)
    end
end

local function buildDetailHeader(left)
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
    frame.track:SetWidth(100)
    frame.track:SetPoint("TOPRIGHT", 0, -22)
    frame.selSub:SetPoint("RIGHT", frame.track, "LEFT", -8, 0)
    return tile
end

local function buildReagentSlots(left, anchor)
    local label = W.Text(left, 11, Theme.muted)
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    label:SetText("Reagents")
    frame.reagentLabel = label

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
end

-- Auctionator: mats cost, what's missing and the sell price as small tiles,
-- plus a shopping list button with Auctionator's logo.
local function buildCostTiles(left)
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
end

local function buildCrafterRow(right, index)
    local row = CreateFrame("Frame", nil, right)
    row:SetHeight(CRAFTER_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -18 - (index - 1) * CRAFTER_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -18 - (index - 1) * CRAFTER_HEIGHT)
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
    return row
end

local function buildCrafters(right)
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
        frame.crafters[i] = buildCrafterRow(right, i)
    end
    frame.nobody = W.Text(right, 12, Theme.muted)
    frame.nobody:SetPoint("TOPLEFT", 4, -24)
    frame.nobody:SetPoint("RIGHT")
    frame.nobody:SetWordWrap(true)
    frame.nobody:SetText("Nobody in your guild knows this recipe yet.")
end

-- Where to learn it (from the recipe catalog); hover for the recipe item.
local function buildSourcePanel(right)
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

local function buildDetail()
    local left = CreateFrame("Frame", nil, frame.browse)
    left:SetPoint("TOPLEFT", PAD, -DETAIL_TOP)
    left:SetSize(420, HEIGHT - DETAIL_TOP - 40)
    frame.detail = left

    local tile = buildDetailHeader(left)
    buildReagentSlots(left, tile)
    buildCostTiles(left)

    local divider = frame.browse:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(Theme.hairline))
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
    divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 12, 0)

    local right = CreateFrame("Frame", nil, frame.browse)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 26, 0)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -DETAIL_TOP)
    right:SetHeight(HEIGHT - DETAIL_TOP - 40)
    frame.right = right

    buildCrafters(right)
    buildSourcePanel(right)
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
            hideMenus()
            Window.Refresh()
        end)
        tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", -1, -48 - (i - 1) * (TAB_SIZE + 4) - (i > 1 and 6 or 0))
        tab:Hide()
        frame.tabs[i] = tab
    end
end

local function build()
    frame = W.Window("MarketplaceWindow", WIDTH, HEIGHT, nil, function(point, relPoint, x, y)
        if ns.db and ns.db.settings then
            ns.db.settings.windowPos = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
        end
    end)
    local pos = ns.db and ns.db.settings and ns.db.settings.windowPos
    if type(pos) == "table" and pos[1] and pos[2] and pos[3] and pos[4] then
        frame:ClearAllPoints()
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end
    local savedSort = ns.db and ns.db.settings and ns.db.settings.sort
    if Data.SortInfo(savedSort) then
        state.sort = savedSort
    end
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
        ns.Sync.RequestRoster()
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

local function drawHeaderRow(row, item)
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
    row.count:SetText("")
    row.dot:Hide()
    row.selectedBg:Hide()
end

local function drawRecipeRow(row, item)
    row.band:Hide()
    local meta = ns.Scanner.Meta(item.recipe.id) or {}
    local quality = meta.item and itemQuality(meta.item)
    row.sign:SetText("")
    row.star:Hide()
    row.label:SetPoint("LEFT", 34, 0)
    row.label:SetText(Theme.QualityHex(quality or 1) .. item.name .. "|r")
    row.label:SetAlpha(item.total == 0 and 0.6 or 1)
    row.count:SetText(Data.CrafterText(item, state.sort))
    row.dot:SetShown(item.online > 0)
    row.selectedBg:SetShown(item.recipe.id == state.selected)
end

local function emptyListMessage()
    local count = model.count or 0
    if next(model.recipes) == nil then
        return "Nothing here yet. Open your profession windows once to scan them; guildmates who run Marketplace show up as they log in."
    end
    if count > 0 then
        return ""
    end
    if state.prof ~= "all" and (state.query or "") == "" and not state.onlineOnly then
        local p = model.tabs and model.tabs[state.prof]
        return "Nobody in your guild has shared " .. (p and p.name or "this profession") .. " yet."
    end
    if state.member then
        return (state.memberName or state.member) .. " has no patterns here."
    end
    return "No recipe matches."
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
            drawHeaderRow(row, item)
        elseif item then
            drawRecipeRow(row, item)
        end
    end
    if frame.listScroll then
        frame.listScroll:Update(state.offset, ROWS, #items)
    end
    drawListHeader()
    frame.empty:SetText(emptyListMessage())
end

local function setStat(tile, label, value, title, text)
    tile.label:SetText(label)
    tile.value:SetText(value)
    tile.tipTitle, tile.tipText = title, text
end

local function unpricedNote(count, noun)
    if count <= 0 then
        return nil
    end
    local verb = count == 1 and "is" or "are"
    return string.format("%s without an auction price %s left out.", ns.Plural(count, noun), verb)
end

local function drawMatsStat(reagents, cost, muted)
    local value = muted .. "No price|r"
    if #reagents > 0 and cost.total > 0 then
        local suffix = cost.unknown > 0 and (muted .. " +?|r") or ""
        value = ns.AH.Money(cost.total) .. suffix
    end
    local tip = unpricedNote(cost.unknown, "reagent") or "From Auctionator's last scan."
    setStat(frame.stats.mats, "Mats cost", value, "What the reagents cost", tip)
end

local function drawShortStat(cost, muted)
    if #cost.missing == 0 then
        setStat(frame.stats.short, "You're short", Theme.Hex(Theme.online) .. "Nothing|r", "You have every reagent", "Counts your bags and bank.")
        return
    end
    local value
    if cost.missingTotal > 0 then
        local suffix = cost.missingUnknown > 0 and (muted .. " +?|r") or ""
        value = Theme.Hex(Theme.bad) .. ns.AH.Money(cost.missingTotal) .. "|r" .. suffix
    else
        value = Theme.Hex(Theme.bad) .. ns.Plural(#cost.missing, "reagent") .. "|r"
    end
    local tip = "Counts your bags and bank. The button next to it makes an Auctionator shopping list of it."
    local missingNote = unpricedNote(cost.missingUnknown, "missing reagent")
    if missingNote then
        tip = tip .. "\n" .. missingNote
    end
    setStat(frame.stats.short, "You're short", value, "What you still need to buy", tip)
end

local function formatSeenAge(age)
    if not age then
        return "No auction price for it yet."
    end
    if age == 0 then
        return "Seen at the auction house today."
    end
    return string.format("Last seen at the auction house %s ago.", ns.Plural(age, "day"))
end

local function formatSellsLabel(base, age)
    if not age then
        return base
    end
    if age == 0 then
        return base .. " · today"
    end
    return string.format("%s · %dd ago", base, age)
end

local function drawSellStat(recipe, meta, cost, muted)
    local unitSell = meta.item and ns.AH.AuctionPrice(meta.item)
    local yield, yieldLabel = ns.AH.CraftYield(recipe and recipe.source and recipe.source.n, meta)
    local sell = unitSell and math.floor(unitSell * yield + 0.5) or nil
    local age = meta.item and ns.AH.Age(meta.item)

    local tipParts = { formatSeenAge(age) }
    if unitSell and yieldLabel then
        tipParts[#tipParts + 1] = string.format("%s each (%s per craft).", ns.AH.Money(unitSell), yieldLabel)
    end
    if sell and cost.total > 0 and cost.unknown == 0 then
        local diff = sell - cost.total
        local prefix = diff >= 0 and "Profit over the mats: " or "Loss against the mats: "
        tipParts[#tipParts + 1] = prefix .. ns.AH.Money(math.abs(diff))
    end
    local sellsBase = yieldLabel and ("Sells (" .. yieldLabel .. ")") or "Sells for"
    local value = sell and ns.AH.Money(sell) or (muted .. "No price|r")
    setStat(frame.stats.sells, formatSellsLabel(sellsBase, age), value, "Auction price of the crafted item", table.concat(tipParts, "\n"))
end

local function drawCosts(recipe, meta, reagents, cost)
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
    drawMatsStat(reagents, cost, muted)
    drawShortStat(cost, muted)
    drawSellStat(recipe, meta, cost, muted)
end

local function drawReagents(recipe, meta)
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
    drawCosts(recipe, meta or {}, reagents, cost)
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
            local price = ns.AH.Available() and ns.AH.AuctionPrice(entry.t)
            lines[#lines + 1] = icon .. "  " .. (price and ("Pattern on the auction house: " .. ns.AH.Money(price)) or "Pattern can be traded")
        else
            lines[#lines + 1] = icon .. "  " .. muted .. "Pattern binds when picked up|r"
        end
    end
    frame.sourceText:SetText(table.concat(lines, "\n"))
end

local function drawCrafterRow(row, c, profID)
    local onlineState = Data.IsOnline(c.state)
    row.dot:SetColorTexture(unpack(onlineState and Theme.online or Theme.offline))
    row.dot:SetAlpha(c.state == "noaddon" and 0.45 or 1)
    -- "Billy Joel (215)": their level in this recipe's profession.
    local p = c.professions and c.professions[profID]
    local skillSuffix = p and p.skill and p.skill > 0 and (Theme.Hex(Theme.muted) .. " (" .. p.skill .. ")|r") or ""
    row.name:SetText(c.name .. skillSuffix)
    row.name:SetTextColor(unpack(onlineState and classColor(c.class) or Theme.muted))
    setClassIcon(row.class, c.class)
    row.class:SetDesaturated(not onlineState)
    row.class:SetAlpha(onlineState and 1 or 0.6)
    local status = Data.StatusText(c, ns.Now())
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

function Window.DrawDetail()
    if not frame then
        return
    end
    local recipe = state.selected and model.recipes[state.selected]
    frame.detail:SetShown(recipe ~= nil)
    frame.right:SetShown(recipe ~= nil)
    frame.source:SetShown(recipe ~= nil)
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
    drawReagents(recipe, meta)
    local T = C_TradeSkillUI
    frame.track:SetShown(T and T.SetRecipeTracked and T.IsRecipeTracked and true or false)
    frame.track:Update()

    local list = recipe.crafters
    state.crafterOffset = math.max(0, math.min(state.crafterOffset, math.max(0, #list - CRAFTER_ROWS)))
    for i, row in ipairs(frame.crafters) do
        local c = list[state.crafterOffset + i]
        row:SetShown(c ~= nil)
        if c then
            drawCrafterRow(row, c, recipe.prof)
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
    if menu.scroll then
        menu.scroll:Update(menu.offset, MEMBER_ROWS, #entries)
    end
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
    hideMenus()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", frame.member, "BOTTOMLEFT", 0, -2)
    menu.offset = 0
    menu:Show()
    Window.DrawMemberMenu()
end

function Window.DrawSortMenu()
    local menu = frame.sortMenu
    if not menu or not menu:IsShown() then
        return
    end
    for _, row in ipairs(menu.rows) do
        local selected = row.key == state.sort
        row.label:SetTextColor(unpack(selected and Theme.accent or Theme.text))
        row.label:SetAlpha(selected and 1 or 0.85)
    end
end

function Window.ToggleSortMenu()
    local menu = frame.sortMenu
    if menu:IsShown() then
        menu:Hide()
        return
    end
    hideMenus()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", frame.sort, "BOTTOMLEFT", 0, -2)
    menu:Show()
    Window.DrawSortMenu()
end

local function drawFooter()
    local covered = 0
    for _, c in ipairs(model.crafters) do
        if not c.mine or next(c.professions) then
            covered = covered + 1
        end
    end
    if model.rosterSize > 0 then
        frame.footer:SetText(string.format("Data from %d of %s", math.min(covered, model.rosterSize), ns.Plural(model.rosterSize, "guild member")))
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
    local cooldown = ns.Sync.RefreshCooldown()
    frame.syncText:SetText(Data.RefreshText(phase, got, total))
    frame.refresh:SetDisabled(model.rosterSize == 0 or phase == "checking" or phase == "updating" or cooldown > 0)
end
ns.Sync.OnRefresh = Window.DrawSync

local function ensureSelection()
    if state.selected and model.recipes[state.selected] then
        return
    end
    state.selected = nil
    for _, item in ipairs(model.items) do
        if not item.header then
            state.selected = item.recipe.id
            return
        end
    end
end

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
    local sortInfo = Data.SortInfo(state.sort) or Data.SORTS[1]
    frame.sort:SetLabel(sortInfo.buttonLabel)
    model.items, model.count = Data.List(model.recipes, state, function(id) return ns.Scanner.Meta(id) end, itemName)
    ensureSelection()
    drawHeader()
    Window.DrawList()
    Window.DrawDetail()
    drawFooter()
    Window.DrawSync()
    Window.DrawMemberMenu()
    Window.DrawSortMenu()
end

-- Tracking changed elsewhere (the profession window, the tracker).
function Window.TrackingChanged()
    if frame and frame:IsShown() and frame.track then
        frame.track:Update()
    end
end

-- Item names and icons load lazily; redraw once a burst of them arrived,
-- without re-reading the guild roster or rebuilding the recipe index.
local redrawQueued = false
function Window.ItemDataArrived()
    if redrawQueued or not frame or not frame:IsShown() then
        return
    end
    redrawQueued = true
    C_Timer.After(0.3, function()
        redrawQueued = false
        if not frame or not frame:IsShown() then
            return
        end
        if (state.query or "") ~= "" then
            model.items, model.count = Data.List(model.recipes, state, function(id) return ns.Scanner.Meta(id) end, itemName)
            ensureSelection()
        end
        Window.DrawList()
        Window.DrawDetail()
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

ns.OnRefresh(function()
    model.builtAt = nil
    Window.Refresh()
end)
