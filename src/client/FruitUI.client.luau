-- FruitUI: the Devil Tree on your plot (FruitService / FruitConfig).
--
--   Window   opened by the Devil Tree prompt (Remotes.FruitOpen). Left: every fruit with its chance,
--            how many you own (unknown fruits are dark silhouettes) and its skill on hover / tap.
--            Right: your fertilizer bags, GROW (FruitAction "Grow") and the Robux packs ("Buy").
--            Closes with X or when you walk FruitConfig.CloseDistance studs away.
--   Cutscene GROW -> the window, the other GUIs, the planter's sign / "Grow" prompt, the greenhouse's
--            front wall and your character hide; the camera goes into the greenhouse:
--            seed flies into the soil > fertilizer pours > green sprout > it grows into the Old Oak
--            (copy of ReplicatedStorage.Trees.Map1.OldOakTree) > a MYSTERY fruit (black silhouette with a
--            "?", neutral glow, so nothing gives the roll away) swells under the crown > it drops >
--            zoom in, it trembles faster and faster > burst: the real fruit + its name and rarity
--            colour > white flash > reveal. SKIP jumps straight to the reveal.
--            Everything hidden comes back once the reveal closes.
--   Reveal   "NEW FRUIT!", name, rarity, skill, boost, the fruit spinning. EQUIP puts it on your best
--            pad (FruitAction "Equip"), CONTINUE goes back to the window.
-- Everything is client-side visuals; the fruit is rolled and given by the server before it starts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local FruitModels = require(Shared:WaitForChild("FruitModels"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FruitAction = Remotes:WaitForChild("FruitAction") :: RemoteFunction
local FruitOpen = Remotes:WaitForChild("FruitOpen") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FONT = Theme.Font
local DESIGN = Vector2.new(780, 440) -- the window is laid out at this size, then scaled to fit
local PANEL = Theme.Color.Surface
local PANEL_DARK = Theme.Color.SurfaceInset
local STROKE = Theme.Color.Stroke
local GREEN = Theme.Color.Primary
local GREY = Theme.Color.Disabled
local PURPLE = Theme.Color.Accent -- Robux / premium = gold
local ORANGE = Theme.Color.Danger -- close X
local INFO = Color3.fromRGB(180, 182, 195)
local BAD = Color3.fromRGB(255, 90, 90)
local GOOD = Color3.fromRGB(90, 255, 110)
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

-- Helpers ------------------------------------------------------------------------------------------

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

local function corner(r: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function outline(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function label(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local thickness = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local l = new("TextLabel", props)
	outline(STROKE, thickness).Parent = l
	return l
end

local function button(text: string, color: Color3, props: { [string]: any }): TextButton
	props.Text = text
	props.BackgroundColor3 = color
	props.Font = FONT
	props.TextScaled = true
	props.TextColor3 = Color3.new(1, 1, 1)
	props.AutoButtonColor = true
	local b = new("TextButton", props, { corner(6), outline(STROKE, 2.5, true) })
	outline(STROKE, 2).Parent = b
	new("UIPadding", { PaddingTop = UDim.new(0.14, 0), PaddingBottom = UDim.new(0.14, 0), PaddingLeft = UDim.new(0.06, 0), PaddingRight = UDim.new(0.06, 0), Parent = b })
	UIStyle.Button(b)
	return b
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function percent(chance: number): string
	local pct = chance * 100
	if pct >= 10 then
		return ("%d%%"):format(math.floor(pct + 0.5))
	elseif pct >= 1 then
		return ("%.1f%%"):format(pct)
	end
	return ("%.2f%%"):format(pct)
end

local function fertilizer(): number
	local n = player:GetAttribute("Fertilizer")
	return if typeof(n) == "number" then n else 0
end

local function owned(id: string): number
	local folder = player:FindFirstChild("Fruits")
	local v = folder and folder:FindFirstChild(id) :: IntValue?
	return if v then v.Value else 0
end

local function myGarden(): Model?
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local g = plot:FindFirstChild("DevilGarden")
			return if g and g:IsA("Model") then g else nil
		end
	end
	return nil
end

-- Window ---------------------------------------------------------------------------------------------

local gui = new("ScreenGui", { Name = "FruitGui", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 8, Enabled = false, Parent = playerGui })
local root = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.52),
	Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y),
	BackgroundColor3 = PANEL,
	Parent = gui,
}, { corner(12), outline(STROKE, 4, true) })
UIStyle.Panel(root)
local scale = new("UIScale", { Parent = root })
local function fit()
	local view = workspace.CurrentCamera.ViewportSize
	scale.Scale = math.min((view.X * 0.92) / DESIGN.X, (view.Y * 0.82) / DESIGN.Y, 1.4)
end
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
fit()

local title = label({ Text = "Devil Tree", Position = UDim2.fromOffset(0, -26), Size = UDim2.new(1, 0, 0, 52), StrokeThickness = 4, ZIndex = 3, Parent = root })
new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(230, 170, 255), Color3.fromRGB(150, 70, 230)), Rotation = 90, Parent = title })
local close = button("X", ORANGE, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(40, 40), ZIndex = 3, Parent = root })
UIStyle.Close(close)

-- Left: the fruit index.
local left = new("Frame", { Name = "Fruits", Position = UDim2.fromOffset(16, 34), Size = UDim2.fromOffset(470, 390), BackgroundColor3 = PANEL_DARK, Parent = root }, { corner(8) })
label({ Text = "Fruits", Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 26), Parent = left })
local grid = new("Frame", { Name = "Grid", Position = UDim2.fromOffset(10, 38), Size = UDim2.fromOffset(450, 270), BackgroundTransparency = 1, Parent = left }, {
	new("UIGridLayout", { CellSize = UDim2.fromOffset(105, 130), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local detail = new("Frame", { Name = "Detail", Position = UDim2.fromOffset(10, 318), Size = UDim2.fromOffset(450, 62), BackgroundColor3 = PANEL, Parent = left }, { corner(6) })
local detailName = label({ Text = "", Position = UDim2.fromOffset(10, 4), Size = UDim2.fromOffset(250, 24), TextXAlignment = Enum.TextXAlignment.Left, Parent = detail })
local detailBoost = label({ Text = "", TextColor3 = GOOD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 4), Size = UDim2.fromOffset(170, 24), TextXAlignment = Enum.TextXAlignment.Right, Parent = detail })
local detailSkill = label({ Text = "Tap a fruit to see its skill", TextColor3 = INFO, RichText = true, Position = UDim2.fromOffset(10, 32), Size = UDim2.new(1, -20, 0, 24), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 1.5, Parent = detail })

local function showDetail(def: FruitConfig.FruitDef)
	detailName.Text = def.Name
	detailName.TextColor3 = TreeConfig.RarityColors[def.Rarity] or Color3.new(1, 1, 1)
	detailBoost.Text = FruitConfig.BoostText(def)
	detailSkill.Text = ("<b>%s:</b> %s"):format(def.Skill.Name, def.Skill.Desc)
end

type Card = { def: FruitConfig.FruitDef, view: ViewportFrame, count: TextLabel, name: TextLabel, mystery: TextLabel }
local cards: { Card } = {}
for i, def in FruitConfig.Fruits do
	local color = ItemDisplay.SlotColor(def.Rarity)
	local card = new("TextButton", { Name = def.Id, Text = "", AutoButtonColor = true, LayoutOrder = i, BackgroundColor3 = color, Parent = grid }, {
		corner(8),
		outline(color:Lerp(Color3.new(1, 1, 1), 0.35), 2.5, true),
	})
	label({ Text = percent(FruitConfig.ChanceOf(def.Id)), Position = UDim2.fromOffset(6, 4), Size = UDim2.fromOffset(60, 18), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3, Parent = card })
	local count = label({ Text = "", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 4), Size = UDim2.fromOffset(40, 18), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 3, Parent = card })
	local view = new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 22), Size = UDim2.fromOffset(89, 74), ZIndex = 2, Parent = card })
	local mystery = label({ Text = "?", Visible = false, Position = UDim2.fromOffset(8, 30), Size = UDim2.fromOffset(89, 56), ZIndex = 3, StrokeThickness = 3, Parent = card })
	local name = label({ Text = def.Name, Position = UDim2.fromOffset(4, 98), Size = UDim2.new(1, -8, 0, 26), ZIndex = 3, Parent = card })
	ItemDisplay.FillFruitViewport(view, def.Id)
	card.Activated:Connect(function()
		showDetail(def)
	end)
	card.MouseEnter:Connect(function()
		showDetail(def)
	end)
	table.insert(cards, { def = def, view = view, count = count, name = name, mystery = mystery })
end

-- Right: fertilizer, GROW, Robux packs.
local right = new("Frame", { Name = "Grow", Position = UDim2.fromOffset(500, 34), Size = UDim2.fromOffset(264, 390), BackgroundColor3 = PANEL_DARK, Parent = root }, { corner(8) })
local bagView = new("ViewportFrame", { Name = "Bag", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 10), Size = UDim2.fromOffset(80, 80), Ambient = Color3.fromRGB(200, 200, 200), LightColor = Color3.new(1, 1, 1), Parent = right })
do
	local bag = FruitModels.Bag()
	bag:PivotTo(CFrame.Angles(0, math.rad(-25), 0))
	bag.Parent = bagView
	local cam = new("Camera", { FieldOfView = 30, Parent = bagView })
	cam.CFrame = CFrame.lookAt(Vector3.new(0, 0.6, -6.2), Vector3.new(0, 0.2, 0))
	bagView.CurrentCamera = cam
end
label({ Text = FruitConfig.FertilizerName, TextColor3 = INFO, Position = UDim2.fromOffset(98, 16), Size = UDim2.fromOffset(156, 22), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 1.5, Parent = right })
local bagCount = label({ Text = "x0", Position = UDim2.fromOffset(98, 40), Size = UDim2.fromOffset(156, 40), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 3, Parent = right })
local growButton = button("GROW", GREEN, { Name = "GrowButton", Position = UDim2.fromOffset(12, 100), Size = UDim2.fromOffset(240, 62), Parent = right })
label({ Text = ("Uses %d bag"):format(FruitConfig.FertilizerPerGrow), TextColor3 = INFO, Position = UDim2.fromOffset(12, 164), Size = UDim2.fromOffset(240, 18), StrokeThickness = 1.5, Parent = right })
local toast: (string, Color3) -> ()
label({ Text = "Get more bags", Position = UDim2.fromOffset(12, 192), Size = UDim2.fromOffset(240, 22), Parent = right })
for i, pack in FruitConfig.FertilizerProducts do
	local soon = pack.ProductId == 0
	local b = button(("x%d  -  %s"):format(pack.Amount, if soon then "Soon" else ("R$ %d"):format(pack.Robux)), if soon then GREY else PURPLE, {
		Position = UDim2.fromOffset(12, 220 + (i - 1) * 50),
		Size = UDim2.fromOffset(240, 42),
		Parent = right,
	})
	b.Activated:Connect(function()
		local ok, result = pcall(FruitAction.InvokeServer, FruitAction, "Buy", pack.Amount)
		if ok and typeof(result) == "table" and not result.ok and result.message then
			toast(result.message, BAD)
		end
	end)
end
local toastLabel = label({ Text = "", Visible = false, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 8), Size = UDim2.fromOffset(500, 30), StrokeThickness = 2.5, ZIndex = 5, Parent = root })
local toastId = 0
toast = function(text: string, color: Color3)
	toastId += 1
	local id = toastId
	toastLabel.Text = text
	toastLabel.TextColor3 = color
	toastLabel.Visible = true
	task.delay(2.2, function()
		if toastId == id then
			toastLabel.Visible = false
		end
	end)
end

local function refresh()
	bagCount.Text = ("x%d"):format(fertilizer())
	for _, c in cards do
		local n = owned(c.def.Id)
		c.count.Text = if n > 0 then ("x%d"):format(n) else ""
		-- Fruits you never got are dark silhouettes.
		c.view.ImageColor3 = if n > 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		c.view.ImageTransparency = if n > 0 then 0 else 0.25
		c.mystery.Visible = n <= 0
	end
end
player:GetAttributeChangedSignal("Fertilizer"):Connect(refresh)
local function watchFruits(folder: Instance)
	folder.ChildAdded:Connect(function(v)
		if v:IsA("IntValue") then
			v.Changed:Connect(refresh)
		end
		refresh()
	end)
	for _, v in folder:GetChildren() do
		if v:IsA("IntValue") then
			v.Changed:Connect(refresh)
		end
	end
end
task.spawn(function()
	watchFruits(player:WaitForChild("Fruits"))
	refresh()
end)
refresh()

local isOpen = false
local busy = false

local function openWindow()
	if busy then
		return
	end
	refresh()
	isOpen = true
	gui.Enabled = true
	root.Visible = true
	fit()
	local target = scale.Scale
	scale.Scale = target * 0.85
	tween(scale, 0.15, { Scale = target }, Enum.EasingStyle.Back)
end

local function closeWindow()
	isOpen = false
	gui.Enabled = false
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("Fruit", root, closeWindow)

close.Activated:Connect(closeWindow)
FruitOpen.OnClientEvent:Connect(openWindow)

-- Close when walking away.
task.spawn(function()
	while true do
		task.wait(0.5)
		if isOpen and not busy then
			local garden = myGarden()
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not garden or not hrp or (hrp.Position - garden:GetPivot().Position).Magnitude > FruitConfig.CloseDistance then
				closeWindow()
			end
		end
	end
end)

-- Cutscene -------------------------------------------------------------------------------------------

local function getControls(): any
	local ok, controls = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 2)
		return module and (require(module :: ModuleScript) :: any):GetControls()
	end)
	return if ok then controls else nil
end

-- Hides every other ScreenGui; returns a function that shows them again.
local function hideGuis(except: ScreenGui): () -> ()
	local hidden: { ScreenGui } = {}
	for _, g in playerGui:GetChildren() do
		if g:IsA("ScreenGui") and g ~= except and g ~= gui and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
	return function()
		for _, g in hidden do
			if g.Parent then
				g.Enabled = true
			end
		end
	end
end

local fxFolder = workspace:FindFirstChild("ClientFX") or Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace

local function emitter(parent: Instance, texture: string, color: Color3, props: { [string]: any }?): ParticleEmitter
	local e = new("ParticleEmitter", {
		Texture = texture,
		Color = ColorSequence.new(color),
		LightEmission = 0.6,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.5, 1),
		Speed = NumberRange.new(4, 9),
		SpreadAngle = Vector2.new(180, 180),
		Rate = 0,
		Parent = parent,
	})
	for k, v in props or {} do
		(e :: any)[k] = v
	end
	return e
end

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function backOut(x: number): number
	x = math.clamp(x, 0, 1)
	local c = 1.7
	return 1 + (c + 1) * (x - 1) ^ 3 + c * (x - 1) ^ 2
end

-- The reveal card shown after the cutscene. Calls `done(equip)` when a button is pressed.
local function reveal(cutGui: ScreenGui, def: FruitConfig.FruitDef, done: (boolean) -> ())
	local rarityColor = TreeConfig.RarityColors[def.Rarity] or Color3.new(1, 1, 1)
	local holder = new("Frame", { Name = "Reveal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = cutGui })
	-- Soft glow behind the fruit in the rarity colour: stacked circles, faint at the edge, breathing.
	local glowRings: { Frame } = {}
	for i = 1, 6 do
		table.insert(glowRings, new("Frame", {
			Name = "Glow",
			BackgroundColor3 = rarityColor,
			BackgroundTransparency = 0.72 + i * 0.035,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.68, 0.5),
			Size = UDim2.fromScale(0.16 + i * 0.09, 0.16 + i * 0.09),
			ZIndex = 10,
			Parent = holder,
		}, {
			new("UIAspectRatioConstraint", { AspectRatio = 1 }),
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}))
	end
	local view = new("ViewportFrame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.68, 0.5),
		Size = UDim2.fromScale(0.5, 0.62),
		Ambient = Color3.fromRGB(210, 210, 210),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-0.4, -1, -0.8),
		ZIndex = 11,
		Parent = holder,
	}, { new("UIAspectRatioConstraint", { AspectRatio = 1 }) })
	local fruit = FruitModels.Fruit(def, 2)
	fruit.Parent = view
	local cam = new("Camera", { FieldOfView = 30, Parent = view })
	cam.CFrame = CFrame.lookAt(Vector3.new(0, 0.2, 5.2), Vector3.zero)
	view.CurrentCamera = cam

	local info = new("Frame", { Name = "Info", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.06, 0.5), Size = UDim2.fromScale(0.42, 0.56), ZIndex = 12, Parent = holder })
	local tag = new("TextLabel", { Text = "NEW FRUIT!", Font = FONT, TextScaled = true, TextColor3 = Color3.fromRGB(40, 40, 50), BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(0.3, 0.09), ZIndex = 12, Parent = info }, { corner(8) })
	new("UIPadding", { PaddingTop = UDim.new(0.15, 0), PaddingBottom = UDim.new(0.15, 0), Parent = tag })
	local name = label({ Text = def.Name, Position = UDim2.fromScale(0, 0.11), Size = UDim2.fromScale(1, 0.2), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 4, ZIndex = 12, Parent = info })
	new("UIGradient", { Color = ColorSequence.new(Color3.new(1, 1, 1), rarityColor), Rotation = 90, Parent = name })
	local rarity = label({ Text = def.Rarity, Position = UDim2.fromScale(0, 0.32), Size = UDim2.fromScale(0.5, 0.1), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 3, ZIndex = 12, Parent = info })
	HeroConfig.PaintRarity(rarity, def.Rarity)
	label({ Text = ("%s  ·  %s"):format(FruitConfig.BoostText(def), def.Skill.Name), TextColor3 = GOOD, Position = UDim2.fromScale(0, 0.44), Size = UDim2.fromScale(1, 0.1), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 2.5, ZIndex = 12, Parent = info })
	label({ Text = def.Skill.Desc, TextColor3 = Color3.fromRGB(230, 230, 240), Position = UDim2.fromScale(0, 0.55), Size = UDim2.fromScale(1, 0.09), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 2, ZIndex = 12, Parent = info })
	local equip = button("EQUIP", GREEN, { Position = UDim2.fromScale(0, 0.72), Size = UDim2.fromScale(0.38, 0.15), ZIndex = 12, Parent = info })
	local continue = button("CONTINUE", Color3.fromRGB(200, 150, 40), { Position = UDim2.fromScale(0.42, 0.72), Size = UDim2.fromScale(0.42, 0.15), ZIndex = 12, Parent = info })
	equip.Name = "Equip"
	continue.Name = "Continue"
	local message = label({ Text = "", Position = UDim2.fromScale(0, 0.9), Size = UDim2.fromScale(1, 0.08), TextXAlignment = Enum.TextXAlignment.Left, StrokeThickness = 2, ZIndex = 12, Parent = info })

	-- Pop in.
	local infoScale = new("UIScale", { Scale = 0.6, Parent = info })
	tween(infoScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	local spin = 0
	local conn = RunService.RenderStepped:Connect(function(dt)
		spin += dt
		local breath = 1 + math.sin(spin * 2.5) * 0.04
		for i, ring in glowRings do
			local size = (0.16 + i * 0.09) * breath
			ring.Size = UDim2.fromScale(size, size)
		end
		fruit:PivotTo(CFrame.new(0, math.sin(spin * 2) * 0.08, 0) * CFrame.Angles(0, spin * 1.2, math.rad(8)))
	end)
	local finished = false
	local function finish(didEquip: boolean)
		if finished then
			return
		end
		finished = true
		conn:Disconnect()
		holder:Destroy()
		done(didEquip)
	end
	equip.Activated:Connect(function()
		if finished then
			return
		end
		equip.Active = false
		local ok, result = pcall(FruitAction.InvokeServer, FruitAction, "Equip", def.Id)
		if ok and typeof(result) == "table" and result.ok then
			message.TextColor3 = GOOD
			message.Text = result.message or "Equipped!"
			task.wait(0.9)
			finish(true)
		else
			message.TextColor3 = BAD
			message.Text = if ok and typeof(result) == "table" and result.message then result.message else "Couldn't equip"
			equip.Active = true
		end
	end)
	continue.Activated:Connect(function()
		finish(false)
	end)
end

-- Cutscene props --------------------------------------------------------------------------------------

local function prop(props: { [string]: any }): BasePart
	props.Anchored = if props.Anchored == nil then true else props.Anchored
	props.CanCollide = props.CanCollide or false
	props.CanQuery = false
	props.CanTouch = false
	props.TopSurface = Enum.SurfaceType.Smooth
	props.BottomSurface = Enum.SurfaceType.Smooth
	return new("Part", props)
end

local function oval(props: { [string]: any }): BasePart
	local p = prop(props)
	new("SpecialMesh", { MeshType = Enum.MeshType.Sphere, Parent = p })
	return p
end

-- Where the growing tree comes from: a copy of this tree's "Tree" model (its trunk + leaf voxels, no
-- ground or sign). Falls back to FruitModels.Tree if it isn't there.
local TREE_TEMPLATE = { "Trees", "Map1", "OldOakTree" }

local function isLeaf(c: Color3): boolean
	return c.G > c.R * 1.12 and c.G > c.B * 1.1
end

type Leaf = { part: BasePart, h: number }
type TreeInfo = { model: Model, leaves: { Leaf }, height: number, crownBottom: number, crownRadius: number }

-- The tree with its pivot on its ground level, standing on `ground` at scale 1.
local function makeTree(def: FruitConfig.FruitDef, ground: CFrame): TreeInfo
	local template: Instance? = ReplicatedStorage
	for _, name in TREE_TEMPLATE do
		template = template and template:FindFirstChild(name)
	end
	local source = template and (template:FindFirstChild("Tree") or template)
	local model: Model
	local groundTop: number? = nil
	if source and source:IsA("Model") then
		model = source:Clone()
		local groundModel = (template :: Instance):FindFirstChild("Ground")
		if groundModel and groundModel:IsA("Model") then
			local gcf, gsize = groundModel:GetBoundingBox()
			groundTop = gcf.Y + gsize.Y / 2
		end
	else
		model = FruitModels.Tree(def)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif not d:IsA("SpecialMesh") and not d:IsA("Texture") and not d:IsA("Decal") then
			d:Destroy()
		end
	end
	local cf, size = model:GetBoundingBox()
	model.PrimaryPart = nil
	model.WorldPivot = CFrame.new(cf.X, groundTop or (cf.Y - size.Y / 2), cf.Z)
	model:PivotTo(ground)

	-- Leaf voxels, with their height share inside the crown (the crown fills in from the bottom up).
	local leaves: { Leaf } = {}
	local lo, hi, radius = math.huge, -math.huge, 0
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and isLeaf(p.Color) then
			local rel = ground:PointToObjectSpace(p.Position)
			lo = math.min(lo, rel.Y)
			hi = math.max(hi, rel.Y)
			radius = math.max(radius, Vector2.new(rel.X, rel.Z).Magnitude)
			table.insert(leaves, { part = p, h = rel.Y })
		end
	end
	for _, l in leaves do
		l.h = if hi > lo then (l.h - lo) / (hi - lo) else 0
	end
	local _, full = model:GetBoundingBox()
	return {
		model = model,
		leaves = leaves,
		height = full.Y,
		crownBottom = if lo < math.huge then lo else full.Y * 0.5,
		crownRadius = if radius > 0 then radius else 3,
	}
end

local function makeSeed(): Model
	local m = new("Model", { Name = "Seed" })
	local body = oval({ Name = "Body", Size = Vector3.new(0.7, 0.95, 0.7), Color = Color3.fromRGB(150, 95, 45), Material = Enum.Material.SmoothPlastic, Parent = m })
	oval({ Name = "Stripe", Size = Vector3.new(0.72, 0.6, 0.3), Color = Color3.fromRGB(235, 200, 120), Material = Enum.Material.SmoothPlastic, Parent = m })
	m.PrimaryPart = body
	new("PointLight", { Color = Color3.fromRGB(255, 230, 150), Range = 6, Brightness = 1.5, Parent = body })
	emitter(body, SPARKLE, Color3.fromRGB(255, 235, 160), { Rate = 30, Lifetime = NumberRange.new(0.3, 0.6), Speed = NumberRange.new(0.5, 1.5), Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }) })
	return m
end

local function makeSprout(): Model
	local m = new("Model", { Name = "Sprout" })
	local green = Color3.fromRGB(110, 210, 80)
	local stem = prop({ Name = "Stem", Size = Vector3.new(0.22, 1.2, 0.22), Color = green:Lerp(Color3.new(0, 0, 0), 0.15), Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(0, 0.6, 0), Parent = m })
	m.PrimaryPart = stem
	for _, dir in { -1, 1 } do
		oval({
			Name = "Leaf",
			Size = Vector3.new(1.1, 0.12, 0.6),
			Color = green,
			Material = Enum.Material.SmoothPlastic,
			CFrame = CFrame.new(dir * 0.5, 1.25, 0) * CFrame.Angles(0, 0, math.rad(dir * 25)),
			Parent = m,
		})
	end
	m.WorldPivot = CFrame.new()
	return m
end

-- Hides the things that would get in the shot (the sign and "Grow" prompt over the planter, the front
-- wall of the greenhouse, your own character). Returns a function that puts them back.
local function hideForCutscene(garden: Model): () -> ()
	local undo: { () -> () } = {}
	for _, d in garden:GetDescendants() do
		if (d:IsA("BillboardGui") or d:IsA("SurfaceGui")) and d.Enabled then
			d.Enabled = false
			table.insert(undo, function()
				d.Enabled = true
			end)
		elseif d:IsA("ProximityPrompt") and d.Enabled then
			d.Enabled = false
			table.insert(undo, function()
				d.Enabled = true
			end)
		elseif d:IsA("BasePart") and d:GetAttribute("Front") then
			d.LocalTransparencyModifier = 1
			table.insert(undo, function()
				d.LocalTransparencyModifier = 0
			end)
		end
	end
	local character = player.Character
	if character then
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 1
				table.insert(undo, function()
					d.LocalTransparencyModifier = 0
				end)
			end
		end
	end
	return function()
		for _, f in undo do
			pcall(f)
		end
	end
end

local function playCutscene(def: FruitConfig.FruitDef, garden: Model, onDone: () -> ())
	local camera = workspace.CurrentCamera
	local oldType, oldCFrame, oldFov = camera.CameraType, camera.CFrame, camera.FieldOfView
	local controls = getControls()
	if controls then
		controls:Disable()
	end
	local showWorld = hideForCutscene(garden)

	local cutGui = new("ScreenGui", { Name = "FruitCutscene", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 20, Parent = playerGui })
	local showGuis = hideGuis(cutGui)
	local barTop = new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Size = UDim2.fromScale(1, 0), Parent = cutGui })
	local barBottom = new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), Parent = cutGui })
	tween(barTop, 0.4, { Size = UDim2.fromScale(1, 0.1) })
	tween(barBottom, 0.4, { Size = UDim2.fromScale(1, 0.1) })
	local flash = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 9, Parent = cutGui })
	local skip = button("SKIP", Color3.fromRGB(60, 170, 80), { Name = "Skip", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -24, 1, -24), Size = UDim2.fromOffset(120, 48), ZIndex = 8, Parent = cutGui })

	-- The scene, in the planter's space (front = -Z of its pivot).
	local base = garden:GetPivot()
	local rot = base - base.Position
	local bed = garden:FindFirstChild("Bed") :: BasePart?
	local bedTop = if bed then bed.Position.Y + bed.Size.Y / 2 else base.Y + 1.4
	local ground = CFrame.new(base.X, bedTop, base.Z) * rot -- soil surface, tree stands here
	local moundTop = bedTop
	for _, m in garden:GetChildren() do
		if m.Name == "Mound" and m:IsA("BasePart") then
			moundTop = math.max(moundTop, m.Position.Y + m.Size.Y / 2)
		end
	end
	local soil = Vector3.new(base.X, moundTop, base.Z) -- where the seed lands
	local front = rot.LookVector -- local -Z: the side with the prompt, facing the pads
	local up = Vector3.yAxis
	local side = rot.RightVector
	local rarityColor = TreeConfig.RarityColors[def.Rarity] or Color3.new(1, 1, 1)

	local scene = new("Folder", { Name = "FruitScene", Parent = fxFolder })
	local function anchor(at: Vector3): BasePart
		return prop({ Transparency = 1, Size = Vector3.one * 0.2, CFrame = CFrame.new(at), Parent = scene })
	end

	-- Props.
	local seed = makeSeed()
	local bag = FruitModels.Bag()
	bag:ScaleTo(1.4)
	local sprout = makeSprout()
	local treeInfo = makeTree(def, ground)
	local tree = treeInfo.model
	local leaves = treeInfo.leaves
	tree:ScaleTo(0.12)
	local FRUIT_SIZE = 1.8
	local fruit = FruitModels.Fruit(def, FRUIT_SIZE)
	new("Highlight", { FillTransparency = 1, OutlineColor = def.Swirl:Lerp(Color3.new(0, 0, 0), 0.55), OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.Occluded, Parent = fruit })
	-- The mystery fruit shown until the reveal: same shape (every fruit shares it), all black, with a "?".
	local MYSTERY = Color3.fromRGB(200, 170, 255)
	local mystery = FruitModels.Fruit(def, FRUIT_SIZE)
	for _, d in mystery:GetDescendants() do
		if d:IsA("BasePart") then
			d.Color = Color3.fromRGB(22, 16, 30)
			d.Material = Enum.Material.SmoothPlastic
		end
	end
	new("Highlight", { FillTransparency = 1, OutlineColor = MYSTERY, OutlineTransparency = 0.2, DepthMode = Enum.HighlightDepthMode.Occluded, Parent = mystery })
	local qGui = new("BillboardGui", { Name = "Mystery", Size = UDim2.fromScale(FRUIT_SIZE, FRUIT_SIZE), LightInfluence = 0, AlwaysOnTop = true, Parent = mystery.PrimaryPart })
	local qLabel = new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONT, TextScaled = true, Text = "?", TextColor3 = Color3.new(1, 1, 1), Parent = qGui })
	outline(Color3.fromRGB(60, 30, 100), 3).Parent = qLabel
	local function sizeQuestion(scale: number)
		local q = FRUIT_SIZE * 0.9 * scale
		qGui.Size = UDim2.fromScale(q, q)
	end
	-- The fruit hangs under the front edge of the crown, and lands on the soil in front of the trunk.
	local fruitSpot = ground.Position + front * treeInfo.crownRadius * 0.55 + side * 0.8 + up * (treeInfo.crownBottom - FRUIT_SIZE * 0.45)
	local landSpot = ground.Position + front * 3.2 + side * 0.8 + up * (FRUIT_SIZE * 0.55)

	local soilFx = anchor(soil + up * 0.2)
	local dirt = emitter(soilFx, SMOKE, Color3.fromRGB(130, 90, 60), { LightEmission = 0, Speed = NumberRange.new(3, 7), Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0) }) })
	local magic = emitter(soilFx, SPARKLE, Color3.fromRGB(190, 120, 255), { Speed = NumberRange.new(2, 6), Acceleration = Vector3.new(0, 6, 0) })
	-- Glowing patch spreading over the soil when the fertilizer soaks in.
	local patch = prop({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 0.5, 0.5), Color = Color3.fromRGB(170, 90, 240), Material = Enum.Material.Neon, Transparency = 1, CastShadow = false, CFrame = CFrame.new(Vector3.new(soil.X, bedTop + 0.06, soil.Z)) * CFrame.Angles(0, 0, math.rad(90)), Parent = scene })

	-- Neutral glow until the reveal, then it turns the rarity colour.
	local glow = prop({ Shape = Enum.PartType.Ball, Size = Vector3.one, Color = MYSTERY, Material = Enum.Material.Neon, Transparency = 1, CastShadow = false, CFrame = CFrame.new(fruitSpot) })
	local light = new("PointLight", { Color = MYSTERY, Range = 16, Brightness = 0, Parent = glow })
	local sparkle = emitter(glow, SPARKLE, MYSTERY, { Speed = NumberRange.new(2, 6) })

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 55

	-- Timeline (seconds): each stage starts at its time.
	local T_SEED, T_FERT, T_SPROUT, T_TREE, T_FRUIT, T_DROP, T_ZOOM, T_END = 0.5, 1.8, 3.6, 4.6, 7.2, 8.7, 9.6, 13.4
	local REVEAL_AT = 0.52 -- share of the zoom stage spent trembling before the burst
	local revealed = false
	local nameCard: Frame? = nil
	local t = 0
	local skipped = false
	local stage = 0
	skip.Activated:Connect(function()
		skipped = true
	end)

	-- The camera eases towards where each stage wants it (no hard cuts); `snap` jumps there.
	local camPos, camLook = soil + front * 24 + up * 12, soil + up * 3
	local shakeLeft = 0
	local function cam(pos: Vector3, look: Vector3, dt: number, speed: number?)
		local k = 1 - math.exp(-dt * (speed or 4))
		camPos = camPos:Lerp(pos, k)
		camLook = camLook:Lerp(look, k)
		local cf = CFrame.lookAt(camPos, camLook)
		if shakeLeft > 0 then
			cf *= CFrame.new((math.random() - 0.5) * shakeLeft, (math.random() - 0.5) * shakeLeft, 0)
		end
		camera.CFrame = cf
	end
	local function enter(n: number): boolean
		if stage < n then
			stage = n
			return true
		end
		return false
	end

	local granules: { BasePart } = {}
	local pourNext = 0
	local lastLeafH = -1
	local fallVel = 0
	local fruitPos = fruitSpot

	local doneRunning = false
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		if skipped then
			t = math.max(t, T_END)
		end
		shakeLeft = math.max(0, shakeLeft - dt * 1.5)

		if t < T_SEED then
			-- Wide shot of the greenhouse, pushing in.
			cam(soil + front * 15 + up * 8, soil + up * 2, dt, 2)
		elseif t < T_FERT then
			-- 1. A glowing seed flies in on an arc and plants itself in the mound.
			if enter(1) then
				seed:PivotTo(CFrame.new(soil + front * 9 + side * 5 + up * 9))
				seed.Parent = scene
			end
			local k = math.clamp((t - T_SEED) / 0.9, 0, 1)
			local from = soil + front * 9 + side * 5 + up * 9
			local pos = from:Lerp(soil + up * 0.3, k) + up * math.sin(k * math.pi) * 3
			if k < 1 then
				seed:PivotTo(CFrame.new(pos) * CFrame.Angles(t * 7, t * 5, 0))
			elseif seed.Parent then
				seed.Parent = nil
				dirt:Emit(18)
				magic:Emit(14)
				shakeLeft = 0.25
			end
			cam(soil + front * 10 + side * 2 + up * 5, (if k < 1 then pos:Lerp(soil, 0.5) else soil), dt, 3)
		elseif t < T_SPROUT then
			-- 2. A fertilizer bag swings in over the soil and pours; the soil glows where it soaks in.
			if enter(2) then
				seed:Destroy()
				bag.Parent = scene
			end
			local k = (t - T_FERT) / (T_SPROUT - T_FERT)
			local appear = backOut(k / 0.2)
			local tip = smooth((k - 0.15) / 0.2) * 125
			local leave = smooth((k - 0.85) / 0.15)
			-- Tipped over sideways (in the camera's view), its neck ending up over the mound.
			local full = CFrame.fromAxisAngle(front, math.rad(125))
			local bagPos = soil + up * (3.6 + leave * 6) - full:VectorToWorldSpace(up) * 1.8
			local bagCf = CFrame.new(bagPos) * CFrame.fromAxisAngle(front, math.rad(tip)) * rot
			local bagScale = math.max(0.05, 1.4 * appear * (1 - leave))
			bag:ScaleTo(bagScale)
			bag:PivotTo(bagCf)
			-- Granules falling from the bag's mouth.
			if k > 0.3 and k < 0.85 and t >= pourNext then
				pourNext = t + 0.035
				local mouth = bagCf:PointToWorldSpace(Vector3.new(0, 1.3 * bagScale, 0))
				local g = prop({
					Anchored = false,
					CanCollide = true,
					Size = Vector3.one * (0.18 + math.random() * 0.14),
					Color = if math.random() < 0.5 then Color3.fromRGB(170, 90, 240) else Color3.fromRGB(110, 220, 120),
					Material = Enum.Material.Neon,
					CastShadow = false,
					CFrame = CFrame.new(mouth + Vector3.new((math.random() - 0.5) * 0.5, 0, (math.random() - 0.5) * 0.5)) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
					Parent = scene,
				})
				g.AssemblyLinearVelocity = Vector3.new((math.random() - 0.5) * 3, -3, (math.random() - 0.5) * 3)
				table.insert(granules, g)
			end
			if k > 0.45 then
				local p = smooth((k - 0.45) / 0.45)
				patch.Size = Vector3.new(0.1, 1 + p * 7, 1 + p * 7)
				patch.Transparency = 0.35 + 0.15 * math.sin(t * 8)
				if math.random() < 0.3 then
					magic:Emit(1)
				end
			end
			cam(soil + front * 9 - side * 2 + up * 5.5, soil + up * 2.2, dt, 3)
		elseif t < T_TREE then
			-- 3. A green sprout pops out of the soil.
			if enter(3) then
				bag:Destroy()
				for _, g in granules do
					g:Destroy()
				end
				sprout:PivotTo(CFrame.new(soil) * rot)
				sprout:ScaleTo(0.05)
				sprout.Parent = scene
				dirt:Emit(16)
				magic:Emit(20)
			end
			local k = (t - T_SPROUT) / (T_TREE - T_SPROUT)
			sprout:ScaleTo(math.max(0.05, 1.3 * backOut(k / 0.45)))
			sprout:PivotTo(CFrame.new(soil) * rot * CFrame.Angles(0, 0, math.sin(t * 6) * 0.08))
			patch.Transparency = math.min(1, patch.Transparency + dt * 0.8)
			cam(soil + front * 5.5 + up * 2.2, soil + up * 1.3, dt, 4)
		elseif t < T_FRUIT then
			-- 4. The sprout shoots up into the Old Oak: the trunk rises, leaves fill in from the bottom.
			if enter(4) then
				sprout:Destroy()
				patch:Destroy()
				for _, l in leaves do
					l.part.Transparency = 1
				end
				tree.Parent = scene
				dirt:Emit(30)
				shakeLeft = 0.5
			end
			local k = (t - T_TREE) / (T_FRUIT - T_TREE)
			local grow = 0.12 + 0.88 * backOut(math.min(1, k / 0.8))
			tree:ScaleTo(math.max(0.05, grow))
			local reveal = math.clamp((k - 0.2) / 0.6, 0, 1)
			if reveal > lastLeafH then
				for _, l in leaves do
					if l.h <= reveal and l.h > lastLeafH then
						l.part.Transparency = 0
					end
				end
				lastLeafH = reveal
			end
			local height = treeInfo.height * grow
			cam(ground.Position + front * (7 + k * 9) + up * (1.5 + k * 3), ground.Position + up * height * 0.55, dt, 3)
		elseif t < T_DROP then
			-- 5. A mystery fruit (black, "?") swells under the crown with a neutral glow.
			if enter(5) then
				tree:ScaleTo(1)
				for _, l in leaves do
					l.part.Transparency = 0
				end
				mystery:ScaleTo(0.05)
				mystery.Parent = scene
				glow.Parent = scene
				sparkle.Rate = 25
			end
			local k = (t - T_FRUIT) / (T_DROP - T_FRUIT)
			local grown = math.max(0.05, backOut(k / 0.6))
			mystery:ScaleTo(grown)
			sizeQuestion(grown * (1 + 0.08 * math.sin(t * 5)))
			mystery:PivotTo(CFrame.new(fruitSpot) * rot * CFrame.Angles(0, math.sin(t * 2) * 0.3, math.sin(t * 3) * 0.08))
			local pulse = 0.5 + 0.5 * math.sin(t * 9)
			glow.CFrame = CFrame.new(fruitSpot)
			glow.Size = Vector3.one * (FRUIT_SIZE * 1.6 + pulse * 0.6) * math.clamp(k * 2, 0, 1)
			glow.Transparency = 0.9 + pulse * 0.05 -- faint aura, the black silhouette must read
			light.Brightness = 0.8 + pulse * 0.7
			cam(fruitSpot + front * 6.5 + up * -1.2, fruitSpot, dt, 3)
		elseif t < T_ZOOM then
			-- 6. It drops to the soil and bounces.
			if enter(6) then
				fruitPos = fruitSpot
				fallVel = 0
				shakeLeft = 0.2
			end
			fallVel -= 70 * dt
			fruitPos += up * fallVel * dt
			local floor = landSpot.Y
			local horizontal = Vector3.new(fruitSpot.X, 0, fruitSpot.Z):Lerp(Vector3.new(landSpot.X, 0, landSpot.Z), math.clamp((t - T_DROP) / 0.4, 0, 1))
			if fruitPos.Y <= floor then
				if fallVel < -6 then
					dirt:Emit(10)
					shakeLeft = 0.35
				end
				fallVel = -fallVel * 0.35
				fruitPos = Vector3.new(fruitPos.X, floor, fruitPos.Z)
			end
			fruitPos = Vector3.new(horizontal.X, fruitPos.Y, horizontal.Z)
			mystery:ScaleTo(1)
			sizeQuestion(1)
			mystery:PivotTo(CFrame.new(fruitPos) * rot * CFrame.Angles(0, (t - T_DROP) * 4, 0))
			glow.CFrame = CFrame.new(fruitPos)
			cam(landSpot + front * 7 + up * 3.5, fruitPos:Lerp(landSpot, 0.5), dt, 3)
		elseif t < T_END then
			-- 7. Zoom in on the mystery fruit: it lifts and trembles faster and faster, the "?" throbs...
			--    then a burst reveals the real fruit, its name and rarity colour; then a white flash.
			if enter(7) then
				sparkle.Rate = 40
			end
			local k = (t - T_ZOOM) / (T_END - T_ZOOM)
			local at = landSpot + up * smooth(k / REVEAL_AT) * 1.2
			if k < REVEAL_AT then
				local s = k / REVEAL_AT
				local amount = s * s * 0.14
				local jitter = Vector3.new((math.random() - 0.5) * amount, (math.random() - 0.5) * amount, (math.random() - 0.5) * amount)
				mystery:PivotTo(CFrame.new(at + jitter) * rot * CFrame.Angles(0, (t - T_ZOOM) * (2 + s * 14), 0))
				local pulse = 0.5 + 0.5 * math.sin(t * (6 + s * 22))
				sizeQuestion(1 + pulse * (0.1 + s * 0.2))
				qLabel.TextColor3 = Color3.new(1, 1, 1):Lerp(MYSTERY, pulse * s)
				glow.CFrame = CFrame.new(at)
				glow.Size = Vector3.one * (FRUIT_SIZE * 1.5 + pulse * 0.5 + s * 1.5)
				glow.Transparency = 0.92 - s * 0.2
				light.Brightness = 1 + s * 3 + pulse
				if math.random() < s * 0.5 then
					magic:Emit(1)
				end
				shakeLeft = math.max(shakeLeft, s * 0.1)
				camera.FieldOfView = 55 - smooth(s) * 18
				cam(at + front * (4.6 - s * 1.1) + up * 0.6, at, dt, 5)
			else
				if not revealed then
					revealed = true
					-- Burst: swap in the real fruit, the glow takes the rarity colour.
					mystery.Parent = nil
					fruit:ScaleTo(1)
					fruit.Parent = scene
					glow.Color = rarityColor
					light.Color = rarityColor
					sparkle.Color = ColorSequence.new(rarityColor)
					sparkle:Emit(70)
					magic:Emit(30)
					shakeLeft = 0.6
					flash.BackgroundColor3 = Color3.new(1, 1, 1)
					flash.BackgroundTransparency = 0.1
					tween(flash, 0.45, { BackgroundTransparency = 1 })
					-- Name + rarity popping in under the fruit.
					local card = new("Frame", { Name = "FruitName", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.76), Size = UDim2.fromScale(0.6, 0.14), ZIndex = 8, Parent = cutGui })
					local nameLabel = label({ Text = def.Name, Size = UDim2.fromScale(1, 0.62), StrokeThickness = 4, ZIndex = 8, Parent = card })
					new("UIGradient", { Color = ColorSequence.new(Color3.new(1, 1, 1), rarityColor), Rotation = 90, Parent = nameLabel })
					local rarityLabel = label({ Text = def.Rarity, Position = UDim2.fromScale(0, 0.62), Size = UDim2.fromScale(1, 0.38), StrokeThickness = 3, ZIndex = 8, Parent = card })
					HeroConfig.PaintRarity(rarityLabel, def.Rarity)
					local pop = new("UIScale", { Scale = 0.3, Parent = card })
					tween(pop, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
					nameCard = card
				end
				local s = (k - REVEAL_AT) / (1 - REVEAL_AT)
				fruit:PivotTo(CFrame.new(at) * rot * CFrame.Angles(0, (t - T_ZOOM) * 2.5, 0))
				glow.CFrame = CFrame.new(at)
				glow.Size = Vector3.one * (FRUIT_SIZE * 1.8 + s * 2 + 0.3 * math.sin(t * 6))
				glow.Transparency = 0.55 + 0.1 * math.sin(t * 6)
				light.Brightness = 6 + s * 3
				-- Pull back a little so the fruit and its name are both in frame.
				camera.FieldOfView = 37 + smooth(s / 0.4) * 6
				cam(at + front * 4.6 + up * 0.9, at + up * -0.25, dt, 4)
				if s > 0.78 then
					flash.BackgroundColor3 = Color3.new(1, 1, 1)
					flash.BackgroundTransparency = 1 - smooth((s - 0.78) / 0.22)
				end
			end
		elseif not doneRunning then
			doneRunning = true
			conn:Disconnect()
			skip:Destroy()
			flash.BackgroundTransparency = 0
			tween(flash, 0.5, { BackgroundTransparency = 0.25 })
			flash.BackgroundColor3 = Color3.fromRGB(20, 12, 34)
			scene:Destroy()
			glow:Destroy()
			if nameCard then
				nameCard:Destroy()
			end
			for _, p in { seed, bag, sprout, tree, fruit, mystery } :: { Instance } do
				p:Destroy()
			end
			-- Reveal over a dim backdrop; the sign / prompt / your character come back after it.
			reveal(cutGui, def, function()
				camera.CameraType = oldType
				camera.CFrame = oldCFrame
				camera.FieldOfView = oldFov
				if controls then
					controls:Enable()
				end
				showWorld()
				showGuis()
				cutGui:Destroy()
				onDone()
			end)
		end
	end)
end

-- GROW ------------------------------------------------------------------------------------------------

growButton.Activated:Connect(function()
	if busy then
		return
	end
	if fertilizer() < FruitConfig.FertilizerPerGrow then
		toast(("You need %s! Get more below."):format(FruitConfig.FertilizerName), BAD)
		return
	end
	local garden = myGarden()
	if not garden then
		toast("Your Devil Tree isn't ready", BAD)
		return
	end
	busy = true
	local ok, result = pcall(FruitAction.InvokeServer, FruitAction, "Grow")
	if not ok or typeof(result) ~= "table" or not result.ok then
		busy = false
		toast(if ok and typeof(result) == "table" and result.message then result.message else "Couldn't grow", BAD)
		return
	end
	local def = FruitConfig.Get(result.fruit)
	if not def then
		busy = false
		return
	end
	gui.Enabled = false
	playCutscene(def, garden, function()
		busy = false
		if isOpen then
			openWindow()
		end
	end)
end)

-- Greenhouse doors -------------------------------------------------------------------------------------
-- The double door of every greenhouse (FruitModels.Greenhouse: models "DoorLeft" / "DoorRight" with
-- an OpenDir attribute, pivot = hinge) swings open locally when your character comes close.

local DOOR_RANGE = 13
local DOOR_ANGLE = math.rad(105)
-- `closed` is read once the hinge has streamed in (and forgotten again if it streams out).
local doors: { [Model]: { closed: CFrame?, dir: number, open: number } } = {}

local function trackDoor(leaf: Instance)
	if leaf:IsA("Model") and (leaf.Name == "DoorLeft" or leaf.Name == "DoorRight") and not doors[leaf] then
		local dir = leaf:GetAttribute("OpenDir")
		if typeof(dir) == "number" then
			doors[leaf] = { closed = nil, dir = dir, open = 0 }
		end
	end
end

local plotsFolder = workspace:WaitForChild("Plots", 10)
if plotsFolder then
	for _, d in plotsFolder:GetDescendants() do
		trackDoor(d)
	end
	plotsFolder.DescendantAdded:Connect(trackDoor)
end

RunService.Heartbeat:Connect(function(dt)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	for leaf, state in doors do
		if not leaf:IsDescendantOf(workspace) then
			doors[leaf] = nil
			continue
		end
		if not leaf.PrimaryPart then
			state.closed = nil
			state.open = 0
			continue
		end
		if not state.closed then
			state.closed = leaf:GetPivot()
		end
		local closed = state.closed :: CFrame
		local near = root ~= nil and (root.Position - closed.Position).Magnitude < DOOR_RANGE
		local target = if near then 1 else 0
		if state.open ~= target then
			state.open = if target > state.open then math.min(1, state.open + dt * 2.2) else math.max(0, state.open - dt * 1.4)
			leaf:PivotTo(closed * CFrame.Angles(0, DOOR_ANGLE * smooth(state.open) * state.dir, 0))
		end
	end
end)
