-- ShopUI: the shop windows, opened from the shops' "ShopPrompt" (ShopService / ShopConfig).
--
-- (Selling moved: materials are sold at the Farm Stand, heroes from the Inventory window.)
-- Lumber Axe ("Lumber Axe!"): a card per axe (ShopConfig.Axes) with its model, damage and price.
--   Click to buy (then it is equipped) or to equip one you own. Each axe shows its server-wide stock
--   (ReplicatedStorage.AxeStock, "Sold Out" at 0) and is locked until the player has unlocked its
--   Zone; the subtitle counts down to the next restock (AxeStock "NextRestock").
-- The window closes with X or when you walk ShopConfig.CloseDistance away from the shop.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))
local ShopAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ShopAction") :: RemoteFunction

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local PANEL_COLOR = Color3.fromRGB(38, 40, 50)
local PANEL_STROKE = Color3.fromRGB(78, 80, 92)
local CLOSE_COLOR = UIStyle.CLOSE_COLOR
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
	UIStyle.Button(b)
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
	subtitle: TextLabel,
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
	UIStyle.Panel(root)
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
	local subtitleLabel = text({
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
	UIStyle.Close(close)

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
	-- 5 square cards per row, sized in pixels from the grid's width (scale cell sizes collapse inside
	-- an auto-sized ScrollingFrame).
	local gridLayout = new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local function sizeCells()
		local width = grid.AbsoluteSize.X - 16 - grid.ScrollBarThickness
		local gap = math.max(4, math.floor(width * 0.02))
		local cell = math.max(20, math.floor((width - gap * 4) / 5))
		gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		gridLayout.CellSize = UDim2.fromOffset(cell, cell)
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeCells)
	sizeCells()

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

	local window: Window = { root = root, subtitle = subtitleLabel, scale = scale, grid = grid, leftButton = leftButton, rightButton = rightButton, footerText = footerText, toast = toast }
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

local SOLD_OUT_COLOR = Color3.fromRGB(255, 90, 80)
local LOCKED_COLOR = Color3.fromRGB(190, 190, 200)
local STOCK_COLOR = Color3.fromRGB(255, 220, 90)

-- Lumber Axe window (card style): dark panel, striped header, a vertical grid of rarity cards with a
-- stud backdrop and a still axe model, stock + restock timer in the info bar.
local AXE_HEADER = ColorSequence.new(Color3.fromRGB(255, 170, 40), Color3.fromRGB(235, 95, 20))
local AXE_COLUMNS = 3
local AXE_CARD_ASPECT = 0.68 -- card width / height

local function makeAxeWindow(): Window
	local root = new("Frame", {
		Name = "LumberAxe",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromScale(0.62, 0.78),
		BackgroundColor3 = Color3.fromRGB(18, 18, 22),
		Visible = false,
		Parent = gui,
	}, {
		corner(18),
		new("UIAspectRatioConstraint", { AspectRatio = 1.45 }),
		new("UISizeConstraint", { MinSize = Vector2.new(400, 276), MaxSize = Vector2.new(1100, 760) }),
	})
	stroke(Color3.fromRGB(10, 10, 12), 5, true).Parent = root
	local scale = new("UIScale", { Parent = root })

	-- Header: gradient strip with diagonal light stripes, title on the left, X on the right.
	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.fromScale(1, 0.13),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ClipsDescendants = true,
		Parent = root,
	}, {
		corner(16),
		new("UIGradient", { Color = AXE_HEADER, Rotation = 90 }),
	})
	-- Square bottom edge under the rounded header.
	new("Frame", {
		Name = "Base",
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromScale(1, 0.5),
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = header,
	}, { new("UIGradient", { Color = AXE_HEADER, Rotation = 90, Offset = Vector2.new(0, 0.5) }) })
	for i = 0, 5 do
		new("Frame", {
			Name = "Stripe",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.42 + i * 0.045, 0.5),
			Size = UDim2.new(0.018, 0, 2.2, 0),
			Rotation = 25,
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.82,
			ZIndex = 2,
			Parent = header,
		})
	end
	-- Lighter band across the top half.
	new("Frame", {
		Name = "Shine",
		Size = UDim2.fromScale(1, 0.45),
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.88,
		ZIndex = 2,
		Parent = header,
	})
	text({
		Name = "Title",
		Text = "Axe Shop",
		Position = UDim2.fromScale(0.03, 0.14),
		Size = UDim2.fromScale(0.5, 0.74),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 4,
		ZIndex = 3,
		Parent = header,
	})
	local close = new("TextButton", {
		Name = "Close",
		Text = "X",
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = Color3.fromRGB(205, 25, 25),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromScale(0.07, 0.8),
		ZIndex = 3,
		Parent = header,
	}, {
		corner(10),
		new("UIAspectRatioConstraint", { AspectRatio = 1.12 }),
		new("UIPadding", { PaddingTop = UDim.new(0.16, 0), PaddingBottom = UDim.new(0.16, 0) }),
	})
	stroke(Color3.fromRGB(10, 10, 12), 3, true).Parent = close
	stroke(Color3.fromRGB(10, 10, 12), 2.5).Parent = close
	UIStyle.Close(close)

	-- Info bar: restock timer | axes in stock | cash.
	local info = new("Frame", {
		Name = "Info",
		Position = UDim2.fromScale(0.025, 0.155),
		Size = UDim2.fromScale(0.95, 0.075),
		BackgroundColor3 = Color3.fromRGB(40, 41, 48),
		Parent = root,
	}, { corner(10) })
	stroke(Color3.fromRGB(10, 10, 12), 2, true).Parent = info
	local restock = text({
		Name = "Restock",
		Text = "",
		TextColor3 = STOCK_COLOR,
		Position = UDim2.fromScale(0.02, 0.15),
		Size = UDim2.fromScale(0.36, 0.7),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = info,
	})
	local inStock = text({
		Name = "InStock",
		Text = "",
		TextColor3 = Color3.fromRGB(120, 230, 255),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.15),
		Size = UDim2.fromScale(0.3, 0.7),
		Parent = info,
	})
	local cash = new("TextButton", {
		Name = "Cash",
		Text = "",
		AutoButtonColor = false,
		Active = false,
		BackgroundTransparency = 1,
		Font = FONT,
		TextScaled = true,
		TextColor3 = VALUE_GREEN,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.98, 0.15),
		Size = UDim2.fromScale(0.3, 0.7),
		Parent = info,
	})
	stroke(Color3.fromRGB(20, 20, 24), 2).Parent = cash

	local grid = new("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromScale(0.025, 0.25),
		Size = UDim2.fromScale(0.95, 0.72),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Color3.fromRGB(120, 122, 132),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = root,
	}, {
		new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 16), PaddingBottom = UDim.new(0, 10) }),
	})
	local gridLayout = new("UIGridLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local function sizeCells()
		local width = grid.AbsoluteSize.X - 22 - grid.ScrollBarThickness
		local gap = math.max(6, math.floor(width * 0.025))
		local cell = math.max(40, math.floor((width - gap * (AXE_COLUMNS - 1)) / AXE_COLUMNS))
		gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		gridLayout.CellSize = UDim2.fromOffset(cell, math.floor(cell / AXE_CARD_ASPECT))
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeCells)
	sizeCells()

	local toast = text({
		Name = "Toast",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1.02),
		Size = UDim2.fromScale(0.6, 0.07),
		TextColor3 = VALUE_GREEN,
		TextTransparency = 1,
		Parent = root,
	})
	;(toast:FindFirstChildOfClass("UIStroke") :: UIStroke).Transparency = 1

	-- Unused parts of the shared Window shape.
	local dummyButton = new("TextButton", { Name = "Unused", Visible = false, Parent = root })
	local dummyText = new("TextLabel", { Name = "UnusedFooter", Visible = false, Parent = root })
	inStock:SetAttribute("Role", "InStock")

	close.Activated:Connect(function()
		root.Visible = false
	end)
	return {
		root = root,
		subtitle = restock,
		scale = scale,
		grid = grid,
		leftButton = dummyButton,
		rightButton = cash,
		footerText = dummyText,
		toast = toast,
	}
end

local axeWindow = makeAxeWindow()
local renderAxes: () -> ()

local function folder(name: string): Instance?
	return player:FindFirstChild(name)
end

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild("Money")
	return if v and v:IsA("ValueBase") then (v :: any).Value else 0
end

local busy = false

-- Axe window ----------------------------------------------------------------------------------------

local function owns(model: string): boolean
	local axes = folder("Axes")
	local v = axes and axes:FindFirstChild(model)
	return v ~= nil and v:IsA("BoolValue") and v.Value
end


local function equipped(): string?
	return player:GetAttribute("EquippedAxe")
end

local AXE_SUBTITLE = "~ Better axes chop harder ~"

local function stockFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("AxeStock")
end

local function stockOf(model: string): number
	local f = stockFolder()
	local v = f and f:FindFirstChild(model)
	return if v and v:IsA("IntValue") then v.Value else 0
end

local function unlockedZones(): number
	local n = player:GetAttribute("UnlockedZones")
	return if typeof(n) == "number" then n else 1
end

local function restockText(): string
	local f = stockFolder()
	local at = f and f:GetAttribute("NextRestock")
	if typeof(at) ~= "number" then
		return AXE_SUBTITLE
	end
	local left = math.max(0, math.ceil(at - workspace:GetServerTimeNow()))
	return ("Restock in %d:%02d"):format(left // 60, left % 60)
end

-- Axe models in the cards: a still pose (no per-frame spin: re-posing a model makes its
-- ViewportFrame re-render every frame, which was the shop lag). Each axe's ViewportFrame is built
-- once and cached; renderAxes detaches the cached views before destroying the old cards and
-- reuses them, so a stock / money update never re-clones the models.
local AXE_POSE = CFrame.Angles(0, math.rad(35), 0) * CFrame.Angles(0, 0, math.rad(-22))
local axeViews: { [string]: ViewportFrame } = {}

local function axeViewport(model: string): ViewportFrame?
	local cached = axeViews[model]
	if cached then
		cached.ImageColor3 = Color3.new(1, 1, 1)
		cached.ImageTransparency = 0
		local picture = cached:FindFirstChild("Picture") :: ImageLabel?
		if picture then
			picture.ImageColor3 = Color3.new(1, 1, 1)
			picture.ImageTransparency = 0
		end
		return cached
	end
	-- Uploaded icon (ShopConfig AxeImage): no model to clone.
	local axe = ShopConfig.GetAxe(model)
	if axe and axe.AxeImage then
		local view = new("ViewportFrame", {
			Name = "View",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.2),
			Size = UDim2.fromScale(0.95, 0.5),
			ZIndex = 2,
		})
		ItemDisplay.ShowAxeImage(view, model)
		axeViews[model] = view
		return view
	end
	local axes = ReplicatedStorage:FindFirstChild("Axes")
	local source = axes and axes:FindFirstChild(model)
	if not source or not source:IsA("Model") then
		return nil
	end
	local view = new("ViewportFrame", {
		Name = "View",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromScale(0.95, 0.5),
		Ambient = Color3.fromRGB(190, 190, 190),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-1, -1, -1),
		ZIndex = 2,
	})
	local m = source:Clone()
	for _, d in m:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	local bbox, size = m:GetBoundingBox()
	local offset = bbox:ToObjectSpace(m:GetPivot()) -- pivot relative to the box centre
	m:PivotTo(AXE_POSE * offset)
	m.Parent = view
	local fov = 35
	-- Fit the whole box whichever way it is turned.
	local radius = math.max(size.X, size.Y, size.Z) * 0.44
	local camera = new("Camera", { FieldOfView = fov, Parent = view })
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0, radius / math.tan(math.rad(fov / 2))), Vector3.zero)
	view.CurrentCamera = camera
	axeViews[model] = view
	return view
end

-- Studs on a card: one tiled stud image tinted to the card colour (was ~70 rounded Frames per card).
local STUD_IMAGE = "rbxassetid://110613161164843"
local STUD_COLUMNS = 5
local function studBackdrop(card: GuiObject, color: Color3)
	new("ImageLabel", {
		Name = "Studs",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Image = STUD_IMAGE,
		ImageColor3 = color:Lerp(Color3.new(1, 1, 1), 0.1),
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromScale(1 / STUD_COLUMNS, AXE_CARD_ASPECT / STUD_COLUMNS),
		ZIndex = 1,
		Parent = card,
	}, { corner(14) })
end

-- Out-of-stock card: dark overlay over the whole card, a padlock and red "OUT OF STOCK".
-- LOCK_IMAGE: put a padlock image id here (rbxassetid://...) to use it instead of the emoji.
local LOCK_IMAGE = ""
local OUT_OF_STOCK_GRADIENT = ColorSequence.new(Color3.fromRGB(255, 110, 90), Color3.fromRGB(200, 15, 25))
local function outOfStockOverlay(card: GuiObject)
	local overlay = new("Frame", {
		Name = "OutOfStock",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.22,
		ZIndex = 10,
		Parent = card,
	}, { corner(14) })
	local lockProps: { [string]: any } = {
		Name = "Lock",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.31),
		Size = UDim2.fromScale(0.3, 0.3),
		BackgroundTransparency = 1,
		ZIndex = 11,
		Parent = overlay,
	}
	if LOCK_IMAGE ~= "" then
		lockProps.Image = LOCK_IMAGE
		lockProps.ScaleType = Enum.ScaleType.Fit
		new("ImageLabel", lockProps, { new("UIAspectRatioConstraint", { AspectRatio = 1 }) })
	else
		lockProps.Text = "🔒"
		lockProps.TextScaled = true
		lockProps.Font = FONT
		new("TextLabel", lockProps, { new("UIAspectRatioConstraint", { AspectRatio = 1 }) })
	end
	local label = text({
		Name = "Label",
		Text = "OUT OF STOCK",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.465),
		Size = UDim2.fromScale(0.92, 0.095),
		StrokeThickness = 3,
		ZIndex = 11,
		Parent = overlay,
	})
	new("UIGradient", { Color = OUT_OF_STOCK_GRADIENT, Rotation = 90, Parent = label })
end

local BUY_COLOR = Color3.fromRGB(255, 170, 25)
local STAT_KEY_COLOR = Color3.fromRGB(200, 202, 212)
local EQUIPPED_COLOR = Color3.fromRGB(95, 98, 110)
local SOLD_COLOR = Color3.fromRGB(185, 45, 45)

local function cardButton(parent: Instance, label: string, color: Color3, pos: UDim2, size: UDim2, z: number): TextButton
	local b = new("TextButton", {
		Text = label,
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = color,
		AutoButtonColor = true,
		Position = pos,
		Size = size,
		ZIndex = z,
		Parent = parent,
	}, {
		corner(10),
		new("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(210, 210, 210)),
			Rotation = 90,
		}),
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
	})
	stroke(Color3.fromRGB(10, 10, 12), 3, true).Parent = b
	stroke(Color3.fromRGB(10, 10, 12), 2.5).Parent = b
	UIStyle.Button(b)
	return b
end

local function buy(action: string, def: ShopConfig.AxeDef, from: GuiObject)
	if busy then
		return
	end
	busy = true
	pop(from)
	local ok, result = pcall(ShopAction.InvokeServer, ShopAction, action, def.Model)
	busy = false
	if ok and result and result.ok then
		local message = result.message or ("Bought %s!"):format(def.Name)
		showToast(axeWindow, message, VALUE_GREEN)
	else
		showToast(axeWindow, if ok and result and result.message then result.message else "Could not buy", SOLD_OUT_COLOR)
	end
	renderAxes()
end

renderAxes = function()
	for _, v in axeViews do
		v.Parent = nil -- keep the cached views alive while the old cards go
	end
	for _, c in axeWindow.grid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local inStockCount = 0
	for i, def in ShopConfig.Axes do
		local have = owns(def.Model)
		local locked = not have and unlockedZones() < def.Zone
		local stock = stockOf(def.Model)
		local soldOut = not locked and def.Price > 0 and stock <= 0
		if not locked and def.Price > 0 and stock > 0 then
			inStockCount += 1
		end

		local color = ItemDisplay.SlotColor(def.Rarity)
		local card = new("Frame", {
			Name = def.Model,
			LayoutOrder = i,
			BackgroundColor3 = color,
		}, {
			corner(14),
			new("UIGradient", {
				Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200)),
				Rotation = 90,
			}),
		})
		stroke(Color3.fromRGB(10, 10, 12), 3, true).Parent = card
		studBackdrop(card, color)

		-- Header: name + rarity (gradient).
		text({ Name = "NameLabel", Text = def.Name, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.035), Size = UDim2.fromScale(0.9, 0.085), StrokeThickness = 3, ZIndex = 3, Parent = card })
		local rarityLabel = text({ Name = "Rarity", Text = def.Rarity, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.12), Size = UDim2.fromScale(0.6, 0.055), StrokeThickness = 2.5, ZIndex = 3, Parent = card })
		HeroConfig.PaintRarity(rarityLabel, def.Rarity) -- rarity gradient, animated by RarityGradientFX

		-- The axe.
		local view = axeViewport(def.Model)
		if view then
			view.Position = UDim2.fromScale(0.5, 0.18)
			view.Size = UDim2.fromScale(0.9, 0.38)
			view.Parent = card
		end

		-- Stats: In Stock / Owned / Power, one row each in a dark panel.
		local stats = new("Frame", {
			Name = "Stats",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.575),
			Size = UDim2.fromScale(0.88, 0.245),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.45,
			ZIndex = 3,
			Parent = card,
		}, {
			corner(10),
			new("UIPadding", { PaddingLeft = UDim.new(0.07, 0), PaddingRight = UDim.new(0.07, 0), PaddingTop = UDim.new(0.06, 0), PaddingBottom = UDim.new(0.06, 0) }),
			new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }),
		})
		local function statRow(order: number, name: string, value: string, valueColor: Color3)
			local row = new("Frame", { Name = name, LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1 / 3), ZIndex = 3, Parent = stats })
			text({ Name = "Key", Text = name, TextColor3 = STAT_KEY_COLOR, Size = UDim2.fromScale(0.55, 0.8), Position = UDim2.fromScale(0, 0.1), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4, Parent = row })
			text({ Name = "Value", Text = value, TextColor3 = valueColor, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0.05), Size = UDim2.fromScale(0.45, 0.9), TextXAlignment = Enum.TextXAlignment.Right, StrokeThickness = 2.5, ZIndex = 4, Parent = row })
		end
		local copies = 0
		if have then
			local axes = folder("Axes")
			local v = axes and axes:FindFirstChild(def.Model)
			local n = v and v:GetAttribute("Copies")
			copies = if typeof(n) == "number" then n else 1
		end
		statRow(1, "In Stock", if def.Price <= 0 then "-" else tostring(stock), if stock > 0 then STOCK_COLOR else SOLD_OUT_COLOR)
		statRow(2, "Owned", tostring(copies), if copies > 0 then Color3.new(1, 1, 1) else STAT_KEY_COLOR)
		statRow(3, "Power", "x" .. tostring(def.HeroBoost), VALUE_GREEN)

		-- The only button: buy (another copy when already owned).
		local label, bColor
		if locked then
			label, bColor = ("🔒 ZONE %d"):format(def.Zone), EQUIPPED_COLOR
		elseif def.Price <= 0 then
			label, bColor = "FREE", EQUIPPED_COLOR
		elseif soldOut then
			label, bColor = "SOLD OUT", SOLD_COLOR
		else
			label, bColor = "$" .. abbreviate(def.Price), BUY_COLOR
		end
		local main = cardButton(card, label, bColor, UDim2.fromScale(0.06, 0.85), UDim2.fromScale(0.88, 0.11), 3)
		main.Name = "Buy"

		if view and locked then
			view.ImageColor3 = Color3.new(0, 0, 0)
			view.ImageTransparency = 0.35
			local picture = view:FindFirstChild("Picture") :: ImageLabel?
			if picture then
				picture.ImageColor3 = Color3.new(0, 0, 0)
				picture.ImageTransparency = 0.35
			end
		end
		if soldOut then
			outOfStockOverlay(card)
		end
		main.Activated:Connect(function()
			if locked then
				showToast(axeWindow, ("Unlock Zone %d to buy this axe!"):format(def.Zone), SOLD_OUT_COLOR)
			elseif def.Price <= 0 then
				return
			elseif stockOf(def.Model) <= 0 then
				showToast(axeWindow, "Sold out! Wait for the restock", SOLD_OUT_COLOR)
			else
				buy(if owns(def.Model) then "BuyAxeCopy" else "BuyAxe", def, main)
			end
		end)
		card.Parent = axeWindow.grid
	end
	local info = axeWindow.root:FindFirstChild("Info")
	local inStockLabel = info and info:FindFirstChild("InStock") :: TextLabel?
	if inStockLabel then
		inStockLabel.Text = ("%d Axes In Stock"):format(inStockCount)
	end
	axeWindow.rightButton.Text = ("$%s"):format(abbreviate(money()))
end

-- Opening / closing ---------------------------------------------------------------------------------

local windows = { LumberAxe = axeWindow }
local watchers: { RBXScriptConnection } = {}

local function closeAll()
	for _, w in windows do
		w.root.Visible = false
	end
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("Shop", axeWindow.root, closeAll)

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
	do
		renderAxes()
		-- Several values often change together (a restock touches every axe): rebuild once per batch.
		local queued = false
		local refresh = function()
			if queued then
				return
			end
			queued = true
			task.delay(0.1, function()
				queued = false
				if current and current.kind == "LumberAxe" then
					renderAxes()
				end
			end)
		end
		table.insert(watchers, player:GetAttributeChangedSignal("EquippedAxe"):Connect(refresh))
		watch(folder("Axes"), refresh)
		watch(stockFolder(), refresh)
		table.insert(watchers, player:GetAttributeChangedSignal("UnlockedZones"):Connect(refresh))
		local stats = player:FindFirstChild("leaderstats")
		local m = stats and stats:FindFirstChild("Money")
		if m then
			table.insert(watchers, (m :: any).Changed:Connect(function()
				axeWindow.rightButton.Text = ("$%s"):format(abbreviate(money()))
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

-- True when the prompt sits on a plot this player owns (or on no plot at all, e.g. Workspace.Shops).
local function isMine(prompt: ProximityPrompt): boolean
	local inst = prompt.Parent
	while inst and inst ~= workspace do
		local owner = inst:GetAttribute("OwnerUserId")
		if owner ~= nil then
			return owner == Players.LocalPlayer.UserId
		end
		inst = inst.Parent
	end
	return true
end

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name ~= "ShopPrompt" or not isMine(prompt) then
		return
	end
	local kind = prompt:GetAttribute("Shop")
	if typeof(kind) == "string" then
		open(kind, prompt)
	end
end)

-- Walked away: close. Also ticks the restock countdown.
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.25 or not current then
		return
	end
	acc = 0
	if current.kind == "LumberAxe" then
		axeWindow.subtitle.Text = "⏱ " .. restockText()
		axeWindow.subtitle.TextColor3 = STOCK_COLOR
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = current.anchor
	if not root or (anchor and (root.Position - anchor.Position).Magnitude > ShopConfig.CloseDistance) then
		closeAll()
	end
end)
