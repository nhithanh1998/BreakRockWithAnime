-- ShopUI: the shop windows, opened from the shops' "ShopPrompt" (ShopService / ShopConfig).
--
-- (Selling moved: materials are sold at the Farm Stand, heroes from the Inventory window.)
-- Lumber Axe ("Axe Shop"): a card per axe (ShopConfig.Axes) with its model, damage and price.
--   Click to buy (then it is equipped) or to equip one you own. Each axe shows its server-wide stock
--   (ReplicatedStorage.AxeStock, "Sold Out" at 0) and is locked until the player has unlocked its
--   Zone; the info bar counts down to the next restock (AxeStock "NextRestock").
-- The window is the common UIStyle.Window (header, red X, Theme colours, global UIScale, UIManager).
-- It closes with X or when you walk ShopConfig.CloseDistance away from the shop.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local ShopAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ShopAction") :: RemoteFunction

local player = Players.LocalPlayer

local FONT = Theme.Font
local VALUE_GREEN = ItemDisplay.MATERIAL_VALUE_COLOR

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
	props.TextColor3 = props.TextColor3 or Theme.Color.Text
	local thickness = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local label = new("TextLabel", props)
	stroke(Theme.Color.Stroke, thickness).Parent = label
	return label
end

local function pop(inst: GuiObject)
	local scale = inst:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = inst })
	scale.Scale = 0.92
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Window ------------------------------------------------------------------------------------------

type Window = {
	win: UIStyle.Window,
	root: Frame,
	restock: TextLabel,
	inStock: TextLabel,
	cash: TextLabel,
	grid: ScrollingFrame,
	toast: TextLabel,
}

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

-- Shop state --------------------------------------------------------------------------------------

local current: { kind: string, prompt: ProximityPrompt?, anchor: BasePart? }? = nil

-- Colours (Theme): stock / restock = gold info, sold out = red, money = gold.
local SOLD_OUT_COLOR = Theme.Color.Danger
local STOCK_COLOR = Theme.Color.Accent

-- Lumber Axe window: the common window template; an info bar (restock | stock | cash) and a
-- vertical grid of rarity cards with a stud backdrop and a still axe model.
local AXE_COLUMNS = 3
local AXE_CARD_ASPECT = 0.68 -- card width / height

local function makeAxeWindow(): Window
	local win = UIStyle.Window({
		Name = "ShopGui",
		Title = "AXE SHOP",
		Size = Vector2.new(900, 620),
		PhoneSize = Vector2.new(660, 400),
		DisplayOrder = 12,
	})
	local body = win.body
	local pad = Theme.Space.L

	-- Info bar: restock timer | axes in stock | cash.
	local info = new("Frame", {
		Name = "Info",
		Position = UDim2.fromOffset(pad, 0),
		Size = UDim2.new(1, -pad * 2, 0, if win.phone then 36 else 44),
		BackgroundColor3 = Theme.Color.SurfaceInset,
		Parent = body,
	}, {
		corner(Theme.Radius.Button),
		new("UIPadding", { PaddingLeft = UDim.new(0, Theme.Space.M), PaddingRight = UDim.new(0, Theme.Space.M) }),
	})
	stroke(Theme.Color.Stroke, 2, true).Parent = info
	local restock = text({
		Name = "Restock",
		Text = "",
		TextColor3 = STOCK_COLOR,
		Position = UDim2.fromScale(0, 0.18),
		Size = UDim2.fromScale(0.36, 0.64),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = info,
	})
	local inStock = text({
		Name = "InStock",
		Text = "",
		TextColor3 = Theme.Color.TextDim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.18),
		Size = UDim2.fromScale(0.3, 0.64),
		Parent = info,
	})
	local cash = text({
		Name = "Cash",
		Text = "",
		TextColor3 = Theme.Color.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0.18),
		Size = UDim2.fromScale(0.3, 0.64),
		Parent = info,
	})

	local infoBottom = info.Size.Y.Offset + Theme.Space.S
	local grid = new("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromOffset(pad, infoBottom),
		Size = UDim2.new(1, -pad, 1, -infoBottom),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Color.TextDim,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = body,
	}, {
		-- Bottom padding: the last row scrolls fully into view above the window's edge.
		new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, pad), PaddingBottom = UDim.new(0, pad + 8) }),
	})
	local gridLayout = new("UIGridLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local function sizeCells()
		-- AbsoluteSize includes the window's UIScale; cells are in design px.
		local width = (grid.AbsoluteSize.X / math.max(win.scale.Scale, 0.01)) - pad - 2 - grid.ScrollBarThickness
		local gap = math.max(6, math.floor(width * 0.025))
		local cell = math.max(40, math.floor((width - gap * (AXE_COLUMNS - 1)) / AXE_COLUMNS))
		gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		gridLayout.CellSize = UDim2.fromOffset(cell, math.floor(cell / AXE_CARD_ASPECT))
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeCells)
	sizeCells()

	-- Toast just under the window (the body clips, so it hangs off the root).
	local toast = text({
		Name = "Toast",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, Theme.Space.S),
		Size = UDim2.new(0.7, 0, 0, 32),
		TextColor3 = VALUE_GREEN,
		TextTransparency = 1,
		Parent = win.root,
	})
	;(toast:FindFirstChildOfClass("UIStroke") :: UIStroke).Transparency = 1

	return {
		win = win,
		root = win.root,
		restock = restock,
		inStock = inStock,
		cash = cash,
		grid = grid,
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

local BUY_COLOR = Theme.Color.Primary -- the one main action of a card
local STAT_KEY_COLOR = Theme.Color.TextDim
local EQUIPPED_COLOR = Theme.Color.Disabled
local SOLD_COLOR = Theme.Color.DangerDark

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
	axeWindow.inStock.Text = ("%d Axes In Stock"):format(inStockCount)
	axeWindow.cash.Text = ("$%s"):format(abbreviate(money()))
end

-- Opening / closing ---------------------------------------------------------------------------------

local windows = { LumberAxe = axeWindow }
local watchers: { RBXScriptConnection } = {}

-- UIStyle.Window already registered the window with UIManager (one window at a time).
local function closeAll()
	for _, w in windows do
		w.win.Close()
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
				axeWindow.cash.Text = ("$%s"):format(abbreviate(money()))
			end))
		end
	end
	w.win.Open()
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
		axeWindow.restock.Text = "⏱ " .. restockText()
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = current.anchor
	if not root or (anchor and (root.Position - anchor.Position).Magnitude > ShopConfig.CloseDistance) then
		closeAll()
	end
end)
