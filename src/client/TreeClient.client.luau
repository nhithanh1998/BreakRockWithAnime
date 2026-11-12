-- TreeClient: click / tap trees to chop them.
-- Plays hit effects right away (prediction) and asks the server to deal the damage; the server's
-- answer brings the damage number, the fall animation and the drops.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeFX = require(script.Parent:WaitForChild("TreeFX"))
local DropFX = require(script.Parent:WaitForChild("DropFX"))
local ChestFX = require(script.Parent:WaitForChild("ChestFX"))
local TargetRing = require(script.Parent:WaitForChild("TargetRing"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitTree = Remotes:WaitForChild("HitTree") :: RemoteEvent
local TreeHit = Remotes:WaitForChild("TreeHit") :: RemoteEvent
local TreeDrops = Remotes:WaitForChild("TreeDrops") :: RemoteEvent

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local lastClick = 0
local holding = false
local holdScreenPos: Vector2? = nil

-- Finding the tree under the cursor ------------------------------------------------------------

local function treeFromPart(inst: Instance?): Model?
	while inst and inst ~= workspace do
		local parent = inst.Parent
		if parent and parent.Name == "TreeSpawns" and inst:IsA("Model") then
			return inst
		end
		inst = parent
	end
	return nil
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function raycastScreen(screenPos: Vector2): (Model?, Vector3?)
	local exclude: { Instance } = { TreeFX.Folder }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	rayParams.FilterDescendantsInstances = exclude
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams)
	if not result then
		return nil, nil
	end
	return treeFromPart(result.Instance), result.Position
end

local function canChop(tree: Model): boolean
	if tree:GetAttribute("Dead") or (tree:GetAttribute("HP") or 0) <= 0 then
		return false
	end
	if TreeConfig.OnlyOwnPlot then
		local plot = tree.Parent and tree.Parent.Parent
		if not plot or plot:GetAttribute("OwnerUserId") ~= player.UserId then
			return false
		end
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - tree:GetPivot().Position).Magnitude > TreeConfig.MaxHitDistance then
		return false
	end
	return true
end

local function myPosition(): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root and root.Position
end

-- Chopping -------------------------------------------------------------------------------------

local function tryChop(screenPos: Vector2)
	local now = os.clock()
	if now - lastClick < TreeConfig.ClickCooldown then
		return
	end
	local tree, hitPos = raycastScreen(screenPos)
	if not tree or not hitPos or not canChop(tree) then
		return
	end
	lastClick = now
	TreeFX.Hit(tree, hitPos, myPosition())
	TargetRing.MarkHit(tree)
	HitTree:FireServer(tree, hitPos)
end

-- Hover outline (mouse only) -------------------------------------------------------------------

local hover = Instance.new("Highlight")
hover.Name = "TreeHover"
hover.FillTransparency = 1
hover.OutlineColor = TreeConfig.HoverOutlineColor
hover.OutlineTransparency = 0.35
hover.DepthMode = Enum.HighlightDepthMode.Occluded
hover.Enabled = false
hover.Parent = TreeFX.Folder

RunService.RenderStepped:Connect(function()
	if holding and holdScreenPos then
		tryChop(holdScreenPos)
	end
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	-- GetMouseLocation includes the top bar inset; ViewportPointToRay expects exactly that.
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local exclude: { Instance } = { TreeFX.Folder }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	rayParams.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams)
	local tree = result and treeFromPart(result.Instance)
	if tree and canChop(tree) then
		hover.Adornee = tree
		hover.Enabled = true
	else
		hover.Enabled = false
		hover.Adornee = nil
	end
end)

-- Input ----------------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		tryChop(pos)
		if TreeConfig.HoldToChop then
			holding = true
			holdScreenPos = pos
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not holding then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		holdScreenPos = Vector2.new(input.Position.X, input.Position.Y)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		holding = false
		holdScreenPos = nil
	end
end)

-- HP bars --------------------------------------------------------------------------------------
-- Tree templates carry InfoAttachment.TreeBar.Container: "TreeName" and "HPFill" (with "Empty" and
-- "HPDisplay" "1.2K/2K"). The look is rebuilt here on the client, from the tree's HP / MaxHP
-- attributes: a dark track, a cyan fill that slides down on each hit, a white "lag" bar behind it
-- that catches up a moment later, and a quick pop + shake of the whole bar when the tree is hit.

local TRACK_COLOR = Color3.fromRGB(16, 18, 28)
local TRACK_STROKE = Color3.fromRGB(0, 0, 0)
local FILL_TOP = Color3.fromRGB(140, 240, 255)
local FILL_BOTTOM = Color3.fromRGB(30, 175, 240)
local LAG_COLOR = Color3.fromRGB(255, 255, 255)
local FLASH_COLOR = Color3.fromRGB(255, 255, 255)
local LOW_TOP = Color3.fromRGB(255, 150, 120) -- fill colours below LOW_RATIO
local LOW_BOTTOM = Color3.fromRGB(235, 60, 60)
local LOW_RATIO = 0.25

local FILL_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LAG_DELAY = 0.28
local LAG_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_SCALE = 1.12
local SHAKE_TIME = 0.16
local SHAKE_STUDS = 0.09

type Bar = {
	gui: BillboardGui?,
	track: Frame,
	fill: Frame,
	fillGradient: UIGradient,
	flash: Frame,
	lag: Frame,
	text: TextLabel?,
	scale: UIScale?,
	baseOffset: Vector3,
	ratio: number,
	lagToken: number,
	shakeToken: number,
}

local bars: { [Model]: Bar } = setmetatable({}, { __mode = "k" }) :: any

local function corner(parent: Instance, radius: UDim)
	local c = parent:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function layer(parent: Frame, name: string, color: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.AnchorPoint = Vector2.new(0, 0)
	f.Position = UDim2.fromScale(0, 0)
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = z
	corner(f, UDim.new(0.25, 0))
	f.Parent = parent
	return f
end

local function setupBar(tree: Model): Bar?
	local existing = bars[tree]
	if existing and existing.track.Parent then
		return existing
	end
	local track = tree:FindFirstChild("HPFill", true)
	if not track or not track:IsA("Frame") then
		return nil
	end
	local gui = track:FindFirstAncestorOfClass("BillboardGui")
	local container = track.Parent

	-- Track: the dark background.
	track.BackgroundColor3 = TRACK_COLOR
	track.BackgroundTransparency = 0.15
	corner(track, UDim.new(0.25, 0))
	-- Billboards draw at a tiny internal resolution, so strokes are fractions of a pixel here.
	local stroke = track:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = TRACK_STROKE
	stroke.Thickness = 0.12
	stroke.Transparency = 0
	stroke.Parent = track
	local empty = track:FindFirstChild("Empty")
	if empty and empty:IsA("GuiObject") then
		empty.Visible = false
	end

	local lag = layer(track, "Lag", LAG_COLOR, 2)
	lag.BackgroundTransparency = 0.15
	local fill = layer(track, "Fill", Color3.new(1, 1, 1), 3)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Parent = fill
	-- Shine on the upper half of the fill.
	local shine = layer(fill, "Shine", Color3.new(1, 1, 1), 4)
	shine.Size = UDim2.fromScale(1, 0.42)
	shine.BackgroundTransparency = 0.72
	local flash = layer(fill, "Flash", FLASH_COLOR, 5)
	flash.BackgroundTransparency = 1

	local text = track:FindFirstChild("HPDisplay") :: TextLabel?
	if text then
		text.ZIndex = 6
		text.TextColor3 = Color3.new(1, 1, 1)
		local ts = text:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
		ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		ts.Color = Color3.new(0, 0, 0)
		ts.Thickness = 0.08
		ts.Parent = text
	end

	local scale: UIScale? = nil
	if container and container:IsA("GuiObject") then
		scale = container:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = container
	end

	local bar: Bar = {
		gui = gui,
		track = track,
		fill = fill,
		fillGradient = gradient,
		flash = flash,
		lag = lag,
		text = text,
		scale = scale,
		baseOffset = if gui then gui.StudsOffset else Vector3.zero,
		ratio = 1,
		lagToken = 0,
		shakeToken = 0,
	}
	bars[tree] = bar
	return bar
end

local function paintFill(bar: Bar, ratio: number)
	local low = ratio <= LOW_RATIO
	bar.fillGradient.Color = ColorSequence.new(if low then LOW_TOP else FILL_TOP, if low then LOW_BOTTOM else FILL_BOTTOM)
end

-- Pop + shake + white flash: the bar reacts to a hit.
local function punch(bar: Bar)
	if bar.scale then
		bar.scale.Scale = POP_SCALE
		TweenService:Create(bar.scale, POP_TWEEN, { Scale = 1 }):Play()
	end
	bar.flash.BackgroundTransparency = 0.25
	TweenService:Create(bar.flash, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	local gui = bar.gui
	if gui then
		bar.shakeToken += 1
		local token = bar.shakeToken
		task.spawn(function()
			local t0 = os.clock()
			while os.clock() - t0 < SHAKE_TIME and bar.shakeToken == token and gui.Parent do
				local k = 1 - (os.clock() - t0) / SHAKE_TIME
				gui.StudsOffset = bar.baseOffset + Vector3.new((math.random() * 2 - 1) * SHAKE_STUDS * k, (math.random() * 2 - 1) * SHAKE_STUDS * 0.5 * k, 0)
				task.wait()
			end
			if bar.shakeToken == token then
				gui.StudsOffset = bar.baseOffset
			end
		end)
	end
end

local function drawBar(tree: Model, animate: boolean)
	local bar = setupBar(tree)
	if not bar then
		return
	end
	local hp = math.max(tree:GetAttribute("HP") or 0, 0)
	local maxHp = math.max(tree:GetAttribute("MaxHP") or 1, 1)
	local ratio = math.clamp(hp / maxHp, 0, 1)
	local goal = UDim2.fromScale(ratio, 1)
	paintFill(bar, ratio)
	bar.fill.Visible = ratio > 0
	local damaged = ratio < bar.ratio - 1e-6
	bar.ratio = ratio

	bar.lagToken += 1
	if animate and damaged then
		TweenService:Create(bar.fill, FILL_TWEEN, { Size = goal }):Play()
		-- The white lag bar waits a moment, then drains down to the fill.
		local token = bar.lagToken
		task.delay(LAG_DELAY, function()
			if bar.lagToken == token and bar.lag.Parent then
				TweenService:Create(bar.lag, LAG_TWEEN, { Size = goal }):Play()
			end
		end)
		punch(bar)
	else
		-- First draw, regrowth or a respawn: snap.
		bar.fill.Size = goal
		bar.lag.Size = goal
	end
	if bar.text then
		bar.text.Text = ("%s/%s"):format(HeroConfig.Abbreviate(hp), HeroConfig.Abbreviate(maxHp))
	end
end

local barBound: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function bindBar(tree: Instance)
	if not tree:IsA("Model") or barBound[tree] then
		return
	end
	barBound[tree] = true
	drawBar(tree, false)
	task.delay(0.5, drawBar, tree, false) -- in case the bar arrived after the model
	tree:GetAttributeChangedSignal("HP"):Connect(function()
		drawBar(tree, true)
	end)
	tree:GetAttributeChangedSignal("MaxHP"):Connect(function()
		drawBar(tree, false)
	end)
end

local function isTree(inst: Instance): boolean
	return inst:IsA("Model") and inst.Parent ~= nil and inst.Parent.Name == "TreeSpawns"
end

for _, d in workspace:GetDescendants() do
	if isTree(d) then
		bindBar(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if isTree(d) then
		-- The bar's GUI streams in with the tree; give it a moment.
		task.defer(bindBar, d)
	end
end)

-- Server results -------------------------------------------------------------------------------

TreeHit.OnClientEvent:Connect(function(tree: Model?, attacker: Player?, damage: number, hitPos: Vector3, felled: boolean, heroPos: Vector3?)
	if not tree or not tree.Parent then
		return
	end
	local fromPos: Vector3? = heroPos -- set when a hero (not a player) made the hit
	local attackerRoot = attacker and attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if attackerRoot then
		fromPos = attackerRoot.Position
	end
	-- Our own hits were already shown when we clicked.
	if attacker ~= player and not felled then
		TreeFX.Hit(tree, hitPos, fromPos)
	end
	TreeFX.DamageNumber(hitPos, damage)
	if not felled then
		TargetRing.MarkHit(tree)
	end
	if felled then
		TreeFX.Fell(tree, fromPos)
	end
end)

TreeDrops.OnClientEvent:Connect(function(origin: Vector3, groundY: number, drops, chest: Model?)
	DropFX.Play(origin, groundY, drops, chest)
end)

ChestFX.Start()
TargetRing.Start()
