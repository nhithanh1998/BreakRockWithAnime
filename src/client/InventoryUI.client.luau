-- InventoryUI: the inventory window (StarterGui.InventoryGui), opened by the hotbar's backpack
-- button or the ` key (HotbarUI toggles the InventoryGui "Open" attribute).
--
-- Shows everything the player owns:
--   heroes    - player.Heroes (IntValue per hero = how many owned); count shown = copies not on a pad
--   materials - player.Carried (IntValue per TreeConfig.Materials key: what the player carries)
--   other     - potions (player.Potions, PotionConfig) and axes (player.Axes, "Copies" attribute)
-- Tabs: Panel.Tabs.All / Heroes / Materials / Other. Panel.Search.Box filters by name.
-- Clicking a potion opens a small card with what it does and a DRINK button (Remotes.PotionAction).
-- Clicking a hero opens the same card with SELL 1 / SELL ALL (Remotes.InventoryAction "SellHero").
-- Copies standing on any pad are never sold (the server checks; only free copies are listed).
-- Cards are clones of InventoryGui.Templates.ItemSlot, drawn with ItemDisplay.
-- Panel.EquipBest fills the hero pads with the strongest heroes and axes (HeroSlotService).
--
-- The layout lives in StarterGui.InventoryGui (edited in Studio); this script only fills it.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("InventoryGui") :: ScreenGui
local panel = gui:WaitForChild("Panel") :: Frame
local panelScale = panel:WaitForChild("UIScale") :: UIScale
local closeButton = panel:WaitForChild("Close") :: TextButton
local tabsFrame = panel:WaitForChild("Tabs") :: Frame
local searchBox = (panel:WaitForChild("Search") :: Frame):WaitForChild("Box") :: TextBox
local grid = panel:WaitForChild("Grid") :: ScrollingFrame
local emptyLabel = panel:WaitForChild("Empty") :: TextLabel
local slotTemplate = (gui:WaitForChild("Templates") :: Folder):WaitForChild("ItemSlot") :: TextButton

-- Hero portraits fill the whole card (under the name / count), not just the smaller "View" box.
if not slotTemplate:FindFirstChild("HeroView") then
	local heroView = Instance.new("ViewportFrame")
	heroView.Name = "HeroView"
	heroView.BackgroundTransparency = 1
	heroView.Size = UDim2.fromScale(1, 1)
	heroView.ZIndex = 1
	heroView.Visible = false
	heroView.Parent = slotTemplate
end

-- Card layout: the name sits on a dark strip along the bottom (the portrait stays visible), the
-- count is a small pill in the top-right corner. Portrait layers use ZIndex 1-2, so these go above.
if not slotTemplate:FindFirstChild("NameBar") then
	local nameBar = Instance.new("Frame")
	nameBar.Name = "NameBar"
	nameBar.AnchorPoint = Vector2.new(0, 1)
	nameBar.Position = UDim2.fromScale(0, 1)
	nameBar.Size = UDim2.fromScale(1, 0.4)
	nameBar.BackgroundColor3 = Color3.new(0, 0, 0)
	nameBar.BackgroundTransparency = 0
	nameBar.BorderSizePixel = 0
	nameBar.ZIndex = 4
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.35, 0.45),
		NumberSequenceKeypoint.new(1, 0.25),
	})
	fade.Parent = nameBar
	for _, rounded in { slotTemplate, nameBar } do
		if not rounded:FindFirstChildOfClass("UICorner") then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = rounded
		end
	end
	nameBar.Parent = slotTemplate

	local itemName = slotTemplate:FindFirstChild("ItemName") :: TextLabel?
	if itemName then
		itemName.AnchorPoint = Vector2.new(0.5, 1)
		itemName.Position = UDim2.new(0.5, 0, 1, -4)
		itemName.Size = UDim2.new(1, -10, 0.3, 0)
		itemName.TextWrapped = true
		itemName.TextScaled = true
		itemName.ZIndex = 5
		local limit = itemName:FindFirstChildOfClass("UITextSizeConstraint")
		if limit then
			limit.MaxTextSize = 20
		end
		local stroke = itemName:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = 1.5
		end
	end

	local count = slotTemplate:FindFirstChild("Count") :: TextLabel?
	if count then
		count.AnchorPoint = Vector2.new(1, 0)
		count.Position = UDim2.new(1, -5, 0, 5)
		count.Size = UDim2.fromOffset(0, 24)
		count.AutomaticSize = Enum.AutomaticSize.X
		count.TextScaled = false
		count.TextSize = 18
		count.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
		count.BackgroundTransparency = 0.25
		count.ZIndex = 5
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = count
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 7)
		pad.PaddingRight = UDim.new(0, 7)
		pad.Parent = count
		local stroke = count:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = 1.5
		end
	end

	-- Potion / axe pictures sit in the space above the name strip.
	for _, name in { "View", "Image" } do
		local child = slotTemplate:FindFirstChild(name) :: GuiObject?
		if child then
			child.Position = UDim2.fromScale(0.5, 0.4)
			child.Size = UDim2.fromScale(0.66, 0.66)
		end
	end
end

local TAB_ON_BG = Color3.fromRGB(45, 180, 60)
local TAB_ON_STROKE = Color3.fromRGB(25, 110, 35)
local TAB_OFF_BG = Color3.fromRGB(70, 75, 88)
local TAB_OFF_STROKE = Color3.fromRGB(115, 120, 132)
local SCREEN_FILL_X = 0.92 -- largest share of the screen the panel may cover

local commas = ItemDisplay.Commas
local abbreviate = ItemDisplay.Abbreviate

type Tab = "All" | "Heroes" | "Materials" | "Other"
type Kind = "Hero" | "Material" | "Potion" | "Axe"
type Entry = { stack: string, info: ItemDisplay.ItemInfo, amount: number, onPad: number, kind: Kind, id: string? }

local KIND_ORDER = { Hero = 1, Material = 2, Potion = 3, Axe = 4 }

local currentTab: Tab = "All"
local isOpen = false
local renderQueued = false
local cards: { [string]: TextButton } = {}

local function press(button: GuiObject)
	local scale = button:FindFirstChild("Press") :: UIScale?
	if scale then
		scale.Scale = 0.88
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

-- Data -------------------------------------------------------------------------------------------

-- How many of each hero stand on my plot's pads: worker pads (HeroSlotService writes each slot's
-- "HeroId") and Farm Stand keeper / helper pads (tag "StandHeroPad", StandService). A copy is on one pad only.
local function placedCounts(): { [string]: number }
	local counts = {}
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local pads = plot:FindFirstChild("HeroSlots")
			for _, slot in if pads then pads:GetChildren() else {} do
				local hero = slot:GetAttribute("HeroId")
				if typeof(hero) == "string" and hero ~= "" then
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
			for _, pad in CollectionService:GetTagged("StandHeroPad") do
				local hero = pad:GetAttribute("HeroId")
				if typeof(hero) == "string" and hero ~= "" and pad:IsDescendantOf(plot) then
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
		end
	end
	return counts
end

local function entries(): { Entry }
	local list: { Entry } = {}
	if currentTab == "All" or currentTab == "Heroes" then
		local heroes = player:FindFirstChild("Heroes")
		local placed = placedCounts()
		for _, v in if heroes then heroes:GetChildren() else {} do
			if v:IsA("IntValue") and v.Value > 0 then
				-- Only copies not standing on a pad are listed; fully placed heroes are hidden.
				local available = v.Value - math.min(v.Value, placed[v.Name] or 0)
				if available > 0 then
					local stack = ItemDisplay.HeroStack(v.Name)
					table.insert(list, { stack = stack, info = ItemDisplay.Info(stack), amount = available, onPad = 0, kind = "Hero" })
				end
			end
		end
	end
	if currentTab == "All" or currentTab == "Materials" then
		-- Materials the player carries (picked up on the Loot Pad, CarryService).
		local inventory = player:FindFirstChild("Carried")
		for _, v in if inventory then inventory:GetChildren() else {} do
			if v:IsA("IntValue") and v.Value > 0 and TreeConfig.Materials[v.Name] then
				table.insert(list, { stack = v.Name, info = ItemDisplay.Info(v.Name), amount = v.Value, onPad = 0, kind = "Material" })
			end
		end
	end
	if currentTab == "All" or currentTab == "Other" then
		local potions = player:FindFirstChild("Potions")
		for _, v in if potions then potions:GetChildren() else {} do
			local def = v:IsA("IntValue") and v.Value > 0 and PotionConfig.Get(v.Name)
			if def then
				table.insert(list, {
					stack = "Potion:" .. def.Id,
					info = { name = def.Name, rarity = def.Rarity, isHero = false, value = 0 },
					amount = v.Value,
					onPad = 0,
					kind = "Potion",
					id = def.Id,
				})
			end
		end
		local axes = player:FindFirstChild("Axes")
		for _, v in if axes then axes:GetChildren() else {} do
			local def = v:IsA("BoolValue") and v.Value and ShopConfig.GetAxe(v.Name)
			if def then
				local copies = v:GetAttribute("Copies")
				table.insert(list, {
					stack = "Axe:" .. def.Model,
					info = { name = def.Name, rarity = def.Rarity, isHero = false, value = def.HeroBoost },
					amount = if typeof(copies) == "number" then math.max(1, copies) else 1,
					onPad = 0,
					kind = "Axe",
					id = def.Model,
				})
			end
		end
	end

	local query = searchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if query ~= "" then
		local filtered = {}
		for _, e in list do
			if e.info.name:lower():find(query, 1, true) then
				table.insert(filtered, e)
			end
		end
		list = filtered
	end

	-- Heroes first, then materials, potions, axes; rarest first, then most valuable / powerful, then by name.
	table.sort(list, function(a, b)
		if a.kind ~= b.kind then
			return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
		end
		local ra = TreeConfig.RarityOrder[a.info.rarity] or 99
		local rb = TreeConfig.RarityOrder[b.info.rarity] or 99
		if ra ~= rb then
			return ra < rb
		end
		if a.info.value ~= b.info.value then
			return a.info.value > b.info.value
		end
		return a.info.name < b.info.name
	end)
	return list
end

-- Drawing ----------------------------------------------------------------------------------------

local function drawCard(card: TextButton, e: Entry)
	local info = e.info
	ItemDisplay.PaintRarity(card, info.rarity);
	(card:FindFirstChild("ItemName") :: TextLabel).Text = info.name
	local count = card:FindFirstChild("Count") :: TextLabel
	count.Text = "x" .. commas(e.amount)
	count.Visible = true
	-- No "E" badge in the inventory: placed heroes are simply not listed.
	local equipped = card:FindFirstChild("Equipped") :: TextLabel?
	if equipped then
		equipped.Visible = false
	end
	if e.kind == "Potion" or e.kind == "Axe" then
		-- Drawn in the lower "View" box, under the name (cached per card: the Fill* functions skip a repeat).
		for _, name in { "HeroView", "Icon", "Image" } do
			local child = card:FindFirstChild(name) :: GuiObject?
			if child then
				child.Visible = false
			end
		end
		local view = (card:FindFirstChild("View") or card:FindFirstChild("HeroView")) :: ViewportFrame?
		if view and e.id then
			view.Visible = true
			if e.kind == "Potion" then
				ItemDisplay.FillPotionViewport(view, e.id)
			else
				ItemDisplay.FillAxeViewport(view, e.id)
			end
		end
		-- A running potion shows its time left under the name.
		if e.kind == "Potion" and e.id then
			local left = PotionConfig.TimeLeft(player, e.id)
			if left > 0 then
				count.Text = ("x%s  •  %s"):format(commas(e.amount), PotionConfig.Clock(left))
			end
		end
		return
	end
	ItemDisplay.SetPicture(card, info)
end

-- Potion card: what it does and DRINK -----------------------------------------------------------------

local PotionAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PotionAction", 10) :: RemoteFunction?
local FONT = Enum.Font.FredokaOne

local function uiText(props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	for k, v in props do
		(l :: any)[k] = v
	end
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(20, 20, 26)
	stroke.Parent = l
	return l
end

local potionCard = Instance.new("Frame")
potionCard.Name = "PotionCard"
potionCard.AnchorPoint = Vector2.new(0.5, 0.5)
potionCard.Position = UDim2.fromScale(0.5, 0.55)
potionCard.Size = UDim2.fromOffset(440, 250)
potionCard.BackgroundColor3 = Color3.fromRGB(34, 36, 46)
potionCard.Visible = false
potionCard.ZIndex = 20
potionCard.Parent = panel
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 16)
	c.Parent = potionCard
	local st = Instance.new("UIStroke")
	st.Thickness = 4
	st.Color = Color3.fromRGB(255, 255, 255)
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = potionCard
end
local potionView = Instance.new("ViewportFrame")
potionView.BackgroundTransparency = 1
potionView.Position = UDim2.fromOffset(16, 30)
potionView.Size = UDim2.fromOffset(150, 150)
potionView.ZIndex = 21
potionView.Parent = potionCard
local potionName = uiText({ Position = UDim2.fromOffset(180, 22), Size = UDim2.fromOffset(196, 40), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21, Parent = potionCard })
local potionDesc = uiText({ Position = UDim2.fromOffset(180, 66), Size = UDim2.fromOffset(244, 30), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(110, 255, 120), ZIndex = 21, Parent = potionCard })
local potionInfo = uiText({ Position = UDim2.fromOffset(180, 98), Size = UDim2.fromOffset(244, 76), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextScaled = false, TextSize = 18, TextWrapped = true, TextColor3 = Color3.fromRGB(220, 222, 235), ZIndex = 21, Parent = potionCard })
local drinkButton = Instance.new("TextButton")
drinkButton.Name = "Drink"
drinkButton.AutoButtonColor = true
drinkButton.Position = UDim2.fromOffset(180, 180)
drinkButton.Size = UDim2.fromOffset(150, 52)
drinkButton.BackgroundColor3 = Color3.fromRGB(45, 180, 60)
drinkButton.Text = ""
drinkButton.ZIndex = 21
drinkButton.Parent = potionCard
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 12)
	c.Parent = drinkButton
	local st = Instance.new("UIStroke")
	st.Thickness = 3
	st.Color = Color3.fromRGB(25, 110, 35)
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = drinkButton
end
local drinkLabel = uiText({ Size = UDim2.fromScale(1, 1), Text = "DRINK", ZIndex = 22, Parent = drinkButton })
-- Second button, only for heroes ("SELL ALL").
local sellAllButton = drinkButton:Clone()
sellAllButton.Name = "SellAll"
sellAllButton.Position = UDim2.fromOffset(340, 180)
sellAllButton.Size = UDim2.fromOffset(88, 52)
sellAllButton.BackgroundColor3 = Color3.fromRGB(210, 120, 30)
sellAllButton.Visible = false
sellAllButton.Parent = potionCard
local sellAllLabel = sellAllButton:FindFirstChildOfClass("TextLabel") :: TextLabel
sellAllLabel.Text = "ALL"
local closeCard = Instance.new("TextButton")
closeCard.Name = "Close"
closeCard.AnchorPoint = Vector2.new(1, 0)
closeCard.Position = UDim2.new(1, -12, 0, 12)
closeCard.Size = UDim2.fromOffset(40, 40)
closeCard.BackgroundColor3 = Color3.fromRGB(220, 70, 60)
closeCard.Text = ""
closeCard.ZIndex = 21
closeCard.Parent = potionCard
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = closeCard
end
uiText({ Size = UDim2.fromScale(1, 1), Text = "X", ZIndex = 22, Parent = closeCard })
local cardMessage = uiText({ Position = UDim2.fromOffset(16, 200), Size = UDim2.fromOffset(150, 30), Text = "", TextColor3 = Color3.fromRGB(255, 220, 120), ZIndex = 21, Parent = potionCard })

local shownPotion: string? = nil
local shownHero: string? = nil
local InventoryAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("InventoryAction", 10) :: RemoteFunction?
local SELL_COLOR = Color3.fromRGB(45, 180, 60)
local OFF_COLOR = Color3.fromRGB(90, 92, 102)

local function freeCopies(hero: string): (number, number)
	local heroes = player:FindFirstChild("Heroes")
	local v = heroes and heroes:FindFirstChild(hero)
	local owned = if v and v:IsA("IntValue") then v.Value else 0
	local onPad = math.min(owned, placedCounts()[hero] or 0)
	return owned - onPad, onPad
end

local function drawHeroCard()
	local def = shownHero and HeroConfig.Get(shownHero)
	if not def then
		potionCard.Visible = false
		return
	end
	local stroke = potionCard:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = ItemDisplay.SlotColor(def.Rarity)
	end
	ItemDisplay.FillHeroViewport(potionView, def.Name)
	potionName.Text = def.Name
	potionDesc.Text = def.Rarity
	potionDesc.TextColor3 = TreeConfig.RarityColors[def.Rarity] or Color3.new(1, 1, 1)
	local free, onPad = freeCopies(def.Name)
	local price = math.floor(def.SellValue * ShopConfig.HeroSellMultiplier)
	potionInfo.Text = ("Sells for $%s each\nFree: %d%s"):format(abbreviate(price), free, if onPad > 0 then ("   •   On pads: %d"):format(onPad) else "")
	drinkLabel.Text = "SELL 1"
	drinkButton.Active = free > 0
	drinkButton.BackgroundColor3 = if free > 0 then SELL_COLOR else OFF_COLOR
	sellAllButton.Visible = true
	sellAllButton.Active = free > 0
	sellAllButton.BackgroundColor3 = if free > 0 then Color3.fromRGB(210, 120, 30) else OFF_COLOR
end

local function drawPotionCard()
	if shownHero then
		drawHeroCard()
		return
	end
	sellAllButton.Visible = false
	drinkLabel.Text = "DRINK"
	local def = shownPotion and PotionConfig.Get(shownPotion)
	if not def then
		potionCard.Visible = false
		return
	end
	local stroke = potionCard:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = def.Color
	end
	ItemDisplay.FillPotionViewport(potionView, def.Id)
	potionName.Text = def.Name
	potionDesc.Text = def.Desc
	potionDesc.TextColor3 = Color3.fromRGB(110, 255, 120)
	local owned = 0
	local folder = player:FindFirstChild("Potions")
	local v = folder and folder:FindFirstChild(def.Id)
	if v and v:IsA("IntValue") then
		owned = v.Value
	end
	local left = PotionConfig.TimeLeft(player, def.Id)
	potionInfo.Text = ("Lasts %s each (drinking more adds time)\nOwned: %d%s"):format(
		PotionConfig.Clock(def.Duration),
		owned,
		if left > 0 then ("   •   Active: %s"):format(PotionConfig.Clock(left)) else ""
	)
	drinkButton.Active = owned > 0
	drinkButton.BackgroundColor3 = if owned > 0 then Color3.fromRGB(45, 180, 60) else Color3.fromRGB(90, 92, 102)
end

local function openPotion(id: string)
	shownPotion = id
	shownHero = nil
	cardMessage.Text = ""
	potionCard.Visible = true
	drawPotionCard()
end

local function openHero(hero: string)
	shownHero = hero
	shownPotion = nil
	cardMessage.Text = ""
	potionCard.Visible = true
	drawPotionCard()
end

local selling = false
local function sellHero(amount: number | string)
	local hero = shownHero
	if selling or not hero or not InventoryAction then
		return
	end
	selling = true
	local ok, result = pcall((InventoryAction :: RemoteFunction).InvokeServer, InventoryAction, "SellHero", hero, amount)
	if ok and typeof(result) == "table" and result.ok then
		cardMessage.TextColor3 = Color3.fromRGB(110, 255, 120)
		cardMessage.Text = "+$" .. abbreviate(result.earned or 0)
	else
		cardMessage.TextColor3 = Color3.fromRGB(255, 130, 130)
		cardMessage.Text = if ok and typeof(result) == "table" and result.message then result.message else "Try again"
	end
	selling = false
	drawPotionCard()
end

sellAllButton.Activated:Connect(function()
	press(sellAllButton)
	sellHero("All")
end)

closeCard.Activated:Connect(function()
	shownPotion = nil
	shownHero = nil
	potionCard.Visible = false
end)

local drinking = false
drinkButton.Activated:Connect(function()
	if shownHero then
		sellHero(1)
		return
	end
	local id = shownPotion
	if drinking or not id or not PotionAction then
		return
	end
	drinking = true
	drinkLabel.Text = "..."
	local ok, result = pcall((PotionAction :: RemoteFunction).InvokeServer, PotionAction, "Use", id)
	drinkLabel.Text = "DRINK"
	if ok and typeof(result) == "table" and result.ok then
		cardMessage.TextColor3 = Color3.fromRGB(110, 255, 120)
		cardMessage.Text = "Active!"
	else
		cardMessage.TextColor3 = Color3.fromRGB(255, 130, 130)
		cardMessage.Text = if ok and typeof(result) == "table" and result.message then result.message else "Try again"
	end
	drawPotionCard()
	drinking = false
end)

local entryByStack: { [string]: Entry } = {}

local function render()
	renderQueued = false
	if not isOpen then
		return
	end
	local list = entries()
	local keep: { [string]: boolean } = {}
	table.clear(entryByStack)
	for i, e in list do
		keep[e.stack] = true
		entryByStack[e.stack] = e
		local card = cards[e.stack]
		if not card then
			card = slotTemplate:Clone()
			card.Name = e.stack
			card.Visible = true
			cards[e.stack] = card
			card.Parent = grid
			local stack = e.stack
			card.Activated:Connect(function()
				local entry = entryByStack[stack]
				if entry and entry.kind == "Potion" and entry.id then
					press(card)
					openPotion(entry.id)
				elseif entry and entry.kind == "Hero" then
					press(card)
					openHero(entry.stack:sub(#ItemDisplay.HERO_PREFIX + 1))
				end
			end)
		end
		card.LayoutOrder = i
		drawCard(card, e)
	end
	for stack, card in cards do
		if not keep[stack] then
			card:Destroy()
			cards[stack] = nil
		end
	end
	emptyLabel.Visible = #list == 0
	if shownHero and potionCard.Visible then
		drawPotionCard() -- copies sold / placed meanwhile
	end
end

local function queueRender()
	if not renderQueued then
		renderQueued = true
		task.defer(render)
	end
end

-- Tabs & search ----------------------------------------------------------------------------------

-- Selected tab: solid green shaded light-to-dark (3D look, like the other buttons).
-- The others: dark glass with dimmed text and icon, so the choice reads at a glance.
local function styleTabs()
	for _, tab in tabsFrame:GetChildren() do
		if tab:IsA("GuiButton") then
			local on = tab.Name == currentTab
			tab.BackgroundColor3 = if on then TAB_ON_BG else TAB_OFF_BG
			tab.BackgroundTransparency = if on then 0 else 0.45
			local stroke = tab:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if on then TAB_ON_STROKE else TAB_OFF_STROKE
				stroke.Transparency = if on then 0 else 0.5
			end
			local shade = tab:FindFirstChild("Shade") :: UIGradient?
			if shade then
				shade.Enabled = on
			end
			for _, part in { "Label", "Icon" } do
				local child = tab:FindFirstChild(part)
				if child and child:IsA("TextLabel") then
					child.TextTransparency = if on then 0 else 0.35
				elseif child and child:IsA("GuiObject") then
					for _, d in child:GetDescendants() do
						if d:IsA("GuiObject") then
							d.BackgroundTransparency = if on then 0 else 0.35
						end
					end
				end
			end
		end
	end
end

-- Rounded tabs with a shade gradient for the selected state; the Materials log emoji does
-- not render on every device, so it gets a tree.
for _, tab in tabsFrame:GetChildren() do
	if tab:IsA("GuiButton") then
		if not tab:FindFirstChildOfClass("UICorner") then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = tab
		end
		if not tab:FindFirstChild("Shade") then
			local shade = Instance.new("UIGradient")
			shade.Name = "Shade"
			shade.Rotation = 90
			shade.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(175, 175, 175))
			shade.Parent = tab
		end
	end
end
local materialsIcon = tabsFrame:FindFirstChild("Materials") and tabsFrame.Materials:FindFirstChild("Icon")
if materialsIcon and materialsIcon:IsA("TextLabel") then
	materialsIcon.Text = "🌳"
end

-- Four tabs have to fit the Tabs frame (it was laid out for three; "Other" starts hidden in Studio).
local TAB_WIDTHS = { All = 100, Heroes = 140, Materials = 170, Other = 130 }
for _, name in { "All", "Heroes", "Materials", "Other" } do
	local tab = tabsFrame:FindFirstChild(name) :: GuiButton?
	if tab then
		tab.Visible = true
		tab.Size = UDim2.new(0, TAB_WIDTHS[name], tab.Size.Y.Scale, tab.Size.Y.Offset)
		tab.Activated:Connect(function()
			press(tab)
			if currentTab ~= name then
				currentTab = name :: Tab
				styleTabs()
				grid.CanvasPosition = Vector2.zero
				render()
			end
		end)
	else
		warn(("InventoryUI: InventoryGui.Panel.Tabs.%s is missing"):format(name))
	end
end

searchBox:GetPropertyChangedSignal("Text"):Connect(queueRender)

-- Open / close -----------------------------------------------------------------------------------

-- The panel fits in the space above the hotbar (it is laid out in pixels): shrink it for small
-- screens and centre it in that space, so it never covers the hotbar. Returns the scale.
local PANEL_MARGIN = 10
local function layoutPanel(): number
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	-- Work in screen pixels. AbsolutePosition is always measured from below the top bar.
	local inset = GuiService:GetGuiInset().Y
	local top = inset + PANEL_MARGIN -- clear of Roblox's top-bar buttons
	local bottom = view.Y - PANEL_MARGIN
	local hotbar = player.PlayerGui:FindFirstChild("HotbarGui") :: ScreenGui?
	local bar = if hotbar and hotbar.Enabled then hotbar:FindFirstChild("Bar") :: GuiObject? else nil
	if bar and bar.Visible then
		bottom = math.min(bottom, bar.AbsolutePosition.Y + inset - PANEL_MARGIN)
	end
	local origin = if gui.IgnoreGuiInset then 0 else inset -- this ScreenGui's y = 0 on screen
	local size = panel.Size
	local w, h = math.max(size.X.Offset, 1), math.max(size.Y.Offset, 1)
	local scale = math.min(1, view.X * SCREEN_FILL_X / w, math.max(bottom - top, 100) / h)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0, math.floor((top + bottom) / 2 - origin))
	return scale
end

local function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui:SetAttribute("Open", open)
	if open then
		panel.Visible = true
		local target = layoutPanel()
		panelScale.Scale = target * 0.85
		TweenService:Create(panelScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
		styleTabs()
		render()
	else
		searchBox:ReleaseFocus()
		panel.Visible = false
	end
end

gui:GetAttributeChangedSignal("Open"):Connect(function()
	setOpen(gui:GetAttribute("Open") == true)
end)

closeButton.Activated:Connect(function()
	press(closeButton)
	setOpen(false)
end)

-- Equip Best (Panel.EquipBest, designed in Studio; its text is in "Label"): the server puts the
-- strongest heroes on the open pads and the best axes on the strongest of them (HeroSlotService).
-- The label shows the answer for a moment.
local equipBestButton = panel:FindFirstChild("EquipBest") :: TextButton?
if equipBestButton then
	local button = equipBestButton
	local label = (button:FindFirstChild("Label") or button) :: TextLabel
	local idleText = label.Text
	local idleColor = label.TextColor3
	local busy = false
	-- Longer answers shrink to fit the button instead of spilling out (never bigger than the
	-- size set in Studio).
	if not label.TextScaled then
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = label.TextSize
		limit.Parent = label
		label.TextScaled = true
	end
	button.Visible = true
	button.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		press(button)
		label.Text = "..."
		local upgradeRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HeroUpgrade") :: RemoteFunction
		local ok, success, message = pcall(upgradeRemote.InvokeServer, upgradeRemote, 0, "EquipBest")
		label.Text = if ok and typeof(message) == "string" then message else "Try again"
		label.TextColor3 = if ok and success then idleColor else Color3.fromRGB(255, 150, 150)
		task.wait(1.5)
		label.Text = idleText
		label.TextColor3 = idleColor
		busy = false
	end)
end

local function onViewportChanged()
	if isOpen then
		panelScale.Scale = layoutPanel()
	end
end
local function hookCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
	end
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
hookCamera()

-- Watch player.Heroes / player.Inventory ---------------------------------------------------------

local watched: { [Instance]: { RBXScriptConnection } } = {}

local function watchFolder(folder: Instance)
	if watched[folder] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	watched[folder] = conns
	local function hook(v: Instance)
		if v:IsA("IntValue") or v:IsA("BoolValue") then
			table.insert(conns, v.Changed:Connect(queueRender))
			table.insert(conns, v:GetAttributeChangedSignal("Copies"):Connect(queueRender))
		end
	end
	for _, v in folder:GetChildren() do
		hook(v)
	end
	table.insert(conns, folder.ChildAdded:Connect(function(v)
		hook(v)
		queueRender()
	end))
	table.insert(conns, folder.ChildRemoved:Connect(queueRender))
	table.insert(conns, folder.Destroying:Connect(function()
		for _, c in conns do
			c:Disconnect()
		end
		watched[folder] = nil
	end))
	queueRender()
end

local function maybeWatch(c: Instance)
	if c.Name == "Heroes" or c.Name == "Carried" or c.Name == "Potions" or c.Name == "Axes" then
		watchFolder(c)
	end
end
player.ChildAdded:Connect(maybeWatch)
for _, c in player:GetChildren() do
	maybeWatch(c)
end

-- Re-render when a hero is placed on / removed from a pad (slot "HeroId" attribute changes).
local function watchSlot(slot: Instance)
	slot:GetAttributeChangedSignal("HeroId"):Connect(queueRender)
end
local function watchSlots(pads: Instance)
	for _, slot in pads:GetChildren() do
		watchSlot(slot)
	end
	pads.ChildAdded:Connect(function(slot)
		watchSlot(slot)
		queueRender()
	end)
	pads.ChildRemoved:Connect(queueRender)
end
local function watchPlot(plot: Instance)
	local hooked = false
	local function tryHook()
		if hooked then
			return
		end
		local pads = plot:FindFirstChild("HeroSlots")
		if pads then
			hooked = true
			watchSlots(pads)
		end
	end
	tryHook()
	plot.ChildAdded:Connect(function(c)
		if c.Name == "HeroSlots" then
			tryHook()
		end
	end)
	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(queueRender)
end
task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
	for _, plot in plots:GetChildren() do
		watchPlot(plot)
	end
	plots.ChildAdded:Connect(watchPlot)
end)

-- Farm Stand keeper / helper pads (StandService) change what is listed too.
local function watchStandPad(pad: Instance)
	pad:GetAttributeChangedSignal("HeroId"):Connect(queueRender)
end
for _, pad in CollectionService:GetTagged("StandHeroPad") do
	watchStandPad(pad)
end
CollectionService:GetInstanceAddedSignal("StandHeroPad"):Connect(function(pad)
	watchStandPad(pad)
	queueRender()
end)

-- Running potions count down on their cards (and on the open potion card) once a second.
task.spawn(function()
	while true do
		task.wait(1)
		if isOpen then
			local anyActive = false
			for _, def in PotionConfig.Potions do
				if PotionConfig.TimeLeft(player, def.Id) > 0 then
					anyActive = true
					break
				end
			end
			if anyActive and (currentTab == "All" or currentTab == "Other") then
				queueRender()
			end
			if potionCard.Visible then
				drawPotionCard()
			end
		elseif potionCard.Visible then
			shownPotion = nil
			potionCard.Visible = false
		end
	end
end)

panel.Visible = false
gui:SetAttribute("Open", false)
