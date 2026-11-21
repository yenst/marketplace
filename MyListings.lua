local _, ns = ...

local Theme, W, Listings = ns.Theme, ns.W, ns.Listings

-- "My listings": pick which of this character's professions and recipes to
-- list publicly, and on what terms. Lives inside the main window and
-- replaces the browser while that mode is selected.
local MyListings = {}
ns.MyListings = MyListings

local PAD = 14
local LEFT_WIDTH = 220
local PROF_HEIGHT, PROF_ROWS = 44, 10
local ROW_HEIGHT, ROWS = 20, 15
local RECIPES_TOP = 214

local panel
local state = { prof = nil, selected = nil, offset = 0, query = "" }
local rows = {} -- the recipe list as drawn: { id, name, quality }

local function itemQuality(id)
    if C_Item and C_Item.GetItemQualityByID then
        return C_Item.GetItemQualityByID(id)
    end
    return GetItemInfo and select(3, GetItemInfo(id))
end

local function professions()
    local list = {}
    for id, p in pairs(ns.char and ns.char.professions or {}) do
        if next(p.recipes or {}) then
            list[#list + 1] = p
        end
    end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

local function current()
    local p = state.prof and ns.char and ns.char.professions and ns.char.professions[state.prof]
    return p, p and Listings.Get(ns.char, p.id)
end

local function changed()
    ns.Public.QueueAnnounce()
    MyListings.Draw()
end

-- Mats / fee / price / tips controls, bound to one terms table at a time.
local MATS_OPTIONS = {
    { key = "bring", label = "Buyer brings mats" },
    { key = "provide", label = "I provide mats" },
    { key = "either", label = "Either" },
}

local function termsEditor(parent)
    local editor = CreateFrame("Frame", nil, parent)
    editor:SetSize(500, 60)
    local target

    local matsLabel = W.Text(editor, 11, Theme.muted)
    matsLabel:SetPoint("TOPLEFT")
    matsLabel:SetText("Materials")
    editor.mats = W.Segmented(editor, MATS_OPTIONS, 118, function(key)
        if target then
            target.mats = key
            editor.mats:SetValue(key)
            editor:Sync()
            changed()
        end
    end)
    editor.mats:SetPoint("TOPLEFT", matsLabel, "BOTTOMLEFT", 0, -5)

    local feeLabel = W.Text(editor, 11, Theme.muted)
    feeLabel:SetPoint("TOPLEFT", 0, -50)
    feeLabel:SetText("Fee, buyer's mats")
    editor.fee = W.MoneyBox(editor, nil, function(value)
        if target then
            target.fee = value or 0
            changed()
        end
    end)
    editor.fee:SetPoint("TOPLEFT", feeLabel, "BOTTOMLEFT", 0, -5)

    local priceLabel = W.Text(editor, 11, Theme.muted)
    priceLabel:SetPoint("TOPLEFT", 140, -50)
    priceLabel:SetText("Price, my mats")
    editor.price = W.MoneyBox(editor, "mats + fee", function(value)
        if target then
            target.price = value
            changed()
        end
    end)
    editor.price:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -5)
    W.Tooltip(editor.price, function(tooltip)
        tooltip:AddLine("Price with your materials", 1, 1, 1)
        tooltip:AddLine("Leave it empty to charge what the mats cost plus your fee. Buyers with Auctionator see an estimate.", 0.7, 0.7, 0.7, true)
    end)

    editor.tips = W.Toggle(editor, "Tips instead of a fee", function() return target and target.tips or false end, function(v)
        if target then
            target.tips = v
            editor:Sync()
            changed()
        end
    end)
    editor.tips:SetWidth(170)
    editor.tips:SetPoint("TOPLEFT", 280, -70)

    -- Greys out what the chosen terms don't use.
    function editor:Sync()
        local mats = target and target.mats or "bring"
        local on = self.enabled ~= false and target ~= nil
        self.mats:SetEnabled(on)
        self.fee:SetEnabled(on and not (target and target.tips))
        self.price:SetEnabled(on and mats ~= "bring")
        self.tips:SetAlpha(on and 1 or 0.4)
        self.tips:EnableMouse(on)
    end

    function editor:Bind(terms)
        target = terms
        self.mats:SetValue(terms and terms.mats or "bring")
        self.fee:SetValue(terms and terms.fee or 0)
        self.price:SetValue(terms and terms.price)
        self.tips:Update()
        self:Sync()
    end

    function editor:SetEnabled(on)
        self.enabled = on
        self:Sync()
    end
    return editor
end

-- Layout ----------------------------------------------------------------------

local function buildLeft()
    local left = CreateFrame("Frame", nil, panel)
    left:SetPoint("TOPLEFT", 0, -31)
    left:SetPoint("BOTTOMLEFT", 0, 27)
    left:SetWidth(LEFT_WIDTH)
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(Theme.border))
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT")
    divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT")

    local title = W.Text(left, 11, Theme.muted)
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Your professions")

    panel.profs = {}
    for i = 1, PROF_ROWS do
        local row = CreateFrame("Button", nil, left)
        row:SetHeight(PROF_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -30 - (i - 1) * PROF_HEIGHT)
        row:SetPoint("TOPRIGHT", 0, -30 - (i - 1) * PROF_HEIGHT)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.14)
        row.hover = row:CreateTexture(nil, "BACKGROUND")
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 1, 1, 0.04)
        row.hover:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(26, 26)
        row.icon:SetPoint("LEFT", 12, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = W.Text(row, 12)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
        row.sub = W.Text(row, 11, Theme.muted)
        row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
        row.badge = W.Text(row, 10, Theme.muted, "RIGHT")
        row.badge:SetPoint("RIGHT", -12, 0)
        row:SetScript("OnEnter", function(self) self.hover:Show() end)
        row:SetScript("OnLeave", function(self) self.hover:Hide() end)
        row:SetScript("OnClick", function(self)
            state.prof, state.selected, state.offset = self.prof, nil, 0
            MyListings.Refresh()
        end)
        panel.profs[i] = row
    end

    local note = W.Text(left, 11, Theme.muted)
    note:SetPoint("BOTTOMLEFT", 12, 10)
    note:SetPoint("BOTTOMRIGHT", -12, 10)
    note:SetWordWrap(true)
    note:SetJustifyV("BOTTOM")
    note:SetText("Your guild always sees all your recipes. Public listings are only what you switch on here, and are shared while this character is online.")
end

local function buildSettings()
    local x = LEFT_WIDTH + 1 + PAD
    panel.profTitle = W.Text(panel, 15)
    panel.profTitle:SetPoint("TOPLEFT", x, -44)
    panel.listToggle = W.Toggle(panel, "List publicly", function()
        local _, l = current()
        return l and l.on or false
    end, function(v)
        local _, l = current()
        if l then
            l.on = v
            changed()
        end
    end)
    panel.listToggle:SetWidth(120)
    panel.listToggle:SetPoint("TOPRIGHT", -PAD, -42)

    panel.defaults = termsEditor(panel)
    panel.defaults:SetPoint("TOPLEFT", x, -72)
    panel.defaults:SetPoint("RIGHT", -PAD, 0)

    local line = W.Line(panel)
    line:SetPoint("TOPLEFT", x - PAD, -172)
    line:SetPoint("TOPRIGHT", 0, -172)
end

local function buildRecipes()
    local x = LEFT_WIDTH + 1 + PAD
    panel.recipeTitle = W.Text(panel, 11, Theme.muted)
    panel.recipeTitle:SetPoint("TOPLEFT", x, -188)
    panel.search = W.SearchBox(panel, 180, "Filter recipes", function(text)
        state.query, state.offset = text:lower(), 0
        MyListings.Draw()
    end)
    panel.search:SetPoint("TOPRIGHT", -PAD, -182)

    local list = W.Panel(panel, { 0.04, 0.06, 0.08, 1 })
    list:SetPoint("TOPLEFT", x, -RECIPES_TOP)
    list:SetPoint("TOPRIGHT", -PAD, -RECIPES_TOP)
    list:SetHeight(ROWS * ROW_HEIGHT + 6)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, math.min(math.max(0, #rows - ROWS), state.offset - delta * 3))
        MyListings.Draw()
    end)
    panel.empty = W.Text(list, 12, Theme.muted, "CENTER")
    panel.empty:SetPoint("CENTER")

    local head = W.Text(panel, 10, Theme.muted, "RIGHT")
    head:SetPoint("BOTTOMRIGHT", list, "TOPRIGHT", -8, 3)

    panel.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 3, -3 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -3, -3 - (i - 1) * ROW_HEIGHT)
        row.selectedBg = row:CreateTexture(nil, "BACKGROUND")
        row.selectedBg:SetAllPoints()
        row.selectedBg:SetColorTexture(Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.16)
        row.hover = row:CreateTexture(nil, "BACKGROUND")
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 1, 1, 0.04)
        row.hover:Hide()

        -- Listed checkbox
        row.check = CreateFrame("Button", nil, row, "BackdropTemplate")
        row.check:SetSize(14, 14)
        row.check:SetPoint("LEFT", 6, 0)
        W.Skin(row.check, Theme.bgRaised)
        row.check.row = row
        row.check.mark = row.check:CreateTexture(nil, "OVERLAY")
        row.check.mark:SetPoint("TOPLEFT", 3, -3)
        row.check.mark:SetPoint("BOTTOMRIGHT", -3, 3)
        row.check.mark:SetColorTexture(unpack(Theme.accent))
        row.check:SetScript("OnClick", function(self)
            local _, l = current()
            local id = self.row.id
            if l and id then
                if l.recipes[id] == false then
                    l.recipes[id] = nil
                else
                    l.recipes[id] = false
                end
                changed()
                MyListings.BindOverride()
            end
        end)

        row.name = W.Text(row, 12)
        row.name:SetPoint("LEFT", 28, 0)
        row.name:SetPoint("RIGHT", -270, 0)
        row.custom = W.Text(row, 10, Theme.accent, "RIGHT")
        row.custom:SetPoint("RIGHT", -214, 0)
        row.custom:SetText("own terms")
        row.terms = W.Text(row, 11, Theme.muted, "RIGHT")
        row.terms:SetPoint("RIGHT", -8, 0)
        row.terms:SetWidth(200)
        row:SetScript("OnEnter", function(self)
            self.hover:Show()
            local T = C_TradeSkillUI
            local link = self.id and T and T.GetRecipeLink and T.GetRecipeLink(self.id)
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
            state.selected = self.id
            MyListings.Draw()
            MyListings.BindOverride()
        end)
        panel.rows[i] = row
    end
end

local function buildOverride()
    local x = LEFT_WIDTH + 1 + PAD
    local top = RECIPES_TOP + ROWS * ROW_HEIGHT + 6 + 12
    panel.ovTitle = W.Text(panel, 12)
    panel.ovTitle:SetPoint("TOPLEFT", x, -top)
    panel.ovTitle:SetPoint("RIGHT", -170, 0)
    panel.ovToggle = W.Toggle(panel, "Own terms for this recipe", function()
        local _, l = current()
        return Listings.IsCustom(l, state.selected)
    end, function(v)
        local _, l = current()
        if not (l and state.selected) then
            return
        end
        if v then
            local base = Listings.Terms(l, state.selected) or { mats = l.mats, fee = l.fee, price = l.price, tips = l.tips }
            l.recipes[state.selected] = { mats = base.mats, fee = base.fee, price = base.price, tips = base.tips }
        else
            l.recipes[state.selected] = nil
        end
        MyListings.BindOverride()
        changed()
    end)
    panel.ovToggle:SetWidth(190)
    panel.ovToggle:SetPoint("TOPRIGHT", -PAD, -top + 2)
    panel.override = termsEditor(panel)
    panel.override:SetPoint("TOPLEFT", x, -top - 24)
    panel.override:SetPoint("RIGHT", -PAD, 0)
end

local function buildFooter()
    local line = W.Line(panel, Theme.border)
    line:SetPoint("BOTTOMLEFT", 0, 26)
    line:SetPoint("BOTTOMRIGHT", 0, 26)
    panel.footer = W.Text(panel, 11, Theme.muted)
    panel.footer:SetPoint("BOTTOMLEFT", 12, 8)
    panel.footer:SetPoint("RIGHT", -12, 0)
end

local function build(window)
    panel = CreateFrame("Frame", nil, window)
    panel:SetAllPoints()
    MyListings.panel = panel
    buildLeft()
    buildSettings()
    buildRecipes()
    buildOverride()
    buildFooter()
    panel:Hide()
end

-- Drawing ---------------------------------------------------------------------

local function professionTexture(id)
    local T = C_TradeSkillUI
    return T and T.GetTradeSkillTexture and T.GetTradeSkillTexture(id)
end

local function drawProfessions(list)
    for i, row in ipairs(panel.profs) do
        local p = list[i]
        row:SetShown(p ~= nil)
        if p then
            local l = Listings.Get(ns.char, p.id)
            local listed = Listings.Counts(l, p)
            row.prof = p.id
            row.icon:SetTexture(professionTexture(p.id) or ns.ICON)
            row.name:SetText(p.name or "?")
            row.sub:SetText(string.format("%d · %s", p.skill or 0, ns.Plural(ns.Scanner.Count(p), "recipe")))
            row.bg:SetShown(p.id == state.prof)
            if l.on and listed > 0 then
                row.badge:SetText("Public")
                row.badge:SetTextColor(unpack(Theme.online))
            else
                row.badge:SetText("Guild only")
                row.badge:SetTextColor(unpack(Theme.muted))
            end
        end
    end
end

local function collectRows(p)
    wipe(rows)
    for id in pairs(p.recipes or {}) do
        local meta = ns.Scanner.Meta(id) or {}
        local name = meta.name or ("Recipe " .. id)
        if state.query == "" or name:lower():find(state.query, 1, true) then
            rows[#rows + 1] = { id = id, name = name, quality = meta.item and itemQuality(meta.item) }
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
end

local function drawRecipes(p, l)
    collectRows(p)
    state.offset = math.max(0, math.min(state.offset, math.max(0, #rows - ROWS)))
    local listed, custom, total = Listings.Counts(l, p)
    local parts = { string.format("Recipes · %d of %d listed", listed, total) }
    if custom > 0 then
        parts[#parts + 1] = custom .. " with own terms"
    end
    panel.recipeTitle:SetText(table.concat(parts, " · "))
    for i, row in ipairs(panel.rows) do
        local r = rows[state.offset + i]
        row:SetShown(r ~= nil)
        if r then
            row.id = r.id
            local own = l.recipes[r.id]
            local isListed = own ~= false
            row.check.mark:SetShown(isListed)
            row.name:SetText((isListed and Theme.QualityHex(r.quality or 1) or Theme.Hex(Theme.muted)) .. r.name .. "|r")
            row.custom:SetShown(type(own) == "table")
            local terms = isListed and (type(own) == "table" and own or { mats = l.mats, fee = l.fee, price = l.price, tips = l.tips })
            row.terms:SetText(terms and (Listings.Summary(terms, ns.AH.Money) .. "  ·  " .. Listings.MATS_LABEL[terms.mats]) or "not listed")
            row.terms:SetTextColor(unpack(type(own) == "table" and Theme.text or Theme.muted))
            row.selectedBg:SetShown(r.id == state.selected)
        end
    end
    panel.empty:SetText(#rows == 0 and "No recipe matches." or "")
end

-- Points the lower editor at the selected recipe's own terms.
function MyListings.BindOverride()
    if not panel then
        return
    end
    local _, l = current()
    local id = state.selected
    local own = l and id and l.recipes[id]
    local meta = id and ns.Scanner.Meta(id)
    panel.ovTitle:SetText(id and (meta and meta.name or ("Recipe " .. id)) or Theme.Hex(Theme.muted) .. "Select a recipe to give it its own terms or unlist it|r")
    panel.ovToggle:SetShown(id ~= nil and own ~= false)
    panel.ovToggle:Update()
    panel.override:SetShown(type(own) == "table")
    panel.override:Bind(type(own) == "table" and own or nil)
end

local function drawFooter()
    local parts = {}
    for _, p in pairs(ns.Public.Mine()) do
        local n = 0
        for _ in pairs(p.recipes) do n = n + 1 end
        parts[#parts + 1] = string.format("%s (%d)", p.name or "?", n)
    end
    table.sort(parts)
    panel.footer:SetText(#parts > 0 and ("Listed publicly: " .. table.concat(parts, ", ") .. "  ·  shared automatically while you're online")
        or "Nothing listed publicly yet: pick a profession and switch on \"List publicly\".")
end

-- Redraws lists and labels without touching the edit boxes.
function MyListings.Draw()
    if not panel or not panel:IsShown() then
        return
    end
    local list = professions()
    drawProfessions(list)
    drawFooter()
    local p, l = current()
    local has = p ~= nil
    panel.profTitle:SetShown(has)
    panel.listToggle:SetShown(has)
    panel.defaults:SetShown(has)
    if not has then
        panel.empty:SetText("Open a profession window to scan it; then you can list its recipes here.")
        for _, row in ipairs(panel.rows) do
            row:Hide()
        end
        panel.recipeTitle:SetText("")
        return
    end
    panel.profTitle:SetText(p.name or "?")
    panel.listToggle:Update()
    panel.defaults:SetEnabled(l.on)
    drawRecipes(p, l)
end

-- Full redraw: also rebinds the editors (call when the selection changes).
function MyListings.Refresh()
    if not panel or not panel:IsShown() then
        return
    end
    local list = professions()
    local valid = false
    for _, p in ipairs(list) do
        if p.id == state.prof then
            valid = true
        end
    end
    if not valid then
        state.prof, state.selected = list[1] and list[1].id or nil, nil
    end
    local p = current()
    if state.selected and not (p and p.recipes[state.selected]) then
        state.selected = nil
    end
    local _, l = current()
    panel.defaults:Bind(l)
    MyListings.Draw()
    MyListings.BindOverride()
end

function MyListings.Show(window, show)
    if not panel then
        if not show then
            return
        end
        build(window)
    end
    panel:SetShown(show)
    if show then
        MyListings.Refresh()
    end
end
