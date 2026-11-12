-- Hitlist: the tab and page inside the Social window (SocialUIFrame).
--
-- Blizzard builds its own side tabs from a private table and rebuilds them
-- often, so Hitlist does not register itself there. It adds one extra tab
-- button under Blizzard's and one page over the content area, and only ever
-- reads Blizzard's state or calls plain widget methods on its frames. That
-- keeps addon taint out of the Social window.
local ADDON, ns = ...
local H = ns.H

local S = {}
ns.S = S

local TITLE = "Hitlist"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local PAGE_LEVEL = 200 -- frame levels above the window, so the page sits over Blizzard's
local CARD_PAD = 9
local LINE_GAP = 4
local EMPTY_TEXT = "Your hitlist is empty.\n\nTarget a player and click Add to Hitlist,\nor type  /hit add Name"
local NO_MATCH_TEXT = "Nobody on your hitlist matches that search."

local root, tab, page, view
local setup = "waiting"    -- "waiting" for the Social window, then "ready" or "failed"
local active = false       -- the Hitlist page is the one showing
local reopen = false       -- show the Hitlist page again next time the window opens
local openRequested = false
local clearedAt            -- GetTime() of Blizzard's last "no tab selected" while active
local rowHeight = 62

local function FontObject(preferred, fallback)
	return _G[preferred] and preferred or fallback
end

local function IsInside(frame, ancestor)
	for _ = 1, 20 do
		if frame == ancestor then
			return true
		end
		if not frame or not frame.GetParent then
			return false
		end
		frame = frame:GetParent()
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

local function ShowCardTooltip(card)
	local entry = H:GetByKey(card.hitlistKey)
	if not entry then
		return
	end
	GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
	GameTooltip:SetText(H:ColorName(entry))
	local description = H:Describe(entry, true)
	if description then
		GameTooltip:AddLine(description, 1, 1, 1)
	end
	if entry.guild then
		GameTooltip:AddLine("<" .. entry.guild .. ">", 0.7, 0.7, 0.7)
	end
	if entry.note then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(entry.note, 1, 0.82, 0, true)
	end
	GameTooltip:AddLine(" ")
	local added = "Added " .. H.Date(entry.added, true)
	if entry.addedZone then
		added = added .. " in " .. entry.addedZone
	end
	GameTooltip:AddLine(added, 0.6, 0.6, 0.6, true)
	if entry.seen then
		local seen = "Last seen " .. H.Ago(entry.seen)
		if entry.seenZone then
			seen = seen .. " in " .. entry.seenZone
		end
		GameTooltip:AddLine(seen, 0.6, 0.6, 0.6, true)
	else
		GameTooltip:AddLine("Not seen since you added them", 0.6, 0.6, 0.6, true)
	end
	GameTooltip:AddLine("Click for options", 0.1, 1, 0.1)
	GameTooltip:Show()
end

local function OpenCardMenu(card)
	local key = card.hitlistKey
	local entry = H:GetByKey(key)
	if not entry then
		return
	end
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		H:PromptNote(key)
		return
	end
	MenuUtil.CreateContextMenu(card, function(_, menu)
		menu:CreateTitle(entry.name)
		menu:CreateButton(entry.note and "Edit Note" or "Add Note", function()
			H:PromptNote(key)
		end)
		menu:CreateButton("Remove from Hitlist", function()
			H:PromptRemove(key)
		end)
	end)
end

local function BuildCard(card)
	card.hitlistBuilt = true
	card:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local background = card:CreateTexture(nil, "BACKGROUND")
	background:SetAtlas("friends-card-default")
	background:SetAllPoints()

	local highlight = card:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAtlas("friends-card-selected")
	highlight:SetBlendMode("ADD")
	highlight:SetAllPoints()

	local skull = card:CreateTexture(nil, "ARTWORK")
	skull:SetTexture(SKULL)
	skull:SetSize(22, 22)
	skull:SetPoint("RIGHT", card, "RIGHT", -12, 0)
	skull:SetAlpha(0.6)

	local name = card:CreateFontString(nil, "ARTWORK", FontObject("UserScaledFontHeader", "GameFontHighlightLarge"))
	name:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -CARD_PAD)
	name:SetPoint("TOPRIGHT", card, "TOPRIGHT", -44, -CARD_PAD)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	card.Name = name

	local info = card:CreateFontString(nil, "ARTWORK", FontObject("UserScaledFontBody", "GameFontHighlight"))
	info:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 1, -LINE_GAP)
	info:SetPoint("TOPRIGHT", name, "BOTTOMRIGHT", 0, -LINE_GAP)
	info:SetJustifyH("LEFT")
	info:SetWordWrap(false)
	card.Info = info

	local note = card:CreateFontString(nil, "ARTWORK", FontObject("UserScaledFontBody", "GameFontHighlight"))
	note:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -LINE_GAP)
	note:SetPoint("TOPRIGHT", info, "BOTTOMRIGHT", 0, -LINE_GAP)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(false)
	card.Note = note

	card:SetScript("OnClick", OpenCardMenu)
	card:SetScript("OnEnter", ShowCardTooltip)
	card:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function UpdateCard(card, elementData)
	if not card.hitlistBuilt then
		BuildCard(card)
	end
	card.hitlistKey = elementData.key
	card:SetHeight(rowHeight)

	local entry = H:GetByKey(elementData.key)
	if not entry then
		card.Name:SetText("")
		card.Info:SetText("")
		card.Note:SetText("")
		return
	end

	card.Name:SetText(H:ColorName(entry))

	local description = H:Describe(entry, true)
	if description and entry.guild then
		description = description .. "  |cffb0b0b0<" .. entry.guild .. ">|r"
	end
	card.Info:SetText(description or "|cff808080Not seen yet|r")

	if entry.note then
		card.Note:SetText("|cffffd100" .. entry.note .. "|r")
	else
		local added = "Added " .. H.Date(entry.added)
		if entry.addedZone then
			added = added .. " in " .. entry.addedZone
		end
		card.Note:SetText("|cff808080" .. added .. "|r")
	end
end

-- The Social window's fonts follow the game's text size setting, so the card
-- height is measured rather than fixed.
local function MeasureRowHeight()
	local header = page.MeasureHeader:GetLineHeight() or 0
	local body = page.MeasureBody:GetLineHeight() or 0
	if header <= 0 then
		header = 16
	end
	if body <= 0 then
		body = 12
	end
	return math.floor(CARD_PAD * 2 + header + 2 * (LINE_GAP + body) + 0.5)
end

-- ---------------------------------------------------------------------------
-- Page and tab
-- ---------------------------------------------------------------------------

function S:Refresh()
	if setup ~= "ready" then
		return
	end
	tab:RefreshCounter()
	if not page:IsShown() then
		return
	end

	local height = MeasureRowHeight()
	if height ~= rowHeight then
		rowHeight = height
		view:SetElementExtent(height)
	end

	local keys = H:Sorted(strtrim(page.FilterBar.SearchBar:GetText() or ""))
	local provider = CreateDataProvider()
	for _, key in ipairs(keys) do
		provider:Insert({ key = key })
	end
	page.ScrollBox:SetDataProvider(provider, ScrollBoxConstants.RetainScrollPosition)

	local empty = #keys == 0
	page.ScrollBox:SetShown(not empty)
	page.ScrollBar:SetShown(not empty)
	page.EmptyText:SetShown(empty)
	if empty then
		page.EmptyText:SetText(H:Count() == 0 and EMPTY_TEXT or NO_MATCH_TEXT)
	end
end

local function BuildPage()
	-- The same template Blizzard's Friends page uses: search bar, list, red button.
	page = CreateFrame("Frame", "HitlistSocialPage", root, "SocialUIContactsFrameTemplate")
	page:SetPoint("TOPLEFT", root.BattleNetBar, "BOTTOMLEFT", 0, 5)
	page:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -2, 2)
	page:SetFrameLevel(root:GetFrameLevel() + PAGE_LEVEL)
	-- Blizzard's own page stays underneath (invisible); swallow the mouse so it
	-- cannot be clicked through gaps in this one.
	page:EnableMouse(true)
	page:EnableMouseWheel(true)
	page:SetScript("OnMouseWheel", function() end)
	page:Hide()

	local bar = page.FilterBar
	bar.SearchFilterDropdown:Hide()
	bar.SearchBar:ClearAllPoints()
	bar.SearchBar:SetPoint("LEFT", bar, "LEFT", 15, 0)
	bar.SearchBar:SetPoint("RIGHT", bar, "RIGHT", -15, 0)
	if bar.SearchBar.Instructions then
		bar.SearchBar.Instructions:SetText("Search your hitlist")
	end
	bar.SearchBar.OnSearchTextChanged = function()
		S:Refresh()
	end

	page.ActionButton:SetText("Add to Hitlist")
	page.ActionButton.PerformClickAction = function()
		H:PromptAdd()
	end

	page.EmptyText = page.FriendsDisabledText

	page.MeasureHeader = page:CreateFontString(nil, "ARTWORK", FontObject("UserScaledFontHeader", "GameFontHighlightLarge"))
	page.MeasureHeader:Hide()
	page.MeasureBody = page:CreateFontString(nil, "ARTWORK", FontObject("UserScaledFontBody", "GameFontHighlight"))
	page.MeasureBody:Hide()

	view = CreateScrollBoxListLinearView(10, 10, 10, 7, 3)
	rowHeight = MeasureRowHeight()
	view:SetElementExtent(rowHeight)
	view:SetElementInitializer("Button", UpdateCard)
	ScrollUtil.InitScrollBoxListWithScrollBar(page.ScrollBox, page.ScrollBar, view)
end

local function PaintTab(checked)
	tab:SetChecked(checked)
	if checked then
		tab.Icon:SetVertexColor(1, 0.82, 0)
	else
		tab.Icon:SetVertexColor(0.72, 0.6, 0.38)
	end
end

local function BuildTab()
	-- The same template Blizzard's side tabs use, so it matches them.
	tab = CreateFrame("Button", "HitlistSocialTab", root, "SocialUITabTemplate")
	tab:Initialize({
		tabName = TITLE,
		countGenerator = function()
			return H:Count()
		end,
	})
	tab.Icon:SetTexture(SKULL)
	tab.Icon:SetSize(24, 24)
	tab:SetScript("OnClick", function()
		S:Activate()
	end)
	PaintTab(false)
end

-- Blizzard releases and re-creates its tabs whenever the window opens or a
-- feature turns on or off, so the Hitlist tab is re-hung under the lowest one
-- each time.
function S:PlaceTab()
	local last, lastOrder
	for blizzardTab in root:EnumerateTabs() do
		local order = blizzardTab.tabData and blizzardTab.tabData.tabOrder or 0
		if blizzardTab:IsShown() and (not last or order > lastOrder) then
			last, lastOrder = blizzardTab, order
		end
	end
	tab:ClearAllPoints()
	if last then
		tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -3)
	else
		tab:SetPoint("TOPLEFT", root, "TOPRIGHT", 0, -122)
	end
	tab:Show()
end

-- ---------------------------------------------------------------------------
-- Switching between the Hitlist page and Blizzard's pages
-- ---------------------------------------------------------------------------

-- Blizzard's page is made invisible rather than hidden: hiding and re-showing
-- it from addon code would run its scripts as addon code.
local function SetBlizzardPagesInvisible(invisible)
	local definitions = root.tabDefinitions
	if type(definitions) ~= "table" then
		return
	end
	for _, definition in pairs(definitions) do
		local frame = definition.contentFrame
		if frame then
			frame:SetAlpha(invisible and 0 or 1)
		end
	end
end

function S:ApplyState()
	SetBlizzardPagesInvisible(active)

	local selected = root:GetSelectedTab()
	for blizzardTab in root:EnumerateTabs() do
		local tabType = blizzardTab.tabData and blizzardTab.tabData.tabType
		blizzardTab:SetChecked(not active and tabType ~= nil and tabType == selected)
	end
	PaintTab(active)

	if active then
		root:SetTitle(TITLE)
	else
		root:SetTitle(root:GetTitleForSelectedTab() or "")
	end
	page:SetShown(active)
end

function S:Activate()
	if setup ~= "ready" or not root:IsShown() then
		return
	end
	-- A search box on the page being covered would keep eating key presses.
	local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
	if focus and not (focus.IsForbidden and focus:IsForbidden()) and IsInside(focus, root) and not IsInside(focus, page) then
		focus:ClearFocus()
	end
	active = true
	reopen = true
	clearedAt = nil
	self:ApplyState()
	self:Refresh()
end

function S:Deactivate()
	if not active then
		return
	end
	active = false
	clearedAt = nil
	self:ApplyState()
end

-- Runs after every SocialUIFrame:SelectTab.
function S:OnBlizzardSelect(tabType)
	if not active then
		return
	end
	if tabType == nil then
		-- Blizzard cleared its selection: it is closing, or about to rebuild its tabs.
		clearedAt = GetTime()
		return
	end
	if clearedAt and clearedAt == GetTime() then
		-- A rebuild put Blizzard's previous tab back in the same frame. Nobody
		-- clicked anything, so the Hitlist page stays up.
		clearedAt = nil
		self:ApplyState()
		return
	end
	-- A Blizzard tab was chosen.
	reopen = false
	self:Deactivate()
end

function S:OnRootShow()
	self:PlaceTab()
	local wanted = openRequested or reopen
	openRequested = false
	if wanted then
		self:Activate()
	end
end

function S:OnRootHide()
	-- `reopen` is left alone so the window comes back on the Hitlist page.
	self:Deactivate()
end

-- Opens the Social window on the Hitlist page. Returns false if it cannot.
function S:Open()
	if setup ~= "ready" then
		return false
	end
	if root:IsShown() then
		self:Activate()
		return true
	end
	if not (ToggleSocialUI and SocialUIControl and SocialUIControl.IsEnabled()) then
		return false
	end
	openRequested = true
	ToggleSocialUI()
	if not root:IsShown() then
		openRequested = false
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local REQUIRED_METHODS = {
	"SelectTab", "RefreshTabs", "ClearAllTabs", "EnumerateTabs", "SetDeferredOpenTab",
	"GetSelectedTab", "GetTitleForSelectedTab", "SetTitle",
}

-- Attaches to the Social window once it exists. Safe to call repeatedly.
function S:TrySetup()
	if setup ~= "waiting" then
		return setup == "ready"
	end
	local frame = _G.SocialUIFrame
	if not frame then
		return false
	end

	local problem
	if not frame.BattleNetBar then
		problem = "SocialUIFrame.BattleNetBar is missing"
	end
	for _, method in ipairs(REQUIRED_METHODS) do
		if not problem and type(frame[method]) ~= "function" then
			problem = "SocialUIFrame:" .. method .. " is missing"
		end
	end

	if not problem then
		root = frame
		local ok, err = pcall(function()
			BuildPage()
			BuildTab()
		end)
		if not ok then
			problem = tostring(err)
		end
	end

	if problem then
		setup = "failed"
		self.failure = problem
		if tab then
			tab:Hide()
		end
		if page then
			page:Hide()
		end
		H.Print("couldn't add its tab to the Social window: " .. problem)
		H.Print("the list still works from chat. Type  /hit help")
		return false
	end

	setup = "ready"

	hooksecurefunc(root, "RefreshTabs", function()
		S:PlaceTab()
	end)
	hooksecurefunc(root, "ClearAllTabs", function()
		S:PlaceTab()
	end)
	hooksecurefunc(root, "SelectTab", function(_, tabType)
		S:OnBlizzardSelect(tabType)
	end)
	hooksecurefunc(root, "SetDeferredOpenTab", function(_, tabType)
		-- Something asked for a specific Blizzard tab; do not reopen on Hitlist.
		if tabType ~= nil then
			reopen = false
		end
	end)
	root:HookScript("OnShow", function()
		S:OnRootShow()
	end)
	root:HookScript("OnHide", function()
		S:OnRootHide()
	end)

	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("TextSizeManager.OnTextScaleUpdated", function()
			S:Refresh()
		end, S)
	end
	H:OnChange(function()
		S:Refresh()
	end)

	self:PlaceTab()
	if root:IsShown() and openRequested then
		openRequested = false
		self:Activate()
	end
	return true
end
