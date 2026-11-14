-- IndexUI: the Index (collection book) window, opened by the sidebar's "Index" button
-- (StarterGui.LeftSidebar.Buttons.Index). Rules and rewards: Shared.IndexConfig; server: IndexService.
--
-- The window is the common UIStyle.Window (header, red X, Theme colours, global UIScale, UIManager).
--   Header   "INDEX", a progress bar of everything found in every zone ("95/346 Found  27%"), X.
--   Tabs     one per zone (blue = shown). A red badge = rewards ready to claim in that zone.
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
local Theme = require(script.Parent:WaitForChild("Theme"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local IndexAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("IndexAction") :: RemoteFunction

local FONT = Theme.Font
local C = Theme.Color
local STROKE = C.Stroke
local TAB_ON = C.Secondary -- tabs = blue (Theme: navigation)
local TAB_OFF = C.SurfaceInset
local UNKNOWN_BG = C.SurfaceInset
local GOLD = C.Accent

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
	props.TextColor3 = props.TextColor3 or C.Text
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

local drawZone: () -> () -- defined further down (tabs redraw the zone, OnOpen draws)
local drawTabs: () -> ()

local win = UIStyle.Window({
	Name = "IndexGui",
	Title = "INDEX",
	Size = Vector2.new(1000, UIStyle.HEADER + 584),
	PhoneSize = Vector2.new(760, UIStyle.HEADER_PHONE + 396),
	DisplayOrder = 13,
	OnOpen = function()
		drawTabs()
		drawZone()
	end,
})
local phone = win.phone
local headerH = if phone then UIStyle.HEADER_PHONE else UIStyle.HEADER
local PAD = Theme.Space.L
local COLS = if phone then 5 else 6
local CELL_GAP = if phone then 8 else 10
local TAB_W, TAB_H = if phone then 190 else 240, if phone then 44 else 52
local MILESTONE_W = if phone then 340 else 380
local REWARD_W = if phone then 100 else 112

-- Overall progress bar, in the header between the title and X.
local BAR_X = PAD + (if phone then 90 else 120)
local bar = new("Frame", {
	Name = "Progress",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, BAR_X, 0.5, 0),
	Size = UDim2.new(1, -(BAR_X + headerH + PAD), 0, headerH - 16),
	BackgroundColor3 = C.SurfaceInset,
	ClipsDescendants = true,
	Parent = win.header,
}, { corner(Theme.Radius.Button) })
stroke(C.PrimaryDark, 2, true).Parent = bar
local barFill = new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Primary, Parent = bar }, { corner(Theme.Radius.Button) })
local barText = label({ Text = "0/0 Found", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.6, 0, 0.7, 0), ZIndex = 3, Parent = bar })
local barPct = label({ Text = "0%", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -Theme.Space.M, 0.5, 0), Size = UDim2.new(0.16, 0, 0.62, 0), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 3, Parent = bar })

-- Zone tabs (scroll sideways when there are many zones).
local tabs = new("ScrollingFrame", {
	Name = "Tabs",
	Position = UDim2.fromOffset(PAD, 0),
	Size = UDim2.new(1, -PAD * 2, 0, TAB_H + 10),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = C.TextDim,
	ScrollingDirection = Enum.ScrollingDirection.X,
	AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(),
	Parent = win.body,
})
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, Theme.Space.S), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = tabs })
new("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2), Parent = tabs })

-- Content: the item grid, then the rewards.
local contentTop = TAB_H + 10 + Theme.Space.S
local content = new("ScrollingFrame", {
	Name = "Content",
	Position = UDim2.fromOffset(PAD, contentTop),
	Size = UDim2.new(1, -PAD, 1, -contentTop),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = C.TextDim,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Parent = win.body,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, Theme.Space.M), HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = content })
-- Right padding keeps the cards clear of the scrollbar; bottom padding lets the last row scroll fully in.
new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, PAD), PaddingBottom = UDim.new(0, PAD + 8), Parent = content })

local grid = new("Frame", { Name = "Grid", LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = content })
local gridLayout = new("UIGridLayout", { CellPadding = UDim2.fromOffset(CELL_GAP, CELL_GAP), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
local function sizeCells()
	-- AbsoluteSize includes the window's UIScale; cells are in design px.
	local width = grid.AbsoluteSize.X / math.max(win.scale.Scale, 0.01)
	local cell = math.max(60, math.floor((width - CELL_GAP * (COLS - 1)) / COLS))
	gridLayout.CellSize = UDim2.fromOffset(cell, cell)
end
grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeCells)
sizeCells()

new("Frame", { Name = "Divider", LayoutOrder = 2, Size = UDim2.new(1, -24, 0, 3), BackgroundColor3 = C.TextDim, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = content })
label({ Name = "RewardsTitle", LayoutOrder = 3, Text = "REWARDS", Size = UDim2.fromOffset(300, if phone then 36 else 44), Parent = content })
local rewardsRow = new("Frame", { Name = "Rewards", LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 230), Parent = content })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, if phone then Theme.Space.L else 40), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rewardsRow })

-- State ---------------------------------------------------------------------------------------------


local zones = IndexConfig.Zones()
local currentZone = zones[1] or 1
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

drawTabs = function()
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
			Size = UDim2.fromOffset(TAB_W, TAB_H),
			BackgroundColor3 = if on then TAB_ON else TAB_OFF,
			Text = "",
			AutoButtonColor = false,
			Parent = tabs,
		}, { corner(Theme.Radius.Button) })
		stroke(if on then C.SecondaryDark else C.Stroke, 2, true).Parent = tab
		UIStyle.Button(tab) -- tabs sit in a list: corners + gloss, no lip
		label({
			Text = if locked then "🔒 " .. name else name,
			TextColor3 = if locked or not on then C.TextDim else C.Text,
			Position = UDim2.fromOffset(Theme.Space.M, Theme.Space.S),
			Size = UDim2.new(1, -(Theme.Space.M + TAB_H), 1, -Theme.Space.S * 2),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = tab,
		})
		local ready = IndexConfig.Claimable(player, zone)
		if ready > 0 then
			local size = TAB_H - 20
			local b = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -Theme.Space.S, 0.5, 0), Size = UDim2.fromOffset(size, size), BackgroundColor3 = C.Danger, Parent = tab }, { corner(size // 2) })
			stroke(C.DangerDark, 2, true).Parent = b
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
	}, { corner(Theme.Radius.Chip) })
	stroke(if found then slotColor:Lerp(Color3.new(1, 1, 1), 0.45) else slotColor:Lerp(Color3.new(0, 0, 0), 0.35), 3, true).Parent = card
	picture(card, entry, found)
	local nameLabel = label({
		Text = if found then entry.Name else "???",
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(0.92, 0, 0.36, 0),
		TextWrapped = true,
		TextColor3 = if found then C.Text else C.TextDim,
		StrokeThickness = 2.5,
		ZIndex = 3,
		Parent = card,
	})
	new("UITextSizeConstraint", { MaxTextSize = if found then 30 else 54, Parent = nameLabel })
	local chance = label({
		Text = formatChance(entry.Chance),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(0.92, 0, 0.22, 0),
		TextColor3 = if found then C.Text else C.TextDim,
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
	local col = new("Frame", { Name = "Milestone" .. index, LayoutOrder = index, BackgroundTransparency = 1, Size = UDim2.fromOffset(MILESTONE_W, 230), Parent = rewardsRow })

	-- "x/y Found" gold pill.
	local pill = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.SurfaceInset, ClipsDescendants = true, Parent = col }, { corner(Theme.Radius.Button) })
	stroke(C.AccentDark, 2, true).Parent = pill
	new("Frame", { Size = UDim2.fromScale(math.clamp(found / need, 0, 1), 1), BackgroundColor3 = GOLD, Parent = pill }, { corner(Theme.Radius.Button) })
	label({ Text = ("%d/%d Found"):format(math.min(found, need), need), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.7), ZIndex = 3, Parent = pill })

	-- Reward cards (all rewards of the milestone side by side).
	local cardsRow = new("Frame", { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 120), BackgroundTransparency = 1, Parent = col })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = cardsRow })
	for i, reward in milestone.Rewards do
		local card = new("Frame", { LayoutOrder = i, Size = UDim2.fromOffset(REWARD_W, 120), BackgroundColor3 = C.SurfaceInset, Parent = cardsRow }, { corner(Theme.Radius.Chip) })
		stroke(C.AccentDark, 2, true).Parent = card
		local pic = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0.5, -40, 0, 18), Size = UDim2.fromOffset(80, 80), Parent = card })
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
		label({ Text = "Claimed ✓", TextColor3 = C.Primary, Position = UDim2.fromOffset(0, stateY), Size = UDim2.new(1, 0, 0, 36), Parent = col })
	elseif ready then
		local button = new("TextButton", { Position = UDim2.new(0.5, -90, 0, stateY), Size = UDim2.fromOffset(180, 44), BackgroundColor3 = C.Primary, Text = "", Parent = col }, { corner(Theme.Radius.Button) })
		stroke(C.PrimaryDark, 2, true).Parent = button
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
		label({ Text = ("Find %d more"):format(need - found), TextColor3 = C.TextDim, Position = UDim2.fromOffset(0, stateY), Size = UDim2.new(1, 0, 0, 34), StrokeThickness = 2, Parent = col })
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

-- The window (UIStyle.Window) owns open / close, X and UIManager; OnOpen draws the zone.
if openButton then
	openButton.Activated:Connect(function()
		if win.IsOpen() then
			win.Close()
		else
			win.Open()
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
		if win.IsOpen() then
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
