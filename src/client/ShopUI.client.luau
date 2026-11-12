-- ShopUI: the shop windows, opened from the shops' "ShopPrompt" (ShopService / ShopConfig).
--
-- Sell ("Sell Items!"): a card per stack in player.Inventory (materials) and player.Heroes. Click a
--   card to tick / untick it. "Select All" only ticks materials; heroes are only sold when you tick
--   them yourself, and heroes standing on a pad are kept. "Sell for $X" sells every ticked stack.
-- Lumber Axe ("Lumber Axe!"): a card per axe (ShopConfig.Axes) with its model, damage and price.
--   Click to buy (then it is equipped) or to equip one you own.
-- The window closes with X or when you walk ShopConfig.CloseDistance away from the shop.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local ShopAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ShopAction") :: RemoteFunction

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local PANEL_COLOR = Color3.fromRGB(38, 40, 50)
local PANEL_STROKE = Color3.fromRGB(78, 80, 92)
local CLOSE_COLOR = Color3.fromRGB(214, 92, 28)
local RED_BUTTON = Color3.fromRGB(150, 38, 44)
local GREEN_BUTTON = Color3.fromRGB(36, 132, 66)
local GREY_BUTTON = Color3.fromRGB(80, 82, 92)
local BLUE_BUTTON = Color3.fromRGB(40, 110, 210)
local CHECK_COLOR = Color3.fromRGB(90, 230, 70)
local VALUE_GREEN = ItemDisplay.MATERIAL_VALUE_COLOR
local HERO_PREFIX = ItemDisplay.HERO_PREFIX

local abbreviate = ItemDisplay.Abbreviate

-- Small UI helpers ---------------------------------------------------------------------------------

local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(radius: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local thickness = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local label = new("TextLabel", props)
	stroke(Color3.fromRGB(20, 20, 24), thickness).Parent = label
	return label
end

local function button(props: { [string]: any }): TextButton
	local b = new("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = props.Color,
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		Text = props.Text,
		Position = props.Position,
		Size = props.Size,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Parent = props.Parent,
	}, {
		corner(4),
		new("UIPadding", { PaddingTop = UDim.new(0.2, 0), PaddingBottom = UDim.new(0.2, 0), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	stroke(props.Color:Lerp(Color3.new(1, 1, 1), 0.25), 2, true).Parent = b
	stroke(Color3.fromRGB(20, 20, 24), 1.5).Parent = b
	return b
end

local function pop(inst: GuiObject)
	local scale = inst:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = inst })
	scale.Scale = 0.92
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Window frame ------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "ShopGui",
	DisplayOrder = 12,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

type Window = {
	root: Frame,
	scale: UIScale,
	grid: ScrollingFrame,
	leftButton: TextButton,
	rightButton: TextButton,
	footerText: TextLabel,
	toast: TextLabel,
}

local function makeWindow(name: string, title: string, gradient: ColorSequence, header: string, subtitle: string): Window
	local root = new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromScale(0.46, 0.68),
		BackgroundColor3 = PANEL_COLOR,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = gui,
	}, {
		corner(6),
		new("UIAspectRatioConstraint", { AspectRatio = 1.2 }),
		new("UISizeConstraint", { MinSize = Vector2.new(380, 316) }),
	})
	stroke(PANEL_STROKE, 2, true).Parent = root
	local scale = new("UIScale", { Parent = root })

	local titleLabel = text({
		Name = "Title",
		Text = title,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, -0.005),
		Size = UDim2.fromScale(0.75, 0.13),
		StrokeThickness = 3,
		Parent = root,
	})
	new("UIGradient", { Color = gradient, Rotation = 90, Parent = titleLabel })

	text({ Name = "Header", Text = header, Position = UDim2.fromScale(0.035, 0.03), Size = UDim2.fromScale(0.2, 0.075), TextXAlignment = Enum.TextXAlignment.Left, Parent = root })
	text({
		Name = "Subtitle",
		Text = subtitle,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.52, 0.035),
		Size = UDim2.fromScale(0.56, 0.06),
		TextColor3 = Color3.fromRGB(150, 152, 160),
		Parent = root,
	})
	local close = button({ Text = "X", Color = CLOSE_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.97, 0.025), Size = UDim2.fromScale(0.075, 0.085), Parent = root })
	close.Name = "Close"

	local grid = new("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromScale(0.035, 0.14),
		Size = UDim2.fromScale(0.93, 0.68),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(120, 122, 132),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = root,
	}, {
		new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 4) }),
	})
	new("UIGridLayout", {
		CellSize = UDim2.new(0.185, 0, 0, 10),
		CellPadding = UDim2.new(0.0175, 0, 0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	}, { new("UIAspectRatioConstraint", { AspectRatio = 1 }) })

	local leftButton = button({ Text = "", Color = RED_BUTTON, Position = UDim2.fromScale(0.035, 0.85), Size = UDim2.fromScale(0.31, 0.105), Parent = root })
	local rightButton = button({ Text = "", Color = GREEN_BUTTON, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.965, 0.85), Size = UDim2.fromScale(0.42, 0.105), Parent = root })
	local footerText = text({ Name = "Footer", Text = "", Position = UDim2.fromScale(0.035, 0.865), Size = UDim2.fromScale(0.5, 0.07), TextXAlignment = Enum.TextXAlignment.Left, Visible = false, Parent = root })
	local toast = text({
		Name = "Toast",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1.02),
		Size = UDim2.fromScale(0.6, 0.08),
		TextColor3 = VALUE_GREEN,
		TextTransparency = 1,
		Parent = root,
	})
	local toastStroke = toast:FindFirstChildOfClass("UIStroke") :: UIStroke
	toastStroke.Transparency = 1

	local window: Window = { root = root, scale = scale, grid = grid, leftButton = leftButton, rightButton = rightButton, footerText = footerText, toast = toast }
	close.Activated:Connect(function()
		root.Visible = false
	end)
	return window
end

local function showToast(w: Window, message: string, color: Color3)
	local label = w.toast
	local s = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	label.Text = message
	label.TextColor3 = color
	label.TextTransparency = 0
	s.Transparency = 0
	local info = TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 1.4)
	TweenService:Create(label, info, { TextTransparency = 1 }):Play()
	TweenService:Create(s, info, { Transparency = 1 }):Play()
end

-- A card: rarity background, picture, name on top, value + amount at the bottom, check mark.
local function makeCard(parent: Instance, order: number, rarity: string): TextButton
	local color = ItemDisplay.SlotColor(rarity)
	local card = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = color,
		LayoutOrder = order,
		Parent = parent,
	}, {
		corner(4),
		new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }),
		new("ImageLabel", { Name = "Image", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop, Visible = false }),
		new("TextLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.48),
			Size = UDim2.fromScale(0.5, 0.5),
			Font = FONT,
			Text = "★",
			TextScaled = true,
			TextColor3 = Color3.fromRGB(255, 230, 120),
			Visible = false,
		}),
	})
	stroke(color:Lerp(Color3.new(1, 1, 1), 0.35), 2.5, true).Parent = card
	return card
end

local function cardText(card: Instance, name: string, value: string, valueColor: Color3, amount: string?)
	text({ Name = "NameLabel", Text = name, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.05), Size = UDim2.fromScale(0.92, 0.22), ZIndex = 3, Parent = card })
	text({ Name = "ValueLabel", Text = value, TextColor3 = valueColor, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.fromScale(0.92, 0.2), ZIndex = 3, Parent = card })
	if amount then
		text({ Name = "AmountLabel", Text = amount, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.83), Size = UDim2.fromScale(0.6, 0.15), ZIndex = 3, Parent = card })
	end
end

-- Shop state --------------------------------------------------------------------------------------

local current: { kind: string, prompt: ProximityPrompt?, anchor: BasePart? }? = nil

local sellWindow = makeWindow("Sell", "Sell Items!", ColorSequence.new(Color3.fromRGB(150, 255, 90), Color3.fromRGB(40, 200, 60)), "Sell", "~ Sell your items for cash ~")
local axeWindow = makeWindow("LumberAxe", "Lumber Axe!", ColorSequence.new(Color3.fromRGB(255, 235, 110), Color3.fromRGB(240, 150, 40)), "Axes", "~ Better axes chop harder ~")

local function folder(name: string): Instance?
	return player:FindFirstChild(name)
end

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild("Money")
	return if v and v:IsA("ValueBase") then (v :: any).Value else 0
end

-- Heroes standing on my plot's pads (HeroSlotService writes each slot's "HeroId").
local function placedHeroes(): { [string]: number }
	local counts = {}
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local slots = plot:FindFirstChild("HeroSlots")
			for _, slot in if slots then slots:GetChildren() else {} do
				local hero = slot:GetAttribute("HeroId")
				if typeof(hero) == "string" and hero ~= "" then
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
		end
	end
	return counts
end

-- Sell window ---------------------------------------------------------------------------------------

type SellEntry = { stack: string, isHero: boolean, amount: number, total: number, rarity: string }

local selected: { [string]: boolean } = {}
local entries: { [string]: SellEntry } = {}
local busy = false

local function sellEntries(): { SellEntry }
	local list: { SellEntry } = {}
	local inventory = folder("Inventory")
	for _, v in if inventory then inventory:GetChildren() else {} do
		local def = v:IsA("IntValue") and TreeConfig.Materials[v.Name]
		if def and (v :: IntValue).Value > 0 then
			local amount = (v :: IntValue).Value
			table.insert(list, { stack = v.Name, isHero = false, amount = amount, total = def.Value * amount, rarity = def.Rarity })
		end
	end
	local heroes = folder("Heroes")
	local placed = placedHeroes()
	for _, v in if heroes then heroes:GetChildren() else {} do
		local hero = v:IsA("IntValue") and TreeConfig.GetHero(v.Name)
		if hero and (v :: IntValue).Value > 0 then
			local amount = math.max(0, (v :: IntValue).Value - (placed[v.Name] or 0))
			table.insert(list, {
				stack = HERO_PREFIX .. v.Name,
				isHero = true,
				amount = amount,
				total = hero.MinePower * ShopConfig.HeroSellMultiplier * amount,
				rarity = hero.Rarity,
			})
		end
	end
	-- Materials first, then heroes; rarest first, then most valuable.
	table.sort(list, function(a, b)
		if a.isHero ~= b.isHero then
			return not a.isHero
		end
		local ra, rb = TreeConfig.RarityOrder[a.rarity] or 99, TreeConfig.RarityOrder[b.rarity] or 99
		if ra ~= rb then
			return ra < rb
		end
		return a.total > b.total
	end)
	return list
end

local function selectedTotal(): number
	local total = 0
	for stack in selected do
		local e = entries[stack]
		if e then
			total += e.total
		end
	end
	return total
end

local function updateSellFooter()
	local any = next(selected) ~= nil
	sellWindow.leftButton.Text = if any then "Deselect All" else "Select All"
	sellWindow.leftButton.BackgroundColor3 = if any then RED_BUTTON else GREEN_BUTTON
	local total = selectedTotal()
	sellWindow.rightButton.Text = if total > 0 then ("Sell for $%s"):format(abbreviate(total)) else "Sell"
	sellWindow.rightButton.BackgroundColor3 = if total > 0 then GREEN_BUTTON else GREY_BUTTON
end

local function drawCheck(card: Instance, on: boolean)
	local check = card:FindFirstChild("Check") :: TextLabel?
	local tint = card:FindFirstChild("Tint") :: Frame?
	if check then
		check.Visible = on
	end
	if tint then
		tint.Visible = on
	end
end

local function renderSell()
	for _, c in sellWindow.grid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	entries = {}
	local list = sellEntries()
	for i, e in list do
		entries[e.stack] = e
		local info = ItemDisplay.Info(e.stack)
		local card = makeCard(sellWindow.grid, i, e.rarity)
		ItemDisplay.SetPicture(card, info)
		local sellable = e.amount > 0
		cardText(card, info.name, if sellable then "$" .. abbreviate(e.total) else "On Pad", if sellable then VALUE_GREEN else Color3.fromRGB(255, 200, 80), "x" .. ItemDisplay.Commas(e.amount))
		new("Frame", { Name = "Tint", BackgroundColor3 = CHECK_COLOR, BackgroundTransparency = 0.75, Size = UDim2.fromScale(1, 1), ZIndex = 2, Visible = false, Parent = card }, { corner(4) })
		local check = text({ Name = "Check", Text = "✓", TextColor3 = CHECK_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1.02, -0.04), Size = UDim2.fromScale(0.42, 0.42), ZIndex = 4, Visible = false, StrokeThickness = 2.5, Parent = card })
		check.Font = Enum.Font.GothamBlack
		if not sellable then
			selected[e.stack] = nil
			card.BackgroundTransparency = 0.4
		end
		drawCheck(card, selected[e.stack] == true)
		card.Activated:Connect(function()
			if not sellable then
				return
			end
			selected[e.stack] = if selected[e.stack] then nil else true
			drawCheck(card, selected[e.stack] == true)
			pop(card)
			updateSellFooter()
		end)
	end
	-- Drop ticks for stacks that are gone.
	for stack in selected do
		if not entries[stack] then
			selected[stack] = nil
		end
	end
	updateSellFooter()
end

local function selectAllMaterials()
	for stack, e in entries do
		if not e.isHero and e.amount > 0 then
			selected[stack] = true
		end
	end
end

sellWindow.leftButton.Activated:Connect(function()
	if next(selected) ~= nil then
		table.clear(selected)
	else
		selectAllMaterials()
	end
	renderSell()
	pop(sellWindow.leftButton)
end)

sellWindow.rightButton.Activated:Connect(function()
	if busy or selectedTotal() <= 0 then
		return
	end
	busy = true
	pop(sellWindow.rightButton)
	local ok, result = pcall(ShopAction.InvokeServer, ShopAction, "Sell", selected)
	busy = false
	if ok and result and result.ok then
		table.clear(selected)
		showToast(sellWindow, ("+$%s"):format(abbreviate(result.earned or 0)), VALUE_GREEN)
	else
		showToast(sellWindow, if ok and result and result.message then result.message else "Could not sell", Color3.fromRGB(255, 90, 80))
	end
	renderSell()
end)

-- Axe window ----------------------------------------------------------------------------------------

local function owns(model: string): boolean
	local axes = folder("Axes")
	local v = axes and axes:FindFirstChild(model)
	return v ~= nil and v:IsA("BoolValue") and v.Value
end

local function axeViewport(view: ViewportFrame, model: string)
	view:ClearAllChildren()
	local axes = ReplicatedStorage:FindFirstChild("Axes")
	local source = axes and axes:FindFirstChild(model)
	if not source or not source:IsA("Model") then
		return
	end
	local m = source:Clone()
	local bbox, size = m:GetBoundingBox()
	-- Centre it at the origin, tilted like it's being swung.
	m:PivotTo(CFrame.Angles(0, 0, math.rad(-28)) * bbox:ToObjectSpace(m:GetPivot()))
	m.Parent = view
	local fov = 40
	local reach = math.max(size.X, size.Y) * 0.62
	local camera = new("Camera", { FieldOfView = fov, Parent = view })
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0.2, reach / math.tan(math.rad(fov / 2))), Vector3.new(0, 0.2, 0))
	view.CurrentCamera = camera
	view.Visible = true
end

local function equipped(): string?
	return player:GetAttribute("EquippedAxe")
end

local function renderAxes()
	for _, c in axeWindow.grid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local current_ = equipped()
	for i, def in ShopConfig.Axes do
		local card = makeCard(axeWindow.grid, i, def.Rarity)
		local view = card:FindFirstChild("View") :: ViewportFrame
		view.Position = UDim2.fromScale(0, 0.12)
		view.Size = UDim2.fromScale(1, 0.62)
		axeViewport(view, def.Model)
		local have = owns(def.Model)
		local state = if def.Model == current_ then "Equipped" elseif have then "Equip" else "$" .. abbreviate(def.Price)
		local stateColor = if def.Model == current_ then Color3.fromRGB(255, 255, 255) elseif have then Color3.fromRGB(120, 200, 255) else VALUE_GREEN
		cardText(card, def.Name, state, stateColor, ("%s Damage"):format(abbreviate(def.Damage)))
		if def.Model == current_ then
			new("Frame", { Name = "Tint", BackgroundColor3 = CHECK_COLOR, BackgroundTransparency = 0.75, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = card }, { corner(4) })
		end
		card.Activated:Connect(function()
			if busy or def.Model == equipped() then
				return
			end
			busy = true
			pop(card)
			local action = if owns(def.Model) then "EquipAxe" else "BuyAxe"
			local ok, result = pcall(ShopAction.InvokeServer, ShopAction, action, def.Model)
			busy = false
			if ok and result and result.ok then
				showToast(axeWindow, ("%s equipped!"):format(def.Name), VALUE_GREEN)
			else
				showToast(axeWindow, if ok and result and result.message then result.message else "Could not buy", Color3.fromRGB(255, 90, 80))
			end
			renderAxes()
		end)
	end
	local def = current_ and ShopConfig.GetAxe(current_)
	axeWindow.footerText.Text = if def then ("Equipped: %s (%s Damage)"):format(def.Name, abbreviate(def.Damage)) else ""
	axeWindow.rightButton.Text = ("Cash: $%s"):format(abbreviate(money()))
end

axeWindow.leftButton.Visible = false
axeWindow.footerText.Visible = true
axeWindow.rightButton.AutoButtonColor = false

-- Opening / closing ---------------------------------------------------------------------------------

local windows = { Sell = sellWindow, LumberAxe = axeWindow }
local watchers: { RBXScriptConnection } = {}

local function closeAll()
	for _, w in windows do
		w.root.Visible = false
	end
end

local function onClosed()
	for _, c in watchers do
		c:Disconnect()
	end
	table.clear(watchers)
	if current and current.prompt then
		current.prompt.Enabled = true
	end
	current = nil
end

local function watch(inst: Instance?, fn: () -> ())
	if not inst then
		return
	end
	table.insert(watchers, inst.ChildAdded:Connect(fn))
	table.insert(watchers, inst.ChildRemoved:Connect(fn))
	for _, v in inst:GetChildren() do
		if v:IsA("ValueBase") then
			table.insert(watchers, (v :: any).Changed:Connect(fn))
		end
	end
end

local function open(kind: string, prompt: ProximityPrompt?)
	local w = windows[kind]
	if not w then
		return
	end
	closeAll()
	onClosed()
	current = { kind = kind, prompt = prompt, anchor = prompt and prompt.Parent :: BasePart }
	if prompt then
		prompt.Enabled = false -- hide it while the window is open
	end
	if kind == "Sell" then
		table.clear(selected)
		entries = {}
		for _, e in sellEntries() do
			entries[e.stack] = e
		end
		selectAllMaterials()
		renderSell()
		local refresh = function()
			if not busy then
				renderSell()
			end
		end
		watch(folder("Inventory"), refresh)
		watch(folder("Heroes"), refresh)
	else
		renderAxes()
		table.insert(watchers, player:GetAttributeChangedSignal("EquippedAxe"):Connect(renderAxes))
		watch(folder("Axes"), renderAxes)
		local stats = player:FindFirstChild("leaderstats")
		local m = stats and stats:FindFirstChild("Money")
		if m then
			table.insert(watchers, (m :: any).Changed:Connect(function()
				axeWindow.rightButton.Text = ("Cash: $%s"):format(abbreviate(money()))
			end))
		end
	end
	w.root.Visible = true
	w.scale.Scale = 0.6
	TweenService:Create(w.scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	table.insert(watchers, w.root:GetPropertyChangedSignal("Visible"):Connect(function()
		if not w.root.Visible then
			onClosed()
		end
	end))
end

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name ~= "ShopPrompt" then
		return
	end
	local kind = prompt:GetAttribute("Shop")
	if typeof(kind) == "string" then
		open(kind, prompt)
	end
end)

-- Walked away: close.
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.25 or not current then
		return
	end
	acc = 0
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = current.anchor
	if not root or (anchor and (root.Position - anchor.Position).Magnitude > ShopConfig.CloseDistance) then
		closeAll()
	end
end)
