-- ShopHubUI: the Robux shop hub, opened from the SHOP button of the left sidebar
-- (StarterGui.LeftSidebar.Buttons.Shop). Built with the common window template (UIStyle.Window).
--
--   Tabs        Featured / Game Passes / Potions / Fertilizer / Hero Chest.
--               PC: a column on the left. Phone: a row on top that scrolls sideways.
--   Featured    the Exclusive Hero Chest card (the main call to action) + the top game passes.
--   Game Passes ShopCatalog.GamePasses; "OWNED" once the player has it (attribute Pass_<Id>).
--   Potions     every potion of PotionConfig in x1 / x3 / x10 packs (ShopCatalog.PotionBundles).
--   Fertilizer  FruitConfig.FertilizerProducts (same packs as the Devil Tree window).
--   Hero Chest  the Exclusive card: odds list (Roblox requires it for paid random items) and
--               Open x1 / x3 / x10.
--
-- Every price button prompts MarketplaceService directly; the server (RobuxShopService +
-- FruitService's ProcessReceipt) grants the item. Ids of 0 (ShopCatalog mock data) show "Soon".
-- Remotes.RobuxShopResult tells the window what a chest gave, for the reveal.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))
local PotionConfig = require(Shared:WaitForChild("PotionConfig"))
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local player = Players.LocalPlayer
local C = Theme.Color
local ROBUX = utf8.char(0xE002) -- the Robux icon glyph

local win = UIStyle.Window({
	Name = "ShopHubGui",
	Title = "SHOP",
	Size = Vector2.new(880, 560),
	PhoneSize = Vector2.new(640, 340),
	DisplayOrder = 12,
})
local phone = win.phone
local PAD = if phone then Theme.Space.S else Theme.Space.M
local TEXT = {
	Big = if phone then Theme.Text.Header else Theme.Text.Title,
	Name = if phone then Theme.Text.Body else Theme.Text.Header,
	Body = if phone then Theme.Text.Small else Theme.Text.Body,
	Small = Theme.Text.Small,
}

-- Small builders ----------------------------------------------------------------------------------------

local function corner(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: GuiObject, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = color
	s.Thickness = thickness
	s.Parent = inst
	return s
end

local function padding(inst: GuiObject, px: number)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.Parent = inst
end

local function card(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = C.SurfaceInset
	corner(f, Theme.Radius.Card)
	stroke(f, C.Stroke, 2)
	f.Parent = parent
	return f
end

local function label(parent: Instance, text: string, size: number, color: Color3?): TextLabel
	local l = UIStyle.Label(text, size, color)
	l.Parent = parent
	return l
end

-- A Robux price button. Not on sale (id 0) = grey "Soon" that can't be pressed.
local function priceButton(parent: Instance, caption: string?, robux: number, onSale: boolean, buy: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Buy"
	b.Font = Theme.Font
	b.TextColor3 = C.Text
	b.TextSize = TEXT.Body
	b.AutoButtonColor = onSale
	b.BackgroundColor3 = if onSale then C.Primary else C.Disabled
	local price = if onSale then ("%s %d"):format(ROBUX, robux) else "Soon"
	b.Text = if caption then caption .. "  " .. price else price
	local s = Instance.new("UIStroke")
	s.Color = C.Stroke
	s.Thickness = 1.5
	s.Parent = b
	stroke(b, if onSale then C.PrimaryDark else C.Stroke, 2)
	b.Parent = parent
	UIStyle.Button(b)
	if onSale then
		b.Activated:Connect(buy)
	end
	return b
end

local function promptProduct(id: number)
	if ShopCatalog.OnSale(id) then
		MarketplaceService:PromptProductPurchase(player, id)
	end
end

local function heroImage(name: string): string
	local def = HeroConfig.Get(name) :: any
	return if def and typeof(def.AnimeImage) == "string" then def.AnimeImage else ""
end

local function heroRarity(name: string): string
	local def = HeroConfig.Get(name) :: any
	return if def then def.Rarity else "Common"
end

-- A page = one scrolling list of a tab.
local function page(parent: Instance, name: string): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.Name = name
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = UDim2.fromScale(1, 1)
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	s.ScrollBarThickness = 6
	s.ScrollBarImageColor3 = C.TextDim
	s.Visible = false
	padding(s, PAD)
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, PAD)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = s
	s.Parent = parent
	return s
end

local function heading(parent: Instance, text: string, order: number)
	local l = label(parent, text, TEXT.Name, C.TextDim)
	l.LayoutOrder = order
	l.Size = UDim2.new(1, 0, 0, TEXT.Name + 6)
end

-- A grid of cards inside a page; `columns` cards per row of `height` px.
local function grid(parent: Instance, order: number, columns: number, height: number): Frame
	local g = Instance.new("Frame")
	g.Name = "Grid"
	g.BackgroundTransparency = 1
	g.LayoutOrder = order
	g.Size = UDim2.fromScale(1, 0)
	g.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIGridLayout")
	local gap = PAD
	layout.CellPadding = UDim2.fromOffset(gap, gap)
	layout.CellSize = UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, height)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = g
	g.Parent = parent
	return g
end

-- Layout: tabs + content ---------------------------------------------------------------------------------

local TAB_W = 170
local TAB_H = if phone then 40 else 52

local tabBar = Instance.new("ScrollingFrame")
tabBar.Name = "Tabs"
tabBar.BackgroundTransparency = 1
tabBar.BorderSizePixel = 0
tabBar.ScrollBarThickness = 0
tabBar.CanvasSize = UDim2.new()
local tabList = Instance.new("UIListLayout")
tabList.Padding = UDim.new(0, Theme.Space.S)
tabList.SortOrder = Enum.SortOrder.LayoutOrder
tabList.Parent = tabBar
local content = Instance.new("Frame")
content.Name = "Content"
content.BackgroundTransparency = 1
if phone then
	tabBar.Position = UDim2.fromOffset(PAD, 0)
	tabBar.Size = UDim2.new(1, -PAD * 2, 0, TAB_H + 4)
	tabBar.ScrollingDirection = Enum.ScrollingDirection.X
	tabBar.AutomaticCanvasSize = Enum.AutomaticSize.X
	tabList.FillDirection = Enum.FillDirection.Horizontal
	content.Position = UDim2.fromOffset(0, TAB_H + 4)
	content.Size = UDim2.new(1, 0, 1, -(TAB_H + 4))
else
	tabBar.Position = UDim2.fromOffset(PAD, 0)
	tabBar.Size = UDim2.new(0, TAB_W, 1, -PAD)
	tabBar.ScrollingDirection = Enum.ScrollingDirection.Y
	tabBar.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.Position = UDim2.fromOffset(TAB_W + PAD, 0)
	content.Size = UDim2.new(1, -(TAB_W + PAD), 1, 0)
end
tabBar.Parent = win.body
content.Parent = win.body

type Tab = { id: string, button: TextButton, page: ScrollingFrame }
local tabs: { Tab } = {}
local current: string? = nil

local function selectTab(id: string)
	current = id
	for _, t in tabs do
		local on = t.id == id
		t.page.Visible = on
		t.button.BackgroundColor3 = if on then C.Secondary else C.SurfaceInset
		t.button.TextColor3 = if on then C.Text else C.TextDim
	end
end

local function addTab(id: string, text: string): ScrollingFrame
	local b = Instance.new("TextButton")
	b.Name = id
	b.LayoutOrder = #tabs + 1
	b.Font = Theme.Font
	b.Text = text
	b.TextSize = TEXT.Body
	b.AutoButtonColor = true
	b.Size = if phone then UDim2.fromOffset(0, TAB_H) else UDim2.new(1, 0, 0, TAB_H)
	if phone then
		b.AutomaticSize = Enum.AutomaticSize.X
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, Theme.Space.L)
		p.PaddingRight = UDim.new(0, Theme.Space.L)
		p.Parent = b
	end
	local s = Instance.new("UIStroke")
	s.Color = C.Stroke
	s.Thickness = 1.5
	s.Parent = b
	b.Parent = tabBar
	UIStyle.Button(b)
	local pg = page(content, id)
	table.insert(tabs, { id = id, button = b, page = pg })
	b.Activated:Connect(function()
		selectTab(id)
	end)
	return pg
end

-- Shine sweep (Exclusive cards) --------------------------------------------------------------------------

local function shine(parent: GuiObject)
	local f = Instance.new("Frame")
	f.Name = "Shine"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0
	f.ZIndex = parent.ZIndex + 5
	f.Active = false
	corner(f, Theme.Radius.Card)
	local g = Instance.new("UIGradient")
	g.Rotation = 20
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.82),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = f
	f.Parent = parent
	task.spawn(function()
		while f.Parent do
			if win.IsOpen() then
				g.Offset = Vector2.new(-1, 0)
				local t = TweenService:Create(g, TweenInfo.new(1.1, Enum.EasingStyle.Quad), { Offset = Vector2.new(1, 0) })
				t:Play()
				t.Completed:Wait()
			end
			task.wait(2.2)
		end
	end)
end

-- Hero Chest card ----------------------------------------------------------------------------------------

local CHEST = ShopCatalog.HeroChest

local function chestCard(parent: Instance, order: number)
	local h = if phone then 250 else 330
	local f = card(parent, "ExclusiveChest")
	f.LayoutOrder = order
	f.Size = UDim2.new(1, 0, 0, h)
	f.ClipsDescendants = true
	stroke(f, C.Accent, 3)
	-- Left: title, text, Open buttons.
	local left = Instance.new("Frame")
	left.Name = "Left"
	left.BackgroundTransparency = 1
	left.Size = UDim2.fromScale(0.46, 1)
	padding(left, PAD)
	left.Parent = f
	local tag = Instance.new("TextLabel")
	tag.Name = "Tag"
	tag.BackgroundColor3 = C.Accent
	tag.Font = Theme.Font
	tag.Text = "EXCLUSIVE"
	tag.TextSize = TEXT.Small
	tag.TextColor3 = C.Stroke
	tag.Size = UDim2.fromOffset(96, 24)
	corner(tag, Theme.Radius.Chip)
	tag.Parent = left
	local title = label(left, CHEST.Name, TEXT.Big, C.Accent)
	title.Position = UDim2.fromOffset(0, 30)
	title.Size = UDim2.new(1, 0, 0, TEXT.Big * 2 + 6)
	title.TextYAlignment = Enum.TextYAlignment.Top
	local desc = label(left, CHEST.Desc, TEXT.Body, C.TextDim)
	desc.Position = UDim2.fromOffset(0, 30 + TEXT.Big * 2 + 10)
	desc.Size = UDim2.new(1, 0, 0, TEXT.Body + 4)
	-- Hero faces
	local faces = Instance.new("Frame")
	faces.Name = "Faces"
	faces.BackgroundTransparency = 1
	faces.Position = UDim2.fromOffset(0, 30 + TEXT.Big * 2 + TEXT.Body + 20)
	faces.Size = UDim2.new(1, 0, 0, if phone then 0 else 56)
	faces.Visible = not phone
	local fl = Instance.new("UIListLayout")
	fl.FillDirection = Enum.FillDirection.Horizontal
	fl.Padding = UDim.new(0, -10)
	fl.Parent = faces
	for i, e in CHEST.Pool do
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromOffset(56, 56)
		img.BackgroundColor3 = TreeConfig.RarityColors[heroRarity(e.Hero)] or C.Surface
		img.Image = heroImage(e.Hero)
		img.ZIndex = 10 - i
		corner(img, 28)
		stroke(img, C.Stroke, 2)
		img.Parent = faces
	end
	faces.Parent = left
	-- Open buttons: x1 big, x3 / x10 below.
	local buttons = Instance.new("Frame")
	buttons.Name = "Open"
	buttons.BackgroundTransparency = 1
	buttons.AnchorPoint = Vector2.new(0, 1)
	buttons.Position = UDim2.new(0, 0, 1, -4)
	buttons.Size = UDim2.new(1, 0, 0, Theme.TouchMin * 2 + PAD)
	buttons.Parent = left
	local function open(count: number, pos: UDim2, size: UDim2)
		local b = priceButton(buttons, ("Open x%d"):format(count), CHEST.Robux[count], ShopCatalog.OnSale(CHEST.ProductIds[count]), function()
			promptProduct(CHEST.ProductIds[count])
		end)
		b.Position = pos
		b.Size = size
	end
	open(1, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, Theme.TouchMin))
	open(3, UDim2.fromOffset(0, Theme.TouchMin + PAD), UDim2.new(0.5, -PAD / 2, 0, Theme.TouchMin))
	open(10, UDim2.new(0.5, PAD / 2, 0, Theme.TouchMin + PAD), UDim2.new(0.5, -PAD / 2, 0, Theme.TouchMin))
	-- Right: odds list.
	local right = Instance.new("Frame")
	right.Name = "Odds"
	right.BackgroundColor3 = C.Surface
	right.Position = UDim2.new(0.46, 0, 0, PAD)
	right.Size = UDim2.new(0.54, -PAD, 1, -PAD * 2)
	corner(right, Theme.Radius.Button)
	padding(right, PAD)
	right.Parent = f
	local rl = Instance.new("UIListLayout")
	rl.Padding = UDim.new(0, if phone then 2 else Theme.Space.XS)
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Parent = right
	local oddsTitle = label(right, "Drop chances", TEXT.Small, C.TextDim)
	oddsTitle.Size = UDim2.new(1, 0, 0, TEXT.Small + 4)
	local odds = ShopCatalog.ChestOdds()
	local rowH = if phone then 32 else 44
	for i, e in CHEST.Pool do
		local rarity = heroRarity(e.Hero)
		local color = TreeConfig.RarityColors[rarity] or C.Text
		local row = Instance.new("Frame")
		row.Name = e.Hero
		row.LayoutOrder = i
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, rowH)
		row.Parent = right
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromOffset(rowH, rowH)
		img.BackgroundColor3 = color
		img.Image = heroImage(e.Hero)
		corner(img, Theme.Radius.Chip)
		img.Parent = row
		local n = label(row, e.Hero, TEXT.Body, color)
		n.Position = UDim2.fromOffset(rowH + Theme.Space.S, 0)
		n.Size = UDim2.new(1, -(rowH + Theme.Space.S + 70), 1, 0)
		n.TextWrapped = false
		n.TextTruncate = Enum.TextTruncate.AtEnd
		local pct = odds[e.Hero] * 100
		local p = label(row, if pct < 1 then ("%.1f%%"):format(pct) else ("%d%%"):format(math.floor(pct + 0.5)), TEXT.Body)
		p.AnchorPoint = Vector2.new(1, 0)
		p.Position = UDim2.fromScale(1, 0)
		p.Size = UDim2.new(0, 66, 1, 0)
		p.TextXAlignment = Enum.TextXAlignment.Right
	end
	shine(f)
end

-- Game pass card -----------------------------------------------------------------------------------------

local function passCard(parent: Instance, pass: ShopCatalog.GamePass, order: number)
	local f = card(parent, pass.Id)
	f.LayoutOrder = order
	padding(f, PAD)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundColor3 = C.Accent
	icon.Image = pass.Icon
	icon.Size = UDim2.fromOffset(Theme.Icon.L, Theme.Icon.L)
	corner(icon, Theme.Icon.L // 2)
	icon.Parent = f
	if pass.Icon == "" then
		local letter = label(icon, string.sub(pass.Name, 1, 2), TEXT.Body, C.Stroke)
		letter.Size = UDim2.fromScale(1, 1)
		letter.TextXAlignment = Enum.TextXAlignment.Center
		local st = letter:FindFirstChildOfClass("UIStroke")
		if st then
			st.Enabled = false
		end
	end
	local name = label(f, pass.Name, TEXT.Name)
	name.Position = UDim2.fromOffset(Theme.Icon.L + Theme.Space.S, 0)
	name.Size = UDim2.new(1, -(Theme.Icon.L + Theme.Space.S), 0, Theme.Icon.L)
	name.TextWrapped = true
	local desc = label(f, pass.Desc, TEXT.Small, C.TextDim)
	desc.Position = UDim2.fromOffset(0, Theme.Icon.L + Theme.Space.XS)
	desc.Size = UDim2.new(1, 0, 1, -(Theme.Icon.L + Theme.TouchMin + Theme.Space.S * 2))
	desc.TextYAlignment = Enum.TextYAlignment.Top
	local onSale = ShopCatalog.OnSale(pass.GamePassId)
	local b = priceButton(f, nil, pass.Robux, onSale, function()
		MarketplaceService:PromptGamePassPurchase(player, pass.GamePassId)
	end)
	b.AnchorPoint = Vector2.new(0, 1)
	b.Position = UDim2.fromScale(0, 1)
	b.Size = UDim2.new(1, 0, 0, Theme.TouchMin)
	local function refresh()
		if player:GetAttribute("Pass_" .. pass.Id) == true then
			b.Text = "OWNED"
			b.AutoButtonColor = false
			b.Active = false
			b.BackgroundColor3 = C.SecondaryDark
		end
	end
	player:GetAttributeChangedSignal("Pass_" .. pass.Id):Connect(refresh)
	refresh()
end

-- Potion card --------------------------------------------------------------------------------------------

local function potionCard(parent: Instance, def: any, order: number)
	local f = card(parent, def.Id)
	f.LayoutOrder = order
	padding(f, PAD)
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.BackgroundColor3 = def.Color
	swatch.Size = UDim2.fromOffset(Theme.Icon.L, Theme.Icon.L)
	corner(swatch, Theme.Icon.L // 2)
	stroke(swatch, C.Stroke, 2)
	swatch.Parent = f
	local name = label(f, (string.gsub(def.Name, " Potion$", "")), TEXT.Name) -- the tab already says Potions
	name.Position = UDim2.fromOffset(Theme.Icon.L + Theme.Space.S, 0)
	name.Size = UDim2.new(1, -(Theme.Icon.L + Theme.Space.S), 0, Theme.Icon.L)
	local desc = label(f, ("%s  (%d min)"):format(def.Desc, math.floor(def.Duration / 60)), TEXT.Small, C.TextDim)
	desc.Position = UDim2.fromOffset(0, Theme.Icon.L + Theme.Space.XS)
	desc.Size = UDim2.new(1, 0, 0, TEXT.Small * 2 + 4)
	desc.TextYAlignment = Enum.TextYAlignment.Top
	local row = Instance.new("Frame")
	row.Name = "Packs"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.fromScale(0, 1)
	row.Size = UDim2.new(1, 0, 0, Theme.TouchMin)
	row.Parent = f
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.Padding = UDim.new(0, Theme.Space.XS)
	rl.Parent = row
	local products = ShopCatalog.PotionProducts[def.Id] or {}
	local n = #ShopCatalog.PotionBundles
	for i, bundle in ShopCatalog.PotionBundles do
		local id = products[bundle.Amount] or 0
		local b = priceButton(row, nil, bundle.Robux, ShopCatalog.OnSale(id), function()
			promptProduct(id)
		end)
		b.LayoutOrder = i
		b.Size = UDim2.new(1 / n, -Theme.Space.XS * (n - 1) / n, 1, 0)
		b.TextSize = TEXT.Small
		b.Text = ("x%d\n%s"):format(bundle.Amount, b.Text)
		b.LineHeight = 0.9
	end
end

-- Fertilizer card ----------------------------------------------------------------------------------------

local function fertilizerCard(parent: Instance, pack: any, order: number, best: boolean)
	local f = card(parent, "Fertilizer" .. pack.Amount)
	f.LayoutOrder = order
	padding(f, PAD)
	if best then
		stroke(f, C.Accent, 3)
		local tag = Instance.new("TextLabel")
		tag.BackgroundColor3 = C.Accent
		tag.Font = Theme.Font
		tag.Text = "BEST VALUE"
		tag.TextSize = TEXT.Small
		tag.TextColor3 = C.Stroke
		tag.AnchorPoint = Vector2.new(1, 0)
		tag.Position = UDim2.fromScale(1, 0)
		tag.Size = UDim2.fromOffset(100, 24)
		corner(tag, Theme.Radius.Chip)
		tag.Parent = f
	end
	local amount = label(f, ("x%d"):format(pack.Amount), TEXT.Big, C.Accent)
	amount.Size = UDim2.new(1, 0, 0, TEXT.Big + 4)
	local name = label(f, "Fruit Fertilizer", TEXT.Name)
	name.Position = UDim2.fromOffset(0, TEXT.Big + 6)
	name.Size = UDim2.new(1, 0, 0, TEXT.Name + 4)
	local desc = label(f, ("Grows %d Devil Fruit%s"):format(
		math.floor(pack.Amount / math.max(1, FruitConfig.FertilizerPerGrow or 1)),
		if pack.Amount > 1 then "s" else ""
	), TEXT.Small, C.TextDim)
	desc.Position = UDim2.fromOffset(0, TEXT.Big + TEXT.Name + 12)
	desc.Size = UDim2.new(1, 0, 0, TEXT.Small + 4)
	local b = priceButton(f, nil, pack.Robux, ShopCatalog.OnSale(pack.ProductId), function()
		promptProduct(pack.ProductId)
	end)
	b.AnchorPoint = Vector2.new(0, 1)
	b.Position = UDim2.fromScale(0, 1)
	b.Size = UDim2.new(1, 0, 0, Theme.TouchMin)
end

-- Pages ---------------------------------------------------------------------------------------------------

local COLS = 3
local PASS_H = if phone then 170 else 200
local POTION_H = if phone then 150 else 170
local FERT_H = if phone then 170 else 200

do -- Featured
	local pg = addTab("Featured", "Featured")
	chestCard(pg, 1)
	heading(pg, "Top Game Passes", 2)
	local g = grid(pg, 3, COLS, PASS_H)
	for i = 1, math.min(COLS, #ShopCatalog.GamePasses) do
		passCard(g, ShopCatalog.GamePasses[i], i)
	end
end

do -- Game passes
	local pg = addTab("Passes", "Game Passes")
	local g = grid(pg, 1, COLS, PASS_H)
	for i, pass in ShopCatalog.GamePasses do
		passCard(g, pass, i)
	end
end

do -- Potions
	local pg = addTab("Potions", "Potions")
	local g = grid(pg, 1, if phone then 2 else COLS, POTION_H)
	for i, def in PotionConfig.Potions do
		potionCard(g, def, i)
	end
end

do -- Fertilizer
	local pg = addTab("Fertilizer", "Fertilizer")
	local g = grid(pg, 1, COLS, FERT_H)
	local packs = FruitConfig.FertilizerProducts
	for i, pack in packs do
		fertilizerCard(g, pack, i, i == #packs)
	end
end

do -- Hero chest
	local pg = addTab("Chest", "Hero Chest")
	chestCard(pg, 1)
	local note = label(pg, "Heroes go to your bag. Drop chances are shown for every hero.", TEXT.Small, C.TextDim)
	note.LayoutOrder = 2
	note.Size = UDim2.new(1, 0, 0, TEXT.Small * 2 + 4)
end

selectTab("Featured")

-- Purchase results ----------------------------------------------------------------------------------------

local reveal = Instance.new("Frame")
reveal.Name = "Reveal"
reveal.BackgroundColor3 = C.Surface
reveal.BackgroundTransparency = 0.05
reveal.Size = UDim2.fromScale(1, 1)
reveal.ZIndex = 50
reveal.Visible = false
reveal.Active = true
reveal.Parent = win.body

local revealTitle = label(reveal, "YOU GOT!", TEXT.Big, C.Accent)
revealTitle.ZIndex = 51
revealTitle.Size = UDim2.new(1, 0, 0, TEXT.Big + 16)
revealTitle.TextXAlignment = Enum.TextXAlignment.Center

local revealRow = Instance.new("Frame")
revealRow.Name = "Heroes"
revealRow.BackgroundTransparency = 1
revealRow.Position = UDim2.fromOffset(0, TEXT.Big + 24)
revealRow.Size = UDim2.new(1, 0, 1, -(TEXT.Big + 24 + Theme.TouchMin + PAD * 2))
revealRow.ZIndex = 51
revealRow.Parent = reveal
local revealGrid = Instance.new("UIGridLayout")
revealGrid.CellSize = if phone then UDim2.fromOffset(84, 104) else UDim2.fromOffset(110, 136)
revealGrid.CellPadding = UDim2.fromOffset(PAD, PAD)
revealGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
revealGrid.VerticalAlignment = Enum.VerticalAlignment.Center
revealGrid.SortOrder = Enum.SortOrder.LayoutOrder
revealGrid.Parent = revealRow

local okButton = Instance.new("TextButton")
okButton.Name = "OK"
okButton.AnchorPoint = Vector2.new(0.5, 1)
okButton.Position = UDim2.new(0.5, 0, 1, -PAD)
okButton.Size = UDim2.fromOffset(180, Theme.TouchMin)
okButton.BackgroundColor3 = C.Primary
okButton.Font = Theme.Font
okButton.Text = "OK"
okButton.TextSize = TEXT.Name
okButton.TextColor3 = C.Text
okButton.ZIndex = 52
okButton.Parent = reveal
UIStyle.Button(okButton)
okButton.Activated:Connect(function()
	reveal.Visible = false
end)

local function showChest(heroes: { string })
	for _, c in revealRow:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, hero in heroes do
		local rarity = heroRarity(hero)
		local color = TreeConfig.RarityColors[rarity] or C.Text
		local cell = Instance.new("Frame")
		cell.LayoutOrder = i
		cell.BackgroundColor3 = C.SurfaceInset
		cell.ZIndex = 52
		corner(cell, Theme.Radius.Card)
		stroke(cell, color, 3)
		local sc = Instance.new("UIScale")
		sc.Scale = 0
		sc.Parent = cell
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Image = heroImage(hero)
		img.Position = UDim2.fromScale(0.1, 0.05)
		img.Size = UDim2.fromScale(0.8, 0.65)
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = 53
		img.Parent = cell
		local n = label(cell, hero, TEXT.Small, color)
		n.AnchorPoint = Vector2.new(0, 1)
		n.Position = UDim2.new(0, 4, 1, -4)
		n.Size = UDim2.new(1, -8, 0.28, 0)
		n.TextXAlignment = Enum.TextXAlignment.Center
		n.TextScaled = true
		n.ZIndex = 53
		cell.Parent = revealRow
		-- Bounce in, one after the other.
		task.delay((i - 1) * 0.12, function()
			TweenService:Create(sc, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
	end
	revealTitle.Text = "YOU GOT!"
	reveal.Visible = true
	win.Open()
end

local banner = label(win.header, "", TEXT.Body, C.Primary)
banner.AnchorPoint = Vector2.new(1, 0.5)
banner.Position = UDim2.new(1, -(UIStyle.HEADER + Theme.Space.L), 0.5, 0)
banner.Size = UDim2.new(0.5, 0, 1, 0)
banner.TextXAlignment = Enum.TextXAlignment.Right
banner.TextWrapped = false

local bannerToken = 0
local function flash(text: string)
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	task.delay(3, function()
		if bannerToken == token then
			banner.Text = ""
		end
	end)
end

local resultRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RobuxShopResult") :: RemoteEvent
resultRemote.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "Chest" and typeof(data) == "table" and typeof(data.heroes) == "table" then
		showChest(data.heroes)
	elseif kind == "Potion" and typeof(data) == "table" then
		local def = PotionConfig.Get(data.id)
		flash(("+%d %s"):format(data.amount or 1, if def then def.Name else "Potion"))
	end
end)

-- Sidebar button --------------------------------------------------------------------------------------------

local sidebar = player:WaitForChild("PlayerGui"):WaitForChild("LeftSidebar")
local shopButton = sidebar:WaitForChild("Buttons"):WaitForChild("Shop") :: GuiButton
shopButton.Activated:Connect(function()
	if win.IsOpen() then
		win.Close()
	else
		reveal.Visible = false
		selectTab(current or "Featured")
		win.Open()
	end
end)
