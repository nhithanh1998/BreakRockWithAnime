-- IndexUI: the Index (collection book) window, opened by the sidebar's "Index" button
-- (StarterGui.LeftSidebar.Buttons.Index). Rules and rewards: Shared.IndexConfig; server: IndexService.
--
--   Header   "Index", a progress bar of everything found in every zone ("95/346 Found  27%"), X.
--   Tabs     one per zone (green = shown). A red badge = rewards ready to claim in that zone.
--            Zones not unlocked yet show "🔒" but can still be browsed.
--   Grid     every item the zone's trees drop: materials, then heroes. Found items show their picture,
--            name and drop chance on their rarity's colour; unknown ones are a dark silhouette with
--            "???" and the chance.
--   Rewards  under the grid: one card per milestone ("12/24 Found" bar + the rewards). CLAIM when
--            reached (Remotes.IndexAction "Claim"), then "Claimed ✓".
-- The sidebar button's badge shows how many rewards are ready in all zones.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local IndexConfig = require(Shared:WaitForChild("IndexConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local PotionConfig = require(Shared:WaitForChild("PotionConfig"))
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local IndexAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("IndexAction") :: RemoteFunction

local FONT = Enum.Font.FredokaOne
local STROKE = Color3.fromRGB(20, 20, 26)
local BG = Color3.fromRGB(38, 38, 44)
local TAB_ON = Color3.fromRGB(45, 185, 70)
local TAB_OFF = Color3.fromRGB(78, 80, 92)
local UNKNOWN_BG = Color3.fromRGB(30, 30, 36)
local GOLD = Color3.fromRGB(255, 196, 60)
local WIDTH, HEIGHT = 1000, 680
local COLS = 6
local CELL = 146
local CELL_GAP = 10

local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(r: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function stroke(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function label(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = FONT
	if props.TextScaled == nil then
		props.TextScaled = true
	end
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local t = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local l = new("TextLabel", props)
	stroke(STROKE, t).Parent = l
	return l
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function formatChance(chance: number): string
	local pct = chance * 100
	if pct >= 100 then
		return "100%"
	elseif pct <= 0 then
		return "0%"
	end
	local decimals = math.clamp(2 - math.floor(math.log10(pct)), 0, 4)
	return ("%." .. decimals .. "f%%"):format(pct)
end

local function press(button: GuiObject)
	local scale = button:FindFirstChild("Press") :: UIScale?
	if not scale then
		scale = new("UIScale", { Name = "Press", Parent = button })
	end
	(scale :: UIScale).Scale = 0.9
	tween(scale :: UIScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Window ------------------------------------------------------------------------------------------

local gui = new("ScreenGui", { Name = "IndexGui", DisplayOrder = 13, IgnoreGuiInset = true, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = true, Parent = playerGui })
local root = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	BackgroundColor3 = BG,
	BackgroundTransparency = 0.08,
	Visible = false,
	Parent = gui,
}, { corner(14) })
stroke(Color3.fromRGB(70, 72, 82), 3, true).Parent = root
UIStyle.Panel(root)
local openScale = new("UIScale", { Parent = root })

local function fitScale(): number
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return math.min(1, (vp.X - 24) / WIDTH, (vp.Y - 24) / HEIGHT)
end

label({ Text = "Index", Position = UDim2.fromOffset(28, 14), Size = UDim2.fromOffset(160, 56), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 3, Parent = root })

-- Overall progress bar.
local bar = new("Frame", { Name = "Progress", Position = UDim2.fromOffset(250, 18), Size = UDim2.fromOffset(600, 50), BackgroundColor3 = Color3.fromRGB(24, 25, 30), Parent = root }, { corner(25) })
stroke(Color3.fromRGB(110, 230, 110), 3, true).Parent = bar
local barFill = new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(110, 225, 90), Parent = bar }, { corner(25) })
new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(190, 255, 150), Color3.fromRGB(80, 200, 70)), Parent = barFill })
local barText = label({ Text = "0/0 Found", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.6, 0, 0.66, 0), ZIndex = 3, StrokeThickness = 2.5, Parent = bar })
local barPct = label({ Text = "0%", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Size = UDim2.new(0.16, 0, 0.56, 0), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 3, Parent = bar })

local closeButton = new("TextButton", { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 16), Size = UDim2.fromOffset(58, 54), BackgroundColor3 = Color3.fromRGB(214, 92, 28), Text = "", AutoButtonColor = true, Parent = root }, { corner(8) })
stroke(Color3.fromRGB(120, 45, 10), 3, true).Parent = closeButton
label({ Text = "X", Size = UDim2.fromScale(1, 1), Parent = closeButton })
UIStyle.Close(closeButton)

-- Zone tabs (scroll sideways when there are many zones).
local tabs = new("ScrollingFrame", {
	Name = "Tabs",
	Position = UDim2.fromOffset(20, 84),
	Size = UDim2.new(1, -40, 0, 70),
	BackgroundTransparency = 1,
	ScrollBarThickness = 4,
	ScrollingDirection = Enum.ScrollingDirection.X,
	AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(),
	Parent = root,
})
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = tabs })
new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = tabs })

-- Content: the item grid, then the rewards.
local content = new("ScrollingFrame", {
	Name = "Content",
	Position = UDim2.fromOffset(20, 164),
	Size = UDim2.new(1, -40, 1, -180),
	BackgroundTransparency = 1,
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = Color3.fromRGB(150, 150, 160),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = root,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 14), HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = content })
new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 16), Parent = content })

local grid = new("Frame", { Name = "Grid", LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.fromOffset(COLS * CELL + (COLS - 1) * CELL_GAP, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = content })
new("UIGridLayout", { CellSize = UDim2.fromOffset(CELL, CELL), CellPadding = UDim2.fromOffset(CELL_GAP, CELL_GAP), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })

new("Frame", { Name = "Divider", LayoutOrder = 2, Size = UDim2.new(1, -24, 0, 4), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = content })
label({ Name = "RewardsTitle", LayoutOrder = 3, Text = "Rewards", Size = UDim2.fromOffset(300, 54), StrokeThickness = 3, Parent = content })
local rewardsRow = new("Frame", { Name = "Rewards", LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 230), Parent = content })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 40), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rewardsRow })

-- State ---------------------------------------------------------------------------------------------

local drawZone: () -> () -- defined further down (tabs redraw the zone)

local zones = IndexConfig.Zones()
local currentZone = zones[1] or 1
local isOpen = false
local claiming = false

local function unlockedZones(): number
	local n = player:GetAttribute("UnlockedZones")
	return if typeof(n) == "number" then n else 1
end

local function foundFolder(): Instance?
	return player:FindFirstChild(IndexConfig.FoundFolder)
end

local function isFound(stack: string): boolean
	local folder = foundFolder()
	return folder ~= nil and folder:FindFirstChild(stack) ~= nil
end

-- Sidebar badge -----------------------------------------------------------------------------------------

local sidebar = playerGui:WaitForChild("LeftSidebar", 30)
local sidebarButtons = sidebar and sidebar:WaitForChild("Buttons", 10)
local openButton = sidebarButtons and sidebarButtons:WaitForChild("Index", 10) :: GuiButton?
local badge = openButton and openButton:FindFirstChild("Badge") :: GuiObject?
local badgeCount = badge and badge:FindFirstChild("Count") :: TextLabel?

local function drawBadge()
	local total = 0
	for _, zone in zones do
		total += IndexConfig.Claimable(player, zone)
	end
	if badge then
		badge.Visible = total > 0
	end
	if badgeCount then
		badgeCount.Text = tostring(total)
	end
end

-- Drawing -----------------------------------------------------------------------------------------------

local function drawProgress()
	local found, total = 0, 0
	for _, zone in zones do
		local f, t = IndexConfig.FoundIn(player, zone)
		found += f
		total += t
	end
	local share = if total > 0 then found / total else 0
	barText.Text = ("%d/%d Found"):format(found, total)
	barPct.Text = ("%d%%"):format(math.floor(share * 100))
	tween(barFill, 0.3, { Size = UDim2.fromScale(math.max(share, if found > 0 then 0.08 else 0), 1) })
end

local function drawTabs()
	for _, c in tabs:GetChildren() do
		if c:IsA("GuiButton") then
			c:Destroy()
		end
	end
	for i, zone in zones do
		local on = zone == currentZone
		local locked = zone > unlockedZones()
		local name = IndexConfig.ZoneName(zone)
		local tab = new("TextButton", {
			Name = "Zone" .. zone,
			LayoutOrder = i,
			Size = UDim2.fromOffset(250, 60),
			BackgroundColor3 = if on then TAB_ON else TAB_OFF,
			BackgroundTransparency = if on then 0 else 0.2,
			Text = "",
			AutoButtonColor = false,
			Parent = tabs,
		}, { corner(8) })
		stroke(if on then Color3.fromRGB(25, 110, 35) else Color3.fromRGB(120, 124, 136), 3, true).Parent = tab
		UIStyle.Button(tab) -- tabs sit in a list: corners + gloss, no lip
		label({
			Text = if locked then "🔒 " .. name else name,
			TextColor3 = if locked then Color3.fromRGB(255, 120, 120) else Color3.new(1, 1, 1),
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -64, 1, -16),
			TextXAlignment = Enum.TextXAlignment.Left,
			StrokeThickness = 2.5,
			Parent = tab,
		})
		local ready = IndexConfig.Claimable(player, zone)
		if ready > 0 then
			local b = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(38, 38), BackgroundColor3 = Color3.fromRGB(200, 40, 40), Parent = tab }, { corner(6) })
			stroke(Color3.fromRGB(90, 15, 15), 2.5, true).Parent = b
			label({ Text = tostring(ready), Size = UDim2.fromScale(1, 1), Parent = b })
		end
		tab.Activated:Connect(function()
			press(tab)
			if currentZone ~= zone then
				currentZone = zone
				content.CanvasPosition = Vector2.zero
				drawTabs()
				drawZone()
			end
		end)
	end
end

local function picture(holder: GuiObject, entry: IndexConfig.Entry, found: boolean)
	local view = new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromScale(0.86, 0.86), Parent = holder })
	if entry.IsHero then
		local hero = TreeConfig.GetHero(entry.Name)
		if not ItemDisplay.FillHeroViewport(view, entry.Name) then
			if hero and hero.AnimeImage then
				ItemDisplay.ShowImage(view, hero.AnimeImage)
			else
				label({ Text = "★", Size = UDim2.fromScale(0.6, 0.6), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = view })
			end
		end
	else
		local info = ItemDisplay.Info(entry.Stack)
		if info.image then
			ItemDisplay.ShowImage(view, info.image)
		else
			ItemDisplay.FillViewport(view, info.visual, entry.Stack)
		end
	end
	if not found then
		-- Silhouette: the picture (and any layered views / uploaded image in it) drawn black and faded.
		local function darken(inst: Instance)
			if inst:IsA("ViewportFrame") or inst:IsA("ImageLabel") then
				inst.ImageColor3 = Color3.new(0, 0, 0)
				inst.ImageTransparency = 0.35
			end
		end
		darken(view)
		for _, d in view:GetDescendants() do
			darken(d)
		end
	end
end

local function drawCard(entry: IndexConfig.Entry, order: number)
	local found = isFound(entry.Stack)
	local slotColor = ItemDisplay.SlotColor(entry.Rarity)
	local card = new("Frame", {
		Name = entry.Stack,
		LayoutOrder = order,
		BackgroundColor3 = if found then slotColor else UNKNOWN_BG,
		Parent = grid,
	}, { corner(6) })
	stroke(if found then slotColor:Lerp(Color3.new(1, 1, 1), 0.45) else slotColor:Lerp(Color3.new(0, 0, 0), 0.35), 4, true).Parent = card
	picture(card, entry, found)
	local nameLabel = label({
		Text = if found then entry.Name else "???",
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 0, if found then 58 else 64),
		TextWrapped = true,
		TextColor3 = if found then Color3.new(1, 1, 1) else Color3.fromRGB(190, 190, 200),
		StrokeThickness = 2.5,
		ZIndex = 3,
		Parent = card,
	})
	new("UITextSizeConstraint", { MaxTextSize = if found then 30 else 54, Parent = nameLabel })
	local chance = label({
		Text = formatChance(entry.Chance),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -12, 0, 34),
		TextColor3 = if found then Color3.new(1, 1, 1) else Color3.fromRGB(200, 200, 210),
		StrokeThickness = 2.5,
		ZIndex = 3,
		Parent = card,
	})
	if found then
		-- The chance in the rarity's moving gradient (like the hero billboards).
		HeroConfig.PaintRarityGradient(chance, entry.Rarity)
	end
end

-- One reward picture (big) with its amount.
local function rewardName(reward: IndexConfig.Reward): string
	if reward.Kind == "Money" then
		return "Money"
	elseif reward.Kind == "Fertilizer" then
		return "Fertilizer"
	elseif reward.Kind == "Hero" then
		return reward.Name or "Hero"
	elseif reward.Kind == "Fruit" then
		local def = reward.Id and FruitConfig.Get(reward.Id)
		return if def then def.Name else "Fruit"
	elseif reward.Kind == "Potion" then
		local def = reward.Id and PotionConfig.Get(reward.Id)
		return if def then def.Name else "Potion"
	elseif reward.Kind == "Material" and reward.Key then
		return ItemDisplay.Info(reward.Key).name
	end
	return reward.Kind
end

local function rewardPicture(holder: GuiObject, reward: IndexConfig.Reward)
	local emoji = if reward.Kind == "Money" then "💰" elseif reward.Kind == "Fertilizer" then "🧪" else nil
	if emoji then
		new("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.7, 0.7), Text = emoji, TextScaled = true, Font = FONT, Parent = holder })
		return
	end
	local view = new("ViewportFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = holder })
	if reward.Kind == "Hero" and reward.Name then
		ItemDisplay.FillHeroViewport(view, reward.Name)
	elseif reward.Kind == "Fruit" and reward.Id then
		ItemDisplay.FillFruitViewport(view, reward.Id)
	elseif reward.Kind == "Potion" and reward.Id then
		ItemDisplay.FillPotionViewport(view, reward.Id)
	elseif reward.Kind == "Material" and reward.Key then
		local info = ItemDisplay.Info(reward.Key)
		if info.image then
			ItemDisplay.ShowImage(view, info.image)
		else
			ItemDisplay.FillViewport(view, info.visual, reward.Key)
		end
	end
end

local function drawMilestone(zone: number, index: number, milestone: IndexConfig.Milestone, found: number)
	local need = IndexConfig.Needed(zone, milestone)
	local claimed = IndexConfig.IsClaimed(IndexConfig.ClaimedMask(player, zone), index)
	local ready = not claimed and found >= need
	local col = new("Frame", { Name = "Milestone" .. index, LayoutOrder = index, BackgroundTransparency = 1, Size = UDim2.fromOffset(380, 230), Parent = rewardsRow })

	-- "x/y Found" gold pill.
	local pill = new("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = Color3.fromRGB(70, 60, 30), Parent = col }, { corner(21) })
	stroke(Color3.fromRGB(150, 110, 20), 2.5, true).Parent = pill
	new("Frame", { Size = UDim2.fromScale(math.clamp(found / need, 0, 1), 1), BackgroundColor3 = GOLD, Parent = pill }, {
		corner(21),
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 235, 140), Color3.fromRGB(255, 175, 40)) }),
	})
	label({ Text = ("%d/%d Found"):format(math.min(found, need), need), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.7), ZIndex = 3, Parent = pill })

	-- Reward cards (all rewards of the milestone side by side).
	local cardsRow = new("Frame", { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 120), BackgroundTransparency = 1, Parent = col })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = cardsRow })
	for i, reward in milestone.Rewards do
		local card = new("Frame", { LayoutOrder = i, Size = UDim2.fromOffset(112, 120), BackgroundColor3 = Color3.fromRGB(110, 75, 35), Parent = cardsRow }, { corner(6) })
		stroke(Color3.fromRGB(190, 140, 50), 3, true).Parent = card
		local pic = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 18), Size = UDim2.fromOffset(92, 80), Parent = card })
		rewardPicture(pic, reward)
		local nameL = label({ Text = rewardName(reward), Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 0, 34), TextWrapped = true, StrokeThickness = 2, ZIndex = 3, Parent = card })
		new("UITextSizeConstraint", { MaxTextSize = 18, Parent = nameL })
		local amount = reward.Amount or 1
		label({ Text = if reward.Kind == "Money" then "$" .. HeroConfig.Abbreviate(amount) else "x" .. tostring(amount), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -8, 0, 24), ZIndex = 3, Parent = card })
		if claimed then
			card.BackgroundTransparency = 0.35
		end
	end

	-- State: CLAIM / Claimed ✓ / still locked.
	local stateY = 186
	if claimed then
		label({ Text = "Claimed", TextColor3 = Color3.fromRGB(110, 255, 120), Position = UDim2.fromOffset(0, stateY), Size = UDim2.new(1, 0, 0, 38), StrokeThickness = 2.5, Parent = col })
	elseif ready then
		local button = new("TextButton", { Position = UDim2.new(0.5, -90, 0, stateY), Size = UDim2.fromOffset(180, 42), BackgroundColor3 = TAB_ON, Text = "", Parent = col }, { corner(10) })
		stroke(Color3.fromRGB(25, 110, 35), 3, true).Parent = button
		UIStyle.Button(button)
		local text = label({ Text = "CLAIM!", Size = UDim2.fromScale(1, 1), Parent = button })
		-- Gentle pulse so it gets noticed.
		local pulse = new("UIScale", { Parent = button })
		TweenService:Create(pulse, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.08 }):Play()
		button.Activated:Connect(function()
			if claiming then
				return
			end
			claiming = true
			text.Text = "..."
			local ok, result = pcall(IndexAction.InvokeServer, IndexAction, "Claim", zone, index)
			claiming = false
			if ok and typeof(result) == "table" and result.ok then
				drawZone()
				drawBadge()
				drawTabs()
			else
				text.Text = if ok and typeof(result) == "table" and result.message then result.message else "Try again"
				task.delay(1.5, function()
					if text.Parent then
						text.Text = "CLAIM!"
					end
				end)
			end
		end)
	else
		label({ Text = ("Find %d more"):format(need - found), TextColor3 = Color3.fromRGB(200, 200, 210), Position = UDim2.fromOffset(0, stateY), Size = UDim2.new(1, 0, 0, 34), StrokeThickness = 2, Parent = col })
	end
end

drawZone = function()
	for _, c in grid:GetChildren() do
		if not c:IsA("UIGridLayout") then
			c:Destroy()
		end
	end
	for _, c in rewardsRow:GetChildren() do
		if not c:IsA("UIListLayout") then
			c:Destroy()
		end
	end
	local items = IndexConfig.Items(currentZone)
	for i, entry in items do
		drawCard(entry, i)
	end
	local found = IndexConfig.FoundIn(player, currentZone)
	local milestones = IndexConfig.Rewards[currentZone] or {}
	for i, m in milestones do
		drawMilestone(currentZone, i, m, found)
	end
	local hasRewards = #milestones > 0
	for _, name in { "Divider", "RewardsTitle", "Rewards" } do
		local c = content:FindFirstChild(name) :: GuiObject?
		if c then
			c.Visible = hasRewards
		end
	end
	drawProgress()
end

-- Open / close -------------------------------------------------------------------------------------------

local function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	if open then
		root.Visible = true
		drawTabs()
		drawZone()
		local target = fitScale()
		openScale.Scale = target * 0.85
		tween(openScale, 0.25, { Scale = target }, Enum.EasingStyle.Back)
	else
		root.Visible = false
	end
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("Index", root, function()
	setOpen(false)
end)

closeButton.Activated:Connect(function()
	press(closeButton)
	setOpen(false)
end)

if openButton then
	openButton.Activated:Connect(function()
		setOpen(not isOpen)
	end)
end

if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		if isOpen then
			openScale.Scale = fitScale()
		end
	end)
end

-- Live updates: something found, a reward claimed, a zone unlocked ----------------------------------------

local redrawQueued = false
local function queueRedraw()
	if redrawQueued then
		return
	end
	redrawQueued = true
	task.delay(0.2, function()
		redrawQueued = false
		drawBadge()
		if isOpen then
			drawTabs()
			drawZone()
		end
	end)
end

local function watchFound(folder: Instance)
	folder.ChildAdded:Connect(queueRedraw)
	folder.ChildRemoved:Connect(queueRedraw)
	queueRedraw()
end
local existing = foundFolder()
if existing then
	watchFound(existing)
end
player.ChildAdded:Connect(function(c)
	if c.Name == IndexConfig.FoundFolder then
		watchFound(c)
	end
end)
player.AttributeChanged:Connect(function(name)
	if name == "UnlockedZones" or name:sub(1, #IndexConfig.ClaimedPrefix) == IndexConfig.ClaimedPrefix then
		queueRedraw()
	end
end)

drawBadge()
