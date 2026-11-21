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
local CRAFTER_HEIGHT, CRAFTER_ROWS = 30, 5
local REAGENT_SLOTS, REAGENT_ROW = 8, 38
local TAB_SIZE, MAX_TABS = 36, 12

local frame
local state = { mode = "guild", prof = "all", query = "", onlineOnly = false, collapsed = {}, selected = nil, offset = 0, crafterOffset = 0 }
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

local function gatherPublic()
    local crafters = Data.PublicCrafters({
        me = ns.char and { name = ns.char.name, class = ns.char.class, professions = ns.Public.Mine() },
        public = ns.Public.Data(),
        stateOf = function(sender) return ns.Public.State(sender) end,
        isMe = ns.Sync.IsMe,
    })
    model.crafters, model.rosterSize = crafters, 0
    model.recipes, model.professions = Data.Index(crafters)
end

local function gather()
    if state.mode == "public" then
        return gatherPublic()
    end
    local guild = IsInGuild() and GetGuildInfo("player") or nil
    local own = {}
    for _, c in pairs(ns.db.chars) do
        if c == ns.char or (guild and c.guild == guild) then
            own[#own + 1] = { name = c.fullName or c.name, class = c.class, professions = c.professions, current = c == ns.char }
        end
    end
    local roster, size = readRoster()
    local crafters = Data.Crafters({
        own = own,
        guildData = guild and ns.db.guilds[guild] or {},
        roster = roster,
        seen = ns.Sync.seen,
    })
    model.crafters, model.rosterSize = crafters, size
    model.recipes, model.professions = Data.Index(crafters)
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

local function whisper(name, link, public)
    if ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat("/w " .. name .. " ")
    end
    local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if editBox and link then
        editBox:Insert(public and ("Hi! I saw your Marketplace listing: could you craft " .. link .. " for me? ")
            or ("Hi! Could you craft " .. link .. " for me? "))
    end
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

local function buildFilters()
    frame.search = W.SearchBox(frame.browse, 520, "Search recipes, reagents or members", function(text)
        state.query, state.offset = text, 0
        Window.Refresh()
    end)
    frame.search:SetPoint("TOPLEFT", PAD, -102)
    local online = W.Toggle(frame.browse, "Online only", function() return state.onlineOnly end, function(v)
        state.onlineOnly, state.offset = v, 0
        Window.Refresh()
    end)
    online:SetWidth(120)
    online:SetPoint("LEFT", frame.search, "RIGHT", 14, 0)
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
        row:SetScript("OnClick", function(self)
            local item = self.item
            if not item then
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
    frame.selIcon = tile.icon
    frame.selName = W.Text(left, 14)
    frame.selName:SetPoint("TOPLEFT", tile, "TOPRIGHT", 10, -3)
    frame.selName:SetPoint("RIGHT", left, "RIGHT")
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
        frame.reagents[i] = slot
    end
    frame.reagentLabel = label

    -- Auctionator: mats cost, what's missing, sell price, shopping list.
    frame.costLine = W.Text(left, 11, Theme.text)
    frame.sellLine = W.Text(left, 11, Theme.muted)
    frame.sellLine:SetPoint("TOPLEFT", frame.costLine, "BOTTOMLEFT", 0, -4)
    frame.shop = W.Button(left, "Shopping list", 104, 20, function()
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
    frame.shop:SetPoint("TOPRIGHT", left, "TOPRIGHT", 0, 0)
    W.Tooltip(frame.shop, function(tooltip)
        tooltip:AddLine("Auctionator shopping list", 1, 1, 1)
        tooltip:AddLine("Adds the reagents you're missing, with exact names and amounts, as a list in Auctionator's Shopping tab. Searches them right away if the auction house is open.", 0.7, 0.7, 0.7, true)
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
        row.name = W.Text(row, 12)
        row.name:SetPoint("TOPLEFT", 20, -2)
        row.name:SetPoint("RIGHT", -76, 0)
        row.status = W.Text(row, 11, Theme.muted)
        row.status:SetPoint("BOTTOMLEFT", 20, 2)
        row.status:SetPoint("RIGHT", -76, 0)
        row.fee = W.Text(row, 12, Theme.text, "RIGHT")
        row.fee:SetPoint("TOPRIGHT", -76, -2)
        row.whisper = W.Button(row, "Whisper", 66, 20, function(self)
            whisper(self.target, state.selected and recipeLink(state.selected), state.mode == "public")
        end)
        row.whisper:SetPoint("RIGHT")
        frame.crafters[i] = row
    end
end

local function buildFooter()
    local line = W.Line(frame.browse, Theme.border)
    line:SetPoint("BOTTOMLEFT", 0, 26)
    line:SetPoint("BOTTOMRIGHT", 0, 26)
    frame.footer = W.Text(frame.browse, 11, Theme.muted)
    frame.footer:SetPoint("BOTTOMLEFT", 12, 8)
    local hint = W.Text(frame.browse, 11, Theme.muted, "RIGHT")
    hint:SetPoint("BOTTOMRIGHT", -12, 8)
    hint:SetText("Shift-click a recipe to link it in chat")
end

function Window.SetMode(mode)
    state.mode, state.selected, state.offset, state.crafterOffset = mode, nil, 0, 0
    for key, button in pairs(frame.modes) do
        button:SetSelected(key == mode)
    end
    frame.browse:SetShown(mode ~= "mine")
    frame.search:SetText("")
    if mode == "public" then
        ns.Public.Activate()
    end
    if ns.MyListings then
        ns.MyListings.Show(frame, mode == "mine")
    end
    Window.Refresh()
end

local function buildModes()
    frame.modes = {}
    local mine = W.Button(frame, "My listings", 84, 20, function() Window.SetMode("mine") end)
    mine:SetPoint("TOPRIGHT", -34, -5)
    local public = W.Button(frame, "Public", 60, 20, function() Window.SetMode("public") end)
    public:SetPoint("RIGHT", mine, "LEFT", -4, 0)
    W.Tooltip(public, function(tooltip)
        tooltip:AddLine("Public listings", 1, 1, 1)
        tooltip:AddLine("Crafts anyone running Marketplace offers, with their fee and materials terms.", 0.7, 0.7, 0.7, true)
    end)
    local guild = W.Button(frame, "Guild", 56, 20, function() Window.SetMode("guild") end)
    guild:SetPoint("RIGHT", public, "LEFT", -4, 0)
    guild:SetSelected(true)
    frame.modes.guild, frame.modes.public, frame.modes.mine = guild, public, mine
end

local function buildTabs()
    frame.tabs = {}
    for i = 1, MAX_TABS do
        local tab = W.IconButton(frame.browse, TAB_SIZE, nil, "?", function(self)
            return self.title or "", self.hint
        end, function(self)
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
    buildModes()
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

local function crafterHint(crafters)
    local n = 0
    for _ in pairs(crafters) do
        n = n + 1
    end
    if state.mode == "public" then
        return n > 0 and ns.Plural(n, "lister") or "Nobody lists this publicly yet"
    end
    return n > 0 and ns.Plural(n, "crafter") or "Nobody in your guild has shared this yet"
end

local function drawTabs()
    local list, byId = Data.Tabs(gameProfessions(), model.professions)
    model.tabs = byId
    local entries = { { prof = "all", label = "All professions", texture = ns.ICON } }
    for _, p in ipairs(list) do
        entries[#entries + 1] = { prof = p.id, label = p.name, texture = professionTexture(p.id), hint = crafterHint(p.crafters) }
    end
    if state.prof ~= "all" and not byId[state.prof] then
        state.prof = "all"
    end
    for i, tab in ipairs(frame.tabs) do
        local e = entries[i]
        tab:SetShown(e ~= nil)
        if e then
            tab.prof, tab.title, tab.hint = e.prof, e.label, e.hint
            tab:SetIcon(e.texture, e.label:sub(1, 2))
            tab:SetSelected(state.prof == e.prof)
        end
    end
end

local function drawHeader()
    local onlineNow, total = 0, 0
    local crafters = {}
    if state.prof == "all" then
        for _, c in ipairs(model.crafters) do
            if next(c.professions) then
                crafters[#crafters + 1] = c
            end
        end
        frame.headTitle:SetText("All professions")
        frame.headIcon:SetTexture(ns.ICON)
    else
        local p = model.tabs[state.prof]
        for _, c in pairs(p.crafters) do
            crafters[#crafters + 1] = c
        end
        frame.headTitle:SetText(p.name)
        frame.headIcon:SetTexture(professionTexture(p.id) or ns.ICON)
    end
    for _, c in ipairs(crafters) do
        total = total + 1
        if Data.IsOnline(c.state) then
            onlineNow = onlineNow + 1
        end
    end
    frame.barFill:SetShown(onlineNow > 0)
    frame.barFill:SetWidth(math.max(1, 298 * (total > 0 and onlineNow / total or 0)))
    frame.barText:SetText(string.format(state.mode == "public" and "%d of %s live" or "%d of %s online", onlineNow, ns.Plural(total, "crafter")))
end

-- "3 listings · from 2g"
function Window.FromText(item)
    local text = ns.Plural(item.total, "listing")
    local t = item.cheapest
    if t then
        local cost = ns.Listings.SortCost(t)
        text = text .. " · from " .. (t.tips and "tips" or (cost == 0 and "free" or ns.AH.Money(cost)))
    end
    return text
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
            row.label:SetPoint("LEFT", 22, 0)
            row.label:SetText(item.label)
            row.label:SetTextColor(unpack(Theme.text))
            row.count:SetText(ns.Plural(item.count, "recipe"))
            row.dot:Hide()
            row.selectedBg:Hide()
        elseif item then
            row.band:Hide()
            local meta = ns.Scanner.Meta(item.recipe.id) or {}
            local quality = meta.item and itemQuality(meta.item)
            row.sign:SetText("")
            row.label:SetPoint("LEFT", 34, 0)
            row.label:SetText(Theme.QualityHex(quality or 1) .. item.name .. "|r")
            row.count:SetText(state.mode == "public" and Window.FromText(item) or Data.CrafterText(item))
            row.dot:SetShown(item.online > 0)
            row.selectedBg:SetShown(item.recipe.id == state.selected)
        end
    end
    local count = model.count or 0
    if state.mode == "public" and next(model.recipes) == nil then
        frame.empty:SetText("No public listings yet. They show up as players who run Marketplace list their crafts; list yours under My listings.")
    elseif state.mode == "public" and count == 0 and state.prof ~= "all" and (state.query or "") == "" and not state.onlineOnly then
        local p = model.tabs and model.tabs[state.prof]
        frame.empty:SetText("Nobody lists " .. (p and p.name or "this profession") .. " publicly yet.")
    elseif next(model.recipes) == nil then
        frame.empty:SetText("Nothing here yet. Open your profession windows once to scan them; guildmates who run Marketplace show up as they log in.")
    elseif count == 0 and state.prof ~= "all" and (state.query or "") == "" and not state.onlineOnly then
        local p = model.tabs and model.tabs[state.prof]
        frame.empty:SetText("Nobody in your guild has shared " .. (p and p.name or "this profession") .. " yet.")
    elseif count == 0 then
        frame.empty:SetText("No recipe matches.")
    else
        frame.empty:SetText("")
    end
end

local function drawCosts(meta, reagents, cost)
    local ah = ns.AH.Available()
    frame.costLine:SetShown(ah and #reagents > 0)
    frame.sellLine:SetShown(ah)
    frame.shop:SetShown(ah and #cost.missing > 0)
    if not ah then
        return
    end
    local rows = math.ceil(math.min(#reagents, REAGENT_SLOTS) / 2)
    frame.costLine:ClearAllPoints()
    frame.costLine:SetPoint("TOPLEFT", frame.reagentLabel, "BOTTOMLEFT", 0, -10 - rows * REAGENT_ROW)
    frame.costLine:SetPoint("RIGHT", frame.detail, "RIGHT", -112, 0)
    frame.shop:ClearAllPoints()
    frame.shop:SetPoint("RIGHT", frame.detail, "RIGHT", 0, 0)
    frame.shop:SetPoint("TOP", frame.costLine, "TOP", 0, 4)

    local unknown = cost.unknown > 0 and Theme.Hex(Theme.muted) .. string.format(" (%d without a price)", cost.unknown) .. "|r" or ""
    local short = #cost.missing > 0 and cost.missingTotal > 0
        and string.format(" · you're short %s", ns.AH.Money(cost.missingTotal)) or ""
    frame.costLine:SetText("Mats " .. ns.AH.Money(cost.total) .. short .. unknown)

    local sell = meta.item and ns.AH.Price(meta.item)
    local age = meta.item and ns.AH.Age(meta.item)
    local ageText = age and (age == 0 and " · seen today" or string.format(" · seen %dd ago", age)) or ""
    frame.sellLine:SetText(sell and ("Sells for " .. ns.AH.Money(sell) .. ageText) or "No auction price for the crafted item yet")
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
        return
    end
    local meta = ns.Scanner.Meta(recipe.id) or {}
    local quality = meta.item and itemQuality(meta.item)
    frame.selIcon:SetTexture((meta.item and itemIcon(meta.item)) or meta.icon)
    frame.selName:SetText(Theme.QualityHex(quality or 1) .. (meta.name or ("Recipe " .. recipe.id)) .. "|r")
    frame.selSub:SetText(recipe.profName .. (recipe.catName ~= "Other" and (" · " .. recipe.catName) or ""))
    drawReagents(meta)

    local list = recipe.crafters
    local public = state.mode == "public"
    if public then
        local names = {}
        for _, c in ipairs(list) do
            if c.whisperTo then
                names[#names + 1] = c.whisperTo
            end
        end
        ns.Public.Ping(names)
    end
    state.crafterOffset = math.max(0, math.min(state.crafterOffset, math.max(0, #list - CRAFTER_ROWS)))
    for i, row in ipairs(frame.crafters) do
        local c = list[state.crafterOffset + i]
        row:SetShown(c ~= nil)
        if c then
            local onlineState = Data.IsOnline(c.state)
            row.dot:SetColorTexture(unpack(onlineState and Theme.online or Theme.offline))
            row.dot:SetAlpha((c.state == "noaddon" or c.state == "pinging") and 0.45 or 1)
            row.name:SetText(c.name)
            row.name:SetTextColor(unpack(onlineState and classColor(c.class) or Theme.muted))
            row.name:SetPoint("RIGHT", public and -160 or -76, 0)
            local status = Data.StatusText(c, time())
            local terms = public and Data.TermsFor(c, recipe)
            if terms then
                row.fee:SetText(Window.TermsPrice(terms))
                status = status .. " · " .. ns.Listings.MATS_LABEL[terms.mats]
            else
                row.fee:SetText("")
            end
            row.status:SetText(status)
            row.whisper.target = c.whisperTo or c.name
            if public then
                row.whisper:SetShown(c.state ~= "you")
            else
                row.whisper:SetShown(c.state == "addon" or c.state == "noaddon")
            end
        end
    end
    frame.crafterMore:SetText(#list > CRAFTER_ROWS and string.format("%d of %d  (scroll)", math.min(#list, state.crafterOffset + CRAFTER_ROWS), #list) or "")
end

-- What a listing costs you, in the crafter row: the fee with your mats, or
-- the price with theirs (estimated from Auctionator when it's "mats + fee").
function Window.TermsPrice(terms)
    if terms.mats ~= "provide" then
        return ns.Listings.FeeText(terms, ns.AH.Money)
    end
    if terms.price then
        return ns.AH.Money(terms.price)
    end
    local cost = frame.cost
    if cost and cost.unknown == 0 and cost.total > 0 then
        return "~" .. ns.AH.Money(cost.total + (terms.tips and 0 or terms.fee or 0))
    end
    return ns.Listings.PriceText(terms, ns.AH.Money)
end

local function drawFooter()
    if state.mode == "public" then
        local mine, listers = 0, 0
        for _ in pairs(ns.Public.Mine()) do
            mine = mine + 1
        end
        for _, c in ipairs(model.crafters) do
            if not c.mine then
                listers = listers + 1
            end
        end
        frame.footer:SetText(string.format("%s listing publicly · you list %s", ns.Plural(listers, "player"),
            mine > 0 and ns.Plural(mine, "profession") or "nothing yet"))
        return
    end
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

function Window.Refresh()
    if not frame or not frame:IsShown() then
        return
    end
    if state.mode == "mine" then
        ns.MyListings.Draw() -- leaves the edit boxes alone while typing
        return
    end
    gather()
    drawTabs()
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

function Window.Toggle()
    if not frame then
        build()
    end
    frame:SetShown(not frame:IsShown())
end

ns.OnRefresh(Window.Refresh)
