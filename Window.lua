local _, ns = ...

local Theme, W, Data = ns.Theme, ns.W, ns.Data

-- The guild browser, laid out like the in-game profession window: header
-- with the profession and a bar where the skill bar sits, a recipe list
-- grouped under collapsible headers, and the selected recipe's reagents and
-- crafters below it. Profession tabs hang off the right edge like the
-- spellbook's.
local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 760, 620
local PAD = 14
local LIST_TOP = 132
local ROW_HEIGHT, ROWS = 20, 12
local LIST_HEIGHT = ROWS * ROW_HEIGHT + 6
local DETAIL_TOP = LIST_TOP + LIST_HEIGHT + 12
local CRAFTER_HEIGHT, CRAFTER_ROWS = 30, 5
local REAGENT_SLOTS = 8
local TAB_SIZE, MAX_TABS = 36, 12

local frame
local state = { prof = "all", query = "", onlineOnly = false, collapsed = {}, selected = nil, offset = 0, crafterOffset = 0 }
local model = { recipes = {}, professions = {}, crafters = {}, items = {}, rosterSize = 0 }

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

-- Layout --------------------------------------------------------------------

local function buildHeader()
    local tile = iconTile(frame, 42)
    tile:SetPoint("TOPLEFT", PAD, -42)
    frame.headIcon = tile.icon
    frame.headTitle = W.Text(frame, 15)
    frame.headTitle:SetPoint("TOPLEFT", tile, "TOPRIGHT", 12, -2)

    local bar = W.Panel(frame, { 0.02, 0.03, 0.04, 1 })
    bar:SetSize(300, 16)
    bar:SetPoint("BOTTOMLEFT", tile, "BOTTOMRIGHT", 12, 0)
    frame.barFill = bar:CreateTexture(nil, "ARTWORK")
    frame.barFill:SetPoint("TOPLEFT", 1, -1)
    frame.barFill:SetPoint("BOTTOMLEFT", 1, 1)
    frame.barFill:SetColorTexture(0.18, 0.48, 0.29, 1)
    frame.barText = W.Text(bar, 11, Theme.text, "CENTER")
    frame.barText:SetPoint("CENTER")

    local line = W.Line(frame)
    line:SetPoint("TOPLEFT", PAD, -94)
    line:SetPoint("TOPRIGHT", -PAD, -94)
end

local function buildFilters()
    frame.search = W.SearchBox(frame, 520, "Search recipes, reagents or members", function(text)
        state.query, state.offset = text, 0
        Window.Refresh()
    end)
    frame.search:SetPoint("TOPLEFT", PAD, -102)
    local online = W.Toggle(frame, "Online only", function() return state.onlineOnly end, function(v)
        state.onlineOnly, state.offset = v, 0
        Window.Refresh()
    end)
    online:SetWidth(120)
    online:SetPoint("LEFT", frame.search, "RIGHT", 14, 0)
end

local function buildList()
    local list = W.Panel(frame, { 0.04, 0.06, 0.08, 1 })
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
        row.selectedBg = row:CreateTexture(nil, "BACKGROUND")
        row.selectedBg:SetAllPoints()
        row.selectedBg:SetColorTexture(Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.16)
        row.sign = W.Text(row, 12, Theme.muted)
        row.sign:SetPoint("LEFT", 6, 0)
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
    local left = CreateFrame("Frame", nil, frame)
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
        slot:SetSize(204, 30)
        local col, rowIndex = (i - 1) % 2, math.floor((i - 1) / 2)
        slot:SetPoint("TOPLEFT", label, "BOTTOMLEFT", col * 212, -6 - rowIndex * 34)
        slot.tile = iconTile(slot, 30)
        slot.tile:SetPoint("LEFT")
        slot.count = W.Text(slot.tile, 10, Theme.text, "RIGHT")
        W.SetFont(slot.count, 10, "OUTLINE")
        slot.count:SetPoint("BOTTOMRIGHT", -1, 2)
        slot.name = W.Text(slot, 11)
        slot.name:SetPoint("LEFT", slot.tile, "RIGHT", 8, 0)
        slot.name:SetPoint("RIGHT", -4, 0)
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

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(Theme.hairline))
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
    divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 12, 0)

    local right = CreateFrame("Frame", nil, frame)
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
        row.whisper = W.Button(row, "Whisper", 66, 20, function(self)
            whisper(self.target, state.selected and recipeLink(state.selected))
        end)
        row.whisper:SetPoint("RIGHT")
        frame.crafters[i] = row
    end
end

local function buildFooter()
    local line = W.Line(frame, Theme.border)
    line:SetPoint("BOTTOMLEFT", 0, 26)
    line:SetPoint("BOTTOMRIGHT", 0, 26)
    frame.footer = W.Text(frame, 11, Theme.muted)
    frame.footer:SetPoint("BOTTOMLEFT", 12, 8)
    local hint = W.Text(frame, 11, Theme.muted, "RIGHT")
    hint:SetPoint("BOTTOMRIGHT", -12, 8)
    hint:SetText("Shift-click a recipe to link it in chat")
end

local function buildModes()
    local soon = function(tooltip)
        tooltip:AddLine("Coming soon", 1, 1, 1)
    end
    local mine = W.Button(frame, "My listings", 84, 20, function() end)
    mine:SetPoint("TOPRIGHT", -34, -5)
    mine:SetDisabled(true)
    W.Tooltip(mine, soon)
    local public = W.Button(frame, "Public", 60, 20, function() end)
    public:SetPoint("RIGHT", mine, "LEFT", -4, 0)
    public:SetDisabled(true)
    W.Tooltip(public, soon)
    local guild = W.Button(frame, "Guild", 56, 20, function() end)
    guild:SetPoint("RIGHT", public, "LEFT", -4, 0)
    guild:SetSelected(true)
end

local function buildTabs()
    frame.tabs = {}
    for i = 1, MAX_TABS do
        local tab = W.IconButton(frame, TAB_SIZE, nil, "?", function(self)
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

local function drawTabs()
    local list = Data.ProfessionList(model.professions)
    local entries = { { prof = "all", label = "All professions", texture = ns.ICON } }
    for _, p in ipairs(list) do
        entries[#entries + 1] = { prof = p.id, label = p.name, texture = professionTexture(p.id) }
    end
    if state.prof ~= "all" and not model.professions[state.prof] then
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
        local p = model.professions[state.prof]
        for _, c in pairs(p.crafters) do
            crafters[#crafters + 1] = c
        end
        frame.headTitle:SetText(p.name)
        frame.headIcon:SetTexture(professionTexture(p.id) or ns.ICON)
    end
    for _, c in ipairs(crafters) do
        total = total + 1
        if c.state ~= "offline" then
            onlineNow = onlineNow + 1
        end
    end
    frame.barFill:SetShown(onlineNow > 0)
    frame.barFill:SetWidth(math.max(1, 298 * (total > 0 and onlineNow / total or 0)))
    frame.barText:SetText(string.format("%d of %s online", onlineNow, ns.Plural(total, "crafter")))
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
            row.sign:SetText(item.collapsed and "+" or "-")
            row.label:SetPoint("LEFT", 22, 0)
            row.label:SetText(item.label)
            row.label:SetTextColor(unpack(Theme.text))
            row.count:SetText(item.count)
            row.dot:Hide()
            row.selectedBg:Hide()
        elseif item then
            local meta = ns.Scanner.Meta(item.recipe.id) or {}
            local quality = meta.item and itemQuality(meta.item)
            row.sign:SetText("")
            row.label:SetPoint("LEFT", 30, 0)
            row.label:SetText(Theme.QualityHex(quality or 1) .. item.name .. "|r")
            row.count:SetText(Data.CrafterText(item))
            row.dot:SetShown(item.online > 0)
            row.selectedBg:SetShown(item.recipe.id == state.selected)
        end
    end
    local count = model.count or 0
    if next(model.recipes) == nil then
        frame.empty:SetText("Nothing here yet. Open your profession windows once to scan them; guildmates who run Marketplace show up as they log in.")
    elseif count == 0 then
        frame.empty:SetText("No recipe matches.")
    else
        frame.empty:SetText("")
    end
end

local function drawReagents(meta)
    local reagents = meta and meta.reagents or {}
    for i, slot in ipairs(frame.reagents) do
        local r = reagents[i]
        slot:SetShown(r ~= nil)
        if r then
            local id, need = r[1], r[2]
            local have = itemCount(id)
            slot.itemID = id
            slot.tile.icon:SetTexture(itemIcon(id))
            slot.count:SetText(have .. "/" .. need)
            slot.count:SetTextColor(unpack(have >= need and Theme.text or Theme.bad))
            slot.name:SetText(itemName(id) or "…")
        end
    end
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
    state.crafterOffset = math.max(0, math.min(state.crafterOffset, math.max(0, #list - CRAFTER_ROWS)))
    for i, row in ipairs(frame.crafters) do
        local c = list[state.crafterOffset + i]
        row:SetShown(c ~= nil)
        if c then
            local onlineState = c.state ~= "offline"
            row.dot:SetColorTexture(unpack(onlineState and Theme.online or Theme.offline))
            row.dot:SetAlpha(c.state == "noaddon" and 0.45 or 1)
            row.name:SetText(c.name)
            row.name:SetTextColor(unpack(onlineState and classColor(c.class) or Theme.muted))
            row.status:SetText(Data.StatusText(c, time()))
            row.whisper.target = c.name
            row.whisper:SetShown(c.state == "addon" or c.state == "noaddon")
        end
    end
    frame.crafterMore:SetText(#list > CRAFTER_ROWS and string.format("%d of %d  (scroll)", math.min(#list, state.crafterOffset + CRAFTER_ROWS), #list) or "")
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

function Window.Refresh()
    if not frame or not frame:IsShown() then
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
